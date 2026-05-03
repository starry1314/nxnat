#!/bin/bash

# ==========================================
# Debian 11 多目標中轉工具 (最終穩定版)
# 修正：單端口語法報錯、端口防呆、每分鐘 DDNS
# ==========================================

# 1. 環境檢查與基礎安裝
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 錯誤：請使用 sudo bash 執行安裝腳本。"
  exit 1
fi

echo "正在安裝核心組件並配置環境 (nftables, dnsutils, cron)..."
# 修復軟體源 (針對阿里雲環境優化)
sed -i 's/.*backports.*/#&/g' /etc/apt/sources.list
apt-get update -o Acquire::Check-Valid-Until=false || true
apt-get install -y nftables dnsutils cron

# 強制開啟核心轉發 (中轉核心)
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-forward.conf
sysctl -p /etc/sysctl.d/99-forward.conf || true
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

# 配置 nftables 基礎結構 (徹底重置防止舊規則衝突)
mkdir -p /etc/nftables.d
cat << 'EOF' > /etc/nftables.conf
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input { type filter hook input priority 0; policy accept; }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output { type filter hook output priority 0; policy accept; }
}
include "/etc/nftables.d/*.nft"
EOF

# --------------------------------------------------
# 工具 1：nat 管理主腳本 (優化提權、防呆、單端口)
# --------------------------------------------------
cat << 'EOF' > /usr/local/bin/nat
#!/bin/bash

# 自動提權
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

# 內部函數：端口檢查 (1-65535 防呆)
check_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "❌ 錯誤：端口 $port 不合法！(必須是 1-65535 之間的數字)"
        exit 1
    fi
}

case "$1" in
    add)
        # 判斷是否為 UDP 兜底模式
        if [ "$2" == "udp" ]; then
            TARGET=$3; START=$4; END=$5; MODE="UDP_DEFAULT"
            [ -z "$END" ] && { echo "❌ 用法: nat add udp [域名/IP] [起始端口] [結束端口]"; exit 1; }
            check_port "$START"; check_port "$END"
            ID="zzz_nat_udp_${START}_${END}"
        else
            TARGET=$2; START=$3; END=$4; MODE="NORMAL"
            [ -z "$END" ] && { echo "❌ 用法: nat add [域名/IP] [起始端口] [結束端口]"; exit 1; }
            check_port "$START"; check_port "$END"
            ID="nat_${START}_${END}"
        fi

        # 端口語法優化 (修正 Range has zero or negative size 錯誤)
        if [ "$START" == "$END" ]; then
            PORT_SPEC="$START"
        else
            PORT_SPEC="$START-$END"
        fi

        # 解析 IP (支援域名與純 IP)
        echo "正在解析 $TARGET ..."
        IP=$(nslookup $TARGET 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
        [ -z "$IP" ] && IP=$(getent hosts $TARGET | awk '{print $1}' | head -1)
        if [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then 
            echo "❌ 解析失敗，請檢查域名或網路。"; exit 1; 
        fi

        FILE="/etc/nftables.d/${ID}.nft"
        
        if [ "$MODE" == "UDP_DEFAULT" ]; then
            # UDP 兜底規則 (優先級 101)
            cat << RULE > $FILE
# TARGET: $TARGET ($IP) | MODE: UDP_DEFAULT
table inet $ID {
    chain p { type nat hook prerouting priority 101; policy accept; udp dport $PORT_SPEC dnat ip to $IP; }
    chain o { type nat hook postrouting priority 101; policy accept; ip daddr $IP udp dport $PORT_SPEC masquerade; }
}
RULE
            echo "✅ 已增加動態 UDP 兜底轉發 ($PORT_SPEC -> $TARGET)"
        else
            # 標準 TCP/UDP 轉發 (優先級 100)
            cat << RULE > $FILE
# TARGET: $TARGET ($IP) | MODE: NORMAL
table inet $ID {
    chain p { type nat hook prerouting priority 100; policy accept; tcp dport $PORT_SPEC dnat ip to $IP; udp dport $PORT_SPEC dnat ip to $IP; }
    chain o { type nat hook postrouting priority 100; policy accept; ip daddr $IP masquerade; }
}
RULE
            echo "✅ 已增加標準轉發 ($PORT_SPEC -> $TARGET)"
        fi
        
        systemctl restart nftables || { echo "❌ nftables 加載失敗，正在自動診斷..."; nft -f /etc/nftables.conf; }
        ;;
    
    list)
        echo "=================================================================="
        printf "%-12s | %-15s | %-30s\n" "模式" "轉發端口" "目標伺服器 (DDNS)"
        echo "------------------------------------------------------------------"
        files=$(ls /etc/nftables.d/*.nft 2>/dev/null | sort)
        if [ -n "$files" ]; then
            for f in $files; do
                INFO=$(head -n 1 $f)
                T_NAME=$(echo $INFO | awk '{print $3}')
                T_IP=$(echo $INFO | awk '{print $4}')
                T_MODE=$(echo $INFO | awk -F'| MODE: ' '{print $2}')
                P_RAW=$(basename $f | sed 's/.nft//')
                [[ $P_RAW == zzz* ]] && P_VIEW=$(echo $P_RAW | sed 's/zzz_nat_udp_//;s/_/-/') || P_VIEW=$(echo $P_RAW | sed 's/nat_//;s/_/-/')
                printf "%-12s | %-15s | %-30s\n" "$T_MODE" "$P_VIEW" "$T_NAME $T_IP"
            done
        else
            echo "暫無任何轉發規則。"
        fi
        echo "=================================================================="
        ;;

    del)
        PORT=$2
        [ -z "$PORT" ] && { echo "❌ 用法: nat del [起始端口]"; exit 1; }
        FILE=$(ls /etc/nftables.d/nat_${PORT}_*.nft /etc/nftables.d/zzz_nat_udp_${PORT}_*.nft 2>/dev/null | head -n 1)
        if [ -n "$FILE" ]; then 
            rm -f "$FILE"; systemctl restart nftables; echo "✅ 規則已刪除。"; 
        else 
            echo "❌ 找不到以 $PORT 為起始端口的規則。"; 
        fi
        ;;

    clean)
        read -p "確定要清空所有規則並抹除舊數據嗎? (y/n): " confirm
        if [ "$confirm" == "y" ]; then
            rm -f /etc/nftables.d/*.nft
            nft flush ruleset
            systemctl restart nftables
            echo "✅ 所有轉發規則已徹底清空。"
        fi
        ;;

    *)
        echo "🛠️  NAT 中轉腳本功能說明:"
        echo "----------------------------------------------------------------"
        echo "1. 標準轉發 (TCP+UDP):"
        echo "   nat add [域名/IP] [起始端口] [結束端口]"
        echo ""
        echo "2. UDP 兜底轉發 (僅 UDP, 最低優先級):"
        echo "   nat add udp [域名/IP] [起始端口] [結束端口]"
        echo ""
        echo "3. 查看列表: nat list"
        echo "4. 刪除規則: nat del [起始端口]"
        echo "5. 徹底清空: nat clean"
        echo "----------------------------------------------------------------"
        ;;
esac
EOF

# --------------------------------------------------
# 工具 2：DDNS 監控腳本 (每分鐘檢查)
# --------------------------------------------------
cat << 'EOF' > /usr/local/bin/nat-update
#!/bin/bash
if ls /etc/nftables.d/*.nft >/dev/null 2>&1; then
    UPDATED=0
    for f in /etc/nftables.d/*.nft; do
        TARGET=$(head -n 1 $f | awk '{print $3}')
        # 跳過純 IP 目標
        if [[ ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            OLD_IP=$(grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" $f | head -n 1)
            NEW_IP=$(nslookup $TARGET 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
            [ -z "$NEW_IP" ] && NEW_IP=$(getent hosts $TARGET | awk '{print $1}' | head -1)
            if [ -n "$NEW_IP" ] && [ "$OLD_IP" != "$NEW_IP" ]; then
                sed -i "s/$OLD_IP/$NEW_IP/g" $f
                UPDATED=1
            fi
        fi
    done
    [ "$UPDATED" == "1" ] && systemctl restart nftables
fi
EOF

# 設置權限
chmod +x /usr/local/bin/nat /usr/local/bin/nat-update

# 配置 Cron 定時任務 (每分鐘執行)
(crontab -l 2>/dev/null | grep -v "nat-update"; echo "* * * * * /usr/local/bin/nat-update") | crontab -

# 初始化啟動
systemctl daemon-reload
systemctl restart nftables

echo "------------------------------------------------"
echo "✅ 終極版安裝成功！"
echo "👉 輸入 'nat' 查看指令說明"
echo "👉 DDNS 檢測頻率：每 1 分鐘"
echo "------------------------------------------------"
