# IP-Sentinel (分布式 IP 状态监测与养护系统)

IP-Sentinel 是一个基于 Master-Agent 架构的分布式 VPS IP 状态监测与养护工具。项目主要用于解决云服务器公网 IP 被地理位置数据库错误定位以及因信誉度较低被拦截的问题。系统支持通过部署在边缘节点的 Agent 进行本地模拟访问以提升 IP 信誉，并允许管理者通过私有 Telegram Bot 控制中枢（Master）对所有边缘节点进行配置管理与指令分发。

> [!WARNING]
> **📌 关于本 Fork 加固版 (Downstream Hardened Edition)**
> 本仓库是基于 [hotyue/IP-Sentinel](https://github.com/Gitucc/IP-Sentinel) 官方项目的安全加固与重构分支。
> 
> **⚠️ 状态声明（仅限测试使用）：**
> 本分支当前的重构与安全改造目前仅通过了本地模拟环境的端到端联测。截至目前，实际上机部署和大规模实网可用性测试流程尚未正式开始，无法保证生产环境的可用性与长期稳定性。请勿在关键生产环境直接运行。
> 
> **核心改动与不兼容声明：**
> 1. **协议重构**：本分支引入了节点专属 Token 鉴权机制与中枢管理者 Chat ID 安全白名单，因此无法与官方原版直接互通或混合部署。
> 2. **自适应拉取源**：为防止中枢或节点在执行 OTA 升级时因拉取上游非兼容代码导致系统失效，本分支将资源拉取源（`REPO_RAW_URL`）重定向至本仓库。
> 
> 感谢原作者 [@hotyue](https://github.com/hotyue) 提供的开源基础。如需部署标准版，请访问 [上游官方仓库](https://github.com/Gitucc/IP-Sentinel)。

---

## 核心设计与安全机制

- 📊 **自适应 IP 质量监测**：内置多维质量检测探针，支持获取公网 IP 分区定位、流媒体解锁状态及异常预警，并展示 IP 历史污染指数趋势。
- 🔒 **基于 HMAC-SHA256 的请求防篡改机制**：Agent 端与 Master 端通信引入带有 60 秒时效性（时间戳校验）的 HMAC-SHA256 签名。本次安全重构将 URL 的所有业务查询参数以及节点专属 Token（`AGENT_TOKEN`）共同纳入签名哈希，防止参数篡改与跨节点的横向重放攻击。
- 🛡️ **中枢安全白名单过滤**：中枢控制端引入 `ALLOWED_CHAT_ID` 白名单限制。非授权账户向 Bot 发送的指令和数据均会被丢弃，用以防范针对中枢的 SQL 注入与非授权节点的注册。
- ⚡ **SQLite WAL 并发控制**：控制中枢采用 SQLite 数据库存储节点状态，并激活 `WAL` (Write-Ahead Logging) 模式和排队重试机制，在高频并发场景下降低数据库锁死及 Telegram 限流风险。
- 🖧 **多 IP 出口自适应**：Agent 节点支持检测物理网卡的 IPv4 与 IPv6 出口，并结合发包参数（`--interface`）实现多宿主路由通道的绑定与自动降级。
- 🔄 **带签名验证的远程升级**：在私有中枢部署下，支持通过双端签名校验授权的 OTA 静默热升级，降低多节点日常运维复杂度。

---

## 项目架构说明

本项目采用模块化的代码库结构，冷热数据隔离：

```text
📦 IP-Sentinel
 ┣ 📂 .github/workflows/      # 云端指纹库与热词抓取流水线
 ┣ 📂 install/                # 安装及环境判定的编排脚本目录
 ┣ 📜 install.sh              # 边缘节点 Agent 安装入口脚本
 ┣ 📂 master/                 # 控制中枢 Master 端逻辑（包含 SQLite 建库与 TG 轮询守护脚本）
 ┣ 📂 core/                   # 边缘节点 Agent 端逻辑（内置 Webhook Python 进程及纠偏、净化等 shell 模块）
 ┣ 📂 scripts/                # 辅助词库及设备指纹生成的 python 工具
 ┣ 📂 data/                   # 全球区域拓扑图与本地持久化指纹/词库
 ┣ 📜 version.txt             # 版本控制标识文件
 ┗ 📂 telemetry/              # 匿名装机量统计网关代码 (基于 Cloudflare Workers)
```

---

## 部署指南

系统支持 **Debian / Ubuntu / CentOS / RHEL / Alpine Linux / Arch Linux** 等 Linux 发行版，并自动适配 Systemd 守护进程或 Cron 看门狗守护。

根据您的安全性与隐私需求，系统提供两种部署接入模式：

### 🔹 模式 A：私有独立部署模式 (推荐)
在此模式下，您需要自行部署控制中枢和边缘哨兵，提供独立的数据隐私和远程 OTA 升级功能。

1. **部署 Master 控制中枢**：
   在一台独立的 VPS 上执行以下指令以启动中枢控制端。安装过程中需要提供您自建的 Telegram Bot Token，并必须设置管理者 Chat ID 白名单以确立安全防线：
   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main/master/install_master.sh)"
   ```
2. **部署 Agent 边缘哨兵**：
   在需要进行监测与养护的各个目标边缘服务器上执行以下指令。安装时选择接入自建的私有独立中枢，并输入您相应的 Token、管理者 Chat ID 以及 Webhook 端口：
   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main/install.sh)"
   ```
3. **激活节点**：
   安装完成后，Agent 会在本地生成专属的 `AGENT_TOKEN`，并通过 Telegram 推送一条带有 `#REGISTER#` 格式的注册报文。将此报文发送给您的私有机器人，中枢验证无误后即可将该节点录入并完成注册。

### 🔸 模式 B：官方公共网关模式
适合需要免除 Master 自建、希望体验节点养护效果的用户。在该模式下，您的节点会连接到公共网关，出于滥用防范与供应链风险管理，该模式下远程 OTA 升级权限会被自动禁用。

1. **关注 Bot**：
   在 Telegram 中搜索并关注官方机器人 [@OmniBeacon_bot](https://t.me/OmniBeacon_bot) 并发送 `/start`。
2. **部署 Agent 边缘哨兵**：
   在目标服务器上执行 Agent 引导安装指令，过程中选择接入官方网关，并提供您的 Chat ID：
   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main/install.sh)"
   ```
3. **激活节点**：
   将安装成功后收到含有 Token 的注册报文发送给官方机器人 [@OmniBeacon_bot](https://t.me/OmniBeacon_bot) 即可。

---

## 升级与维护

- **远程静默升级**（私有中枢专属）：
  当中枢检测到新版本时，您可以通过 Telegram Bot 菜单一键向控制端及所有已授权的 Agent 发送升级指令。Agent 收到请求后会在后台下载并自动覆写。
- **SSH 手动平滑覆盖**（公共网关或老旧节点）：
  登录节点终端，重新执行顶部的单行部署指令。安装引擎会自动检测本地存在的 `config.conf` 配置，并执行平滑覆盖以继承老节点的配置属性。

---

## 免责声明

本项目仅供网络原理研究及个人服务器运维学习使用。请严格遵守您 VPS 提供商的 TOS（服务条款）及当地法律法规，切勿用于恶意高频请求或任何非法用途。使用者需自行承担由此产生的相关风险。