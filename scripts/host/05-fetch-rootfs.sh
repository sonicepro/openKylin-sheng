#!/usr/bin/env bash
# 05-fetch-rootfs.sh —— 选项 C：从 openKylin 官方 arm64 桌面镜像铺出 rootfs
#
# 背景：openKylin 公开的 arm64 软件归档缺包，用 debootstrap+apt 装不出 UKUI。
# 改为直接取官方镜像里"已经装好"的 rootfs（casper/filesystem.squashfs）。
# 与 ubuntu-sheng 的对应：那边用 ubuntu-base tarball 铺底，这里用官方 ISO 的
# squashfs 铺底——等价的一步，只是来源不同。
#
# 为什么用「挂载整个 ISO」而不是「range 只下 squashfs」：
#   ISO 里 filesystem.squashfs 有 7.2 GiB（>4 GiB，ISO9660 会拆成多个 extent），
#   直接按目录项长度 range 下会只拿到第一段 → 坏文件。挂载 ISO 读整个文件最稳。
#   （squashfs 7.2 GiB 与整个 ISO 7.35 GiB 相差无几，也没必要省这点。）
#
# 环境变量：
#   OPENKYLIN_ISO_URL       ISO 地址
#   OPENKYLIN_ISO           本地 ISO 路径（默认 $PWD/openkylin.iso；已存在则复用）
#   ROOTFS_SIZE_MARGIN_GIB  镜像在「解包大小」之上留的余量 GiB（默认 4）
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
ISO="${OPENKYLIN_ISO:-$PWD/openkylin.iso}"
IMAGE="${OPENKYLIN_ROOTFS_IMAGE:-$PWD/rootfs.img}"
MARGIN_GIB="${ROOTFS_SIZE_MARGIN_GIB:-4}"
ISOMNT="${OPENKYLIN_ISO_MNT:-/mnt/ok-iso}"

# ---------------------------------------------------------------------------
# 1) ISO（本地已有则复用）
# ---------------------------------------------------------------------------
if [[ ! -s "$ISO" ]]; then
  log "下载 openKylin ISO: $OPENKYLIN_ISO_URL（并行分段）"
  iso_size="$(curl -sIL "$OPENKYLIN_ISO_URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1)"
  conns=8
  if [[ "$iso_size" =~ ^[0-9]+$ ]] && [ "$iso_size" -gt 1048576 ]; then
    part=$(( (iso_size + conns - 1) / conns ))
    pids=()
    for (( i=0; i<conns; i++ )); do
      s=$(( i * part )); e=$(( s + part - 1 )); [ "$e" -ge "$iso_size" ] && e=$(( iso_size - 1 ))
      [ "$s" -ge "$iso_size" ] && break
      curl -fsL --retry 3 --connect-timeout 30 -r "${s}-${e}" -o "$ISO.part$(printf '%02d' "$i")" "$OPENKYLIN_ISO_URL" &
      pids+=( $! )
    done
    rc=0; for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    [ "$rc" -eq 0 ] || die "并行分段下载失败"
    cat "$ISO".part* > "$ISO"
    rm -f "$ISO".part*
  else
    warn "拿不到文件大小，单连接下载"
    curl -fL --retry 3 --connect-timeout 30 -o "$ISO" "$OPENKYLIN_ISO_URL" || die "ISO 下载失败"
  fi
else
  log "复用本地 ISO: $ISO"
fi
log "ISO 大小: $(du -h "$ISO" | cut -f1)"

# ---------------------------------------------------------------------------
# 2) 只读挂载 ISO
# ---------------------------------------------------------------------------
mkdir -p "$ISOMNT"
if ! mountpoint -q "$ISOMNT"; then
  mount -o loop,ro "$ISO" "$ISOMNT"
fi
cleanup() { mountpoint -q "$ISOMNT" && umount "$ISOMNT" 2>/dev/null || true; }
trap cleanup EXIT

SQUASH="$ISOMNT/casper/filesystem.squashfs"
[[ -f "$SQUASH" ]] || SQUASH="$(find "$ISOMNT" -maxdepth 3 -iname 'filesystem.squashfs' | head -n1)"
[[ -f "$SQUASH" ]] || die "ISO 里找不到 filesystem.squashfs（检查 $ISOMNT 结构）"
log "rootfs: $SQUASH（$(du -h "$SQUASH" | cut -f1)）"

# ---------------------------------------------------------------------------
# 3) 读「解包后大小」→ 决定 rootfs.img 多大
#    （filesystem.size 是解包后内容大小；镜像要 ≥ 它 + 余量）
# ---------------------------------------------------------------------------
UNCOMPRESSED=""
for f in "$(dirname "$SQUASH")/filesystem.size" "$ISOMNT/casper/filesystem.size"; do
  if [[ -f "$f" ]]; then UNCOMPRESSED="$(tr -dc '0-9' < "$f")"; break; fi
done
if [[ -n "${UNCOMPRESSED:-}" ]]; then
  SIZE_GIB=$(( (UNCOMPRESSED + 1073741823) / 1073741824 + MARGIN_GIB ))
  log "rootfs 解包后约 $((UNCOMPRESSED / 1024 / 1024)) MB → rootfs.img = ${SIZE_GIB}G（含 ${MARGIN_GIB}G 余量）"
else
  SIZE_GIB="${ROOTFS_SIZE_GIB_DEFAULT:-36}"
  warn "读不到 filesystem.size，回退 rootfs.img=${SIZE_GIB}G"
fi

# ---------------------------------------------------------------------------
# 4) 建并挂载 rootfs.img
# ---------------------------------------------------------------------------
rm -f "$IMAGE"
truncate -s "${SIZE_GIB}G" "$IMAGE"
mkfs.ext4 -F -q -L rootfs "$IMAGE"
mkdir -p "$MOUNT"
mount -o loop "$IMAGE" "$MOUNT"

# ---------------------------------------------------------------------------
# 5) 解包
# ---------------------------------------------------------------------------
log "unsquashfs → $MOUNT（这一步较慢，几分钟）"
unsquashfs -f -d "$MOUNT" "$SQUASH"

[[ -x "$MOUNT/usr/bin/apt-get" ]] || die "解包后的 rootfs 缺少 apt-get（镜像结构异常）"

# 备份会话目录：设备包安装（apt 解析器）可能误删会话文件，40-system-config 会按需恢复
install -d "$MOUNT/root/ok-build/session-backup"
cp -a "$MOUNT/usr/share/xsessions"        "$MOUNT/root/ok-build/session-backup/" 2>/dev/null || true
cp -a "$MOUNT/usr/share/wayland-sessions" "$MOUNT/root/ok-build/session-backup/" 2>/dev/null || true
log "会话: xsessions=[$(ls "$MOUNT/usr/share/xsessions" 2>/dev/null | tr '\n' ' ')] wayland=[$(ls "$MOUNT/usr/share/wayland-sessions" 2>/dev/null | tr '\n' ' ')]"

log "rootfs 就绪："
cat "$MOUNT/etc/os-release" 2>/dev/null | sed 's/^/    /' || true
printf '    顶层目录: %s\n' "$(ls "$MOUNT" | tr '\n' ' ')"
