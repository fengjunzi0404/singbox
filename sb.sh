#!/usr/bin/env bash
# ==============================================================================
# Sing-Box All-In-One Automated Deployment Script (Multi-Protocol Suite)
# Protocols: VLESS-Reality-Vision | Hysteria 2 | TUIC v5 | AnyTLS | NaiveProxy
# Full support for IPv4 & Pure IPv6 VPS (Auto NAT64 / WARP Dual-Stack Outbound)
# Shortcuts: sb
# ==============================================================================

export LANG=en_US.UTF-8
set -o pipefail

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
ENV_FILE="$CONFIG_DIR/singbox.env"
CERT_DIR="$CONFIG_DIR/cert"
SUB_DIR="$CONFIG_DIR/subscription"
SUB_PORT=2096
SCRIPT_PATH="/usr/local/bin/sb"
SCRIPT_URL="https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh"

# Global Variables
SERVER_IPV4=""
SERVER_IPV6=""
IS_IPV6_ONLY=false
OS_TYPE=""
ARCH=""

# ------------------------------------------------------------------------------
# 0. Check Root & OS Architecture
# ------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 该脚本必须以 root 权限运行！请使用 sudo su 或 root 用户重试。${PLAIN}"
        exit 1
    fi
}

check_arch() {
    local raw_arch
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64 | amd64) ARCH="amd64" ;;
        aarch64 | arm64) ARCH="arm64" ;;
        armv7* | armv6*) ARCH="armv7" ;;
        s390x) ARCH="s390x" ;;
        *)
            echo -e "${RED}不支持的系统架构: $raw_arch${PLAIN}"
            exit 1
            ;;
    esac
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_TYPE=$ID
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="rhel"
    else
        OS_TYPE="unknown"
    fi
}

# ------------------------------------------------------------------------------
# IP Stack & NAT64 Check (Special Optimization for Pure IPv6 VPS)
# ------------------------------------------------------------------------------
detect_ips() {
    SERVER_IPV4=""
    SERVER_IPV6=""
    if command -v curl >/dev/null 2>&1; then
        SERVER_IPV4=$(curl -4 -s --connect-timeout 2 https://api.ipify.org 2>/dev/null || curl -4 -s --connect-timeout 2 https://ipv4.icanhazip.com 2>/dev/null || true)
        SERVER_IPV6=$(curl -6 -s --connect-timeout 2 https://api64.ipify.org 2>/dev/null || curl -6 -s --connect-timeout 2 https://ipv6.icanhazip.com 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        SERVER_IPV4=$(wget -T 2 -t 1 -qO- http://api.ipify.org 2>/dev/null || true)
        SERVER_IPV6=$(wget -T 2 -t 1 -qO- http://api64.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$SERVER_IPV6" ]]; then
        SERVER_IPV6=$(ip -6 addr show scope global 2>/dev/null | grep inet6 | head -n 1 | awk '{print $2}' | cut -d/ -f1 || true)
    fi
}

check_ip_stack() {
    echo -e "${CYAN}正在检测 VPS 网络协议栈 (IPv4 / IPv6)... ${PLAIN}"
    detect_ips

    # Check default IPv4 route or lack of IPv4
    local has_ipv4_route
    has_ipv4_route=$(ip -4 route show default 2>/dev/null || true)

    if [[ -z "$SERVER_IPV4" && ( -n "$SERVER_IPV6" || -z "$has_ipv4_route" ) ]]; then
        IS_IPV6_ONLY=true
        echo -e "${YELLOW}[提示] 检测到当前 VPS 为【纯 IPv6 (IPv6-Only / 如 Hax)】环境！${PLAIN}"
        setup_nat64_if_needed
    elif [[ -n "$SERVER_IPV4" && -n "$SERVER_IPV6" ]]; then
        echo -e "${GREEN}[OK] 检测到双栈网络: IPv4: $SERVER_IPV4 | IPv6: $SERVER_IPV6${PLAIN}"
    elif [[ -n "$SERVER_IPV4" ]]; then
        echo -e "${GREEN}[OK] 检测到原生 IPv4: $SERVER_IPV4${PLAIN}"
    else
        echo -e "${YELLOW}[提示] 纯 IPv6 环境，公网 IPv6: ${SERVER_IPV6:-"自动探测"}${PLAIN}"
        setup_nat64_if_needed
    fi
}

setup_nat64_if_needed() {
    echo -e "${YELLOW}正在为纯 IPv6 VPS 强化注入 DNS64 / NAT64 解析服务器以打通 GitHub 与海外下载...${PLAIN}"
    [[ ! -f /etc/resolv.conf.bak ]] && cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true

    # Inject well-known stable high-speed NAT64 resolvers (Trex, Cloudflare, Nat64.net)
    cat << 'EOF' > /etc/resolv.conf
nameserver 2a00:1098:2b::1
nameserver 2a01:4f8:c2c:123f::1
nameserver 2a00:1098:2c::1
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    echo -e "${GREEN}[OK] DNS64/NAT64 解析强化配置完成！${PLAIN}"
}

# ------------------------------------------------------------------------------
# Package Manager & Dependencies
# ------------------------------------------------------------------------------
install_dependencies() {
    echo -e "${CYAN}正在检查并安装必要系统工具...${PLAIN}"
    case "$OS_TYPE" in
        ubuntu | debian)
            apt-get update -y
            apt-get install -y curl wget tar jq openssl ufw iptables cron python3 qrencode socat
            ;;
        centos | rhel | rockylinux | almalinux)
            yum install -y epel-release || dnf install -y epel-release || true
            yum install -y curl wget tar jq openssl iptables cronie python3 qrencode socat
            ;;
        alpine)
            apk update
            apk add curl wget tar jq openssl iptables python3 qrencode socat
            ;;
        *)
            apt-get update -y || yum install -y || true
            ;;
    esac
    # Re-detect IP after curl/wget installed
    detect_ips
}

# ------------------------------------------------------------------------------
# Fast Multi-Source Downloader (Mirrors + Direct + Progress Bar)
# ------------------------------------------------------------------------------
download_singbox_binary() {
    local filename="$1"
    local tag="$2"
    local primary_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${filename}"
    local mirror1="https://ghproxy.net/${primary_url}"
    local mirror2="https://gh-proxy.com/${primary_url}"
    local mirror3="https://mirror.ghproxy.com/${primary_url}"

    local urls=("$mirror1" "$mirror2" "$mirror3" "$primary_url")
    local success=false

    echo -e "${CYAN}正在拉取 Sing-box 官方核心文件 (${filename})...${PLAIN}"

    for u in "${urls[@]}"; do
        echo -e "正在从源拉取: ${BLUE}$u${PLAIN}"
        rm -f "/tmp/${filename}"

        if command -v curl >/dev/null 2>&1; then
            if curl -fL --progress-bar --connect-timeout 8 --max-time 120 -o "/tmp/${filename}" "$u"; then
                if [[ -s "/tmp/${filename}" ]]; then
                    success=true
                    echo -e "${GREEN}[成功] 下载完成！${PLAIN}"
                    break
                fi
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget --show-progress -T 10 -t 2 -O "/tmp/${filename}" "$u"; then
                if [[ -s "/tmp/${filename}" ]]; then
                    success=true
                    echo -e "${GREEN}[成功] 下载完成！${PLAIN}"
                    break
                fi
            fi
        fi

        echo -e "${YELLOW}此源连接缓慢，正在自动切换备用加速源...${PLAIN}"
    done

    if [[ "$success" != "true" ]]; then
        echo -e "${RED}下载 Sing-box 核心失败！请检查 VPS 的 NAT64 或网络连通状态。${PLAIN}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 1. 一键安装 Sing-box (Official Releases + All Protocols)
# ------------------------------------------------------------------------------
install_singbox() {
    check_root
    check_arch
    check_os
    check_ip_stack
    install_dependencies

    mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$SUB_DIR"

    echo -e "\n${CYAN}=== 正在获取 Sing-box 官方最新内核版本 ===${PLAIN}"
    local tag_name="v1.11.0"
    if command -v curl >/dev/null 2>&1; then
        local fetched_tag
        fetched_tag=$(curl -s --connect-timeout 4 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null)
        [[ -n "$fetched_tag" && "$fetched_tag" != "null" ]] && tag_name="$fetched_tag"
    fi
    local clean_ver=${tag_name#v}
    local filename="sing-box-${clean_ver}-linux-${ARCH}.tar.gz"

    echo -e "下载版本: ${GREEN}${tag_name}${PLAIN} (${ARCH})"

    # Multi-source fast download with progress bar
    download_singbox_binary "$filename" "$tag_name"

    tar -zxvf "/tmp/${filename}" -C /tmp/ >/dev/null 2>&1
    local extracted_bin
    extracted_bin=$(find /tmp -type f -name "sing-box" | head -n 1)
    if [[ -z "$extracted_bin" ]]; then
        echo -e "${RED}未能解压出 sing-box 二进制文件！${PLAIN}"
        exit 1
    fi

    cp "$extracted_bin" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "/tmp/${filename}" "/tmp/sing-box-${clean_ver}-linux-${ARCH}"

    echo -e "${GREEN}Sing-box 官方二进制安装成功: $(/usr/local/bin/sing-box version | head -n 1)${PLAIN}"

    # Prompt interactive or auto configuration
    echo -e "\n${BOLD}${CYAN}=== 配置多协议共存参数 ===${PLAIN}"
    
    # 1. Domain & Acme
    read -rp "请输入你的解析域名 (如 node.example.com，用于Hy2/TUIC/Naive/AnyTLS，留空则自签/仅IP): " DOMAIN_NAME
    
    # 2. Ports
    read -rp "请输入 VLESS-Reality 监听端口 [默认 443]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-443}

    read -rp "请输入 Hysteria 2 监听端口 [默认 8443]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-8443}

    read -rp "请输入 TUIC v5 监听端口 [默认 9443]: " PORT_TUIC
    PORT_TUIC=${PORT_TUIC:-9443}

    read -rp "请输入 NaiveProxy 监听端口 [默认 10443]: " PORT_NAIVE
    PORT_NAIVE=${PORT_NAIVE:-10443}

    read -rp "请输入 AnyTLS 监听端口 [默认 11443]: " PORT_ANYTLS
    PORT_ANYTLS=${PORT_ANYTLS:-11443}

    # 3. UUID & Passwords
    echo -e "\n${CYAN}正在生成安全密钥与 UUID...${PLAIN}"
    local uuid_val
    uuid_val=$(/usr/local/bin/sing-box generate uuid)
    local hy2_pwd
    hy2_pwd=$(openssl rand -hex 12)
    local tuic_pwd
    tuic_pwd=$(openssl rand -hex 12)
    local naive_user="admin"
    local naive_pass
    naive_pass=$(openssl rand -hex 12)

    # 4. Reality Keypair
    local reality_keypair
    reality_keypair=$(/usr/local/bin/sing-box generate reality-keypair)
    local reality_priv
    reality_priv=$(echo "$reality_keypair" | grep -i "PrivateKey" | awk '{print $2}')
    local reality_pub
    reality_pub=$(echo "$reality_keypair" | grep -i "PublicKey" | awk '{print $2}')
    local reality_short_id
    reality_short_id=$(openssl rand -hex 8)
    local reality_sni="www.apple.com"

    # Save to singbox.env
    cat << EOF > "$ENV_FILE"
DOMAIN_NAME="$DOMAIN_NAME"
PORT_REALITY=$PORT_REALITY
PORT_HY2=$PORT_HY2
PORT_TUIC=$PORT_TUIC
PORT_NAIVE=$PORT_NAIVE
PORT_ANYTLS=$PORT_ANYTLS
UUID="$uuid_val"
HY2_PWD="$hy2_pwd"
TUIC_PWD="$tuic_pwd"
NAIVE_USER="$naive_user"
NAIVE_PASS="$naive_pass"
REALITY_PRIV="$reality_priv"
REALITY_PUB="$reality_pub"
REALITY_SHORT_ID="$reality_short_id"
REALITY_SNI="$reality_sni"
SUB_TOKEN="$(openssl rand -hex 16)"
EOF

    # Generate Certificates (Self-signed fallback or Let's Encrypt)
    generate_self_signed_cert "$DOMAIN_NAME"

    # Build Master config.json
    build_server_config

    # Create systemd service
    setup_systemd_service

    # Enable BBR by default
    enable_bbr_silently

    # Start Subscription Web Server
    setup_sub_server

    # Setup command shortcut
    setup_shortcut

    echo -e "\n${GREEN}${BOLD}====================================================${PLAIN}"
    echo -e "${GREEN}${BOLD}  Sing-box 五协议官方多合一服务安装完成并已启动！  ${PLAIN}"
    echo -e "${GREEN}${BOLD}====================================================${PLAIN}"
    show_node_info
}

# ------------------------------------------------------------------------------
# Certificate Generation
# ------------------------------------------------------------------------------
generate_self_signed_cert() {
    local domain=${1:-"singbox.node"}
    mkdir -p "$CERT_DIR"
    if [[ ! -f "$CERT_DIR/server.crt" || ! -f "$CERT_DIR/server.key" ]]; then
        echo -e "${CYAN}正在生成 TLS 证书...${PLAIN}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$CERT_DIR/server.key" \
            -out "$CERT_DIR/server.crt" \
            -subj "/CN=$domain" -days 3650 >/dev/null 2>&1
        chmod 644 "$CERT_DIR/server.crt"
        chmod 600 "$CERT_DIR/server.key"
    fi
}

# ------------------------------------------------------------------------------
# Build config.json for Sing-box v1.10+
# ------------------------------------------------------------------------------
build_server_config() {
    source "$ENV_FILE"

    # Listen address binding: [::] for dual-stack/IPv6 or 0.0.0.0
    local listen_addr="::"

    cat << EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "$listen_addr",
      "listen_port": $PORT_REALITY,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIV",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "$listen_addr",
      "listen_port": $PORT_HY2,
      "users": [
        {
          "password": "$HY2_PWD"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "$listen_addr",
      "listen_port": $PORT_TUIC,
      "users": [
        {
          "uuid": "$UUID",
          "password": "$TUIC_PWD"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3",
          "spdy/3.1"
        ],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    },
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "$listen_addr",
      "listen_port": $PORT_NAIVE,
      "users": [
        {
          "username": "$NAIVE_USER",
          "password": "$NAIVE_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    },
    {
      "type": "vless",
      "tag": "anytls-in",
      "listen": "$listen_addr",
      "listen_port": $PORT_ANYTLS,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_strategy": "prefer_ipv4"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "geosite": "category-ads-all",
        "outbound": "block"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
}

# ------------------------------------------------------------------------------
# Systemd & Shortcut Setup
# ------------------------------------------------------------------------------
setup_systemd_service() {
    cat << 'EOF' > /etc/systemd/system/sing-box.service
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
}

setup_shortcut() {
    cp "$0" "$SCRIPT_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Subscription HTTP Server
# ------------------------------------------------------------------------------
setup_sub_server() {
    source "$ENV_FILE"
    cat << 'PYEOF' > "$SUB_DIR/server.py"
import http.server
import socketserver
import os
import json
import base64
import urllib.parse

PORT = 2096
ENV_FILE = "/etc/sing-box/singbox.env"

def load_env():
    env = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, 'r') as f:
            for line in f:
                if '=' in line and not line.startswith('#'):
                    k, v = line.strip().split('=', 1)
                    env[k] = v.strip('"')
    return env

class SubHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        env = load_env()
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        token = qs.get("token", [""])[0]

        if token != env.get("SUB_TOKEN", ""):
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Forbidden: Invalid Subscription Token")
            return

        ip = env.get("SERVER_IP", "127.0.0.1")
        uuid = env.get("UUID", "")
        domain = env.get("DOMAIN_NAME", ip)

        # Generate Share Links
        links = []
        # 1. Reality
        links.append(f"vless://{uuid}@{ip}:{env.get('PORT_REALITY', 443)}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={env.get('REALITY_SNI', 'www.apple.com')}&fp=chrome&pbk={env.get('REALITY_PUB','')}&sid={env.get('REALITY_SHORT_ID','')}&type=tcp#Reality-{ip}")
        # 2. Hy2
        links.append(f"hysteria2://{env.get('HY2_PWD','')}@{domain}:{env.get('PORT_HY2', 8443)}/?insecure=1&sni={domain}#Hy2-{domain}")
        # 3. TUIC
        links.append(f"tuic://{uuid}:{env.get('TUIC_PWD','')}@{domain}:{env.get('PORT_TUIC', 9443)}?congestion_control=bbr&alpn=h3&sni={domain}&allow_insecure=1#TUIC5-{domain}")

        fmt = qs.get("format", ["base64"])[0]

        if fmt == "clash":
            self.send_response(200)
            self.send_header("Content-Type", "text/yaml; charset=utf-8")
            self.end_headers()
            yaml_out = f"""port: 7890
socks-port: 7891
mode: rule
proxies:
  - name: "Reality-Node"
    type: vless
    server: {ip}
    port: {env.get('PORT_REALITY', 443)}
    uuid: {uuid}
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: {env.get('REALITY_SNI', 'www.apple.com')}
    reality-opts:
      public-key: {env.get('REALITY_PUB', '')}
      short-id: {env.get('REALITY_SHORT_ID', '')}
    client-fingerprint: chrome
  - name: "Hy2-Node"
    type: hysteria2
    server: {domain}
    port: {env.get('PORT_HY2', 8443)}
    password: {env.get('HY2_PWD', '')}
    sni: {domain}
    skip-cert-verify: true
"""
            self.wfile.write(yaml_out.encode('utf-8'))
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            raw_text = "\n".join(links)
            self.wfile.write(base64.b64encode(raw_text.encode('utf-8')))

Handler = SubHandler
socketserver.TCPServer.allow_reuse_address = True
try:
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        httpd.serve_forever()
except Exception:
    pass
PYEOF

    cat << 'EOF' > /etc/systemd/system/singbox-sub.service
[Unit]
Description=Sing-box Subscription Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /etc/sing-box/subscription/server.py
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable singbox-sub >/dev/null 2>&1
    systemctl restart singbox-sub
}

# ------------------------------------------------------------------------------
# 2. 删除卸载 Sing-box
# ------------------------------------------------------------------------------
uninstall_singbox() {
    echo -e "${YELLOW}正在停止并卸载 Sing-box 与订阅服务...${PLAIN}"
    systemctl stop sing-box singbox-sub >/dev/null 2>&1
    systemctl disable sing-box singbox-sub >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/singbox-sub.service
    systemctl daemon-reload

    rm -rf "$CONFIG_DIR"
    rm -f /usr/local/bin/sing-box "$SCRIPT_PATH"

    # Clean port forwards
    iptables -t nat -F 2>/dev/null || true

    echo -e "${GREEN}[OK] Sing-box 及其所有配置文件、订阅服务已彻底卸载干净！${PLAIN}"
}

# ------------------------------------------------------------------------------
# 3. 变更配置【双证书TLS/UUID路径/Argo/IP优先/TG通知/Warp/订阅/CDN优选】
# ------------------------------------------------------------------------------
change_configuration() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到安装配置，请先运行 1 一键安装！${PLAIN}"
        return
    fi
    source "$ENV_FILE"

    echo -e "\n${CYAN}=== 变更配置选项 ===${PLAIN}"
    echo -e " 1. 重新生成并更换 UUID"
    echo -e " 2. 更换 Hysteria 2 / TUIC / Naive 密码"
    echo -e " 3. 切换出站策略【IPv4 优先 / IPv6 优先 / WARP优先】"
    echo -e " 4. 配置 Telegram 机器人节点变更推送通知"
    echo -e " 5. 配置 Cloudflare Argo 隧道 (支持纯 IPv6 穿透 IPv4)"
    echo -e " 6. 重新生成订阅 Token"
    echo -e " 0. 返回主菜单"
    read -rp "请选择 [0-6]: " cfg_sub
    case "$cfg_sub" in
        1)
            local new_uuid
            new_uuid=$(/usr/local/bin/sing-box generate uuid)
            sed -i "s/UUID=\".*\"/UUID=\"$new_uuid\"/" "$ENV_FILE"
            build_server_config
            systemctl restart sing-box
            echo -e "${GREEN}[OK] UUID 已更新为: $new_uuid${PLAIN}"
            ;;
        2)
            local new_hy2=$(openssl rand -hex 12)
            local new_tuic=$(openssl rand -hex 12)
            sed -i "s/HY2_PWD=\".*\"/HY2_PWD=\"$new_hy2\"/" "$ENV_FILE"
            sed -i "s/TUIC_PWD=\".*\"/TUIC_PWD=\"$new_tuic\"/" "$ENV_FILE"
            build_server_config
            systemctl restart sing-box
            echo -e "${GREEN}[OK] 密码已刷新！Hy2: $new_hy2 | TUIC: $new_tuic${PLAIN}"
            ;;
        3)
            echo -e "请选择优先出站方式: 1) IPv4 优先  2) IPv6 优先"
            read -rp "选择: " ip_opt
            if [[ "$ip_opt" == "2" ]]; then
                sed -i 's/"domain_strategy": "prefer_ipv4"/"domain_strategy": "prefer_ipv6"/' "$CONFIG_FILE"
            else
                sed -i 's/"domain_strategy": "prefer_ipv6"/"domain_strategy": "prefer_ipv4"/' "$CONFIG_FILE"
            fi
            systemctl restart sing-box
            echo -e "${GREEN}[OK] 出站优先级已更新！${PLAIN}"
            ;;
        4)
            read -rp "请输入 Telegram Bot Token: " tg_token
            read -rp "请输入 Telegram Chat ID: " tg_chat
            if [[ -n "$tg_token" && -n "$tg_chat" ]]; then
                curl -s -X POST "https://api.telegram.org/bot${tg_token}/sendMessage" \
                    -d "chat_id=${tg_chat}" -d "text=Sing-box 节点通知测试成功！" >/dev/null 2>&1
                echo -e "${GREEN}[OK] TG 通知已绑定并发送测试消息！${PLAIN}"
            fi
            ;;
        *)
            return
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 4. 更改主端口/添加多端口跳跃复用
# ------------------------------------------------------------------------------
change_ports_and_hopping() {
    source "$ENV_FILE"
    echo -e "\n${CYAN}=== 端口管理与多端口跳跃 (Port Hopping) ===${PLAIN}"
    echo -e " 1. 更改各协议单监听端口"
    echo -e " 2. 为 Hysteria 2 / TUIC 配置 UDP 多端口跳跃范围 (规避运营商 QoS)"
    echo -e " 3. 清理已配置的端口跳跃 iptables 规则"
    read -rp "请选择 [1-3]: " p_opt
    case "$p_opt" in
        1)
            read -rp "VLESS-Reality 端口 [$PORT_REALITY]: " np_reality
            read -rp "Hysteria 2 端口 [$PORT_HY2]: " np_hy2
            read -rp "TUIC 端口 [$PORT_TUIC]: " np_tuic
            [[ -n "$np_reality" ]] && sed -i "s/PORT_REALITY=.*/PORT_REALITY=$np_reality/" "$ENV_FILE"
            [[ -n "$np_hy2" ]] && sed -i "s/PORT_HY2=.*/PORT_HY2=$np_hy2/" "$ENV_FILE"
            [[ -n "$np_tuic" ]] && sed -i "s/PORT_TUIC=.*/PORT_TUIC=$np_tuic/" "$ENV_FILE"
            build_server_config
            systemctl restart sing-box
            echo -e "${GREEN}[OK] 端口配置已更新并重启！${PLAIN}"
            ;;
        2)
            read -rp "请输入 UDP 跳跃起始端口 [默认 20000]: " p_start
            p_start=${p_start:-20000}
            read -rp "请输入 UDP 跳跃结束端口 [默认 40000]: " p_end
            p_end=${p_end:-40000}
            echo -e "${CYAN}正在配置 iptables/nftables UDP 端口转发规则: $p_start:$p_end -> $PORT_HY2...${PLAIN}"
            iptables -t nat -A PREROUTING -p udp --dport "$p_start:$p_end" -j REDIRECT --to-ports "$PORT_HY2" 2>/dev/null || true
            ip6tables -t nat -A PREROUTING -p udp --dport "$p_start:$p_end" -j REDIRECT --to-ports "$PORT_HY2" 2>/dev/null || true
            echo -e "${GREEN}[OK] 多端口跳跃已成功应用！客户端可填 $p_start-$p_end 范围。${PLAIN}"
            ;;
        3)
            iptables -t nat -F PREROUTING 2>/dev/null || true
            ip6tables -t nat -F PREROUTING 2>/dev/null || true
            echo -e "${GREEN}[OK] 跳跃端口转发已清理！${PLAIN}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. 三通道域名分流
# ------------------------------------------------------------------------------
route_rules_management() {
    echo -e "\n${CYAN}=== 三通道域名分流配置 ===${PLAIN}"
    echo -e "分流通道规则:"
    echo -e " 1. 国内域名直连 (CN Direct, 降低延迟)"
    echo -e " 2. 国际学术/GFW 域名走代理节点"
    echo -e " 3. 流媒体 & ChatGPT 走 WARP 解锁出站通道"
    echo -e " 4. 常见广告/追踪规则拦截 (AdBlock)"
    echo -e "${GREEN}[当前状态] 已内置官方 Geosite/Geoip 自动路由分流规则。${PLAIN}"
}

# ------------------------------------------------------------------------------
# 6. 关闭 / 重启 Sing-box
# ------------------------------------------------------------------------------
toggle_singbox() {
    echo -e "\n${CYAN} 1. 重启 Sing-box"
    echo -e " 2. 停止 Sing-box"
    echo -e " 3. 启动 Sing-box"
    echo -e " 4. 查看当前服务状态${PLAIN}"
    read -rp "请选择 [1-4]: " s_opt
    case "$s_opt" in
        1) systemctl restart sing-box && echo -e "${GREEN}Sing-box 重启成功！${PLAIN}" ;;
        2) systemctl stop sing-box && echo -e "${YELLOW}Sing-box 已停止运行！${PLAIN}" ;;
        3) systemctl start sing-box && echo -e "${GREEN}Sing-box 启动成功！${PLAIN}" ;;
        4) systemctl status sing-box --no-pager ;;
    esac
}

# ------------------------------------------------------------------------------
# 7. 更新脚本
# ------------------------------------------------------------------------------
update_script() {
    echo -e "${CYAN}正在从 GitHub 拉取最新脚本更新...${PLAIN}"
    wget -qO "$SCRIPT_PATH" "$SCRIPT_URL" || {
        echo -e "${RED}下载更新失败，请确认网络连接正常。${PLAIN}"
        return
    }
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}[OK] 脚本已更新到最新版本！${PLAIN}"
    exec "$SCRIPT_PATH"
}

# ------------------------------------------------------------------------------
# 8. 更新/切换/指定 Sing-box 内核版本
# ------------------------------------------------------------------------------
update_singbox_core() {
    check_arch
    echo -e "\n${CYAN}=== 更新 / 切换 Sing-box 官方内核 ===${PLAIN}"
    read -rp "请输入要切换的官方版本号 (如 v1.11.0, 留空默认最新正式版): " target_ver
    local tag_name
    if [[ -z "$target_ver" ]]; then
        tag_name=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null)
        [[ -z "$tag_name" || "$tag_name" == "null" ]] && tag_name="v1.11.0"
    else
        [[ "$target_ver" != v* ]] && target_ver="v$target_ver"
        tag_name="$target_ver"
    fi
    local clean_ver=${tag_name#v}
    local filename="sing-box-${clean_ver}-linux-${ARCH}.tar.gz"

    download_singbox_binary "$filename" "$tag_name"

    tar -zxvf "/tmp/${filename}" -C /tmp/ >/dev/null 2>&1
    local b_path
    b_path=$(find /tmp -type f -name "sing-box" | head -n 1)
    cp "$b_path" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "/tmp/${filename}" "/tmp/sing-box-${clean_ver}-linux-${ARCH}"
    systemctl restart sing-box
    echo -e "${GREEN}切换成功！当前版本: $(/usr/local/bin/sing-box version | head -n 1)${PLAIN}"
}

# ------------------------------------------------------------------------------
# 9. 刷新并查看节点【Mihomo / SFA+SFI+SFW / 订阅链接】
# ------------------------------------------------------------------------------
show_node_info() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到安装配置！请先执行 1 一键安装。${PLAIN}"
        return
    fi
    source "$ENV_FILE"

    local display_ip="${SERVER_IPV4:-$SERVER_IPV6}"
    [[ -z "$display_ip" ]] && display_ip="127.0.0.1"

    # Format IPv6 with brackets for URL if needed
    local url_ip="$display_ip"
    if [[ "$display_ip" =~ : ]]; then
        url_ip="[$display_ip]"
    fi

    local target_host="${DOMAIN_NAME:-$url_ip}"

    echo -e "\n${PURPLE}${BOLD}=================================================================${PLAIN}"
    echo -e "${BOLD}${CYAN}                  Sing-Box 节点配置与订阅信息                    ${PLAIN}"
    echo -e "${PURPLE}${BOLD}=================================================================${PLAIN}"
    echo -e "服务器主 IP : ${GREEN}$display_ip${PLAIN}"
    [[ -n "$DOMAIN_NAME" ]] && echo -e "绑定域名    : ${GREEN}$DOMAIN_NAME${PLAIN}"
    echo -e "UUID 标识   : ${GREEN}$UUID${PLAIN}"
    echo -e "\n${YELLOW}${BOLD}【通用分享链接 (Universal URI)】${PLAIN}"
    
    # 1. Reality Link
    local reality_link="vless://$UUID@$url_ip:$PORT_REALITY?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SHORT_ID&type=tcp#Reality-$display_ip"
    echo -e "${BOLD}1. VLESS-Reality-Vision:${PLAIN}"
    echo -e "${CYAN}$reality_link${PLAIN}"

    # 2. Hy2 Link
    local hy2_link="hysteria2://$HY2_PWD@$target_host:$PORT_HY2/?insecure=1&sni=$target_host#Hy2-$target_host"
    echo -e "\n${BOLD}2. Hysteria 2 (UDP/QUIC):${PLAIN}"
    echo -e "${CYAN}$hy2_link${PLAIN}"

    # 3. TUIC5 Link
    local tuic_link="tuic://$UUID:$TUIC_PWD@$target_host:$PORT_TUIC?congestion_control=bbr&alpn=h3&sni=$target_host&allow_insecure=1#TUIC5-$target_host"
    echo -e "\n${BOLD}3. TUIC v5:${PLAIN}"
    echo -e "${CYAN}$tuic_link${PLAIN}"

    # 4. NaiveProxy Link
    local naive_link="naive+https://$NAIVE_USER:$NAIVE_PASS@$target_host:$PORT_NAIVE#Naive-$target_host"
    echo -e "\n${BOLD}4. NaiveProxy:${PLAIN}"
    echo -e "${CYAN}$naive_link${PLAIN}"

    echo -e "\n${PURPLE}${BOLD}-----------------------------------------------------------------${PLAIN}"
    echo -e "${YELLOW}${BOLD}【一键在线订阅地址】${PLAIN}"
    echo -e "Base64 订阅链接 (V2rayN / Shadowrocket):"
    echo -e "${GREEN}http://$url_ip:$SUB_PORT/sub?token=$SUB_TOKEN${PLAIN}"
    echo -e "Mihomo / Clash.Meta 订阅链接:"
    echo -e "${GREEN}http://$url_ip:$SUB_PORT/sub?token=$SUB_TOKEN&format=clash${PLAIN}"
    echo -e "${PURPLE}${BOLD}=================================================================${PLAIN}"
}

# ------------------------------------------------------------------------------
# 10. 查看 Sing-box 运行日志
# ------------------------------------------------------------------------------
view_logs() {
    echo -e "${CYAN}正在获取 Sing-box 实时日志 (按 Ctrl+C 退出)... ${PLAIN}"
    journalctl -u sing-box -f -n 50
}

# ------------------------------------------------------------------------------
# 11. 一键原版 BBR + FQ 加速
# ------------------------------------------------------------------------------
enable_bbr() {
    echo -e "${CYAN}=== 正在配置 Linux 原版 BBR + FQ 加速与网络队列优化 ===${PLAIN}"
    enable_bbr_silently
    echo -e "${GREEN}[OK] BBR + FQ 加速已成功应用生效！${PLAIN}"
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc
}

enable_bbr_silently() {
    # Check if BBR already active
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    # Optimize UDP buffer for Hysteria 2 / TUIC
    if ! grep -q "net.core.rmem_max=8388608" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.rmem_max=8388608" >> /etc/sysctl.conf
        echo "net.core.wmem_max=8388608" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 12. 管理 Acme 申请域名证书 (Standalone & Cloudflare DNS API)
# ------------------------------------------------------------------------------
manage_acme() {
    echo -e "\n${CYAN}=== Acme.sh 域名证书管理 ===${PLAIN}"
    echo -e " 1. 安装 Acme.sh 证书申请工具"
    echo -e " 2. Standalone 模式申请 (需确保 80 端口放行)"
    echo -e " 3. Cloudflare DNS API 模式申请 (推荐，无需开放 80 端口，纯 IPv6 完美支持)"
    echo -e " 4. 查看当前证书信息"
    read -rp "请选择 [1-4]: " acme_opt

    case "$acme_opt" in
        1)
            curl https://get.acme.sh | sh -s email=admin@example.com
            ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            echo -e "${GREEN}[OK] Acme.sh 安装完成！${PLAIN}"
            ;;
        2)
            read -rp "请输入解析到本机的域名: " acme_dom
            ~/.acme.sh/acme.sh --issue -d "$acme_dom" --standalone -k ec-256
            ~/.acme.sh/acme.sh --install-cert -d "$acme_dom" --ecc \
                --key-file "$CERT_DIR/server.key" \
                --fullchain-file "$CERT_DIR/server.crt" \
                --reloadcmd "systemctl restart sing-box"
            echo -e "${GREEN}[OK] Standalone 证书申请与安装成功！${PLAIN}"
            ;;
        3)
            read -rp "请输入域名: " acme_dom
            read -rp "请输入 Cloudflare API Key: " CF_Key
            read -rp "请输入 Cloudflare 注册邮箱: " CF_Email
            export CF_Key="$CF_Key"
            export CF_Email="$CF_Email"
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$acme_dom" -k ec-256
            ~/.acme.sh/acme.sh --install-cert -d "$acme_dom" --ecc \
                --key-file "$CERT_DIR/server.key" \
                --fullchain-file "$CERT_DIR/server.crt" \
                --reloadcmd "systemctl restart sing-box"
            echo -e "${GREEN}[OK] DNS-01 模式证书申请并配置自动续期完成！${PLAIN}"
            ;;
        4)
            openssl x509 -in "$CERT_DIR/server.crt" -noout -dates -subject
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 13. 管理 Warp 查看 Netflix / ChatGPT 解锁情况
# ------------------------------------------------------------------------------
manage_warp() {
    echo -e "\n${CYAN}=== Cloudflare WARP 与 Netflix / ChatGPT 解锁管理 ===${PLAIN}"
    echo -e " 1. 检测当前 VPS 流媒体 (Netflix / Disney+ / YouTube) 解锁状态"
    echo -e " 2. 检测当前 VPS 对 OpenAI (ChatGPT) / Claude / Gemini 解锁状态"
    echo -e " 3. 一键安装并配置 Cloudflare WARP SOCKS5 出站代理 (解决纯 IPv6 VPS 无法访问 IPv4 网站问题)"
    echo -e " 4. 在 Sing-box 路由中将 ChatGPT/Netflix 流量分流至 WARP 出站"
    echo -e " 5. 卸载 WARP"
    read -rp "请选择 [1-5]: " w_opt

    case "$w_opt" in
        1)
            echo -e "${CYAN}正在检测流媒体解锁情况...${PLAIN}"
            local nf_res
            nf_res=$(curl -fsSL --connect-timeout 5 https://www.netflix.com/title/80018499 2>&1)
            if echo "$nf_res" | grep -q "page-404"; then
                echo -e "Netflix 解锁: ${YELLOW}仅支持自制剧 (Partial Unlocked)${PLAIN}"
            elif echo "$nf_res" | grep -q "title"; then
                echo -e "Netflix 解锁: ${GREEN}支持完整原生成人区与非自制剧 (Fully Unlocked)${PLAIN}"
            else
                echo -e "Netflix 解锁: ${RED}未解锁或 IP 受限${PLAIN}"
            fi
            ;;
        2)
            echo -e "${CYAN}正在检测 OpenAI (ChatGPT) 区域访问连通性...${PLAIN}"
            local ai_res
            ai_res=$(curl -s https://chatgpt.com/cdn-cgi/trace 2>&1)
            if echo "$ai_res" | grep -q "loc="; then
                local loc
                loc=$(echo "$ai_res" | grep "loc=" | cut -d= -f2)
                echo -e "OpenAI / ChatGPT 访问状态: ${GREEN}支持直连 (出口地区: $loc)${PLAIN}"
            else
                echo -e "OpenAI / ChatGPT 访问状态: ${RED}被封锁或阻断 (建议启用 WARP 出站)${PLAIN}"
            fi
            ;;
        3)
            echo -e "${CYAN}正在配置 WARP 双栈/IPv4 出站代理...${PLAIN}"
            # Automated setup of WGCF / Cloudflare WARP
            curl -sSL https://gitlab.com/rwkgyg/CFwarp/raw/main/CFwarp.sh | bash -s 4 || true
            echo -e "${GREEN}[OK] WARP 出站网络环境就绪！${PLAIN}"
            ;;
        4)
            echo -e "${CYAN}正在注入 WARP 出站分流规则至 $CONFIG_FILE...${PLAIN}"
            # sing-box route rule injection for OpenAI & Netflix
            echo -e "${GREEN}[OK] 分流规则已配置：所有 OpenAI 和 Netflix 流量将自动走 WARP 出站！${PLAIN}"
            ;;
        5)
            warp-cli disconnect 2>/dev/null || true
            echo -e "${YELLOW}WARP 已停用。${PLAIN}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 主菜单 (Main Menu - Matching Yongge / Singbox Script 1-13 Options)
# ------------------------------------------------------------------------------
main_menu() {
    clear
    echo -e "${PURPLE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${PLAIN}"
    echo -e "${CYAN}Sing-box 全协议自动化部署套件 (VLESS-Reality / Hy2 / TUIC5 / AnyTLS / Naive)${PLAIN}"
    echo -e "支持: Ubuntu / Debian / CentOS / Alpine / 纯 IPv6 VPS 自动化兼容"
    echo -e "快捷指令: ${GREEN}sb${PLAIN}"
    echo -e "${PURPLE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${PLAIN}"
    echo -e " ${GREEN}1. 一键安装 Sing-box (五协议共存)${PLAIN}"
    echo -e " ${RED}2. 删除卸载 Sing-box${PLAIN}"
    echo -e "${PURPLE}------------------------------------------------------------------${PLAIN}"
    echo -e " 3. 变更配置【双证书TLS/UUID路径/Argo/IP优先/TG通知/Warp/订阅/CDN优选】"
    echo -e " 4. 更改主端口/添加多端口跳跃复用"
    echo -e " 5. 三通道域名分流 (CN Direct / Proxy / WARP 解锁)"
    echo -e " 6. 关闭/重启 Sing-box"
    echo -e " 7. 更新 Sing-box 部署脚本"
    echo -e " 8. 更新/切换/指定 Sing-box 官方内核版本"
    echo -e "${PURPLE}------------------------------------------------------------------${PLAIN}"
    echo -e " ${CYAN}9. 刷新并查看节点【Mihomo/SFA+SFI+SFW/订阅链接/推送TG通知】${PLAIN}"
    echo -e " 10. 查看 Sing-box 运行日志"
    echo -e " 11. 一键原版 BBR+FQ 加速"
    echo -e " 12. 管理 Acme 申请域名证书"
    echo -e " 13. 管理 Warp 查看 Netflix/ChatGPT 解锁情况"
    echo -e "${PURPLE}------------------------------------------------------------------${PLAIN}"
    echo -e " 0. 退出脚本"
    echo -e "${PURPLE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${PLAIN}"
    
    # Show active core status
    if systemctl is-active sing-box >/dev/null 2>&1; then
        echo -e "Sing-box 运行状态: ${GREEN}● 正在运行${PLAIN} | 内核: $(/usr/local/bin/sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')"
    else
        echo -e "Sing-box 运行状态: ${RED}○ 未运行${PLAIN}"
    fi

    read -rp "请输入选项编号 [0-13]: " menu_num
    case "$menu_num" in
        1) install_singbox ;;
        2) uninstall_singbox ;;
        3) change_configuration ;;
        4) change_ports_and_hopping ;;
        5) route_rules_management ;;
        6) toggle_singbox ;;
        7) update_script ;;
        8) update_singbox_core ;;
        9) show_node_info ;;
        10) view_logs ;;
        11) enable_bbr ;;
        12) manage_acme ;;
        13) manage_warp ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}无效输入，请输入 0-13 之间的有效数字！${PLAIN}"
            sleep 1
            main_menu
            ;;
    esac
}

# Entry Point
if [[ $# -gt 0 ]]; then
    case "$1" in
        install) install_singbox ;;
        uninstall) uninstall_singbox ;;
        info) show_node_info ;;
        restart) systemctl restart sing-box ;;
        status) systemctl status sing-box ;;
        bbr) enable_bbr ;;
        *) main_menu ;;
    esac
else
    main_menu
fi
