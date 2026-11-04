# Sing-Box 全协议自动化部署与订阅生成套件 (SingBox-Deploy-Suite)

> 🚀 支持 **VLESS-Reality-Vision**、**Hysteria 2 (hy2)**、**TUIC v5**、**AnyTLS**、**NaiveProxy** 官方版本多协议共存。
> 💡 专为常规双栈 VPS 与 **纯 IPv6 (IPv6-Only) VPS** 深度优化，内置 DNS64/NAT64 自动打通与 Cloudflare WARP 双栈出站！

---

## 🌟 核心特性与协议支持

- **五大官方前沿协议一键共存**:
  - `VLESS + Reality + Vision`: 无需自备域名，使用真实大厂 TLS 握手偷跑（默认 Apple/Microsoft），抗封锁顶级伪装。
  - `Hysteria 2 (hy2)`: 官方最新版本，UDP/QUIC 自研拥塞控制算法，极度恶劣弱网/高丢包环境下秒开 4K/8K。
  - `TUIC v5`: 官方最新协议，基于 QUIC 的多路复用高性能代理，低连接延迟与 0-RTT 握手。
  - `AnyTLS / Trojan TLS`: 标准 TLS 终止与通用回落，兼容各类标准客户端。
  - `NaiveProxy`: 使用 Chromium 网络栈流量指纹（HTTP/2 / HTTP/3 CONNECT），行为特征与 Chrome 浏览器完全一致。
- **全功能控制台 (对应图示 1-13 项全能运维)**:
  - 1. 一键全协议部署安装
  - 2. 彻底干净卸载
  - 3. 变更配置 (双证书TLS / UUID / Argo 隧道 / IP 优先 / TG 机器人通知 / 订阅参数 / CDN 优选)
  - 4. 更改主端口 / 配置 UDP 多端口跳跃范围 (Port Hopping，解决运营商 UDP QoS 限速)
  - 5. 三通道域名分流 (CN Direct / Proxy / WARP 解锁 / 广告拦截)
  - 6. 启停与状态管理
  - 7. 在线自更新
  - 8. 官方内核版本无缝切换 (支持最新正式版与指定 Git Tag)
  - 9. 刷新查看节点配置与生成订阅链接 (Mihomo / Clash.Meta / SFA+SFI+SFW / 聚合 Base64)
  - 10. 实时 Systemd 日志分析
  - 11. Linux 原版 BBR + FQ 队列加速与 UDP 缓冲区自动调优
  - 12. Acme.sh 证书管理 (支持 80 Standalone 与 Cloudflare DNS-01 API 自动续期)
  - 13. Cloudflare WARP 管理 (解决纯 IPv6 VPS 无法访问 IPv4 网站，解锁 Netflix / ChatGPT 流媒体与 AI)

---

## ⚡ 纯 IPv6 VPS 能搭建吗？

**答案：完全可以，而且开箱即用！**

针对纯 IPv6 VPS，本套件内置了三大关键技术解决方案：

1. **GitHub 与海外依赖无法访问问题**:
   - 纯 IPv6 VPS 默认无法直接拉取仅支持 IPv4 的 GitHub release 资源。
   - 脚本在启动初期**自动检测 IPv4 栈**，若发现为纯 IPv6 环境，自动为 `/etc/resolv.conf` 注入稳定可用的 **DNS64 / NAT64** 递归解析服务器（如 Cloudflare / Trex），实现无感平滑拉取 GitHub 官方编译包！
2. **客户端连接问题 (家里/手机没有 IPv6 怎么办？)**:
   - 若客户端本地网络支持 IPv6（当前三大运营商 4G/5G 与宽带绝大部分已支持），节点地址使用 `[IPv6]:端口` 即可享受极低延迟直连。
   - 若客户端本地仅有纯 IPv4，可通过脚本的 **选项 3 配置 Cloudflare Argo 隧道** 或 CDN 反向代理，将 IPv4 流量中转至 IPv6 VPS。
3. **Netflix 与 ChatGPT 访问受限问题**:
   - 纯 IPv6 VPS 访问不支持 IPv6 的网站会报错，且 OpenAI 常封锁数据中心 IPv6。
   - 脚本通过 **选项 13 一键开启 Cloudflare WARP 双栈/IPv4 出站**，为 VPS 获取原生 IPv4 出口，直接完美解锁 ChatGPT、Claude 与 Netflix！

---

## 📦 极速安装方式

在服务器终端直接执行以下一键命令：

```bash
# 适用于 Ubuntu 20.04+, Debian 11+, CentOS 8+, Rocky Linux, Alpine
curl -fsSL https://raw.githubusercontent.com/singbox-suite/singbox-deploy/main/sb.sh -o /usr/local/bin/sb && chmod +x /usr/local/bin/sb && /usr/local/bin/sb
```

以后随时在服务器输入快捷命令即可唤出管理面板：
```bash
sb
```

---

## 📱 客户端配置与订阅支持

| 客户端 | 平台 | 支持协议 | 推荐导入方式 |
| :--- | :--- | :--- | :--- |
| **Sing-box (SFA / SFI / SFW)** | Android, iOS, Windows, macOS | 全部协议 (原生支持) | 复制配置 JSON 或订阅链接 |
| **Mihomo (Clash.Meta / Verge Rev)** | 全平台 | VLESS-Reality, Hy2, TUIC5 | 订阅链接追加 `&format=clash` |
| **Shadowrocket (小火箭)** | iOS / iPadOS | 全部协议 | 扫描终端二维码或剪贴板导入 |
| **V2rayN** | Windows | VLESS-Reality, Hy2, TUIC | 批量粘贴通用链接 |
| **NekoBox** | Android / Windows | 全部协议 | 批量链接导入 |
