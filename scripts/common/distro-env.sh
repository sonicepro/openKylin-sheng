#!/usr/bin/env bash
# 公共环境：openKylin 版本 ↔ suite 代号映射 + 归档地址 + 密钥环 + 日志工具
# 被 host/ 与 in-chroot/ 下的脚本共同 source。
#
# openKylin 的 suite 代号（与 ubuntu-sheng 的 Ubuntu 代号无关，集中维护在此，
# 避免散落到 workflow YAML）：
#   nile    = openKylin 2.0（默认，稳定）
#   huanghe = openKylin 3.0
#   yangtze = openKylin 1.0（较旧，仅兼容保留）
#
# 归档：http://archive.build.openkylin.top/openkylin/
#   * 该归档**直接含 arm64**（Release 里 Architectures: amd64 arm64 i386
#     loong64 riscv64 rv64g），无需 ports 镜像
#   * 组件：main cross pty
#   * 用 PGP 签名（InRelease），密钥环 openkylin-archive-keyring gpg
#
# openKylin 2.0（nile）基础为 Debian 13 系（base-files 13-ok2.2、systemd 255.2），
# 因此 debootstrap 借 Debian 的 trixie 脚本即可引导（见 01-bootstrap.sh）。

# 镜像内由 workflow 写入的构建参数（/root/build.env）；宿主阶段不存在该文件
if [[ -f /root/build.env ]]; then
  set -a
  # shellcheck source=/dev/null
  . /root/build.env
  set +a
fi

# ── 环境变量卫生 ────────────────────────────────────────────────────────────
# 上面的 set -a 会把 build.env 里的每一个变量导出。LANGUAGE 的哨兵值
# "None (C.UTF-8)" 带括号，一路传进 dpkg 子进程时，某些包的 preinst 会
# `eval \`locale\`` 并在括号处报语法错误，导致 --unpack 阶段失败。
# 需要哨兵值的脚本自己会用 ${LANGUAGE:-None (C.UTF-8)} 取回，这里先摘掉。
if [[ "${LANGUAGE:-}" == "None (C.UTF-8)" ]]; then
  unset LANGUAGE
fi
case "${LANG:-}" in
  *\(*|*\)*|*\;*|*\|*|*\`*) unset LANG ;;
esac
case "${LC_ALL:-}" in
  *\(*|*\)*|*\;*|*\|*|*\`*) unset LC_ALL ;;
esac
export LANG="${LANG:-C.UTF-8}"

# 默认 3.0（huanghe）：其 arm64 归档比 2.0（nile）完整得多；
# 但即便是 huanghe，公开归档也缺少量包 → 默认走 ROOTFS_SOURCE=image（见下）。
: "${DISTRO_SERIES:=huanghe}"

case "$DISTRO_SERIES" in
  nile|2.0)     DISTRO_SUITE="nile";    DEBOOTSTRAP_SCRIPT="trixie" ;;
  huanghe|3.0)  DISTRO_SUITE="huanghe"; DEBOOTSTRAP_SCRIPT="trixie" ;;
  yangtze|1.0)  DISTRO_SUITE="yangtze"; DEBOOTSTRAP_SCRIPT="bookworm" ;;
  *) echo "不支持的 openKylin 版本: $DISTRO_SERIES（可选 nile / huanghe / yangtze）" >&2; exit 1 ;;
esac
export DISTRO_SUITE
# debootstrap 用来引导的 Debian 脚本名（openKylin 未随 debootstrap 提供脚本）
export DEBOOTSTRAP_SCRIPT="${DEBOOTSTRAP_SCRIPT:-trixie}"

# 归档地址（可被环境变量覆盖，例如换更快的镜像）
export OPENKYLIN_MIRROR="${OPENKYLIN_MIRROR:-http://archive.build.openkylin.top/openkylin/}"
export OPENKYLIN_KEYRING_URL="${OPENKYLIN_KEYRING_URL:-http://archive.build.openkylin.top/openkylin/project/openkylin-archive-keyring.gpg}"
# 需要 Signed-By 时指向镜像内安装的 keyring 包路径
export OPENKYLIN_KEYRING_PATH="${OPENKYLIN_KEYRING_PATH:-/usr/share/keyrings/openkylin-archive-keyring.gpg}"
export OPENKYLIN_COMPONENTS="${OPENKYLIN_COMPONENTS:-main cross pty}"

# ── 选项 C：直接用 openKylin 官方镜像里的 rootfs ────────────────────────────
# ROOTFS_SOURCE=image：宿主 05-fetch-rootfs.sh 下载官方 arm64 桌面 ISO，解出
#   casper/filesystem.squashfs 铺进镜像。这样做绕开了公开归档缺包的问题——
#   镜像里已经是"装好的"完整 UKUI 桌面，不需要 apt 再解析依赖。
# ROOTFS_SOURCE=debootstrap：旧的从零引导路径（nile/huanghe 都会因缺包失败，
#   仅保留供归档修好后使用）。
export ROOTFS_SOURCE="${ROOTFS_SOURCE:-image}"
export OPENKYLIN_ISO_URL="${OPENKYLIN_ISO_URL:-https://cdimage.openkylin.top/3.0/openKylin-Desktop-V3.0-20260905-arm64.iso}"

log()  { printf '[%s %s] %s\n' "${0##*/}" "$(date +%T)" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "需要 root 权限（请用 sudo 调用本脚本）"
}
