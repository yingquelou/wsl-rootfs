#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Debian 远古套件（buzz/rex/bo/hamm/slink，1996–1999）独立 rootfs 构建器。

为什么不用 debootstrap/mmdebstrap（嫁接路线已废弃）：
  这五个套件在 archive.debian.org 上连 dists/<suite>/Release 都没有；而它们的 .deb 仍是标准
  ar/tar 格式，现代 dpkg-deb 可以直接解包。嫁接路线（合成 Release + 补丁 debootstrap + 两阶段
  chroot configure）会逐个踩中古董维护脚本的坑：exim/smail 交互向导、timezones 交互、install-info
  锁、perl.dist 改名、invalid user、libc5 在现代内核 OOM……越老的套件坑越深且无收敛迹象。

本构建器的做法（全部已用原型实测）：
  1. 直接抓各组件 Packages.gz（不需要 Release），解析出 Priority: required 包集合；
  2. 沿 Depends/Pre-Depends 做依赖闭包（alternative 取仓库内第一个可满足者，识别 Provides）；
  3. 下载 .deb（MD5Sum 校验），buzz/rex 的 Filename 指向已删除的 Debian-1.x 旧树时，保留
     子目录、改试 dists/<suite>/main/{binary-all,binary-i386}/<子目录>/<文件名>；
  4. dpkg-deb -x 纯解包——不执行任何 preinst/postinst，因此彻底不存在交互挂起/顺序问题；
  5. 静态补齐系统配置：passwd/group（base-passwd master 或 buzz 的 base 包）、debian_version、
     fstab/hostname/hosts、perl.dist 改名、/dev 设备节点、libc5 加载器 soname 符号链接
     （ld-linux.so.1 等，正常由 ldso postinst 创建）、dpkg status 数据库；
  6. 执行验证：chroot 跑 /bin/sh + id。slink/hamm 等 libc6 套件现代内核原生即可；
     buzz/rex/bo 等 libc5 套件原生会 “Out of virtual memory”（老加载器与现代内核不兼容），
     自动注册 qemu-i386-static 的 binfmt_misc 后用用户态模拟验证，做完注销（qemu 不进产物）；
  7. 打包 deb-<suite>-<arch>-rootfs.tar.gz，并做 tar 结构校验，杜绝空产物。

产物：./debian/deb-<suite>-<arch>-rootfs.tar.gz
日志：./debian/logs/deb-<suite>-<arch>.log
这五个套件只有 i386：请求 amd64 时会明确报告“归档里没有该架构”并跳过（不算失败）。

用法（在仓库根目录、Linux/WSL 下，需要 root 做 chroot/mknod）：
  sudo python3 debian-ancient.py
  ONLY="slink buzz" ARCHES="i386" sudo -E python3 debian-ancient.py
  JOBS=16 MIRRORS="https://a/debian http://b/debian" sudo -E python3 debian-ancient.py

源与效率（均可用环境变量覆盖）：
  * 源不固定：默认 archive.debian.org 的 https/http 双源按序尝试，单个文件下载失败自动
    换下一个源，成功过的源优先；MIRRORS（空格/逗号分隔）可整体替换，MIRROR=xxx 插最前。
  * 并行下载：JOBS（默认 8）线程并行下载+MD5 校验进缓存，再按闭包顺序解包。
  * 断点省事：已有有效产物默认跳过，FORCE=1 强制重建。
"""

import gzip
import hashlib
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

# 源不固定：按序尝试，单个文件下载失败自动换下一个源，成功过的源排最前。
# MIRRORS（空格/逗号分隔）整体替换；MIRROR=xxx 插到最前；JOBS=下载线程数；FORCE=1 强制重建。
DEFAULT_MIRRORS = [
    "https://archive.debian.org/debian",
    "http://archive.debian.org/debian",
]


def _resolve_mirrors():
    env = os.environ.get("MIRRORS", "").replace(",", " ").split()
    if env:
        return env
    first = os.environ.get("MIRROR", "").strip()
    return ([first] if first else []) + DEFAULT_MIRRORS


MIRRORS = _resolve_mirrors()
try:
    JOBS = max(2, int(os.environ.get("JOBS", "8")))
except ValueError:
    JOBS = 8
FORCE = os.environ.get("FORCE", "").strip() == "1"

SUITES = ["buzz", "rex", "bo", "hamm", "slink"]
# 各套件的 /etc/debian_version（Debian 发行代号版本号）
DEBIAN_VERSION = {
    "buzz": "1.1",
    "rex": "1.2",
    "bo": "1.3",
    "hamm": "2.0",
    "slink": "2.1",
}
COMPONENTS = ["main", "contrib", "non-free"]
# target/缓存必须在 Linux 原生文件系统上（chroot、mknod 无法在 /mnt 下的 drvfs 上工作）
HOME = os.path.expanduser("~")
CACHE_DIR = os.path.join(HOME, "debootstrap-cache-debian")
BUILD_ROOT = os.path.join(HOME, "debian-ancient")
# 产物/日志落在调用目录（仓库根）
OUT_DIR = os.path.join(os.getcwd(), "debian")
LOG_DIR = os.path.join(OUT_DIR, "logs")

# qemu-i386 静态解释器候选（binfmt-P 包装器不能配 F flag，会段错误，只认真静态二进制）
QEMU_I386_CANDIDATES = ["/usr/bin/qemu-i386-static", "/usr/bin/qemu-i386"]
QEMU_I386_MAGIC = (
    r"\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    r"\x02\x00\x03\x00"
)
QEMU_I386_MASK = (
    r"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff"
    r"\xff\xff\xfe\xff\xff\xff"
)
BINFMT_REGISTER = "/proc/sys/fs/binfmt_misc/register"
BINFMT_QEMU_I386 = "/proc/sys/fs/binfmt_misc/qemu-i386"


_LOG_LOCK = threading.Lock()      # 控制台/套件日志按行输出不串行错乱（下载线程并发 emit）
_MIRROR_LOCK = threading.Lock()
_MIRROR_GOOD = {"m": None}        # 本次运行中最近成功过的源，优先使用


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    with _LOG_LOCK:
        print(line, flush=True)


class SuiteLogger:
    """同时输出到控制台和该套件的日志文件。"""

    def __init__(self, path):
        self.f = open(path, "a", encoding="utf-8")

    def emit(self, msg):
        line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
        with _LOG_LOCK:
            print(line, flush=True)
            self.f.write(line + "\n")
            self.f.flush()

    def close(self):
        self.f.close()


def run(cmd, check=False, timeout=None, capture=True, env=None):
    return subprocess.run(
        cmd,
        check=check,
        timeout=timeout,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        env=env,
    )


# ---------------------------------------------------------------- 索引解析
def parse_packages(data):
    """解析 RFC822 风格的 Packages 内容为 {包名小写: 字段dict(小写键)}。

    同名包以先出现者为准（调用方按 main→contrib→non-free 顺序喂入）。
    字段名全部小写，兼容 buzz 的全小写字段。续行（空格/Tab 开头）合并为空格。
    """
    pkgs = {}
    for block in data.split("\n\n"):
        fields = {}
        for m in re.finditer(
            r"^([A-Za-z-]+):[ \t]*(.*(?:\n[ \t].*)*)", block, re.M
        ):
            key = m.group(1).lower()
            val = re.sub(r"\s+", " ", m.group(2)).strip()
            fields[key] = val
        name = fields.get("package", "").lower()
        if name and name not in pkgs:
            pkgs[name] = fields
    return pkgs


def download(url, dst, attempts=3):
    """下载到 dst；TLS 拦截环境下允许放弃证书校验。返回是否成功且非空。"""
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return True
    tmp = dst + ".part"
    for i in range(attempts):
        for opts in (["-q"], ["-q", "--no-check-certificate"]):
            r = run(["wget"] + opts + ["-O", tmp, url])
            if r.returncode == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
                os.replace(tmp, dst)
                return True
        time.sleep(1 + i)
    if os.path.exists(tmp):
        os.remove(tmp)
    return False


def _mirror_order():
    """按“最近成功的源优先”排列源列表。"""
    with _MIRROR_LOCK:
        good = _MIRROR_GOOD["m"]
    rest = [m for m in MIRRORS if m != good]
    return ([good] if good else []) + rest


def fetch_rel(rel, dst, attempts=2):
    """从源列表依次尝试把 rel 下载到 dst（缓存命中直接成功）；成功后记住优先源。"""
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return True
    for m in _mirror_order():
        if download("%s/%s" % (m, rel), dst, attempts=attempts):
            with _MIRROR_LOCK:
                _MIRROR_GOOD["m"] = m
            return True
    return False


def fetch_packages(suite, arch, lg):
    """并行抓 main(必选)+contrib/non-free(可选) 的 Packages.gz 并解析。

    amd64 在这五个套件上不存在：main 也取不到时返回 None，由调用方给出“无此架构”结论。
    """
    def get_comp(comp):
        rel = "dists/%s/%s/binary-%s/Packages.gz" % (suite, comp, arch)
        tmp = os.path.join(BUILD_ROOT, "%s-%s-%s-Packages.gz" % (suite, comp, arch))
        return comp, fetch_rel(rel, tmp)

    got = {}
    with ThreadPoolExecutor(max_workers=min(JOBS, len(COMPONENTS))) as ex:
        for comp, ok in ex.map(get_comp, COMPONENTS):
            got[comp] = ok
    if not got.get("main"):
        # main 必选：连 main 都没有说明该架构在归档中不存在（如 amd64）
        return None

    merged = {}
    got_any = False
    for comp in COMPONENTS:  # main 优先
        if not got.get(comp):
            lg.emit("  组件 %s 无索引（该时代可能尚未拆分），跳过" % comp)
            continue
        tmp = os.path.join(BUILD_ROOT, "%s-%s-%s-Packages.gz" % (suite, comp, arch))
        try:
            with gzip.open(tmp, "rt", errors="replace") as f:
                data = f.read()
        except OSError:
            continue
        part = parse_packages(data)
        for name, fields in part.items():
            if name not in merged:  # main 优先
                merged[name] = fields
        got_any = True
        lg.emit("  组件 %s：%d 个包" % (comp, len(part)))
    return merged if got_any else None


# ---------------------------------------------------------------- 依赖闭包
def split_dep_names(clause):
    """'smail | mail-transport-agent (>= 1)' -> ['smail','mail-transport-agent']。"""
    names = []
    for alt in clause.split("|"):
        # 去掉版本约束 (...)、架构限定 [...]、:any，取第一个 token
        name = re.split(r"[\s(:\[]", alt.strip(), maxsplit=1)[0].lower()
        if name and not name.startswith("${"):
            names.append(name)
    return names


def package_deps(fields):
    """返回 Depends/Pre-Depends 的 alternative 列表（每个元素是候选名列表）。"""
    clauses = []
    for key in ("depends", "pre-depends"):
        for raw in fields.get(key, "").split(","):
            raw = raw.strip()
            if not raw:
                continue
            names = split_dep_names(raw)
            if names:
                clauses.append(names)
    return clauses


def resolve_closure(pkgs, seeds, lg):
    """从 seeds 出发按依赖闭包选包。

    alternative 满足顺序：仓库中的真实包 > 某包通过 Provides 声明的虚拟提供者。
    无法满足的依赖子句跳过（required 自举集之外的引用，debootstrap 同样 force-depends）。
    """
    # 虚拟包名 -> 提供者（取第一个）
    providers = {}
    for name, f in pkgs.items():
        for pv in f.get("provides", "").split(","):
            pv = re.split(r"[\s(:\[]", pv.strip(), maxsplit=1)[0].lower()
            if pv:
                providers.setdefault(pv, name)

    def resolve_alt(names):
        for n in names:
            if n in pkgs:
                return n
        for n in names:
            if n in providers and providers[n] in pkgs:
                return providers[n]
        return None

    ordered = []
    have = set()
    queued = set(seeds)
    todo = list(seeds)
    missing = set()
    while todo:
        name = todo.pop(0)
        if name in have:
            continue
        if name not in pkgs:
            # 种子/依赖点名但仓库索引里没有（极少），记录后跳过
            have.add(name)
            missing.add(name)
            continue
        have.add(name)
        ordered.append(name)
        for alts in package_deps(pkgs[name]):
            pick = resolve_alt(alts)
            if pick and pick not in have and pick not in queued:
                queued.add(pick)
                todo.append(pick)
    if missing:
        lg.emit("  依赖闭包：索引中不存在、已跳过的包名: %s" % " ".join(sorted(missing)))
    return ordered


# ---------------------------------------------------------------- 下载/解包
def deb_candidates(suite, arch, filename):
    """由 Packages 的 Filename 生成下载 URL 候选。

    常规（hamm/slink 起）：Filename 已是 dists/... 标准相对路径，直接下。
    旧树（buzz/rex）：Filename 形如 Debian-1.1/binary-i386/base/x.deb，旧目录已从归档删除；
    归档把文件挪到了 dists/<suite>/main/ 下，架构目录要同时试 binary-all（all 架构包，
    如 adduser）和 binary-i386，并保留 Filename 里声明的子目录（base/、misc/ 等）。
    """
    cands = [filename]
    m = re.match(r"^Debian-[0-9.]+/binary-[a-z0-9]+/(.*)$", filename)
    if m:
        sub = m.group(1)
        cands += [
            "dists/%s/main/binary-all/%s" % (suite, sub),
            "dists/%s/main/binary-%s/%s" % (suite, arch, sub),
        ]
    return cands


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download_deb(suite, arch, fields, lg):
    filename = fields.get("filename", "")
    if not filename:
        return None
    dst = os.path.join(CACHE_DIR, os.path.basename(filename))
    if not (os.path.exists(dst) and os.path.getsize(dst) > 0):
        ok = False
        for rel in deb_candidates(suite, arch, filename):
            if fetch_rel(rel, dst):
                ok = True
                break
        if not ok:
            return None
    # MD5Sum 校验（远古包没有 SHA256；buzz 字段名为小写 md5sum）
    expect = fields.get("md5sum", "").lower()
    if expect and re.fullmatch(r"[0-9a-f]{32}", expect):
        actual = md5_file(dst)
        if actual != expect:
            lg.emit("  MD5 不符，丢弃重下: %s" % os.path.basename(filename))
            os.remove(dst)
            for rel in deb_candidates(suite, arch, filename):
                if fetch_rel(rel, dst) and md5_file(dst) == expect:
                    break
            else:
                return None
    return dst


# ---------------------------------------------------------------- 静态系统配置
def write_file(path, content, mode=None):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    if mode is not None:
        os.chmod(path, mode)


def configure_target(target, suite, chosen_pkgs, deb_path, lg):
    etc = os.path.join(target, "etc")
    os.makedirs(etc, exist_ok=True)

    # ---- passwd / group ----
    # hamm/slink 由 base-passwd 包提供 master 模板；buzz 时代无 base-passwd，
    # 由 required 的 base 包直接放入 /etc/passwd、/etc/group。
    pw_master = os.path.join(target, "usr/share/base-passwd/passwd.master")
    gr_master = os.path.join(target, "usr/share/base-passwd/group.master")
    etc_pw = os.path.join(etc, "passwd")
    etc_gr = os.path.join(etc, "group")
    if os.path.exists(pw_master):
        shutil.copyfile(pw_master, etc_pw)
        shutil.copyfile(gr_master, etc_gr)
        lg.emit("  passwd/group：base-passwd master")
    elif os.path.exists(etc_pw) and _file_contains(etc_pw, "root"):
        lg.emit("  passwd/group：保留 base 包提供的原始文件")
    else:
        write_file(etc_pw, "root::0:0:root:/root:/bin/sh\n", 0o644)
        write_file(etc_gr, "root:x:0:\n", 0o644)
        lg.emit("  passwd/group：内置最小 root 集")
    # 空 shadow 占位，避免部分工具因 shadow 缺失报错
    shadow = os.path.join(etc, "shadow")
    if not os.path.exists(shadow):
        write_file(shadow, "root:*:10000:0:99999:7:::\n", 0o640)

    # ---- 基础标识与网络文件（包已提供则不覆盖）----
    write_file(os.path.join(etc, "debian_version"),
               DEBIAN_VERSION[suite] + "\n")
    _write_if_absent(os.path.join(etc, "fstab"),
                     "# UNCONFIGURED FSTAB FOR BASE SYSTEM\n")
    _write_if_absent(os.path.join(etc, "hostname"), "localhost\n")
    _write_if_absent(os.path.join(etc, "hosts"),
                     "127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost\n")
    _write_if_absent(os.path.join(etc, "shells"),
                     "/bin/sh\n/bin/bash\n")
    mtab = os.path.join(etc, "mtab")
    if not os.path.lexists(mtab):
        os.symlink("/proc/mounts", mtab)

    # ---- perl.dist -> perl（名字本应由 perl-base postinst 创建）----
    perl_dist = os.path.join(target, "usr/bin/perl.dist")
    perl = os.path.join(target, "usr/bin/perl")
    if os.path.exists(perl_dist) and not os.path.exists(perl):
        shutil.copyfile(perl_dist, perl)
        st = os.stat(perl_dist)
        os.chmod(perl, st.st_mode)
        lg.emit("  perl.dist 已改名为 /usr/bin/perl")

    # ---- 基础设备节点（必须在原生 ext4 上；drvfs 不支持 mknod）----
    dev = os.path.join(target, "dev")
    os.makedirs(dev, exist_ok=True)
    for node, kind, major, minor, mode in (
        ("null", "c", 1, 3, 0o666),
        ("zero", "c", 1, 5, 0o666),
        ("full", "c", 1, 7, 0o666),
        ("console", "c", 5, 1, 0o600),
        ("tty", "c", 5, 0, 0o666),
    ):
        p = os.path.join(dev, node)
        if not os.path.exists(p):
            # 0o020000 == S_IFCHR
            os.mknod(p, 0o020000 | mode, os.makedev(major, minor))

    # ---- libc5 加载器 soname 符号链接 ----
    # buzz/rex/bo 的 ldso 包只放入 ld-linux.so.1.7.14 / ld.so.1.7.14 实体，
    # soname 链接（ld-linux.so.1 / ld.so.1）由其 postinst 创建，纯解包没有它。
    made_ld_links = []
    libdir = os.path.join(target, "lib")
    if os.path.isdir(libdir):
        for fname in os.listdir(libdir):
            m = re.match(r"^(ld(?:-linux)?\.so)\.([0-9]+)\.[0-9.]+$", fname)
            if not m:
                continue
            link = os.path.join(libdir, "%s.%s" % (m.group(1), m.group(2)))
            if not os.path.lexists(link):
                os.symlink(fname, link)
                made_ld_links.append(os.path.basename(link))
    if made_ld_links:
        lg.emit("  补加载器 soname 链接: %s" % " ".join(made_ld_links))
    # 注意：绝不创建空 /etc/ld.so.cache——ld.so 1.7.x 会 mmap 这个零长度文件，
    # 得到 EINVAL 后不检查返回值直接解引用而段错误。

    # ---- dpkg 数据库：标记所有解包包为 installed ----
    dpkg_dir = os.path.join(target, "var/lib/dpkg/info")
    os.makedirs(dpkg_dir, exist_ok=True)
    status = os.path.join(target, "var/lib/dpkg/status")
    available = os.path.join(target, "var/lib/dpkg/available")
    open(available, "w").close()
    with open(status, "w", encoding="utf-8") as out:
        for name in chosen_pkgs:
            deb = deb_path.get(name)
            ver = arch = ""
            if deb:
                ver = _deb_field(deb, "Version")
                arch = _deb_field(deb, "Architecture") or "i386"
            out.write(
                "Package: %s\nStatus: install ok installed\n"
                "Version: %s\nArchitecture: %s\n\n" % (name, ver, arch)
            )
            open(os.path.join(dpkg_dir, name + ".list"), "w").close()


def _file_contains(path, text):
    try:
        with open(path, "r", errors="replace") as f:
            return text in f.read()
    except OSError:
        return False


def _write_if_absent(path, content):
    if not os.path.exists(path):
        write_file(path, content)


def _deb_field(deb, field):
    r = run(["dpkg-deb", "-f", deb, field])
    return r.stdout.decode(errors="replace").strip() if r.returncode == 0 else ""


# ---------------------------------------------------------------- qemu binfmt
def binfmt_i386_present():
    return os.path.exists(BINFMT_QEMU_I386)


def register_qemu_i386():
    """注册 qemu-i386 的 binfmt_misc（F flag：解释器常驻内存，chroot 内可用）。

    返回 (是否由本函数新注册, 解释器路径)。已存在则不重复注册。
    """
    if binfmt_i386_present():
        return False, None
    qemu = next((p for p in QEMU_I386_CANDIDATES if os.path.exists(p)), None)
    if qemu is None:
        raise RuntimeError("找不到 qemu-i386-static，无法验证 libc5 套件")
    if not os.path.exists(os.path.dirname(BINFMT_REGISTER)):
        run(["mount", "-t", "binfmt_misc", "binfmt_misc",
             "/proc/sys/fs/binfmt_misc"])
    spec = ":qemu-i386:M::%s:%s:%s:F" % (QEMU_I386_MAGIC, QEMU_I386_MASK, qemu)
    with open(BINFMT_REGISTER, "w") as f:
        f.write(spec)
    return True, qemu


def unregister_qemu_i386():
    if binfmt_i386_present():
        try:
            with open(BINFMT_QEMU_I386, "w") as f:
                f.write("-1")
        except OSError:
            pass


# ---------------------------------------------------------------- 执行验证
# 探针列表：优先 /bin/sh（最严格）。rex 的 bash 2.0 链接的 libreadline 与 libc/ncurses
# 挤在 0 地址附近，老 loader 在 qemu 下腾挪失败——此时退而用其他时代二进制证明 rootfs
# 真实可执行；产物内容仍完全来自归档，不受影响。
EXEC_PROBES = [
    ("/bin/sh", ["-c", "echo ANCIENT_ROOTFS_OK; id"]),
    ("/bin/ls", ["/"]),
    ("/bin/gzip", ["--version"]),
]


def chroot_smoke(target, prog, args, timeout=40):
    """chroot 内执行 prog，返回 (通过与否, 输出摘要)。"""
    cmd = ["chroot", target, prog] + args
    try:
        r = run(cmd, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "chroot 超时（疑似交互挂起）"
    out = r.stdout.decode(errors="replace")
    if prog == "/bin/sh":
        ok = r.returncode == 0 and "ANCIENT_ROOTFS_OK" in out and "uid=0" in out
    else:
        ok = r.returncode == 0 and bool(out.strip())
    tail = " | ".join(out.splitlines()[-3:])
    return ok, "rc=%d %s" % (r.returncode, tail[:200])


def verify_execution(target, lg):
    """按探针列表先原生 chroot，全败（libc5 老加载器在现代内核 OOM）则用 qemu 模拟。"""
    probes = [(p, a) for p, a in EXEC_PROBES
              if os.path.exists(os.path.join(target, p.lstrip("/")))]
    if not probes:
        lg.emit("  执行验证失败：rootfs 内没有可用的探针二进制")
        return None
    detail = ""
    for prog, args in probes:
        ok, detail = chroot_smoke(target, prog, args)
        if ok:
            lg.emit("  执行验证（原生 chroot，%s）通过：%s" % (prog, detail))
            return "native"
    lg.emit("  原生 chroot 各探针不通过（%s），注册 qemu-i386 模拟" % detail)
    registered, qemu = register_qemu_i386()
    if qemu:
        lg.emit("  已注册 binfmt_misc -> %s（F flag）" % qemu)
    passed = None
    try:
        for prog, args in probes:
            ok, detail = chroot_smoke(target, prog, args)
            if ok:
                passed = (prog, detail)
                break
    finally:
        if registered:
            # 仅注销本次注册的；开始前就存在的不动
            unregister_qemu_i386()
            lg.emit("  已注销本次注册的 qemu-i386 binfmt")
    if passed:
        prog, detail = passed
        lg.emit("  执行验证（qemu-i386 模拟，%s）通过：%s" % (prog, detail))
        if prog != "/bin/sh":
            lg.emit("  注意：/bin/sh 未能执行（bash 2.0 的 libreadline 链接基址与"
                    "老 loader 在 qemu 下冲突），以 %s 证明 rootfs 可执行" % prog)
        return "qemu"
    lg.emit("  执行验证失败：%s" % detail)
    return None


# ---------------------------------------------------------------- 打包/校验
def package_tar(target, out_tar):
    os.makedirs(os.path.dirname(out_tar), exist_ok=True)
    tmp = out_tar + ".part"
    r = run(["tar", "-C", target, "-czf", tmp, "."], timeout=600)
    if r.returncode != 0:
        if os.path.exists(tmp):
            os.remove(tmp)
        return False
    os.replace(tmp, out_tar)
    return verify_tar(out_tar)


def verify_tar(path):
    """对齐 debian-debootstrap.sh 的产物门：≥1MiB、可列成员、含 etc/、bin/sh。"""
    if not os.path.exists(path) or os.path.getsize(path) < 1 << 20:
        return False
    r = run(["tar", "-tf", path], timeout=120)
    if r.returncode != 0:
        return False
    members = r.stdout.decode(errors="replace").splitlines()
    if not members:
        return False
    joined = "\n".join(members)
    if not re.search(r"(?m)^(\./)?etc/", joined):
        return False
    if re.search(r"(?m)^(\./)?bin/sh$", joined):
        return True
    if not re.search(r"(?m)^(\./)?bin$", joined):
        return False
    return bool(re.search(r"(?m)^(\./)?usr/bin/sh$", joined))


# ---------------------------------------------------------------- 单套件构建
def build_suite(suite, arch, lg):
    target = os.path.join(BUILD_ROOT, "%s-%s-rootfs" % (suite, arch))
    if os.path.exists(target):
        shutil.rmtree(target, ignore_errors=False)
    os.makedirs(target, exist_ok=True)

    lg.emit("抓取 %s/%s 索引" % (suite, arch))
    pkgs = fetch_packages(suite, arch, lg)
    if pkgs is None:
        return "noarch", "归档里没有 binary-%s 索引：这个版本只有 i386" % arch

    seeds = sorted(n for n, f in pkgs.items()
                   if f.get("priority", "").lower() == "required")
    lg.emit("required 种子 %d 个" % len(seeds))
    chosen = resolve_closure(pkgs, seeds, lg)
    lg.emit("依赖闭包后共 %d 个包" % len(chosen))

    deb_path = {}
    failed = []
    lg.emit("并行下载 %d 个包（%d 线程，源：%s）"
            % (len(chosen), JOBS, " -> ".join(MIRRORS)))

    def fetch_one(name):
        try:
            return name, download_deb(suite, arch, pkgs[name], lg)
        except Exception as e:  # 单包异常不拖垮整批
            lg.emit("  下载异常: %s %r" % (name, e))
            return name, None

    with ThreadPoolExecutor(max_workers=JOBS) as ex:
        for i, (name, deb) in enumerate(ex.map(fetch_one, chosen), 1):
            if deb:
                deb_path[name] = deb
            else:
                failed.append(name)
            if i % 20 == 0 or i == len(chosen):
                lg.emit("  下载进度 %d/%d" % (i, len(chosen)))
    if failed:
        for name in failed:
            lg.emit("  下载失败: %s (%s)"
                    % (name, pkgs[name].get("filename", "?")))
        return "fail", "下载失败 %d 个: %s" % (
            len(failed), " ".join(failed[:12]))

    # 按闭包顺序解包（纯解包不执行维护脚本，顺序只影响日志可读性）
    for i, name in enumerate(chosen, 1):
        r = run(["dpkg-deb", "-x", deb_path[name], target])
        if r.returncode != 0:
            failed.append(name)
            lg.emit("  [%d/%d] 解包失败: %s %s"
                    % (i, len(chosen), name,
                       r.stdout.decode(errors="replace")[:120]))
    if failed:
        return "fail", "解包失败 %d 个: %s" % (
            len(failed), " ".join(failed[:12]))
    lg.emit("  %d 个包全部解包成功" % len(chosen))

    configure_target(target, suite, chosen, deb_path, lg)

    mode = verify_execution(target, lg)
    if mode is None:
        return "fail", "chroot 执行验证未通过（详见日志）"

    out_tar = os.path.join(OUT_DIR, "deb-%s-%s-rootfs.tar.gz" % (suite, arch))
    if not package_tar(target, out_tar):
        return "fail", "打包或产物校验失败"
    size = os.path.getsize(out_tar)
    lg.emit("产物校验通过：%s（%d 字节，执行验证=%s）"
            % (os.path.basename(out_tar), size, mode))
    return "ok", "%d 个包，%d 字节，执行验证=%s" % (len(chosen), size, mode)


def main():
    if os.geteuid() != 0:
        print("需要 root 权限（chroot/mknod），请用 sudo 运行", file=sys.stderr)
        return 2
    only = os.environ.get("ONLY", "").split()
    arches = os.environ.get("ARCHES", "i386 amd64").split()
    suites = [s for s in SUITES if not only or s in only]
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(BUILD_ROOT, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)

    results = []  # (suite, arch, status, detail)
    log("mirrors: %s (JOBS=%d, FORCE=%s)" % (" -> ".join(MIRRORS), JOBS, "1" if FORCE else "0"))
    for suite in suites:
        for arch in arches:
            log("构建 Debian %s/%s（远古套件独立构建器 → %s）"
                % (suite, arch, MIRRORS[0]))
            log_path = os.path.join(LOG_DIR, "deb-%s-%s.log" % (suite, arch))
            open(log_path, "w").close()
            lg = SuiteLogger(log_path)
            try:
                out_tar = os.path.join(OUT_DIR, "deb-%s-%s-rootfs.tar.gz" % (suite, arch))
                if not FORCE and os.path.exists(out_tar) and verify_tar(out_tar):
                    status = "skip"
                    detail = "existing valid tarball (%d bytes); FORCE=1 to rebuild" % os.path.getsize(out_tar)
                    lg.emit("  " + detail)
                else:
                    status, detail = build_suite(suite, arch, lg)
            except Exception as e:  # 单套件异常不影响其余套件
                status, detail = "fail", "构建异常: %r" % e
                lg.emit("  异常: %r" % e)
            finally:
                lg.close()
            results.append((suite, arch, status, detail))
            if status == "ok":
                log("  ✓ %s/%s 完成：%s" % (suite, arch, detail))
            elif status in ("noarch", "skip"):
                log("  - %s/%s 跳过：%s" % (suite, arch, detail))
            else:
                log("  ✗ %s/%s 失败：%s（日志：%s）"
                    % (suite, arch, detail, log_path))

    ok = [r for r in results if r[2] == "ok"]
    skip = [r for r in results if r[2] in ("noarch", "skip")]
    bad = [r for r in results if r[2] == "fail"]
    log("产物目录：%s（日志：%s）" % (OUT_DIR, LOG_DIR))
    log("成功 %d 个，跳过(无该架构) %d 个，失败 %d 个"
        % (len(ok), sum(1 for r in results if r[2] == "noarch") + sum(1 for r in results if r[2] == "skip"), len(bad)))
    log("skip-existing=%d" % sum(1 for r in results if r[2] == "skip"))
    if bad:
        log("失败清单： %s"
            % " ".join("%s/%s" % (s, a) for s, a, _, _ in bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
