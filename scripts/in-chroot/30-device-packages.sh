#!/usr/bin/env bash
# 30-device-packages.sh —— 安装全部设备功能包（/tmp/debs/*.deb）并做设备侧收尾
#
# 与 ubuntu-sheng 完全一致：openKylin 是 dpkg/apt 系，ubuntu-sheng 构建出的
# linux-xiaomi-sheng / fastrpc / libssc / iio-sensor-proxy / sheng-sensors /
# sheng-devauth / alsa-xiaomi-sheng / firmware-xiaomi-sheng / xiaomi-* 都是标准
# Debian 包，可直接安装。差异仅在于目录名（/root/ok-build）。
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/ok-build/in-chroot/30-device-packages.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/ok-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

shopt -s nullglob
debs=(/tmp/debs/*.deb)
[[ "${#debs[@]}" -gt 0 ]] || die "/tmp/debs 下没有 .deb"

log "待安装设备包（${#debs[@]} 个）："
for d in "${debs[@]}"; do
  printf '    %-42s %s\n' "$(basename "$d")" \
    "$(dpkg-deb -f "$d" Package 2>/dev/null) $(dpkg-deb -f "$d" Version 2>/dev/null)"
done

log "安装中"
if ! apt_install "${debs[@]}"; then
  warn "首次安装失败，尝试 apt-get install -f 修复依赖后重试"
  apt-get install -f -y || true
  apt_install "${debs[@]}" || die "设备包安装失败，请检查上面的依赖错误"
fi

# 版本断言：桌面安装可能把发行版自带的 iio-sensor-proxy 作为 Recommends 带进来，
# 必须以本仓库构建的 9999x 版本覆盖（发行版版没有 SSC 后端 → 传感器不工作）。
IIO_VER="$(dpkg-query -W -f='${Version}' iio-sensor-proxy 2>/dev/null || true)"
case "$IIO_VER" in
  "")    warn "iio-sensor-proxy 未安装（本仓库的 deb 可能没装上）" ;;
  9999*) log "iio-sensor-proxy 使用本仓库版本: $IIO_VER" ;;
  *)     die "iio-sensor-proxy 装成了发行版版本（$IIO_VER），不带 SSC 后端" ;;
esac

# 权限修复：dpkg-deb 打包时统一 644，可执行文件需要显式补权限
log "修复可执行权限"
for f in /usr/bin/adsprpcd /usr/libexec/iio-sensor-proxy /usr/bin/monitor-sensor /usr/bin/ssccli; do
  if [[ -e "$f" ]]; then
    chmod +x "$f"
    printf '    +x %s\n' "$f"
  else
    printf '    (跳过，不存在) %s\n' "$f"
  fi
done

# depmod：让 /usr/lib/modules/<kver>/modules.dep 等索引在镜像内就生成
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [[ -n "$KVER" ]]; then
  log "为内核 $KVER 生成模块依赖索引（depmod）"
  depmod -a "$KVER" || warn "depmod 返回非 0（可能已有现成索引）"
  [[ -f "/usr/lib/modules/$KVER/modules.dep" ]] \
    || die "modules.dep 未生成（$KVER）：模块在设备上无法自动加载"
else
  warn "未找到 /usr/lib/modules/*，内核包可能没有装上"
fi

# 传感器服务（unit 文件名与二进制都是 adsprpcd，注意拼写）
if [[ -f /usr/lib/systemd/system/adsprpcd-sensorspd.service ]]; then
  systemctl enable adsprpcd-sensorspd.service || warn "启用 adsprpcd-sensorspd 失败"
else
  warn "未找到 adsprpcd-sensorspd.service（fastrpc 包可能没装上）"
fi
if [[ -f /usr/lib/systemd/system/sheng-devauth.service ]]; then
  systemctl enable sheng-devauth.service || warn "启用 sheng-devauth 失败"
fi

log "设备包安装完成"
