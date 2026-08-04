/**
 * Custom footer: same as default, but adds "Path: " prefix to the directory line.
 */

import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { CustomEditor } from "@earendil-works/pi-coding-agent";
import { Container, Spacer, Text, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { EditorTheme, TUI } from "@earendil-works/pi-tui";
import type { KeybindingsManager } from "@earendil-works/pi-coding-agent";
import { isAbsolute, relative, resolve, sep, join } from "node:path";
import { readFileSync, existsSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { exec } from "node:child_process";
import { promisify } from "node:util";

function formatTokens(count: number): string {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
  return `${Math.round(count / 1000000)}M`;
}

function formatCwd(cwd: string, home: string | undefined): string {
  if (!home) return cwd;
  const resolvedCwd = resolve(cwd);
  const resolvedHome = resolve(home);
  const rel = relative(resolvedHome, resolvedCwd);
  const inside = rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
  if (!inside) return cwd;
  return rel === "" ? "~" : `~${sep}${rel}`;
}

// USD → CNY rate, refreshed max once per hour
let _rateCache: { rate: number; ts: number } | null = null;

async function getUsdToCny(): Promise<number> {
  if (_rateCache && Date.now() - _rateCache.ts < 3600_000) return _rateCache.rate;

  try {
    const cachePath = join(homedir(), ".pi", "agent", "rate-cache.json");
    if (existsSync(cachePath)) {
      const cached = JSON.parse(readFileSync(cachePath, "utf8"));
      if (cached.rate && cached.ts && Date.now() - cached.ts < 3600_000) {
        _rateCache = cached;
        return cached.rate;
      }
    }
  } catch { /* ok */ }

  try {
    const res = await fetch("https://open.er-api.com/v6/latest/USD");
    const data = await res.json() as any;
    const rate = data?.rates?.CNY as number;
    if (rate && rate > 0) {
      _rateCache = { rate, ts: Date.now() };
      try {
        const cacheDir = join(homedir(), ".pi", "agent");
        if (!existsSync(cacheDir)) mkdirSync(cacheDir, { recursive: true });
        writeFileSync(join(cacheDir, "rate-cache.json"), JSON.stringify(_rateCache));
      } catch { /* ok */ }
      return rate;
    }
  } catch { /* fall through */ }

  return 7.25;
}

// Git status cache
interface GitStatus {
  modified: boolean;
  untracked: boolean;
  staged: boolean;
  ahead: number;
  behind: number;
  conflicted: boolean;
  stashed: boolean;
}

// ── git 状态：异步刷新 + 缓存，render 不阻塞 ──
let _gitStatusCache: { status: GitStatus | null; ts: number } | null = null;
let _gitStatusFetching = false;
let _onGitStatusChange: (() => void) | null = null;
const GIT_STATUS_TTL = 4000;
const execAsync = promisify(exec);

function getGitStatus(): GitStatus | null {
  if (_gitStatusCache && Date.now() - _gitStatusCache.ts < GIT_STATUS_TTL) {
    return _gitStatusCache.status;
  }
  // 缓存过期：触发异步刷新，本次先返回旧值（不阻塞渲染）
  void refreshGitStatus();
  return _gitStatusCache?.status ?? null;
}

async function refreshGitStatus(): Promise<void> {
  if (_gitStatusFetching) return;
  _gitStatusFetching = true;
  const status = await fetchGitStatusAsync();
  _gitStatusCache = { status, ts: Date.now() };
  _gitStatusFetching = false;
  _onGitStatusChange?.();
}

async function fetchGitStatusAsync(): Promise<GitStatus | null> {
  const isRepo = await execAsync("git rev-parse --is-inside-work-tree", {
    encoding: "utf8", timeout: 2000, windowsHide: true,
  })
    .then(({ stdout }) => stdout.trim() === "true")
    .catch(() => false);
  if (!isRepo) return null;

  const status: GitStatus = { modified: false, untracked: false, staged: false, ahead: 0, behind: 0, conflicted: false, stashed: false };

  // 三个命令互不依赖，并行执行
  const [porcelain, aheadBehind, stashList] = await Promise.all([
    execAsync("git status --porcelain", { encoding: "utf8", timeout: 2000, windowsHide: true, maxBuffer: 10 * 1024 * 1024 }).catch(() => null),
    execAsync("git rev-list --left-right --count @{u}...HEAD 2>/dev/null", { encoding: "utf8", timeout: 2000, windowsHide: true, shell: true }).catch(() => null),
    execAsync("git stash list", { encoding: "utf8", timeout: 2000, windowsHide: true, maxBuffer: 1024 * 1024 }).catch(() => null),
  ]);

  if (porcelain) {
    for (const line of porcelain.stdout.split("\n")) {
      const idx = line.slice(0, 2);
      if (idx.includes("M")) status.modified = true;
      if (idx.includes("?")) status.untracked = true;
      if (idx.includes("A") || idx.includes("D") || idx.includes("R")) status.staged = true;
      if (idx.includes("U")) status.conflicted = true;
    }
  }

  if (aheadBehind) {
    const parts = aheadBehind.stdout.trim().split(/\s+/);
    if (parts.length === 2) {
      status.ahead = parseInt(parts[1], 10) || 0;
      status.behind = parseInt(parts[0], 10) || 0;
    }
  }

  if (stashList) {
    status.stashed = stashList.stdout.trim().length > 0;
  }

  return status;
}

// ── Thinking / Working 计时（合并自 thinking-test.ts）──
function fmtTime(ms: number): string {
  const s = Math.round(ms / 1000);
  return s >= 60 ? `${Math.floor(s / 60)}m${s % 60}s` : `${s}s`;
}

export default function (pi: ExtensionAPI) {
  // ── Working / Thinking 计时状态 ──
  // thinking 段用事件驱动（按 message_update 最后一个 content 块类型判断起止），不设定时器；
  // 实时读秒复用 working 的定时器拼字符串，避免 setHiddenThinkingLabel 全量重建历史消息。
  let workingStartMs: number | null = null;
  let workingInterval: ReturnType<typeof setInterval> | null = null;
  let thinkingSegmentStartMs: number | null = null;
  let msgThinkingMs = 0;
  // 思考段结束后的 "Thought for" 短暂展示：时长 + 展示截止时间
  let lastThoughtMs: number | null = null;
  let thoughtShowUntil = 0;
  const THOUGHT_SHOW_MS = 1500;

  // ── 对话标签：User: / Reply: ──
  let replyLabelAdded = false;

  pi.registerEntryRenderer("user-label", (_entry, _options, theme) => {
    const container = new Container();
    container.addChild(new Spacer(1));
    container.addChild(new Text(theme.fg("accent", "User:"), 1, 0));
    return container;
  });

  pi.registerEntryRenderer("reply-label", (_entry, _options, theme) => {
    return new Text(theme.fg("accent", "Reply:"), 1, 0);
  });

  pi.on("input", async (event) => {
    if (event.source !== "extension") {
      pi.appendEntry("user-label", {});
      replyLabelAdded = false;
    }
    return { action: "continue" };
  });

  pi.on("message_start", async (event) => {
    if (event.message.role === "assistant") {
      if (!replyLabelAdded) {
        replyLabelAdded = true;
        pi.appendEntry("reply-label", {});
      }
      thinkingSegmentStartMs = null;
      msgThinkingMs = 0;
      lastThoughtMs = null;
      thoughtShowUntil = 0;
    }
  });

  // ── Working: 总用时 + 思考段实时计时（编辑器下方）──
  pi.on("agent_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    workingStartMs = Date.now();
    thinkingSegmentStartMs = null;
    msgThinkingMs = 0;
    lastThoughtMs = null;
    thoughtShowUntil = 0;
    if (workingInterval) clearInterval(workingInterval);
    workingInterval = setInterval(() => {
      const working = fmtTime(Date.now() - workingStartMs!);
      let detail = "";
      if (thinkingSegmentStartMs !== null) {
        detail = ` · thinking for ${fmtTime(Date.now() - thinkingSegmentStartMs)}`;
      } else if (lastThoughtMs !== null && Date.now() < thoughtShowUntil) {
        detail = ` · Thought for ${fmtTime(lastThoughtMs)}`;
      }
      ctx.ui.setWorkingMessage(`Working... (${working}${detail})`);
    }, 500);
  });

  pi.on("agent_end", (_event, ctx) => {
    if (!ctx.hasUI) return;
    workingStartMs = null;
    thinkingSegmentStartMs = null;
    lastThoughtMs = null;
    thoughtShowUntil = 0;
    if (workingInterval) { clearInterval(workingInterval); workingInterval = null; }
    ctx.ui.setWorkingMessage();
  });

  // ── Thinking 段检测（事件驱动，无定时器）──
  // 以当前正在生成的 content 块类型判断：变成 thinking 记段起点，
  // 离开 thinking（text/toolCall）段结束并累计时长。
  pi.on("message_update", (event) => {
    if (event.message.role !== "assistant") return;

    const content = event.message.content as { type: string }[];
    const lastType = content[content.length - 1]?.type ?? null;

    if (lastType === "thinking") {
      if (thinkingSegmentStartMs === null) thinkingSegmentStartMs = Date.now();
    } else if (thinkingSegmentStartMs !== null) {
      const segMs = Date.now() - thinkingSegmentStartMs;
      msgThinkingMs += segMs;
      thinkingSegmentStartMs = null;
      lastThoughtMs = segMs;
      thoughtShowUntil = Date.now() + THOUGHT_SHOW_MS;
    }
  });

  pi.on("session_shutdown", () => {
    workingStartMs = null;
    thinkingSegmentStartMs = null;
    msgThinkingMs = 0;
    lastThoughtMs = null;
    thoughtShowUntil = 0;
    if (workingInterval) { clearInterval(workingInterval); workingInterval = null; }
  });

  // ── Thinking 结束标签写回（独立 handler，返回 {message} 替换）──
  // 与 session_start 内的 footer 刷新 message_end 并存，互不干扰
  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") return;
    if (thinkingSegmentStartMs !== null) {
      msgThinkingMs += Date.now() - thinkingSegmentStartMs;
      thinkingSegmentStartMs = null;
    }
    if (msgThinkingMs <= 0) return;
    const label = `Thought for ${Math.round(msgThinkingMs / 1000)}s`;
    msgThinkingMs = 0;
    return {
      message: {
        ...event.message,
        hiddenThinkingLabel: label,
      },
    };
  });

  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui") return;

    getUsdToCny();

    // ── 不可编辑的 > 前缀（渲染层画上去，不在文本里） ──
    const PROMPT = "\x1b[90m>\x1b[0m ";
    const PROMPT_W = visibleWidth(PROMPT);

    ctx.ui.setEditorComponent((tui: TUI, theme: EditorTheme, keybindings: KeybindingsManager) => {
      class PromptEditor extends CustomEditor {
        render(width: number): string[] {
          const lines = super.render(width);
          if (lines.length < 3) return lines;
          for (let i = 1; i < lines.length - 1; i++) {
            const line = lines[i];
            const match = line.match(/^( +)/);
            if (match) {
              const pad = match[1];
              const rest = line.slice(pad.length);
              if (pad.length >= PROMPT_W) {
                lines[i] = pad.slice(0, pad.length - PROMPT_W) + PROMPT + rest;
              } else {
                lines[i] = truncateToWidth(PROMPT + line, width, "");
              }
              break;
            }
            lines[i] = truncateToWidth(PROMPT + line, width, "");
            break;
          }
          return lines;
        }
      }
      return new PromptEditor(tui, theme, keybindings);
    });

    // ── Footer：初始值 + 事件驱动，零 TTL 轮询 ──
    // thinking level: 初始读文件 + thinking_level_select 事件更新
    let thinkingLevel = "off";
    try {
      const raw = readFileSync(join(homedir(), ".pi", "agent", "settings.json"), "utf8");
      thinkingLevel = JSON.parse(raw).defaultThinkingLevel ?? "off";
    } catch { /* ok */ }

    // session name: 初始读取 + session_info_changed 事件更新
    let sessionName: string | undefined = ctx.sessionManager.getSessionName();

    pi.on("thinking_level_select", (event) => { thinkingLevel = event.level; });
    pi.on("session_info_changed", (event) => { sessionName = event.name?.trim() || undefined; });

    // token stats: message_end 事件驱动
    let invalidateStats: () => void = () => {};
    pi.on("message_end", async (event) => {
      const msg = (event as any).message;
      if (msg?.role === "assistant") invalidateStats();
    });

    ctx.ui.setFooter((_tui, theme, footerData) => {
      const unsub = footerData.onBranchChange(() => _tui.requestRender());
      // git 状态异步刷新完成后，通知 footer 重新渲染
      _onGitStatusChange = () => _tui.requestRender();

      let _statsCache: string | null = null;

      const computeTokenStats = (): string => {
        if (_statsCache !== null) return _statsCache;
        let input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cost = 0;
        let cacheHitRate: number | undefined;
        for (const e of ctx.sessionManager.getBranch()) {
          if (e.type === "message" && e.message.role === "assistant") {
            const m = e.message as AssistantMessage;
            input += m.usage.input;
            output += m.usage.output;
            cacheRead += m.usage.cacheRead;
            cacheWrite += m.usage.cacheWrite;
            cost += m.usage.cost.total;
            const pt = input + cacheRead + cacheWrite;
            cacheHitRate = pt > 0 ? (cacheRead / pt) * 100 : undefined;
          }
        }
        const parts: string[] = [];
        if (input) parts.push(`↑${formatTokens(input)}`);
        if (output) parts.push(`↓${formatTokens(output)}`);
        if (cacheRead) parts.push(`R${formatTokens(cacheRead)}`);
        if (cacheWrite) parts.push(`W${formatTokens(cacheWrite)}`);
        if ((cacheRead > 0 || cacheWrite > 0) && cacheHitRate !== undefined) {
          parts.push(`CH${cacheHitRate.toFixed(1)}%`);
        }
        if (cost) parts.push(`¥${(cost * (_rateCache?.rate ?? 7.25)).toFixed(3)}`);
        const cu = ctx.getContextUsage();
        const ctxWin = cu?.contextWindow ?? 0;
        const ctxPct = cu?.percent;
        const ctxTokens = cu?.tokens;
        const ctxStr = ctxTokens != null && ctxPct != null
          ? `${ctxTokens.toLocaleString()}/${formatTokens(ctxWin)}(${ctxPct.toFixed(1)}%)`
          : ctxPct !== null && ctxPct !== undefined
            ? `${ctxPct.toFixed(1)}%/${formatTokens(ctxWin)}`
            : `?/${formatTokens(ctxWin)}`;
        parts.push(ctxStr);
        return (_statsCache = parts.join(" "));
      };

      invalidateStats = () => { _statsCache = null; };

      return {
        dispose: () => {
          _onGitStatusChange = null;
          unsub();
        },
        invalidate() {},
        render(width: number): string[] {
          const home = process.env.HOME || process.env.USERPROFILE;

          // ── Line 1: 路径 + git ──
          let pwd = "Path: " + formatCwd(ctx.sessionManager.getCwd(), home);
          const branch = footerData.getGitBranch();
          const gitStatus = getGitStatus();
          if (gitStatus) {
            const icons: string[] = [];
            if (gitStatus.conflicted) icons.push("=");
            if (gitStatus.staged) icons.push("+");
            if (gitStatus.modified) icons.push("!");
            if (gitStatus.untracked) icons.push("?");
            if (gitStatus.ahead > 0) icons.push(`↑${gitStatus.ahead}`);
            if (gitStatus.behind > 0) icons.push(`↓${gitStatus.behind}`);
            if (gitStatus.stashed) icons.push("$");
            const gs = icons.length > 0 ? ` ${icons.join(" ")}` : "";
            pwd = `${pwd} (${branch || "HEAD"}${gs})`;
          } else {
            pwd = `${pwd} (no git repo)`;
          }
          if (sessionName) pwd = `${pwd} · ${sessionName}`;
          const line1 = truncateToWidth(theme.fg("dim", pwd), width, theme.fg("dim", "..."));

          // ── Line 2: token 统计 + model ──
          let statsLeft = computeTokenStats();

          let rightSide = ctx.model?.id ?? "";
          if (ctx.model?.reasoning) {
            rightSide = thinkingLevel === "off"
              ? `${rightSide} · thinking off`
              : `${rightSide} · ${thinkingLevel}`;
          }

          let leftW = visibleWidth(statsLeft);
          if (leftW > width) {
            statsLeft = truncateToWidth(statsLeft, width, "...");
            leftW = visibleWidth(statsLeft);
          }

          const rightW = visibleWidth(rightSide);
          let line2: string;
          if (leftW + 2 + rightW <= width) {
            line2 = statsLeft + " ".repeat(width - leftW - rightW) + rightSide;
          } else {
            const avail = width - leftW - 2;
            if (avail > 0) {
              const t = truncateToWidth(rightSide, avail, "");
              line2 = statsLeft + " ".repeat(Math.max(0, width - leftW - visibleWidth(t))) + t;
            } else {
              line2 = statsLeft;
            }
          }
          line2 = theme.fg("dim", line2);

          return [line1, line2];
        },
      };
    });
  });
}
