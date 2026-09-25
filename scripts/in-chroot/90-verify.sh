#!/usr/bin/env bash
# 90-verify.sh —— 构建末尾的硬校验
#
# 检查若干"装错了也能出镜像"的关键项：
#   * 内核模块索引 modules.dep 必须存在
#   * fstab 必须按 PARTLABEL + x-systemd.growfs 写好
#   * 设备功能包的关键二进制/服务是否就位
#   * 用户 / 自动登录（lightdm）/ UKUI 会话 / 显示管理器是否就位
#   * policy-rc.d 必须已移除（否则设备上服务永远起不来）
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/ok-build/in-chroot/90-verify.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/ok-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

if [[ -f /root/build.env ]]; then
  # shellcheck source=/dev/null
  source /root/build.env
fi

FAIL=0
pass() { printf '  [ OK ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

log "开始校验"

# 1) 内核模块
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [[ -n "$KVER" && -f "/usr/lib/modules/$KVER/modules.dep" ]]; then
  pass "内核模块就绪: $KVER（modules.dep 已生成）"
else
  fail "内核模块不完整（KVER=${KVER:-无}，缺少 modules.dep）"
fi

# 2) fstab
if grep -qE "^PARTLABEL=.*[[:space:]]/[[:space:]]+ext4.*x-systemd\.growfs" /etc/fstab 2>/dev/null; then
  pass "fstab 正确（PARTLABEL + x-systemd.growfs）"
else
  fail "fstab 不符合预期: $(tr '\n' ' ' < /etc/fstab 2>/dev/null)"
fi

# 2b) systemd 系统用户/组（sysusers）必须已生成，否则设备首启 systemd-tmpfiles 报错
if grep -qE "^systemd-network:" /etc/passwd 2>/dev/null; then
  pass "systemd 用户存在: systemd-network"
else
  fail "缺少系统用户 systemd-network（设备首启会报 Failed to resolve user）"
fi
if grep -qE "^systemd-journal:" /etc/group 2>/dev/null; then
  pass "systemd 组存在: systemd-journal"
else
  fail "缺少系统组 systemd-journal（设备首启会报 Failed to resolve group）"
fi

# 3) 设备功能包关键文件
for f in /usr/bin/adsprpcd /usr/libexec/iio-sensor-proxy /usr/bin/ssccli \
         /usr/lib/systemd/system/adsprpcd-sensorspd.service \
         /usr/share/qcom/sm8550/Xiaomi/sheng; do
  if [[ -e "$f" ]]; then
    pass "存在 $f"
  else
    fail "缺少 $f"
  fi
done

# 3b) iio-sensor-proxy 必须是本仓库构建的 9999x 版本（带 SSC 后端）
IIO_VER="$(dpkg-query -W -f='${Version}' iio-sensor-proxy 2>/dev/null || true)"
case "$IIO_VER" in
  9999*) pass "iio-sensor-proxy 版本正确: $IIO_VER" ;;
  "")    fail "iio-sensor-proxy 未安装" ;;
  *)     fail "iio-sensor-proxy 装成了发行版版本（$IIO_VER），不带 SSC 后端" ;;
esac

# 4) 用户
if id "${USERNAME:-}" >/dev/null 2>&1; then
  pass "用户存在: $USERNAME"
else
  fail "用户不存在: ${USERNAME:-<未设置>}"
fi

# 4b) 桌面链路（UKUI / lightdm）
if [[ "${DESKTOP:-server}" == "UKUI" ]]; then
  # UKUI 会话文件（x11 或 wayland 任一即可；名字可能带 ukui/kylin 前缀）
  SESS=""
  for d in /usr/share/wayland-sessions /usr/share/xsessions; do
    for f in "$d"/*.desktop; do
      [[ -e "$f" ]] || continue
      case "$(basename "$f")" in *ukui*|*kylin*) SESS="$f"; break 2 ;; esac
    done
  done
  if [[ -n "$SESS" ]]; then
    pass "UKUI 会话文件: $SESS"
  else
    fail "未找到 UKUI 会话文件；xsessions=[$(ls /usr/share/xsessions 2>/dev/null | tr '\n' ' ')] wayland=[$(ls /usr/share/wayland-sessions 2>/dev/null | tr '\n' ' ')]"
  fi
  # 显示管理器必须 enabled
  if [[ -e /etc/systemd/system/display-manager.service ]] \
     || systemctl is-enabled lightdm.service >/dev/null 2>&1 \
     || [[ -e /etc/systemd/system/graphical.target.wants/lightdm.service ]]; then
    pass "lightdm.service 已启用"
  else
    fail "lightdm.service 未启用"
  fi
  # 自动登录
  if [[ "${AUTOLOGIN:-false}" == "true" ]]; then
    if grep -rqE '^autologin-user=' /etc/lightdm/lightdm.conf.d/ 2>/dev/null \
       || grep -qE '^autologin-user=' /etc/lightdm/lightdm.conf 2>/dev/null; then
      pass "LightDM 自动登录已配置"
    else
      fail "LightDM 自动登录未配置（检查 /etc/lightdm/lightdm.conf.d/）"
    fi
  fi
fi

# 5) 网络
if [[ -e /etc/systemd/system/multi-user.target.wants/NetworkManager.service ]] \
   || [[ -e /etc/systemd/system/dbus-org.freedesktop.NetworkManager.service ]] \
   || systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
  pass "NetworkManager 已启用"
else
  fail "NetworkManager 未启用（看 /etc/systemd/system/multi-user.target.wants/）"
fi

# 6) locale
if [[ "${LANGUAGE:-zh_CN.UTF-8}" != "None (C.UTF-8)" ]]; then
  grep -q "${LANGUAGE}" /etc/default/locale 2>/dev/null && pass "locale 已写入: $LANGUAGE" || fail "locale 未写入"
fi

# 7) machine-info（平板形态）
if grep -qE '^CHASSIS=tablet' /etc/machine-info 2>/dev/null; then
  pass "CHASSIS=tablet"
else
  fail "/etc/machine-info 未设 CHASSIS=tablet"
fi

# 8) 传感器守护进程必须真的被 enable
if [[ -f /usr/lib/systemd/system/adsprpcd-sensorspd.service ]]; then
  if systemctl is-enabled adsprpcd-sensorspd.service >/dev/null 2>&1 \
     || [[ -e /etc/systemd/system/iio-sensor-proxy.service.wants/adsprpcd-sensorspd.service ]] \
     || [[ -e /etc/systemd/system/multi-user.target.wants/adsprpcd-sensorspd.service ]]; then
    pass "adsprpcd-sensorspd.service 已启用"
  else
    fail "adsprpcd-sensorspd.service 存在但未启用（传感器不会工作）"
  fi
fi

# 9) policy-rc.d 必须已移除
if [[ -e /usr/sbin/policy-rc.d ]]; then
  fail "policy-rc.d 仍存在（会导致设备上服务无法启动）"
else
  pass "policy-rc.d 已移除"
fi

if [[ "$FAIL" -ne 0 ]]; then
  die "校验未通过，镜像不可用"
fi
log "全部校验通过"
