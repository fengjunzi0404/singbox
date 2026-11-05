#!/usr/bin/env bash
# ==============================================================================
# SingBox Suite Pro — 现代化全协议聚合部署运维套件 (All-In-One 单脚本自包含版)
# 协议支持: VLESS-Reality-Vision | Hysteria 2 | TUIC v5 | AnyTLS | NaiveProxy+Argo
# 特性亮点:
#   1. 一键安装默认自动挂载 Cloudflare Argo 免费临时隧道，NaiveProxy 免域名、免导证书秒通
#   2. 默认分配 15000-59999 高位随机非标端口，彻底规避运营商对 443/8443 的阻断
#   3. 纯 IPv6 (如 Hax) 与双栈 VPS 自适应：自动注入 NAT64/DNS64，默认 prefer_ipv6 出站
#   4. 标准化 HTTP/1.1 [::] 双栈订阅服务：带 Content-Length，原生完美支持 Karing Base64 与 Clash
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
ARGO_BIN="/usr/local/bin/cloudflared"
ARGO_LOG="/var/log/argo.log"
REPO_RAW_URL="https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh"

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
        x86_64|amd64)
            ARCH="amd64"
            CF_ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            CF_ARCH="arm64"
            ;;
        *)
            echo -e "${RED}[错误] 不支持的 CPU 架构: $(uname -m)${PLAIN}"
            exit 1
            ;;
    esac
}

# 检测网络栈环境 (纯 IPv6 / 纯 IPv4 / 双栈) 并自动强化 NAT64
detect_network() {
    IPV4_ADDR=$(curl -s4m3 https://api.ipify.org 2>/dev/null || curl -s4m3 https://icanhazip.com 2>/dev/null | tr -d '\n')
    IPV6_ADDR=$(ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -v "fe80" | head -n 1 | awk '{print $2}' | cut -d/ -f1)
    if [[ -z "$IPV6_ADDR" ]]; then
        IPV6_ADDR=$(curl -s6m3 https://api64.ipify.org 2>/dev/null || curl -s6m3 https://icanhazip.com 2>/dev/null | tr -d '\n')
    fi

    if [[ -z "$IPV4_ADDR" && -n "$IPV6_ADDR" ]]; then
        NET_STACK="纯 IPv6 VPS (NAT64 强化)"
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
        NET_STACK="未知网络 (本地回环兜底)"
        SERVER_IP="127.0.0.1"
        OUTBOUND_STRATEGY="prefer_ipv6"
    fi
}

# 为纯 IPv6 VPS 注入高可用 NAT64/DNS64 解析
setup_nat64_dns() {
    detect_network
    if [[ -z "$IPV4_ADDR" && -n "$IPV6_ADDR" ]]; then
        echo -e "${YELLOW}[提示] 检测到当前 VPS 为【纯 IPv6 (如 Hax)】环境，正在注入 DNS64/NAT64 以打通 GitHub 与 Cloudflared 下载...${PLAIN}"
        cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
        cat << 'EOF' > /etc/resolv.conf
nameserver 2a00:1098:2b::1
nameserver 2a01:4f8:c2c:123f::1
nameserver 2a00:1098:2c::1
nameserver 2606:4700:4700::1111
EOF
        echo -e "${GREEN}[OK] DNS64/NAT64 解析强化配置完成！${PLAIN}"
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

# 安装基础依赖工具
install_deps() {
    echo -e "${BLUE}正在检查并安装必要系统工具 (curl / wget / tar / openssl / python3 / jq)...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar jq openssl ufw iptables cron python3 qrencode socat procps >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar jq openssl iptables python3 qrencode socat procps-ng >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1
        apk add bash curl wget tar jq openssl iptables python3 libqrencode socat procps >/dev/null 2>&1
    fi
}

# 下载并安装官方 Sing-box 核心 (自动停止旧进程防止 Text file busy)
install_singbox_binary() {
    local target_ver="${1:-1.11.0}"
    echo -e "${BLUE}=== 正在准备 Sing-box 官方内核 v${target_ver} (${ARCH}) ===${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true
    pkill -9 sing-box 2>/dev/null || true

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
        if curl -fsSL --connect-timeout 8 --max-time 90 "$url" -o "/tmp/sb_dl/${tarball}"; then
            dl_ok=1
            break
        fi
        echo -e "${YELLOW}当前源响应较慢，自动切换备用加速源...${PLAIN}"
    done

    if [[ $dl_ok -eq 0 ]]; then
        echo -e "${RED}[错误] Sing-box 内核下载失败，请检查 VPS 网络或 DNS64 配置！${PLAIN}"
        exit 1
    fi

    tar -zxvf "/tmp/sb_dl/${tarball}" -C /tmp/sb_dl >/dev/null 2>&1
    local extracted_bin
    extracted_bin=$(find /tmp/sb_dl -name "sing-box" -type f | head -n 1)
    rm -f "$BIN_PATH"
    cp -f "$extracted_bin" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf /tmp/sb_dl
    echo -e "${GREEN}[成功] Sing-box 内核安装完成: $($BIN_PATH version 2>/dev/null | head -n 1)${PLAIN}"
}

# 部署标准化双栈订阅服务 (默认返回通用 Base64 完美支持 Karing/v2rayN，带 ?format=clash 返回 YAML)
deploy_sub_server() {
    mkdir -p "$SUB_DIR"
    cat << 'PYEOF' > "${SUB_DIR}/server.py"
#!/usr/bin/env python3
import http.server, socketserver, socket, os, base64, urllib.parse

ENV_PATH = "/etc/sing-box/singbox.env"

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

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_payload(self, code, content_type, data_bytes):
        self.send_response(code)
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
            domain = env.get("DOMAIN_NAME", "").strip()
            target = domain if domain else url_ip
            raw_host = domain if domain else ip
            sni_reality = env.get("REALITY_SNI", "addons.mozilla.org").strip()
            argo = env.get("ARGO_DOMAIN", "").strip()

            links = [
                f"vless://{uuid}@{url_ip}:{env.get('PORT_REALITY', '27409')}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={sni_reality}&fp=chrome&pbk={env.get('REALITY_PUB', '')}&sid={env.get('REALITY_SHORT_ID', '')}&type=tcp#Reality-{ip}",
                f"hysteria2://{env.get('HY2_PWD', '')}@{target}:{env.get('PORT_HY2', '56333')}/?insecure=1&sni={target}#Hy2-{target}",
                f"tuic://{uuid}:{env.get('TUIC_PWD', '')}@{target}:{env.get('PORT_TUIC', '49515')}?congestion_control=bbr&alpn=h3&sni={target}&allow_insecure=1#TUIC5-{target}",
            ]

            if argo:
                links.append(f"naive+https://{env.get('NAIVE_USER', 'admin')}:{env.get('NAIVE_PASS', '')}@{argo}:443#Naive-Argo-Trusted")
            links.append(f"naive+https://{env.get('NAIVE_USER', 'admin')}:{env.get('NAIVE_PASS', '')}@{target}:{env.get('PORT_NAIVE', '33445')}?insecure=1#Naive-Direct-{target}")
            links.append(f"vless://{uuid}@{target}:{env.get('PORT_ANYTLS', '20418')}?security=tls&sni={target}&allow_insecure=1&type=tcp#AnyTLS-{target}")

            fmt = qs.get("format", [""])[0].lower()
            if fmt in ["clash", "meta", "yaml"]:
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
  - name: "Hy2 [{raw_host}]"
    type: hysteria2
    server: "{raw_host}"
    port: {env.get('PORT_HY2', '56333')}
    password: "{env.get('HY2_PWD', '')}"
    sni: "{raw_host}"
    skip-cert-verify: true
  - name: "TUIC5 [{raw_host}]"
    type: tuic
    server: "{raw_host}"
    port: {env.get('PORT_TUIC', '49515')}
    uuid: "{uuid}"
    password: "{env.get('TUIC_PWD', '')}"
    congestion-controller: bbr
    alpn: [h3]
    sni: "{raw_host}"
    skip-cert-verify: true
  - name: "AnyTLS [{raw_host}]"
    type: vless
    server: "{raw_host}"
    port: {env.get('PORT_ANYTLS', '20418')}
    uuid: "{uuid}"
    network: tcp
    tls: true
    servername: "{raw_host}"
    skip-cert-verify: true
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "Reality [{ip}]"
      - "Hy2 [{raw_host}]"
      - "TUIC5 [{raw_host}]"
      - "AnyTLS [{raw_host}]"
rules:
  - MATCH,PROXY
"""
                self.send_payload(200, "text/yaml; charset=utf-8", yaml_content.encode("utf-8"))
            else:
                b64_payload = base64.b64encode("\n".join(links).encode("utf-8"))
                self.send_payload(200, "text/plain; charset=utf-8", b64_payload)
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
Description=SingBox Suite Pro DualStack Subscription Server
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

# 自动安装并开启 Cloudflare Argo 免费临时隧道 (解决 NaiveProxy 无域名 -202 证书报错)
setup_argo_quick_tunnel() {
    source "$ENV_FILE" 2>/dev/null || true
    local naive_port="${PORT_NAIVE:-33445}"

    echo -e "${BLUE}=== 正在配置 Cloudflare Argo 免费临时权威证书隧道 (赋能 NaiveProxy 免证书直通) ===${PLAIN}"
    systemctl stop argo 2>/dev/null || true
    pkill -9 cloudflared 2>/dev/null || true
    rm -f "$ARGO_LOG"

    if [[ ! -x "$ARGO_BIN" ]]; then
        echo -e "正在下载 Cloudflare 官方 cloudflared 二进制程序 (${CF_ARCH})..."
        local cf_urls=(
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
            "https://gh-proxy.com/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
            "https://ghproxy.net/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
        )
        for u in "${cf_urls[@]}"; do
            if curl -fsSL --connect-timeout 8 --max-time 60 "$u" -o "$ARGO_BIN"; then
                chmod +x "$ARGO_BIN"
                break
            fi
        done
    fi

    if [[ ! -x "$ARGO_BIN" ]]; then
        echo -e "${YELLOW}[提示] cloudflared 下载超时，将保留纯 IP 自签证书模式运行 NaiveProxy。${PLAIN}"
        return 1
    fi

    cat << EOF > /etc/systemd/system/argo.service
[Unit]
Description=Cloudflare Argo Quick Tunnel for NaiveProxy
After=network.target

[Service]
Type=simple
ExecStart=${ARGO_BIN} tunnel --url https://localhost:${naive_port} --no-tls-verify --no-autoupdate --edge-ip-version auto
StandardOutput=append:${ARGO_LOG}
StandardError=append:${ARGO_LOG}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now argo >/dev/null 2>&1
    systemctl restart argo

    echo -e "正在向 Cloudflare 全球边缘申请官方权威域名与合法 SSL 证书 (约需 5-8 秒)..."
    local argo_dom=""
    for i in {1..16}; do
        sleep 1
        argo_dom=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | tail -n 1 | sed 's|https://||')
        [[ -n "$argo_dom" ]] && break
    done

    if [[ -n "$argo_dom" ]]; then
        sed -i '/^ARGO_DOMAIN=/d' "$ENV_FILE"
        echo "ARGO_DOMAIN=\"$argo_dom\"" >> "$ENV_FILE"
        systemctl restart singbox-sub 2>/dev/null || true
        echo -e "${GREEN}🎉 Cloudflare Argo 免费权威证书隧道建立成功: https://${argo_dom}${PLAIN}"
        echo -e "${GREEN}✔ Chrome / v2rayN 100% 信任，无需导入自签证书，彻底消除 -202 cert authority invalid！${PLAIN}"
    else
        echo -e "${YELLOW}[提示] 暂未捕获到 Argo 临时域名，可稍后在菜单 [4 -> 5] 查看或刷新隧道状态。${PLAIN}"
    fi
}

# 生成 Sing-box 五协议共存 config.json
write_singbox_config() {
    source "$ENV_FILE"
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
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    },
    {
      "type": "vless",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${PORT_ANYTLS},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_strategy": "${OUTBOUND_STRATEGY}"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": []
  }
}
EOF
}

# 放行防火墙所有协议与订阅端口
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

# 选项 1: 一键全协议安装部署 (支持一路回车或免交互自动完成，默认自动开启 Argo 隧道)
install_singbox() {
    local auto_mode="${1:-0}"
    setup_nat64_dns
    install_deps
    install_singbox_binary "1.11.0"

    mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$SUB_DIR"

    local def_r=$(gen_random_port)
    local def_h=$(gen_random_port)
    local def_t=$(gen_random_port)
    local def_n=$(gen_random_port)
    local def_a=$(gen_random_port)
    local def_s=$(gen_random_port)

    if [[ "$auto_mode" == "1" ]]; then
        DOMAIN_NAME=""
        PORT_REALITY="$def_r"
        PORT_HY2="$def_h"
        PORT_TUIC="$def_t"
        PORT_NAIVE="$def_n"
        PORT_ANYTLS="$def_a"
        SUB_PORT="$def_s"
        REALITY_SNI="addons.mozilla.org"
        ENABLE_ARGO="y"
    else
        echo -e "\n${GREEN}=== 配置五协议共存参数 (直接一路按回车即采用推荐随机高位端口与自动 Argo 隧道) ===${PLAIN}"
        read -rp "请输入解析域名 (留空默认使用纯 IP + 自动 Argo 免费权威证书隧道): " DOMAIN_NAME
        read -rp "请输入 VLESS-Reality 端口 [默认随机 ${def_r}]: " PORT_REALITY
        PORT_REALITY="${PORT_REALITY:-$def_r}"
        read -rp "请输入 Reality 伪装域名 SNI [默认 addons.mozilla.org]: " REALITY_SNI
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        read -rp "请输入 Hysteria 2 (UDP) 端口 [默认随机 ${def_h}]: " PORT_HY2
        PORT_HY2="${PORT_HY2:-$def_h}"
        read -rp "请输入 TUIC v5 (UDP) 端口 [默认随机 ${def_t}]: " PORT_TUIC
        PORT_TUIC="${PORT_TUIC:-$def_t}"
        read -rp "请输入 NaiveProxy 端口 [默认随机 ${def_n}]: " PORT_NAIVE
        PORT_NAIVE="${PORT_NAIVE:-$def_n}"
        read -rp "请输入 AnyTLS (TCP) 端口 [默认随机 ${def_a}]: " PORT_ANYTLS
        PORT_ANYTLS="${PORT_ANYTLS:-$def_a}"
        read -rp "请输入在线订阅服务端口 [默认随机 ${def_s}]: " SUB_PORT
        SUB_PORT="${SUB_PORT:-$def_s}"
        read -rp "是否自动开启 Cloudflare Argo 免费隧道解决 NaiveProxy 证书问题? [Y/n, 默认 Y]: " ENABLE_ARGO
        ENABLE_ARGO="${ENABLE_ARGO:-y}"
    fi

    echo -e "${BLUE}正在生成 UUID、Reality 密钥对与自签 EC 证书...${PLAIN}"
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

    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" \
        -subj "/CN=${DOMAIN_NAME:-$SERVER_IP}" -days 3650 >/dev/null 2>&1
    chmod 644 "${CERT_DIR}/server.crt"
    chmod 600 "${CERT_DIR}/server.key"

    cat << EOF > "$ENV_FILE"
SERVER_IP="${SERVER_IP}"
SERVER_IPV4="${IPV4_ADDR}"
SERVER_IPV6="${IPV6_ADDR}"
DOMAIN_NAME="${DOMAIN_NAME}"
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
ARGO_DOMAIN=""
EOF

    write_singbox_config

    cat << 'EOF' > /etc/systemd/system/sing-box.service
[Unit]
Description=Sing-box Service (SingBox Suite Pro)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
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

    # 默认自动启动 Argo 免费临时隧道，彻底解决 NaiveProxy 无域名证书报错
    if [[ "$ENABLE_ARGO" =~ ^[Yy]$ ]]; then
        setup_argo_quick_tunnel
    fi

    # 创建快捷指令 sb
    if [[ "$0" != "$SHORTCUT_PATH" && -f "$0" ]]; then
        cp -f "$0" "$SHORTCUT_PATH" 2>/dev/null || true
        chmod +x "$SHORTCUT_PATH" 2>/dev/null || true
    fi

    show_nodes
}

# 选项 7: 刷新并打印全部五协议节点与订阅链接
show_nodes() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}[提示] 尚未安装配置 Sing-box，请先运行选项 1 进行安装！${PLAIN}"
        return
    fi

    detect_network
    source "$ENV_FILE"
    if [[ "$SERVER_IP" == "127.0.0.1" || -z "$SERVER_IP" ]]; then
        SERVER_IP="${IPV6_ADDR:-$IPV4_ADDR}"
        sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$SERVER_IP\"|" "$ENV_FILE"
    fi

    # 若启用了 Argo 服务，尝试同步最新临时域名
    if systemctl is-active --quiet argo 2>/dev/null && [[ -f "$ARGO_LOG" ]]; then
        local latest_argo
        latest_argo=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | tail -n 1 | sed 's|https://||')
        if [[ -n "$latest_argo" && "$latest_argo" != "$ARGO_DOMAIN" ]]; then
            ARGO_DOMAIN="$latest_argo"
            sed -i '/^ARGO_DOMAIN=/d' "$ENV_FILE"
            echo "ARGO_DOMAIN=\"$ARGO_DOMAIN\"" >> "$ENV_FILE"
        fi
    fi

    local url_ip="${SERVER_IP}"
    [[ "$SERVER_IP" == *":"* ]] && url_ip="[${SERVER_IP}]"
    local target="${DOMAIN_NAME:-$url_ip}"

    echo -e "\n${GREEN}======================================================================${PLAIN}"
    echo -e "${BOLD}                  Sing-Box 五协议节点配置与在线订阅信息               ${PLAIN}"
    echo -e "${GREEN}======================================================================${PLAIN}"
    echo -e " 服务器主 IP  : ${BLUE}${SERVER_IP}${PLAIN}"
    echo -e " UUID 标识    : ${BLUE}${UUID}${PLAIN}"
    echo -e " 出站优先级   : ${BLUE}${OUTBOUND_STRATEGY:-prefer_ipv6}${PLAIN}"
    [[ -n "$ARGO_DOMAIN" ]] && echo -e " Argo 权威域名: ${GREEN}${ARGO_DOMAIN} (Cloudflare 官方 CA 证书)${PLAIN}"
    echo -e "----------------------------------------------------------------------"
    echo -e "${YELLOW}【通用分享链接 (Universal URI - 复制导入 v2rayN / Karing / 小火箭)】${PLAIN}\n"

    echo -e "${BOLD}1. VLESS-Reality-Vision (端口 ${PORT_REALITY} | 伪装 ${REALITY_SNI}):${PLAIN}"
    echo -e "${GREEN}vless://${UUID}@${url_ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SHORT_ID}&type=tcp#Reality-${SERVER_IP}${PLAIN}\n"

    echo -e "${BOLD}2. Hysteria 2 (端口 ${PORT_HY2} | UDP/QUIC 极速抗丢包):${PLAIN}"
    echo -e "${GREEN}hysteria2://${HY2_PWD}@${target}:${PORT_HY2}/?insecure=1&sni=${target}#Hy2-${target}${PLAIN}\n"

    echo -e "${BOLD}3. TUIC v5 (端口 ${PORT_TUIC} | UDP BBR 多路复用):${PLAIN}"
    echo -e "${GREEN}tuic://${UUID}:${TUIC_PWD}@${target}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&sni=${target}&allow_insecure=1#TUIC5-${target}${PLAIN}\n"

    echo -e "${BOLD}4. NaiveProxy (请确保 v2rayN 参数设置中已关闭 TLS Fragment 分片):${PLAIN}"
    if [[ -n "$ARGO_DOMAIN" ]]; then
        echo -e "${GREEN}[✔ 已自动挂载 Cloudflare Argo 免费权威证书隧道，免导证书 100% 消除 -202 报错]${PLAIN}"
        echo -e "${GREEN}naive+https://${NAIVE_USER}:${NAIVE_PASS}@${ARGO_DOMAIN}:443#Naive-Argo-Trusted${PLAIN}"
        echo -e "   (备选纯 IP 直连端口 ${PORT_NAIVE}: naive+https://${NAIVE_USER}:${NAIVE_PASS}@${target}:${PORT_NAIVE}?insecure=1#Naive-Direct-${target})\n"
    else
        echo -e "${GREEN}naive+https://${NAIVE_USER}:${NAIVE_PASS}@${target}:${PORT_NAIVE}?insecure=1#Naive-${target}${PLAIN}\n"
    fi

    echo -e "${BOLD}5. AnyTLS / VLESS-TLS (端口 ${PORT_ANYTLS} | 标准 TCP+TLS):${PLAIN}"
    echo -e "${GREEN}vless://${UUID}@${target}:${PORT_ANYTLS}?security=tls&sni=${target}&allow_insecure=1&type=tcp#AnyTLS-${target}${PLAIN}"

    echo -e "----------------------------------------------------------------------"
    echo -e "${YELLOW}【一键在线订阅地址 (原生支持 Karing / v2rayN / Shadowrocket / Clash.Meta)】${PLAIN}"
    echo -e " 通用 Base64 订阅链接 (推荐 Karing / v2rayN / 小火箭 直接填入):"
    echo -e " ${GREEN}http://${url_ip}:${SUB_PORT}/sub?token=${SUB_TOKEN}${PLAIN}\n"
    echo -e " Clash.Meta / Mihomo 专属 YAML 订阅链接:"
    echo -e " ${GREEN}http://${url_ip}:${SUB_PORT}/sub?token=${SUB_TOKEN}&format=clash${PLAIN}"
    echo -e "${GREEN}======================================================================${PLAIN}"
}

# 选项 2: 干净卸载
uninstall_singbox() {
    echo -e "${YELLOW}正在停止并卸载 Sing-box、Argo 隧道与订阅微服务...${PLAIN}"
    systemctl stop sing-box singbox-sub argo 2>/dev/null || true
    systemctl disable sing-box singbox-sub argo 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/singbox-sub.service /etc/systemd/system/argo.service
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR" "$BIN_PATH" "$ARGO_BIN" "$ARGO_LOG"
    echo -e "${GREEN}[OK] Sing-box 全套组件已彻底卸载干净！${PLAIN}"
}

# 选项 3: 启停与状态管理
manage_service() {
    echo -e "\n=== 服务启停与运行状态管理 ==="
    echo " 1. 启动全部服务 (Sing-box + 订阅 + Argo)"
    echo " 2. 停止全部服务"
    echo " 3. 重启全部服务"
    echo " 4. 查看详细 systemctl 状态"
    echo " 0. 返回主菜单"
    read -rp "请选择 [0-4]: " s_choice
    case "$s_choice" in
        1) systemctl start sing-box singbox-sub argo 2>/dev/null; echo -e "${GREEN}[OK] 已启动！${PLAIN}" ;;
        2) systemctl stop sing-box singbox-sub argo 2>/dev/null; echo -e "${YELLOW}[OK] 已停止！${PLAIN}" ;;
        3) systemctl restart sing-box singbox-sub argo 2>/dev/null; echo -e "${GREEN}[OK] 已重启！${PLAIN}" ;;
        4) systemctl status sing-box singbox-sub argo --no-pager | head -n 35 ;;
    esac
}

# 选项 4: 变更核心配置 (含 Argo 隧道管理)
modify_config() {
    source "$ENV_FILE" 2>/dev/null || { echo -e "${RED}请先安装 Sing-box！${PLAIN}"; return; }
    echo -e "\n=== 变更核心配置选项 ==="
    echo " 1. 重新生成并更换 UUID"
    echo " 2. 重新生成 Hysteria 2 / TUIC / Naive 密码"
    echo " 3. 切换出站策略【prefer_ipv6 / prefer_ipv4】"
    echo " 4. 更换 Reality 伪装域名 SNI (当前: ${REALITY_SNI})"
    echo " 5. 管理 Cloudflare Argo 免费隧道 (当前域名: ${ARGO_DOMAIN:-未开启})"
    echo " 6. 重新生成订阅安全 Token"
    echo " 0. 返回主菜单"
    read -rp "请选择 [0-6]: " m_choice
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
            read -rp "请输入新的 Reality 伪装域名 [默认 addons.mozilla.org]: " new_sni
            REALITY_SNI="${new_sni:-addons.mozilla.org}"
            sed -i "s|^REALITY_SNI=.*|REALITY_SNI=\"$REALITY_SNI\"|" "$ENV_FILE"
            write_singbox_config && systemctl restart sing-box singbox-sub
            echo -e "${GREEN}[OK] Reality 伪装源已更新为: $REALITY_SNI${PLAIN}"
            ;;
        5)
            echo -e "\n=== Cloudflare Argo 免费隧道管理 (解决 NaiveProxy 证书报错) ==="
            echo " 1. 开启 / 重新申请 Argo 免费临时隧道 (*.trycloudflare.com 权威证书)"
            echo " 2. 关闭并停止 Argo 隧道 (切回纯 IP 直连模式)"
            echo " 0. 返回"
            read -rp "请选择 [0-2]: " a_choice
            if [[ "$a_choice" == "1" ]]; then
                setup_argo_quick_tunnel
                show_nodes
            elif [[ "$a_choice" == "2" ]]; then
                systemctl stop argo 2>/dev/null || true
                systemctl disable argo 2>/dev/null || true
                sed -i 's|^ARGO_DOMAIN=.*|ARGO_DOMAIN=""|' "$ENV_FILE"
                systemctl restart singbox-sub 2>/dev/null || true
                echo -e "${YELLOW}[OK] Argo 隧道已关闭。${PLAIN}"
            fi
            ;;
        6)
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
    if systemctl is-active --quiet argo 2>/dev/null; then
        setup_argo_quick_tunnel
    fi
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

# 主菜单渲染 (严格按 1-13 顺次排列 + 致敬 ygkkk 与 fscarmen)
show_menu() {
    check_arch
    detect_network
    local ver="未安装"
    [[ -x "$BIN_PATH" ]] && ver="v$($BIN_PATH version 2>/dev/null | head -n 1 | awk '{print $3}')"
    local status="${RED}○ 已停止${PLAIN}"
    systemctl is-active --quiet sing-box 2>/dev/null && status="${GREEN}● 正在运行${PLAIN}"
    local argo_stat="${YELLOW}未启用${PLAIN}"
    systemctl is-active --quiet argo 2>/dev/null && argo_stat="${GREEN}● 已挂载权威证书隧道${PLAIN}"

    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║${PLAIN}      ${BOLD}SingBox Suite Pro — 现代化全协议聚合部署套件 (All-In-One)${PLAIN}       ${BLUE}║${PLAIN}"
    echo -e "${BLUE}║${PLAIN}   VLESS-Reality • Hysteria 2 • TUIC v5 • AnyTLS • NaiveProxy+Argo    ${BLUE}║${PLAIN}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════╝${PLAIN}"
    echo -e " 系统架构: ${GREEN}${ARCH}${PLAIN} | 网络环境: ${GREEN}${NET_STACK}${PLAIN} | 快捷指令: ${YELLOW}sb${PLAIN}"
    echo -e " 核心版本: ${GREEN}${ver}${PLAIN} | 服务状态: ${status} | Argo 隧道: ${argo_stat}"
    echo -e "──────────────────────────────────────────────────────────────────────"
    echo -e " ${BOLD}【核心部署与控制】${PLAIN}"
    echo -e "   ${GREEN}1.${PLAIN} 一键全协议安装部署 (五大协议共存 / 默认随机高位端口 + 自动 Argo 隧道)"
    echo -e "   ${GREEN}2.${PLAIN} 干净卸载 Sing-box (彻底移除二进制、配置、Argo 与订阅守护服务)"
    echo -e "   ${GREEN}3.${PLAIN} 启停与状态管理 (启动 / 停止 / 重启 Sing-box 及附属服务)"
    echo ""
    echo -e " ${BOLD}【节点配置与端口管理】${PLAIN}"
    echo -e "   ${GREEN}4.${PLAIN} 变更核心配置 (UUID / 密码 / 出站优先级 / Argo 隧道开关 / 订阅 Token)"
    echo -e "   ${GREEN}5.${PLAIN} 协议端口调整与一键随机刷新 (规避运营商封锁与 UDP QoS)"
    echo -e "   ${GREEN}6.${PLAIN} 管理 Acme.sh 域名证书 (支持自有域名 Standalone 申请)"
    echo ""
    echo -e " ${BOLD}【订阅管理与分流解锁】${PLAIN}"
    echo -e "   ${GREEN}7.${PLAIN} 刷新查看节点配置与订阅链接 (通用 Base64 / Karing / Clash.Meta)"
    echo -e "   ${GREEN}8.${PLAIN} 路由分流管理 (纯净直连模式 / 屏蔽广告与 BT)"
    echo -e "   ${GREEN}9.${PLAIN} 网络连通性与流媒体解锁自检 (IPv6 / NAT64 / YouTube / ChatGPT 检测)"
    echo ""
    echo -e " ${BOLD}【系统优化与工具维护】${PLAIN}"
    echo -e "   ${GREEN}10.${PLAIN} 实时查看运行日志 (追踪 Sing-box 与 Argo 证书隧道状态)"
    echo -e "   ${GREEN}11.${PLAIN} 一键原版 BBR + FQ 加速 (内核网络拥塞控制调优)"
    echo -e "   ${GREEN}12.${PLAIN} 官方内核版本切换 (一键重装或升级 Sing-box 核心)"
    echo -e "   ${GREEN}13.${PLAIN} 在线拉取更新部署脚本 (同步 GitHub 仓库最新 sb.sh)"
    echo -e "──────────────────────────────────────────────────────────────────────"
    echo -e "   ${GREEN}0.${PLAIN} 退出管理控制台"
    echo -e "──────────────────────────────────────────────────────────────────────"
    echo -e " ${PURPLE}❤ 致敬与特别鸣谢: 本脚本基于并深度修改自 ygkkk (甬哥) 与 fscarmen (F佬) 的开源脚本！${PLAIN}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════${PLAIN}"
}

# 命令行快捷参数支持 (如 sb 1 自动安装, sb 7 / sb 9 查看节点)
check_root
check_arch
if [[ $# -gt 0 ]]; then
    case "$1" in
        1|-y|--yes) install_singbox "1"; exit 0 ;;
        2) uninstall_singbox; exit 0 ;;
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
        6)
            echo -e "${YELLOW}[提示] 当前已内置 Cloudflare Argo 自动权威证书隧道，无需购买域名即可让全协议 100% 连通。${PLAIN}"
            ;;
        7) show_nodes ;;
        8)
            write_singbox_config && systemctl restart sing-box
            echo -e "${GREEN}[OK] 已校准为纯净无 geosite 依赖路由规则，防止容器环境崩溃！${PLAIN}"
            ;;
        9)
            echo -e "${BLUE}正在测试 VPS 出站连通性...${PLAIN}"
            curl -s6m5 https://www.cloudflare.com/cdn-cgi/trace | grep -E "ip=|loc=|warp=" || true
            ;;
        10) journalctl -u sing-box -u argo -n 35 --no-pager ;;
        11) enable_bbr ;;
        12)
            read -rp "请输入要安装的 Sing-box 官方版本号 [默认 1.11.0]: " v_tag
            install_singbox_binary "${v_tag:-1.11.0}"
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
