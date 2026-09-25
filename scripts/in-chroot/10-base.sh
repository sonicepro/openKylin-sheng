#!/usr/bin/env bash
# 10-base.sh —— 在 chroot 内安装 openKylin 基础系统包
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/ok-build/in-chroot/10-base.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/ok-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

prepare_apt

log "安装基础包（$DISTRO_SERIES / $DISTRO_SUITE）"
apt_update

apt_install_list "$BUILD_DIR/lists/base.list"

# 上游 debian-sheng 显式预装的运行期库（best-effort，带 t64 兜底）
apt_install_list_best_effort "$BUILD_DIR/lists/runtime-libs.list"

# wireless-regdb 的 alternatives（与 ubuntu-sheng 的 "Use Upstream Regulatory Database" 一致）
if [[ -x /usr/bin/update-alternatives && -e /lib/firmware/regulatory.db-upstream ]]; then
  update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream \
    || warn "设置 regulatory.db alternatives 失败"
  log "已切换到 upstream 无线管制数据库"
else
  log "跳过 regulatory.db alternatives（该版本未提供）"
fi

log "基础包安装完成"
