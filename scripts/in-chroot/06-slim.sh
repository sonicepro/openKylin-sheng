#!/usr/bin/env bash
# 06-slim.sh —— 可选：精简掉 kylin AI/模型包（slim_kylin_ai=true 时执行）
#
# 目的：openKylin 桌面里 kylin 的 AI 子系统 + 本地模型（onnx 权重）占了数 GiB，
# 是镜像「又大又慢」的主因之一。打开 slim_kylin_ai 后卸载这批包，显著减小镜像。
#
# 可逆：卸载前记录已装包，卸载后 diff 出被移除的包，写进 /root/restore-kylin-ai.sh，
#       设备上执行即可从 openKylin 源装回（这些包在 huanghe/arm64 源里都有）。
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/ok-build/in-chroot/06-slim.sh
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

if [[ "${SLIM_KYLIN_AI:-false}" != "true" ]]; then
  log "slim_kylin_ai 未开启，跳过精简"
  exit 0
fi

PAT_FILE="$BUILD_DIR/lists/slim-kylin-ai.patterns"
[[ -f "$PAT_FILE" ]] || die "缺少 $PAT_FILE"

re="$(grep -vE '^[[:space:]]*(#|$)' "$PAT_FILE" | paste -sd'|' -)"
[[ -n "$re" ]] || die "slim-kylin-ai.patterns 为空"

# 记录当前已装包（用于事后 diff 出被移除的包）
dpkg --get-selections | awk '$2=="install"{print $1}' | sort > /tmp/installed-before.txt

mapfile -t targets < <(grep -E "$re" /tmp/installed-before.txt || true)
if [[ "${#targets[@]}" -eq 0 ]]; then
  log "没有匹配到任何 AI/模型包，跳过精简"
  exit 0
fi

log "精简：卸载 ${#targets[@]} 个 kylin AI/模型包（含其依赖会被一并移除）"
# 先用 apt purge（会自动移除依赖这些包的包，即整个 AI 栈）；失败也不致命
apt-get purge -y "${targets[@]}" || warn "purge 返回非 0（个别包可能有依赖/被占用），继续"

# diff 出被移除的包，生成恢复脚本
dpkg --get-selections | awk '$2=="install"{print $1}' | sort > /tmp/installed-after.txt
removed="$(comm -23 /tmp/installed-before.txt /tmp/installed-after.txt || true)"
if [[ -n "$removed" ]]; then
  {
    echo "#!/bin/sh"
    echo "# 本脚本由 openKylin-sheng 构建（slim_kylin_ai=true）自动生成。"
    echo "# 用途：把精简镜像里被移除的 kylin AI/模型包装回来（需联网）。"
    echo "# 用法：sudo sh /root/restore-kylin-ai.sh"
    echo "set -e"
    echo "apt-get update"
    echo "apt-get install -y \\"
    while read -r p; do [ -n "$p" ] && echo "    '$p' \\"; done <<< "$removed"
    echo "    ;"
  } > /root/restore-kylin-ai.sh
  chmod +x /root/restore-kylin-ai.sh
  log "已移除 $(echo "$removed" | grep -c . || echo 0) 个包；恢复脚本 /root/restore-kylin-ai.sh"
else
  log "没有包被真正移除"
fi

log "精简完成"
