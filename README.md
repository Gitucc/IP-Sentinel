# IP-Sentinel

IP-Sentinel 是一个面向 VPS 公网 IP 的监测与低频养护工具，采用 Master-Agent 架构。Agent 部署在需要维护的服务器上，按所选地区执行本地化搜索与白名单访问，并生成 IP 质量报告；Master 可选，用 Telegram Bot 统一管理多台 Agent。

本仓库是 [hotyue/IP-Sentinel](https://github.com/hotyue/IP-Sentinel) 的下游 Fork。代码、安装脚本和 OTA 更新源都指向本仓库，Master 与 Agent 应成套使用。

> [!IMPORTANT]
> IP 地理定位和信誉由外部平台决定，本项目只能提供持续、低频的正常访问行为与检测结果，不能保证 IP 一定被改定位、解除风控或恢复特定服务。

> [!WARNING]
> 当前代码已通过 Shell 语法检查、Master 安全策略、注册重发、每日更新器和数据契约等自动化测试；尚未完成真实 Telegram、不同云厂商安全组和大规模节点的生产验证。建议先在一台测试机部署。

## 当前仓库会做什么

### Agent：在节点上执行监测与养护

- 安装时选择国家、行政区和城市。国家代码决定热词文件，城市配置决定坐标、语言参数和白名单网址。
- 默认每 20 分钟唤醒一次任务，并加入随机延迟。Google 地区纠偏和 IP 信用养护同时开启时，每轮按 70% / 30% 的概率选择其中一个执行。
- 每天在安装时刻附近同步本国热词、当前城市配置和 IP 质量探针；User-Agent 池每 30 天更新一次。
- 下载内容先写入临时目录并检查格式。热词不足、下载到 HTML/404 页面或城市 JSON 缺字段时，保留本地旧文件，不用坏数据覆盖。
- 可通过 Telegram 手动执行养护、质量检测、报告生成和日志提取，也可完全不接入 Master，只运行本地定时任务。

热词按国家或地区共享，不细分到城市。例如选择美国某个城市时，Agent 使用 `data/keywords/kw_US.txt`；城市差异来自对应的 `data/regions/.../*.json`。

### 数据仓库：每天准备 Agent 要用的地区数据

- GitHub Actions 每天 03:00 UTC 从 Google Trends RSS 抓取各国家或地区的热门词，合并旧记录后每个地区最多保留 100 条。
- 同一任务会读取各城市的 Google News RSS，更新城市配置里的白名单访问地址。
- 如果所有地区的热词都抓取失败，任务会返回失败并保留旧词库，不提交一份看似成功的空更新。
- User-Agent 数据在每月 1 日 04:00 UTC 重新生成。

Agent 从本仓库的 `main` 分支读取这些数据。因此，仓库里的每日数据提交不需要手动合并到已经安装的节点。

### Master：通过 Telegram 管理多台 Agent

Master 使用 SQLite 保存节点、配置和 IP 质量历史，可在 Bot 面板中执行以下操作：

- 查看已登记节点、单机报告、日志和质量趋势；
- 单独或批量触发 Google 纠偏、信用养护和系统巡检；
- 开关 Agent 模块、修改展示名、删除节点；
- 在私有部署且已授权时，升级 Master 或 Agent。

当前通信和管理边界包括：

- 新安装的每台 Agent 都有独立 `AGENT_TOKEN`。Master 对请求路径、全部业务参数和时间戳计算 HMAC-SHA256，Agent 只接受 60 秒窗口内且未使用过的签名。
- `ALLOWED_CHAT_ID` 限制可以操作私有 Master 的 Telegram 账号。
- 升级、删除、改名、模块开关和批量任务只能从 Bot 按钮发起；Master 会检查节点是否属于当前 Chat ID。
- Master 只接受公网 IPv4/IPv6 注册地址，拒绝回环、私网、保留和组播地址，避免把节点注册入口变成内网请求代理。
- SQLite 使用 WAL 和忙等待设置，减少多条 Telegram 请求同时写库时的锁冲突。
- Master 的安全规则位于独立的 `master/security_policy.sh`。安装器会同时下载并检查它与主程序；缺少规则文件时 Master 不启动。

## 安装前准备

- 一台或多台拥有公网 IPv4 或 IPv6 的 Linux VPS；
- `root` 权限；
- 能访问 GitHub Raw、Google 和相关目标站点的网络；
- 使用远程管理时，需要 Telegram Bot Token、自己的 Chat ID，以及一个可从 Master 访问的 Agent TCP 端口；
- 云厂商安全组和主机防火墙需要放行所选 Agent 端口。

安装器支持 Debian、Ubuntu、CentOS、RHEL、Alpine Linux 和 Arch Linux。Systemd 环境使用 service/timer；其他环境回退到 Cron 或兼容调度器。

## 推荐用法：私有 Master + Agent

### 1. 安装 Master

先用 [@BotFather](https://t.me/BotFather) 创建 Telegram Bot，并取得自己的 Chat ID。然后在 Master 服务器上执行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main/master/install_master.sh)"
```

安装时选择“私有独立中枢”，填写 Bot Token、管理者 Chat ID，并决定是否允许 Master OTA。

### 2. 安装 Agent

在每台需要监测和养护的 VPS 上执行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main/install.sh)"
```

按提示完成以下设置：

1. 选择国家、行政区和城市；
2. 选择接入 Master；
3. 选择“私有独立中枢”，填写同一个 Bot Token 和 Chat ID；
4. 确认 Agent 的 Webhook 端口和 OTA 权限；
5. 在云安全组与主机防火墙中放行该 TCP 端口。

安装结束后，Agent 会向 Telegram 发送一条 8 字段注册指令：

```text
#REGISTER#|REGION_CODE|NODE_NAME|COMM_IP|AGENT_PORT|NODE_ALIAS|ENABLE_OTA|AGENT_TOKEN
```

把整行指令发送给自己的 Bot。Master 回复“档案已录入”后，在 Bot 中发送 `/start` 或 `/menu` 打开控制面板。

注册指令含 `AGENT_TOKEN`，不要转发、截图公开或写进仓库。

## 其他运行方式

### 只运行本地 Agent

执行 Agent 安装命令，在“是否接入 Master”处选择 `n`。本地的 20 分钟养护和每日数据同步仍会运行，但没有 Telegram 报告、远程控制和 OTA。

### 不支持官方公共网关

当前 Fork 的注册协议和签名方式与官方 Bot / Master 不兼容，不能使用官方公共网关。安装器目前仍会显示“官方公共网关”选项，请不要选择；需要 Telegram 管理时必须部署本 Fork 的私有 Master。

## 日常维护

### 平滑升级

重新执行对应的安装命令并选择安装/升级。安装器检测到同一 Fork 的现有配置后，会询问是否沿用配置和保留日志。

私有 Master 和已授权的 Agent 也可以从 Telegram 面板执行 OTA。不要把 `REPO_RAW_URL` 改成上游仓库地址，否则可能把不兼容的通信代码覆盖到单侧节点。

### 重新发送注册信息

重新执行 Agent 安装命令，选择：

```text
3) 重新发送节点注册信息
```

脚本会读取 `/opt/ip_sentinel/config.conf`，检查端口、公网地址、HTTPS API、Chat ID 和 `AGENT_TOKEN`。如果探测到公网 IPv4/IPv6 已变化，会先询问是否使用新地址，再发送新的注册消息。此操作不会重新下载地区地图，也不会重装 Agent。

### 常用位置

| 内容 | 路径 |
| --- | --- |
| Agent 配置 | `/opt/ip_sentinel/config.conf` |
| Agent 日志 | `/opt/ip_sentinel/logs/sentinel.log` |
| Agent OTA 日志 | `/opt/ip_sentinel/logs/ota_upgrade.log` |
| Master 配置 | `/opt/ip_sentinel_master/master.conf` |
| Master 数据库 | `/opt/ip_sentinel_master/sentinel.db` |
| Master 日志 | `/opt/ip_sentinel/logs/master.log` |

Systemd 环境可查看服务状态：

```bash
systemctl status ip-sentinel-agent-daemon.service
systemctl status ip-sentinel-master.service
```

## 与上游仓库的主要差异和兼容性

| 项目 | 本 Fork 的处理 | 兼容性 |
| --- | --- | --- |
| Master-Agent 鉴权 | 新节点使用独立 `AGENT_TOKEN`，对请求路径、排序后的业务参数和时间戳签名，并检查超时与重放 | Fork Master 与 Fork Agent 成套使用 |
| 注册协议 | 使用包含 `AGENT_TOKEN` 的 8 字段 `#REGISTER#` 指令 | 不支持把上游 Master 和本 Fork Agent 混用，反向组合也不受支持 |
| 官方 Bot / 公共网关 | 当前 Fork 没有官方协议适配 | 不可用；不要选择安装器里的“官方公共网关” |
| Telegram 权限 | 管理者 Chat ID 白名单；高权限操作只接受按钮回调；操作前检查节点归属和参数 | 需要本 Fork 的 `tg_master.sh` 与 `security_policy.sh` 一起部署 |
| 注册地址 | 只接受公网 IP；私网、回环、保留、组播地址会被拒绝 | 内网地址、Tailscale/WireGuard 私网地址不能直接注册为通讯地址 |
| 更新来源 | 安装、数据同步和 OTA 默认读取 `Gitucc/IP-Sentinel` | 不能把单侧组件的更新源切到 `hotyue/IP-Sentinel` |
| 数据格式 | 继续使用 `data/map.json`、`data/keywords/kw_<地区>.txt` 和城市 JSON 结构 | 可以按文件审查并同步上游数据，但不要直接同步上游通信与安装代码 |
| 同 Fork 旧节点 | 安装器会保留配置，并为缺少 Token 的旧配置生成 `AGENT_TOKEN` | 升级后如提示鉴权失败，需要重新发送注册信息 |

Agent 和 Master 仍保留以 `CHAT_ID` 作为签名密钥的旧配置回退，用来避免同一 Fork 的旧节点在升级瞬间失联。新安装和“重新发送注册信息”都要求 `AGENT_TOKEN`；这条回退不代表可以和上游版本混合部署。

从上游原版迁移时，先备份配置和数据库，再把 Master 与 Agent 一起切换到本 Fork，并重新注册所有节点。只升级其中一端不在支持范围内。

## 自动化检查

仓库的 `Quality Checks` 工作流会执行：

- 所有 Shell 脚本的语法检查；
- Master 安全策略测试；
- 注册重发测试；
- 每日更新器的下载失败、坏数据和保留旧文件测试；
- 地图、城市配置和热词的数据契约测试；
- 热词全部抓取失败时的退出状态测试。

这些检查覆盖脚本逻辑，不等同于真实云网络、Telegram API 或目标网站的生产验收。

## 仓库结构

```text
IP-Sentinel/
├── .github/workflows/   # 每日数据、月度 UA 和质量检查
├── install/             # Agent 与 Master 的模块化安装流程
├── core/                # Agent 调度、养护、报告、更新和 Webhook
├── master/              # Telegram Master 与安全策略
├── scripts/             # 热词、新闻网址和 User-Agent 生成器
├── data/                # 地图、国家热词、城市配置和 User-Agent
├── telemetry/           # 匿名装机计数 Worker
├── tests/               # Shell 与 Python 回归测试
├── install.sh           # Agent 安装入口
└── version.txt          # Master / Agent 版本号
```

## 免责声明

本项目仅用于网络原理研究和个人服务器运维。使用前请确认 VPS 提供商的服务条款、目标网站规则和当地法律，不要用于恶意请求、流量伪造或规避平台限制。使用者自行承担运行风险。

感谢 [@hotyue](https://github.com/hotyue) 提供上游项目。标准上游版本见 [hotyue/IP-Sentinel](https://github.com/hotyue/IP-Sentinel)。
