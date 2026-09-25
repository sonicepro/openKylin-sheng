#!/usr/bin/env bash
# 05-fetch-rootfs.sh —— 选项 C（下载部分）：只取官方 ISO 里的 rootfs，不下载整个 ISO
#
# openKylin 桌面 ISO 有 7.35 GB，而 rootfs 解包后又约 31 GiB；GitHub runner 的磁盘
# 放不下「完整 ISO + 大镜像」。这里用 HTTP Range：
#   1) 先拉 ISO 头部 8 MB，解析 casper/filesystem.squashfs 的字节偏移与长度；
#   2) 只 range 下载这段 squashfs（约 2.7 GB）；
#   3) 顺带读 casper/filesystem.size（解包后大小），据此算出 rootfs.img 需要多大，
#      通过 $GITHUB_OUTPUT 的 img_size 传给后续步骤。
#
# 依赖：curl（需支持 Range）、python3（iso-squash-info.py）。
# 产出：$PWD/filesystem.squashfs；$GITHUB_OUTPUT 的 img_size（形如 34G）。
#
# 用法: scripts/host/05-fetch-rootfs.sh   （不需要 root，只要联网）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"

ISO_URL="$OPENKYLIN_ISO_URL"
HEAD="$PWD/iso-head.bin"
SQUASH="$PWD/filesystem.squashfs"
SIZE_BIN="$PWD/fs-size.bin"
MARGIN_GIB="${ROOTFS_SIZE_MARGIN_GIB:-4}"   # 镜像余量（内核/固件/设备包等）

command -v python3 >/dev/null 2>&1 || die "需要 python3（解析 ISO 头部）"

# ---------------------------------------------------------------------------
# 1) 头部 8 MB（若服务器忽略 Range 会拿到完整文件，用 --max-filesize 兜底中止）
# ---------------------------------------------------------------------------
log "读取 ISO 头部以定位 rootfs: $ISO_URL"
if ! curl -fL --retry 3 --connect-timeout 30 -r 0-8388607 --max-filesize 16777216 \
        -o "$HEAD" "$ISO_URL"; then
  die "无法读取 ISO 头部（$ISO_URL）。本脚本依赖对 ISO 的 HTTP Range 支持；请换一个支持 Range 的镜像地址"
fi
[[ -s "$HEAD" ]] || die "ISO 头部为空"

# ---------------------------------------------------------------------------
# 2) 解析偏移/长度
# ---------------------------------------------------------------------------
eval "$(python3 "$HERE/iso-squash-info.py" "$HEAD")"
: "${squashfs_off:?}" "${squashfs_len:?}"
log "filesystem.squashfs: offset=$squashfs_off len=$squashfs_len"

# ---------------------------------------------------------------------------
# 3) 只下载 squashfs 这一段
# ---------------------------------------------------------------------------
squashfs_end=$((squashfs_off + squashfs_len - 1))
log "range 下载 squashfs（约 $((squashfs_len / 1024 / 1024)) MB）..."
curl -fL --retry 3 --connect-timeout 30 -r "${squashfs_off}-${squashfs_end}" \
     -o "$SQUASH" "$ISO_URL"

actual="$(stat -c%s "$SQUASH" 2>/dev/null || wc -c < "$SQUASH")"
if [[ "$actual" != "$squashfs_len" ]]; then
  die "range 下载大小不符：得到 $actual，期望 $squashfs_len（服务器可能不支持 Range，请换镜像）"
fi
log "squashfs 就绪: $(du -h "$SQUASH" | cut -f1)"

# ---------------------------------------------------------------------------
# 4) 解包后大小 → 计算 rootfs.img 需要多大
# ---------------------------------------------------------------------------
#   filesystem.size 是纯文本的字节数；rootfs.img 需要「解包大小 + 余量」。
#   余量用于：设备内核/固件 deb、inode 开销、e2fs 元数据等。
if [[ "$size_len" -gt 0 ]]; then
  curl -fL --retry 3 -r "${size_off}-$((size_off + size_len - 1))" -o "$SIZE_BIN" "$ISO_URL" || true
  UNCOMPRESSED="$(tr -dc '0-9' < "$SIZE_BIN" 2>/dev/null || true)"
else
  UNCOMPRESSED=""
fi

if [[ -n "${UNCOMPRESSED:-}" ]]; then
  need_gib=$(( (UNCOMPRESSED + 1073741823) / 1073741824 + MARGIN_GIB ))
  log "rootfs 解包后约 $((UNCOMPRESSED / 1024 / 1024)) MB → rootfs.img 设为 ${need_gib}G（含 ${MARGIN_GIB}G 余量）"
else
  need_gib="${ROOTFS_SIZE_GIB_DEFAULT:-36}"
  warn "未能读到 filesystem.size，回退 rootfs.img=${need_gib}G"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "img_size=${need_gib}G" >> "$GITHUB_OUTPUT"
  echo "uncompressed_bytes=${UNCOMPRESSED:-0}" >> "$GITHUB_OUTPUT"
fi

# 清理只有头部解析用得到的临时文件
rm -f "$HEAD" "$SIZE_BIN" 2>/dev/null || true
log "完成：filesystem.squashfs 已在 $PWD，供 06-unsquashfs.sh 使用"
