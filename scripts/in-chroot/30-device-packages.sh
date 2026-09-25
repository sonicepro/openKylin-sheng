#!/usr/bin/env bash
# 30-device-packages.sh —— 安装设备功能包（/tmp/debs/*.deb）并做设备侧收尾
#
# openKylin image 模式的差异：
#   * 官方桌面 rootfs 自带 linux-firmware，而 firmware-xiaomi-sheng 声明
#     Conflicts/Replaces: linux-firmware。**绝不能** `apt purge linux-firmware`——
#     在 openKylin 上会沿依赖链级联删掉一大片（连桌面会话包 ukui-session-manager、
#     network-manager 都被带走，90-verify 因此报“无会话/无 NM”）。
#     改用 `dpkg-deb -x` 直接把固件文件铺进 /（覆盖同名文件、不注册包、不删别人）。
#   * image 模式不跑 10-base → 先补装设备包运行期依赖（libprotobuf-c1/libqmi-glib5 等）。
#   * 设备包分「必需」与「可选（xiaomi-*）」：必需硬失败；可选装不上则跳过
#     （如 xiaomi-sheng-fingerprint 需要更高的 fprintd/libgusb2）。
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
  printf '    %-48s %s\n' "$(basename "$d")" \
    "$(dpkg-deb -f "$d" Package 2>/dev/null) $(dpkg-deb -f "$d" Version 2>/dev/null)"
done

# ---------------------------------------------------------------------------
# 1) apt 索引 + 设备包运行期依赖
# ---------------------------------------------------------------------------
log "apt-get update（解析设备包依赖）"
apt_update || warn "apt update 失败，设备包依赖可能装不上"

apt_install_list_best_effort "$BUILD_DIR/lists/runtime-libs.list"

# ---------------------------------------------------------------------------
# 2) 必需设备包（不含固件）——硬失败
# ---------------------------------------------------------------------------
essential=()
for p in linux-xiaomi-sheng fastrpc libssc iio-sensor-proxy sheng-sensors \
         sheng-devauth alsa-xiaomi-sheng; do
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
# 3) 设备固件：用 dpkg-deb -x 直接铺（避免与 linux-firmware 的 Conflicts 级联删包）
#    同名文件以 sheng 固件为准；linux-firmware 保留（多出来的文件无害）。
# ---------------------------------------------------------------------------
fw=(/tmp/debs/firmware-xiaomi-sheng*.deb)
if [[ "${#fw[@]}" -gt 0 ]]; then
  log "解包固件 $(basename "${fw[0]}") → /（保留 linux-firmware，不触发删包）"
  dpkg-deb -x "${fw[0]}" /
else
  warn "未找到 firmware-xiaomi-sheng deb"
fi

# ---------------------------------------------------------------------------
# 4) 可选功能包（xiaomi-*）——逐个 best-effort，依赖不满足则跳过
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
# 5) 版本断言：iio-sensor-proxy 必须是本仓库的 9999x（带 SSC 后端）
# ---------------------------------------------------------------------------
IIO_VER="$(dpkg-query -W -f='${Version}' iio-sensor-proxy 2>/dev/null || true)"
case "$IIO_VER" in
  "")    warn "iio-sensor-proxy 未安装（本仓库的 deb 可能没装上）" ;;
  9999*) log "iio-sensor-proxy 使用本仓库版本: $IIO_VER" ;;
  *)     die "iio-sensor-proxy 装成了发行版版本（$IIO_VER），不带 SSC 后端" ;;
esac

# ---------------------------------------------------------------------------
# 6) 权限修复
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
# 7) depmod（生成模块依赖索引）
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
# 8) 传感器/认证服务
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
