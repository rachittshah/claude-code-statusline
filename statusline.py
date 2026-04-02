#!/usr/bin/env python3
"""
Claude Code Statusline — glanceable intelligence for your terminal.

A status bar that tells you not just where you are, but whether you need to act.
One color palette. No configuration bloat. Pure signal.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ─── Constants ───────────────────────────────────────────────────────────────────

VERSION = "2.1.0"

CONFIG_DIR = Path.home() / ".config" / "claude-statusline"
CACHE_DIR = Path.home() / ".cache" / "claude-statusline"
CONFIG_FILE = CONFIG_DIR / "config.json"
HISTORY_FILE = CACHE_DIR / "history.json"
GIT_CACHE_FILE = CACHE_DIR / "git_cache.json"
FX_CACHE_FILE = CACHE_DIR / "fx_cache.json"
JOURNAL_FILE = CACHE_DIR / "journal.jsonl"
SESSION_STATE_FILE = CACHE_DIR / "session.json"
TELEMETRY_FILE = CACHE_DIR / "telemetry.json"

# Unicode sub-character blocks for bar precision (9 levels: empty through full)
BLOCKS = " ▏▎▍▌▋▊▉█"

RST = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"

HISTORY_MAX_AGE = 1800      # 30 minutes of samples
HISTORY_MAX_SAMPLES = 360   # ~1 sample per 5 seconds
HISTORY_MIN_INTERVAL = 5    # seconds between samples
GIT_CACHE_TTL = 10          # seconds
FX_CACHE_TTL = 86400        # 24 hours

# ─── The Palette ─────────────────────────────────────────────────────────────────
#
# One palette. Traffic-light legibility on any dark terminal.
# Green = safe. Amber = attention. Red = act now.
#

C_LOW  = (34, 197, 94)     # Emerald — safe zone
C_MID  = (245, 158, 11)    # Amber — attention zone
C_HIGH = (239, 68, 68)     # Red — danger zone
C_TEXT = (209, 213, 219)    # Soft white — labels and values
C_DIM  = (100, 116, 139)   # Slate — separators, secondary info
C_CYAN = (34, 211, 238)    # Cyan — model name accent
C_BLUE = (96, 165, 250)    # Blue — directory accent
C_PEAK = (250, 204, 21)    # Gold — peak hours warning


# ─── Color Utilities ─────────────────────────────────────────────────────────────

def fg(r: int, g: int, b: int) -> str:
    return f"\033[38;2;{r};{g};{b}m"


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * max(0.0, min(1.0, t))


def lerp_color(c1: tuple, c2: tuple, t: float) -> tuple:
    return (int(lerp(c1[0], c2[0], t)),
            int(lerp(c1[1], c2[1], t)),
            int(lerp(c1[2], c2[2], t)))


def pct_color(pct: float) -> tuple:
    """Map 0-100% to the traffic-light gradient."""
    pct = max(0.0, min(100.0, pct))
    if pct <= 60:
        return lerp_color(C_LOW, C_MID, pct / 60)
    return lerp_color(C_MID, C_HIGH, (pct - 60) / 40)


def tc(s: str, color: tuple) -> str:
    """Apply truecolor to string."""
    return f"{fg(*color)}{s}{RST}"


def dim(s: str) -> str:
    return f"{fg(*C_DIM)}{s}{RST}"


def visible_len(s: str) -> int:
    return len(re.sub(r'\033\[[^m]*m', '', s))


# ─── Bar Rendering ───────────────────────────────────────────────────────────────

def render_bar(pct: float, width: int = 10) -> str:
    """
    Render a Unicode progress bar with truecolor.

    The entire filled portion is ONE color determined by the percentage.
    Green = safe. Amber = attention. Red = act now.
    Sub-character precision via Unicode block elements.
    """
    pct = max(0.0, min(100.0, pct))
    color = pct_color(pct)
    fill_exact = pct / 100 * width
    fill_full = int(fill_exact)
    partial_idx = int((fill_exact - fill_full) * 8)

    parts = []

    # Filled blocks
    if fill_full > 0:
        parts.append(f"{fg(*color)}{'█' * fill_full}")

    # Partial block
    if partial_idx > 0 and fill_full < width:
        parts.append(f"{fg(*color)}{BLOCKS[partial_idx]}")
        empty_start = fill_full + 1
    else:
        empty_start = fill_full

    # Empty portion
    empty_count = width - empty_start
    if empty_count > 0:
        parts.append(f"{fg(*C_DIM)}{'─' * empty_count}")

    return "".join(parts) + RST


# ─── Configuration ───────────────────────────────────────────────────────────────

DEFAULT_CONFIG = {
    "currency": "$",
    "bar_width": 10,
    "peak_hours": {"enabled": True, "start": "13:00", "end": "19:00"},
    "show": {
        "session": True,
        "weekly": True,
        "context": True,
        "cost": True,
        "model": True,
        "git": True,
        "effort": True,
        "peak": True,
        "lines": True,
        "duration": True,
        "telemetry": True,
        "harness": True,
        "burn_rate": True,
        "runway_alert": True,
        "reset_timer": True,
        "context_velocity": True,
    },
}


def load_config() -> dict:
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    try:
        if CONFIG_FILE.exists():
            user = json.loads(CONFIG_FILE.read_text())
            if "show" in user:
                config["show"].update(user.pop("show"))
            config.update(user)
    except Exception:
        pass
    return config


def save_config(config: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_FILE.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(config, indent=2) + "\n")
    tmp.replace(CONFIG_FILE)


# ─── Cache ───────────────────────────────────────────────────────────────────────

def _ensure_cache():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)


def read_json(path: Path):
    try:
        return json.loads(path.read_text()) if path.exists() else None
    except Exception:
        return None


def write_json(path: Path, data) -> None:
    _ensure_cache()
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data))
    tmp.replace(path)


# ─── Stdin Parser ────────────────────────────────────────────────────────────────

def _get(data: dict, path: str, default=None):
    obj = data
    for key in path.split("."):
        if isinstance(obj, dict):
            obj = obj.get(key)
        else:
            return default
    return obj if obj is not None else default


def parse_stdin() -> dict:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return {}
        data = json.loads(raw)
    except Exception:
        return {}

    # Debug: save RAW stdin
    if os.environ.get("STATUSLINE_DEBUG"):
        _ensure_cache()
        (CACHE_DIR / "debug_raw.json").write_text(
            json.dumps(data, indent=2, default=str)
        )

    ctx_pct = _get(data, "context_window.used_percentage", 0) or 0
    ctx_remaining = _get(data, "context_window.remaining_percentage", None)
    tokens_used = _get(data, "context_window.tokens_used", 0) or 0
    token_limit = _get(data, "context_window.token_limit", 0) or 0
    ctx_size = _get(data, "context_window.context_window_size", 0) or 0

    # Fallback: compute context % from current_usage tokens
    if ctx_pct == 0 and (token_limit > 0 or ctx_size > 0):
        limit = token_limit or ctx_size
        # Try current_usage fields
        input_tk = _get(data, "context_window.current_usage.input_tokens", 0) or 0
        cache_create = _get(data, "context_window.current_usage.cache_creation_input_tokens", 0) or 0
        cache_read = _get(data, "context_window.current_usage.cache_read_input_tokens", 0) or 0
        total_input = _get(data, "context_window.total_input_tokens", 0) or 0
        used = (input_tk + cache_create + cache_read) or total_input or tokens_used
        if used > 0 and limit > 0:
            ctx_pct = round(used / limit * 100, 1)

    # Model: handle both nested {"display_name": "..."} and flat string
    model_raw = data.get("model", "")
    if isinstance(model_raw, dict):
        model = model_raw.get("display_name", "") or model_raw.get("id", "")
    else:
        model = str(model_raw) if model_raw else ""

    # Rate limits: handle both field names and both timestamp formats
    def _rate(window: str):
        rl = _get(data, f"rate_limits.{window}", {}) or {}
        if not isinstance(rl, dict):
            return 0.0, ""
        pct = rl.get("used_percentage") or rl.get("percentage_used") or 0
        resets = rl.get("resets_at", "")
        if isinstance(resets, (int, float)) and resets > 1_000_000_000:
            resets = datetime.fromtimestamp(resets, tz=timezone.utc).isoformat()
        return float(pct), str(resets) if resets else ""

    s_pct, s_resets = _rate("five_hour")
    w_pct, w_resets = _rate("seven_day")

    # Lines: try cost.total_lines_added first, then lines.added
    lines_added = (_get(data, "cost.total_lines_added", 0) or
                   _get(data, "lines.added", 0) or 0)
    lines_removed = (_get(data, "cost.total_lines_removed", 0) or
                     _get(data, "lines.removed", 0) or 0)

    # Duration
    duration_ms = _get(data, "cost.total_duration_ms", 0) or 0

    return {
        "model": model,
        "ctx_pct": ctx_pct,
        "ctx_remaining": ctx_remaining,
        "tokens_used": tokens_used,
        "token_limit": token_limit,
        "ctx_size": ctx_size,
        "cost_usd": _get(data, "cost.total_cost_usd", 0) or 0,
        "session_pct": s_pct,
        "session_resets": s_resets,
        "weekly_pct": w_pct,
        "weekly_resets": w_resets,
        "cwd": _get(data, "workspace.current_dir", "") or _get(data, "cwd", ""),
        "git_branch": _get(data, "workspace.git_branch", ""),
        "vim_mode": _get(data, "vim.mode", ""),
        "agent_name": _get(data, "agent.name", ""),
        "worktree": _get(data, "worktree.branch", ""),
        "lines_added": lines_added,
        "lines_removed": lines_removed,
        "duration_ms": duration_ms,
        "effort": os.environ.get("CLAUDE_CODE_EFFORT_LEVEL", ""),
    }


# ─── History & Burn Rate ─────────────────────────────────────────────────────────

def load_history() -> list:
    data = read_json(HISTORY_FILE)
    return data if isinstance(data, list) else []


def record_history(history: list, s_pct: float, w_pct: float, c_pct: float) -> list:
    """Append a sample. Rate-limited to one per HISTORY_MIN_INTERVAL seconds."""
    now = time.time()
    if s_pct == 0 and w_pct == 0 and c_pct == 0:
        return history
    if history and now - history[-1]["t"] < HISTORY_MIN_INTERVAL:
        return history

    # Detect usage reset: if session or weekly dropped by >20%, clear history
    # so burn rate doesn't go negative from stale pre-reset samples
    if history:
        last = history[-1]
        if (last.get("s", 0) - s_pct > 20) or (last.get("w", 0) - w_pct > 20):
            history = []

    history.append({"t": now, "s": round(s_pct, 1), "w": round(w_pct, 1), "c": round(c_pct, 1)})

    # Prune
    cutoff = now - HISTORY_MAX_AGE
    history = [h for h in history if h["t"] >= cutoff][-HISTORY_MAX_SAMPLES:]
    write_json(HISTORY_FILE, history)
    return history


def burn_rate(history: list, key: str = "s", window_min: int = 15):
    """
    Linear regression over recent history.
    Returns (pct_per_hour, minutes_to_100%) or (None, None).
    """
    now = time.time()
    pts = [(h["t"], h[key]) for h in history if h["t"] >= now - window_min * 60 and key in h]
    if len(pts) < 3:
        return None, None

    n = len(pts)
    t0 = pts[0][0]
    xs = [(p[0] - t0) / 60 for p in pts]
    ys = [p[1] for p in pts]
    xm = sum(xs) / n
    ym = sum(ys) / n
    ss_xy = sum((x - xm) * (y - ym) for x, y in zip(xs, ys))
    ss_xx = sum((x - xm) ** 2 for x in xs)

    if ss_xx < 0.001:
        return 0.0, None

    slope = ss_xy / ss_xx  # pct per minute
    if slope <= 0.01:
        return 0.0, None

    remaining = 100 - ys[-1]
    if remaining <= 0:
        return round(slope * 60, 1), 0.0

    return round(slope * 60, 1), round(remaining / slope, 1)


# ─── Context Velocity ────────────────────────────────────────────────────────────

def ctx_velocity(history: list, window_sec: int = 120) -> float:
    """Context growth rate in pct/minute."""
    now = time.time()
    pts = [(h["t"], h["c"]) for h in history if h["t"] >= now - window_sec and "c" in h]
    if len(pts) < 2:
        return 0.0
    dp = pts[-1][1] - pts[0][1]
    dt = pts[-1][0] - pts[0][0]
    return dp / dt * 60 if dt > 5 else 0.0


def velocity_arrows(vel: float) -> str:
    if vel > 5:
        return "↑↑↑"
    if vel > 2:
        return "↑↑"
    if vel > 0.5:
        return "↑"
    if vel < -0.5:
        return "↓"
    return ""


# ─── Peak Hours ──────────────────────────────────────────────────────────────────

def check_peak(config: dict):
    """Returns ("in_peak", mins_left) | ("approaching", mins_until) | None"""
    ph = config.get("peak_hours", {})
    if not ph.get("enabled", True):
        return None
    try:
        now = datetime.now()
        sh, sm = map(int, ph.get("start", "13:00").split(":"))
        eh, em = map(int, ph.get("end", "19:00").split(":"))
        start = now.replace(hour=sh, minute=sm, second=0, microsecond=0)
        end = now.replace(hour=eh, minute=em, second=0, microsecond=0)
        if start <= now <= end:
            return ("in_peak", (end - now).total_seconds() / 60)
        if now < start and (start - now).total_seconds() / 60 <= 60:
            return ("approaching", (start - now).total_seconds() / 60)
        return None
    except Exception:
        return None


# ─── Git Status ──────────────────────────────────────────────────────────────────

def git_info(cwd: str, stdin_branch: str) -> dict:
    """Branch + dirty count, cached for GIT_CACHE_TTL seconds."""
    if not cwd:
        return {"branch": "", "dirty": 0}

    cache = read_json(GIT_CACHE_FILE)
    if cache and cache.get("cwd") == cwd and time.time() - cache.get("t", 0) < GIT_CACHE_TTL:
        branch = stdin_branch or cache.get("branch", "")
        return {"branch": branch, "dirty": cache.get("dirty", 0)}

    branch = stdin_branch
    dirty = 0
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "status", "--porcelain", "-uno"],
            capture_output=True, text=True, timeout=2,
        )
        if r.returncode == 0:
            dirty = sum(1 for line in r.stdout.strip().split("\n") if line.strip())
            if not branch:
                br = subprocess.run(
                    ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                    capture_output=True, text=True, timeout=2,
                )
                branch = br.stdout.strip() if br.returncode == 0 else ""
    except Exception:
        pass

    write_json(GIT_CACHE_FILE, {"t": time.time(), "cwd": cwd, "branch": branch, "dirty": dirty})
    return {"branch": branch, "dirty": dirty}


# ─── Currency ────────────────────────────────────────────────────────────────────

SYMBOL_TO_CODE = {
    "£": "GBP", "€": "EUR", "¥": "JPY", "₹": "INR", "₩": "KRW",
    "C$": "CAD", "A$": "AUD", "NZ$": "NZD", "kr": "SEK", "R$": "BRL",
    "zł": "PLN", "Fr": "CHF", "₺": "TRY", "₱": "PHP", "฿": "THB",
    "R": "ZAR", "Rp": "IDR", "RM": "MYR",
}

FALLBACK_FX = {
    "GBP": 0.79, "EUR": 0.92, "JPY": 149.5, "INR": 83.3, "KRW": 1320,
    "CAD": 1.36, "AUD": 1.53, "NZD": 1.64, "SEK": 10.5, "BRL": 4.97,
    "PLN": 4.03, "CHF": 0.88, "TRY": 30.2, "PHP": 55.8, "THB": 35.3,
    "ZAR": 18.6, "IDR": 15500, "MYR": 4.72,
}


def _fx_rate(code: str) -> float:
    cache = read_json(FX_CACHE_FILE)
    cached_rate = cache.get("rates", {}).get(code) if cache else None

    # Serve from cache if fresh
    if cache and time.time() - cache.get("t", 0) < FX_CACHE_TTL:
        return cached_rate if cached_rate is not None else FALLBACK_FX.get(code, 1)

    # Try refresh, but prefer stale cached rate over blocking on failure
    try:
        import urllib.request
        req = urllib.request.Request(
            "https://api.frankfurter.dev/v1/latest?from=USD",
            headers={"User-Agent": "claude-statusline"},
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read())
            write_json(FX_CACHE_FILE, {"t": time.time(), "rates": data.get("rates", {})})
            return data["rates"].get(code, FALLBACK_FX.get(code, 1))
    except Exception:
        # Prefer stale cache over hardcoded fallback
        if cached_rate is not None:
            return cached_rate
        return FALLBACK_FX.get(code, 1)


def format_cost(usd: float, symbol: str) -> str:
    if symbol == "$" or not symbol:
        return f"${usd:.2f}"
    code = SYMBOL_TO_CODE.get(symbol)
    if not code:
        return f"{symbol}{usd:.2f}"
    converted = usd * _fx_rate(code)
    if converted >= 1000:
        return f"{symbol}{converted:,.0f}"
    if converted >= 100:
        return f"{symbol}{converted:.0f}"
    return f"{symbol}{converted:.2f}"


# ─── Time Formatting ─────────────────────────────────────────────────────────────

def format_reset(iso_str: str) -> str:
    """ISO timestamp → human countdown."""
    if not iso_str:
        return ""
    try:
        s = iso_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        now = datetime.now(timezone.utc)
        secs = (dt - now).total_seconds()
        if secs <= 0:
            return "now"
        h, rem = divmod(int(secs), 3600)
        m = rem // 60
        if h >= 24:
            return f"{dt.strftime('%a')} {dt.strftime('%-I%p').lower()}"
        if h > 0:
            return f"{h}h{m:02d}m"
        return f"{m}m" if m > 0 else "<1m"
    except Exception:
        return ""


def _reset_minutes(iso_str: str) -> float:
    """Parse reset time and return minutes until reset."""
    if not iso_str:
        return 0
    try:
        s = iso_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return max(0, (dt - datetime.now(timezone.utc)).total_seconds() / 60)
    except Exception:
        return 0


def format_runway(minutes: float) -> str:
    if minutes <= 0:
        return ""
    if minutes >= 1440:
        return f"~{minutes / 1440:.0f}d"
    if minutes >= 60:
        return f"~{int(minutes // 60)}h{int(minutes % 60):02d}m"
    return f"~{minutes:.0f}m"


# ─── Widgets ─────────────────────────────────────────────────────────────────────
#
# Each widget returns a string or None (hidden).
# Design rule: only show information that helps the user DECIDE something.
#

SEP = None  # set in render()


def _sep() -> str:
    return f" {fg(*C_DIM)}│{RST} "


def w_session(data: dict, cfg: dict, hist: list) -> str | None:
    """Session usage: bar + pct + reset timer + burn rate + runway alert."""
    pct = data["session_pct"]
    if not pct and not data["session_resets"]:
        return None

    show = cfg["show"]
    bw = cfg["bar_width"]
    bar = render_bar(pct, bw)
    parts = [f"{tc('S', C_TEXT)} {bar} {tc(f'{pct:.0f}%', pct_color(pct))}"]

    # Reset timer
    if show.get("reset_timer"):
        timer = format_reset(data["session_resets"])
        if timer:
            parts.append(dim(f"↻{timer}"))

    # Burn rate
    rate_val, runway_min = None, None
    if show.get("burn_rate") and hist:
        rate_val, runway_min = burn_rate(hist, "s")
        if rate_val and rate_val > 0:
            parts.append(tc(f"{rate_val:.0f}%/h", C_DIM))

    # Runway alert: only appears when you'll hit the limit before reset
    if show.get("runway_alert") and runway_min is not None and runway_min > 0:
        reset_min = _reset_minutes(data["session_resets"])
        if reset_min > 0:
            if runway_min < reset_min * 0.8:
                # DANGER: will hit limit before reset
                alert = format_runway(runway_min)
                parts.append(tc(f"⚠{alert}", C_HIGH))
            elif runway_min < reset_min * 1.3:
                # WARNING: cutting it close
                alert = format_runway(runway_min)
                parts.append(tc(f"→{alert}", C_MID))

    return " ".join(parts)


def w_weekly(data: dict, cfg: dict, hist: list) -> str | None:
    """Weekly usage: bar + pct + reset timer."""
    pct = data["weekly_pct"]
    if not pct and not data["weekly_resets"]:
        return None

    bw = cfg["bar_width"]
    bar = render_bar(pct, bw)
    parts = [f"{tc('W', C_TEXT)} {bar} {tc(f'{pct:.0f}%', pct_color(pct))}"]

    if cfg["show"].get("reset_timer"):
        timer = format_reset(data["weekly_resets"])
        if timer:
            parts.append(dim(f"↻{timer}"))

    return " ".join(parts)


def w_context(data: dict, cfg: dict, hist: list) -> str | None:
    """Context window: bar + pct + velocity arrows. Always shown."""
    pct = data["ctx_pct"]
    bw = cfg["bar_width"]
    bar = render_bar(pct, bw)
    vel_str = ""

    if cfg["show"].get("context_velocity") and hist:
        arrows = velocity_arrows(ctx_velocity(hist))
        if arrows:
            vel_str = arrows

    return f"{tc('C', C_TEXT)} {bar} {tc(f'{pct:.0f}%{vel_str}', pct_color(pct))}"


def w_cost(data: dict, cfg: dict) -> str | None:
    """Always show cost, even $0.00."""
    cost = data["cost_usd"]
    return tc(format_cost(cost, cfg["currency"]), C_TEXT)


def w_model(data: dict, cfg: dict) -> str | None:
    model = data["model"]
    if not model:
        return None

    display = model.lower()
    for prefix in ("claude ", "claude-"):
        if display.startswith(prefix):
            display = display[len(prefix):]

    parts = [tc(display, C_CYAN)]

    if cfg["show"].get("effort"):
        effort = data.get("effort", "")
        if effort and effort.lower() not in ("", "default"):
            parts.append(tc(effort[0].upper(), C_DIM))

    return " ".join(parts)


def w_git(data: dict, cfg: dict) -> str | None:
    branch_hint = data.get("git_branch", "") or data.get("worktree", "")
    info = git_info(data["cwd"], branch_hint)
    branch = info["branch"]
    if not branch:
        return None

    dirty = info["dirty"]
    if dirty > 0:
        return f"{tc(branch, C_TEXT)}{dim(f'*{dirty}')}"
    return tc(branch, C_TEXT)


def w_lines(data: dict, cfg: dict) -> str | None:
    """Lines added/removed this session. Always shown."""
    added = data.get("lines_added", 0)
    removed = data.get("lines_removed", 0)
    return f"{tc(f'+{added}', C_LOW)} {tc(f'-{removed}', C_HIGH)}"


def w_duration(data: dict, cfg: dict) -> str | None:
    """Session duration."""
    ms = data.get("duration_ms", 0)
    if not ms:
        return None
    secs = ms / 1000
    if secs < 60:
        return dim(f"{secs:.0f}s")
    mins = secs / 60
    if mins < 60:
        return dim(f"{mins:.0f}m")
    hours = int(mins // 60)
    m = int(mins % 60)
    return dim(f"{hours}h{m:02d}m")


def w_peak(data: dict, cfg: dict) -> str | None:
    result = check_peak(cfg)
    if not result:
        return None
    state, mins = result
    if state == "in_peak":
        return tc("⚡Peak", C_PEAK)
    if state == "approaching" and mins is not None:
        return dim(f"⚡{mins:.0f}m")
    return None


def w_harness() -> str | None:
    """Show harness surface: hooks, plugins, skills, agents."""
    settings_path = Path.home() / ".claude" / "settings.json"

    # Cache this — settings.json doesn't change mid-session
    cache_key = "harness"
    cache = read_json(GIT_CACHE_FILE)  # reuse git cache file for simplicity
    if cache and cache.get(cache_key) and time.time() - cache.get("ht", 0) < 300:
        h, p = cache[cache_key]
    else:
        try:
            s = json.loads(settings_path.read_text())
            h = sum(len(e.get("hooks", [])) for entries in s.get("hooks", {}).values() for e in entries)
            p = sum(1 for v in s.get("enabledPlugins", {}).values() if v)
        except Exception:
            h, p = 0, 0
        # Write to cache
        c = cache if cache else {}
        c[cache_key] = [h, p]
        c["ht"] = time.time()
        write_json(GIT_CACHE_FILE, c)

    parts = []
    if h:
        parts.append(f"{h}H")
    if p:
        parts.append(f"{p}P")
    parts.append("11A")   # agents are built-in, count is stable
    parts.append("18S")   # skills are built-in, count is stable

    return dim(" ".join(parts))


def w_telemetry(data: dict, cfg: dict) -> str | None:
    """Live tool counter from PostToolUse hook. Always shown."""
    telem = read_json(TELEMETRY_FILE)
    count = telem.get("tool_count", 0) if telem else 0

    if count == 0:
        return dim("⚡0 tools")

    elapsed_min = (time.time() - telem.get("session_start", time.time())) / 60

    if elapsed_min > 1 and count > 5:
        vel = count / elapsed_min
        return tc(f"⚡{count} tools", C_PEAK) + " " + dim(f"{vel:.0f}/m")

    return tc(f"⚡{count} tools", C_PEAK)


# ─── Session State (tracks peaks across renders) ────────────────────────────────

def update_session_state(data: dict) -> None:
    """Update running session state on every render. The Stop hook reads this."""
    state = read_json(SESSION_STATE_FILE) or {}

    now = time.time()
    if "start_ts" not in state:
        state["start_ts"] = now

    state["last_ts"] = now
    state["cost"] = data.get("cost_usd", 0)
    state["lines_added"] = data.get("lines_added", 0)
    state["lines_removed"] = data.get("lines_removed", 0)
    state["model"] = data.get("model", "")
    state["ctx_peak"] = max(state.get("ctx_peak", 0), data.get("ctx_pct", 0))

    cwd = data.get("cwd", "")
    if cwd:
        state["repo"] = os.path.basename(cwd)

    write_json(SESSION_STATE_FILE, state)


# ─── Layout ──────────────────────────────────────────────────────────────────────

def terminal_width() -> int:
    for fd in (sys.stderr.fileno(), sys.stdout.fileno(), sys.stdin.fileno()):
        try:
            return os.get_terminal_size(fd).columns
        except Exception:
            continue
    try:
        return int(os.environ.get("COLUMNS", "120"))
    except Exception:
        return 120


def render(data: dict, cfg: dict, hist: list) -> str:
    """Assemble the status line. Responsive: drops low-priority widgets to fit."""
    # If no meaningful data arrived, show fallback
    if not data.get("model") and not data.get("session_pct") and not data.get("ctx_pct"):
        return tc("Claude", C_TEXT)

    show = cfg["show"]

    # Build widgets in priority order (most important first)
    widget_specs = [
        ("session",  lambda: w_session(data, cfg, hist)),
        ("weekly",   lambda: w_weekly(data, cfg, hist)),
        ("context",  lambda: w_context(data, cfg, hist)),
        ("cost",     lambda: w_cost(data, cfg)),
        ("model",    lambda: w_model(data, cfg)),
        ("lines",     lambda: w_lines(data, cfg)),
        ("telemetry", lambda: w_telemetry(data, cfg)),
        ("duration",  lambda: w_duration(data, cfg)),
        ("peak",      lambda: w_peak(data, cfg)),
        ("harness",   lambda: w_harness()),
        ("git",       lambda: w_git(data, cfg)),
    ]
    widgets = []
    for name, builder in widget_specs:
        if show.get(name):
            w = builder()
            if w:
                widgets.append(w)

    if not widgets:
        return tc("Claude", C_TEXT)

    sep = _sep()
    sep_vlen = 3
    tw = terminal_width() - 2

    # Try full set, then progressively drop from the tail
    for drop in range(len(widgets)):
        active = widgets[: len(widgets) - drop] if drop else widgets
        line = sep.join(active)
        if visible_len(line) <= tw:
            return line

    return widgets[0]


# ─── CLI ─────────────────────────────────────────────────────────────────────────

def cli_install() -> None:
    script = str(Path(__file__).resolve())
    python = sys.executable
    cmd = f'{python} "{script}"'

    settings_path = Path.home() / ".claude" / "settings.json"
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text())
        except Exception:
            print(f"Error: {settings_path} contains invalid JSON. Fix it manually first.")
            sys.exit(1)
    else:
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        settings = {}

    settings["statusLine"] = {"type": "command", "command": cmd}
    tmp = settings_path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(settings, indent=2) + "\n")
    tmp.replace(settings_path)

    print(f"{BOLD}Installed.{RST}")
    print(f"  Python:   {python}")
    print(f"  Script:   {script}")
    print(f"  Settings: {settings_path}")
    print("\nRestart Claude Code to activate.")


def cli_config() -> None:
    cfg = load_config()
    bar = render_bar(65, cfg["bar_width"])
    ph = cfg.get("peak_hours", {})
    peak = f"{ph.get('start', '13:00')}-{ph.get('end', '19:00')}" if ph.get("enabled") else "off"

    print(f"{BOLD}claude-statusline v{VERSION}{RST}\n")
    print(f"  Palette:    {render_bar(20, 4)} {render_bar(50, 4)} {render_bar(80, 4)}")
    print(f"  Currency:   {cfg.get('currency', '$')}")
    print(f"  Bar width:  {cfg.get('bar_width', 10)}")
    print(f"  Peak hours: {peak}")
    print(f"\n  {BOLD}Widgets:{RST}")
    for key, val in cfg.get("show", {}).items():
        s = "\033[32mon\033[0m" if val else "\033[31moff\033[0m"
        print(f"    {key:<20} {s}")


def cli_currency(symbol: str) -> None:
    cfg = load_config()
    cfg["currency"] = symbol
    save_config(cfg)
    print(f"Currency: {BOLD}{symbol}{RST}")
    code = SYMBOL_TO_CODE.get(symbol)
    if code:
        rate = _fx_rate(code)
        print(f"  $1 USD = {symbol}{rate:.2f} {code}")


def cli_bar_width(val: str) -> None:
    sizes = {"small": 6, "medium": 8, "large": 10, "xl": 14}
    try:
        w = int(val)
    except ValueError:
        w = sizes.get(val.lower())
        if w is None:
            print(f"Use a number (4-20) or: {', '.join(sizes)}")
            sys.exit(1)
    if not 4 <= w <= 20:
        print("Bar width must be 4-20")
        sys.exit(1)

    cfg = load_config()
    cfg["bar_width"] = w
    save_config(cfg)
    print(f"Bar width: {BOLD}{w}{RST}  {render_bar(65, w)}")


def cli_toggle(action: str, widget: str) -> None:
    cfg = load_config()
    valid = set(DEFAULT_CONFIG["show"])
    if widget not in valid:
        print(f"Unknown widget: {widget}\nAvailable: {', '.join(sorted(valid))}")
        sys.exit(1)
    cfg["show"][widget] = action == "show"
    save_config(cfg)
    print(f"Widget '{widget}' {'shown' if action == 'show' else 'hidden'}")


def cli_peak(val: str) -> None:
    cfg = load_config()
    if val.lower() == "off":
        cfg["peak_hours"]["enabled"] = False
    elif val.lower() == "on":
        cfg["peak_hours"]["enabled"] = True
    elif "-" in val:
        parts = val.split("-", 1)
        cfg["peak_hours"] = {"enabled": True, "start": parts[0].strip(), "end": parts[1].strip()}
    else:
        print("Usage: --peak-hours <HH:MM-HH:MM | on | off>")
        sys.exit(1)
    save_config(cfg)
    ph = cfg["peak_hours"]
    print(f"Peak hours: {BOLD}{ph['start']}-{ph['end']}{RST}" if ph["enabled"] else "Peak hours: off")


def cli_demo() -> None:
    """Show a demo of the status line at different usage levels."""
    bw = load_config()["bar_width"]
    print(f"{BOLD}claude-statusline v{VERSION}{RST}\n")
    for pct in (15, 35, 55, 75, 90, 100):
        bar = render_bar(pct, bw)
        print(f"  {pct:>3}%  {bar}")
    print(f"\n  {BOLD}Max plan:{RST}")
    print(f"  {tc('S', C_TEXT)} {render_bar(67, bw)} {tc('67%', pct_color(67))} "
          f"{dim('↻1h08m')} {tc('12%/h', C_DIM)}"
          f"{_sep()}{tc('W', C_TEXT)} {render_bar(89, bw)} {tc('89%', pct_color(89))} "
          f"{dim('↻Mon 5pm')}"
          f"{_sep()}{tc('C', C_TEXT)} {render_bar(45, bw)} {tc('45%↑', pct_color(45))}"
          f"{_sep()}{tc('$2.71', C_TEXT)}"
          f"{_sep()}{tc('opus-4.6', C_CYAN)} {tc('H', C_DIM)}"
          f"{_sep()}{tc('+156', C_LOW)} {tc('-23', C_HIGH)}"
          f"{_sep()}{tc('⚡Peak', C_PEAK)}"
          f"{_sep()}{tc('main', C_TEXT)}{dim('*2')}")
    print(f"\n  {BOLD}Enterprise:{RST}")
    print(f"  {tc('C', C_TEXT)} {render_bar(14, bw)} {tc('14%', pct_color(14))}"
          f"{_sep()}{tc('$14.30', C_TEXT)}"
          f"{_sep()}{tc('opus 4.6 (1m context)', C_CYAN)}"
          f"{_sep()}{tc('+987', C_LOW)} {tc('-226', C_HIGH)}"
          f"{_sep()}{dim('42m')}"
          f"{_sep()}{tc('⚡Peak', C_PEAK)}"
          f"{_sep()}{tc('main', C_TEXT)}{dim('*5')}")


def cli_status() -> None:
    """Full system dashboard: config, hooks, plugins, agents, skills, journal."""
    cfg = load_config()
    settings_path = Path.home() / ".claude" / "settings.json"

    print(f"\n{BOLD}claude-statusline v{VERSION} — system status{RST}\n")

    # ── Statusline ──
    print(f"  {BOLD}Statusline{RST}")
    print(f"    Palette:    {render_bar(20, 4)} {render_bar(50, 4)} {render_bar(80, 4)}")
    print(f"    Currency:   {cfg.get('currency', '$')}")
    print(f"    Bar width:  {cfg.get('bar_width', 10)}")
    ph = cfg.get("peak_hours", {})
    print(f"    Peak hours: {ph.get('start', '13:00')}-{ph.get('end', '19:00')}" if ph.get("enabled") else "    Peak hours: off")

    # ── Hooks ──
    try:
        settings = json.loads(settings_path.read_text())
    except Exception:
        settings = {}

    hooks = settings.get("hooks", {})
    print(f"\n  {BOLD}Hooks{RST} ({len(hooks)} events)")
    for event, entries in hooks.items():
        count = sum(len(e.get("hooks", [])) for e in entries)
        has_sl = any("statusline" in str(h) for e in entries for h in e.get("hooks", []))
        marker = f" {tc('◀ statusline', C_CYAN)}" if has_sl else ""
        print(f"    {event:<20} {count} hook{'s' if count != 1 else ''}{marker}")

    # ── Plugins ──
    plugins = settings.get("enabledPlugins", {})
    active = [k.split("@")[0] for k, v in plugins.items() if v]
    print(f"\n  {BOLD}Plugins{RST} ({len(active)} active)")
    for p in active:
        print(f"    {tc(p, C_TEXT)}")

    # ── MCP Servers ──
    mcp = settings.get("mcpServers", {})
    if mcp:
        print(f"\n  {BOLD}MCP Servers{RST} ({len(mcp)})")
        for name in sorted(mcp.keys()):
            print(f"    {tc(name, C_TEXT)}")

    # ── Agents (built-in) ──
    agents = [
        ("Explore", "Fast codebase exploration"),
        ("Plan", "Architecture and implementation planning"),
        ("research-synthesizer", "Multi-source research synthesis"),
        ("dd-analyst", "Due diligence on companies/markets"),
        ("security-reviewer", "Code security audits"),
        ("code-auditor", "Deep code review, trace execution paths"),
        ("eval-runner", "Design and run LLM evaluations"),
        ("team-orchestrator", "Multi-agent team coordination"),
        ("writing-editor", "Sharpen memos, theses, documents"),
        ("code-simplifier", "Simplify and refine code"),
        ("claude-code-guide", "Questions about Claude Code"),
    ]
    print(f"\n  {BOLD}Agents{RST} ({len(agents)} types)")
    for name, desc in agents:
        print(f"    {tc(name, C_CYAN):<38} {dim(desc)}")

    # ── Skills ──
    skills = [
        ("/pulse", "Configure status bar"),
        ("/reason", "Deep reasoning via Codex"),
        ("/plan", "Implementation plan via Codex"),
        ("/spec", "Technical spec via Codex"),
        ("/codex", "Custom Codex task"),
        ("/simplify", "Review code for quality"),
        ("/loop", "Recurring interval commands"),
        ("/schedule", "Cron-scheduled remote agents"),
        ("/claude-api", "Build with Anthropic SDK"),
        ("/llm-evals", "Build LLM evaluations"),
        ("/optimize-anything", "Iterative GEPA optimization"),
        ("/deep-dd", "Due diligence and company evaluation"),
        ("/research-synthesis", "Deep research and synthesis"),
        ("/memo-writer", "Investment memos and analysis"),
        ("/codebase-onboard", "Explore and understand codebases"),
        ("/claude-md-management:revise-claude-md", "Update CLAUDE.md"),
        ("/claude-md-management:claude-md-improver", "Audit CLAUDE.md files"),
        ("/ralph-loop:ralph-loop", "Start Ralph Loop"),
    ]
    print(f"\n  {BOLD}Skills{RST} ({len(skills)} available)")
    for name, desc in skills:
        print(f"    {tc(name, C_PEAK):<45} {dim(desc)}")

    # ── Journal ──
    print(f"\n  {BOLD}Journal{RST}")
    if JOURNAL_FILE.exists():
        lines = [l for l in JOURNAL_FILE.read_text().strip().split("\n") if l.strip()]
        total_cost = 0
        total_lines = 0
        total_tools = 0
        for line in lines:
            try:
                e = json.loads(line)
                total_cost += e.get("cost", 0)
                total_lines += e.get("lines_added", 0)
                total_tools += e.get("tools", 0)
            except Exception:
                continue
        print(f"    {len(lines)} sessions recorded")
        print(f"    ${total_cost:.2f} total cost   +{total_lines} lines   {total_tools} tools")
    else:
        print(f"    No data yet. Run {BOLD}--install-hooks{RST} to start recording.")

    # ── Telemetry ──
    telem = read_json(TELEMETRY_FILE)
    if telem and telem.get("tool_count"):
        elapsed = (time.time() - telem.get("session_start", time.time())) / 60
        print(f"\n  {BOLD}Current session{RST}")
        print(f"    {telem['tool_count']} tools   {elapsed:.0f}m elapsed   last: {telem.get('last_tool', '?')}")

    print()


def usage() -> None:
    print(f"""{BOLD}claude-statusline v{VERSION}{RST} — glanceable intelligence for your terminal

{BOLD}Setup:{RST}
  statusline.py --install          Add to Claude Code settings
  statusline.py --demo             Preview the status bar

{BOLD}Configure:{RST}
  statusline.py --config           Show current settings
  statusline.py --currency <sym>   Set currency ($, £, €, ¥, ₹, kr, etc.)
  statusline.py --bar-width <n>    4-20 or small/medium/large/xl
  statusline.py --show <widget>    Enable a widget
  statusline.py --hide <widget>    Disable a widget
  statusline.py --peak-hours <v>   HH:MM-HH:MM | on | off
  statusline.py --reset            Factory reset

{BOLD}Analytics:{RST}
  statusline.py --stats            Session analytics (cost, lines, repos)
  statusline.py --install-hooks    Install Stop + PostToolUse hooks

{BOLD}Widgets:{RST}
  session, weekly, context, cost, model, git, effort, lines,
  telemetry, duration, peak, burn_rate, runway_alert, context_velocity""")


# ─── Act 1: Session Journal ─────────────────────────────────────────────────────

def cli_hook_stop() -> None:
    """Called by Stop hook. Records session summary to journal."""
    # Read latest data from Stop hook stdin
    stop_cost = stop_lines_add = stop_lines_rem = stop_duration = 0
    try:
        raw = sys.stdin.read()
        if raw.strip():
            hook_data = json.loads(raw)
            stop_cost = _get(hook_data, "cost.total_cost_usd", 0) or 0
            stop_lines_add = _get(hook_data, "cost.total_lines_added", 0) or 0
            stop_lines_rem = _get(hook_data, "cost.total_lines_removed", 0) or 0
            stop_duration = _get(hook_data, "cost.total_duration_ms", 0) or 0
    except Exception:
        pass

    state = read_json(SESSION_STATE_FILE) or {}
    telem = read_json(TELEMETRY_FILE) or {}

    # Merge: prefer hook data (freshest) over cached state
    cost = stop_cost or state.get("cost", 0)
    lines_added = stop_lines_add or state.get("lines_added", 0)
    lines_removed = stop_lines_rem or state.get("lines_removed", 0)
    duration_s = (stop_duration / 1000) if stop_duration else (
        state.get("last_ts", time.time()) - state.get("start_ts", time.time())
    )

    # Skip empty sessions
    if cost == 0 and lines_added == 0 and telem.get("tool_count", 0) == 0:
        for f in (SESSION_STATE_FILE, TELEMETRY_FILE):
            try:
                f.unlink(missing_ok=True)
            except Exception:
                pass
        return

    start_ts = state.get("start_ts", time.time())
    entry = {
        "ts": start_ts,
        "date": datetime.fromtimestamp(start_ts).strftime("%Y-%m-%d"),
        "repo": state.get("repo", "unknown"),
        "model": state.get("model", ""),
        "cost": round(cost, 4),
        "lines_added": lines_added,
        "lines_removed": lines_removed,
        "duration_s": round(duration_s),
        "ctx_peak": round(state.get("ctx_peak", 0), 1),
        "tools": telem.get("tool_count", 0),
    }

    _ensure_cache()
    with open(JOURNAL_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")

    # Clear session state
    for f in (SESSION_STATE_FILE, TELEMETRY_FILE):
        try:
            f.unlink(missing_ok=True)
        except Exception:
            pass


# ─── Act 3: Live Telemetry ──────────────────────────────────────────────────────

def cli_hook_tool() -> None:
    """Called by PostToolUse hook. Increments tool counter."""
    telem = read_json(TELEMETRY_FILE) or {}

    now = time.time()
    if "session_start" not in telem:
        telem["session_start"] = now

    telem["tool_count"] = telem.get("tool_count", 0) + 1
    telem["last_tool_ts"] = now

    # Try to read tool name from hook stdin
    try:
        raw = sys.stdin.read()
        if raw.strip():
            hook_data = json.loads(raw)
            tool_name = (
                hook_data.get("tool_name", "")
                or _get(hook_data, "tool.name", "")
                or ""
            )
            if tool_name:
                telem["last_tool"] = tool_name[:20]
    except Exception:
        pass

    write_json(TELEMETRY_FILE, telem)


# ─── Act 2: Analytics ───────────────────────────────────────────────────────────

def cli_stats() -> None:
    """Show session analytics from the journal."""
    if not JOURNAL_FILE.exists():
        print("No session data yet. Install hooks first:")
        print(f"  {sys.executable} {Path(__file__).resolve()} --install-hooks")
        return

    entries = []
    for line in JOURNAL_FILE.read_text().strip().split("\n"):
        if line.strip():
            try:
                entries.append(json.loads(line))
            except Exception:
                continue

    if not entries:
        print("No session data yet.")
        return

    now = datetime.now()
    today_str = now.strftime("%Y-%m-%d")
    week_ago = (now - timedelta(days=7)).strftime("%Y-%m-%d")

    def _sum(items):
        return {
            "n": len(items),
            "cost": sum(e.get("cost", 0) for e in items),
            "lines": sum(e.get("lines_added", 0) for e in items),
            "lines_rm": sum(e.get("lines_removed", 0) for e in items),
            "hours": sum(e.get("duration_s", 0) for e in items) / 3600,
            "tools": sum(e.get("tools", 0) for e in items),
        }

    s_today = _sum([e for e in entries if e.get("date") == today_str])
    s_week = _sum([e for e in entries if e.get("date", "") >= week_ago])
    s_all = _sum(entries)

    def _lines(n):
        return f"+{n / 1000:.1f}K" if n >= 1000 else f"+{n}"

    def _hrs(h):
        return f"{h:.1f}h" if h >= 1 else f"{h * 60:.0f}m"

    def _cost(c):
        return f"${c:,.0f}" if c >= 1000 else f"${c:.2f}"

    print(f"\n{BOLD}claude-statusline — session analytics{RST}\n")

    for label, s in [("Today", s_today), ("This week", s_week), ("All time", s_all)]:
        if s["n"] == 0:
            continue
        print(
            f"  {tc(label, C_TEXT):<28} "
            f"{s['n']:>3} sessions   "
            f"{_cost(s['cost']):>8}   "
            f"{_lines(s['lines']):>8} lines   "
            f"{_hrs(s['hours']):>6}   "
            f"{s['tools']:>5} tools"
        )

    # Cost by repo
    repos = {}
    for e in entries:
        repo = e.get("repo", "unknown")
        r = repos.setdefault(repo, {"n": 0, "cost": 0, "lines": 0, "tools": 0})
        r["n"] += 1
        r["cost"] += e.get("cost", 0)
        r["lines"] += e.get("lines_added", 0)
        r["tools"] += e.get("tools", 0)

    sorted_repos = sorted(repos.items(), key=lambda x: x[1]["cost"], reverse=True)
    max_cost = sorted_repos[0][1]["cost"] if sorted_repos else 1

    if sorted_repos:
        print(f"\n  {BOLD}Cost by repo{RST}")
        for repo, d in sorted_repos[:10]:
            pct = d["cost"] / max_cost * 100 if max_cost > 0 else 0
            bar = render_bar(pct, 20)
            print(
                f"    {repo:<18} {bar}  "
                f"{d['n']:>3} sessions  "
                f"{_cost(d['cost']):>8}  "
                f"{_lines(d['lines']):>8}  "
                f"{d['tools']:>5} tools"
            )

    # Efficiency metrics
    print()
    parts = []
    if s_all["lines"] > 0 and s_all["cost"] > 0:
        parts.append(f"Cost/line: ${s_all['cost'] / s_all['lines']:.3f}")
    if s_all["n"] > 0:
        avg_min = s_all["hours"] * 60 / s_all["n"]
        parts.append(f"Avg session: {avg_min:.0f}m")
    if s_all["tools"] > 0 and s_all["n"] > 0:
        parts.append(f"Avg tools: {s_all['tools'] // s_all['n']}/session")
    if s_all["lines"] > 0 and s_all["tools"] > 0:
        parts.append(f"Tools/line: {s_all['tools'] / s_all['lines']:.2f}")
    if parts:
        print(f"  {dim(' │ '.join(parts))}")
    print()


def cli_install_hooks() -> None:
    """Install Stop + PostToolUse hooks into Claude Code settings."""
    script = str(Path(__file__).resolve())
    python = sys.executable

    settings_path = Path.home() / ".claude" / "settings.json"
    try:
        settings = json.loads(settings_path.read_text())
    except Exception:
        print(f"Error: Cannot read {settings_path}")
        sys.exit(1)

    hooks = settings.setdefault("hooks", {})

    stop_cmd = f'{python} "{script}" --hook-stop'
    tool_cmd = f'{python} "{script}" --hook-tool'

    def _has_cmd(hook_list, cmd):
        return any(
            cmd in str(h.get("command", ""))
            for entry in hook_list
            for h in entry.get("hooks", [])
        )

    # Stop hook → session journal
    stop_list = hooks.setdefault("Stop", [])
    if not _has_cmd(stop_list, "statusline"):
        stop_list.append({"hooks": [{"type": "command", "command": stop_cmd}]})

    # PostToolUse hook → telemetry
    tool_list = hooks.setdefault("PostToolUse", [])
    if not _has_cmd(tool_list, "statusline"):
        tool_list.append({"hooks": [{"type": "command", "command": tool_cmd}]})

    tmp = settings_path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(settings, indent=2) + "\n")
    tmp.replace(settings_path)

    print(f"{BOLD}Hooks installed.{RST}")
    print("  Stop hook:        → session journal (records every session)")
    print("  PostToolUse hook: → live telemetry (⚡tool counter in status bar)")
    print("\nRestart Claude Code to activate.")


# ─── Main ────────────────────────────────────────────────────────────────────────

def main() -> None:
    args = sys.argv[1:]

    if args:
        cmd = args[0]
        arg = args[1] if len(args) > 1 else None
        dispatch = {
            "--help": lambda: usage(),
            "-h": lambda: usage(),
            "--version": lambda: print(f"claude-statusline v{VERSION}"),
            "--install": lambda: cli_install(),
            "--install-hooks": lambda: cli_install_hooks(),
            "--config": lambda: cli_config(),
            "--demo": lambda: cli_demo(),
            "--status": lambda: cli_status(),
            "--stats": lambda: cli_stats(),
            "--hook-stop": lambda: cli_hook_stop(),
            "--hook-tool": lambda: cli_hook_tool(),
            "--reset": lambda: (save_config(json.loads(json.dumps(DEFAULT_CONFIG))),
                                print("Reset to defaults.")),
        }
        if cmd in dispatch:
            dispatch[cmd]()
            return
        if cmd == "--currency" and arg:
            cli_currency(arg)
            return
        if cmd == "--bar-width" and arg:
            cli_bar_width(arg)
            return
        if cmd in ("--show", "--hide") and arg:
            cli_toggle(cmd[2:], arg)
            return
        if cmd == "--peak-hours" and arg:
            cli_peak(arg)
            return

        print(f"Unknown: {cmd}")
        usage()
        sys.exit(1)

    # ── Normal operation: render status line ─────────────────────────────────
    try:
        cfg = load_config()
        data = parse_stdin()

        # Debug: save raw stdin for diagnosis
        if os.environ.get("STATUSLINE_DEBUG"):
            _ensure_cache()
            (CACHE_DIR / "debug_stdin.json").write_text(
                json.dumps(data, indent=2, default=str)
            )

        if not data:
            print(tc("Claude", C_TEXT))
            return

        # Yield when context <= 20% remaining — Claude Code's built-in bar takes over
        ctx_rem = data.get("ctx_remaining")
        if ctx_rem is not None and ctx_rem <= 20:
            return

        hist = load_history()
        hist = record_history(hist, data["session_pct"], data["weekly_pct"], data["ctx_pct"])

        # Track session state for the journal
        update_session_state(data)

        print(render(data, cfg, hist))
    except Exception:
        print("Claude")


if __name__ == "__main__":
    main()
