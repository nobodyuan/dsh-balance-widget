# dsh-balance-widget

桌面余额悬浮窗 —— dsh 桌宠启动时自动带出，无需开机自启。

仿 [codex-usage-widget](https://github.com/Sweelimcue/codex-usage-widget) 的桌面小部件，实时显示：

- **WorkBuddy 算力余额**（如 `235.62 / 901`，体验版/付费版均支持）
- **DeepSeek 开放平台余额 / 总额**（如 `¥0.00 / ¥16`，自动读取 `~/.dsh/.credentials.yaml` 里的 API Key）
- 单击 dsh 那一行 → **用量明细窗口**：按会话 / 按请求列出 token 消耗与估算花费

## 特性

- **跟随 dsh 启动**：作为 desktop profile 的 bundle，dsh（桌宠）一开悬浮窗就出现；dsh 不开它也不出现
- 每 5 分钟自动刷新，按余量六档变色（>80% 翠绿 → ≤10% 红橙）
- **贴边吸附 + 自动隐藏**：拖到屏幕边缘（26px 内）自动对齐；鼠标移开后整窗缩进边缘，只留 8px 窄边；鼠标移到窄边上自动滑出（QQ/迅雷那种手感）
- **dsh 余额显示成 `余额 / 总额`**：总额 = 赠送 + 充值，右键「设置 dsh 总额」填一次即可
- **今日已花 + 超预算提醒**：底部显示「今日 ¥1.23」，右键可设今日预算，超了变橙色
- **点击 dsh 行看用量明细**：4 个页签（会话 / 按天 / 按模型 / 按工作区），可按任务关键词筛选，会话页签下还能看到每次请求的 token 与高峰/空闲计费
- 左键拖动、双击刷新、右键菜单（刷新 / 用量明细 / 设置总额 / 设置今日预算 / 贴边自动隐藏 / 置顶 / 打开配置 / 退出）、记住窗口位置
- 接口异常时显示带 `*` 的缓存值；单实例保护；**升级后自动替换掉旧版本窗口**（插件读 `instance.json` 的版本号，不一致就先结束旧进程再拉起）
- 免编译：PowerShell + WPF 实现，Windows 10/11 自带运行时即可

## 安装

### 通过 dshmarket 安装（收录后可用）

在 dsh 插件市场搜索 `dsh-balance-widget` 一键安装。

### 手动安装

```bash
# 1. 把本目录复制到 ~/.dsh/plugins/dsh-balance-widget
# 2. 在 desktop profile 的 package.json 中追加：
#    dependencies: { "dsh-balance-widget": "link:<本目录绝对路径>" }
#    dsh.profile.bundles: [ ..., "dsh-balance-widget" ]
# 3. 重启 dsh
```

## 贴边隐藏怎么用

1. 按住悬浮窗拖到屏幕**左/右/上/下边缘**附近松手 → 自动对齐
2. 鼠标移开 0.45 秒 → 整窗滑进边缘，只留 8px 窄边（不挡桌面）
3. 鼠标移到那条窄边上 → 自动滑出完整窗口；移开再缩回去
4. 抓住窄边拖动 = 先滑出再跟手拖；拖离边缘就不再隐藏
5. 不想要这个行为：右键取消勾选「贴边自动隐藏」，或把 `autoHide` 设为 `false`

> 记住的是「滑出后」的位置，重启 dsh 不会把窗口留在屏幕外。

## 命令与开关

| 操作 | 效果 |
|---|---|
| `/widget` | 随时打开悬浮窗（即使已停用跟随启动也可用；已在运行则不会重复开） |
| `/usage` | 在对话里直接打印 dsh 累计花费、今日花费、按模型/按天分布，以及最近消耗最多的会话 |
| 单击悬浮窗 dsh 行 | 打开图形化明细（4 个页签 + 任务筛选 + 导出 CSV） |
| 拖动悬浮窗 | 整窗任意位置都能拖（包括 dsh 那一行）；位移 <4px 判定为单击 |
| 右键「停用跟随启动」 | 下次 dsh 启动时不再自动出现（写 `enabled: false`） |
| 右键「退出」 | 只关本次窗口，下次 dsh 启动仍会带出；`/widget` 可随时叫回 |
| 恢复跟随启动 | 把 `%LOCALAPPDATA%\BalanceWidget\config.json` 的 `"enabled": false` 改回 `true`（或删掉该字段） |

## 配置

配置文件：`%LOCALAPPDATA%\BalanceWidget\config.json`

| 字段 | 说明 |
|---|---|
| `workbuddyCookie` | WorkBuddy 网页版登录 Cookie（见下方获取方法） |
| `deepseekApiKey` | DeepSeek API Key（留空则自动读 `~/.dsh/.credentials.yaml`） |
| `refreshMinutes` | 刷新间隔，默认 5 分钟 |
| `deepseekTotal` | dsh 累计总额（元，含赠送）。例：赠送 6 + 充值 10 = `16`，则显示 `¥0.00 / ¥16`；填 `0` 表示自动推算（余额 + 本地估算消耗） |
| `dailyBudget` | 今日花费预算（元）。超过后悬浮窗底部变橙色提醒；`0` = 不提醒 |
| `snapPx` | 贴边吸附阈值（像素），默认 26；填 0 关闭吸附 |
| `autoHide` | 贴边后是否自动隐藏（鼠标移开缩边、移上去滑出），默认 `true` |
| `hangPx` | 隐藏后留在屏幕上的窄边宽度（像素），默认 8 |
| `hideDelayMs` | 鼠标移开后多久缩边（毫秒），默认 450 |
| `nodePath` | 可选。手动指定 `node.exe` 路径（Node 22.15+），一般不用填，见下方「明细读不到数据」 |

### 明细读不到数据 / 提示需要 Node

明细窗口要靠 Node 解压会话日志（zstd）。dsh 是从资源管理器拉起来的，**PATH 里通常没有 node**，所以插件会：

1. 自己找一个能用的 Node（`~/.dsh/dsh-runtimes/*/dependencies/node/bin/node.exe` → 系统安装 → `~/.workbuddy/binaries/node/versions/*`）
2. 把路径写进 `%LOCALAPPDATA%\BalanceWidget\node.txt`，悬浮窗优先读它

如果窗口里仍然提示找不到 Node：

- 在 `config.json` 里加 `"nodePath": "C:\\路径\\node.exe"`（任意 Node 22.15+ 都行，dsh 自带的那个就可以）
- 或者装一个 Node 22+ 到默认位置
- 详细原因看 `%LOCALAPPDATA%\BalanceWidget\widget.log`（搜 `node` / `扫描`）

### WorkBuddy Cookie 获取方法

1. 浏览器打开并登录 [workbuddy.cn](https://www.workbuddy.cn)
2. 按 `F12` → Network（网络）标签，刷新页面
3. 点任意 `workbuddy.cn` 请求 → Headers → Request Headers → 复制 `Cookie:` 整行
4. 粘贴到 config.json 的 `workbuddyCookie` 字段

> 注意：Cookie 有有效期（通常约一周），过期后 WB 栏显示 `--`，重新抓一次即可。
> Cookie 等同登录凭证，仅保存在本机，请勿外传。

## 用量明细（token 花在哪些任务上）

DeepSeek 官方只提供 `user/balance`（余额），没有用量明细接口，所以本插件的明细是**读 dsh 自己的本地会话日志**统计出来的：

- 数据源：`~/.dsh/sessions/<工作区>/session-<id>/session.v4.jsonl.zstd`
- 每条助手消息里都有 `usage.inputTokens / outputTokens / cacheReadTokens`
- 会话首条用户提问被当作「任务名」，会话头里的 `cwd` 用来做「按工作区」分组
- 文件是**多个 zstd 帧首尾相接**的 JSONL，`usage-scan.cjs` 按帧魔数切开逐帧解压后汇总（Node 22+ 内置 zstd，无需额外依赖）

明细窗口 4 个页签：

| 页签 | 看什么 |
|---|---|
| 会话 | 每个会话的任务名、请求数、输入/输出/缓存命中 token、估算花费；选中后下方列出**每次请求**的时间、模型、高峰/空闲、token、花费 |
| 按天 | 每天的花费、请求数、其中高峰时段请求占比、token 构成 |
| 按模型 | flash / v4-pro 各用了多少、花了多少 |
| 按工作区 | 按会话 `cwd` 拆，看哪个项目最烧钱 |

费用口径按 DeepSeek 官方峰谷价估算（元 / 百万 tokens，2026-09 起）：

| 模型 | 缓存命中 | 缓存未命中 | 输出 |
|---|---|---|---|
| `deepseek-flash` | 0.02 / 0.04 | 1 / 2 | 4 / 8 |
| `deepseek-v4-pro` | 0.15 / 0.30 | 4.5 / 9 | 13.5 / 27 |

（斜杠左=空闲时段，右=高峰时段；高峰为北京时间周一至周五 9:00-12:00、14:00-18:00，其余含周末节假日全按空闲）

> 估算值仅用于看趋势，**不是账单**；精确数字以 [platform.deepseek.com](https://platform.deepseek.com) 的用量页为准。

## 隐私与安全

- 余额查询只访问 `www.workbuddy.cn` 与 `api.deepseek.com` 两个官方接口
- 用量统计只读本机 `~/.dsh/sessions`，不外发任何内容
- Cookie 与 API Key 仅存本机 `%LOCALAPPDATA%\BalanceWidget\`，不上报任何第三方

## License

MIT
