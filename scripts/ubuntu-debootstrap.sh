#!/bin/bash
# Ubuntu rootfs 构建脚本（debootstrap 版）
#
# Ubuntu 26.04.1 LTS (Resolute Raccoon)   resolute
# Ubuntu 25.10          (Questing Quokka) questing
# Ubuntu 25.04          (Plucky Puffin)   plucky
# Ubuntu 24.04.x LTS    (Noble Numbat)    noble
# Ubuntu 22.04.x LTS    (Jammy Jellyfish) jammy
# Ubuntu 20.04.x LTS    (Focal Fossa)     focal
# Ubuntu 18.04.x LTS    (Bionic Beaver)   bionic
# Ubuntu 16.04.x LTS    (Xenial Xerus)    xenial
# Ubuntu 14.04.x LTS    (Trusty Tahr)     trusty
# 14.10 及更早的版本只在归档镜像 oldubuntu-releases 里（见 old_release）
#
# 产物：./ubuntu/ubuntu-<suite>-<arch>-rootfs.tar.gz
# 日志：./ubuntu/logs/<suite>-<arch>.log
# 只有 debootstrap 成功、且目标目录确实是完整 rootfs 时才打包并复制产物：
# debootstrap 失败时会留下一个空（或半成品）目录，tar 照样能成功，
# 于是产生“104 字节、只有 ./ 一个成员”的假产物——这是本次检查在 ./ubuntu 里
# 看到的 74 个旧版本产物全部为空的直接原因，现在由 has_rootfs/verify_rootfs_tar 拦住。
# 产物命名与压缩方式与 ubuntu-mmdebstrap.sh 一致，两者产物可互换。
#
# 几个老版本的特殊处理（都是实测出来的，脚本会自动判断，不需要手工干预）：
#   * warty…feisty：debootstrap 的套件脚本没声明 minbase，自动去掉 --variant，
#     退回默认 variant（required+important，包更多、产物更大，warty 约 50MB）。
#   * warty/hoary：Release 只有 MD5Sum/SHA1 段，debootstrap 按 SHA256 段找不到
#     索引（实测 hoary/amd64 首试报 no entry for main/binary-amd64/Packages），
#     自动改用一份“强制 MD5Sum 校验”的 debootstrap 副本（放在构建目录里，不动
#     系统文件）重试；edgy 的 Release 已带 SHA256 段，不需要这个兜底。
#   * plucky/amd64：librtmp1 依赖 t64 改名前的旧包名（只以 Provides 存在），
#     自动把 t64 提供者加进 --include。
#   * warty/hoary 的 i386：2004/2005 年的老 glibc 在当前内核上会 ld.so 断言失败
#     （_dl_sysinfo_dso；setarch -L/-R/-3 都没用；实测 edgy/i386 无此问题，不需要
#     模拟），脚本会自动注册 qemu-i386 的 binfmt
#     处理器、用用户态模拟重试，做完再撤掉。解释器按
#     /usr/libexec/qemu-binfmt/i386-binfmt-P → /usr/bin/qemu-i386-static → /usr/bin/qemu-i386
#     顺序取用；实测 warty/hoary i386 用静态版 /usr/bin/qemu-i386-static 构建成功，
#     而发行版 qemu-user-binfmt 的动态 qemu-i386 在真实构建中段会段错误，建议用静态版。
#     注意：注册期间所有 i386 程序都走模拟（慢一些），脚本用完即撤。
#   * 2026-10 实测补齐 hoary/amd64、edgy i386/amd64 后，44 suites × i386/amd64
#     共 88 个组合全部可构建。
#
# 可选环境变量：ONLY="warty plucky" 只构建指定版本；ARCHES="amd64" 只构建指定架构。

set -u

# 别用 . 或 source 运行：本脚本会 cd、会 exit，被 source 时会把你当前 shell 搞乱
# （曾经就是被 source 运行，导致每条 sudo debootstrap 都瞬间失败）
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    printf '请不要用 source/. 运行本脚本，请用： bash %s\n' "$0" >&2
    return 1 2>/dev/null || true
    exit 1
fi

prev_dir=$(pwd)

# ---------- 依赖与路径（用绝对路径，避免调用者 PATH 里没有 /usr/sbin 时 command not found）----------
command -v sudo >/dev/null 2>&1 || { printf '缺少 sudo\n' >&2; exit 1; }
DEBOOTSTRAP_BIN=$(command -v debootstrap 2>/dev/null || true)
if [ -z "$DEBOOTSTRAP_BIN" ]; then
    for p in /usr/sbin/debootstrap /usr/bin/debootstrap /sbin/debootstrap; do
        [ -x "$p" ] && { DEBOOTSTRAP_BIN="$p"; break; }
    done
fi
[ -n "$DEBOOTSTRAP_BIN" ] || { printf '找不到 debootstrap，请先安装：apt-get install debootstrap\n' >&2; exit 1; }
for k in /usr/share/keyrings/ubuntu-archive-keyring.gpg /usr/share/keyrings/ubuntu-archive-removed-keys.gpg; do
    [ -s "$k" ] || { printf '缺少 %s，请先安装：apt-get install ubuntu-keyring\n' "$k" >&2; exit 1; }
done

sudo -v

# ---------- 目录准备 ----------
sudo rm -rf ./ubuntu ~/ubuntu
mkdir -p ./ubuntu/logs ~/ubuntu
mkdir -p ~/debootstrap-cache

# 说明：debootstrap 没有“第二阶段执行自定义清理脚本”的钩子，下面这个清理脚本
# 目前不会被自动执行；产物里的文档/语言包清理是靠 tar -X exclude.txt 完成的。
sudo cp -f ./debootstrap-cleanup.sh "${HOME}"
sudo chmod +x "${HOME}/debootstrap-cleanup.sh"

# ---------- 镜像与密钥环 ----------
MIRROR="https://mirrors.aliyun.com/ubuntu"
OLD_MIRROR="https://mirrors.aliyun.com/oldubuntu-releases/ubuntu"
KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
# EOL 版本的 Release 由已移出 ubuntu-archive-keyring 的密钥签名，
# 继续用 ubuntu-archive-keyring.gpg 会报 “Release signed by unknown key”
# （Ubuntu bug #1851459：precise 的签名密钥 40976EAF437D05B5 自 ubuntu-keyring
#   >= 2016.10.27 起被移入 removed-keys，必须显式 --keyring 指定）。
REMOVED_KEYRING="/usr/share/keyrings/ubuntu-archive-removed-keys.gpg"
CACHE_DIR="${HOME}/debootstrap-cache"

# 主线镜像仍在提供的版本（trusty/xenial 也还在主线；plucky/questing 虽已 EOL，但尚未归档）
release="trusty xenial bionic focal jammy noble plucky questing resolute"

# 只存在于 oldubuntu-releases 的版本。
old_release="warty hoary breezy dapper edgy feisty gutsy hardy intrepid jaunty karmic lucid maverick natty \
oneiric precise quantal raring saucy utopic vivid wily yakkety zesty artful cosmic disco eoan groovy hirsute \
impish kinetic lunar mantic oracular"

# ---------- 可选：只构建部分版本/架构（便于分步验证） ----------
# 用法示例：ONLY="noble trusty precise" ARCHES="amd64" bash ubuntu-debootstrap.sh
only="${ONLY:-}"
arches="${ARCHES:-i386 amd64}"

want_suite() {
    [ -z "$only" ] && return 0
    case " $only " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# ---------- 统计 ----------
ok_count=0
fail_count=0
failed_list=""

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# 目标目录是否是一个可用的 rootfs（debootstrap 失败时会留下空目录）
has_rootfs() {
    local d=$1
    [ -d "$d" ] || return 1
    [ -f "$d/etc/debian_version" ] || return 1
    if [ -x "$d/bin/sh" ] || [ -x "$d/usr/bin/sh" ]; then
        return 0
    fi
    return 1
}

# 产物校验：≥1MiB、能列出成员、有 ./etc/、并且 /bin/sh 可用
# （要么 ./bin/sh 存在，要么 ./bin 是指向 usr/bin 的符号链接且有 ./usr/bin/sh）。
# 后者可以拦住“强行 --merged-usr 把 trusty 打成 /bin 空目录”这类坏 rootfs。
verify_rootfs_tar() {
    local f=$1 list
    [ -f "$f" ] || return 1
    [ "$(wc -c < "$f")" -ge 1048576 ] || return 1
    list=$(tar -tf "$f" 2>/dev/null) || return 1
    [ -n "$list" ] || return 1
    printf '%s\n' "$list" | grep -qE '^(\./)?etc/' || return 1
    if printf '%s\n' "$list" | grep -qE '^(\./)?bin/sh$'; then
        return 0
    fi
    printf '%s\n' "$list" | grep -qE '^(\./)?bin$' || return 1
    printf '%s\n' "$list" | grep -qE '^(\./)?usr/bin/sh$' || return 1
    return 0
}

# debootstrap 的套件脚本用 “variants ...” 声明自己支持哪些 variant。
# warty…feisty 的脚本没有这一行（只支持默认 variant），传 --variant=minbase 会立刻
# 报 “unsupported variant”（实测），所以先探测；探测不到就退回默认 variant。
supports_minbase() {
    local script="/usr/share/debootstrap/scripts/$1"
    [ -r "$script" ] || return 1
    grep -qE '^[[:space:]]*variants[[:space:]].*minbase' "$script" 2>/dev/null || return 1
    return 0
}

# debootstrap 的依赖解析只看包名、不认 Provides。plucky/amd64 的 librtmp1 依赖的是
# t64 改名前的旧名字（libgnutls30 / libhogweed6 / libnettle8），而这些名字在 plucky 里
# 只以 t64 包的“带版本 Provides”形式存在（如 libgnutls30t64 Provides: libgnutls30 (= 3.8.9-2ubuntu3)），
# debootstrap 于是不会把它们装上，dpkg 在 configure 阶段报 “Package libgnutls30 is not installed”，
# 连锁导致 libcurl4t64 与 curl 无法配置（实测 inner 日志）。显式把提供者加进 --include 即可。
# 其它版本没有这些包名，所以按套件区分，避免给老版本塞不存在的包。
extra_includes_for() {
    case "$1" in
        plucky) printf '%s' ",libgnutls30t64,libhogweed6t64,libnettle8t64" ;;
        *)      printf '%s' "" ;;
    esac
}

# 生成一份“强制用 MD5Sum 段校验”的 debootstrap 副本，返回路径。
# 背景：warty…edgy（2004–2006）的 Release 只有 MD5Sum/SHA1 两段。debootstrap 1.0.1xx 在
# /usr/sbin/debootstrap:627 无条件把 DEBOOTSTRAP_CHECKSUM_FIELD 设成 “SHA$SHA_SIZE”（环境变量
# 会被覆盖），随后 get_release_checksum 只在 SHA 段里找条目，于是报
# “Invalid Release file, no entry for main/binary-*/Packages”。debootstrap 自己留着
# force_md5()（functions:304）但在这条路径上不会被调用，所以只能改这一行的副本。
# 副本放在构建目录里，不动系统文件；它仍然使用 /usr/share/debootstrap 下的官方套件脚本。
make_md5_debootstrap() {
    local src dst
    src="$DEBOOTSTRAP_BIN"
    dst="${HOME}/ubuntu/debootstrap-md5"
    sed 's/^DEBOOTSTRAP_CHECKSUM_FIELD=.*/DEBOOTSTRAP_CHECKSUM_FIELD="MD5SUM"/' "$src" > "$dst" || return 1
    chmod 0755 "$dst" || return 1
    grep -q 'DEBOOTSTRAP_CHECKSUM_FIELD="MD5SUM"' "$dst" || return 1
    printf '%s\n' "$dst"
}

# 清理目标目录：老套件脚本或 qemu 模拟进程会把 /dev、/proc、/sys 留在目标目录里挂着，
# 直接 rm 会刷出一大堆 “Operation not permitted”（曾把整段日志淹没）。先杀掉残留的
# qemu、递归卸载（必要时强卸），最后安静地删。
clean_target() {
    sudo pkill -f 'qemu-i386' >/dev/null 2>&1 || true
    sudo umount -R "$1" >/dev/null 2>&1 || true
    sudo umount -l -R "$1" >/dev/null 2>&1 || true
    sudo rm -rf "$1" >/dev/null 2>&1 || true
    if [ -d "$1" ]; then
        sudo umount -f -R "$1" >/dev/null 2>&1 || true
        sudo rm -rf "$1" >/dev/null 2>&1 || true
    fi
    return 0
}

# 一次 debootstrap 尝试：
# debootstrap_try <suite> <dir> <mirror> <arch> <includes> <dbbin> <extra> <sig_opts> <variant_opts> <log>
# <dbbin> 为空时用系统 debootstrap，否则用给定的副本（MD5 回退用）。
debootstrap_try() {
    local suite=$1 dir=$2 mirror=$3 arch=$4 includes=$5 dbbin=$6 extra=$7 sig_opts=$8 variant_opts=$9
    local logfile=${10}
    [ -n "$dbbin" ] || dbbin="$DEBOOTSTRAP_BIN"
    # 下面 $variant_opts / $sig_opts / $extra 需要按空格拆开（内容都不含空格与通配符）
    # shellcheck disable=SC2086
    sudo "$dbbin" $variant_opts --include="$includes" \
        --arch="$arch" --cache-dir="$CACHE_DIR" \
        $sig_opts $extra \
        "$suite" "$dir" "$mirror" >>"$logfile" 2>&1
}

# 老的 i386 glibc（warty/hoary 那批，2004–2005）在现代内核上跑目标系统的 dpkg 时会崩：
#   Inconsistency detected by ld.so: rtld.c: 1192: dl_main: Assertion
#   `(void *) ph->p_vaddr == _rtld_local._dl_sysinfo_dso' failed!
# setarch -L/-R/-3 都没用（实测各 10/10 仍失败）；用 qemu 的 binfmt 用户态模拟则 10/10 成功。
# 这里提供按需启用/关闭：只在需要时注册处理器，做完这个套件就撤掉，避免影响别的 i386 构建。
BINFMT_QEMU_I386="/proc/sys/fs/binfmt_misc/qemu-i386"

qemu_i386_binary() {
    local b
    for b in /usr/libexec/qemu-binfmt/i386-binfmt-P /usr/bin/qemu-i386-static /usr/bin/qemu-i386; do
        [ -x "$b" ] && { printf '%s\n' "$b"; return 0; }
    done
    return 1
}

enable_binfmt_qemu_i386() {
    [ -f "$BINFMT_QEMU_I386" ] && return 0
    local bin
    bin=$(qemu_i386_binary) || return 1
    [ -w /proc/sys/fs/binfmt_misc/register ] || return 1
    # binfmt_misc 的 register 用 \xNN 转义，由内核解析，所以这里必须是字面量
    printf '%s' ':qemu-i386:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:'"$bin"':CF' \
        | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 || return 1
    [ -f "$BINFMT_QEMU_I386" ]
}

disable_binfmt_qemu_i386() {
    [ -f "$BINFMT_QEMU_I386" ] || return 0
    printf '%s' '-1' | sudo tee "$BINFMT_QEMU_I386" >/dev/null 2>&1 || true
}

# 失败后给出结论
explain_failure() {
    local dir=$1 arch=$2 rel
    if [ -f "$dir/debootstrap/debootstrap.log" ] \
            && grep -q 'Inconsistency detected by ld.so' "$dir/debootstrap/debootstrap.log" 2>/dev/null; then
        printf '%s\n' "老 i386 glibc 在当前内核上 ld.so 断言失败（_dl_sysinfo_dso）；装 qemu-user-binfmt 后脚本会自动启用模拟"
        return 0
    fi
    rel=$(find "$dir" -maxdepth 6 -type f -name '*Release' 2>/dev/null | head -n 1)
    if [ -n "$rel" ] && ! grep -q "binary-$arch/Packages\$" "$rel" 2>/dev/null; then
        printf '%s\n' "Release 里没有 binary-$arch 索引：该版本归档没有 $arch 架构"
        return 0
    fi
    if [ -n "$rel" ] && ! grep -q '^SHA256:' "$rel" 2>/dev/null; then
        printf '%s\n' "Release 只有 MD5Sum/SHA1 段（已用强制 MD5Sum 的副本重试过）"
        return 0
    fi
    printf '%s\n' "详见日志（$dir/../logs 与 inner 日志）"
}

# build_suite <suite> <arch> <mirror> <eol:0|1>
build_suite() {
    local suite=$1 arch=$2 mirror=$3 eol=$4
    local dir="ubuntu-${suite}-${arch}-rootfs"
    local out="ubuntu-${suite}-${arch}-rootfs.tar.gz"
    local dest="${prev_dir}/ubuntu/${out}"
    local logfile="${prev_dir}/ubuntu/logs/${suite}-${arch}.log"
    local sig_opts="" extra="" candidates="" variant_opts="" last_try="" rc=1 stop_retry=0
    local includes="ca-certificates,curl$(extra_includes_for "$suite")"
    local dbbin=""
    local qemu_tried=0

    if [ "$eol" = 1 ]; then
        # 归档源的 Release 可能由不同年代的密钥签名，依次尝试（候选项之间用空格分隔，各自不含空格）：
        #   1) ubuntu-archive-removed-keys.gpg：已退役的归档密钥
        #      （Ubuntu bug #1851459：precise 的 40976EAF437D05B5 就在这个密钥环里）
        #   2) ubuntu-archive-keyring.gpg：仍在使用的归档密钥
        #   3) --no-check-sig：密钥彻底缺失时兜底（等价于 mmdebstrap 版的 [trusted=yes]）
        candidates="--keyring=$REMOVED_KEYRING --keyring=$KEYRING --no-check-sig"
        # 古老版本把 ca-certificates 放在 universe，只开 main 会 “Couldn't find these debs”
        extra="--components=main,universe"
    else
        candidates="--keyring=$KEYRING"
    fi

    variant_opts="--variant=minbase"
    if ! supports_minbase "$suite"; then
        log "  注：$suite 的 debootstrap 脚本没有 minbase，改用默认 variant（required+important）"
        variant_opts=""
    fi

    clean_target "$dir"
    sudo rm -f "$out"
    log "构建 Ubuntu $suite/$arch（debootstrap → $mirror）"

    # 不强制 --merged-usr：debootstrap 会按套件自己选择（focal 及以后默认合并 /usr，
    # bionic/xenial/trusty 保持上游的非合并布局）。强行 --merged-usr 会把 trusty 打成
    # “/bin 是真实目录、里面没有 sh/bash，只有 /usr/bin/sh”的坏 rootfs。
    #
    # 重试策略：每次都把输出单独收进 $last_try，再按失败原因决定要不要换参数——
    # 只有“签名相关”“unsupported variant”“Release 只有 MD5 摘要”才值得换
    # （这些都在下载前就失败，代价极小），其它失败（例如某个包 configure 失败）直接放弃，
    # 避免把上十分钟的构建重复好几遍。
    for sig_opts in $candidates; do
        while :; do
            last_try="${logfile%.log}.lasttry"
            : > "$last_try"

            if debootstrap_try "$suite" "$dir" "$mirror" "$arch" "$includes" "$dbbin" "$extra" \
                    "$sig_opts" "$variant_opts" "$last_try"; then
                cat "$last_try" >>"$logfile"
                rc=0
                break
            fi
            cat "$last_try" >>"$logfile"

            if [ -n "$variant_opts" ] && grep -q 'unsupported variant' "$last_try" 2>/dev/null; then
                log "  $suite/$arch 报 unsupported variant，去掉 --variant 再试一次"
                variant_opts=""
                clean_target "$dir"
                continue
            fi
            if [ "$eol" = 1 ] && grep -qE 'signed by unknown key|NO_PUBKEY|is not signed|Can.t check signature|signature verification failed' "$last_try" 2>/dev/null; then
                log "  $suite/$arch 签名校验失败，换下一个密钥环候选"
                break
            fi
            if [ -z "$dbbin" ] && grep -q 'Invalid Release file, no entry for' "$last_try" 2>/dev/null; then
                # 只有 MD5Sum/SHA1 段的 Release：用“强制 MD5Sum”的 debootstrap 副本重试
                if dbbin=$(make_md5_debootstrap); then
                    log "  $suite/$arch：Release 只有 MD5Sum/SHA1 摘要，改用强制 MD5Sum 校验的 debootstrap 副本重试"
                    clean_target "$dir"
                    continue
                else
                    log "  无法生成 MD5 校验的 debootstrap 副本"
                    dbbin=""
                fi
            fi
            if grep -q 'Invalid Release file, no entry for' "$last_try" 2>/dev/null; then
                log "  已用 MD5Sum 校验重试仍然失败，这个版本在当前工具链下无法构建"
            fi
            if [ "$qemu_tried" = 0 ] && grep -q 'Inconsistency detected by ld.so' "$dir/debootstrap/debootstrap.log" 2>/dev/null; then
                # warty/hoary 老 i386 glibc 的 ld.so 断言：用 qemu 用户态模拟绕过
                qemu_tried=1
                if enable_binfmt_qemu_i386; then
                    log "  $suite/$arch：老 i386 glibc 的 ld.so 断言 → 已启用 qemu-i386 模拟重试"
                    clean_target "$dir"
                    continue
                fi
                log "  $suite/$arch：老 i386 glibc 的 ld.so 断言（当前内核不兼容）"
                log "  → 先安装 qemu 再重试：apt-get install qemu-user-binfmt"
            fi
            log "  $suite/$arch 失败：$(explain_failure "$dir" "$arch")"
            stop_retry=1
            break
        done

        [ "$rc" = 0 ] && break
        [ "$stop_retry" = 1 ] && break
        clean_target "$dir"
    done

    # qemu 处理器只在这个套件需要时临时启用，用完撤掉，别影响别的 i386 构建
    [ "$qemu_tried" = 1 ] && disable_binfmt_qemu_i386

    # 只有目录确实是完整 rootfs 才打包（tar 自己不会因为目录是空的而失败）
    if [ "$rc" = 0 ] && has_rootfs "$dir"; then
        if sudo tar c -zf "$out" -X exclude.txt -C "$dir" . >>"$logfile" 2>&1 \
                && verify_rootfs_tar "$out" \
                && cp -f "$out" "${prev_dir}/ubuntu/"; then
            rc=0
        else
            rc=1
        fi
    else
        rc=1
    fi

    # 失败时把目标里 debootstrap 自己的日志留存下来（里面才有 postinst/configure 的真实报错）
    if [ "$rc" != 0 ] && [ -f "$dir/debootstrap/debootstrap.log" ]; then
        cp -f "$dir/debootstrap/debootstrap.log" \
            "${prev_dir}/ubuntu/logs/${suite}-${arch}.inner.log" 2>/dev/null || true
    fi

    clean_target "$dir"

    if [ "$rc" = 0 ] && [ -f "$dest" ]; then
        log "✓ $suite/$arch 完成：$out（$(wc -c < "$dest") 字节）"
        ok_count=$((ok_count + 1))
        return 0
    fi

    rm -f "$dest" 2>/dev/null || true
    sudo rm -f "$out"
    warn "✗ $suite/$arch 失败（日志：$logfile）"
    fail_count=$((fail_count + 1))
    failed_list="$failed_list $suite/$arch"
    return 1
}

pushd ~/ubuntu >/dev/null || exit 1

cat > exclude.txt <<'EOF'
# APT 缓存与包列表
var/cache/apt/archives/*
var/lib/apt/lists/*
var/cache/debconf/*

# 文档与手册
usr/share/doc/*
usr/share/man/*
usr/share/info/*
usr/share/groff/*

# 本地化
usr/share/locale/*
usr/share/i18n/locales/*

# 日志与临时文件
var/log/*
tmp/*
var/tmp/*
run/*

# 可复现性文件
etc/machine-id
var/lib/dbus/machine-id
var/cache/ldconfig/aux-cache
EOF

for suite in ${release}; do
    want_suite "$suite" || continue
    for arch in ${arches}; do
        build_suite "$suite" "$arch" "$MIRROR" 0
    done
done

for suite in ${old_release}; do
    want_suite "$suite" || continue
    for arch in ${arches}; do
        build_suite "$suite" "$arch" "$OLD_MIRROR" 1
    done
done

popd >/dev/null || true

log "产物目录：${prev_dir}/ubuntu（日志：${prev_dir}/ubuntu/logs）"
log "成功 $ok_count 个，失败 $fail_count 个"
if [ -n "$failed_list" ]; then
    log "失败清单：$failed_list"
fi

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
