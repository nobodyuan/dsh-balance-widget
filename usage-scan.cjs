#!/usr/bin/env node
/**
 * usage-scan.cjs — 扫描 dsh 本地会话日志，统计 token 消耗与估算费用
 *
 * 用法: node usage-scan.cjs [sessionsDir] [outJsonPath] [--detail]
 *   --detail  额外输出每次请求（step）级别的明细
 *
 * 数据来源: <sessionsDir>/<workdir>/session-<id>/session.v4.jsonl.zstd
 *   - 文件是「多个 zstd 帧首尾相接」的 JSONL（每行一次追加），
 *     必须按 magic(28 B5 2F FD) 切开逐帧解压，否则只能拿到第一行。
 *   - assistant/message.data.usage = { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens }
 *   - request/header.data.header.config.model = 该次请求使用的模型
 *   - user/message 的首条文本可作为「任务名」
 *
 * 费用口径（DeepSeek 官方价，元/百万 tokens，2026-09-10 起）：
 *   deepseek-flash  缓存命中 0.02/0.04  未命中 1/2   输出 4/8
 *   deepseek-v4-pro 缓存命中 0.15/0.30  未命中 4.5/9 输出 13.5/27
 *   （斜杠前为空闲时段、后为高峰时段；高峰=北京时间周一至周五 9-12、14-18，其余含周末节假日全为空闲）
 */
const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

const PRICING = {
  "deepseek-flash": { off: { hit: 0.02, miss: 1, out: 4 }, peak: { hit: 0.04, miss: 2, out: 8 } },
  "deepseek-v4-flash": { off: { hit: 0.02, miss: 1, out: 4 }, peak: { hit: 0.04, miss: 2, out: 8 } },
  "deepseek-v4-flash-vision-exp": { off: { hit: 0.02, miss: 1, out: 4 }, peak: { hit: 0.04, miss: 2, out: 8 } },
  "deepseek-chat": { off: { hit: 0.02, miss: 1, out: 4 }, peak: { hit: 0.04, miss: 2, out: 8 } },
  "deepseek-reasoner": { off: { hit: 0.02, miss: 1, out: 4 }, peak: { hit: 0.04, miss: 2, out: 8 } },
  "deepseek-v4-pro": { off: { hit: 0.15, miss: 4.5, out: 13.5 }, peak: { hit: 0.3, miss: 9, out: 27 } },
};
const DEFAULT_PRICE = PRICING["deepseek-flash"];

/** 北京时间是否处于高峰时段（周一至周五 9-12、14-18） */
function isPeak(ms) {
  if (!ms) return false;
  const d = new Date(ms + 8 * 3600 * 1000);
  const day = d.getUTCDay();
  if (day === 0 || day === 6) return false;
  const h = d.getUTCHours();
  return (h >= 9 && h < 12) || (h >= 14 && h < 18);
}

function costOf(model, ms, inp, out, cacheRead) {
  const p = PRICING[model] || DEFAULT_PRICE;
  const t = isPeak(ms) ? p.peak : p.off;
  return (inp * t.miss + cacheRead * t.hit + out * t.out) / 1e6;
}

/** 解压由多个 zstd 帧拼接的文件 */
function decompressConcat(buf) {
  if (typeof zlib.zstdDecompressSync !== "function") {
    throw new Error("当前 Node 不支持 zstd（需要 Node >= 22.15）");
  }
  const idx = [];
  let i = 0;
  while (true) {
    const p = buf.indexOf(MAGIC, i);
    if (p < 0) break;
    idx.push(p);
    i = p + 4;
  }
  if (!idx.length) return "";
  const out = [];
  for (let k = 0; k < idx.length; k++) {
    const end = k + 1 < idx.length ? idx[k + 1] : buf.length;
    try {
      out.push(zlib.zstdDecompressSync(buf.subarray(idx[k], end)));
    } catch {
      /* 单帧损坏就跳过，不影响其余内容 */
    }
  }
  return Buffer.concat(out).toString("utf8");
}

function walk(dir, acc) {
  let ents;
  try {
    ents = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.startsWith("session.") && e.name.endsWith(".zstd")) acc.push(p);
  }
  return acc;
}

function pickText(content) {
  if (!content) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((c) => c && c.type === "text" && typeof c.text === "string")
      .map((c) => c.text)
      .join(" ")
      .trim();
  }
  return "";
}

function shortTitle(s, n = 44) {
  const t = String(s || "")
    .replace(/\s+/g, " ")
    .replace(/^[#>*\-\s]+/, "")
    .trim();
  return t.length > n ? t.slice(0, n) + "…" : t;
}

function scanFile(file) {
  let text;
  try {
    text = decompressConcat(fs.readFileSync(file));
  } catch {
    return null;
  }
  const rec = {
    id: path.basename(path.dirname(file)).replace(/^session-/, ""),
    workdir: path.basename(path.dirname(path.dirname(file))).replace(/^--|--$/g, ""),
    title: "",
    firstUser: "",
    turns: 0,
    steps: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 0,
    cost: 0,
    firstTime: 0,
    lastTime: 0,
    models: {},
    stepList: [],
  };
  let curModel = "";
  let curUserText = "";

  for (const line of text.split("\n")) {
    if (!line) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    const d = o.data || {};
    if (o.time) {
      if (!rec.firstTime || o.time < rec.firstTime) rec.firstTime = o.time;
      if (o.time > rec.lastTime) rec.lastTime = o.time;
    }
    switch (o.type) {
      case "session/title":
        if (d.title) rec.title = d.title;
        break;
      case "user/message": {
        const t = pickText((d.message && d.message.content) || d.content);
        if (t && t.length > 1) {
          if (!rec.firstUser) rec.firstUser = shortTitle(t);
          curUserText = t;
        }
        break;
      }
      case "request/header": {
        const m = d.header && d.header.config && d.header.config.model;
        if (m) curModel = m;
        break;
      }
      case "turn/start":
        rec.turns++;
        break;
      case "assistant/message": {
        const u = d.usage;
        if (!u) break;
        const inp = Number(u.inputTokens) || 0;
        const out = Number(u.outputTokens) || 0;
        const cr = Number(u.cacheReadTokens) || 0;
        const cw = Number(u.cacheWriteTokens) || 0;
        const mdl = curModel || "deepseek-flash";
        const c = costOf(mdl, o.time, inp, out, cr);
        rec.steps++;
        rec.inputTokens += inp;
        rec.outputTokens += out;
        rec.cacheReadTokens += cr;
        rec.cacheWriteTokens += cw;
        rec.cost += c;
        rec.totalTokens += Number(u.totalTokens) || inp + out + cr + cw;
        if (!rec.models[mdl]) rec.models[mdl] = { n: 0, in: 0, out: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
        const mm = rec.models[mdl];
        mm.n++;
        mm.in += inp;
        mm.out += out;
        mm.cacheRead += cr;
        mm.cacheWrite += cw;
        mm.cost += c;
        rec.stepList.push({
          t: o.time || 0,
          model: mdl,
          peak: isPeak(o.time),
          in: inp,
          out: out,
          cacheRead: cr,
          cost: Math.round(c * 1e4) / 1e4,
          task: shortTitle(curUserText, 60),
        });
        break;
      }
      default:
        break;
    }
  }
  rec.cost = Math.round(rec.cost * 1e4) / 1e4;
  return rec;
}

function main() {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
  const wantDetail = process.argv.includes("--detail");
  const sessionsDir = args[0] || path.join(process.env.USERPROFILE || ".", ".dsh", "sessions");
  const outPath = args[1] || "";

  const files = walk(sessionsDir, []);
  const sessions = [];
  for (const f of files) {
    const r = scanFile(f);
    if (r) sessions.push(r);
  }
  sessions.sort((a, b) => b.lastTime - a.lastTime);

  const sum = {
    sessions: sessions.length,
    usedSessions: 0,
    steps: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 0,
    cost: 0,
  };
  for (const s of sessions) {
    sum.steps += s.steps;
    sum.inputTokens += s.inputTokens;
    sum.outputTokens += s.outputTokens;
    sum.cacheReadTokens += s.cacheReadTokens;
    sum.cacheWriteTokens += s.cacheWriteTokens;
    sum.totalTokens += s.totalTokens;
    sum.cost += s.cost;
    if (s.steps > 0) sum.usedSessions++;
  }
  sum.cost = Math.round(sum.cost * 100) / 100;

  const payload = { at: Date.now(), sum, sessions };
  if (!wantDetail) for (const s of sessions) delete s.stepList;
  const json = JSON.stringify(payload);
  if (outPath) {
    const tmp = outPath + ".tmp";
    fs.writeFileSync(tmp, json, "utf8");
    try {
      fs.renameSync(tmp, outPath);
    } catch {
      fs.writeFileSync(outPath, json, "utf8");
    }
  } else {
    process.stdout.write(json);
  }
}

main();
