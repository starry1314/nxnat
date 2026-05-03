#!/bin/bash

# ==========================================
# Debian 11 多目標中轉工具 (動態 UDP 兜底版)
# ==========================================

if [ "$EUID" -ne 0 ]; then 
  echo "❌ 錯誤：請使用 sudo bash 執行安裝腳本。"
  exit 1
fi

echo "正在安裝核心組件並配置環境..."
sed -i 's/.*backports.*/#&/g' /etc/apt/sources.list
apt-get update -o Acquire::Check-Valid-Until=false || true
apt-get install -y nftables dnsutils cron

# 強制開啟核心轉發
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-forward.conf
sysctl -p /etc/sysctl.d/99-forward.conf || true

# 配置基礎環境
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
# 工具 1：nat 管理主腳本
# --------------------------------------------------
cat << 'EOF' > /usr/local/bin/nat
#!/bin/bash
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

case "$1" in
    add)
        # 處理動態 UDP 兜底模式: nat add udp [IP] [START] [END]
        if [ "$2" == "udp" ]; then
            TARGET=$3; START=$4; END=$5; MODE="UDP_DEFAULT"
            [ -z "$END" ] && { echo "❌ 用法: nat add udp [IP] [起始端口] [結束端口]"; exit 1; }
            ID="zzz_nat_udp_${START}_${END}" # 使用 zzz 前綴確保排序在最下面
        else
            TARGET=$2; START=$3; END=$4; MODE="NORMAL"
            [ -z "$END" ] && { echo "❌ 用法: nat add [域名/IP] [起始端口] [結束端口]"; exit 1; }
            ID="nat_${START}_${END}"
        fi

        # 解析 IP
        IP=$(nslookup $TARGET 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
        [ -z "$IP" ] && IP=$(getent hosts $TARGET | awk '{print $1}' | head -1)
        if [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "❌ 解析失敗"; exit 1; fi

        FILE="/etc/nftables.d/${ID}.nft"
        
        if [ "$MODE" == "UDP_DEFAULT" ]; then
            # 專屬 UDP 兜底規則
            cat << RULE > $FILE
# TARGET: $TARGET ($IP) | MODE: UDP_DEFAULT
table inet $ID {
    chain p {
        type nat hook prerouting priority 101; policy accept;
        udp dport $START-$END dnat ip to $IP
    }
    chain o {
        type nat hook postrouting priority 101; policy accept;
        ip daddr $IP udp dport $START-$END masquerade
    }
}
RULE
            echo "✅ 已增加動態 UDP 兜底轉發 ($START-$END -> $TARGET)"
        else
            # 一般 TCP/UDP 轉發
            cat << RULE > $FILE
# TARGET: $TARGET ($IP) | MODE: NORMAL
table inet $ID {
    chain p {
        type nat hook prerouting priority 100; policy accept;
        tcp dport $START-$END dnat ip to $IP
        udp dport $START-$END dnat ip to $IP
    }
    chain o {
        type nat hook postrouting priority 100; policy accept;
        ip daddr $IP masquerade
    }
}
RULE
            echo "✅ 已增加標準轉發 ($START-$END -> $TARGET)"
        fi
        systemctl restart nftables
        ;;
    
    list)
        echo "=================================================================="
        printf "%-12s | %-15s | %-30s\n" "模式" "轉發端口" "目標伺服器 (DDNS)"
        echo "------------------------------------------------------------------"
        # 按照字母排序讀取檔案 (zzz 開頭會自然排在最後)
        files=$(ls /etc/nftables.d/*.nft 2>/dev/null | sort)
        if [ -n "$files" ]; then
            for f in $files; do
                INFO=$(head -n 1 $f)
                TARGET_NAME=$(echo $INFO | awk '{print $3}')
                TARGET_IP=$(echo $INFO | awk '{print $4}')
                MODE=$(echo $INFO | awk -F'| MODE: ' '{print $2}')
                
                # 從檔名抓端口
                PORT_RAW=$(basename $f | sed 's/.nft//')
                if [[ $PORT_RAW == zzz* ]]; then
                    PORT=$(echo $PORT_RAW | sed 's/zzz_nat_udp_//;s/_/-/')
                else
                    PORT=$(echo $PORT_RAW | sed 's/nat_//;s/_/-/')
                fi
                
                printf "%-12s | %-15s | %-30s\n" "$MODE" "$PORT" "$TARGET_NAME $TARGET_IP"
            done
        else
            echo "暫無任何轉發規則。"
        fi
        echo "=================================================================="
        ;;

    del)
        PORT=$2
        # 同時查找標準與兜底規則
        FILE=$(ls /etc/nftables.d/nat_${PORT}_*.nft /etc/nftables.d/zzz_nat_udp_${PORT}_*.nft 2>/dev/null | head -n 1)
        if [ -n "$FILE" ]; then
            rm -f "$FILE"
            systemctl restart nftables
            echo "✅ 規則已刪除。"
        else
            echo "❌ 找不到以 $PORT 為起始端口的規則。"
        fi
        ;;

    clean)
        read -p "確定要清空所有規則嗎? (y/n): " confirm
        if [ "$confirm" == "y" ]; then
            rm -f /etc/nftables.d/*.nft
            nft flush ruleset
            systemctl restart nftables
            echo "✅ 環境已完全清空。"
        fi
        ;;

    *)
        echo "🛠️  NAT 中轉腳本功能說明:"
        echo "----------------------------------------------------------------"
        echo "1. 標準轉發 (TCP+UDP):"
        echo "   nat add [域名/IP] [起始端口] [結束端口]"
        echo ""
        echo "2. 動態 UDP 兜底轉發 (僅 UDP, 移動至規則最末端):"
        echo "   nat add udp [域名/IP] [起始端口] [結束端口]"
        echo ""
        echo "3. 查看列表 (按優先級排序):"
        echo "   nat list"
        echo ""
        echo "4. 刪除單條規則 (輸入起始端口):"
        echo "   nat del [起始端口]"
        echo ""
        echo "5. 徹底清空:"
        echo "   nat clean"
        echo "----------------------------------------------------------------"
        ;;
esac
EOF

# --------------------------------------------------
# 工具 2：DDNS 監控腳本 (每分鐘執行)
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
                sed -i "s/$OLD_IP/$NEW_IP/g" $f
                UPDATED=1
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

echo "✅ 安裝成功！請直接輸入 'nat' 查看功能說明。"
