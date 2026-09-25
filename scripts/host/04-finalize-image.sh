#!/usr/bin/env bash
# 04-finalize-image.sh —— 卸载镜像 → 校验 → 收缩 → 固定 UUID
#
# 与 ubuntu-sheng 一致：e2fsck + resize2fs -M 收缩，首启由 fstab 的
# x-systemd.growfs 扩到分区实际大小。
#
# 环境变量：
#   FS_UUID        要写入的文件系统 UUID（默认沿用上游固定值）
#   SHRINK_IMAGE   true/false，默认 true
#   COMPRESS_IMAGE none/zstd/xz，默认 zstd（压缩 rootfs.img 便于上传）
#
# 用法: sudo scripts/host/04-finalize-image.sh [镜像] [挂载点]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

IMAGE="${1:-rootfs.img}"
MOUNT="${2:-/mnt/rootfs}"
FS_UUID="${FS_UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"
SHRINK_IMAGE="${SHRINK_IMAGE:-true}"

# 卸载（可能残留 bind mount，递归卸载兜底）
umount -R "$MOUNT" 2>/dev/null || umount "$MOUNT" 2>/dev/null || warn "挂载点未挂载或已卸载: $MOUNT"
sync
log "镜像已卸载"

# 注意：e2fsck + resize2fs -M 在 31 GiB 近满盘上非常慢（可能几十分钟），且收益极小
# （几乎无可收缩空间）。默认只在显式开启 shrink_image 时才做。
if [[ "$SHRINK_IMAGE" == "true" ]]; then
  log "e2fsck + resize2fs -M 收缩（31 GiB 上较慢）..."
  e2fsck -fy "$IMAGE" >/dev/null 2>&1 || warn "e2fsck 报告了问题（已尝试修复）"
  before="$(du -h --apparent-size "$IMAGE" | cut -f1)"
  if resize2fs -M "$IMAGE" >/dev/null 2>&1; then
    # 把文件本身截断到文件系统实际大小（resize2fs -M 只缩文件系统不缩文件）
    blocks="$(dumpe2fs -h "$IMAGE" 2>/dev/null | awk -F: '/Block count/{gsub(/ /,"",$2); print $2}')"
    bsize="$(dumpe2fs -h "$IMAGE" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')"
    if [[ -n "$blocks" && -n "$bsize" ]]; then
      truncate -s "$((blocks * bsize))" "$IMAGE"
      SHRINK_RESULT="成功（$before → $(du -h --apparent-size "$IMAGE" | cut -f1)）"
      log "镜像已收缩: $SHRINK_RESULT"
    else
      SHRINK_RESULT="文件系统已缩小，但未能算出块数（文件未截断）"
      warn "$SHRINK_RESULT"
    fi
  else
    SHRINK_RESULT="失败（保持 $before；镜像仍可刷写，首启前会占满分区）"
    warn "resize2fs -M 不可用，$SHRINK_RESULT"
  fi
else
  SHRINK_RESULT="已跳过（shrink_image=false）"
fi

tune2fs -U "$FS_UUID" "$IMAGE" >/dev/null 2>&1 || warn "设置文件系统 UUID 失败（fstab 用 PARTLABEL，不影响启动）"

log "最终产物:"
ls -lh "$IMAGE" | sed 's/^/    /'
du -h --apparent-size "$IMAGE" | sed 's/^/    实际大小(逻辑): /'

# ---------------------------------------------------------------------------
# 可选压缩：rootfs.img 约 31 GiB，压缩后约 7-8 GiB，便于上传/下载。
#   设备端刷写前需先解压：`zstd -d rootfs.img.zst` 或 `xz -d rootfs.img.xz`。
# ---------------------------------------------------------------------------
COMPRESS_IMAGE="${COMPRESS_IMAGE:-zstd}"
COMPRESS_RESULT="未压缩"
COMPRESSED=""
case "$COMPRESS_IMAGE" in
  none|"")
    COMPRESS_RESULT="已跳过（compress_image=none）"
    ;;
  zstd)
    if command -v zstd >/dev/null 2>&1; then
      log "zstd 压缩（-T0 -19）..."
      if zstd -T0 "-${ZSTD_LEVEL:-6}" -f "$IMAGE" -o "$IMAGE.zst"; then
        COMPRESSED="$IMAGE.zst"
        COMPRESS_RESULT="zstd $(du -h "$IMAGE.zst" | cut -f1)（原 $(du -h --apparent-size "$IMAGE" | cut -f1)）"
      else
        COMPRESS_RESULT="zstd 压缩失败"; warn "$COMPRESS_RESULT"
      fi
    else
      COMPRESS_RESULT="未找到 zstd"; warn "$COMPRESS_RESULT"
    fi
    ;;
  xz)
    if command -v xz >/dev/null 2>&1; then
      log "xz 压缩（-T0 -6，较慢）..."
      if xz -T0 -6 -k -f "$IMAGE"; then
        COMPRESSED="$IMAGE.xz"
        COMPRESS_RESULT="xz $(du -h "$IMAGE.xz" | cut -f1)（原 $(du -h --apparent-size "$IMAGE" | cut -f1)）"
      else
        COMPRESS_RESULT="xz 压缩失败"; warn "$COMPRESS_RESULT"
      fi
    else
      COMPRESS_RESULT="未找到 xz"; warn "$COMPRESS_RESULT"
    fi
    ;;
  *) COMPRESS_RESULT="未知 compress_image=$COMPRESS_IMAGE"; warn "$COMPRESS_RESULT" ;;
esac
if [[ -n "$COMPRESSED" ]]; then
  log "压缩产物: $(basename "$COMPRESSED") $(du -h "$COMPRESSED" | cut -f1)"
else
  log "未生成压缩产物（$COMPRESS_RESULT）"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### rootfs.img"
    echo ""
    echo "| 项 | 值 |"
    echo "|---|---|"
    echo "| 最终大小（逻辑） | $(du -h --apparent-size "$IMAGE" | cut -f1) |"
    echo "| 文件系统 UUID | $(tune2fs -l "$IMAGE" 2>/dev/null | awk -F': ' '/Filesystem UUID/{print $2}') |"
    echo "| shrink_image | $SHRINK_IMAGE |"
    echo "| 收缩结果 | $SHRINK_RESULT |"
    echo "| 压缩 | $COMPRESS_RESULT |"
    echo "| 压缩产物 | ${COMPRESSED:-无} |"
  } >> "$GITHUB_STEP_SUMMARY"
fi
