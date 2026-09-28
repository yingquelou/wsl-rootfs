#!/bin/bash
# Debian rootfs 构建脚本（mmdebstrap 版）
#
# 主线镜像 https://deb.debian.org/debian：
#   trixie     13  stable
#   bookworm   12  oldstable
#   bullseye   11  oldoldstable
#   （需要 forky(14/testing) 或 sid 时，把它们加进下面的 release 列表即可）
# 归档镜像 https://archive.debian.org/debian：
#   buster stretch jessie（实测：buster 34.8MB、jessie 38.3MB 都能构建）
# mmdebstrap 依赖目标系统自己的 apt/dpkg，越老的版本越难，以下请改用 debian-debootstrap.sh：
#   * woody / potato：Release 只有 MD5Sum，现代 apt 的“弱摘要”策略直接拒收
#   * wheezy 及更早：mmdebstrap 的一次性 dpkg 安装在这些老 dpkg 上顺序出错
#   * slink hamm bo rex buzz：归档里连 dists/<suite>/Release 都没有，mmdebstrap 无法构建；
#     请改用 debian-debootstrap.sh（它会用打补丁的副本现场合成 Release，实测能构建）
#
# 产物：./debian/debian-<suite>-<arch>-rootfs.tar.gz
# 日志：./debian/logs/<suite>-<arch>.log
# 只有构建成功且通过 rootfs 校验的产物才会被复制到 ./debian；失败逐个汇总并非 0 退出。
# 命名与压缩方式与 debian-debootstrap.sh 一致，两者产物可互换。
#
# 可选环境变量：ONLY="trixie buster" 只构建指定版本；ARCHES="amd64" 只构建指定架构。

set -u

# 别用 . 或 source 运行：本脚本会 cd、会 exit，被 source 时会把你当前 shell 搞乱
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    printf '请不要用 source/. 运行本脚本，请用： bash %s\n' "$0" >&2
    return 1 2>/dev/null || true
    exit 1
fi

prev_dir=$(pwd)

# ---------- 依赖与路径 ----------
command -v sudo >/dev/null 2>&1 || { printf '缺少 sudo\n' >&2; exit 1; }
MMDEBSTRAP_BIN=$(command -v mmdebstrap 2>/dev/null || true)
if [ -z "$MMDEBSTRAP_BIN" ]; then
    for p in /usr/bin/mmdebstrap /usr/local/bin/mmdebstrap; do
        [ -x "$p" ] && { MMDEBSTRAP_BIN="$p"; break; }
    done
fi
[ -n "$MMDEBSTRAP_BIN" ] || { printf '找不到 mmdebstrap，请先安装：apt-get install mmdebstrap\n' >&2; exit 1; }

KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
REMOVED_KEYRING="/usr/share/keyrings/debian-archive-removed-keys.gpg"
if [ ! -s "$KEYRING" ] && [ ! -s "$REMOVED_KEYRING" ]; then
    printf '缺少 Debian 密钥环，请先安装：apt-get install debian-archive-keyring\n' >&2
    exit 1
fi

# ---------- 归档（EOL）版本相关 ----------
GPGV_NOEXPSIG="/usr/libexec/mmdebstrap/gpgvnoexpkeysig"
# --aptopt 的取值会放进 $opts 做分词，所以用构建目录下的相对文件名（不含空格/通配符）
EOL_APTOPT_NAME="eol-aptopts.conf"
EOL_APTOPT_FILE="${HOME}/debian/${EOL_APTOPT_NAME}"

# dpkg < 1.20 的版本（buster 及更早）在安装 essential 包时会读 /var/lib/dpkg/available，
# 也常在 apt 记录选择状态时需要它。用 setup-hook 补出这几个文件就够。
# 实测不要用整个 jessie-or-older 钩子：在 Debian 13 的 mmdebstrap 1.5.7 上，buster 会在它的
# extract01.sh 里因为“dash 的 postinst 在依赖就绪前就被配置”而失败
# （installed dash package post-installation script ... error exit status 1，
#   随后 E: command failed: /usr/share/mmdebstrap/hooks/jessie-or-older/extract01.sh）——
# 和 Ubuntu trusty 踩的是同一个坑。
OLD_DPKG_SUITES=" buster stretch jessie wheezy squeeze lenny etch sarge "
OLD_DPKG_SETUP_NAME="old-dpkg-setup.sh"
OLD_DPKG_SETUP_FILE="${HOME}/debian/${OLD_DPKG_SETUP_NAME}"

# jessie 额外需要官方的 jessie-or-older 钩子：它的 init 1.22 还 pre-depends on systemd-sysv，
# 需要钩子的 extract01.sh 先把 base-passwd/base-files/dpkg 装好再解包其它 essential 包，
# 否则 systemd/systemd-sysv 的 postinst 会在依赖没配好的情况下跑而失败（实测）。
# 更老的版本（wheezy 及以前）反而**不能**用这个钩子：它们的 dpkg < 1.17.11，
# extract01.sh 会在 mawk 解包之前就配置 dpkg，dpkg.postinst 报 “awk: not found” 直接失败
# （Ubuntu trusty 上实测过的同一个坑），所以那些版本只用上面的 setup-hook 补 available 文件。
HOOK_SUITES=" jessie "
OLD_HOOK_DIR="/usr/share/mmdebstrap/hooks/jessie-or-older"

sudo -v

# ---------- 目录准备 ----------
sudo rm -rf ./debian ~/debian
mkdir -p ./debian/logs ~/debian

# ---------- 镜像与版本 ----------
MAIN_MIRROR="https://deb.debian.org/debian"
ARCHIVE_MIRROR="https://archive.debian.org/debian"

# 主线镜像仍在提供的版本
release="trixie bookworm bullseye"

# 只有归档镜像才有的版本；mmdebstrap 实测能走通的：
#   buster（setup-hook，实测 34.8MB）、jessie（官方钩子，实测 38.3MB）、stretch
old_release="buster stretch jessie"

# 归档里连 dists/<suite>/Release 都没有的版本：mmdebstrap 无法构建，这里只报告。
# 它们已由独立构建器 debian-ancient.py 负责（纯解包，不依赖 Release），见该脚本文件头。
dead_release="slink hamm bo rex buzz"

# mmdebstrap 走不通、请改用 debian-debootstrap.sh 的归档版本：
#   * woody/potato：Release 只有 MD5Sum，现代 apt 直接拒收
#   * wheezy 及更早：mmdebstrap 的一次性 dpkg 安装在这些老 dpkg 上顺序出错
#     （实测 wheezy 在 base-files/passwd/login 上失败），debootstrap 更稳
mm_unsupported="woody potato wheezy squeeze lenny etch sarge"

# 需要补 /var/lib/dpkg/available 的归档版本（dpkg < 1.20）：buster 及更早
# （OLD_DPKG_SUITES 在文件开头定义，配合 write_old_dpkg_setup 使用）

# ---------- 可选：只构建部分版本/架构 ----------
only="${ONLY:-}"
arches="${ARCHES:-i386 amd64}"

want_suite() {
    [ -z "$only" ] && return 0
    case " $only " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

needs_old_dpkg_hook() {
    case "$OLD_DPKG_SUITES" in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

needs_jessie_hook() {
    case "$HOOK_SUITES" in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# 给 dpkg < 1.20 的版本补 /var/lib/dpkg/{available,diversions,cmethopt}。
# 通过 --setup-hook=./<名字> 传给 mmdebstrap：setup-hook 会把 chroot 目录作为 $1 传进来。
write_old_dpkg_setup() {
    cat > "$OLD_DPKG_SETUP_FILE" <<'EOS'
#!/bin/sh
set -eu
target=$1
mkdir -p "$target/var/lib/dpkg"
for f in available diversions cmethopt; do
    [ -e "$target/var/lib/dpkg/$f" ] || touch "$target/var/lib/dpkg/$f"
done
EOS
    chmod +x "$OLD_DPKG_SETUP_FILE"
}

# ---------- 统计 ----------
ok_count=0
fail_count=0
failed_list=""
skip_list=""

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# 归档版本用的 apt 配置：忽略过期时间与过期签名；最老那批还要允许弱摘要/未认证包
write_eol_aptopts() {
    {
        echo 'Acquire::Check-Valid-Until "false";'
        echo 'Acquire::AllowInsecureRepositories "true";'
        echo 'Acquire::AllowWeakRepositories "true";'
        echo 'APT::Get::AllowUnauthenticated "true";'
        if [ -x "$GPGV_NOEXPSIG" ]; then
            echo "Apt::Key::gpgvcommand \"$GPGV_NOEXPSIG\";"
        else
            warn "$GPGV_NOEXPSIG 不存在：归档版本的过期签名可能无法通过校验"
        fi
    } > "$EOL_APTOPT_FILE"
}

# 产物校验：≥1MiB、能列出成员、有 ./etc/、并且 /bin/sh 可用
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

# 一次完整的 mmdebstrap 调用：run_mmdebstrap <opts> <arch> <logfile> <suite> <out> <mirror 参数>
run_mmdebstrap() {
    local opts=$1 arch=$2 logfile=$3 suite=$4 out=$5 mirror_arg=$6
    # 这里的 $opts 需要按空格拆开（内容都是不含空格的 --keyring=/--aptopt=/--setup-hook=/--components=）
    # shellcheck disable=SC2086
    # /tmp 在 WSL 里是 tmpfs（大小约为内存一半，本机只有 ~450MB），mmdebstrap 的一次性
    # chroot 放那里会在两个组合并行时写满（No space left on device）→ 改指到磁盘上的 HOME
    # （File::Temp 的 TMPDIR=>1 优先用 $TMPDIR；用 env 前缀保证它以 root 身份生效）。
    sudo env TMPDIR="$HOME" "$MMDEBSTRAP_BIN" $opts \
        --variant=minbase --include=ca-certificates,curl \
        --arch="$arch" --logfile="$logfile" \
        --dpkgopt='path-exclude=/usr/share/man/*' \
        --dpkgopt='path-include=/usr/share/man/man[1-9]/*' \
        --dpkgopt='path-exclude=/usr/share/locale/*' \
        --dpkgopt='path-include=/usr/share/locale/locale.alias' \
        --dpkgopt='path-exclude=/usr/share/doc/*' \
        --dpkgopt='path-include=/usr/share/doc/*/copyright' \
        --dpkgopt='path-include=/usr/share/doc/*/changelog.Debian.*' \
        --dpkgopt='path-exclude=/usr/share/info/*' \
        --dpkgopt='path-exclude=/usr/share/groff/*' \
        --dpkgopt='path-exclude=/usr/share/i18n/locales/*' \
        "$suite" "$out" "$mirror_arg"
    # 说明：这是 mmdebstrap(1) 里那套官方 path-exclude/path-include 组合。
    # 千万不能把 man 页整片删掉：实测 Debian buster 的 dash、jessie 的 systemd/bash 会因为
    # “update-alternatives: error: alternative path .../man7/... doesn't exist”而安装失败
    # （postinst 里 update-alternatives 引用的手册页被删了）。所以保留 man[1-9] 真实页面，
    # 只丢翻译等派生目录；版权与 changelog 也按惯例保留（法律合规）。
    # 想连手册页一起删，只能像 debian-debootstrap.sh 那样在“装完之后”用 tar -X 过滤。
}

# build_suite <suite> <arch> <mirror> <eol:0|1>
build_suite() {
    local suite=$1 arch=$2 mirror=$3 eol=$4
    local out="debian-${suite}-${arch}-rootfs.tar.gz"
    local dest="${prev_dir}/debian/${out}"
    local logfile="${prev_dir}/debian/logs/${suite}-${arch}.log"
    local opts="" rc=1

    if [ "$eol" = 1 ]; then
        # 归档源的 Release 由不同年代的密钥签名：把 /usr/share/keyrings 整个目录交给 apt
        # （mmdebstrap 的 --keyring 接受目录，等价于 Dir::Etc::TrustedParts），
        # 这样“已退役密钥（removed-keys）”和“仍在用的密钥”都在信任库里。
        if [ -d /usr/share/keyrings ]; then
            opts="$opts --keyring=/usr/share/keyrings"
        elif [ -s "$REMOVED_KEYRING" ]; then
            opts="$opts --keyring=$REMOVED_KEYRING"
        else
            warn "找不到可用密钥环：$suite 只能靠 [trusted=yes] 兜底"
        fi
        if [ -f "$EOL_APTOPT_FILE" ]; then
            opts="$opts --aptopt=$EOL_APTOPT_NAME"
        fi
        # 归档版本的 Release 过期，且老套件的索引可能只有弱摘要
        opts="$opts --components=main,contrib,non-free"
    fi

    if needs_old_dpkg_hook "$suite"; then
        if [ -x "$OLD_DPKG_SETUP_FILE" ]; then
            opts="$opts --setup-hook=./$OLD_DPKG_SETUP_NAME"
        else
            warn "缺少 $OLD_DPKG_SETUP_FILE：$suite 可能在安装 essential 包时失败"
        fi
    fi

    if needs_jessie_hook "$suite"; then
        if [ -d "$OLD_HOOK_DIR" ]; then
            opts="$opts --hook-dir=$OLD_HOOK_DIR"
        else
            warn "缺少 $OLD_HOOK_DIR：$suite 可能在配置 init/systemd 时失败"
        fi
    fi

    sudo rm -f "$out"
    log "构建 Debian $suite/$arch（mmdebstrap → $mirror）"

    if run_mmdebstrap "$opts" "$arch" "$logfile" "$suite" "$out" "$mirror"; then
        rc=0
    elif [ "$eol" = 1 ]; then
        # 兜底：密钥彻底缺失时，退化成不做签名校验的 apt 单行源
        # （等价于 debootstrap 的 --no-check-sig）
        log "  $suite/$arch 首次失败，改用 [trusted=yes] 源重试（跳过签名校验）"
        [ -f "$logfile" ] && cp -f "$logfile" "${logfile%.log}.attempt1.log"
        sudo rm -f "$out"
        if run_mmdebstrap "$opts" "$arch" "$logfile" "$suite" "$out" \
                "deb [trusted=yes] $mirror $suite main contrib non-free"; then
            rc=0
        fi
    fi

    if [ "$rc" = 0 ] && verify_rootfs_tar "$out" && cp -f "$out" "${prev_dir}/debian/"; then
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

pushd ~/debian >/dev/null || exit 1

write_eol_aptopts
write_old_dpkg_setup

for suite in ${release}; do
    want_suite "$suite" || continue
    for arch in ${arches}; do
        build_suite "$suite" "$arch" "$MAIN_MIRROR" 0
    done
done

for suite in ${old_release}; do
    want_suite "$suite" || continue
    for arch in ${arches}; do
        build_suite "$suite" "$arch" "$ARCHIVE_MIRROR" 1
    done
done

for suite in ${dead_release}; do
    want_suite "$suite" || continue
    warn "跳过 $suite：归档镜像里没有 dists/$suite/Release（pre-dists 布局），现代工具无法构建"
    skip_list="$skip_list $suite"
done

for suite in ${mm_unsupported}; do
    want_suite "$suite" || continue
    warn "跳过 $suite：mmdebstrap 在这些老版本上会失败（apt/dpkg 太老或索引只有 MD5 摘要），请用 debian-debootstrap.sh"
    skip_list="$skip_list $suite"
done

popd >/dev/null || true

log "产物目录：${prev_dir}/debian（日志：${prev_dir}/debian/logs）"
log "成功 $ok_count 个，失败 $fail_count 个"
if [ -n "$failed_list" ]; then
    log "失败清单：$failed_list"
fi
if [ -n "$skip_list" ]; then
    log "跳过（归档里没有 Release）：$skip_list"
fi

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
