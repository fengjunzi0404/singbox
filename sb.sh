#!/usr/bin/env bash
# ==============================================================================
# SingBox Suite Pro — 极速轻量全协议聚合部署运维套件 (All-In-One 单脚本自包含版)
# 协议支持: VLESS-Reality-Vision | Hysteria 2 | TUIC v5 | AnyTLS | NaiveProxy (Acme证书激活)
# 核心特性:
#   1. 极速响应架构: 缓存网络栈状态与本地 IP 检测，告别每次进菜单或看节点的卡顿等待
#   2. 默认部署四协议免域名直连 (Reality / Hy2 / TUIC5 / AnyTLS)，采用 15000-59999 高位随机端口
#   3. NaiveProxy 采用正规 Acme.sh 域名证书机制：只要在菜单【选项 6】申请好证书，即自动开启 Naive 入站并生成节点链接与订阅
#   4. 标准化 HTTP/1.1 [::] 双栈订阅服务：带 Content-Length 与 Connection: close，完美适配 Karing / v2rayN / Shadowrocket / Clash
# 致敬与特别鸣谢: 本脚本基于并深度修改自 ygkkk (甬哥) 与 fscarmen (F佬) 的开源项目！
# 仓库地址: https://github.com/fengjunzi0404/singbox
# ==============================================================================

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PURPLE="\033[35m"
BOLD="\033[1m"
PLAIN="\033[0m"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
ENV_FILE="${CONFIG_DIR}/singbox.env"
CERT_DIR="${CONFIG_DIR}/cert"
SUB_DIR="${CONFIG_DIR}/subscription"
BIN_PATH="/usr/local/bin/sing-box"
SHORTCUT_PATH="/usr/local/bin/sb"
REPO_RAW_URL="https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh"
DEFAULT_SB_VER="1.14.4"

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 请使用 root 用户运行此脚本 (sudo -i)！${PLAIN}"
        exit 1
    fi
}

# 检测系统架构
check_arch() {
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            echo -e "${RED}[错误] 不支持的 CPU 架构: $(uname -m)${PLAIN}"
            exit 1
            ;;
    esac
}

# 极速网络栈检测：优先读取已保存的 ENV 或本地网卡地址，毫秒级响应不卡顿
detect_network() {
    local force_refresh="${1:-0}"
    if [[ "$force_refresh" == "0" && -f "$ENV_FILE" ]]; then
        source "$ENV_FILE" 2>/dev/null || true
        if [[ -n "$SERVER_IP" && "$SERVER_IP" != "127.0.0.1" ]]; then
            if [[ -n "$SERVER_IPV4" && -n "$SERVER_IPV6" ]]; then
                NET_STACK="IPv4 + IPv6 双栈 VPS"
            elif [[ -n "$SERVER_IPV6" || "$SERVER_IP" == *":"* ]]; then
                NET_STACK="纯 IPv6 VPS (NAT64)"
            else
                NET_STACK="纯 IPv4 VPS"
            fi
            return
        fi
    fi

    # 优先从本机公网网卡直接提取 (0ms 瞬时完成)
    IPV4_ADDR=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.)' | head -n 1)
    IPV6_ADDR=$(ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -vE 'fe80|^\s*inet6 fd|^\s*inet6 fc' | head -n 1 | awk '{print $2}' | cut -d/ -f1)

    # 若网卡为 NAT 映射，再用 1.5 秒短超时探测
    if [[ -z "$IPV4_ADDR" && -z "$IPV6_ADDR" ]]; then
        IPV6_ADDR=$(curl -s6m2 https://api64.ipify.org 2>/dev/null | tr -d '\n')
        IPV4_ADDR=$(curl -s4m2 https://api.ipify.org 2>/dev/null | tr -d '\n')
    fi

    if [[ -z "$IPV4_ADDR" && -n "$IPV6_ADDR" ]]; then
        NET_STACK="纯 IPv6 VPS (NAT64)"
        SERVER_IP="$IPV6_ADDR"
        OUTBOUND_STRATEGY="prefer_ipv6"
    elif [[ -n "$IPV4_ADDR" && -n "$IPV6_ADDR" ]]; then
        NET_STACK="IPv4 + IPv6 双栈 VPS"
        SERVER_IP="$IPV4_ADDR"
        OUTBOUND_STRATEGY="prefer_ipv4"
    elif [[ -n "$IPV4_ADDR" ]]; then
        NET_STACK="纯 IPv4 VPS"
        SERVER_IP="$IPV4_ADDR"
        OUTBOUND_STRATEGY="prefer_ipv4"
    else
        NET_STACK="未知网络"
        SERVER_IP="127.0.0.1"
        OUTBOUND_STRATEGY="prefer_ipv6"
    fi
}

# 为纯 IPv6 VPS 注入高可用 NAT64/DNS64 解析
setup_nat64_dns() {
    detect_network "1"
    if [[ -z "$IPV4_ADDR" && -n "$IPV6_ADDR" ]]; then
        if ! grep -q "2a00:1098:2b::1" /etc/resolv.conf 2>/dev/null; then
            echo -e "${YELLOW}[提示] 检测到纯 IPv6 环境，正在配置 DNS64/NAT64 解析...${PLAIN}"
            cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            cat << 'EOF' > /etc/resolv.conf
nameserver 2a00:1098:2b::1
nameserver 2a01:4f8:c2c:123f::1
nameserver 2a00:1098:2c::1
nameserver 2606:4700:4700::1111
EOF
        fi
    fi
}

# 生成互不冲突的随机高位端口 (15000-59999)
gen_random_port() {
    local port
    while true; do
        port=$(shuf -i 15000-59999 -n 1 2>/dev/null || echo $((RANDOM % 45000 + 15000)))
        if ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# 按需安装依赖 (已存在则直接跳过，大幅提速)
install_deps() {
    local missing=0
    for cmd in curl wget tar openssl python3 socat; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done
    if [[ $missing -eq 0 ]]; then
        return
    fi
    echo -e "${BLUE}正在补充安装必要系统组件 (curl / wget / tar / openssl / python3 / socat)...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar jq openssl ufw iptables cron python3 socat procps >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar jq openssl iptables python3 socat procps-ng >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1
        apk add bash curl wget tar jq openssl iptables python3 socat procps >/dev/null 2>&1
    fi
}

# 下载并安装官方 Sing-box v1.14.4 核心 (若已安装同版本则秒过)
install_singbox_binary() {
    local target_ver="${1:-$DEFAULT_SB_VER}"
    local force_dl="${2:-0}"
    if [[ "$force_dl" == "0" && -x "$BIN_PATH" ]]; then
        local cur_ver
        cur_ver=$("$BIN_PATH" version 2>/dev/null | head -n 1 | awk '{print $3}')
        if [[ "$cur_ver" == "$target_ver" ]]; then
            echo -e "${GREEN}[极速跳过] 已安装 Sing-box v${cur_ver}，无需重复下载内核！${PLAIN}"
            return
        fi
    fi

    echo -e "${BLUE}=== 正在下载 Sing-box 官方内核 v${target_ver} (${ARCH}) ===${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true

    local tarball="sing-box-${target_ver}-linux-${ARCH}.tar.gz"
    local urls=(
        "https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/${tarball}"
        "https://gh-proxy.com/https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/${tarball}"
        "https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/${tarball}"
    )

    rm -rf /tmp/sb_dl && mkdir -p /tmp/sb_dl
    local dl_ok=0
    for url in "${urls[@]}"; do
        echo -e "正在拉取内核源: ${url}"
        if curl -fsSL --connect-timeout 6 --max-time 90 "$url" -o "/tmp/sb_dl/${tarball}"; then
            dl_ok=1
            break
        fi
    done

    if [[ $dl_ok -eq 0 ]]; then
        echo -e "${RED}[错误] Sing-box 内核下载失败，请检查 VPS 网络连接！${PLAIN}"
        exit 1
    fi

    tar -zxvf "/tmp/sb_dl/${tarball}" -C /tmp/sb_dl >/dev/null 2>&1
    local extracted_bin extracted_cronet
    extracted_bin=$(find /tmp/sb_dl -name "sing-box" -type f | head -n 1)
    extracted_cronet=$(find /tmp/sb_dl -name "libcronet.so" -type f | head -n 1)

    rm -f "$BIN_PATH"
    cp -f "$extracted_bin" "$BIN_PATH"
    chmod +x "$BIN_PATH"

    if [[ -n "$extracted_cronet" && -f "$extracted_cronet" ]]; then
        cp -f "$extracted_cronet" /usr/local/bin/libcronet.so 2>/dev/null || true
        cp -f "$extracted_cronet" /usr/local/lib/libcronet.so 2>/dev/null || true
        cp -f "$extracted_cronet" /usr/lib/libcronet.so 2>/dev/null || true
        ldconfig 2>/dev/null || true
    fi

    rm -rf /tmp/sb_dl
    echo -e "${GREEN}[成功] Sing-box 内核就绪: $($BIN_PATH version 2>/dev/null | head -n 1)${PLAIN}"
}

# 生成常规自签名证书 (供 Hysteria2 / TUIC5 / AnyTLS 免域名使用)
generate_self_signed_cert() {
    local tls_sni="${1:-addons.mozilla.org}"
    mkdir -p "$CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${CERT_DIR}/server.key" -out "${CERT_DIR}/server.crt" -subj "/CN=${tls_sni}" >/dev/null 2>&1
    chmod 644 "${CERT_DIR}/server.crt"
    chmod 600 "${CERT_DIR}/server.key"
}

# 部署轻量极速双栈订阅服务 (自动检测 Acme 证书决定是否下发 NaiveProxy 节点)
deploy_sub_server() {
    mkdir -p "$SUB_DIR"
    cat << 'PYEOF' > "${SUB_DIR}/server.py"
#!/usr/bin/env python3
import http.server, socketserver, socket, os, base64, urllib.parse

ENV_PATH = "/etc/sing-box/singbox.env"
ACME_CRT_PATH = "/etc/sing-box/cert/acme.crt"
ACME_KEY_PATH = "/etc/sing-box/cert/acme.key"

def load_env():
    env = {}
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def has_acme_cert(env):
    domain = env.get("ACME_DOMAIN", "").strip()
    return bool(domain and os.path.exists(ACME_CRT_PATH) and os.path.getsize(ACME_CRT_PATH) > 0 and os.path.exists(ACME_KEY_PATH))

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_payload(self, status_code, content_type, data_bytes):
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data_bytes)))
        self.send_header("Connection", "close")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("profile-update-interval", "24")
        self.end_headers()
        self.wfile.write(data_bytes)
        self.wfile.flush()

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self):
        try:
            env = load_env()
            parsed = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(parsed.query)
            token = qs.get("token", [""])[0].strip()
            expected_token = env.get("SUB_TOKEN", "").strip()
            if expected_token and token != expected_token:
                self.send_payload(403, "text/plain; charset=utf-8", b"403 Forbidden: Invalid Subscription Token\n")
                return

            ip = env.get("SERVER_IP", "127.0.0.1").strip()
            uuid = env.get("UUID", "").strip()
            url_ip = f"[{ip}]" if ":" in ip else ip
            sni_reality = env.get("REALITY_SNI", "addons.mozilla.org").strip()
            acme_domain = env.get("ACME_DOMAIN", "").strip()
            acme_ready = has_acme_cert(env)

            links = [
                f"vless://{uuid}@{url_ip}:{env.get('PORT_REALITY', '27409')}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={sni_reality}&fp=chrome&pbk={env.get('REALITY_PUB', '')}&sid={env.get('REALITY_SHORT_ID', '')}&type=tcp&headerType=none#Reality-{ip}",
                f"hysteria2://{env.get('HY2_PWD', '')}@{url_ip}:{env.get('PORT_HY2', '56333')}/?insecure=1&sni={sni_reality}#Hy2-{ip}",
                f"tuic://{uuid}:{env.get('TUIC_PWD', '')}@{url_ip}:{env.get('PORT_TUIC', '49515')}?congestion_control=bbr&alpn=h3&sni={sni_reality}&udp_relay_mode=native&allow_insecure=1#TUIC5-{ip}",
                f"anytls://{uuid}@{url_ip}:{env.get('PORT_ANYTLS', '20418')}?security=tls&sni={sni_reality}&insecure=1&fp=chrome#AnyTLS-{ip}",
            ]

            # 只要通过 acme.sh 生成了权威域名证书，即自动加入 NaiveProxy (HTTP/2 与 QUIC) 节点
            if acme_ready:
                n_user = env.get("NAIVE_USER", "admin")
                n_pass = env.get("NAIVE_PASS", "")
                n_port = env.get("PORT_NAIVE", "33445")
                links.append(f"naive+https://{n_user}:{n_pass}@{acme_domain}:{n_port}#Naive-HTTP2-{acme_domain}")
                links.append(f"naive+quic://{n_user}:{n_pass}@{acme_domain}:{n_port}#Naive-QUIC-{acme_domain}")

            fmt = qs.get("format", [""])[0].lower()
            ua = self.headers.get("User-Agent", "").lower()

            if fmt in ["clash", "meta", "yaml"] or any(k in ua for k in ["clash", "mihomo", "flclash", "verge"]):
                yaml_content = f"""port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
proxies:
  - name: "Reality [{ip}]"
    type: vless
    server: "{ip}"
    port: {env.get('PORT_REALITY', '27409')}
    uuid: "{uuid}"
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: "{sni_reality}"
    reality-opts:
      public-key: "{env.get('REALITY_PUB', '')}"
      short-id: "{env.get('REALITY_SHORT_ID', '')}"
    client-fingerprint: chrome
  - name: "Hy2 [{ip}]"
    type: hysteria2
    server: "{ip}"
    port: {env.get('PORT_HY2', '56333')}
    password: "{env.get('HY2_PWD', '')}"
    sni: "{sni_reality}"
    skip-cert-verify: true
  - name: "TUIC5 [{ip}]"
    type: tuic
    server: "{ip}"
    port: {env.get('PORT_TUIC', '49515')}
    uuid: "{uuid}"
    password: "{env.get('TUIC_PWD', '')}"
    congestion-controller: bbr
    alpn: [h3]
    sni: "{sni_reality}"
    skip-cert-verify: true
  - name: "AnyTLS [{ip}]"
    type: anytls
    server: "{ip}"
    port: {env.get('PORT_ANYTLS', '20418')}
    password: "{uuid}"
    client-fingerprint: chrome
    udp: true
    sni: "{sni_reality}"
    skip-cert-verify: true
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "Reality [{ip}]"
      - "Hy2 [{ip}]"
      - "TUIC5 [{ip}]"
      - "AnyTLS [{ip}]"
rules:
  - MATCH,PROXY
"""
                self.send_payload(200, "text/yaml; charset=utf-8", yaml_content.encode("utf-8"))
            else:
                b64_data = base64.b64encode("\n".join(links).encode("utf-8"))
                self.send_payload(200, "text/plain; charset=utf-8", b64_data)
        except Exception as e:
            err_msg = f"500 Internal Error: {str(e)}\n".encode("utf-8")
            self.send_payload(500, "text/plain; charset=utf-8", err_msg)

class DualStackServer(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except Exception:
            pass
        super().server_bind()

if __name__ == "__main__":
    env = load_env()
    port = int(env.get("SUB_PORT", 53358))
    try:
        with DualStackServer(("::", port), SubHandler) as httpd:
            httpd.serve_forever()
    except Exception:
        with socketserver.ThreadingTCPServer(("0.0.0.0", port), SubHandler) as httpd:
            httpd.serve_forever()
PYEOF
    chmod +x "${SUB_DIR}/server.py"

    cat << 'EOF' > /etc/systemd/system/singbox-sub.service
[Unit]
Description=Sing-box Dual-Stack Subscription Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/sing-box/subscription/server.py
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now singbox-sub >/dev/null 2>&1
    systemctl restart singbox-sub >/dev/null 2>&1
}

# 生成 Sing-box 配置文件：
# 若已通过 Acme.sh 生成了 /etc/sing-box/cert/acme.crt，则自动开启 NaiveProxy 入站；否则仅运行四协议入站
write_singbox_config() {
    source "$ENV_FILE"
    local naive_inbound_block=""
    if [[ -n "$ACME_DOMAIN" && -s "${CERT_DIR}/acme.crt" && -s "${CERT_DIR}/acme.key" ]]; then
        naive_inbound_block=",
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": ${PORT_NAIVE},
      "users": [
        {
          "username": "${NAIVE_USER}",
          "password": "${NAIVE_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ACME_DOMAIN}",
        "certificate_path": "${CERT_DIR}/acme.crt",
        "key_path": "${CERT_DIR}/acme.key"
      }
    }"
    fi

    cat << EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "prefer_go": true
      }
    ],
    "strategy": "${OUTBOUND_STRATEGY}"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${PORT_REALITY},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIV}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT_HY2},
      "users": [
        {
          "password": "${HY2_PWD}"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${PORT_TUIC},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${TUIC_PWD}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${PORT_ANYTLS},
      "users": [
        {
          "password": "${UUID}"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    }${naive_inbound_block}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }
    ]
  }
}
EOF
}

# 放行防火墙端口
open_firewall_ports() {
    source "$ENV_FILE" 2>/dev/null || return
    for p in "$PORT_REALITY" "$PORT_HY2" "$PORT_TUIC" "$PORT_NAIVE" "$PORT_ANYTLS" "$SUB_PORT"; do
        [[ -z "$p" ]] && continue
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
        ufw allow "${p}/udp" >/dev/null 2>&1 || true
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
        iptables -I INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
        ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
        ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
    done
}

# 选项 6: Acme.sh 域名证书申请管理 (申请成功后自动激活 NaiveProxy 节点与订阅)
manage_acme_cert() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}[提示] 请先运行选项 1 安装 Sing-box 基础环境！${PLAIN}"
        return
    fi
    source "$ENV_FILE"

    echo -e "\n${BLUE}=== 管理 Acme.sh 权威域名证书 (激活 NaiveProxy 专用) ===${PLAIN}"
    if [[ -n "$ACME_DOMAIN" && -s "${CERT_DIR}/acme.crt" ]]; then
        echo -e " 当前状态: ${GREEN}● 已配置域名证书 (${ACME_DOMAIN}) — NaiveProxy 节点已激活！${PLAIN}"
    else
        echo -e " 当前状态: ${YELLOW}○ 未配置域名证书 — 申请后将自动启用 NaiveProxy 并生成节点链接${PLAIN}"
    fi
    echo "----------------------------------------------------------------------"
    echo " 1. 使用 Acme.sh 自动申请免费域名证书 (80 端口 Standalone 模式，支持纯 IPv6 / IPv4)"
    echo " 2. 手动输入已有证书与私钥路径 (直接激活 NaiveProxy)"
    echo " 3. 移除域名证书并关闭 NaiveProxy"
    echo " 0. 返回主菜单"
    read -rp "请选择 [0-3]: " a_choice

    case "$a_choice" in
        1)
            read -rp "请输入已解析到本机 IP (${SERVER_IP}) 的域名: " input_domain
            input_domain=$(echo "$input_domain" | tr -d ' ')
            if [[ -z "$input_domain" ]]; then
                echo -e "${RED}[错误] 域名不能为空！${PLAIN}"
                return
            fi

            install_deps
            ufw allow 80/tcp >/dev/null 2>&1 || true
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
            ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true

            if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
                echo -e "${BLUE}正在安装官方 acme.sh 证书管理组件...${PLAIN}"
                curl -fsSL https://get.acme.sh | sh -s email="admin@${input_domain}"
            fi

            "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1 || true
            "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

            echo -e "${BLUE}正在为域名 ${input_domain} 申请 Let's Encrypt 权威证书 (请确保 80 端口未被占用)...${PLAIN}"
            local issue_ok=0
            if [[ "$SERVER_IP" == *":"* && -z "$SERVER_IPV4" ]]; then
                "$HOME/.acme.sh/acme.sh" --issue -d "$input_domain" --standalone --listen-v6 -k ec-256 --force && issue_ok=1
            else
                "$HOME/.acme.sh/acme.sh" --issue -d "$input_domain" --standalone -k ec-256 --force && issue_ok=1
                if [[ $issue_ok -eq 0 ]]; then
                    "$HOME/.acme.sh/acme.sh" --issue -d "$input_domain" --standalone --listen-v6 -k ec-256 --force && issue_ok=1
                fi
            fi

            if [[ $issue_ok -eq 0 ]]; then
                echo -e "${RED}[错误] 证书申请失败！请检查域名 DNS (AAAA/A记录) 是否已指向 ${SERVER_IP} 且未开启 Cloudflare 小黄云代理。${PLAIN}"
                return
            fi

            mkdir -p "$CERT_DIR"
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$input_domain" --ecc \
                --fullchain-file "${CERT_DIR}/acme.crt" \
                --key-file "${CERT_DIR}/acme.key" \
                --reloadcmd "systemctl restart sing-box 2>/dev/null || true"

            chmod 644 "${CERT_DIR}/acme.crt"
            chmod 600 "${CERT_DIR}/acme.key"

            if grep -q "^ACME_DOMAIN=" "$ENV_FILE"; then
                sed -i "s|^ACME_DOMAIN=.*|ACME_DOMAIN=\"$input_domain\"|" "$ENV_FILE"
            else
                echo "ACME_DOMAIN=\"$input_domain\"" >> "$ENV_FILE"
            fi

            write_singbox_config
            open_firewall_ports
            systemctl restart sing-box singbox-sub
            echo -e "\n${GREEN}🎉 域名证书 (${input_domain}) 申请并安装成功！NaiveProxy 已自动激活！${PLAIN}"
            show_nodes
            ;;
        2)
            read -rp "请输入绑定该证书的域名 (如 sub.example.com): " input_domain
            read -rp "请输入证书公钥完整路径 (如 /root/cert.crt): " crt_p
            read -rp "请输入证书私钥完整路径 (如 /root/cert.key): " key_p
            if [[ -z "$input_domain" || ! -s "$crt_p" || ! -s "$key_p" ]]; then
                echo -e "${RED}[错误] 域名为空或指定的证书文件不存在！${PLAIN}"
                return
            fi
            mkdir -p "$CERT_DIR"
            cp -f "$crt_p" "${CERT_DIR}/acme.crt"
            cp -f "$key_p" "${CERT_DIR}/acme.key"
            chmod 644 "${CERT_DIR}/acme.crt"
            chmod 600 "${CERT_DIR}/acme.key"

            if grep -q "^ACME_DOMAIN=" "$ENV_FILE"; then
                sed -i "s|^ACME_DOMAIN=.*|ACME_DOMAIN=\"$input_domain\"|" "$ENV_FILE"
            else
                echo "ACME_DOMAIN=\"$input_domain\"" >> "$ENV_FILE"
            fi

            write_singbox_config
            open_firewall_ports
            systemctl restart sing-box singbox-sub
            echo -e "\n${GREEN}🎉 证书配置成功！NaiveProxy 节点已自动生成！${PLAIN}"
            show_nodes
            ;;
        3)
            rm -f "${CERT_DIR}/acme.crt" "${CERT_DIR}/acme.key"
            sed -i "s|^ACME_DOMAIN=.*|ACME_DOMAIN=\"\"|" "$ENV_FILE"
            write_singbox_config
            systemctl restart sing-box singbox-sub
            echo -e "${YELLOW}[OK] 已移除域名证书并关闭 NaiveProxy 入站。${PLAIN}"
            ;;
    esac
}

# 选项 1: 一键极速安装部署
install_singbox() {
    local auto_mode="${1:-0}"
    setup_nat64_dns
    install_deps
    install_singbox_binary "$DEFAULT_SB_VER" "0"

    mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$SUB_DIR"

    local def_r=$(gen_random_port)
    local def_h=$(gen_random_port)
    local def_t=$(gen_random_port)
    local def_n=$(gen_random_port)
    local def_a=$(gen_random_port)
    local def_s=$(gen_random_port)

    # 若之前已申请过 Acme 证书则保留，避免重装丢失已申请好的域名证书
    local saved_acme_domain=""
    if [[ -f "$ENV_FILE" ]]; then
        saved_acme_domain=$(grep "^ACME_DOMAIN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi

    if [[ "$auto_mode" == "1" ]]; then
        ACME_DOMAIN="$saved_acme_domain"
        PORT_REALITY="$def_r"
        PORT_HY2="$def_h"
        PORT_TUIC="$def_t"
        PORT_NAIVE="$def_n"
        PORT_ANYTLS="$def_a"
        SUB_PORT="$def_s"
        REALITY_SNI="addons.mozilla.org"
    else
        echo -e "\n${GREEN}=== 配置协议端口参数 (直接一路按回车即采用推荐随机高位端口) ===${PLAIN}"
        read -rp "请输入 VLESS-Reality 端口 [默认随机 ${def_r}]: " PORT_REALITY
        PORT_REALITY="${PORT_REALITY:-$def_r}"
        read -rp "请输入伪装域名 SNI [默认 addons.mozilla.org]: " REALITY_SNI
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        read -rp "请输入 Hysteria 2 (UDP) 端口 [默认随机 ${def_h}]: " PORT_HY2
        PORT_HY2="${PORT_HY2:-$def_h}"
        read -rp "请输入 TUIC v5 (UDP) 端口 [默认随机 ${def_t}]: " PORT_TUIC
        PORT_TUIC="${PORT_TUIC:-$def_t}"
        read -rp "请输入 AnyTLS (TCP) 端口 [默认随机 ${def_a}]: " PORT_ANYTLS
        PORT_ANYTLS="${PORT_ANYTLS:-$def_a}"
        read -rp "请输入 NaiveProxy 预留端口 (申请 Acme 证书后激活) [默认随机 ${def_n}]: " PORT_NAIVE
        PORT_NAIVE="${PORT_NAIVE:-$def_n}"
        read -rp "请输入在线订阅服务端口 [默认随机 ${def_s}]: " SUB_PORT
        SUB_PORT="${SUB_PORT:-$def_s}"
        ACME_DOMAIN="$saved_acme_domain"
    fi

    echo -e "${BLUE}正在生成 UUID、Reality 密钥对与基础 TLS 证书...${PLAIN}"
    UUID=$("$BIN_PATH" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    KP=$("$BIN_PATH" generate reality-keypair 2>/dev/null)
    REALITY_PRIV=$(echo "$KP" | grep -i "PrivateKey" | awk '{print $2}')
    REALITY_PUB=$(echo "$KP" | grep -i "PublicKey" | awk '{print $2}')
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    HY2_PWD=$(openssl rand -hex 12)
    TUIC_PWD=$(openssl rand -hex 12)
    NAIVE_USER="admin"
    NAIVE_PASS=$(openssl rand -hex 12)
    SUB_TOKEN=$(openssl rand -hex 16)

    generate_self_signed_cert "$REALITY_SNI"

    cat << EOF > "$ENV_FILE"
SERVER_IP="${SERVER_IP}"
SERVER_IPV4="${IPV4_ADDR}"
SERVER_IPV6="${IPV6_ADDR}"
ACME_DOMAIN="${ACME_DOMAIN}"
OUTBOUND_STRATEGY="${OUTBOUND_STRATEGY}"
PORT_REALITY=${PORT_REALITY}
PORT_HY2=${PORT_HY2}
PORT_TUIC=${PORT_TUIC}
PORT_NAIVE=${PORT_NAIVE}
PORT_ANYTLS=${PORT_ANYTLS}
SUB_PORT=${SUB_PORT}
UUID="${UUID}"
HY2_PWD="${HY2_PWD}"
TUIC_PWD="${TUIC_PWD}"
NAIVE_USER="${NAIVE_USER}"
NAIVE_PASS="${NAIVE_PASS}"
REALITY_PRIV="${REALITY_PRIV}"
REALITY_PUB="${REALITY_PUB}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
REALITY_SNI="${REALITY_SNI}"
SUB_TOKEN="${SUB_TOKEN}"
EOF

    write_singbox_config

    cat << 'EOF' > /etc/systemd/system/sing-box.service
[Unit]
Description=Sing-box Service (SingBox Suite Pro)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
Environment="LD_LIBRARY_PATH=/usr/local/bin:/usr/local/lib:/usr/lib"
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    open_firewall_ports
    systemctl daemon-reload
    systemctl enable --now sing-box >/dev/null 2>&1
    systemctl restart sing-box

    deploy_sub_server

    # 创建快捷指令 sb
    if [[ -f "$0" && "$0" != "$SHORTCUT_PATH" ]]; then
        cp -f "$0" "$SHORTCUT_PATH" 2>/dev/null || true
    else
        curl -fsSL "${REPO_RAW_URL}?t=$(date +%s)" -o "$SHORTCUT_PATH" 2>/dev/null || wget -qO "$SHORTCUT_PATH" "${REPO_RAW_URL}?t=$(date +%s)" 2>/dev/null || true
    fi
    chmod +x "$SHORTCUT_PATH" 2>/dev/null || true

    show_nodes
}

# 选项 7: 极速打印全部节点与订阅链接 (毫秒级响应，检测到 Acme 证书即输出 NaiveProxy 节点)
show_nodes() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}[提示] 尚未安装配置 Sing-box，请先运行选项 1 进行安装！${PLAIN}"
        return
    fi

    source "$ENV_FILE"
    if [[ -z "$SERVER_IP" || "$SERVER_IP" == "127.0.0.1" ]]; then
        detect_network "1"
        sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$SERVER_IP\"|" "$ENV_FILE"
    fi

    # 若订阅服务未启动则后台拉起 (不阻塞终端显示)
    if ! pgrep -f "/etc/sing-box/subscription/server.py" >/dev/null 2>&1; then
        systemctl start singbox-sub 2>/dev/null || nohup python3 "${SUB_DIR}/server.py" >/dev/null 2>&1 &
    fi

    local url_ip="${SERVER_IP}"
    [[ "$SERVER_IP" == *":"* ]] && url_ip="[${SERVER_IP}]"

    echo -e "\n${GREEN}======================================================================${PLAIN}"
    echo -e "${BOLD}                 Sing-Box 节点配置与在线订阅信息                      ${PLAIN}"
    echo -e "${GREEN}======================================================================${PLAIN}"
    echo -e " 服务器主 IP  : ${BLUE}${SERVER_IP}${PLAIN}"
    echo -e " UUID 标识    : ${BLUE}${UUID}${PLAIN}"
    echo -e " 出站优先级   : ${BLUE}${OUTBOUND_STRATEGY:-prefer_ipv6}${PLAIN}"
    if [[ -n "$ACME_DOMAIN" && -s "${CERT_DIR}/acme.crt" ]]; then
        echo -e " Acme 证书    : ${GREEN}✔ 已激活 (${ACME_DOMAIN}) — NaiveProxy 节点已生成${PLAIN}"
    else
        echo -e " Acme 证书    : ${YELLOW}○ 未申请 (可在主菜单【选项 6】申请证书以启用 NaiveProxy)${PLAIN}"
    fi
    echo -e "----------------------------------------------------------------------"

    echo -e "${BOLD}1. VLESS-Reality-Vision (端口 ${PORT_REALITY} | 伪装 ${REALITY_SNI}):${PLAIN}"
    echo -e "${GREEN}vless://${UUID}@${url_ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#Reality-${SERVER_IP}${PLAIN}\n"

    echo -e "${BOLD}2. Hysteria 2 (端口 ${PORT_HY2} | UDP/QUIC 极速抗丢包):${PLAIN}"
    echo -e "${GREEN}hysteria2://${HY2_PWD}@${url_ip}:${PORT_HY2}/?insecure=1&sni=${REALITY_SNI}#Hy2-${SERVER_IP}${PLAIN}\n"

    echo -e "${BOLD}3. TUIC v5 (端口 ${PORT_TUIC} | UDP BBR 多路复用):${PLAIN}"
    echo -e "${GREEN}tuic://${UUID}:${TUIC_PWD}@${url_ip}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&sni=${REALITY_SNI}&udp_relay_mode=native&allow_insecure=1#TUIC5-${SERVER_IP}${PLAIN}\n"

    echo -e "${BOLD}4. AnyTLS (端口 ${PORT_ANYTLS} | Sing-box 1.14 原生 AnyTLS 协议):${PLAIN}"
    echo -e "${GREEN}anytls://${UUID}@${url_ip}:${PORT_ANYTLS}?security=tls&sni=${REALITY_SNI}&insecure=1&fp=chrome#AnyTLS-${SERVER_IP}${PLAIN}\n"

    echo -e "${BOLD}5. NaiveProxy (端口 ${PORT_NAIVE} | 依赖 Acme.sh 权威域名证书):${PLAIN}"
    if [[ -n "$ACME_DOMAIN" && -s "${CERT_DIR}/acme.crt" ]]; then
        echo -e "${GREEN}naive+https://${NAIVE_USER}:${NAIVE_PASS}@${ACME_DOMAIN}:${PORT_NAIVE}#Naive-HTTP2-${ACME_DOMAIN}${PLAIN}"
        echo -e "${GREEN}naive+quic://${NAIVE_USER}:${NAIVE_PASS}@${ACME_DOMAIN}:${PORT_NAIVE}#Naive-QUIC-${ACME_DOMAIN}${PLAIN}\n"
    else
        echo -e "${YELLOW}[未生成] NaiveProxy 必须使用域名证书才能连通。请运行【选项 6: 管理 Acme.sh 域名证书】申请证书后自动生成节点！${PLAIN}\n"
    fi

    echo -e "----------------------------------------------------------------------"
    echo -e "${YELLOW}【一键在线订阅地址 (当前订阅端口: ${SUB_PORT})】${PLAIN}"
    echo -e " 1. 通用 Base64 订阅链接 (v2rayN / Karing / Shadowrocket / NekoBox 直接填入):"
    echo -e "    ${GREEN}http://${url_ip}:${SUB_PORT}/sub?token=${SUB_TOKEN}${PLAIN}\n"
    echo -e " 2. Clash.Meta / Mihomo 专属 YAML 订阅链接:"
    echo -e "    ${GREEN}http://${url_ip}:${SUB_PORT}/sub?token=${SUB_TOKEN}&format=clash${PLAIN}"
    echo -e "${GREEN}======================================================================${PLAIN}"
}

# 选项 2: 干净卸载
uninstall_singbox() {
    echo -e "${YELLOW}正在停止并卸载 Sing-box 与订阅微服务...${PLAIN}"
    systemctl stop sing-box singbox-sub 2>/dev/null || true
    systemctl disable sing-box singbox-sub 2>/dev/null || true
    pkill -f "/etc/sing-box/subscription/server.py" 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/singbox-sub.service
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR" "$BIN_PATH" /usr/local/bin/libcronet.so /usr/local/lib/libcronet.so
    echo -e "${GREEN}[OK] Sing-box 全套组件已彻底卸载干净！${PLAIN}"
}

# 选项 3: 启停与状态管理
manage_service() {
    echo -e "\n=== 服务启停与运行状态管理 ==="
    echo " 1. 启动全部服务 (Sing-box + 订阅服务)"
    echo " 2. 停止全部服务"
    echo " 3. 重启全部服务"
    echo " 4. 查看详细 systemctl 状态"
    echo " 0. 返回主菜单"
    read -rp "请选择 [0-4]: " s_choice
    case "$s_choice" in
        1) systemctl start sing-box singbox-sub 2>/dev/null; echo -e "${GREEN}[OK] 已启动！${PLAIN}" ;;
        2) systemctl stop sing-box singbox-sub 2>/dev/null; echo -e "${YELLOW}[OK] 已停止！${PLAIN}" ;;
        3) systemctl restart sing-box singbox-sub 2>/dev/null; echo -e "${GREEN}[OK] 已重启！${PLAIN}" ;;
        4) systemctl status sing-box singbox-sub --no-pager | head -n 30 ;;
    esac
}

# 选项 4: 变更核心配置
modify_config() {
    source "$ENV_FILE" 2>/dev/null || { echo -e "${RED}请先安装 Sing-box！${PLAIN}"; return; }
    echo -e "\n=== 变更核心配置选项 ==="
    echo " 1. 重新生成并更换 UUID"
    echo " 2. 重新生成 Hysteria 2 / TUIC / Naive 密码"
    echo " 3. 切换出站策略【prefer_ipv6 / prefer_ipv4】"
    echo " 4. 更换 Reality 伪装域名 SNI (当前: ${REALITY_SNI})"
    echo " 5. 重新生成订阅安全 Token"
    echo " 0. 返回主菜单"
    read -rp "请选择 [0-5]: " m_choice
    case "$m_choice" in
        1)
            UUID=$("$BIN_PATH" generate uuid)
            sed -i "s|^UUID=.*|UUID=\"$UUID\"|" "$ENV_FILE"
            write_singbox_config && systemctl restart sing-box singbox-sub
            echo -e "${GREEN}[OK] 新 UUID 已生效: $UUID${PLAIN}"
            ;;
        2)
            HY2_PWD=$(openssl rand -hex 12)
            TUIC_PWD=$(openssl rand -hex 12)
            NAIVE_PASS=$(openssl rand -hex 12)
            sed -i "s|^HY2_PWD=.*|HY2_PWD=\"$HY2_PWD\"|" "$ENV_FILE"
            sed -i "s|^TUIC_PWD=.*|TUIC_PWD=\"$TUIC_PWD\"|" "$ENV_FILE"
            sed -i "s|^NAIVE_PASS=.*|NAIVE_PASS=\"$NAIVE_PASS\"|" "$ENV_FILE"
            write_singbox_config && systemctl restart sing-box singbox-sub
            echo -e "${GREEN}[OK] 各协议连接密码已全部刷新！${PLAIN}"
            ;;
        3)
            read -rp "请选择出站策略 (1: prefer_ipv6 [推荐纯IPv6 VPS], 2: prefer_ipv4): " st
            OUTBOUND_STRATEGY=$([[ "$st" == "2" ]] && echo "prefer_ipv4" || echo "prefer_ipv6")
            sed -i "s|^OUTBOUND_STRATEGY=.*|OUTBOUND_STRATEGY=\"$OUTBOUND_STRATEGY\"|" "$ENV_FILE"
            write_singbox_config && systemctl restart sing-box
            echo -e "${GREEN}[OK] 出站策略已切换为: $OUTBOUND_STRATEGY${PLAIN}"
            ;;
        4)
            read -rp "请输入新的伪装域名 SNI [默认 addons.mozilla.org]: " new_sni
            REALITY_SNI="${new_sni:-addons.mozilla.org}"
            sed -i "s|^REALITY_SNI=.*|REALITY_SNI=\"$REALITY_SNI\"|" "$ENV_FILE"
            generate_self_signed_cert "$REALITY_SNI"
            write_singbox_config && systemctl restart sing-box singbox-sub
            echo -e "${GREEN}[OK] Reality 伪装源已更新为: $REALITY_SNI${PLAIN}"
            show_nodes
            ;;
        5)
            SUB_TOKEN=$(openssl rand -hex 16)
            sed -i "s|^SUB_TOKEN=.*|SUB_TOKEN=\"$SUB_TOKEN\"|" "$ENV_FILE"
            systemctl restart singbox-sub
            echo -e "${GREEN}[OK] 订阅 Token 已刷新！${PLAIN}"
            show_nodes
            ;;
    esac
}

# 选项 5: 一键随机刷新全部高位端口
randomize_all_ports() {
    source "$ENV_FILE" 2>/dev/null || { echo -e "${RED}请先安装 Sing-box！${PLAIN}"; return; }
    PORT_REALITY=$(gen_random_port)
    PORT_HY2=$(gen_random_port)
    PORT_TUIC=$(gen_random_port)
    PORT_NAIVE=$(gen_random_port)
    PORT_ANYTLS=$(gen_random_port)
    SUB_PORT=$(gen_random_port)

    sed -i "s|^PORT_REALITY=.*|PORT_REALITY=$PORT_REALITY|" "$ENV_FILE"
    sed -i "s|^PORT_HY2=.*|PORT_HY2=$PORT_HY2|" "$ENV_FILE"
    sed -i "s|^PORT_TUIC=.*|PORT_TUIC=$PORT_TUIC|" "$ENV_FILE"
    sed -i "s|^PORT_NAIVE=.*|PORT_NAIVE=$PORT_NAIVE|" "$ENV_FILE"
    sed -i "s|^PORT_ANYTLS=.*|PORT_ANYTLS=$PORT_ANYTLS|" "$ENV_FILE"
    sed -i "s|^SUB_PORT=.*|SUB_PORT=$SUB_PORT|" "$ENV_FILE"

    write_singbox_config
    open_firewall_ports
    systemctl restart sing-box singbox-sub
    echo -e "${GREEN}[OK] 全部协议与订阅服务已更换为全新的随机高位端口！${PLAIN}"
    show_nodes
}

# 选项 11: 开启原版 BBR + FQ
enable_bbr() {
    echo -e "${BLUE}正在写入 net.core.default_qdisc=fq 与 net.ipv4.tcp_congestion_control=bbr...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    echo -e "${GREEN}[OK] BBR + FQ 拥塞控制加速已开启！当前队列算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo bbr)${PLAIN}"
}

# 选项 13: 在线防缓存更新脚本
update_script() {
    echo -e "${BLUE}正在从 GitHub 仓库拉取最新 sb.sh 脚本 (带防缓存时间戳)...${PLAIN}"
    if curl -fsSL "${REPO_RAW_URL}?t=$(date +%s)" -o "$SHORTCUT_PATH" || wget -qO "$SHORTCUT_PATH" "${REPO_RAW_URL}?t=$(date +%s)"; then
        chmod +x "$SHORTCUT_PATH"
        echo -e "${GREEN}[OK] 脚本已成功更新至最新版本！正在重新加载...${PLAIN}"
        exec "$SHORTCUT_PATH"
    else
        echo -e "${RED}[错误] 更新拉取失败，请检查网络连接。${PLAIN}"
    fi
}

# 主菜单渲染 (毫秒级瞬时响应 + 1-13 顺次排列 + 致敬 ygkkk 与 fscarmen)
show_menu() {
    check_arch
    detect_network "0"
    local ver="未安装"
    [[ -x "$BIN_PATH" ]] && ver="v$DEFAULT_SB_VER"
    local status="${RED}○ 已停止${PLAIN}"
    systemctl is-active --quiet sing-box 2>/dev/null && status="${GREEN}● 正在运行${PLAIN}"
    local acme_stat="${YELLOW}未申请 (Naive待激活)${PLAIN}"
    if [[ -f "$ENV_FILE" ]]; then
        local dom
        dom=$(grep "^ACME_DOMAIN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
        [[ -n "$dom" && -s "${CERT_DIR}/acme.crt" ]] && acme_stat="${GREEN}● 已激活 (${dom})${PLAIN}"
    fi

    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║${PLAIN}      ${BOLD}SingBox Suite Pro — 极速全协议聚合部署套件 (All-In-One)${PLAIN}         ${BLUE}║${PLAIN}"
    echo -e "${BLUE}║${PLAIN}     VLESS-Reality • Hysteria 2 • TUIC v5 • AnyTLS • NaiveProxy       ${BLUE}║${PLAIN}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════╝${PLAIN}"
    echo -e " 系统架构: ${GREEN}${ARCH}${PLAIN} | 网络环境: ${GREEN}${NET_STACK}${PLAIN} | 快捷指令: ${YELLOW}sb${PLAIN}"
    echo -e " 核心版本: ${GREEN}${ver}${PLAIN} | 服务状态: ${status} | Acme证书: ${acme_stat}"
    echo -e "──────────────────────────────────────────────────────────────────────"
    echo -e " ${BOLD}【核心部署与控制】${PLAIN}"
    echo -e "   ${GREEN}1.${PLAIN} 一键极速安装部署 (Reality / Hy2 / TUIC5 / AnyTLS + 订阅服务)"
    echo -e "   ${GREEN}2.${PLAIN} 干净卸载 Sing-box (彻底移除二进制、配置与订阅守护服务)"
    echo -e "   ${GREEN}3.${PLAIN} 启停与状态管理 (启动 / 停止 / 重启 Sing-box 及订阅服务)"
    echo ""
    echo -e " ${BOLD}【节点配置与证书管理】${PLAIN}"
    echo -e "   ${GREEN}4.${PLAIN} 变更核心配置 (UUID / 密码 / 出站优先级 / 伪装源 SNI)"
    echo -e "   ${GREEN}5.${PLAIN} 协议端口调整与一键随机刷新 (规避运营商封锁与 UDP QoS)"
    echo -e "   ${GREEN}6.${PLAIN} 管理 Acme.sh 域名证书 (${YELLOW}★ 申请证书以启用并生成 NaiveProxy 节点${PLAIN})"
    echo ""
    echo -e " ${BOLD}【订阅管理与分流解锁】${PLAIN}"
    echo -e "   ${GREEN}7.${PLAIN} 刷新查看节点配置与订阅链接 (通用 Base64 / Karing / v2rayN / Clash)"
    echo -e "   ${GREEN}8.${PLAIN} 路由分流管理 (校准 v1.14 标准路由与 DNS 策略)"
    echo -e "   ${GREEN}9.${PLAIN} 网络连通性与流媒体解锁自检 (IPv6 / NAT64 / Cloudflare 边缘检测)"
    echo ""
    echo -e " ${BOLD}【系统优化与工具维护】${PLAIN}"
    echo -e "   ${GREEN}10.${PLAIN} 实时查看运行日志 (Journalctl 追踪协议入站连接)"
    echo -e "   ${GREEN}11.${PLAIN} 一键原版 BBR + FQ 加速 (内核网络拥塞控制调优)"
    echo -e "   ${GREEN}12.${PLAIN} 官方内核版本切换 (默认 v1.14.4 含 libcronet.so)"
    echo -e "   ${GREEN}13.${PLAIN} 在线拉取更新部署脚本 (同步 GitHub 仓库最新 sb.sh)"
    echo -e "──────────────────────────────────────────────────────────────────────"
    echo -e "   ${GREEN}0.${PLAIN} 退出管理控制台"
    echo -e "──────────────────────────────────────────────────────────────────────"
    echo -e " ${PURPLE}❤ 致敬与特别鸣谢: 本脚本基于并深度修改自 ygkkk (甬哥) 与 fscarmen (F佬) 的开源脚本！${PLAIN}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════${PLAIN}"
}

check_root
check_arch
if [[ $# -gt 0 ]]; then
    case "$1" in
        1|-y|--yes) install_singbox "1"; exit 0 ;;
        2) uninstall_singbox; exit 0 ;;
        6|acme) manage_acme_cert; exit 0 ;;
        7|9) show_nodes; exit 0 ;;
        13|update) update_script; exit 0 ;;
    esac
fi

while true; do
    show_menu
    read -rp "请输入选项编号 [0-13]: " choice
    case "$choice" in
        1) install_singbox "0" ;;
        2) uninstall_singbox ;;
        3) manage_service ;;
        4) modify_config ;;
        5) randomize_all_ports ;;
        6) manage_acme_cert ;;
        7) show_nodes ;;
        8)
            write_singbox_config && systemctl restart sing-box
            echo -e "${GREEN}[OK] 已校准为 Sing-box v1.14.4 标准配置！${PLAIN}"
            ;;
        9)
            echo -e "${BLUE}正在测试 VPS 出站连通性...${PLAIN}"
            curl -s6m5 https://www.cloudflare.com/cdn-cgi/trace | grep -E "ip=|loc=|warp=" || true
            ;;
        10) journalctl -u sing-box -n 35 --no-pager ;;
        11) enable_bbr ;;
        12)
            read -rp "请输入要安装的 Sing-box 官方版本号 [默认 1.14.4]: " v_tag
            install_singbox_binary "${v_tag:-1.14.4}" "1"
            systemctl restart sing-box
            ;;
        13) update_script ;;
        0)
            echo -e "${GREEN}已退出 SingBox Suite Pro 控制台，随时输入 sb 即可再次唤出。${PLAIN}"
            exit 0
            ;;
        *)
            echo -e "${RED}输入无效，请输入 0 到 13 之间的数字！${PLAIN}"
            ;;
    esac
    echo ""
    read -rp "按回车键返回主菜单..." _
done
