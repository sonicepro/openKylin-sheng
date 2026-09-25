#!/usr/bin/env bash
# 40-system-config.sh —— 系统级配置：主机名 / locale / 用户 / 密码 / 显示管理器 /
# 自动登录 / 网络 / fstab
#
# 与 ubuntu-sheng 的差异：显示管理器从 gdm3/sddm/greetd 改为 openKylin 的
# **lightdm + ukui-greeter**，自动登录写 /etc/lightdm/lightdm.conf.d/。
#
# 环境变量（/root/build.env）：
#   HOSTNAME / USERNAME / LANGUAGE / AUTOLOGIN / DESKTOP / PARTITION_LABEL
#   ROOTFS_PASSWORD 由 workflow 通过 env 传入（不落盘；为空则回退到默认 password）
#
# 在 chroot 内执行:
#   chroot "$MOUNT" env ROOTFS_PASSWORD=... /root/ok-build/in-chroot/40-system-config.sh
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

: "${HOSTNAME:?需要 HOSTNAME}"
: "${USERNAME:?需要 USERNAME}"
DESKTOP="${DESKTOP:-server}"
AUTOLOGIN="${AUTOLOGIN:-false}"
LANGUAGE="${LANGUAGE:-zh_CN.UTF-8}"
PARTITION_LABEL="${PARTITION_LABEL:-linux}"

# ---------------------------------------------------------------------------
# 1) 主机名
# ---------------------------------------------------------------------------
log "设置主机名: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*$HOSTNAME" /etc/hosts 2>/dev/null; then
  echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# 2) locale（生成所选 locale + en_US.UTF-8）
# ---------------------------------------------------------------------------
if [[ "$LANGUAGE" == "None (C.UTF-8)" ]]; then
  log "locale: 保持 C.UTF-8（跳过 locale-gen）"
else
  log "生成 locale: $LANGUAGE"
  apt_install locales
  sed -i 's/^# *\(en_US\.UTF-8\)/\1/' /etc/locale.gen
  esc="$(printf '%s' "$LANGUAGE" | sed 's/\./\\./g')"
  sed -i "s/^# *\(${esc}\)/\1/" /etc/locale.gen
  locale-gen
  _want="$(printf '%s' "$LANGUAGE" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"
  if ! locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$_want"; then
    warn "locale -a 里没有找到 $_want（可能是命名差异），请人工确认 locale 是否生效"
  else
    log "locale 已生成: $_want"
  fi
  echo "LANG=$LANGUAGE" > /etc/default/locale
  echo "LANG=$LANGUAGE" > /etc/locale.conf
fi

# ---------------------------------------------------------------------------
# 3) 用户与密码（用户与 root 同密码）
# ---------------------------------------------------------------------------
if ! id "$USERNAME" >/dev/null 2>&1; then
  log "创建用户: $USERNAME（加入 sudo 组）"
  useradd -m -s /bin/bash -G sudo "$USERNAME"
fi

if [[ -z "${ROOTFS_PASSWORD:-}" && -f /root/build.pw ]]; then
  ROOTFS_PASSWORD="$(cat /root/build.pw)"
fi
if [[ -z "${ROOTFS_PASSWORD:-}" ]]; then
  warn "ROOTFS_PASSWORD 未设置，使用默认密码: password"
  ROOTFS_PASSWORD="password"
fi
printf '%s:%s\n' "$USERNAME" "$ROOTFS_PASSWORD" | chpasswd
printf 'root:%s\n' "$ROOTFS_PASSWORD" | chpasswd
rm -f /root/build.pw
log "已设置 $USERNAME 与 root 的密码"

# ---------------------------------------------------------------------------
# 4) 网络
# ---------------------------------------------------------------------------
log "启用 NetworkManager"
systemctl enable NetworkManager.service || warn "启用 NetworkManager 失败"

# ---------------------------------------------------------------------------
# 5) 显示管理器 + 自动登录（openKylin：lightdm + ukui-greeter）
# ---------------------------------------------------------------------------
case "$DESKTOP" in
  UKUI)
    if [[ "$AUTOLOGIN" == "true" ]]; then
      # 探测可用的 UKUI 会话名（Wayland 优先）
      SESSION=""
      for cand in ukui-wayland ukui; do
        if [[ -f "/usr/share/wayland-sessions/$cand.desktop" || -f "/usr/share/xsessions/$cand.desktop" ]]; then
          SESSION="$cand"; break
        fi
      done
      log "配置 LightDM 自动登录: $USERNAME (session=${SESSION:-默认})"
      install -d /etc/lightdm/lightdm.conf.d
      # 写 conf.d（lightdm 先读 lightdm.conf 再读 conf.d，后者覆盖前者，最稳）
      {
        echo "[Seat:*]"
        echo "autologin-user=$USERNAME"
        echo "autologin-user-timeout=0"
        [[ -n "$SESSION" ]] && echo "autologin-session=$SESSION"
        [[ -f /usr/share/xgreeters/ukui-greeter.desktop ]] && echo "greeter-session=ukui-greeter"
      } > /etc/lightdm/lightdm.conf.d/50-ok-autologin.conf
    fi
    systemctl enable lightdm.service || warn "启用 lightdm 失败"
    systemctl set-default graphical.target
    ;;
  server)
    log "server 模式：不配置显示管理器"
    ;;
esac

# ---------------------------------------------------------------------------
# 6) 设备形态（sheng 是平板；UKUI 会读 /etc/machine-info 的 CHASSIS）
# ---------------------------------------------------------------------------
printf 'CHASSIS=tablet\n' > /etc/machine-info

# ---------------------------------------------------------------------------
# 7) fstab（PARTLABEL 定位根分区；x-systemd.growfs 首启自动扩容）
# ---------------------------------------------------------------------------
log "写入 fstab: PARTLABEL=$PARTITION_LABEL"
cat > /etc/fstab <<EOF
# <file system>            <mount point>  <type>  <options>                          <dump> <pass>
PARTLABEL=$PARTITION_LABEL /              ext4    defaults,x-systemd.growfs         0      1
EOF

# ---------------------------------------------------------------------------
# 8) machine-id：清空为空文件，让设备首启由 systemd 生成唯一 ID
# ---------------------------------------------------------------------------
: > /etc/machine-id

# ---------------------------------------------------------------------------
# 9) 清理
# ---------------------------------------------------------------------------
log "清理 apt 缓存"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* 2>/dev/null || true

# chroot 内的 policy-rc.d 只用于阻止 postinst 启服务，出厂前必须移除
rm -f /usr/sbin/policy-rc.d

log "系统配置完成"
