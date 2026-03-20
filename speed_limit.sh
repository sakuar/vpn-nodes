#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# VPS 端口限速脚本 (基于 tc + iptables mark)
#
# 原理：
#   Xray/3X-UI 没有内建的按用户限速功能。
#   但我们可以通过 Linux traffic control (tc) 对特定端口限速。
#
# 策略（双 inbound 方案）：
#   在 3X-UI 中创建两个 inbound：
#     1. 免费 inbound (VMess, port 10086) → 限速 3Mbps
#     2. 付费 inbound (VLESS Reality, port 443) → 不限速
#
#   客户端根据用户付费状态，下发不同的节点配置（不同端口+UUID）
#   免费用户连 10086 → 自动被 tc 限速
#   付费用户连 443  → 全速
#
# 用法：
#   chmod +x speed_limit.sh
#   sudo ./speed_limit.sh setup     # 首次安装限速规则
#   sudo ./speed_limit.sh status    # 查看当前规则
#   sudo ./speed_limit.sh remove    # 移除所有限速规则
#   sudo ./speed_limit.sh set 5     # 修改限速为 5Mbps
#
# 开机自启：
#   echo "@reboot root /root/speed_limit.sh setup" >> /etc/crontab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── 配置 ──────────────────────────────────────────────────────────
IFACE="eth0"              # 网卡名，用 ip a 查看（部分 VPS 是 ens3）
FREE_PORT="10086"         # 免费 inbound 端口
RATE_MBPS="${2:-3}"       # 默认限速 3Mbps
RATE="${RATE_MBPS}mbit"
CEIL="${RATE_MBPS}mbit"
BURST="32k"

# 自动检测网卡名
detect_iface() {
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$iface" ]; then
        IFACE="$iface"
    fi
}

setup() {
    detect_iface
    echo "=== 设置限速: ${IFACE} port ${FREE_PORT} → ${RATE_MBPS}Mbps ==="

    # 清除旧规则（忽略错误）
    tc qdisc del dev $IFACE root 2>/dev/null
    iptables -t mangle -D OUTPUT -p tcp --sport $FREE_PORT -j MARK --set-mark 10 2>/dev/null
    iptables -t mangle -D OUTPUT -p udp --sport $FREE_PORT -j MARK --set-mark 10 2>/dev/null

    # 1. 创建 HTB 根 qdisc
    tc qdisc add dev $IFACE root handle 1: htb default 99

    # 2. 默认类（不限速，给付费端口和其他流量）
    tc class add dev $IFACE parent 1: classid 1:99 htb rate 1000mbit ceil 1000mbit

    # 3. 限速类（免费端口流量）
    tc class add dev $IFACE parent 1: classid 1:10 htb rate $RATE ceil $CEIL burst $BURST

    # 4. 公平队列（防止单用户占满带宽）
    tc qdisc add dev $IFACE parent 1:10 sfq perturb 10

    # 5. 用 fw filter 匹配 iptables mark
    tc filter add dev $IFACE parent 1: protocol ip prio 1 handle 10 fw flowid 1:10

    # 6. iptables 标记免费端口的出站流量
    iptables -t mangle -A OUTPUT -p tcp --sport $FREE_PORT -j MARK --set-mark 10
    iptables -t mangle -A OUTPUT -p udp --sport $FREE_PORT -j MARK --set-mark 10

    echo "=== 限速设置完成 ==="
    echo "免费端口 $FREE_PORT: ${RATE_MBPS}Mbps"
    echo "付费端口 (443 等): 不限速"
    status
}

remove() {
    detect_iface
    echo "=== 移除限速规则 ==="
    tc qdisc del dev $IFACE root 2>/dev/null
    iptables -t mangle -D OUTPUT -p tcp --sport $FREE_PORT -j MARK --set-mark 10 2>/dev/null
    iptables -t mangle -D OUTPUT -p udp --sport $FREE_PORT -j MARK --set-mark 10 2>/dev/null
    echo "=== 已移除 ==="
}

status() {
    detect_iface
    echo ""
    echo "=== tc 规则 ==="
    tc -s class show dev $IFACE
    echo ""
    echo "=== iptables mangle 标记 ==="
    iptables -t mangle -L OUTPUT -n -v | grep "mark"
}

case "$1" in
    setup)  setup ;;
    remove) remove ;;
    status) status ;;
    set)    RATE_MBPS="${2:-3}"; setup ;;
    *)
        echo "用法: $0 {setup|remove|status|set <Mbps>}"
        echo "  setup       安装限速规则 (默认 3Mbps)"
        echo "  remove      移除所有限速规则"
        echo "  status      查看当前规则"
        echo "  set 5       设置限速为 5Mbps"
        ;;
esac
