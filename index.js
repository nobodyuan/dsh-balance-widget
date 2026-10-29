/**
 * dsh-balance-widget — 宿主半侧插件
 *
 * 作用：dsh desktop profile 启动（即桌宠 dsh-pet 出现）时，把余额悬浮窗一并拉起。
 * 不写任何开机启动项、不注册计划任务；dsh 不启动时悬浮窗也不会自己出现。
 *
 * 命令：
 *   /widget  打开余额悬浮窗（无视 enabled 开关）
 *   /usage   在输入区直接打印 dsh 累计 token 消耗 / 估算花费 / 各会话明细
 *
 * 设计要点：
 * - 全程 try/catch，任何失败都不影响 dsh / 桌宠正常启动；
 * - 悬浮窗脚本自身带命名互斥体单实例保护，多次启动不会出现重复窗口；
 * - dsh 退出时（ctx.effect 清理）不杀悬浮窗，用户可能仍想看着余额。
 */
import { execFileSync, spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const name = "dsh-balance-widget";

/** 无强依赖：即使宿主没提供任何服务，本插件也能独立完成启动动作 */
export const inject = [];

const HERE = dirname(fileURLToPath(import.meta.url));
// 自包含：悬浮窗脚本与用量扫描器随插件分发，路径相对插件目录解析
const SCRIPT_PATH = join(HERE, "BalanceWidget.ps1");
const SCAN_PATH = join(HERE, "usage-scan.cjs");
const LOG_DIR = join(process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local"), "BalanceWidget");
const LOG_PATH = join(LOG_DIR, "plugin.log");
const USAGE_PATH = join(LOG_DIR, "usage.json");
const INSTANCE_PATH = join(LOG_DIR, "instance.json");

/** 必须与 BalanceWidget.ps1 里的 $script:widgetVersion 保持一致 */
const WIDGET_VERSION = "1.3.3";
const NODE_HINT_PATH = join(LOG_DIR, "node.txt");

/**
 * 找可用的 Node：dsh 自己就是 Node 跑的，桌面上却常常没有 node（PATH 里没有）。
 * 悬浮窗要把会话日志的 zstd 解开，必须用 Node >= 22.15。
 */
function resolveNode() {
  const cands = [];
  if (process.env.BW_NODE) cands.push(process.env.BW_NODE);
  const base = pathBasename(process.execPath);
  if (/^node(\.exe)?$/i.test(base)) cands.push(process.execPath);
  // dsh 自带运行时（本机实测 v24，带 zstd）
  for (const root of [join(homedir(), ".dsh", "dsh-runtimes"), join(homedir(), ".dsh", "runtimes")]) {
    try {
      for (const d of readdirSync(root, { withFileTypes: true })) {
        if (d.isDirectory()) cands.push(join(root, d.name, "dependencies", "node", "bin", "node.exe"));
      }
    } catch { }
  }
  // 常见安装位置
  cands.push(join(process.env.ProgramFiles || "C:\\Program Files", "nodejs", "node.exe"));
  cands.push(join(process.env.LOCALAPPDATA || "", "Programs", "nodejs", "node.exe"));
  // WorkBuddy / CodeBuddy 自带 node
  try {
    const wroot = join(homedir(), ".workbuddy", "binaries", "node", "versions");
    for (const d of readdirSync(wroot, { withFileTypes: true })) {
      if (d.isDirectory()) cands.push(join(wroot, d.name, "node.exe"));
    }
  } catch { }

  for (const c of cands) {
    try {
      if (c && existsSync(c)) return c;
    } catch { }
  }
  // 兜底：Electron 自带 node（需要 ELECTRON_RUN_AS_NODE=1）
  return process.execPath;
}

function pathBasename(p) {
  return String(p || "").split(/[\\/]/).pop();
}

function log(msg) {
  try {
    mkdirSync(LOG_DIR, { recursive: true });
    appendFileSync(LOG_PATH, `${new Date().toLocaleString("zh-CN", { hour12: false })} [dsh-balance-widget] ${msg}\n`, "utf8");
  } catch { }
}

/** 悬浮窗启动时会写下 { pid, version }，用来判断桌面上跑的是不是旧脚本 */
function readInstance() {
  try {
    if (!existsSync(INSTANCE_PATH)) return null;
    return JSON.parse(readFileSync(INSTANCE_PATH, "utf8").replace(/^\uFEFF/, ""));
  } catch {
    return null;
  }
}

function isAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** 结束所有 BalanceWidget.ps1 进程（升级后旧窗口仍占着单实例锁，不杀就换不掉） */
function killExisting(logger) {
  try {
    const ps = `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*BalanceWidget.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`;
    execFileSync("powershell.exe", ["-NoProfile", "-Command", ps], { windowsHide: true, timeout: 20000, stdio: "ignore" });
    log("已结束旧的悬浮窗进程");
    try { logger?.info?.("[dsh-balance-widget] 已结束旧版悬浮窗，准备启动新版本"); } catch { }
  } catch (e) {
    log("结束旧进程失败: " + String(e));
  }
}

function readEnabled() {
  const cfgPath = join(LOG_DIR, "config.json");
  if (!existsSync(cfgPath)) return true;
  try {
    // PowerShell 写出的 UTF-8 带 BOM，必须先剥离再 JSON.parse
    const cfg = JSON.parse(readFileSync(cfgPath, "utf8").replace(/^\uFEFF/, ""));
    return cfg.enabled !== false;
  } catch (e) {
    log("读取开关配置失败，按默认开启处理: " + String(e));
    return true;
  }
}

function launchWidget(logger, force = false) {
  try {
    if (!existsSync(SCRIPT_PATH)) {
      log("脚本不存在，跳过: " + SCRIPT_PATH);
      return "missing";
    }
    // 用户开关：config.json 的 enabled 字段（悬浮窗右键「停用跟随启动」写入）
    // /widget 手动命令带 force=true，无视开关直接打开
    if (!force && !readEnabled()) {
      log("开关为关 (enabled=false)，跳过自动启动。可用 /widget 命令手动打开");
      return "disabled";
    }

    // 桌面上已经有同版本的窗口 → 不重复启动（省得单实例锁空转）
    const inst = readInstance();
    if (inst && inst.version === WIDGET_VERSION && isAlive(inst.pid)) {
      log(`同版本悬浮窗已在运行 (pid=${inst.pid})，跳过启动`);
      return "already";
    }
    // 走到这里说明桌面上要么没窗口、要么是旧版本（旧版本可能没有 instance.json），
    // 一律先清掉再拉起，否则单实例互斥体会把新窗口挡掉
    killExisting(logger);

    // 把可用的 Node 路径写给悬浮窗（它自己找不到 node，PATH 里通常没有）
    try {
      const n = resolveNode();
      mkdirSync(LOG_DIR, { recursive: true });
      writeFileSync(NODE_HINT_PATH, n, "utf8");
      log("Node 路径: " + n);
    } catch (e) {
      log("写 node.txt 失败: " + String(e));
    }

    const doSpawn = () => {
      // 注意：不能用 node 的 detached spawn 直接启动 powershell ——
      // Windows 上 detached 模式会让 powershell 立即静默退出(exit 0)。
      // 改用 Start-Process 中转：由 Win32 CreateProcess 原生分离，绝对可靠。
      const helper = spawn(
        "powershell.exe",
        [
          "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
          `Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ` +
          `'-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','${SCRIPT_PATH}'`,
        ],
        { stdio: "ignore", windowsHide: true, cwd: homedir() },
      );

      helper.on("error", (e) => {
        log("中转进程启动失败: " + String(e));
        try { logger?.warn?.("[dsh-balance-widget] 启动悬浮窗失败: " + String(e)); } catch { }
      });
      helper.on("exit", (code) => {
        log("已通过 Start-Process 发起启动 (中转进程 exit=" + code + ")");
      });
    };

    // 杀掉旧进程后留一点时间释放互斥体/文件句柄
    setTimeout(doSpawn, 600);
    return "launched";
  } catch (e) {
    log("异常: " + String(e));
    try { logger?.warn?.("[dsh-balance-widget] 异常: " + String(e)); } catch { }
    return "error";
  }
}

const n0 = (v) => Number(v || 0).toLocaleString("zh-CN");
const money = (v) => "¥" + Number(v || 0).toFixed(2);

/** 扫描本地会话日志，返回用量统计（失败返回 null） */
function scanUsage() {
  try {
    if (!existsSync(SCAN_PATH)) {
      log("用量扫描器缺失: " + SCAN_PATH);
      return null;
    }
    const sessionsDir = join(homedir(), ".dsh", "sessions");
    const node = resolveNode();
    const env = { ...process.env };
    if (/^electron/i.test(pathBasename(node))) env.ELECTRON_RUN_AS_NODE = "1";
    execFileSync(node, [SCAN_PATH, sessionsDir, USAGE_PATH, "--detail"], {
      windowsHide: true,
      timeout: 60000,
      stdio: "ignore",
      env,
    });
    return JSON.parse(readFileSync(USAGE_PATH, "utf8").replace(/^\uFEFF/, ""));
  } catch (e) {
    log("用量扫描失败: " + String(e));
    return null;
  }
}

function usageText() {
  const d = scanUsage();
  if (!d || !d.sum) return "读不到 dsh 会话日志（需要 Node 22+ 解压 ~/.dsh/sessions）";
  const s = d.sum;
  const lines = [];
  lines.push(`dsh 累计用量（本地会话日志估算）`);
  const today = s.todayCost != null ? `（今日 ${money(s.todayCost)} / ${n0(s.todaySteps)} 次）` : "";
  lines.push(`花费 ${money(s.cost)}${today} · tokens ${n0(s.totalTokens)} · 请求 ${n0(s.steps)} 次 · 会话 ${n0(s.usedSessions)} 个`);
  lines.push(`输入 ${n0(s.inputTokens)}（缓存命中 ${n0(s.cacheReadTokens)}）· 输出 ${n0(s.outputTokens)}`);

  if (Array.isArray(d.models) && d.models.length) {
    lines.push("");
    lines.push("按模型：" + d.models.map((m) => `${m.model} ${money(m.cost)}（${n0(m.steps)} 次）`).join(" · "));
  }
  if (Array.isArray(d.daily) && d.daily.length) {
    lines.push("按天（最近 7 天）：");
    d.daily.slice(0, 7).forEach((x) => {
      const barLen = Math.min(20, Math.round((x.cost / Math.max(0.01, d.daily[0].cost)) * 20));
      lines.push(`  ${x.date}  ${money(x.cost).padStart(8)}  ${"▇".repeat(Math.max(1, barLen))}  ${n0(x.steps)} 次`);
    });
  }

  const rows = (d.sessions || []).filter((x) => x.steps > 0).slice(0, 8);
  if (rows.length) {
    lines.push("");
    lines.push("最近消耗 top8：");
    rows.forEach((x, i) => {
      const t = x.lastTime ? new Date(x.lastTime).toLocaleString("zh-CN", { hour12: false, month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }) : "--";
      const task = (x.firstUser || x.title || "(未命名会话)").slice(0, 34);
      lines.push(`${i + 1}. ${t}  ${money(x.cost)}  ${x.steps}次  ${task}`);
    });
  }
  lines.push("");
  lines.push("费用按 DeepSeek 官方峰谷价估算，仅供参考；精确账单看 platform.deepseek.com。");
  lines.push("桌面悬浮窗上单击 dsh 那一行可以点开图形化明细（按会话/天/模型/工作区）。");
  return lines.join("\n");
}

export function apply(ctx) {
  const logger = ctx?.logger;

  // 注册 /widget 斜杠命令：在 dsh 输入框输入 /widget 即可手动打开悬浮窗
  // （无视 enabled 开关；若悬浮窗已在运行则因单实例锁不会重复出现）
  try {
    ctx?.effect?.(() => ctx?.commands?.register({
      name: "widget",
      description: "打开余额悬浮窗（WorkBuddy 算力 + DeepSeek 余额）",
      handler: () => {
        const r = launchWidget(logger, true);
        const map = {
          launched: "正在打开余额悬浮窗（约 1 秒内出现在桌面上）",
          already: "悬浮窗已经在桌面上运行了（单击 dsh 那一行可看用量明细）",
          missing: "启动脚本缺失，无法打开悬浮窗",
          error: "启动失败，查看 %LOCALAPPDATA%\\BalanceWidget\\plugin.log",
          disabled: "已在配置里停用，但 /widget 会强制打开",
        };
        return { kind: "success", text: map[r] || "已发起打开余额悬浮窗" };
      },
    }), "dsh-balance-widget: /widget command");
  } catch { /* 宿主不支持命令注册时静默降级 */ }

  // 注册 /usage 斜杠命令：直接在对话里输出 token 消耗明细
  try {
    ctx?.effect?.(() => ctx?.commands?.register({
      name: "usage",
      description: "查看 dsh 累计 token 消耗与估算花费（按会话/请求）",
      handler: () => ({ kind: "success", text: usageText() }),
    }), "dsh-balance-widget: /usage command");
  } catch { }

  log("插件已加载，3 秒后启动悬浮窗");

  // 宿主就绪后再拉，避免和 dsh 自身的窗口启动抢资源
  try {
    setTimeout(() => launchWidget(logger), 3000);
  } catch {
    launchWidget(logger);
  }

  try {
    ctx?.effect?.(() => () => { /* 保留：dsh 退出时不关闭悬浮窗 */ });
  } catch { }
}
