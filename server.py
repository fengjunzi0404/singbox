#!/usr/bin/env python3
"""
Lightweight Standalone Subscription Server for Sing-box Suite
Generates base64 text or Clash.Meta / Mihomo YAML output.
"""
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
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"403 Forbidden: Invalid Subscription Token")
            return

        ip = env.get("SERVER_IP", "127.0.0.1")
        uuid = env.get("UUID", "")
        domain = env.get("DOMAIN_NAME", ip)
        
        url_ip = f"[{ip}]" if ":" in ip else ip

        links = [
            f"vless://{uuid}@{url_ip}:{env.get('PORT_REALITY', 443)}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={env.get('REALITY_SNI', 'www.apple.com')}&fp=chrome&pbk={env.get('REALITY_PUB','')}&sid={env.get('REALITY_SHORT_ID','')}&type=tcp#Reality-{ip}",
            f"hysteria2://{env.get('HY2_PWD','')}@{domain}:{env.get('PORT_HY2', 8443)}/?insecure=1&sni={domain}#Hy2-{domain}",
            f"tuic://{uuid}:{env.get('TUIC_PWD','')}@{domain}:{env.get('PORT_TUIC', 9443)}?congestion_control=bbr&alpn=h3&sni={domain}&allow_insecure=1#TUIC5-{domain}",
            f"naive+https://{env.get('NAIVE_USER','admin')}:{env.get('NAIVE_PASS','')}@{domain}:{env.get('PORT_NAIVE', 10443)}#Naive-{domain}"
        ]

        fmt = qs.get("format", ["base64"])[0]
        if fmt == "clash":
            self.send_response(200)
            self.send_header("Content-Type", "text/yaml; charset=utf-8")
            self.send_header("profile-update-interval", "24")
            self.end_headers()
            yaml_out = f"""port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "Reality-Vision [{ip}]"
    type: vless
    server: "{ip}"
    port: {env.get('PORT_REALITY', 443)}
    uuid: "{uuid}"
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: "{env.get('REALITY_SNI', 'www.apple.com')}"
    reality-opts:
      public-key: "{env.get('REALITY_PUB', '')}"
      short-id: "{env.get('REALITY_SHORT_ID', '')}"
    client-fingerprint: chrome
  - name: "Hysteria-2 [{domain}]"
    type: hysteria2
    server: "{domain}"
    port: {env.get('PORT_HY2', 8443)}
    password: "{env.get('HY2_PWD', '')}"
    sni: "{domain}"
    skip-cert-verify: true
  - name: "TUIC-v5 [{domain}]"
    type: tuic
    server: "{domain}"
    port: {env.get('PORT_TUIC', 9443)}
    uuid: "{uuid}"
    password: "{env.get('TUIC_PWD', '')}"
    congestion-controller: bbr
    alpn: [h3]
    sni: "{domain}"
    skip-cert-verify: true
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "Reality-Vision [{ip}]"
      - "Hysteria-2 [{domain}]"
      - "TUIC-v5 [{domain}]"
rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
"""
            self.wfile.write(yaml_out.encode('utf-8'))
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("profile-update-interval", "24")
            self.end_headers()
            raw_text = "\n".join(links)
            self.wfile.write(base64.b64encode(raw_text.encode('utf-8')))

Handler = SubHandler
socketserver.TCPServer.allow_reuse_address = True
if __name__ == '__main__':
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        httpd.serve_forever()
