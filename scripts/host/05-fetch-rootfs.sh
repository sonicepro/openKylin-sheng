#!/usr/bin/env bash
# 05-fetch-rootfs.sh —— 选项 C：从 openKylin 官方 arm64 桌面镜像里提取 rootfs
#
# 背景：openKylin 公开的 arm64 软件归档缺包（缺 python3-watchdog / libbytesize1 /
# libei1 / libgtk-4-1 等），用 debootstrap+apt 装不出 UKUI。改为直接取官方镜像里
# 已经装好的 rootfs（casper/filesystem.squashfs），后续叠加 sheng 设备包即可得到
# 可用的 openKylin 桌面。
#
# 与 ubuntu-sheng 的对应关系：那边用 ubuntu-base tarball 铺底，这里用官方 ISO 的
# squashfs 铺底（等价的一步，只是来源不同）。
#
# 环境变量（见 common/distro-env.sh）：
#   OPENKYLIN_ISO_URL  ISO 地址（默认 3.0 arm64 desktop）
#   OPENKYLIN_ISO      本地 ISO 路径（默认 $PWD/openkylin.iso；已存在则复用不重下）
#
# 用法: sudo scripts/host/05-fetch-rootfs.sh [挂载点]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

command -v unsquashfs >/dev/null 2>&1 \
  || die "未安装 squashfs-tools（unsquashfs）；请在 workflow/宿主 apt-get install squashfs-tools"

MOUNT="${1:-/mnt/rootfs}"
[[ -d "$MOUNT" ]] || die "挂载点不存在: $MOUNT"
ISO="${OPENKYLIN_ISO:-$PWD/openkylin.iso}"

# ---------------------------------------------------------------------------
# 1) 镜像：本地已有就复用（CI 里可挂缓存），否则下载
# ---------------------------------------------------------------------------
if [[ ! -s "$ISO" ]]; then
  log "下载 openKylin 镜像: $OPENKYLIN_ISO_URL"
  curl -fL --retry 3 --connect-timeout 30 -o "$ISO.part" "$OPENKYLIN_ISO_URL" \
    || die "镜像下载失败（检查 OPENKYLIN_ISO_URL / 网络）"
  mv "$ISO.part" "$ISO"
else
  log "复用本地镜像: $ISO"
fi
log "镜像大小: $(du -h "$ISO" | cut -f1)"

# ---------------------------------------------------------------------------
# 2) 只读挂载 ISO，找到 casper/filesystem.squashfs
# ---------------------------------------------------------------------------
ISOMNT="$(mktemp -d)"
cleanup() {
  mountpoint -q "$ISOMNT" && umount "$ISOMNT" 2>/dev/null || true
  rmdir "$ISOMNT" 2>/dev/null || true
}
trap cleanup EXIT
mount -o loop,ro "$ISO" "$ISOMNT"

SQUASH="$(find "$ISOMNT" -maxdepth 3 -iname 'filesystem.squashfs' | head -n1)"
[[ -n "$SQUASH" ]] || die "镜像里找不到 filesystem.squashfs（检查 $ISOMNT 结构）"
log "找到 rootfs: $SQUASH"

# ---------------------------------------------------------------------------
# 3) 解包到挂载点（覆盖 mkfs 留下的 lost+found 等）
# ---------------------------------------------------------------------------
log "解包 squashfs → $MOUNT（这一步较慢，几分钟）"
unsquashfs -f -d "$MOUNT" "$SQUASH"

# 自检：解出来得是一个能用的系统
[[ -x "$MOUNT/usr/bin/apt-get" ]] || die "解包后的 rootfs 缺少 apt-get（镜像结构异常）"
[[ -d "$MOUNT/usr/share/ukui" || -d "$MOUNT/usr/lib/ukui" || -e "$MOUNT/usr/bin/ukui-session" || -d "$MOUNT/usr/lib/systemd/system" ]] \
  || warn "没看到明显的 UKUI 目录，稍后 90-verify 会严格校验"

log "rootfs 就绪："
cat "$MOUNT/etc/os-release" 2>/dev/null | sed 's/^/    /' || true
printf '    顶层目录: %s\n' "$(ls "$MOUNT" | tr '\n' ' ')"
