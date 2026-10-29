# dsh-balance-widget

桌面余额悬浮窗 —— dsh 桌宠启动时自动带出，无需开机自启。

仿 [codex-usage-widget](https://github.com/Sweelimcue/codex-usage-widget) 的桌面小部件，实时显示：

- **WorkBuddy 算力余额**（如 `235.62 / 901`，体验版/付费版均支持）
- **DeepSeek 开放平台余额 / 总额**（如 `¥0.00 / ¥16`，自动读取 `~/.dsh/.credentials.yaml` 里的 API Key）
- 单击 dsh 那一行 → **用量明细窗口**：按会话 / 按请求列出 token 消耗与估算花费

## 特性

- **跟随 dsh 启动**：作为 desktop profile 的 bundle，dsh（桌宠）一开悬浮窗就出现；dsh 不开它也不出现
- 每 5 分钟自动刷新，按余量六档变色（>80% 翠绿 → ≤10% 红橙）
- **贴边吸附**：拖到屏幕边缘（阈值 26px）自动对齐，不会卡在屏幕外半截
- **dsh 余额显示成 `余额 / 总额`**：总额 = 赠送 + 充值，右键「设置 dsh 总额」填一次即可
- **点击 dsh 行看用量明细**：每个会话用了多少 token、花多少钱，双击会话还能看到每次请求（含高峰/空闲计费）
- 左键拖动、双击刷新、右键菜单（刷新 / 用量明细 / 设置总额 / 置顶 / 打开配置 / 退出）、记住窗口位置
- 接口异常时显示带 `*` 的缓存值；单实例保护，重复触发不会出现多个窗口
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

## 命令与开关

| 操作 | 效果 |
|---|---|
| `/widget` | 随时打开悬浮窗（即使已停用跟随启动也可用；已在运行则不会重复开） |
| `/usage` | 在对话里直接打印 dsh 累计花费、tokens、请求数，以及最近消耗最多的会话 |
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
| `snapPx` | 贴边吸附阈值（像素），默认 26；填 0 关闭吸附 |

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
- 会话的首条用户提问被当作「任务名」，方便对上「这笔钱花在哪个活上」
- 文件是**多个 zstd 帧首尾相接**的 JSONL，`usage-scan.cjs` 按帧魔数切开逐帧解压后汇总（Node 22+ 内置 zstd，无需额外依赖）

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
