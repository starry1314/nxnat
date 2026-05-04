#!/bin/bash

# ==========================================
# Debian 11 多目標中轉工具 (UX & API 優化版)
# ==========================================

# 1. 環境檢查與基礎安裝
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 錯誤：請使用 sudo bash 執行安裝腳本。"
  exit 1
fi

echo "正在初始化環境 (nftables, dnsutils, cron)..."
# 優化軟體源與依賴安裝
sed -i 's/.*backports.*/#&/g' /etc/apt/sources.list
apt-get update -o Acquire::Check-Valid-Until=false || true
apt-get install -y nftables dnsutils cron jq  # 增加 jq 方便處理 JSON

# 強制開啟核心轉發並檢查狀態
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-forward.conf
sysctl -p /etc/sysctl.d/99-forward.conf || true
[ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 1 ] && echo "✅ 核心轉發已開啟" || echo "⚠️ 核心轉發開啟失敗，請手動檢查"

# 配置基礎結構
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
# 工具 1：nat 管理主腳本 (支援 JSON & UX 優化)
# --------------------------------------------------
cat << 'EOF' > /usr/local/bin/nat
#!/bin/bash

# 自動提權
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

# 內部函數：端口檢查
check_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "❌ 錯誤：端口 $port 不合法 (1-65535)" ; exit 1
    fi
}

case "$1" in
    add)
        # 處理參數
        if [ "$2" == "udp" ]; then
            TARGET=$3; START=$4; END=$5; MODE="UDP_DEFAULT"; PRIO=101; PREFIX="zzz_"
        else
            TARGET=$2; START=$3; END=$4; MODE="NORMAL"; PRIO=100; PREFIX=""
        fi

        # 交互式引導 (若遺漏參數)
        if [ -z "$TARGET" ] || [ -z "$START" ] || [ -z "$END" ]; then
            echo "--- 進入快速添加模式 ---"
            [ -z "$TARGET" ] && read -p "請輸入目標域名或IP: " TARGET
            [ -z "$START" ] && read -p "請輸入起始端口: " START
            [ -z "$END" ] && read -p "請輸入結束端口: " END
        fi

        check_port "$START"; check_port "$END"
        PORT_SPEC=$([ "$START" == "$END" ] && echo "$START" || echo "$START-$END")
        ID="${PREFIX}nat_${START}_${END}"

        # 解析 IP
        echo "正在解析 $TARGET ..."
        IP=$(nslookup $TARGET 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
        [ -z "$IP" ] && IP=$(getent hosts $TARGET | awk '{print $1}' | head -1)
        [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "❌ 解析失敗"; exit 1; }

        FILE="/etc/nftables.d/${ID}.nft"
        
        # 寫入規則 (優化 masquerade 與優先級)
        if [ "$MODE" == "UDP_DEFAULT" ]; then
            cat << RULE > $FILE
# TARGET: $TARGET ($IP) | MODE: UDP_DEFAULT
table inet $ID {
    chain p { type nat hook prerouting priority $PRIO; policy accept; udp dport $PORT_SPEC dnat ip to $IP; }
    chain o { type nat hook postrouting priority $PRIO; policy accept; ip daddr $IP udp dport $PORT_SPEC masquerade; }
}
RULE
        else
            cat << RULE > $FILE
# TARGET: $TARGET ($IP) | MODE: NORMAL
table inet $ID {
    chain p { type nat hook prerouting priority $PRIO; policy accept; tcp dport $PORT_SPEC dnat ip to $IP; udp dport $PORT_SPEC dnat ip to $IP; }
    chain o { type nat hook postrouting priority $PRIO; policy accept; ip daddr $IP masquerade; }
}
RULE
        fi
        
        systemctl restart nftables && echo "✅ 增加成功 ($PORT_SPEC -> $TARGET)" || { echo "❌ 重啟失敗"; nft -f /etc/nftables.conf; }
        ;;
    
    list)
        # 提供給 Web 對接的 JSON 輸出選項
        if [ "$2" == "--json" ]; then
            echo -n "["
            first=true
            for f in $(ls /etc/nftables.d/*.nft 2>/dev/null | sort); do
                [ "$first" = true ] || echo -n ","
                INFO=$(head -n 1 $f)
                NAME=$(echo $INFO | awk '{print $3}')
                IP=$(echo $INFO | awk '{print $4}')
                M=$(echo $INFO | awk -F'| MODE: ' '{print $2}')
                P_RAW=$(basename $f | sed 's/.nft//')
                [[ $P_RAW == zzz* ]] && P=$(echo $P_RAW | sed 's/zzz_nat_udp_//;s/_/-/') || P=$(echo $P_RAW | sed 's/nat_//;s/_/-/')
                echo -n "{\"mode\":\"$M\",\"port\":\"$P\",\"target\":\"$NAME\",\"ip\":\"$IP\"}"
                first=false
            done
            echo "]"
        else
            echo "=================================================================="
            printf "%-12s | %-15s | %-30s\n" "模式" "轉發端口" "目標伺服器 (DDNS)"
            echo "------------------------------------------------------------------"
            for f in $(ls /etc/nftables.d/*.nft 2>/dev/null | sort); do
                INFO=$(head -n 1 $f); N=$(echo $INFO | awk '{print $3}'); I=$(echo $INFO | awk '{print $4}'); M=$(echo $INFO | awk -F'| MODE: ' '{print $2}')
                P_RAW=$(basename $f | sed 's/.nft//')
                [[ $P_RAW == zzz* ]] && P=$(echo $P_RAW | sed 's/zzz_nat_udp_//;s/_/-/') || P=$(echo $P_RAW | sed 's/nat_//;s/_/-/')
                printf "%-12s | %-15s | %-30s\n" "$M" "$P" "$N $I"
            done
            echo "=================================================================="
        fi
        ;;

    del)
        PORT=$2
        [ -z "$PORT" ] && read -p "請輸入要刪除的起始端口: " PORT
        FILE=$(ls /etc/nftables.d/nat_${PORT}_*.nft /etc/nftables.d/zzz_nat_udp_${PORT}_*.nft 2>/dev/null | head -n 1)
        if [ -n "$FILE" ]; then 
            rm -f "$FILE"; systemctl restart nftables; echo "✅ 規則已移除"; 
        else 
            echo "❌ 找不到起始端口為 $PORT 的規則"; 
        fi
        ;;

    clean)
        # 支持 -y 參數用於 Web 自動化清理
        if [ "$2" == "-y" ]; then confirm="y"; else read -p "確定清空所有規則? (y/n): " confirm; fi
        if [ "$confirm" == "y" ]; then
            rm -f /etc/nftables.d/*.nft; nft flush ruleset; systemctl restart nftables
            echo "✅ 數據已完全清空"
        fi
        ;;

    *)
        echo "🛠️  NAT 管理工具 - 功能說明"
        echo "------------------------------------------------"
        echo "🔹 [標準轉發]  nat add [域名/IP] [起始] [結束]"
        echo "🔹 [UDP兜底]   nat add udp [域名/IP] [起始] [結束]"
        echo "🔹 [查詢列表]  nat list (Web對接請用: nat list --json)"
        echo "🔹 [移除單條]  nat del [起始端口]"
        echo "🔹 [徹底清空]  nat clean (靜默模式請加 -y)"
        echo "------------------------------------------------"
        ;;
esac
EOF

# --------------------------------------------------
# 工具 2：DDNS 監控腳本
# --------------------------------------------------
cat << 'EOF' > /usr/local/bin/nat-update
#!/bin/bash
if ls /etc/nftables.d/*.nft >/dev/null 2>&1; then
    UPDATED=0
    for f in /etc/nftables.d/*.nft; do
        TARGET=$(head -n 1 $f | awk '{print $3}')
        if [[ ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            OLD_IP=$(grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" $f | head -n 1)
            NEW_IP=$(nslookup $TARGET 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
            [ -z "$NEW_IP" ] && NEW_IP=$(getent hosts $TARGET | awk '{print $1}' | head -1)
            if [ -n "$NEW_IP" ] && [ "$OLD_IP" != "$NEW_IP" ]; then
                sed -i "s/$OLD_IP/$NEW_IP/g" $f; UPDATED=1
            fi
        fi
    done
    [ "$UPDATED" == "1" ] && systemctl restart nftables
fi
EOF

chmod +x /usr/local/bin/nat /usr/local/bin/nat-update
(crontab -l 2>/dev/null | grep -v "nat-update"; echo "* * * * * /usr/local/bin/nat-update") | crontab -

systemctl daemon-reload
systemctl restart nftables

echo "------------------------------------------------"
echo "✅ 安裝成功！直接輸入 'nat' 即可體驗優化介面"
echo "🌐 未來 Web 對接可調用: nat list --json"
echo "------------------------------------------------"
