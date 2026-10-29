/**
 * dsh-balance-widget — 宿主半侧插件
 *
 * 作用：dsh desktop profile 启动（即桌宠 dsh-pet 出现）时，把余额悬浮窗一并拉起。
 * 不写任何开机启动项、不注册计划任务；dsh 不启动时悬浮窗也不会自己出现。
 *
 * 设计要点：
 * - 全程 try/catch，任何失败都不影响 dsh / 桌宠正常启动；
 * - 悬浮窗脚本自身带命名互斥体单实例保护，多次启动不会出现重复窗口；
 * - dsh 退出时（ctx.effect 清理）不杀悬浮窗，用户可能仍想看着余额。
 */
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const name = "dsh-balance-widget";

/** 无强依赖：即使宿主没提供任何服务，本插件也能独立完成启动动作 */
export const inject = [];

// 自包含：悬浮窗脚本随插件分发，路径相对插件目录解析
const SCRIPT_PATH = join(dirname(fileURLToPath(import.meta.url)), "BalanceWidget.ps1");
const LOG_DIR = join(process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local"), "BalanceWidget");
const LOG_PATH = join(LOG_DIR, "plugin.log");

function log(msg) {
  try {
    mkdirSync(LOG_DIR, { recursive: true });
    appendFileSync(LOG_PATH, `${new Date().toLocaleString("zh-CN", { hour12: false })} [dsh-balance-widget] ${msg}\n`, "utf8");
  } catch { }
}

function launchWidget(logger) {
  try {
    if (!existsSync(SCRIPT_PATH)) {
      log("脚本不存在，跳过: " + SCRIPT_PATH);
      return;
    }

    // 用户开关：config.json 的 enabled 字段（悬浮窗右键「停用跟随启动」写入）
    const cfgPath = join(LOG_DIR, "config.json");
    if (existsSync(cfgPath)) {
      try {
        // PowerShell 写出的 UTF-8 带 BOM，必须先剥离再 JSON.parse
        const raw = readFileSync(cfgPath, "utf8").replace(/^\uFEFF/, "");
        const cfg = JSON.parse(raw);
        if (cfg.enabled === false) {
          log("开关为关 (enabled=false)，跳过启动。重新开启：把 config.json 的 enabled 改回 true");
          return;
        }
      } catch (e) {
        log("读取开关配置失败，按默认开启处理: " + String(e));
      }
    }

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
  } catch (e) {
    log("异常: " + String(e));
    try { logger?.warn?.("[dsh-balance-widget] 异常: " + String(e)); } catch { }
  }
}

export function apply(ctx) {
  const logger = ctx?.logger;
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
