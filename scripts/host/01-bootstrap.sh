#!/usr/bin/env bash
# 01-bootstrap.sh —— 往已挂载的镜像里铺 openKylin 基础系统
#
# 与 ubuntu-sheng 的差异：Ubuntu 侧有官方 ubuntu-base tarball，优先解包；而
# openKylin 不发布 base tarball，因此这里直接用 **debootstrap** 从 openKylin 归档
# 引导。openKylin 2.0（nile）基础是 Debian 13 系，故借 Debian 的 debootstrap 脚本
# （trixie，在现代 debootstrap 里等价于 sid）来引导——套件名仍传 openKylin 自己的
# suite（nile/huanghe），脚本只负责通用引导逻辑，不校验 suite 是否 Debian 的。
#
# 环境变量（见 common/distro-env.sh）：
#   DISTRO_SERIES / DISTRO_SUITE      见 distro-env.sh
#   OPENKYLIN_MIRROR                  openKylin 归档地址
#   OPENKYLIN_KEYRING_URL             归档密钥环（gpg）地址
#   OPENKYLIN_DEBOOTSTRAP_SCRIPT_URL  本地缺脚本时的下载地址（默认 Debian 的 sid 脚本）
#   DEBOOTSTRAP_SCRIPT                debootstrap 脚本名（默认 trixie）
#
# 用法: sudo scripts/host/01-bootstrap.sh [挂载点]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

MOUNT="${1:-/mnt/rootfs}"
[[ -d "$MOUNT" ]] || die "挂载点不存在: $MOUNT"

command -v debootstrap >/dev/null 2>&1 \
  || die "未安装 debootstrap（请在 workflow/宿主里 apt-get install debootstrap）"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1) 归档密钥环（openKylin 归档的 InRelease 用这个密钥签名）
# ---------------------------------------------------------------------------
KEYRING="$WORK/openkylin-archive-keyring.gpg"
log "下载 openKylin 归档密钥环: $OPENKYLIN_KEYRING_URL"
curl -fL --retry 3 --connect-timeout 20 -o "$KEYRING" "$OPENKYLIN_KEYRING_URL" \
  || die "无法下载 openKylin 归档密钥环（检查 OPENKYLIN_KEYRING_URL）"

# ---------------------------------------------------------------------------
# 2) 选 debootstrap 引导脚本
#    现代 debootstrap 里 trixie 与 sid 等价（trixie 脚本内容就是走 sid 逻辑），
#    所以本地缺 trixie 时退到 sid；本地连 sid 都没有（极旧 debootstrap）才联网取。
# ---------------------------------------------------------------------------
DB_SCRIPT=""
for cand in "$DEBOOTSTRAP_SCRIPT" sid; do
  if [[ -f "/usr/share/debootstrap/scripts/$cand" ]]; then
    DB_SCRIPT="/usr/share/debootstrap/scripts/$cand"
    log "使用 debootstrap 脚本: $DB_SCRIPT"
    break
  fi
done
if [[ -z "$DB_SCRIPT" ]]; then
  warn "本地没有 $DEBOOTSTRAP_SCRIPT / sid 脚本，尝试联网下载 Debian 的 sid 脚本"
  DB_SCRIPT="$WORK/$DEBOOTSTRAP_SCRIPT"
  curl -fL --retry 3 -o "$DB_SCRIPT" "${OPENKYLIN_DEBOOTSTRAP_SCRIPT_URL:-https://git.launchpad.net/ubuntu/+source/debootstrap/plain/scripts/sid}" \
    || die "无法获取 debootstrap 脚本"
fi

# ---------------------------------------------------------------------------
# 3) debootstrap 引导
# ---------------------------------------------------------------------------
COMPONENTS_CSV="$(printf '%s' "$OPENKYLIN_COMPONENTS" | tr ' ' ',')"
log "引导 openKylin $DISTRO_SERIES ($DISTRO_SUITE) → $MOUNT"
log "  归档: $OPENKYLIN_MIRROR"
log "  组件: $COMPONENTS_CSV"
debootstrap \
  --arch=arm64 \
  --variant=minbase \
  --keyring="$KEYRING" \
  --components="$COMPONENTS_CSV" \
  --include=apt,openkylin-keyring,ca-certificates \
  "$DISTRO_SUITE" "$MOUNT" "$OPENKYLIN_MIRROR" "$DB_SCRIPT"

# 引导结果自检：chroot 阶段依赖 apt-get，缺失时在这里就报清楚
if [[ ! -x "$MOUNT/usr/bin/apt-get" ]]; then
  warn "引导后的 rootfs 里没有 /usr/bin/apt-get，目录内容如下："
  ls -l "$MOUNT/usr/bin" 2>/dev/null | head -30 | sed 's/^/    /' || true
  die "引导失败：rootfs 缺少 apt-get"
fi
log "已确认 rootfs 内有 apt-get"

# ---------------------------------------------------------------------------
# 4) apt 源：openKylin 归档 + 安全更新口袋
#    debootstrap 只会写主 suite 的 sources.list，这里改写成 deb822 并补安全口袋。
#    密钥环落到镜像内 /etc/apt/keyrings（不依赖 openkylin-keyring 包安装到哪个路径）。
# ---------------------------------------------------------------------------
log "写入 apt 源（deb822 格式）"
install -Dm644 "$KEYRING" "$MOUNT/etc/apt/keyrings/openkylin-archive-keyring.gpg"
mkdir -p "$MOUNT/etc/apt/sources.list.d"
cat > "$MOUNT/etc/apt/sources.list.d/openkylin.sources" <<EOF
Types: deb
URIs: ${OPENKYLIN_MIRROR}
Suites: ${DISTRO_SUITE}
Components: ${OPENKYLIN_COMPONENTS}
Signed-By: /etc/apt/keyrings/openkylin-archive-keyring.gpg

Types: deb
URIs: ${OPENKYLIN_MIRROR}
Suites: ${DISTRO_SUITE}-security
Components: ${OPENKYLIN_COMPONENTS}
Signed-By: /etc/apt/keyrings/openkylin-archive-keyring.gpg
EOF
rm -f "$MOUNT/etc/apt/sources.list"

log "引导完成：$DISTRO_SERIES ($DISTRO_SUITE)"
cat "$MOUNT/etc/os-release" 2>/dev/null | sed 's/^/    /' || true
