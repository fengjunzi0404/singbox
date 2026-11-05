# SingBox Suite Pro — 现代化全协议聚合部署与订阅生成套件

> 🚀 支持 **VLESS-Reality-Vision**、**Hysteria 2 (hy2)**、**TUIC v5**、**AnyTLS**、**NaiveProxy** 官方版本多协议共存。
> 💡 专为常规双栈 VPS 与 **纯 IPv6 (IPv6-Only 如 Hax) VPS** 深度优化，内置 DNS64/NAT64 自动打通与 Cloudflare WARP 双栈出站！


## 🌟 核心特性与协议支持

- **五大官方前沿协议一键共存**:
  - `VLESS + Reality + Vision`: 无需自备域名，使用真实大厂 TLS 握手偷跑（默认 `addons.mozilla.org` / `7443` 端口），彻底避开运营商 IPv6 443 封锁。
  - `Hysteria 2 (hy2)`: 官方最新版本，UDP/QUIC 自研拥塞控制算法，极度恶劣弱网/高丢包环境下秒开 4K/8K。
  - `TUIC v5`: 官方最新协议，基于 QUIC 的多路复用高性能代理，低连接延迟与 0-RTT 握手。
  - `AnyTLS / Trojan TLS`: 标准 TLS 终止与通用回落，兼容各类标准客户端。
  - `NaiveProxy`: 使用 Chromium 网络栈流量指纹（HTTP/2 / HTTP/3 CONNECT），行为特征与 Chrome 浏览器完全一致。
- **全功能现代化控制台 (1-13 顺序列出)**:
  - **1.** 一键全协议安装部署 (五大协议共存 / 自动生成密钥与自签证书)
  - **2.** 干净卸载 Sing-box (彻底移除二进制、配置与守护服务)
  - **3.** 启停与状态管理 (启动 / 停止 / 重启 Sing-box)
  - **4.** 变更核心配置 (UUID / 密码刷新 / IPv4-IPv6 出站优先级切换)
  - **5.** 协议端口调整与多端口跳跃 (Port Hopping 规避 UDP QoS)
  - **6.** 管理 Acme.sh 证书 (支持 Standalone 与 Cloudflare DNS API)
  - **7.** 刷新查看节点配置与订阅链接 (Base64 / Clash.Meta / Karing)
  - **8.** 路由分流管理 (CN 国内直连 / 国际代理 / 广告拦截)
  - **9.** Cloudflare WARP 管理 (测试流媒体 / 一键解锁 ChatGPT & Netflix)
  - **10.** 实时查看运行日志 (Journalctl 追踪分析)
  - **11.** 一键原版 BBR + FQ 加速 (网络拥塞控制调优)
  - **12.** 官方内核版本切换 (一键升级到最新正式版或指定 Tag)
  - **13.** 在线拉取更新部署脚本 (GitHub 同步最新特性)
  - **0.** 退出管理控制台

---

## 💖 致敬与特别鸣谢 (Credits & Acknowledgments)

本项目基于并深度修改/参考了以下两位开源大佬的卓越脚本与架构设计：
- **[ygkkk (甬哥坎坎坷坷)](https://github.com/yonggekkk)**: 提供了经典的 Sing-box 基础功能架构与命令行运维灵感。
- **[fscarmen (F佬)](https://github.com/fscarmen/sing-box)**: 提供了强大的多协议共存体系、IPv6 纯栈优化经验与 Reality 伪装优化思路。

本项目在前辈探索的基础上，针对纯 IPv6 VPS (如 Hax) 进行了 NAT64/DNS64 自动打通、双栈微服务订阅（解决 IPv6 拒绝连接）、AnyTLS 拓展、非标端口规避 443 封锁等专属优化。谨向两位前辈致以最崇高的敬意与感谢！

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

在服务器终端直接执行以下一键命令（自动支持 IPv4 与纯 IPv6）：

```bash 推荐：wget 方式 (适用于 Hax 等未预装 curl 的纯 IPv6 系统)

wget -qO /usr/local/bin/sb https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh && chmod +x /usr/local/bin/sb && /usr/local/bin/sb
```

```bash 或使用 curl 方式：

curl -fsSL https://raw.githubusercontent.com/fengjunzi0404/singbox/main/sb.sh -o /usr/local/bin/sb && chmod +x /usr/local/bin/sb && /usr/local/bin/sb
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
> 💖 **致敬与特别鸣谢**: 本项目基于并深度修改/参考了 **[ygkkk (甬哥坎坎坷坷)](https://github.com/yonggekkk)** 与 **[fscarmen (F佬)](https://github.com/fscarmen/sing-box)** 两位前辈的优秀开源脚本与架构灵感，谨致崇高敬意！

---
