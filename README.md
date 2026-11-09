# SingBox Suite Pro — 现代化五协议聚合一键部署套件




## ✨ 核心特性 (专为纯 IPv6 / Hax 与双栈 VPS 深度强化)

1. **五协议全量共存 (All-In-One 单脚本自包含)**
   - **VLESS-Reality-Vision**：默认采用 `addons.mozilla.org` 全球双栈伪装源 + 高位随机端口，彻底绕过国内运营商对 IPv6 `443` 端口的入站阻断。
   - **NaiveProxy:必须申请证书  
   - **Hysteria 2 (UDP/QUIC)**：内置自签 EC 证书与客户端 `insecure=1`，暴力抗丢包。
   - **TUIC v5 (UDP/QUIC)**：原生 BBR 拥塞控制 + ALPN `h3` 低延迟多路复用。
   - **AnyTLS (VLESS + TLS / TCP)**：稳定可靠的标准 TCP 加密传输通道。

2. **标准化双栈在线订阅服务 (完美适配 Karing / v2rayN / Shadowrocket / Clash.Meta)**
   - 采用 Python `BaseHTTPRequestHandler` + `AF_INET6` 双栈套接字监听 `[::]`，同时支持 IPv6 与 IPv4 访问。
   - 严格注入 `Content-Length` 与 `Connection: close` 响应头，默认直接返回标准 **Base64 通用订阅**（Karing、v2rayN、小火箭直接填入即可秒速更新，不再报 `Connection closed before full header was received` 或 `http response is empty`）。
   - 链接末尾附加 `&format=clash` 即可获取完整 Clash.Meta / Mihomo YAML 规则集。

3. **高位随机端口 + 纯 IPv6 / Virtuozzo 容器防崩优化**
   - 默认自动使用 `15000–59999` 互不冲突的高位随机端口，并自动放行 `ufw`、`iptables` 与 `ip6tables`。
   - 自动检测纯 IPv6 环境注入 NAT64/DNS64，默认设置 `"domain_strategy": "prefer_ipv6"`，并移除容易在容器架构引发 Fatal Panic 秒退的 `geosite.db` 规则。

---

## 🚀 极速安装与使用命令

### 方式一：交互式菜单安装（支持一路按回车全自动完成）
```bash
wget -qO /usr/local/bin/sb "https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh?t=$(date +%s)" && chmod +x /usr/local/bin/sb && /usr/local/bin/sb
```
```bash
curl -sSL "https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh?t=$(date +%s)" -o /usr/local/bin/sb && chmod +x /usr/local/bin/sb && /usr/local/bin/sb
```

### 方式二：零交互无人值守一键部署（无需按任何回车，直接输出全部节点与订阅）
```bash
wget -qO /usr/local/bin/sb "https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh?t=$(date +%s)" && chmod +x /usr/local/bin/sb && /usr/local/bin/sb -y
```
```bash
curl -fsSL "https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh?t=$(date +%s)" -o /usr/local/bin/sb && chmod +x /usr/local/bin/sb && /usr/local/bin/sb -y
```

> 日常管理只需在终端输入快捷指令：`sb`（或直接输入 `sb 7` 查看全部节点与订阅链接）。

---

## 📋 控制台菜单结构 (1–13 顺次排列)

| 编号 | 功能模块 | 说明 |
| :--- | :--- | :--- |
| **1** | **一键全协议安装部署** | 自动分配随机高位端口、生成自签证书、启动五协议并默认挂载 Argo 免费权威证书隧道 |
| **2** | **干净卸载 Sing-box** | 彻底停止并移除 `sing-box`、`singbox-sub`、`argo` 服务与配置文件 |
| **3** | **启停与状态管理** | 一键启动、停止、重启全部服务或查看 `systemctl` 运行状态 |
| **4** | **变更核心配置** | 更换 UUID、密码、切换 `prefer_ipv6/ipv4`、管理 Argo 免费隧道、刷新订阅 Token |
| **5** | **协议端口调整与随机刷新** | 一键重新随机分配全部协议与订阅服务的高位端口并同步放行防火墙 |
| **6** | **管理 Acme.sh 域名证书** | 适合拥有自有域名的用户申请证书（无域名用户直接用默认 Argo 即可） |
| **7** | **刷新查看节点配置与订阅链接** | 打印全部 5 大协议通用 URI（含 `Naive-Argo-Trusted`）与 Base64 / Clash 订阅地址 |
| **8** | **路由分流管理** | 校准纯净无 `geosite` 依赖路由配置，保障容器 VPS 稳定常驻 |
| **9** | **网络连通性与流媒体自检** | 检测当前 VPS 的 IPv6/NAT64 出站状态与 Cloudflare 边缘连接信息 |
| **10** | **实时查看运行日志** | 调用 `journalctl` 追踪 Sing-box 与 Argo 隧道实时日志 |
| **11** | **一键原版 BBR + FQ 加速** | 启用 Linux 内核 BBR 拥塞控制算法提升吞吐率 |
| **12** | **官方内核版本切换** | 指定版本号升级或重装官方 Sing-box 二进制程序 |
| **13** | **在线拉取更新部署脚本** | 带防缓存时间戳拉取 GitHub 仓库最新 `sb.sh` |

---

## 🛠️ 客户端使用关键提示

1. **v2rayN 测试 NaiveProxy 注意事项**：
   - 请在 v2rayN 顶部菜单 **【设置】 -> 【参数设置】** 中确保 **取消勾选 `开启 TLS 碎片 (Fragment)`**（Chromium 网络栈不支持外部注入 Fragment）。
   - 直接导入脚本生成的 `naive+https://admin:密码@xxxx.trycloudflare.com:443#Naive-Argo-Trusted` 节点，由于该域名拥有 Cloudflare 官方签发的权威 SSL 证书，无需往 Windows 导入任何证书即可 100% 绿字秒通！
2. **Karing / v2rayN / Shadowrocket 订阅导入**：
   - 直接复制脚本输出的 **通用 Base64 订阅链接**：`http://[你的IPv6]:端口/sub?token=你的Token` 填入客户端即可正常拉取全部 5 大协议节点。
   - 若使用 Clash Verge Rev / Mihomo，也可使用末尾带 `&format=clash` 的专属 YAML 订阅地址。

---

## 💖 致敬与特别鸣谢 (Credits)

- **[ygkkk (甬哥坎坎坷坷)](https://github.com/ygkkk)** — 感谢甬哥在 Sing-box 多协议脚本普及与交互设计上的开拓性贡献。
- **[fscarmen (F佬)](https://github.com/fscarmen/sing-box)** — 感谢 F 佬在 Cloudflare Argo 临时隧道集成、Reality 优选 SNI 以及纯 IPv6/NAT64 环境适配上的精妙思路。
