#!/bin/bash
set -e

PORT=10086
RATE=3mbit
MAX_CONN=20

IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "网卡：$IFACE  端口：$PORT  限速：$RATE  最大并发：$MAX_CONN"

echo "配置 tc 限速..."
tc qdisc del dev $IFACE root 2>/dev/null || true
tc qdisc add dev $IFACE root handle 1: htb default 99
tc class add dev $IFACE parent 1: classid 1:1 htb rate 1000mbit
tc class add dev $IFACE parent 1:1 classid 1:10 htb rate $RATE ceil $RATE burst 64k
tc class add dev $IFACE parent 1:1 classid 1:99 htb rate 1000mbit
tc filter add dev $IFACE parent 1: protocol ip u32 match ip dport $PORT 0xffff flowid 1:10
tc filter add dev $IFACE parent 1: protocol ip u32 match ip sport $PORT 0xffff flowid 1:10
echo "tc 限速配置完成"

echo "配置 iptables 并发连接限制..."
iptables -D INPUT -p tcp --dport $PORT --syn -m connlimit --connlimit-above $MAX_CONN -j REJECT 2>/dev/null || true
iptables -A INPUT -p tcp --dport $PORT --syn -m connlimit --connlimit-above $MAX_CONN --connlimit-mask 0 -j REJECT --reject-with tcp-reset
echo "iptables 配置完成"

echo "保存 iptables 规则..."
apt-get install -y iptables-persistent -q 2>/dev/null || true
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo "配置开机自启..."
cat > /etc/tc-vpn-limit.sh << SCRIPT
#!/bin/bash
IFACE=\$(ip route get 8.8.8.8 | awk '{print \$5; exit}')
tc qdisc del dev \$IFACE root 2>/dev/null || true
tc qdisc add dev \$IFACE root handle 1: htb default 99
tc class add dev \$IFACE parent 1: classid 1:1 htb rate 1000mbit
tc class add dev \$IFACE parent 1:1 classid 1:10 htb rate 3mbit ceil 3mbit burst 64k
tc class add dev \$IFACE parent 1:1 classid 1:99 htb rate 1000mbit
tc filter add dev \$IFACE parent 1: protocol ip u32 match ip dport 10086 0xffff flowid 1:10
tc filter add dev \$IFACE parent 1: protocol ip u32 match ip sport 10086 0xffff flowid 1:10
SCRIPT
chmod +x /etc/tc-vpn-limit.sh

cat > /etc/systemd/system/tc-vpn-limit.service << SERVICE
[Unit]
Description=TC VPN Speed Limit
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/tc-vpn-limit.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable tc-vpn-limit.service

echo ""
echo "✅ 全部完成！"
echo "验证：tc qdisc show dev $IFACE"
echo "验证：iptables -L INPUT -n | grep $PORT"
