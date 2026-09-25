#!/usr/bin/env bash
# 06-unsquashfs.sh —— 选项 C（解包部分）：把已下载的 filesystem.squashfs 铺进镜像
#
# 与 05-fetch-rootfs.sh 配套：05 只负责下载 squashfs 与算大小，这里负责解包。
# （拆开是因为 rootfs.img 必须在解包前就按正确大小创建好。）
#
# 环境变量：
#   OPENKYLIN_SQUASHFS  本地 squashfs 路径（默认 $PWD/filesystem.squashfs）
#
# 用法: sudo scripts/host/06-unsquashfs.sh [挂载点]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

command -v unsquashfs >/dev/null 2>&1 \
  || die "未安装 squashfs-tools（unsquashfs）；请在 workflow/宿主 apt-get install squashfs-tools"

MOUNT="${1:-/mnt/rootfs}"
SQUASH="${OPENKYLIN_SQUASHFS:-$PWD/filesystem.squashfs}"
[[ -d "$MOUNT" ]] || die "挂载点不存在: $MOUNT"
[[ -f "$SQUASH" ]] || die "找不到 squashfs: $SQUASH（应先运行 05-fetch-rootfs.sh）"

log "解包 $SQUASH → $MOUNT（这一步较慢，几分钟）"
unsquashfs -f -d "$MOUNT" "$SQUASH"

[[ -x "$MOUNT/usr/bin/apt-get" ]] || die "解包后的 rootfs 缺少 apt-get（镜像结构异常）"
log "rootfs 就绪："
cat "$MOUNT/etc/os-release" 2>/dev/null | sed 's/^/    /' || true
printf '    顶层目录: %s\n' "$(ls "$MOUNT" | tr '\n' ' ')"
