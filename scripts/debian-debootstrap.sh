#!/bin/bash
# Debian rootfs 构建脚本（debootstrap 版）
#
# 主线镜像 https://deb.debian.org/debian：
#   trixie     13  stable
#   bookworm   12  oldstable
#   bullseye   11  oldoldstable
#   （需要 forky(14/testing) 或 sid 时，把它们加进下面的 release 列表即可，同样在主线镜像里）
# 归档镜像 https://archive.debian.org/debian：
#   buster stretch jessie wheezy squeeze lenny etch sarge woody potato
# 远古版本（1996–1999，归档里连 dists/<suite>/Release 都没有）：
#   slink hamm bo rex buzz
#   本脚本不再构建它们。debootstrap 强依赖 Release，过去“合成 Release + 补丁 debootstrap 副本 +
#   两阶段 chroot configure”的嫁接路线被一连串古董维护脚本问题连环卡死且无收敛迹象：
#   exim/smail/timezones 等 postinst 的交互向导（无 tty 下永久挂起）、install-info 加锁、
#   perl.dist 改名、passwd/group 顺序、buzz/rex/bo 的 libc5 在现代内核直接 Out of virtual memory。
#   这五个套件改由独立构建器 debian-ancient.py 负责：直接抓 Packages.gz、按 required 依赖闭包
#   纯解包（不执行任何维护脚本，所以上述问题全部不存在）、静态补齐系统配置、先原生 chroot 再
#   自动回退 qemu-i386 做执行验证后打包。用法：sudo python3 debian-ancient.py
#   它们只有 i386；amd64 由该构建器明确报告“归档里没有该架构”并跳过。
#
# 产物：./debian/debian-<suite>-<arch>-rootfs.tar.gz
# 日志：./debian/logs/<suite>-<arch>.log
# 只有 debootstrap 成功、且目标目录确实是完整 rootfs 时才打包并复制产物：
# debootstrap 失败后会留下一个空目录，tar 照样能成功，于是产生“只有 ./ 一个成员”的假产物
# （ubuntu 版就是这么发现 74 个空产物的），这里由 has_rootfs/verify_rootfs_tar 拦住。
# 产物命名与压缩方式与 debian-mmdebstrap.sh 一致，两者产物可互换。
#
# 几个老版本的特殊处理（都在失败后按日志自动判断，不需要手工干预）：
#   * sarge/woody/potato：debootstrap 套件脚本没有 minbase → 自动去掉 --variant，退回默认 variant
#   * woody/potato：Release 只有 MD5Sum 段 → 自动改用一份“强制 MD5Sum 校验”的 debootstrap 副本
#   * potato：归档里没有 ca-certificates（woody 起才有）→ 按 “Couldn't find these debs”
#     日志自动把 --include 里不存在的包剔除后重试
#   * woody/potato/sarge：归档里没有 amd64（只有 i386）→ 会明确报“Release 里没有该架构的索引”
#   * 其余归档版本：按 removed-keys → archive-keyring → --no-check-sig 依次尝试签名校验
#   * 极老版本的 i386（老 glibc 在当前内核上 ld.so 断言失败，_dl_sysinfo_dso）：
#     脚本会自动注册 qemu-i386 的 binfmt 处理器、用用户态模拟重试，做完再撤掉。
#     解释器按 /usr/libexec/qemu-binfmt/i386-binfmt-P → /usr/bin/qemu-i386-static → /usr/bin/qemu-i386
#     顺序取用，建议用静态版 /usr/bin/qemu-i386-static（动态 qemu 在真实构建中段会段错误）。
#     实测：Debian 全矩阵（含 potato i386）未触发该断言，此机制为兜底保留。
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

# ---------- 依赖与路径（用绝对路径，避免 PATH 里没有 /usr/sbin 时“command not found”）----------
command -v sudo >/dev/null 2>&1 || { printf '缺少 sudo\n' >&2; exit 1; }
DEBOOTSTRAP_BIN=$(command -v debootstrap 2>/dev/null || true)
if [ -z "$DEBOOTSTRAP_BIN" ]; then
    for p in /usr/sbin/debootstrap /usr/bin/debootstrap /sbin/debootstrap; do
        [ -x "$p" ] && { DEBOOTSTRAP_BIN="$p"; break; }
    done
fi
[ -n "$DEBOOTSTRAP_BIN" ] || { printf '找不到 debootstrap，请先安装：apt-get install debootstrap\n' >&2; exit 1; }

KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
REMOVED_KEYRING="/usr/share/keyrings/debian-archive-removed-keys.gpg"
if [ ! -s "$KEYRING" ] && [ ! -s "$REMOVED_KEYRING" ]; then
    printf '缺少 Debian 密钥环，请先安装：apt-get install debian-archive-keyring\n' >&2
    exit 1
fi

sudo -v

# ---------- 目录准备 ----------
sudo rm -rf ./debian ~/debian
mkdir -p ./debian/logs ~/debian
# 注意：用独立的缓存目录，别和 ubuntu 版共用（同名 .deb 可能来自不同发行版）
CACHE_DIR="${HOME}/debootstrap-cache-debian"
mkdir -p "$CACHE_DIR"

# 说明：debootstrap 没有“第二阶段执行自定义清理脚本”的钩子，下面这个清理脚本
# 目前不会被自动执行；产物里的文档/语言包清理是靠 tar -X exclude.txt 完成的。
sudo cp -f ./debootstrap-cleanup.sh "${HOME}" 2>/dev/null || true
sudo chmod +x "${HOME}/debootstrap-cleanup.sh" 2>/dev/null || true

# ---------- 镜像与版本 ----------
MAIN_MIRROR="https://deb.debian.org/debian"
ARCHIVE_MIRROR="https://archive.debian.org/debian"

# 主线镜像仍在提供的版本
release="trixie bookworm bullseye"

# 只有归档镜像才有的版本
old_release="buster stretch jessie wheezy squeeze lenny etch sarge woody potato"

# 注：buzz/rex/bo/hamm/slink（无 Release 的远古版本）不在本脚本构建，见文件头说明与
# debian-ancient.py。

# ---------- 可选：只构建部分版本/架构 ----------
# 用法示例：ONLY="trixie buster" ARCHES="amd64" bash debian-debootstrap.sh
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
skip_list=""

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# debootstrap 的套件脚本用 “variants ...” 声明支持的 variant；sarge/woody/potato 没有这一行
supports_minbase() {
    local script="/usr/share/debootstrap/scripts/$1"
    [ -r "$script" ] || return 1
    grep -qE '^[[:space:]]*variants[[:space:]].*minbase' "$script" 2>/dev/null || return 1
    return 0
}

suite_has_script() {
    [ -r "/usr/share/debootstrap/scripts/$1" ]
}

# 目标目录是否是可用 rootfs（debootstrap 失败时会留下空目录）
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

# 清理目标目录：老套件脚本有时会把 /dev、/proc 之类的挂载留在目标目录里，
# 直接 rm 会报 “Device or resource busy”，残留目录会让下次构建叠加内容。
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

# 生成一份“强制用 MD5Sum 段校验”的 debootstrap 副本（woody/potato 的 Release 只有 MD5Sum）。
# debootstrap 主脚本里 DEBOOTSTRAP_CHECKSUM_FIELD 会被无条件设成 “SHA$SHA_SIZE”，
# 环境变量覆盖不了，只能改这一行的副本；副本仍使用 /usr/share/debootstrap 下的官方套件脚本。
make_md5_debootstrap() {
    local dst="${HOME}/debian/debootstrap-md5"
    sed 's/^DEBOOTSTRAP_CHECKSUM_FIELD=.*/DEBOOTSTRAP_CHECKSUM_FIELD="MD5SUM"/' "$DEBOOTSTRAP_BIN" > "$dst" || return 1
    chmod 0755 "$dst" || return 1
    grep -q 'DEBOOTSTRAP_CHECKSUM_FIELD="MD5SUM"' "$dst" || return 1
    printf '%s\n' "$dst"
}

# 失败后给出结论：先看是不是老 i386 glibc 的 ld.so 断言，再看 Release 层面
explain_release_failure() {
    local dir=$1 arch=$2 rel
    if [ -f "$dir/debootstrap/debootstrap.log" ] \
            && grep -q 'Inconsistency detected by ld.so' "$dir/debootstrap/debootstrap.log" 2>/dev/null; then
        printf '%s\n' "老 i386 glibc 在当前内核上 ld.so 断言失败（_dl_sysinfo_dso）；装 qemu-user-binfmt 后脚本会自动启用模拟"
        return 0
    fi
    rel=$(find "$dir" -maxdepth 6 -type f -name '*Release' 2>/dev/null | head -n 1)
    [ -n "$rel" ] || {
        printf '%s\n' "没能取到 Release（网络或镜像问题），详见日志"
        return 0
    }
    if ! grep -q '^SHA256:' "$rel" 2>/dev/null; then
        printf '%s\n' "Release 只有 MD5Sum/SHA1 段（已用强制 MD5Sum 的副本重试过）"
        return 0
    fi
    if ! grep -q "binary-$arch/Packages" "$rel" 2>/dev/null; then
        printf '%s\n' "Release 里没有 binary-$arch 索引：这个版本没有 $arch 架构（归档只有 i386）"
        return 0
    fi
    printf '%s\n' "Release 校验通过但构建仍失败，详见 inner/详细日志"
}

# 一次 debootstrap 尝试：
# debootstrap_try <suite> <dir> <mirror> <arch> <includes> <dbbin> <extra> <sig_opts> <variant_opts> <log>
debootstrap_try() {
    local suite=$1 dir=$2 mirror=$3 arch=$4 includes=$5 dbbin=$6 extra=$7 sig_opts=$8 variant_opts=$9
    local logfile=${10}
    [ -n "$dbbin" ] || dbbin="$DEBOOTSTRAP_BIN"
    local inc_opt=""
    [ -n "$includes" ] && inc_opt="--include=$includes"
    # 下面 $variant_opts / $sig_opts / $extra 需要按空格拆开（内容都不含空格与通配符）
    # shellcheck disable=SC2086
    sudo "$dbbin" $variant_opts $inc_opt \
        --arch="$arch" --cache-dir="$CACHE_DIR" \
        $sig_opts $extra \
        "$suite" "$dir" "$mirror" >>"$logfile" 2>&1
}

# 老的 i386 glibc 在某些现代内核（例如 WSL2）上跑目标系统的 dpkg 时会 ld.so 断言失败：
#   Inconsistency detected by ld.so: ... Assertion `(void *) ph->p_vaddr == _rtld_local._dl_sysinfo_dso' failed!
# setarch -L/-R/-3 都无效，用 qemu 的 binfmt 用户态模拟可以稳定绕过（Ubuntu warty/hoary 上实测 10/10 成功）。
# 这里按需启用，用完撤掉，避免影响其它 i386 构建。
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
    # binfmt_misc 的 register 里用 \xNN 转义，由内核解析，所以这里必须是字面量
    printf '%s' ':qemu-i386:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:'"$bin"':CF' \
        | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 || return 1
    [ -f "$BINFMT_QEMU_I386" ]
}

disable_binfmt_qemu_i386() {
    [ -f "$BINFMT_QEMU_I386" ] || return 0
    printf '%s' '-1' | sudo tee "$BINFMT_QEMU_I386" >/dev/null 2>&1 || true
}

# build_suite <suite> <arch> <mirror> <eol:0|1>
build_suite() {
    local suite=$1 arch=$2 mirror=$3 eol=$4
    local dir="debian-${suite}-${arch}-rootfs"
    local out="debian-${suite}-${arch}-rootfs.tar.gz"
    local dest="${prev_dir}/debian/${out}"
    local logfile="${prev_dir}/debian/logs/${suite}-${arch}.log"
    local sig_opts="" extra="" candidates="" variant_opts="" last_try="" rc=1 stop_retry=0
    local includes="ca-certificates,curl"
    local dbbin=""
    local conclusion=""
    local qemu_tried=0

    if ! suite_has_script "$suite"; then
        warn "跳过 $suite：debootstrap 没有这个套件脚本（/usr/share/debootstrap/scripts/$suite）"
        skip_list="$skip_list $suite"
        return 1
    fi

    if [ "$eol" = 1 ]; then
        # 归档源的 Release 由不同年代的密钥签名：先 removed-keys，再当前 archive-keyring，
        # 最后退到 --no-check-sig（等价于 mmdebstrap 版的 [trusted=yes]）
        candidates=""
        [ -s "$REMOVED_KEYRING" ] && candidates="--keyring=$REMOVED_KEYRING"
        [ -s "$KEYRING" ] && candidates="$candidates --keyring=$KEYRING"
        candidates="$candidates --no-check-sig"
        # 古老版本把 ca-certificates 放在 main 之外的组件里时，多开一些组件更稳
        extra="--components=main,contrib,non-free"
    else
        # 主线版本：显式给合并密钥环（debian-archive-keyring.gpg 含各版本的有效密钥）
        candidates="--keyring=$KEYRING"
        extra=""
    fi

    variant_opts="--variant=minbase"
    if ! supports_minbase "$suite"; then
        log "  注：$suite 的 debootstrap 脚本没有 minbase，改用默认 variant（required+important）"
        variant_opts=""
    fi

    clean_target "$dir"
    sudo rm -f "$out"
    log "构建 Debian $suite/$arch（debootstrap → $mirror）"

    # 不强制 --merged-usr：让 debootstrap 按版本自己选（bookworm 及以后默认合并 /usr，
    # 更老的版本保持上游的非合并布局）。
    #
    # 重试策略：每次输出单独收进 $last_try，再按失败原因决定要不要换参数——
    # 只有“签名相关”“unsupported variant”“Release 缺条目”才值得换（都在下载前失败，代价极小），
    # 其它失败（例如某个包 configure 失败）直接放弃，避免把十几分钟的构建重复好几遍。
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
            if [ "$eol" = 1 ] && grep -qE 'signed by unknown key|NO_PUBKEY|is not signed|Can.t check signature|signature verification failed|not have a known issuer' "$last_try" 2>/dev/null; then
                log "  $suite/$arch 签名校验失败，换下一个密钥环候选"
                break
            fi
            if [ -z "$dbbin" ] && grep -q 'Invalid Release file, no entry for' "$last_try" 2>/dev/null; then
                # 有可能是 Release 只有 MD5Sum 段（woody/potato），也可能是该架构压根没有索引；
                # 先花一次“秒失败”的成本试 MD5 副本，仍不行就给结论。
                if dbbin=$(make_md5_debootstrap); then
                    log "  $suite/$arch：Release 缺条目，改用强制 MD5Sum 校验的 debootstrap 副本再试"
                    clean_target "$dir"
                    continue
                fi
            fi
            if grep -q "Couldn't find these debs:" "$last_try" 2>/dev/null && [ -n "$includes" ]; then
                # 老套件可能连 --include 里的包都没有（potato 没有 ca-certificates，woody 起才有）：
                # 把该版本缺失的包从 include 列表里去掉再试（列表只减不增，最多两轮）。
                missing=$(sed -n "s/^E: Couldn't find these debs: //p" "$last_try" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
                new_includes=""
                removed=""
                for p in $(printf '%s' "$includes" | tr ',' ' '); do
                    case " $missing " in
                        *" $p "*) removed="$removed $p" ;;
                        *) new_includes="${new_includes:+$new_includes,}$p" ;;
                    esac
                done
                if [ -n "$removed" ]; then
                    log "  $suite/$arch：--include 里的包该版本没有（$removed），去掉后重试"
                    includes="$new_includes"
                    clean_target "$dir"
                    continue
                fi
            fi
            if [ "$qemu_tried" = 0 ] && grep -q 'Inconsistency detected by ld.so' "$dir/debootstrap/debootstrap.log" 2>/dev/null; then
                qemu_tried=1
                if enable_binfmt_qemu_i386; then
                    log "  $suite/$arch：老 i386 glibc 的 ld.so 断言 → 已启用 qemu-i386 模拟重试"
                    clean_target "$dir"
                    continue
                fi
                log "  $suite/$arch：老 i386 glibc 的 ld.so 断言（当前内核不兼容）"
                log "  → 先安装 qemu 再重试：apt-get install qemu-user-binfmt"
            fi
            conclusion="$(explain_release_failure "$dir" "$arch")"
            log "  $suite/$arch 失败：$conclusion"
            stop_retry=1
            break
        done

        [ "$rc" = 0 ] && break
        [ "$stop_retry" = 1 ] && break
        clean_target "$dir"
    done

    # qemu 处理器只在这个套件需要时临时启用，用完撤掉
    [ "$qemu_tried" = 1 ] && disable_binfmt_qemu_i386

    # 只有目录确实是完整 rootfs 才打包（tar 自己不会因为目录是空的而失败）
    if [ "$rc" = 0 ] && has_rootfs "$dir"; then
        if sudo tar c -zf "$out" -X exclude.txt -C "$dir" . >>"$logfile" 2>&1 \
                && verify_rootfs_tar "$out" \
                && cp -f "$out" "${prev_dir}/debian/"; then
            rc=0
        else
            rc=1
        fi
    else
        rc=1
    fi

    # 失败时留存目标里 debootstrap 自己的日志（postinst/configure 的真实报错在里面）
    if [ "$rc" != 0 ] && [ -f "$dir/debootstrap/debootstrap.log" ]; then
        cp -f "$dir/debootstrap/debootstrap.log" \
            "${prev_dir}/debian/logs/${suite}-${arch}.inner.log" 2>/dev/null || true
    fi

    clean_target "$dir"

    if [ "$rc" = 0 ] && [ -f "$dest" ]; then
        log "✓ $suite/$arch 完成：$out（$(wc -c < "$dest") 字节）"
        ok_count=$((ok_count + 1))
        return 0
    fi

    # 归档里确实没有该架构：debootstrap 已明确报
    # "no entry for main/binary-$arch/Packages"（Release 校验通过、但索引里就没有这一项）。
    # 按项目硬约束，这种情况必须诚实跳过、不计入失败——比如 woody/potato/sarge 的 amd64
    # 在 archive.debian.org 里就不存在。
    if grep -q "no entry for main/binary-$arch/Packages" "$logfile" 2>/dev/null; then
        log "⊘ $suite/$arch 跳过：Release 里没有 binary-$arch 索引（该版本没有 $arch 架构）"
        skip_list="$skip_list $suite/$arch"
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
        build_suite "$suite" "$arch" "$MAIN_MIRROR" 0
    done
done

for suite in ${old_release}; do
    want_suite "$suite" || continue
    for arch in ${arches}; do
        build_suite "$suite" "$arch" "$ARCHIVE_MIRROR" 1
    done
done

# buzz/rex/bo/hamm/slink 不在此构建：由 debian-ancient.py 独立构建器负责（见文件头说明）

popd >/dev/null || true

log "产物目录：${prev_dir}/debian（日志：${prev_dir}/debian/logs）"
log "成功 $ok_count 个，失败 $fail_count 个"
if [ -n "$failed_list" ]; then
    log "失败清单：$failed_list"
fi
if [ -n "$skip_list" ]; then
    log "跳过（无套件脚本/无该架构索引/无 Release）：$skip_list"
fi

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
