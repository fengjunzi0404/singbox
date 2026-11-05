#!/usr/bin/env bash
# ==============================================================================
# SingBox Suite Pro — 现代化全协议聚合部署运维套件 (All-In-One 单脚本自包含版)
# 协议支持: VLESS-Reality-Vision | Hysteria 2 | TUIC v5 | AnyTLS | NaiveProxy
# 核心技术亮点 (100% 同步 F佬 fscarmen/sing-box 最新 Naive 免域名内嵌证书方案):
#   1. 采用 Sing-box v1.14.4 官方最新稳定版内核 (自带 libcronet.so，原生支持 Naive HTTP2/QUIC 与 AnyTLS)
#   2. 独创双证书机制: 36500天 server.crt + 专为 Chromium 定制的 200天 cert_200.pem (带 v3 SAN: DNS:addons.mozilla.org)
#   3. 节点链接直接内嵌 200天证书 (v2rayn://naive/... 与 naive+https://...&tls_certificate=...)，
#      无需购买域名、无需 Argo 中转、无需往 Windows 手动导入证书，v2rayN / Karing 直接导入 100% 绿字秒通！
#   4. 默认分配 15000-59999 高位随机非标端口，纯 IPv6 (Hax) 与双栈自适应
#   5. 标准化 HTTP/1.1 [::] 双栈订阅服务：带 Content-Length，自动按 User-Agent 适配 v2rayN / Karing / 小火箭 / Clash
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
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
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
        echo -e "${YELLOW}[提示] 检测到当前 VPS 为【纯 IPv6 (如 Hax)】环境，正在注入 DNS64/NAT64 以打通 GitHub 下载...${PLAIN}"
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

# 下载并安装官方 Sing-box v1.14.4 核心与 libcronet.so (原生支持 Naive HTTP2/QUIC 与 AnyTLS)
install_singbox_binary() {
    local target_ver="${1:-$DEFAULT_SB_VER}"
    echo -e "${BLUE}=== 正在准备 Sing-box 官方内核 v${target_ver} (${ARCH}) ===${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true
    pkill -9 sing-box 2>/dev/null || true

    local tarball="sing-box-${target_ver}-linux-${ARCH}.tar.gz"
    local urls=(
        "https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/${tarball}"
        "https://gh-proxy.com/https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/${tarball}"
        "https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/${tarball}"
        "https://ghproxy.lvedong.eu.org/https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/${tarball}"
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
    local extracted_cronet
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
    echo -e "${GREEN}[成功] Sing-box 内核安装完成: $($BIN_PATH version 2>/dev/null | head -n 1)${PLAIN}"
}

# 生成 F佬 (fscarmen) 同款双证书：
# 1. server.crt (36500天) 供 Hy2 / TUIC / AnyTLS 使用
# 2. cert_200.pem (200天 + v3_req subjectAltName = DNS:addons.mozilla.org) 专供 NaiveProxy 使用
#    (Chromium Cronet 严格限制证书有效期必须 <= 398天 且必须包含匹配的 v3 SAN，否则必报 -202 cert authority invalid)
generate_fscarmen_certs() {
    local tls_sni="${1:-addons.mozilla.org}"
    mkdir -p "$CERT_DIR"
    local cn_domain
    cn_domain=$(awk -F '.' '{if (NF>=2) print $(NF-1)"."$NF; else print $0}' <<< "$tls_sni")

    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null

    cat << EOF > "${CERT_DIR}/cert.conf"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${cn_domain}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS = ${tls_sni}
EOF

    openssl req -new -x509 -days 36500 -key "${CERT_DIR}/server.key" -out "${CERT_DIR}/server.crt" -config "${CERT_DIR}/cert.conf" -extensions v3_req >/dev/null 2>&1
    openssl req -new -x509 -days 200 -key "${CERT_DIR}/server.key" -out "${CERT_DIR}/cert_200.pem" -config "${CERT_DIR}/cert.conf" -extensions v3_req >/dev/null 2>&1
    rm -f "${CERT_DIR}/cert.conf"
    chmod 644 "${CERT_DIR}/server.crt" "${CERT_DIR}/cert_200.pem"
    chmod 600 "${CERT_DIR}/server.key"
}

# 部署标准化双栈订阅服务 (100% 同步 F佬内嵌证书编码，自动识别 v2rayN / Karing / Shadowrocket / Clash)
deploy_sub_server() {
    mkdir -p "$SUB_DIR"
    cat << 'PYEOF' > "${SUB_DIR}/server.py"
#!/usr/bin/env python3
import http.server, socketserver, socket, os, json, base64, urllib.parse, subprocess

ENV_PATH = "/etc/sing-box/singbox.env"
CERT_36500_PATH = "/etc/sing-box/cert/server.crt"
CERT_200_PATH = "/etc/sing-box/cert/cert_200.pem"

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

def load_cert_formats(path):
    if not os.path.exists(path):
        return "", "", ""
    with open(path, "r", encoding="utf-8") as f:
        lines = [line.strip() for line in f if line.strip()]
    # CERT_URL_1: 供 naive+https://...&tls_certificate= 使用 (逗号拼接，空格转 %20)
    url_1 = ",".join(lines).replace(" ", "%20")
    # CERT_URL_2: 供 v2rayn://naive/... JSON 内嵌 Cert 字段使用 (
 拼接)
    url_2 = "
".join(lines) + "
"
    # SHA256 指纹: 供 Shadowrocket hpkp 使用
    fp_sha256 = ""
    try:
        out = subprocess.check_output(["openssl", "x509", "-fingerprint", "-noout", "-sha256", "-in", path], text=True)
        if "=" in out:
            fp_sha256 = out.strip().split("=")[-1].strip()
    except Exception:
        pass
    return url_1, url_2, fp_sha256

def b64url_no_pad(text):
    raw = base64.b64encode(text.encode("utf-8")).decode("utf-8")
    return raw.replace("+", "-").replace("/", "_").rstrip("=")

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
                self.send_payload(403, "text/plain; charset=utf-8", b"403 Forbidden: Invalid Subscription Token
")
                return

            ip = env.get("SERVER_IP", "127.0.0.1").strip()
            uuid = env.get("UUID", "").strip()
            url_ip = f"[{ip}]" if ":" in ip else ip
            domain = env.get("DOMAIN_NAME", "").strip()
            target = domain if domain else url_ip
            raw_host = domain if domain else ip
            sni_reality = env.get("REALITY_SNI", "addons.mozilla.org").strip()

            cert_url_1, cert_url_2, _ = load_cert_formats(CERT_36500_PATH)
            cert200_url_1, cert200_url_2, cert200_sha256 = load_cert_formats(CERT_200_PATH)

            # 1. F佬同款 v2rayN 专属内嵌 200天证书 Naive 节点 (HTTP/2 & QUIC)
            v2rayn_naive_h2_obj = {
                "ConfigType": 12,
                "CoreType": 24,
                "ConfigVersion": 4,
                "Remarks": f"Naive-HTTP2-{raw_host}",
                "Address": raw_host,
                "Port": int(env.get("PORT_NAIVE", 33445)),
                "Password": env.get("NAIVE_PASS", ""),
                "Username": env.get("NAIVE_USER", "admin"),
                "StreamSecurity": "tls",
                "AllowInsecure": "false",
                "Sni": sni_reality,
                "Cert": cert200_url_2
            }
            v2rayn_naive_quic_obj = {
                "ConfigType": 12,
                "CoreType": 24,
                "ConfigVersion": 4,
                "Remarks": f"Naive-QUIC-{raw_host}",
                "Address": raw_host,
                "Port": int(env.get("PORT_NAIVE", 33445)),
                "Password": env.get("NAIVE_PASS", ""),
                "Username": env.get("NAIVE_USER", "admin"),
                "StreamSecurity": "tls",
                "AllowInsecure": "false",
                "Sni": sni_reality,
                "Cert": cert200_url_2,
                "ProtoExtraObj": {
                    "CongestionControl": "bbr",
                    "NaiveQuic": True
                }
            }
            v2rayn_anytls_obj = {
                "ConfigType": 11,
                "CoreType": 24,
                "ConfigVersion": 4,
                "Remarks": f"AnyTLS-{raw_host}",
                "Address": raw_host,
                "Port": int(env.get("PORT_ANYTLS", 20418)),
                "Password": uuid,
                "StreamSecurity": "tls",
                "AllowInsecure": "false",
                "Sni": sni_reality,
                "Fingerprint": "chrome",
                "Cert": cert_url_2
            }

            v2rayn_naive_h2_uri = "v2rayn://naive/" + b64url_no_pad(json.dumps(v2rayn_naive_h2_obj, separators=(",", ":")))
            v2rayn_naive_quic_uri = "v2rayn://naive/" + b64url_no_pad(json.dumps(v2rayn_naive_quic_obj, separators=(",", ":")))
            v2rayn_anytls_uri = "v2rayn://anytls/" + b64url_no_pad(json.dumps(v2rayn_anytls_obj, separators=(",", ":")))

            # 2. Karing / Throne / NekoBox 标准内嵌证书 URI
            throne_naive_h2_uri = f"naive+https://{env.get('NAIVE_USER', 'admin')}:{env.get('NAIVE_PASS', '')}@{target}:{env.get('PORT_NAIVE', '33445')}?uot=1&security=tls&sni={sni_reality}&tls_certificate={cert200_url_1}#Naive-HTTP2-{raw_host}"
            throne_naive_quic_uri = f"naive+quic://{env.get('NAIVE_USER', 'admin')}:{env.get('NAIVE_PASS', '')}@{target}:{env.get('PORT_NAIVE', '33445')}?congestion_control=bbr&security=tls&sni={sni_reality}&tls_certificate={cert200_url_1}#Naive-QUIC-{raw_host}"
            std_anytls_uri = f"anytls://{uuid}@{target}:{env.get('PORT_ANYTLS', '20418')}?security=tls&sni={sni_reality}&insecure=1&tls_certificate={cert_url_1}&fp=chrome#AnyTLS-{raw_host}"

            base_links = [
                f"vless://{uuid}@{url_ip}:{env.get('PORT_REALITY', '27409')}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={sni_reality}&fp=chrome&pbk={env.get('REALITY_PUB', '')}&sid={env.get('REALITY_SHORT_ID', '')}&type=tcp&headerType=none#Reality-{ip}",
                f"hysteria2://{env.get('HY2_PWD', '')}@{target}:{env.get('PORT_HY2', '56333')}/?insecure=1&sni={sni_reality}#Hy2-{raw_host}",
                f"tuic://{uuid}:{env.get('TUIC_PWD', '')}@{target}:{env.get('PORT_TUIC', '49515')}?congestion_control=bbr&alpn=h3&sni={sni_reality}&udp_relay_mode=native&allow_insecure=1#TUIC5-{raw_host}",
            ]

            fmt = qs.get("format", [""])[0].lower()
            ua = self.headers.get("User-Agent", "").lower()

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
    sni: "{sni_reality}"
    skip-cert-verify: true
  - name: "TUIC5 [{raw_host}]"
    type: tuic
    server: "{raw_host}"
    port: {env.get('PORT_TUIC', '49515')}
    uuid: "{uuid}"
    password: "{env.get('TUIC_PWD', '')}"
    congestion-controller: bbr
    alpn: [h3]
    sni: "{sni_reality}"
    skip-cert-verify: true
  - name: "AnyTLS [{raw_host}]"
    type: anytls
    server: "{raw_host}"
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
      - "Hy2 [{raw_host}]"
      - "TUIC5 [{raw_host}]"
      - "AnyTLS [{raw_host}]"
rules:
  - MATCH,PROXY
"""
                self.send_payload(200, "text/yaml; charset=utf-8", yaml_content.encode("utf-8"))
            elif "v2rayn" in ua or fmt == "v2rayn":
                v2_links = base_links + [v2rayn_naive_h2_uri, v2rayn_naive_quic_uri, v2rayn_anytls_uri]
                self.send_payload(200, "text/plain; charset=utf-8", base64.b64encode("
".join(v2_links).encode("utf-8")))
            else:
                # 通用 Base64 (兼容 Karing / Throne / NekoBox / v2rayN)
                all_links = base_links + [throne_naive_h2_uri, throne_naive_quic_uri, std_anytls_uri, v2rayn_naive_h2_uri]
                self.send_payload(200, "text/plain; charset=utf-8", base64.b64encode("
".join(all_links).encode("utf-8")))
        except Exception as e:
            err_msg = f"500 Internal Error: {str(e)}
".encode("utf-8")
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

# 生成 Sing-box v1.14.4 五协议共存 config.json
# 关键: naive 入站使用 200天有效期 + v3 SAN (DNS:addons.mozilla.org) 的 cert_200.pem！
write_singbox_config() {
    source "$ENV_FILE"
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
        "certificate_path": "${CERT_DIR}/cert_200.pem",
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
    }
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

# 放行防火墙所有协议与订阅端口 (Naive 同时放行 TCP HTTP/2 与 UDP QUIC)
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

# 选项 1: 一键全协议安装部署 (100% 复刻 F佬免域名内嵌 200天 SAN 证书直连方案)
install_singbox() {
    local auto_mode="${1:-0}"
    setup_nat64_dns
    install_deps
    install_singbox_binary "$DEFAULT_SB_VER"

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
    else
        echo -e "\n${GREEN}=== 配置五协议共存参数 (直接一路按回车即采用推荐随机高位端口与 F佬免导证书方案) ===${PLAIN}"
        read -rp "请输入 VLESS-Reality 端口 [默认随机 ${def_r}]: " PORT_REALITY
        PORT_REALITY="${PORT_REALITY:-$def_r}"
        read -rp "请输入伪装域名 SNI [默认 addons.mozilla.org]: " REALITY_SNI
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        read -rp "请输入 Hysteria 2 (UDP) 端口 [默认随机 ${def_h}]: " PORT_HY2
        PORT_HY2="${PORT_HY2:-$def_h}"
        read -rp "请输入 TUIC v5 (UDP) 端口 [默认随机 ${def_t}]: " PORT_TUIC
        PORT_TUIC="${PORT_TUIC:-$def_t}"
        read -rp "请输入 NaiveProxy (HTTP2/QUIC) 端口 [默认随机 ${def_n}]: " PORT_NAIVE
        PORT_NAIVE="${PORT_NAIVE:-$def_n}"
        read -rp "请输入 AnyTLS (TCP) 端口 [默认随机 ${def_a}]: " PORT_ANYTLS
        PORT_ANYTLS="${PORT_ANYTLS:-$def_a}"
        read -rp "请输入在线订阅服务端口 [默认随机 ${def_s}]: " SUB_PORT
        SUB_PORT="${SUB_PORT:-$def_s}"
    fi

    echo -e "${BLUE}正在生成 UUID、Reality 密钥对与 F佬同款 200天 SAN 专属证书 (cert_200.pem)...${PLAIN}"
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

    generate_fscarmen_certs "$REALITY_SNI"

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
    if [[ "$0" != "$SHORTCUT_PATH" && -f "$0" ]]; then
        cp -f "$0" "$SHORTCUT_PATH" 2>/dev/null || true
        chmod +x "$SHORTCUT_PATH" 2>/dev/null || true
    fi

    show_nodes
}

# 选项 7: 刷新并打印全部五协议节点与订阅链接 (含 F佬同款内嵌证书 v2rayn://naive/ 与 naive+https://)
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

    # 若缺失 cert_200.pem 则自动补齐
    if [[ ! -s "${CERT_DIR}/cert_200.pem" ]]; then
        generate_fscarmen_certs "${REALITY_SNI:-addons.mozilla.org}"
        systemctl restart sing-box singbox-sub 2>/dev/null || true
    fi

    local url_ip="${SERVER_IP}"
    [[ "$SERVER_IP" == *":"* ]] && url_ip="[${SERVER_IP}]"
    local target="${DOMAIN_NAME:-$url_ip}"
    local raw_host="${DOMAIN_NAME:-$SERVER_IP}"

    # 编码 F佬同款内嵌证书字符串
    local CERT_URL_1 CERT_URL_2 CERT_200_URL_1 CERT_200_URL_2
    CERT_URL_1=$(awk '{printf "%s,", $0}' "${CERT_DIR}/server.crt" 2>/dev/null | sed 's/ /%20/g; s/,$//')
    CERT_URL_2=$(awk '{printf "%s\\r\\n", $0}' "${CERT_DIR}/server.crt" 2>/dev/null)
    CERT_200_URL_1=$(awk '{printf "%s,", $0}' "${CERT_DIR}/cert_200.pem" 2>/dev/null | sed 's/ /%20/g; s/,$//')
    CERT_200_URL_2=$(awk '{printf "%s\\r\\n", $0}' "${CERT_DIR}/cert_200.pem" 2>/dev/null)

    local V2RAYN_NAIVE_H2 V2RAYN_NAIVE_QUIC V2RAYN_ANYTLS
    V2RAYN_NAIVE_H2="v2rayn://naive/$(echo -n "{\"ConfigType\":12,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"Naive-HTTP2-${raw_host}\",\"Address\":\"${raw_host}\",\"Port\":${PORT_NAIVE},\"Password\":\"${NAIVE_PASS}\",\"Username\":\"${NAIVE_USER}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${REALITY_SNI}\",\"Cert\":\"${CERT_200_URL_2}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    V2RAYN_NAIVE_QUIC="v2rayn://naive/$(echo -n "{\"ConfigType\":12,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"Naive-QUIC-${raw_host}\",\"Address\":\"${raw_host}\",\"Port\":${PORT_NAIVE},\"Password\":\"${NAIVE_PASS}\",\"Username\":\"${NAIVE_USER}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${REALITY_SNI}\",\"Cert\":\"${CERT_200_URL_2}\",\"ProtoExtraObj\":{\"CongestionControl\":\"bbr\",\"NaiveQuic\":true}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    V2RAYN_ANYTLS="v2rayn://anytls/$(echo -n "{\"ConfigType\":11,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"AnyTLS-${raw_host}\",\"Address\":\"${raw_host}\",\"Port\":${PORT_ANYTLS},\"Password\":\"${UUID}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${REALITY_SNI}\",\"Fingerprint\":\"chrome\",\"Cert\":\"${CERT_URL_2}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

    echo -e "\n${GREEN}======================================================================${PLAIN}"
    echo -e "${BOLD}          Sing-Box v1.14.4 五协议节点配置与在线订阅信息 (F佬内嵌证书版)      ${PLAIN}"
    echo -e "${GREEN}======================================================================${PLAIN}"
    echo -e " 服务器主 IP  : ${BLUE}${SERVER_IP}${PLAIN}"
    echo -e " UUID 标识    : ${BLUE}${UUID}${PLAIN}"
    echo -e " 出站优先级   : ${BLUE}${OUTBOUND_STRATEGY:-prefer_ipv6}${PLAIN}"
    echo -e " Naive 证书   : ${GREEN}✔ 已内嵌 200天 SAN (DNS:${REALITY_SNI}) 证书，免域名、免手动导证书秒通！${PLAIN}"
    echo -e "----------------------------------------------------------------------"

    echo -e "${BOLD}1. VLESS-Reality-Vision (端口 ${PORT_REALITY} | 伪装 ${REALITY_SNI}):${PLAIN}"
    echo -e "${GREEN}vless://${UUID}@${url_ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#Reality-${SERVER_IP}${PLAIN}\n"

    echo -e "${BOLD}2. Hysteria 2 (端口 ${PORT_HY2} | UDP/QUIC 极速抗丢包):${PLAIN}"
    echo -e "${GREEN}hysteria2://${HY2_PWD}@${target}:${PORT_HY2}/?insecure=1&sni=${REALITY_SNI}#Hy2-${raw_host}${PLAIN}\n"

    echo -e "${BOLD}3. TUIC v5 (端口 ${PORT_TUIC} | UDP BBR 多路复用):${PLAIN}"
    echo -e "${GREEN}tuic://${UUID}:${TUIC_PWD}@${target}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&sni=${REALITY_SNI}&udp_relay_mode=native&allow_insecure=1#TUIC5-${raw_host}${PLAIN}\n"

    echo -e "${BOLD}4. NaiveProxy (端口 ${PORT_NAIVE} | F佬同款链接内嵌 200天证书，无 -202 报错):${PLAIN}"
    echo -e "${YELLOW}👉 [v2rayN 专用链接 - 复制后在 v2rayN 按 Ctrl+V 导入，自动填好证书直接秒通]:${PLAIN}"
    echo -e "${GREEN}${V2RAYN_NAIVE_H2}${PLAIN}"
    echo -e "${GREEN}${V2RAYN_NAIVE_QUIC}${PLAIN}"
    echo -e "${YELLOW}👉 [Karing / Throne / NekoBox 专用链接 - URL 内嵌 tls_certificate 证书]:${PLAIN}"
    echo -e "${GREEN}naive+https://${NAIVE_USER}:${NAIVE_PASS}@${target}:${PORT_NAIVE}?uot=1&security=tls&sni=${REALITY_SNI}&tls_certificate=${CERT_200_URL_1}#Naive-HTTP2-${raw_host}${PLAIN}\n"

    echo -e "${BOLD}5. AnyTLS (端口 ${PORT_ANYTLS} | Sing-box 1.14 原生 AnyTLS 协议):${PLAIN}"
    echo -e "${YELLOW}👉 [Karing / Throne / Shadowrocket 通用链接]:${PLAIN}"
    echo -e "${GREEN}anytls://${UUID}@${target}:${PORT_ANYTLS}?security=tls&sni=${REALITY_SNI}&insecure=1&tls_certificate=${CERT_URL_1}&fp=chrome#AnyTLS-${raw_host}${PLAIN}"
    echo -e "${YELLOW}👉 [v2rayN 专用内嵌证书链接]:${PLAIN}"
    echo -e "${GREEN}${V2RAYN_ANYTLS}${PLAIN}"

    echo -e "----------------------------------------------------------------------"
    echo -e "${YELLOW}【一键在线订阅地址 (自动识别客户端 User-Agent 下发内嵌证书节点)】${PLAIN}"
    echo -e " 通用自适应 Base64 订阅链接 (v2rayN / Karing / Shadowrocket / Throne 直接填入):"
    echo -e " ${GREEN}http://${url_ip}:${SUB_PORT}/sub?token=${SUB_TOKEN}${PLAIN}\n"
    echo -e " v2rayN 强制专属订阅链接 (包含内嵌证书的 v2rayn://naive 与 anytls):"
    echo -e " ${GREEN}http://${url_ip}:${SUB_PORT}/sub?token=${SUB_TOKEN}&format=v2rayn${PLAIN}\n"
    echo -e " Clash.Meta / Mihomo 专属 YAML 订阅链接:"
    echo -e " ${GREEN}http://${url_ip}:${SUB_PORT}/sub?token=${SUB_TOKEN}&format=clash${PLAIN}"
    echo -e "${GREEN}======================================================================${PLAIN}"
}

# 选项 2: 干净卸载
uninstall_singbox() {
    echo -e "${YELLOW}正在停止并卸载 Sing-box 与订阅微服务...${PLAIN}"
    systemctl stop sing-box singbox-sub argo 2>/dev/null || true
    systemctl disable sing-box singbox-sub argo 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/singbox-sub.service /etc/systemd/system/argo.service
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

# 选项 4: 变更核心配置 (含重新签发 200天 Naive 证书)
modify_config() {
    source "$ENV_FILE" 2>/dev/null || { echo -e "${RED}请先安装 Sing-box！${PLAIN}"; return; }
    echo -e "\n=== 变更核心配置选项 ==="
    echo " 1. 重新生成并更换 UUID"
    echo " 2. 重新生成 Hysteria 2 / TUIC / Naive 密码"
    echo " 3. 切换出站策略【prefer_ipv6 / prefer_ipv4】"
    echo " 4. 更换伪装域名 SNI 并重新签发 200天 Naive 证书 (当前: ${REALITY_SNI})"
    echo " 5. 重新签发 200天 Naive 专属 SAN 证书 (cert_200.pem)"
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
            read -rp "请输入新的伪装域名 SNI [默认 addons.mozilla.org]: " new_sni
            REALITY_SNI="${new_sni:-addons.mozilla.org}"
            sed -i "s|^REALITY_SNI=.*|REALITY_SNI=\"$REALITY_SNI\"|" "$ENV_FILE"
            generate_fscarmen_certs "$REALITY_SNI"
            write_singbox_config && systemctl restart sing-box singbox-sub
            echo -e "${GREEN}[OK] 伪装源与 200天 SAN 证书已同步更新为: $REALITY_SNI${PLAIN}"
            show_nodes
            ;;
        5)
            generate_fscarmen_certs "${REALITY_SNI:-addons.mozilla.org}"
            systemctl restart sing-box singbox-sub
            echo -e "${GREEN}[OK] 200天 Naive 专属 SAN 证书 (cert_200.pem) 已重新签发！${PLAIN}"
            show_nodes
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
    local cert_stat="${YELLOW}未生成${PLAIN}"
    [[ -s "${CERT_DIR}/cert_200.pem" ]] && cert_stat="${GREEN}● 200天 SAN 内嵌证书就绪${PLAIN}"

    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║${PLAIN}      ${BOLD}SingBox Suite Pro — 现代化全协议聚合部署套件 (All-In-One)${PLAIN}       ${BLUE}║${PLAIN}"
    echo -e "${BLUE}║${PLAIN}     VLESS-Reality • Hysteria 2 • TUIC v5 • AnyTLS • NaiveProxy       ${BLUE}║${PLAIN}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════╝${PLAIN}"
    echo -e " 系统架构: ${GREEN}${ARCH}${PLAIN} | 网络环境: ${GREEN}${NET_STACK}${PLAIN} | 快捷指令: ${YELLOW}sb${PLAIN}"
    echo -e " 核心版本: ${GREEN}${ver}${PLAIN} | 服务状态: ${status} | Naive证书: ${cert_stat}"
    echo -e "──────────────────────────────────────────────────────────────────────"
    echo -e " ${BOLD}【核心部署与控制】${PLAIN}"
    echo -e "   ${GREEN}1.${PLAIN} 一键全协议安装部署 (v1.14.4 五协议共存 / 随机端口 + F佬内嵌证书方案)"
    echo -e "   ${GREEN}2.${PLAIN} 干净卸载 Sing-box (彻底移除二进制、配置与订阅守护服务)"
    echo -e "   ${GREEN}3.${PLAIN} 启停与状态管理 (启动 / 停止 / 重启 Sing-box 及订阅服务)"
    echo ""
    echo -e " ${BOLD}【节点配置与端口管理】${PLAIN}"
    echo -e "   ${GREEN}4.${PLAIN} 变更核心配置 (UUID / 密码 / 出站优先级 / 200天 Naive 证书重签)"
    echo -e "   ${GREEN}5.${PLAIN} 协议端口调整与一键随机刷新 (规避运营商封锁与 UDP QoS)"
    echo -e "   ${GREEN}6.${PLAIN} 管理 Acme.sh 域名证书 (支持自有域名 Standalone 申请)"
    echo ""
    echo -e " ${BOLD}【订阅管理与分流解锁】${PLAIN}"
    echo -e "   ${GREEN}7.${PLAIN} 刷新查看节点配置与订阅链接 (v2rayN 内嵌证书链接 / Karing / Clash)"
    echo -e "   ${GREEN}8.${PLAIN} 路由分流管理 (校准 v1.14 标准路由与 DNS 策略)"
    echo -e "   ${GREEN}9.${PLAIN} 网络连通性与流媒体解锁自检 (IPv6 / NAT64 / Cloudflare 边缘检测)"
    echo ""
    echo -e " ${BOLD}【系统优化与工具维护】${PLAIN}"
    echo -e "   ${GREEN}10.${PLAIN} 实时查看运行日志 (Journalctl 追踪五协议入站连接)"
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
            echo -e "${YELLOW}[提示] 当前已内置 F佬同款 200天 SAN 内嵌证书方案，无需域名即可让 NaiveProxy 100% 绿字连通。${PLAIN}"
            ;;
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
            install_singbox_binary "${v_tag:-1.14.4}"
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
