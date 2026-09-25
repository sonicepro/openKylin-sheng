#!/usr/bin/env bash
# 05-de-live.sh —— 把 ISO 的 live rootfs 转成可独立启动的 rootfs
#
# 官方镜像是 casper/live 系统（开机会由 initrd 里的 casper 脚本拉起 overlay + 建 live
# 用户）。我们的 boot.img 是"内核直挂 rootfs"（root=PARTLABEL=...，无 initramfs），
# 所以 casper 根本不会被触发；这里把残留的 live 痕迹清掉，避免"看起来像 live 系统"，
# 并让后续 40-system-config.sh 正常接管用户/主机名/自动登录。
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/ok-build/in-chroot/05-de-live.sh
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

log "清理 live/casper 残留"
rm -rf /etc/casper /etc/casper.conf 2>/dev/null || true
rm -rf /lib/live /run/live /var/log/installer 2>/dev/null || true
# 有些 live 系统在 /etc/lightdm 里预置了自动登录，先清掉（40-system-config 会重写）
rm -f /etc/lightdm/lightdm.conf.d/*autologin* 2>/dev/null || true

# 首次开机向导/安装器：设备上不该自动弹安装程序
for u in kylin-os-installer.service kylin-installer.service \
         ukui-welcome.service kylin-welcome.service openkylin-firstboot.service; do
  systemctl disable "$u" 2>/dev/null || true
  systemctl mask "$u" 2>/dev/null || true
done

# live 用户（casper 造的）如果不是我们想要的名字就移除；40 会创建 USERNAME
for lu in openkylin kylin live ubuntu; do
  if id "$lu" >/dev/null 2>&1 && [[ "$lu" != "${USERNAME:-user}" ]]; then
    log "移除 live 用户: $lu"
    userdel -r "$lu" 2>/dev/null || userdel "$lu" 2>/dev/null || true
  fi
done

# fstab 交给 40-system-config.sh 按 PARTLABEL 重写
: > /etc/fstab

log "de-live 完成（casper 残留已清、安装器已屏蔽、fstab 已清空）"
