#!/usr/bin/env bash
# 30-device-packages.sh —— 安装全部设备功能包（/tmp/debs/*.deb）并做设备侧收尾
#
# 与 ubuntu-sheng 的差异（主要在 openKylin image 模式）：
#   1. 官方桌面 rootfs 自带 linux-firmware，而 firmware-xiaomi-sheng 声明
#      Conflicts/Replaces: linux-firmware → 必须先移除 linux-firmware，否则装不上。
#   2. image 模式不跑 10-base，设备包的运行期依赖（libprotobuf-c1/libqmi-glib5 等）
#      没装过 → 这里先补装（runtime-libs.list，best-effort）。
#   3. 设备包分「必需」与「可选（xiaomi-* 功能）」：必需硬失败；可选逐个 best-effort，
#      装不上就跳过。例如 xiaomi-sheng-fingerprint 需要 fprintd>=1.94.5 /
#      libgusb2>=0.4.9，openKylin 3.0 版本偏低 → 跳过（仅指纹功能缺失）。
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/ok-build/in-chroot/30-device-packages.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/ok-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

prepare_apt
shopt -s nullglob

debs=(/tmp/debs/*.deb)
[[ "${#debs[@]}" -gt 0 ]] || die "/tmp/debs 下没有 .deb"

log "待安装设备包（${#debs[@]} 个）："
for d in "${debs[@]}"; do
  printf '    %-46s %s\n' "$(basename "$d")" \
    "$(dpkg-deb -f "$d" Package 2>/dev/null) $(dpkg-deb -f "$d" Version 2>/dev/null)"
done

# ---------------------------------------------------------------------------
# 1) 更新 apt 索引（设备包依赖要从软件源解析，image 镜像里索引可能是空的）
# ---------------------------------------------------------------------------
log "apt-get update（用于解析设备包依赖）"
apt_update || warn "apt update 失败，设备包依赖可能装不上"

# ---------------------------------------------------------------------------
# 2) 移除与 firmware-xiaomi-sheng 冲突的 linux-firmware
# ---------------------------------------------------------------------------
if dpkg-query -W -f='${Status}' linux-firmware 2>/dev/null | grep -q "install ok installed"; then
  log "移除 linux-firmware（firmware-xiaomi-sheng Conflicts/Replaces 它）"
  apt-get purge -y linux-firmware 2>/dev/null \
    || dpkg --purge --force-all linux-firmware 2>/dev/null \
    || warn "移除 linux-firmware 失败（下面安装固件包可能因此失败）"
  apt-get autoremove -y 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3) 预装设备包运行期依赖（libssc 依赖 libprotobuf-c1/libqmi-glib5 等）
# ---------------------------------------------------------------------------
apt_install_list_best_effort "$BUILD_DIR/lists/runtime-libs.list"

# ---------------------------------------------------------------------------
# 4) 必需设备包（内核/固件/传感器/音频/键盘认证）——硬失败
# ---------------------------------------------------------------------------
essential=()
for p in linux-xiaomi-sheng fastrpc libssc iio-sensor-proxy sheng-sensors \
         sheng-devauth alsa-xiaomi-sheng firmware-xiaomi-sheng; do
  essential+=(/tmp/debs/${p}*.deb)
done
[[ "${#essential[@]}" -gt 0 ]] || die "没有匹配到必需设备包（检查 /tmp/debs 文件名）"
log "安装必需设备包（${#essential[@]} 个）"
if ! apt_install "${essential[@]}"; then
  warn "首次安装失败，尝试 apt-get install -f 修复依赖后重试"
  apt-get install -f -y || true
  apt_install "${essential[@]}" || die "必需设备包安装失败，请检查上面的依赖错误"
fi

# ---------------------------------------------------------------------------
# 5) 可选功能包（xiaomi-*）——逐个 best-effort，依赖不满足则跳过
# ---------------------------------------------------------------------------
optional=(/tmp/debs/xiaomi-*.deb)
log "安装可选功能包（${#optional[@]} 个，失败则跳过）"
skipped=()
for d in "${optional[@]}"; do
  if apt_install "$d"; then
    log "  已装 $(basename "$d")"
  else
    apt-get install -f -y >/dev/null 2>&1 || true
    skipped+=("$(basename "$d")")
    warn "  跳过（依赖不满足）: $(basename "$d")"
  fi
done
if [[ "${#skipped[@]}" -gt 0 ]]; then
  warn "以下可选包因依赖不满足被跳过（对应功能缺失，不影响其它）：${skipped[*]}"
fi

# ---------------------------------------------------------------------------
# 6) 版本断言：iio-sensor-proxy 必须是本仓库的 9999x（带 SSC 后端）
# ---------------------------------------------------------------------------
IIO_VER="$(dpkg-query -W -f='${Version}' iio-sensor-proxy 2>/dev/null || true)"
case "$IIO_VER" in
  "")    warn "iio-sensor-proxy 未安装（本仓库的 deb 可能没装上）" ;;
  9999*) log "iio-sensor-proxy 使用本仓库版本: $IIO_VER" ;;
  *)     die "iio-sensor-proxy 装成了发行版版本（$IIO_VER），不带 SSC 后端" ;;
esac

# ---------------------------------------------------------------------------
# 7) 权限修复
# ---------------------------------------------------------------------------
log "修复可执行权限"
for f in /usr/bin/adsprpcd /usr/libexec/iio-sensor-proxy /usr/bin/monitor-sensor /usr/bin/ssccli; do
  if [[ -e "$f" ]]; then
    chmod +x "$f"
    printf '    +x %s\n' "$f"
  else
    printf '    (跳过，不存在) %s\n' "$f"
  fi
done

# ---------------------------------------------------------------------------
# 8) depmod（生成模块依赖索引）
# ---------------------------------------------------------------------------
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [[ -n "$KVER" ]]; then
  log "为内核 $KVER 生成模块依赖索引（depmod）"
  depmod -a "$KVER" || warn "depmod 返回非 0（可能已有现成索引）"
  [[ -f "/usr/lib/modules/$KVER/modules.dep" ]] \
    || die "modules.dep 未生成（$KVER）：模块在设备上无法自动加载"
else
  warn "未找到 /usr/lib/modules/*，内核包可能没有装上"
fi

# ---------------------------------------------------------------------------
# 9) 传感器/认证服务
# ---------------------------------------------------------------------------
if [[ -f /usr/lib/systemd/system/adsprpcd-sensorspd.service ]]; then
  systemctl enable adsprpcd-sensorspd.service || warn "启用 adsprpcd-sensorspd 失败"
else
  warn "未找到 adsprpcd-sensorspd.service（fastrpc 包可能没装上）"
fi
if [[ -f /usr/lib/systemd/system/sheng-devauth.service ]]; then
  systemctl enable sheng-devauth.service || warn "启用 sheng-devauth 失败"
fi

log "设备包安装完成"
