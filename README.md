# dsh-balance-widget

桌面余额悬浮窗 —— dsh 桌宠启动时自动带出，无需开机自启。

仿 [codex-usage-widget](https://github.com/Sweelimcue/codex-usage-widget) 的桌面小部件，实时显示：

- **WorkBuddy 算力余额**（如 `235.62 / 901`，体验版/付费版均支持）
- **DeepSeek 开放平台余额**（自动读取 `~/.dsh/.credentials.yaml` 里的 API Key）

## 特性

- **跟随 dsh 启动**：作为 desktop profile 的 bundle，dsh（桌宠）一开悬浮窗就出现；dsh 不开它也不出现
- 每 5 分钟自动刷新，按余量六档变色（>80% 翠绿 → ≤10% 红橙）
- 左键拖动、双击刷新、右键菜单（刷新 / 置顶 / 打开配置 / 退出）、记住窗口位置
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

## 开关控制

- **手动打开**：在 dsh 输入框输入 `/widget`，随时主动打开悬浮窗（即使已停用跟随启动也可用）
- **关（停用跟随启动）**：悬浮窗上右键 → 「停用跟随启动」，下次 dsh 启动时不再出现
- **开（重新启用）**：把 `%LOCALAPPDATA%\BalanceWidget\config.json` 里的 `"enabled": false` 改回 `true`（删掉该字段也行），下次启动 dsh 时恢复；也可以直接在 dsh 对话里让 AI 帮你改
- 悬浮窗右键「退出」只关闭本次窗口，下次 dsh 启动仍会带出；`/widget` 命令任何时候都能把它叫回来

## 配置

配置文件：`%LOCALAPPDATA%\BalanceWidget\config.json`

| 字段 | 说明 |
|---|---|
| `workbuddyCookie` | WorkBuddy 网页版登录 Cookie（见下方获取方法） |
| `deepseekApiKey` | DeepSeek API Key（留空则自动读 `~/.dsh/.credentials.yaml`） |
| `refreshMinutes` | 刷新间隔，默认 5 分钟 |

### WorkBuddy Cookie 获取方法

1. 浏览器打开并登录 [workbuddy.cn](https://www.workbuddy.cn)
2. 按 `F12` → Network（网络）标签，刷新页面
3. 点任意 `workbuddy.cn` 请求 → Headers → Request Headers → 复制 `Cookie:` 整行
4. 粘贴到 config.json 的 `workbuddyCookie` 字段

> 注意：Cookie 有有效期（通常约一周），过期后 WB 栏显示 `--`，重新抓一次即可。
> Cookie 等同登录凭证，仅保存在本机，请勿外传。

## 隐私与安全

- 余额查询只访问 `www.workbuddy.cn` 与 `api.deepseek.com` 两个官方接口
- Cookie 与 API Key 仅存本机 `%LOCALAPPDATA%\BalanceWidget\`，不上报任何第三方

## License

MIT
