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
import { appendFileSync, existsSync, mkdirSync } from "node:fs";
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
