#!/bin/bash
# autostart_mihomo.sh
# 开机自动启动 mihomo 代理（AutoDL 环境）
# 用法：将此脚本添加到 ~/.bashrc 末尾，或通过 crontab @reboot 调用
#
# 在 ~/.bashrc 中添加以下行：
#   bash /root/KimiSwarm4Manus/scripts/autostart_mihomo.sh

MIHOMO_DIR="/root/mihomo-for-autodl"
MIHOMO_BIN="$MIHOMO_DIR/mihomo_main/bin/mihomo"
MIHOMO_CONF="$MIHOMO_DIR/mihomo_main/conf"
MIHOMO_LOG="$MIHOMO_DIR/mihomo_main/logs/mihomo.log"

# 检查 mihomo 是否已在运行
if pgrep -x "mihomo" > /dev/null 2>&1; then
    echo "[autostart_mihomo] mihomo 已在运行，跳过启动"
    exit 0
fi

# 检查二进制文件是否存在
if [ ! -f "$MIHOMO_BIN" ]; then
    echo "[autostart_mihomo] 错误：mihomo 二进制文件不存在：$MIHOMO_BIN"
    exit 1
fi

echo "[autostart_mihomo] 正在启动 mihomo 代理..."
mkdir -p "$(dirname $MIHOMO_LOG)"
nohup "$MIHOMO_BIN" -d "$MIHOMO_CONF" > "$MIHOMO_LOG" 2>&1 &
sleep 2

if pgrep -x "mihomo" > /dev/null 2>&1; then
    echo "[autostart_mihomo] mihomo 启动成功（PID: $(pgrep -x mihomo)）"
    echo "[autostart_mihomo] 代理端口: 7890 (mixed), 9191 (API)"
else
    echo "[autostart_mihomo] 警告：mihomo 启动可能失败，请检查日志：$MIHOMO_LOG"
fi
