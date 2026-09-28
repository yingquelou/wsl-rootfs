#!/bin/bash
# Ubuntu rootfs 构建脚本（mmdebstrap 版）
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
# 只有构建成功且通过 rootfs 校验的产物才会被复制到 ./ubuntu；
# 失败会逐个汇总，并以非 0 退出码结束。
# 命名与压缩方式与 ubuntu-debootstrap.sh 一致，两者产物可互换。
#
# 适用范围（实测）：
#   * 现代版本（xenial 及以后）用本脚本没问题，例如 noble/amd64 构建成功。
#   * 归档年代很久的版本（trusty 及更早）用 mmdebstrap 基本走不通：mmdebstrap 要驱动
#     目标系统自己的 apt/dpkg，实测 precise 在 apt 安装 essential 时就失败
#     （Could not configure 'coreutils:amd64'），warty/dapper 更早的版本连 apt 都拒绝
#     （DSA/SHA1 签名、包索引只有 MD5 摘要，apt 3.x 不给下）。
#     这类版本请用 ubuntu-debootstrap.sh：它带 MD5Sum 校验回退，实测能一直构建到 warty。
#
# 可选环境变量：ONLY="noble trusty" 只构建指定版本；ARCHES="amd64" 只构建指定架构。

set -u

# 别用 . 或 source 运行：本脚本会 cd、会 exit，被 source 时会把你当前 shell 搞乱
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    printf '请不要用 source/. 运行本脚本，请用： bash %s\n' "$0" >&2
    return 1 2>/dev/null || true
    exit 1
fi

prev_dir=$(pwd)

# ---------- 依赖与路径（用绝对路径，避免调用者 PATH 里没有 /usr/sbin 时 command not found）----------
command -v sudo >/dev/null 2>&1 || { printf '缺少 sudo\n' >&2; exit 1; }
MMDEBSTRAP_BIN=$(command -v mmdebstrap 2>/dev/null || true)
if [ -z "$MMDEBSTRAP_BIN" ]; then
    for p in /usr/bin/mmdebstrap /usr/local/bin/mmdebstrap; do
        [ -x "$p" ] && { MMDEBSTRAP_BIN="$p"; break; }
    done
fi
[ -n "$MMDEBSTRAP_BIN" ] || { printf '找不到 mmdebstrap，请先安装：apt-get install mmdebstrap\n' >&2; exit 1; }
for k in /usr/share/keyrings/ubuntu-archive-keyring.gpg /usr/share/keyrings/ubuntu-archive-removed-keys.gpg; do
    [ -s "$k" ] || { printf '缺少 %s，请先安装：apt-get install ubuntu-keyring\n' "$k" >&2; exit 1; }
done

sudo -v

# ---------- 目录准备 ----------
sudo rm -rf ./ubuntu ~/ubuntu
mkdir -p ./ubuntu/logs ~/ubuntu

# ---------- 镜像 ----------
MIRROR="https://mirrors.aliyun.com/ubuntu"
OLD_MIRROR="https://mirrors.aliyun.com/oldubuntu-releases/ubuntu"

# ---------- 归档（EOL）版本相关 ----------
# 归档源的 Release 由已移出 ubuntu-archive-keyring 的密钥签名（Ubuntu bug #1851459：
# 继续用 ubuntu-archive-keyring.gpg 会报 “Release signed by unknown key”），
# 且 Valid-Until 早已过期，所以归档版本要用 removed-keys 密钥环 + 忽略过期时间/过期签名。
# 这两条 apt 配置正是 mmdebstrap(1) 中“为 EOL 发行版创建 tarball”的官方示例。
REMOVED_KEYRING="/usr/share/keyrings/ubuntu-archive-removed-keys.gpg"
GPGV_NOEXPSIG="/usr/libexec/mmdebstrap/gpgvnoexpkeysig"
# --aptopt 的取值会被放进 $opts 做分词，所以这里刻意用“构建目录下的相对文件名”而不是绝对路径：
# mmdebstrap 就是以 ~/ubuntu 为工作目录运行的，相对文件名不含空格/通配符，分词绝对安全。
EOL_APTOPT_NAME="eol-aptopts.conf"
EOL_APTOPT_FILE="${HOME}/ubuntu/${EOL_APTOPT_NAME}"

# dpkg < 1.17.11 的版本（trusty 及更早）在安装 essential 包时会读 /var/lib/dpkg/available，
# 文件不存在就直接失败（本仓库根目录的 trusty.log 就是这个问题：
#   dpkg: error: failed to open package info file `/var/lib/dpkg/available'）。
# 只用 setup-hook 补出这几个文件即可（与官方 jessie-or-older 钩子的 extract00.sh 等价）。
# 实测不要用整个 jessie-or-older 钩子：它的 extract01.sh 会在 mawk 装进去之前就配置 dpkg，
# Ubuntu trusty 的 dpkg.postinst 于是报 “awk: not found” → hook 失败。
OLD_DPKG_SUITES=" warty hoary breezy dapper edgy feisty gutsy hardy intrepid jaunty karmic lucid maverick natty oneiric precise quantal raring saucy trusty "
OLD_DPKG_SETUP_NAME="old-dpkg-setup.sh"
OLD_DPKG_SETUP_FILE="${HOME}/ubuntu/${OLD_DPKG_SETUP_NAME}"

# 主线镜像仍在提供的版本（trusty/xenial 也还在主线；plucky/questing 虽已 EOL，但尚未归档）
release="trusty xenial bionic focal jammy noble plucky questing resolute"

# 只存在于 oldubuntu-releases 的版本。
# 仓库目录名区分大小写，必须全小写：原来写的 Warty/Hoary/... 会去取
# dists/Warty/Release，在镜像上必然 404，全部旧版本因此一个都构建不出来。
old_release="warty hoary breezy dapper edgy feisty gutsy hardy intrepid jaunty karmic lucid maverick natty oneiric precise quantal raring saucy utopic vivid wily yakkety zesty artful cosmic disco eoan groovy hirsute impish kinetic lunar mantic oracular"

# ---------- 可选：只构建部分版本/架构（便于分步验证） ----------
# 用法示例：ONLY="noble trusty precise" ARCHES="amd64" bash ubuntu-mmdebstrap.sh
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

# 归档版本用的 apt 配置。写成文件后通过 --aptopt=<file> 传给 mmdebstrap：
# 文件内容会被原样写进 chroot 的 /etc/apt/apt.conf.d/99mmdebstrap。
# 其中 AllowInsecureRepositories / AllowWeakRepositories 是给最老那批版本用的：
# 它们的 Release 用 DSA/SHA1 签名、包索引只有 MD5 摘要，apt 3.x 默认直接拒绝
# （实测 warty/dapper 报 “untrusted digest algorithm: SHA1”“untrusted public key
#   algorithm: dsa1024”，以及 “Insufficient information available to perform this
#   download securely”）。这两个开关只让 apt 在“弱校验”时继续，不关闭其它校验。
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

needs_old_dpkg_hook() {
    case "$OLD_DPKG_SUITES" in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# 给 dpkg < 1.17.11 的版本补 /var/lib/dpkg/{available,diversions,cmethopt}。
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

# 产物校验：必须是像样的 rootfs，而不是“空目录打出来的空 tar.gz”。
# 判定条件：≥1MiB、能列出成员、有 ./etc/、并且 /bin/sh 可用
# （要么 ./bin/sh 存在，要么 ./bin 是指向 usr/bin 的符号链接且有 ./usr/bin/sh）。
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
    sudo "$MMDEBSTRAP_BIN" $opts \
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
    # 千万不能把 man 页整片删掉：实测（Debian buster 的 dash、jessie 的 systemd/bash 同理）
    # postinst 里的 update-alternatives 会因为引用的手册页被删而报
    # “alternative path .../man7/... doesn't exist”，整个包安装失败。所以保留 man[1-9] 真实页面，
    # 只丢翻译等派生目录；版权与 changelog 也按惯例保留（法律合规）。
    # 想连手册页一起删，只能像 ubuntu-debootstrap.sh 那样在“装完之后”用 tar -X 过滤。
}

# build_suite <suite> <arch> <mirror> <eol:0|1>
build_suite() {
    local suite=$1 arch=$2 mirror=$3 eol=$4
    local out="ubuntu-${suite}-${arch}-rootfs.tar.gz"
    local dest="${prev_dir}/ubuntu/${out}"
    local logfile="${prev_dir}/ubuntu/logs/${suite}-${arch}.log"
    local opts="" rc=1

    if [ "$eol" = 1 ]; then
        # 归档源的 Release 由不同年代的密钥签名：已退役的（removed-keys）和仍在用的都可能用到，
        # 单个密钥环不一定够。mmdebstrap 的 --keyring 接受目录（等价于设置 Dir::Etc::TrustedParts），
        # 所以直接把 /usr/share/keyrings 交给它，既覆盖两种密钥，又不必退化成不校验签名。
        if [ -d /usr/share/keyrings ]; then
            opts="$opts --keyring=/usr/share/keyrings"
        elif [ -f "$REMOVED_KEYRING" ]; then
            opts="$opts --keyring=$REMOVED_KEYRING"
        else
            warn "找不到可用密钥环：$suite 只能靠 [trusted=yes] 兜底"
        fi
        if [ -f "$EOL_APTOPT_FILE" ]; then
            opts="$opts --aptopt=$EOL_APTOPT_NAME"
        fi
        # 古老版本把 ca-certificates 放在 universe，只开 main 会 “Unable to locate package”
        opts="$opts --components=main,universe"
    fi

    if needs_old_dpkg_hook "$suite"; then
        if [ -x "$OLD_DPKG_SETUP_FILE" ]; then
            opts="$opts --setup-hook=./$OLD_DPKG_SETUP_NAME"
        else
            warn "缺少 $OLD_DPKG_SETUP_FILE：$suite 可能在安装 essential 包时失败"
        fi
    fi

    sudo rm -f "$out"
    log "构建 Ubuntu $suite/$arch（mmdebstrap → $mirror）"

    if run_mmdebstrap "$opts" "$arch" "$logfile" "$suite" "$out" "$mirror"; then
        rc=0
    elif [ "$eol" = 1 ]; then
        # 兜底：两个密钥环里的密钥都验证不了（密钥已彻底不存在）时，
        # 退化成不做签名校验的 apt 单行源（等价于 debootstrap 的 --no-check-sig）；
        # main+universe 保证仍能装上 curl/ca-certificates。
        log "  $suite/$arch 首次失败，改用 [trusted=yes] 源重试（跳过签名校验）"
        [ -f "$logfile" ] && cp -f "$logfile" "${logfile%.log}.attempt1.log"
        sudo rm -f "$out"
        if run_mmdebstrap "$opts" "$arch" "$logfile" "$suite" "$out" \
                "deb [trusted=yes] $mirror $suite main universe"; then
            rc=0
        fi
    fi

    if [ "$rc" = 0 ] && verify_rootfs_tar "$out" && cp -f "$out" "${prev_dir}/ubuntu/"; then
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

write_eol_aptopts
write_old_dpkg_setup

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
