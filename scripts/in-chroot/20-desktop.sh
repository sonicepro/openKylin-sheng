#!/usr/bin/env bash
# 20-desktop.sh —— 安装桌面环境（openKylin 默认使用 UKUI；另支持 server 无图形）
#
# 与 ubuntu-sheng 的差异：桌面换成 openKylin 的 UKUI（ukui-desktop-environment 元包，
# Provides: ukui），显示管理器用 lightdm + ukui-greeter（ukui-greeter 提供
# Provides: lightdm-greeter）。不再有 GNOME/KDE/Lomiri 分支。
#
# 环境变量（由 /root/build.env 提供）：
#   DESKTOP      UKUI / server
#   QUIET_BOOT   true/false（true 时安装 plymouth）
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/ok-build/in-chroot/20-desktop.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/ok-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

: "${DESKTOP:?需要 DESKTOP}"
QUIET_BOOT="${QUIET_BOOT:-false}"

case "$DESKTOP" in
  UKUI)
    log "安装 UKUI 桌面环境 + LightDM（openKylin 默认桌面）"
    apt_update
    # 会话本体与显示管理器必须装上，放硬安装（不是 best_effort）
    apt_install_list "$BUILD_DIR/lists/ukui.list"
    for p in ukui-desktop-environment lightdm; do
      dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" \
        || die "$p 未安装成功（UKUI 桌面不可用）"
    done
    [[ -x /usr/sbin/lightdm ]] || warn "未找到 /usr/sbin/lightdm 可执行文件"
    # 会话文件是"能不能进桌面"的关键，这里做一次存在性断言
    if compgen -G "/usr/share/xsessions/ukui*.desktop" >/dev/null \
       || compgen -G "/usr/share/wayland-sessions/ukui*.desktop" >/dev/null; then
      log "检测到 UKUI 会话文件"
    else
      warn "未找到 /usr/share/{x,wayland}-sessions/ukui*.desktop —— 自动登录可能进不了桌面"
    fi
    # 可选增强（缺了不影响启动）
    apt_install_best_effort fonts-noto-cjk xdg-desktop-portal-ukui
    ;;
  server)
    log "desktop=server：不安装桌面环境"
    ;;
  *)
    die "未知的 DESKTOP: $DESKTOP（可选 UKUI / server）"
    ;;
esac

# plymouth：quiet boot 且非 server
if [[ "$QUIET_BOOT" == "true" && "$DESKTOP" != "server" ]]; then
  log "安装 Plymouth（quiet boot）"
  apt_install_list "$BUILD_DIR/lists/plymouth.list"
else
  log "跳过 Plymouth"
fi

log "桌面环境安装完成: $DESKTOP"
