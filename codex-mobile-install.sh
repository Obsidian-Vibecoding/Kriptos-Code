#!/data/data/com.termux/files/usr/bin/bash
# ══════════════════════════════════════════════════════════════
#  CODEX MOBILE · instalador para Termux
#  Uso:  bash codex-mobile-install.sh
# ══════════════════════════════════════════════════════════════
set -e
C1=$'\e[38;2;122;162;247m'; C2=$'\e[38;2;158;206;106m'; C3=$'\e[38;2;224;175;104m'; R=$'\e[0m'
say() { echo -e "${C1}◆${R} $*"; }

if ! command -v pkg >/dev/null 2>&1; then
    echo "Este instalador requiere Termux (comando pkg no disponible)." >&2
    exit 69
fi

say "Instalando dependencias (python, git, tmux, termux-api)…"
pkg install -y python git >/dev/null 2>&1
pkg install -y tmux termux-api >/dev/null 2>&1 || true

say "Instalando librerías de interfaz (rich, prompt_toolkit)…"
if ! python -c 'import rich, prompt_toolkit' >/dev/null 2>&1; then
    python -m pip install --quiet rich prompt_toolkit
fi

if [ ! -d "$HOME/storage/shared" ]; then
  say "Pidiendo acceso al almacenamiento interno (acepta el permiso)…"
  termux-setup-storage || true
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -d "$HOME/storage/shared" ] && break; sleep 1; done
fi

say "Escribiendo Codex Mobile…"
mkdir -p "$HOME/.codex-mobile"
cat > "$HOME/.codex-mobile/codex_mobile.py" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CODEX MOBILE  ·  agente de código multi-modelo para Termux
- Arquitecto (planifica y ordena) + Obrero (ejecuta) + Rápido (consultas fáciles)
- Sesiones independientes en almacenamiento interno, cada una con su configuración
"""
import os, sys, re, json, time, shutil, signal, subprocess, unicodedata, socket, uuid
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from html import unescape

try:
    from rich.console import Console
    from rich.panel import Panel
    from rich.markdown import Markdown
    from rich.table import Table
    from rich.text import Text
    from rich.syntax import Syntax
    from rich.rule import Rule
    from rich.tree import Tree
    from rich.align import Align
    from rich.padding import Padding
    from rich.markup import escape
    from rich.box import ROUNDED
    from rich.theme import Theme
    from prompt_toolkit import PromptSession
    from prompt_toolkit.history import FileHistory
    from prompt_toolkit.completion import Completer, Completion
    from prompt_toolkit.styles import Style as PTStyle
except ImportError:
    print("Faltan dependencias. Ejecuta: pip install rich prompt_toolkit")
    sys.exit(78)

VERSION = "1.2"
UA = "CodexMobile/1.2 (Termux)"
HOME = Path.home()
CFG_DIR = HOME / ".codex-mobile"
CFG_FILE = CFG_DIR / "config.json"

THEME = Theme({
    "accent": "#7aa2f7", "ok": "#9ece6a", "warn": "#e0af68", "err": "#f7768e",
    "muted": "#6b7399", "plan": "#bb9af7", "work": "#7dcfff", "fast": "#ff9e64",
    "title": "bold #c0caf5",
    "bold accent": "bold #7aa2f7", "bold ok": "bold #9ece6a", "bold warn": "bold #e0af68",
    "bold err": "bold #f7768e", "bold plan": "bold #bb9af7", "bold work": "bold #7dcfff",
    "bold fast": "bold #ff9e64", "muted italic": "italic #6b7399",
})
console = Console(theme=THEME, highlight=False)

# ───────────────────────── Proveedores y catálogo ─────────────────────────
# free = etiqueta si el proveedor tiene capa gratuita (None = de pago)
PROVIDERS = {
    "gemini":     dict(name="Google Gemini", kind="openai",
                       url="https://generativelanguage.googleapis.com/v1beta/openai",
                       hint="aistudio.google.com/apikey", free="gratis"),
    "groq":       dict(name="Groq", kind="openai", url="https://api.groq.com/openai/v1",
                       hint="console.groq.com/keys", free="gratis"),
    "openrouter": dict(name="OpenRouter", kind="openai", url="https://openrouter.ai/api/v1",
                       hint="openrouter.ai/keys  (1 key = muchos modelos :free)", free="modelos :free"),
    "nvidia":     dict(name="NVIDIA NIM", kind="openai", url="https://integrate.api.nvidia.com/v1",
                       hint="build.nvidia.com  (Nemotron, Kimi, MiniMax…)", free="gratis"),
    "mistral":    dict(name="Mistral", kind="openai", url="https://api.mistral.ai/v1",
                       hint="console.mistral.ai  (plan Experiment, ~1B tokens/mes)", free="gratis"),
    "ollama":     dict(name="Ollama Cloud", kind="openai", url="https://ollama.com/v1",
                       hint="ollama.com/settings/keys  (plan Free)", free="gratis"),
    "cohere":     dict(name="Cohere", kind="openai", url="https://api.cohere.ai/compatibility/v1",
                       hint="dashboard.cohere.com/api-keys  (key Trial)", free="key Trial"),
}

# (proveedor, modelo, puntaje_planificar, puntaje_programar, puntaje_velocidad)
# SOLO proveedores con plan gratis permanente. Esta lista es la base conocida: al iniciar, Codex Mobile
# pide a cada proveedor su lista real de /models, añade los modelos NUEVOS y oculta los que ya no existan.
CATALOG = [
    ("gemini", "gemini-3.8-flash",       9, 9, 7),
    ("gemini", "gemini-3.7-flash",       8, 8, 7),
    ("gemini", "gemini-3.6-flash",       8, 8, 7),
    ("gemini", "gemini-3.5-flash",       7, 8, 8),
    ("gemini", "gemini-3.5-flash-lite",  5, 6, 9),
    ("gemini", "gemini-3.1-flash-lite",  5, 6, 9),
    ("groq", "openai/gpt-oss-120b",      7, 8, 9),
    ("groq", "qwen/qwen3.6-27b",         7, 8, 8),
    ("groq", "openai/gpt-oss-20b",       5, 6, 10),
    ("nvidia", "nvidia/nemotron-3-ultra-550b-a55b", 9, 8, 3),
    ("nvidia", "nvidia/nemotron-3-super-120b-a12b", 8, 8, 5),
    ("nvidia", "nvidia/nemotron-3.5-lightning",     6, 7, 9),
    ("nvidia", "moonshotai/kimi-k2.5",              8, 9, 4),
    ("nvidia", "minimaxai/minimax-m2.5",            8, 9, 4),
    ("mistral", "mistral-medium-3-5",    8, 8, 6),
    ("mistral", "mistral-medium-latest", 8, 8, 6),
    ("mistral", "mistral-large-2512",    8, 8, 4),
    ("mistral", "mistral-small-2603",    5, 6, 8),
    ("mistral", "codestral-2508",        5, 8, 8),
    ("mistral", "codestral-latest",      5, 8, 8),
    ("ollama", "gpt-oss:120b",           7, 8, 6),
    ("openrouter", "nvidia/nemotron-3-ultra-550b-a55b:free", 9, 8, 3),
    ("openrouter", "nvidia/nemotron-3-super-120b-a12b:free", 8, 8, 5),
    ("openrouter", "cohere/north-mini-code:free",            6, 9, 7),
    ("openrouter", "nvidia/nemotron-3.5-lightning:free",     6, 7, 9),
    ("openrouter", "inclusionai/ling-3.1-flash",             7, 8, 8),
    ("openrouter", "openrouter/free",                        6, 6, 6),
    ("cohere", "command-a-03-2025",      6, 6, 5),
]
ROLE_IDX = {"plan": 2, "code": 3, "fast": 4}
ROLE_NAME = {"plan": "Arquitecto", "code": "Obrero", "fast": "Rápido"}
ROLE_STYLE = {"plan": "plan", "code": "work", "fast": "fast"}


class APIError(Exception):
    def __init__(self, msg, code=None):
        super().__init__(msg)
        self.code = code


class ToolError(Exception):
    pass


# ───────────────────────── Utilidades ─────────────────────────
def human(n):
    n = float(n)
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}TB"


def clip(text, n=6000):
    if len(text) <= n:
        return text
    return text[:1500] + f"\n…[recortadas {len(text) - n} caracteres]…\n" + text[-(n - 1500):]


def mask(k):
    return k[:4] + "…" + k[-4:] if len(k) > 10 else "••••"


def short(ref):
    if not ref or ref == "auto":
        return "auto"
    m = ref.split(":", 1)[-1].split("/")[-1]
    return m if len(m) <= 22 else m[:21] + "…"


def slugify(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()[:40]
    return s or "sesion"


def storage_root():
    for base in (HOME / "storage" / "shared", Path("/storage/emulated/0"), Path("/sdcard")):
        try:
            if base.exists() and os.access(str(base), os.W_OK):
                root = base / "CodexMobile"
                root.mkdir(parents=True, exist_ok=True)
                return root
        except Exception:
            pass
    root = HOME / "CodexMobile"
    root.mkdir(parents=True, exist_ok=True)
    return root


def http_json(url, headers, payload=None, timeout=300, method="POST"):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        detail = e.read(500).decode("utf-8", "replace")
        raise APIError(f"HTTP {e.code}: {detail or e.reason}", e.code)
    except (TimeoutError, urllib.error.URLError, OSError) as e:
        raise APIError(f"error de red: {e}", -1)


# ───────────────────────── Configuración global ─────────────────────────
def load_cfg():
    try:
        cfg = json.loads(CFG_FILE.read_text())
    except Exception:
        cfg = {}
    cfg.setdefault("keys", {})
    cfg.setdefault("skip", [])
    cfg.setdefault("custom", {})
    return cfg


def save_cfg(cfg):
    CFG_DIR.mkdir(parents=True, exist_ok=True)
    CFG_FILE.write_text(json.dumps(cfg, indent=2))
    try:
        os.chmod(CFG_FILE, 0o600)
    except Exception:
        pass


# ───────────────────────── Modelos: ranking y llamadas ─────────────────────────
CAT = list(CATALOG)       # catálogo vivo (base + modelos descubiertos)
BAD = {}                  # ref o "@proveedor" -> hasta cuándo se evita (epoch)
FOREVER = float("inf")


def apply_custom(cfg):
    for cid, c in cfg.get("custom", {}).items():
        PROVIDERS[cid] = dict(name=c["name"], kind="openai", url=c["url"],
                              hint="proveedor personalizado", free="personalizado")


def is_free(pid):
    return bool(PROVIDERS.get(pid, {}).get("free"))


def has_any(cfg):
    return any(cfg["keys"].get(p) for p in PROVIDERS)


def usable(cfg):
    return [p for p in PROVIDERS if cfg["keys"].get(p)]


def ranked(cfg, role):
    i = ROLE_IDX[role]
    av = usable(cfg)
    items = [c for c in CAT if c[0] in av]
    items.sort(key=lambda c: (-c[i], c[0] == "openrouter"))
    return [f"{c[0]}:{c[1]}" for c in items]


def is_bad(ref):
    now = time.time()
    prov = ref.split(":", 1)[0]
    return BAD.get(ref, 0) > now or BAD.get("@" + prov, 0) > now


def penalize(ref, code):
    prov = ref.split(":", 1)[0]
    now = time.time()
    if code == 401:
        BAD["@" + prov] = FOREVER
    elif code in (402, 403, 404):
        BAD[ref] = FOREVER
    elif code == 429:
        BAD[ref] = now + 90
    else:
        BAD[ref] = now + 300


def chain(cfg, sess, role):
    out = []
    m = sess["models"].get(role, "auto")
    if m != "auto" and ":" in m and m.split(":", 1)[0] in PROVIDERS and cfg["keys"].get(m.split(":", 1)[0]):
        out.append(m)
    per = {}
    for r in ranked(cfg, role):
        if r in out:
            continue
        p = r.split(":", 1)[0]
        if per.get(p, 0) >= 3:
            continue
        per[p] = per.get(p, 0) + 1
        out.append(r)
    good = [r for r in out if not is_bad(r)]
    return (good or out)[:6]


def chat(cfg, ref, system, messages, timeout=300):
    prov, model = ref.split(":", 1)
    P = PROVIDERS[prov]
    key = cfg["keys"][prov]
    last = None
    for attempt in range(4):
        try:
            if P["kind"] == "anthropic":
                body = {"model": model, "max_tokens": 12000, "system": system, "messages": messages}
                h = {"x-api-key": key, "anthropic-version": "2023-06-01",
                     "content-type": "application/json", "User-Agent": UA}
                d = http_json(P["url"] + "/messages", h, body, timeout)
                text = "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text")
                u = d.get("usage", {})
                return text, (u.get("input_tokens", 0), u.get("output_tokens", 0))
            body = {"model": model, "messages": [{"role": "system", "content": system}] + messages}
            h = {"Authorization": "Bearer " + key, "Content-Type": "application/json", "User-Agent": UA}
            d = http_json(P["url"] + "/chat/completions", h, body, timeout)
            text = d["choices"][0]["message"].get("content") or ""
            u = d.get("usage", {}) or {}
            return text, (u.get("prompt_tokens", 0), u.get("completion_tokens", 0))
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300].replace("\n", " ")
            last = f"{P['name']} HTTP {e.code}: {detail}"
            retry = (e.code in (500, 502, 503, 504, 529) and attempt < 2) or (e.code == 429 and attempt < 1)
            if retry:
                time.sleep(3 if e.code == 429 else 2 * (attempt + 1))
                continue
            raise APIError(last, e.code)
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            last = f"{P['name']}: {e}"
            if attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            raise APIError(last, 0)
        except (KeyError, IndexError, ValueError) as e:
            raise APIError(f"{P['name']}: respuesta inesperada ({e})", -1)
    raise APIError(last or "error desconocido")


def clean_text(t):
    t = re.sub(r"<think>.*?</think>", "", t, flags=re.S)
    return t.strip()


# ───────────────────────── Descubrimiento de modelos ─────────────────────────
CACHE_FILE = CFG_DIR / "models_cache.json"
CACHE_TTL = 6 * 3600
SKIP_RE = re.compile(
    r"embed|whisper|tts|speech|audio|transcri|guard|safeguard|moderat|image|imagen|veo|lyria|robotics|"
    r"computer-use|-live|live-|dall-e|diffusion|flux|sdxl|clip|bge|parse|reward|classif|translat|riva|"
    r"retriev|paligemma|llava|-vl|vl-|vision|orpheus|playai|rerank|(?<![a-z])ocr|deep-research|safety", re.I)
# generaciones viejas: no se añaden solas al catálogo
OLD_RE = re.compile(
    r"llama-?[0-3](?![0-9])|gemma-?[1-3](?![0-9])|qwen-?[12](?![0-9])|mixtral|mistral-(7b|nemo|tiny)|"
    r"phi-?[1-3](?![0-9])|gpt-[34](?![0-9])|command-r|deepseek-r1|-(2[0-5])(0[1-9]|1[0-2])$", re.I)


def guess_scores(mid):
    """Puntaje aproximado (planificar, programar, velocidad) para un modelo desconocido, por su nombre."""
    m = mid.lower().split("/")[-1]
    nums = [float(x) for x in re.findall(r"(\d+(?:\.\d+)?)b(?![a-z])", m)]
    if nums:
        size = max(nums)
        plan = 9 if size >= 400 else 8 if size >= 100 else 7 if size >= 60 else 6 if size >= 25 else 5 if size >= 10 else 4
        fast = 3 if size >= 300 else 5 if size >= 100 else 7 if size >= 30 else 9
        code = plan
    else:
        plan = code = fast = 6
    if re.search(r"(?<![a-z])(flash|lite|mini|nano|small|instant|haiku|lightning|turbo)(?![a-z])", m):
        plan, code, fast = plan - 1, code - 1, fast + 2
    if re.search(r"(?<![a-z])(pro|ultra|large|max|opus|reason\w*|think\w*|super|sonnet|medium)(?![a-z])", m):
        plan, code, fast = plan + 1, code + 1, fast - 2
    if re.search(r"coder|code|devstral", m):
        code += 2
    cap = lambda x, hi: max(1, min(hi, x))
    return cap(plan, 8), cap(code, 8), cap(fast, 9)


def auth_headers(pid, key):
    h = {"User-Agent": UA}
    if PROVIDERS[pid]["kind"] == "anthropic":
        h.update({"x-api-key": key, "anthropic-version": "2023-06-01"})
    else:
        h["Authorization"] = "Bearer " + key
    return h


def _zero(v):
    try:
        return float(v) == 0
    except Exception:
        return False


def fetch_models(pid, key):
    P = PROVIDERS[pid]
    d = http_json(P.get("models_url", P["url"] + "/models"), auth_headers(pid, key), None, timeout=12, method="GET")
    items = d.get("data") if isinstance(d, dict) else d
    if items is None and isinstance(d, dict):
        items = d.get("models")
    out = []
    for it in items or []:
        if isinstance(it, str):
            it = {"id": it}
        mid = str(it.get("id") or it.get("name") or "")
        if pid == "gemini":
            mid = mid.replace("models/", "", 1)
            mv = re.match(r"gemini-(\d+(?:\.\d+)?)-", mid)
            ver = float(mv.group(1)) if mv else 0
            # solo Flash / Flash-Lite de la serie 3.5+ (y Lite 3.1); los 2.x y los Pro no se ofrecen
            if "flash" not in mid or not (ver >= 3.5 or (ver >= 3.1 and "lite" in mid) or (not mv and "latest" in mid)):
                continue
        if not mid or SKIP_RE.search(mid):
            continue
        if pid == "openrouter":
            pr = it.get("pricing") or {}
            free = mid.endswith(":free") or (_zero(pr.get("prompt")) and _zero(pr.get("completion")))
            mods = (it.get("architecture") or {}).get("output_modalities") or ["text"]
            if not free or list(mods) != ["text"]:
                continue
        caps = it.get("capabilities")
        if isinstance(caps, dict) and caps.get("completion_chat") is False:
            continue
        if it.get("active") is False:
            continue
        if mid not in out:
            out.append(mid)
    return out


def load_cache():
    try:
        return json.loads(CACHE_FILE.read_text())
    except Exception:
        return {"ts": 0, "models": {}}


def build_catalog(cfg, live):
    items, seen = [], set()
    for pid, mid, a, b, c in CATALOG:
        if live.get(pid) and mid not in live[pid]:
            continue                      # el proveedor ya no lo ofrece
        items.append((pid, mid, a, b, c))
        seen.add((pid, mid))
    for pid, ids in live.items():
        if pid not in PROVIDERS:
            continue
        extra = [(pid, mid) + guess_scores(mid) for mid in ids
                 if (pid, mid) not in seen and not OLD_RE.search(mid)]
        extra.sort(key=lambda x: -x[2])
        items += extra[:25]
    for pid, c in cfg.get("custom", {}).items():
        if c.get("model") and (pid, c["model"]) not in seen:
            items.append((pid, c["model"], 6, 6, 6))
    return items


def refresh_models(cfg, force=False, quiet=False):
    """Pide la lista real de modelos a cada proveedor gratis con key (en paralelo, con caché de 6 h)."""
    global CAT
    cache = load_cache()
    live = cache.get("models", {})
    want = [p for p in PROVIDERS if cfg["keys"].get(p) and is_free(p)]
    stale = time.time() - cache.get("ts", 0) > CACHE_TTL or any(p not in live for p in want)
    if want and (force or stale):
        def job(p):
            try:
                return p, fetch_models(p, cfg["keys"][p])
            except Exception:
                return p, None
        res = []
        try:
            with console.status(Text("buscando modelos nuevos…", style="muted"), spinner="dots"):
                with ThreadPoolExecutor(max_workers=8) as ex:
                    res = list(ex.map(job, want))
        except Exception:
            pass
        ok = 0
        for p, ids in res:
            if ids:
                live[p] = ids
                ok += 1
            elif p not in live:
                live[p] = []
        try:
            CACHE_FILE.write_text(json.dumps({"ts": time.time(), "models": live}))
        except Exception:
            pass
        if not quiet:
            n = sum(len(v) for p, v in live.items() if p in want)
            console.print(Text(f"  ✓ modelos actualizados · {ok}/{len(want)} proveedores · {n} modelos gratis detectados",
                               style="ok" if ok else "warn"))
    CAT = build_catalog(cfg, {p: v for p, v in live.items() if p in want})


# ───────────────────────── Contexto de ejecución ─────────────────────────
class Ctx:
    def __init__(self, cfg, ws, sess):
        self.cfg, self.ws, self.sess = cfg, ws, sess
        self.always = False
        self.actions = []
        self.last_answer = ""

    def save(self):
        try:
            (self.ws / ".codex").mkdir(parents=True, exist_ok=True)
            (self.ws / ".codex" / "session.json").write_text(
                json.dumps(self.sess, ensure_ascii=False, indent=1))
        except Exception as e:
            console.print(Text(f"no se pudo guardar la sesión: {e}", style="err"))


CTX = None


def call_model(ctx, role, system, messages, label=None):
    errs = []
    for ref in chain(ctx.cfg, ctx.sess, role):
        try:
            st = ROLE_STYLE[role]
            with console.status(Text.assemble((f"{label or ROLE_NAME[role]} ", f"bold {st}"),
                                              (f"· {short(ref)}", "muted")), spinner="dots"):
                text, (i, o) = chat(ctx.cfg, ref, system, messages)
            text = clean_text(text)
            if not text:
                raise APIError(f"{short(ref)}: respuesta vacía", -1)
            ctx.sess["tokens"][0] += i
            ctx.sess["tokens"][1] += o
            return text, ref
        except APIError as e:
            penalize(ref, e.code)
            errs.append(str(e))
            console.print(Text(f"  ! {short(ref)} falló: {str(e)[:160]} · probando otro…", style="warn"))
    raise APIError("Todos los modelos fallaron:\n" + "\n".join(errs))


# ───────────────────────── Herramientas ─────────────────────────
TOOLSPEC = {
    "list_dir":  ("Lista archivos en árbol.", "path (def .), depth (def 2)"),
    "read_file": ("Lee un archivo de texto.", "path, start y end (líneas, opcionales)"),
    "write_file": ("Crea o sobrescribe un archivo completo.", "path, content"),
    "edit_file": ("Reemplaza texto exacto dentro de un archivo.", "path, old, new, all (true = todas las coincidencias)"),
    "make_dir":  ("Crea carpetas (con padres).", "path"),
    "move":      ("Mueve o renombra archivos/carpetas.", "src, dst"),
    "delete":    ("Borra un archivo o carpeta.", "path"),
    "search":    ("Busca una regex en los archivos.", "pattern, path (def .), glob (opcional, ej. *.py)"),
    "run":       ("Ejecuta un comando bash en el workspace.", "command, timeout (seg, def 120)"),
    "fetch":     ("Descarga una URL y devuelve su texto.", "url"),
    "ask_architect": ("Consulta al arquitecto (modelo de planificación).", "question"),
}
TOOLSETS = {
    "plan_ro": ["list_dir", "read_file", "search"],
    "plan_rw": ["list_dir", "read_file", "search", "write_file", "edit_file", "make_dir", "move"],
    "work": ["list_dir", "read_file", "search", "write_file", "edit_file", "make_dir",
             "move", "delete", "run", "fetch", "ask_architect"],
}


def tool_doc(setname):
    lines = ["HERRAMIENTAS. Para actuar escribe llamadas con este formato EXACTO "
             "(puedes poner varias seguidas; se ejecutan en orden):", "",
             '<tool name="NOMBRE">', "<param>valor</param>", "</tool>", "",
             "Reglas del formato: escribe <path> SIEMPRE primero; el contenido de archivos va en crudo "
             "(sin escapar y sin bloques ```); tras tus llamadas DETENTE y espera el <tool_result>. "
             "Cuando hayas terminado, responde SIN ninguna herramienta con un resumen breve.", "",
             "Disponibles:"]
    for n in TOOLSETS[setname]:
        d, p = TOOLSPEC[n]
        lines.append(f"- {n}: {d}  Parámetros: {p}")
    return "\n".join(lines)


def sys_work(ctx, fast=False):
    extra = "\nSé MUY breve: respuestas cortas y directas." if fast else ""
    return f"""Eres CODEX MOBILE, un agente de programación autónomo que trabaja dentro de Termux (Android, sin root).
Workspace de esta sesión: {ctx.ws}
Responde en el idioma del usuario (por defecto español), conciso y directo.{extra}

ENTORNO
- Instalar: `pkg install -y <paquete>` y `pip install`. Nunca uses sudo ni apt directo.
- El workspace está en almacenamiento compartido de Android: allí NO hay symlinks ni permisos de ejecución.
  Para venv, node_modules, compilar o ejecutar binarios, trabaja en $HOME/build/<proyecto> y copia el resultado al workspace.
- Procesos largos (servidores): `nohup comando > log.txt 2>&1 &` y comprueba el log.
- Si Termux:API está instalado puedes usar termux-notification, termux-clipboard-set, etc.

REGLAS
- Actúa; no preguntes salvo que sea imprescindible. Entrega el trabajo completo y funcional.
- Lee antes de editar; usa edit_file para cambios pequeños.
- Verifica ejecutando cuando sea posible y corrige errores tú mismo.
- Si hay un PLAN del arquitecto, síguelo. Ante dudas de diseño usa ask_architect.
- No imitas las líneas "[acciones: ...]" del historial: son solo memoria.
- Termina con un resumen corto: qué hiciste y cómo usarlo.

{tool_doc("work")}"""


ARCH_SYS = """Eres el ARQUITECTO de Codex Mobile. Planificas y ordenas el proyecto; otro modelo (el obrero) lo implementa.
Responde en el idioma del usuario. Puedes usar herramientas de lectura para inspeccionar el proyecto antes de planificar.
Tu respuesta final es SOLO el plan en Markdown, con estas secciones:
## Objetivo
## Estructura  (árbol de archivos propuesto)
## Pasos  (checklist `- [ ]` numerada, concreta y ejecutable en Termux)
## Dependencias y comandos
## Verificación
Sé preciso y breve. Sin código completo, sin relleno.

""" + tool_doc("plan_ro")

REVIEW_SYS = """Eres el ARQUITECTO revisando el trabajo del obrero.
Inspecciona el proyecto con las herramientas y ORDÉNALO: estructura de carpetas coherente, nombres claros,
README.md corto si falta (qué es y cómo ejecutarlo), y actualiza .codex/PLAN.md marcando los pasos hechos (`- [x]`).
No reescribas la lógica del código. Cierra con un veredicto de 3 a 5 líneas: qué quedó bien y qué falta.

""" + tool_doc("plan_rw")

ARCH_ASK_SYS = ("Eres el ARQUITECTO de un proyecto. El obrero te hace una consulta de diseño. "
                "Responde de forma breve, concreta y accionable, en el idioma del usuario.")

TOOL_RE = re.compile(r'<tool\s+name="([a-z_]+)"\s*>(.*?)</tool>', re.S)
PARAM_RE = re.compile(r'<([a-z_]+)>(.*?)</\1>', re.S)


def unfence(v):
    lines = v.split("\n")
    if len(lines) >= 2 and lines[0].startswith("```") and lines[-1].strip() == "```":
        return "\n".join(lines[1:-1])
    return v


def parse_calls(text):
    calls = []
    for m in TOOL_RE.finditer(text):
        args = {}
        for pm in PARAM_RE.finditer(m.group(2)):
            k, v = pm.group(1), pm.group(2)
            if k in ("content", "old", "new", "question"):
                if v.startswith("\n"):
                    v = v[1:]
                if v.endswith("\n"):
                    v = v[:-1]
                if k == "content":
                    v = unfence(v)
            else:
                v = v.strip()
            args[k] = v
        calls.append((m.group(1), args))
    return calls


def rp(ctx, p):
    p = os.path.expanduser(str(p).strip())
    return Path(p) if os.path.isabs(p) else ctx.ws / p


def inside(ctx, p):
    try:
        Path(p).resolve().relative_to(Path(ctx.ws).resolve())
        return True
    except ValueError:
        return False


SAFE_CMDS = {"ls", "cat", "pwd", "echo", "head", "tail", "wc", "grep", "find", "tree", "stat", "file",
             "du", "df", "which", "whoami", "date", "env", "printenv", "uname", "sort", "uniq", "cut",
             "diff", "python", "python3", "node", "pip", "git", "rg", "sed", "awk", "test", "true", "cd"}
SAFE_GIT = {"status", "diff", "log", "branch", "show", "--version", "remote", "ls-files"}
DANGER = re.compile(
    r"(\brm\s+(-[a-zA-Z]+\s+)*(/|~/?|\$HOME/?|/storage/?|/storage/emulated/?(0/?)?|/sdcard/?|\*)(\s|$))"
    r"|\bmkfs|\bdd\s+if=.*of=/dev|:\(\)\s*\{|>\s*/dev/(sd|block)|chmod\s+-R\s+\d+\s+/(\s|$)")


def is_safe_cmd(cmd):
    if re.search(r"[><`]|\$\(", cmd):
        return False
    for seg in re.split(r"\|\||&&|;|\|", cmd):
        toks = seg.strip().split()
        if not toks:
            continue
        if any("/" in t or t.startswith("~") or "$" in t or re.search(r"(^|/)\.\.(/|$)", t) for t in toks[1:]):
            return False
        if toks[0] not in SAFE_CMDS:
            return False
        if toks[0] == "git" and (len(toks) < 2 or toks[1] not in SAFE_GIT):
            return False
        if toks[0] == "sed" and any(t.startswith("-i") for t in toks):
            return False
        if toks[0] == "find" and any(t in ("-delete", "-exec") for t in toks):
            return False
        if toks[0] in ("pip", "python", "python3", "node") and not any(
                t in ("--version", "-V", "-v", "list", "show") for t in toks[1:]):
            return False
    return True


def approve(ctx, title, detail, danger=False):
    if not danger and (ctx.sess["mode"] == "total" or ctx.always):
        return True
    console.print(Panel(Text(detail), title=Text(f" {title} ", style="bold err" if danger else "bold warn"),
                        title_align="left", border_style="err" if danger else "warn", box=ROUNDED))
    opts = "[s] sí  [n] no" if danger else "[s] sí  [t] sí a todo  [n] no"
    a = ask(opts, default="n").strip().lower()
    if a in ("t", "todo") and not danger:
        ctx.always = True
        return True
    return a in ("s", "si", "sí", "y", "yes")


def guard_outside(ctx, p, verb):
    resolved = Path(p).resolve()
    if not inside(ctx, resolved):
        if not approve(ctx, "Fuera del workspace", f"{verb}: {resolved}"):
            raise ToolError("el usuario denegó la operación fuera del workspace")


def snapshot_file(ctx, p):
    p = Path(p).resolve()
    if not inside(ctx, p):
        return
    if p.exists() and not p.is_file():
        return
    meta = ctx.ws / ".codex" / "snapshots.json"
    folder = ctx.ws / ".codex" / "snapshots"
    folder.mkdir(parents=True, exist_ok=True)
    entries = json.loads(meta.read_text()) if meta.exists() else []
    backup = None
    if p.is_file():
        backup = uuid.uuid4().hex + ".bak"
        shutil.copy2(p, folder / backup)
    entries.append({"path": str(p.relative_to(ctx.ws.resolve())), "backup": backup,
                    "created": datetime.now().isoformat(timespec="seconds")})
    for old in entries[:-50]:
        if old.get("backup"):
            (folder / old["backup"]).unlink(missing_ok=True)
    meta.write_text(json.dumps(entries[-50:], ensure_ascii=False, indent=1))


def cmd_rollback(ctx, arg):
    meta = ctx.ws / ".codex" / "snapshots.json"
    if not meta.is_file():
        console.print(Text("  no hay snapshots para restaurar", style="muted"))
        return
    try:
        count = min(max(int(arg or "1"), 1), 20)
        entries = json.loads(meta.read_text())
        restored = 0
        folder = meta.parent / "snapshots"
        for _ in range(count):
            if not entries:
                break
            item = entries.pop()
            target = (ctx.ws / item["path"]).resolve()
            if not inside(ctx, target):
                continue
            backup = item.get("backup")
            if backup:
                source = folder / backup
                if source.is_file():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
                    source.unlink()
            else:
                target.unlink(missing_ok=True)
            restored += 1
        meta.write_text(json.dumps(entries, ensure_ascii=False, indent=1))
        console.print(Text(f"  ✓ rollback aplicado ({restored} cambio(s))", style="ok"))
    except (ValueError, OSError, json.JSONDecodeError) as e:
        console.print(Text(f"  no se pudo aplicar rollback: {e}", style="err"))


def start_preview(ctx):
    found = False
    for root, dirs, files in os.walk(ctx.ws):
        dirs[:] = [d for d in dirs if d not in IGN]
        if any(name.lower().endswith(".html") for name in files):
            found = True
            break
    if not found:
        return
    meta = ctx.ws / ".codex"
    meta.mkdir(parents=True, exist_ok=True)
    pid_file, url_file = meta / "http.pid", meta / "http.url"
    try:
        pid = int(pid_file.read_text()) if pid_file.exists() else 0
        if pid:
            os.kill(pid, 0)
            if url_file.exists():
                console.print(Text(f"  preview local: {url_file.read_text().strip()}", style="ok"))
                return
    except (ValueError, OSError):
        pass
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    log = (meta / "http.log").open("ab")
    try:
        proc = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
                                cwd=str(ctx.ws), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                start_new_session=True)
    except OSError as e:
        log.close()
        console.print(Text(f"  no se pudo iniciar preview: {e}", style="warn"))
        return
    log.close()
    url = f"http://127.0.0.1:{port}/"
    pid_file.write_text(str(proc.pid))
    url_file.write_text(url)
    console.print(Text(f"  preview local: {url}", style="ok"))


IGN = {".git", "node_modules", "__pycache__", ".codex", ".venv", "venv", ".cache"}


def walk_tree(base, depth=2, limit=300):
    lines = []

    def rec(d, lvl):
        try:
            ents = sorted(d.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except Exception as e:
            lines.append("  " * lvl + f"(sin acceso: {e})")
            return
        for p in ents:
            if p.name in IGN:
                continue
            if p.is_symlink():
                lines.append("  " * lvl + p.name + " -> (symlink omitido)")
                continue
            if len(lines) >= limit:
                lines.append("  " * lvl + "…")
                return
            if p.is_dir():
                lines.append("  " * lvl + p.name + "/")
                if lvl + 1 < depth:
                    rec(p, lvl + 1)
            else:
                try:
                    sz = p.stat().st_size
                except Exception:
                    sz = 0
                lines.append("  " * lvl + f"{p.name} ({human(sz)})")

    rec(base, 0)
    return lines


def t_list_dir(ctx, a):
    base = rp(ctx, a.get("path", "."))
    guard_outside(ctx, base, "listar")
    if not base.is_dir():
        raise ToolError(f"no es una carpeta: {base}")
    lines = walk_tree(base, int(a.get("depth", "2") or 2))
    return "\n".join(lines) or "(vacía)"


def t_read_file(ctx, a):
    p = rp(ctx, a["path"])
    guard_outside(ctx, p, "leer")
    if not p.is_file():
        raise ToolError(f"no existe el archivo: {p}")
    raw = p.read_bytes()
    if b"\0" in raw[:4096]:
        return f"(archivo binario, {human(len(raw))})"
    txt = raw.decode("utf-8", "replace")
    s = int(a.get("start") or 0)
    e = int(a.get("end") or 0)
    if s or e:
        L = txt.split("\n")
        txt = "\n".join(L[max(s, 1) - 1:(e or len(L))])
    if len(txt) > 24000:
        txt = txt[:24000] + f"\n…[recortado; archivo de {human(len(raw))}; usa start/end]"
    return txt or "(archivo vacío)"


def t_write_file(ctx, a):
    p = rp(ctx, a["path"])
    content = a.get("content", "")
    guard_outside(ctx, p, "escribir")
    snapshot_file(ctx, p)
    p.parent.mkdir(parents=True, exist_ok=True)
    existed = p.exists()
    p.write_text(content, encoding="utf-8")
    if content.startswith("#!"):
        try:
            os.chmod(p, 0o755)
        except Exception:
            pass
    return f"{'sobrescrito' if existed else 'creado'}: {p} ({len(content.splitlines())} líneas)"


def t_edit_file(ctx, a):
    p = rp(ctx, a["path"])
    if not p.is_file():
        raise ToolError(f"no existe el archivo: {p}")
    guard_outside(ctx, p, "editar")
    snapshot_file(ctx, p)
    old, new = a["old"], a.get("new", "")
    txt = p.read_text(encoding="utf-8", errors="replace")
    n = txt.count(old)
    if n == 0:
        raise ToolError("el texto 'old' no aparece en el archivo (debe coincidir exacto, con espacios)")
    if n > 1 and a.get("all", "").lower() != "true":
        raise ToolError(f"'old' aparece {n} veces; añade más contexto o usa <all>true</all>")
    p.write_text(txt.replace(old, new), encoding="utf-8")
    return f"editado: {p} ({n} reemplazo{'s' if n > 1 else ''})"


def t_make_dir(ctx, a):
    p = rp(ctx, a["path"])
    guard_outside(ctx, p, "crear carpeta")
    p.mkdir(parents=True, exist_ok=True)
    return f"carpeta lista: {p}"


def t_move(ctx, a):
    s, d = rp(ctx, a["src"]), rp(ctx, a["dst"])
    if not s.exists():
        raise ToolError(f"no existe: {s}")
    guard_outside(ctx, s, "mover desde")
    guard_outside(ctx, d, "mover hacia")
    d.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(s), str(d))
    return f"movido: {s} → {d}"


def t_delete(ctx, a):
    p = rp(ctx, a["path"])
    if not p.exists():
        raise ToolError(f"no existe: {p}")
    if os.path.abspath(p) == os.path.abspath(ctx.ws):
        raise ToolError("no se puede borrar el workspace completo")
    if not approve(ctx, "Borrar", str(p)):
        raise ToolError("el usuario denegó el borrado")
    shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()
    return f"borrado: {p}"


def t_search(ctx, a):
    base = rp(ctx, a.get("path", "."))
    guard_outside(ctx, base, "buscar")
    try:
        rx = re.compile(a["pattern"])
    except re.error as e:
        raise ToolError(f"regex inválida: {e}")
    glob = a.get("glob", "").strip()
    out = []
    files = [base] if base.is_file() else []
    if base.is_dir():
        for root, dirs, fs in os.walk(base):
            dirs[:] = [d for d in dirs if d not in IGN]
            for f in fs:
                if not glob or Path(f).match(glob):
                    files.append(Path(root) / f)
    for f in files:
        try:
            if f.is_symlink():
                continue
            if f.stat().st_size > 1_000_000:
                continue
            raw = f.read_bytes()
            if b"\0" in raw[:2048]:
                continue
            for i, line in enumerate(raw.decode("utf-8", "replace").split("\n"), 1):
                if rx.search(line):
                    rel = os.path.relpath(f, ctx.ws)
                    out.append(f"{rel}:{i}: {line.strip()[:160]}")
                    if len(out) >= 80:
                        return "\n".join(out) + "\n…[límite de 80 coincidencias]"
        except Exception:
            continue
    return "\n".join(out) or "(sin coincidencias)"


def t_fetch(ctx, a):
    url = a["url"].strip()
    if not url.startswith(("http://", "https://")):
        raise ToolError("la URL debe empezar por http:// o https://")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read(1_500_000)
            ctype = r.headers.get("Content-Type", "")
    except Exception as e:
        raise ToolError(f"no se pudo descargar: {e}")
    txt = raw.decode("utf-8", "replace")
    if "html" in ctype or txt.lstrip().startswith("<"):
        txt = re.sub(r"(?is)<(script|style|noscript).*?</\1>", " ", txt)
        txt = re.sub(r"(?s)<[^>]+>", " ", txt)
        txt = re.sub(r"[ \t\r\f\v]+", " ", unescape(txt))
        txt = re.sub(r"\n\s*\n+", "\n\n", txt)
    return clip(txt.strip(), 8000)


def run_shell(ctx, cmd, timeout=120):
    exe = shutil.which("bash") or "/system/bin/sh"
    env = dict(os.environ)
    env.update({"PAGER": "cat", "GIT_PAGER": "cat", "CI": "1", "DEBIAN_FRONTEND": "noninteractive"})
    Path(ctx.ws).mkdir(parents=True, exist_ok=True)
    p = subprocess.Popen(cmd, shell=True, executable=exe, cwd=str(ctx.ws), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, env=env,
                         start_new_session=True)
    try:
        with console.status(Text.assemble(("ejecutando ", "bold work"), (cmd[:50], "muted")), spinner="dots"):
            out, err = p.communicate(timeout=timeout)
        code = p.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
        out, err = p.communicate()
        code = f"timeout>{timeout}s"
    except KeyboardInterrupt:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
        raise
    stdout = out.decode("utf-8", "replace").rstrip()
    stderr = err.decode("utf-8", "replace").rstrip()
    if code != 0 and stderr:
        stdout = (stdout + "\n[stderr]\n" + stderr).strip()
    elif stderr:
        stdout = (stdout + "\n[stderr]\n" + stderr).strip()
    return code, clip(stdout)


def t_run(ctx, a):
    cmd = a["command"]
    timeout = min(int(a.get("timeout") or 120), 900)
    if DANGER.search(cmd):
        if not approve(ctx, "Comando PELIGROSO", cmd, danger=True):
            raise ToolError("el usuario denegó un comando peligroso")
    elif not is_safe_cmd(cmd):
        if not approve(ctx, "Ejecutar comando", cmd):
            raise ToolError("el usuario denegó el comando")
    code, out = run_shell(ctx, cmd, timeout)
    return f"exit={code}\n{out}" if out else f"exit={code}\n(sin salida)"


def t_ask_architect(ctx, a):
    plan = ""
    pf = ctx.ws / ".codex" / "PLAN.md"
    if pf.exists():
        plan = pf.read_text(errors="replace")[:5000]
    q = f"PLAN VIGENTE:\n{plan or '(sin plan)'}\n\nCONSULTA DEL OBRERO:\n{a['question']}"
    text, _ = call_model(ctx, "plan", ARCH_ASK_SYS, [{"role": "user", "content": q}], "Arquitecto")
    return text


TOOL_FUNCS = {
    "list_dir": t_list_dir, "read_file": t_read_file, "write_file": t_write_file,
    "edit_file": t_edit_file, "make_dir": t_make_dir, "move": t_move, "delete": t_delete,
    "search": t_search, "run": t_run, "fetch": t_fetch, "ask_architect": t_ask_architect,
}


def execute(ctx, name, args, toolset):
    fn = TOOL_FUNCS.get(name)
    if not fn or name not in TOOLSETS[toolset]:
        return False, f"herramienta no disponible: {name}"
    try:
        return True, fn(ctx, args)
    except ToolError as e:
        return False, str(e)
    except KeyError as e:
        return False, f"falta el parámetro obligatorio {e}"
    except KeyboardInterrupt:
        raise
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"


# ───────────────────────── Interfaz: llamadas a herramientas ─────────────────────────
ICON = {"read_file": "◇", "list_dir": "◇", "search": "◇", "write_file": "✎", "edit_file": "✎",
        "make_dir": "▣", "move": "⇄", "delete": "✗", "run": "❯", "fetch": "⇣", "ask_architect": "✦"}


def show_call(name, a):
    d = ""
    if name in ("read_file", "write_file", "edit_file", "make_dir", "list_dir", "delete"):
        d = a.get("path", "")
    elif name == "move":
        d = f"{a.get('src', '')} → {a.get('dst', '')}"
    elif name == "run":
        d = a.get("command", "")
    elif name == "search":
        d = a.get("pattern", "")
    elif name == "fetch":
        d = a.get("url", "")
    elif name == "ask_architect":
        d = a.get("question", "")
    d = d.replace("\n", " ")
    if len(d) > 64:
        d = d[:63] + "…"
    style = "plan" if name == "ask_architect" else "accent"
    console.print(Text.assemble(("  " + ICON.get(name, "•") + " ", style), (name, "bold"), ("  " + d, "muted")))


def show_result(name, a, ok, res):
    if not ok:
        console.print(Text("    ✗ " + res.split("\n")[0][:200], style="err"))
        return
    if name == "write_file":
        body = a.get("content", "")
        lines = body.split("\n")
        try:
            lex = Syntax.guess_lexer(a.get("path", ""), body)
        except Exception:
            lex = "text"
        console.print(Padding(Syntax("\n".join(lines[:10]), lex, theme="ansi_dark", line_numbers=True,
                                     word_wrap=True), (0, 0, 0, 4)))
        if len(lines) > 10:
            console.print(Text(f"      … +{len(lines) - 10} líneas", style="muted"))
    elif name == "edit_file":
        t = Text()
        for ln in a.get("old", "").split("\n")[:6]:
            t.append("    - " + ln[:90] + "\n", style="err")
        for ln in a.get("new", "").split("\n")[:6]:
            t.append("    + " + ln[:90] + "\n", style="ok")
        console.print(t, end="")
    elif name == "run":
        head, _, out = res.partition("\n")
        okc = head.strip() == "exit=0"
        console.print(Text("    " + ("✓ " if okc else "✗ ") + head, style="ok" if okc else "err"))
        L = out.split("\n") if out else []
        for ln in L[-10:]:
            console.print(Text("      " + ln[:200], style="muted"))
        if len(L) > 10:
            console.print(Text(f"      (+{len(L) - 10} líneas anteriores)", style="muted"))
    elif name == "ask_architect":
        console.print(Padding(Text(res[:600], style="plan"), (0, 0, 0, 4)))
    else:
        first = res.split("\n")[0][:90]
        n = res.count("\n") + 1
        console.print(Text(f"    ✓ {first}" + (f"  (+{n - 1} líneas)" if n > 1 else ""), style="muted"))


def answer_panel(text, title, style):
    console.print(Panel(Markdown(text or "(sin respuesta)"), title=Text(f" {title} ", style=f"bold {style}"),
                        title_align="left", border_style=style, box=ROUNDED, padding=(0, 1)))


# ───────────────────────── Agente (bucle de herramientas) ─────────────────────────
def run_agent(ctx, role, system, messages, toolset, max_steps=30, label=None):
    msgs = list(messages)
    for step in range(max_steps):
        text, ref = call_model(ctx, role, system, msgs, label)
        calls = parse_calls(text)
        prose = TOOL_RE.sub("", text).strip()
        if not calls:
            return prose or "(sin respuesta)"
        if prose:
            console.print(Padding(Text(prose[:500], style="muted italic"), (0, 0, 0, 2)))
        msgs.append({"role": "assistant", "content": text})
        results = []
        for name, args in calls:
            show_call(name, args)
            ok, res = execute(ctx, name, args, toolset)
            show_result(name, args, ok, res)
            if ok:
                ctx.actions.append(f"{name} {args.get('path') or args.get('command', '')[:40] or ''}".strip())
            tag = "tool_result" if ok else "tool_error"
            results.append(f'<{tag} name="{name}">\n{clip(res)}\n</{tag}>')
        msgs.append({"role": "user", "content": "\n".join(results)})
    return "(límite de pasos alcanzado; dime si continúo)"


# ───────────────────────── Enrutador automático ─────────────────────────
HARD = re.compile(r"\b(proyecto|aplicaci[oó]n|app|sistema|arquitectura|refactor\w*|completo|completa|"
                  r"desde cero|backend|frontend|api|base de datos|bot|juego|sitio web|p[aá]gina web|"
                  r"dashboard|migra\w*|integra\w*|varios archivos|framework|microservic\w*|"
                  r"autenticaci[oó]n|landing|crud|scraper|servidor)\b", re.I)
ACTION = re.compile(r"\b(crea\w*|haz|hacer|genera\w*|escribe|edita\w*|arregla\w*|corrige\w*|instala\w*|"
                    r"ejecuta\w*|corre|configura\w*|borra\w*|elimina\w*|lee|lista\w*|mueve|renombra\w*|"
                    r"agrega\w*|añade|implementa\w*|depura\w*|optimiza\w*|compila\w*|descarga\w*|"
                    r"create|make|write|edit|fix|install|run|build|add|delete|move|debug|deploy)\b", re.I)
FILEREF = re.compile(r"\b[\w\-]+\.(py|js|ts|sh|json|html|css|md|txt|yml|yaml|c|cpp|go|rs|java|php|rb)\b", re.I)


def classify(msg):
    m = msg.strip()
    words = len(m.split())
    if words > 70 or HARD.search(m) and words >= 5:
        return "full"
    act = bool(ACTION.search(m) or FILEREF.search(m))
    if act:
        return "fast" if words <= 7 else "exec"
    return "exec" if words > 40 else "fast"


def smart_route(ctx, msg):
    key = ctx.cfg.get("keys", {}).get("groq")
    if not key:
        return classify(msg)
    ref = "groq:openai/gpt-oss-20b"
    system = ("Clasifica la petición en una ruta. Responde únicamente fast, exec o full. "
              "fast=consulta; exec=cambio acotado; full=proyecto, varios archivos o arquitectura.")
    try:
        text, _ = chat(ctx.cfg, ref, system, [{"role": "user", "content": msg}], timeout=30)
        route = clean_text(text).strip().lower().split()[0]
        return route if route in ("fast", "exec", "full") else classify(msg)
    except (APIError, TimeoutError, OSError, IndexError):
        return classify(msg)


ROUTE_LABEL = {"fast": ("rápido", "fast"), "exec": ("directo · obrero", "work"),
               "full": ("arquitecto → obrero → revisión", "plan")}


# ───────────────────────── Turno completo ─────────────────────────
def task_prompt(ctx, msg, plan, with_tree=True):
    s = f"[Workspace: {ctx.ws}]\n"
    if with_tree:
        tree = "\n".join(walk_tree(ctx.ws, 2, 60)) or "(carpeta vacía)"
        s += f"[Estado actual]\n{tree}\n"
    if plan:
        s += f"\n[PLAN DEL ARQUITECTO — síguelo]\n{plan}\n"
    return s + f"\n[PETICIÓN]\n{msg}"


def phase_plan(ctx, msg):
    console.print(Text("  ✦ Arquitecto planificando…", style="plan"))
    tree = "\n".join(walk_tree(ctx.ws, 2, 80)) or "(vacío)"
    pf = ctx.ws / ".codex" / "PLAN.md"
    prev = pf.read_text(errors="replace")[:4000] if pf.exists() else "(ninguno)"
    user = (f"Workspace: {ctx.ws}\nEstructura actual:\n{tree}\n\nPLAN ANTERIOR:\n{prev}\n\n"
            f"PETICIÓN DEL USUARIO:\n{msg}")
    plan = run_agent(ctx, "plan", ARCH_SYS, [{"role": "user", "content": user}], "plan_ro", 6)
    try:
        pf.parent.mkdir(parents=True, exist_ok=True)
        pf.write_text(plan, encoding="utf-8")
    except Exception:
        pass
    answer_panel(plan, "Plan · " + short(chain(ctx.cfg, ctx.sess, "plan")[0]), "plan")
    return plan


def phase_review(ctx, msg, plan, result):
    console.print(Text("  ✦ Arquitecto revisando y ordenando…", style="plan"))
    user = (f"PETICIÓN:\n{msg}\n\nPLAN:\n{plan}\n\nRESUMEN DEL OBRERO:\n{result}\n\n"
            f"ACCIONES REALIZADAS:\n" + "\n".join(ctx.actions[-30:]) +
            f"\n\nWorkspace: {ctx.ws}")
    out = run_agent(ctx, "plan", REVIEW_SYS, [{"role": "user", "content": user}], "plan_rw", 8, "Arquitecto")
    answer_panel(out, "Revisión", "plan")


def notify(title, text):
    if shutil.which("termux-notification"):
        try:
            subprocess.Popen(["termux-notification", "--title", title, "--content", text],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if shutil.which("termux-vibrate"):
                subprocess.Popen(["termux-vibrate", "-d", "120"], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        except Exception:
            pass


def remember(ctx, msg, final):
    acts = "; ".join(ctx.actions[-12:])
    a = (final or "(sin respuesta)")[:2500]
    if acts:
        a += f"\n[acciones: {acts}]"
    ctx.sess["history"] += [{"role": "user", "content": msg}, {"role": "assistant", "content": a}]
    ctx.sess["history"] = ctx.sess["history"][-40:]
    ctx.save()


def turn(ctx, msg):
    t0 = time.time()
    ctx.actions = []
    router = ctx.sess.get("router_mode", "auto")
    if router == "smart":
        route = smart_route(ctx, msg)
    elif router == "manual":
        route = ctx.sess.get("route", "exec")
        if route == "auto":
            route = "exec"
    else:
        route = classify(msg)
    lab, st = ROUTE_LABEL[route]
    console.print(Rule(Text(f" {lab} ", style=f"bold {st}"), style="muted", characters="─"))
    plan = ""
    try:
        if route == "full":
            plan = phase_plan(ctx, msg)
        role = "fast" if route == "fast" else "code"
        hist = ctx.sess["history"][-16:]
        prompt = task_prompt(ctx, msg, plan, with_tree=(route != "fast"))
        final = run_agent(ctx, role, sys_work(ctx, fast=(route == "fast")), hist + [{"role": "user", "content": prompt}],
                          "work", 8 if route == "fast" else 40)
        ref = chain(ctx.cfg, ctx.sess, role)[0]
        answer_panel(final, f"{ROLE_NAME[role]} · {short(ref)}", ROLE_STYLE[role])
        ctx.last_answer = final
        if route == "full" and ctx.sess.get("review", True):
            phase_review(ctx, msg, plan, final)
        remember(ctx, msg, final)
        start_preview(ctx)
    except APIError as e:
        console.print(Panel(Text(str(e)), title=" Error de API ", border_style="err", box=ROUNDED))
        return
    dt = time.time() - t0
    console.print(Text(f"  ⏱ {dt:.0f}s · tokens ↑{ctx.sess['tokens'][0]:,} ↓{ctx.sess['tokens'][1]:,}", style="muted"))
    if dt > 20:
        notify("Codex Mobile", "Tarea terminada")


# ───────────────────────── Entrada (prompt_toolkit) ─────────────────────────
PT_STYLE = PTStyle.from_dict({
    "pt.mark": "#7aa2f7 bold", "pt.q": "#c0caf5", "pt.dim": "#6b7399",
    "bottom-toolbar": "noreverse bg:#1f2335 #a9b1d6",
    "bottom-toolbar.text": "",
    "tb.k": "bg:#7aa2f7 #1a1b26 bold", "tb.v": "#c0caf5", "tb.sep": "#414868",
    "tb.plan": "#bb9af7 bold", "tb.work": "#7dcfff bold", "tb.fast": "#ff9e64 bold", "tb.mode": "#e0af68",
    "completion-menu.completion": "bg:#24283b #c0caf5",
    "completion-menu.completion.current": "bg:#7aa2f7 #1a1b26",
    "completion-menu.meta.completion": "bg:#1f2335 #6b7399",
    "completion-menu.meta.completion.current": "bg:#7aa2f7 #1a1b26",
})

COMMANDS = {
    "/ayuda": "lista de comandos", "/sesiones": "ver / cambiar de sesión", "/nueva": "crear otra sesión",
    "/modelos": "ver y elegir modelos (u = actualizar lista)", "/claves": "gestionar API keys",
    "/agregar": "añadir otro proveedor gratis (URL + key)",
    "/modo": "normal | total",
    "/ruta": "rapido | directo | plan (selección manual)", "/router": "auto | manual | smart (Groq GPT-OSS-20B)",
    "/revision": "on | off (revisión del arquitecto)", "/rollback": "restaurar cambios recientes",
    "/plan": "mostrar el plan actual", "/ver": "árbol de archivos", "/costo": "tokens usados",
    "/limpiar": "borrar memoria de la sesión", "/copiar": "copiar última respuesta",
    "/config": "ver configuración de la sesión", "/salir": "salir de Codex Mobile",
}


class SlashCompleter(Completer):
    def get_completions(self, document, complete_event):
        t = document.text_before_cursor
        if not t.startswith("/") or " " in t:
            return
        for c, d in COMMANDS.items():
            if c.startswith(t):
                yield Completion(c, start_position=-len(t), display_meta=d)


PS_PLAIN = None
PS_MAIN = None


def init_prompts():
    global PS_PLAIN, PS_MAIN
    CFG_DIR.mkdir(parents=True, exist_ok=True)
    PS_PLAIN = PromptSession(style=PT_STYLE)
    PS_MAIN = PromptSession(history=FileHistory(str(CFG_DIR / "history")), style=PT_STYLE)


def ask(msg, password=False, default=""):
    try:
        return PS_PLAIN.prompt([("class:pt.q", " " + msg + " "), ("class:pt.mark", "❯ ")],
                               is_password=password)
    except (KeyboardInterrupt, EOFError):
        console.print()
        return default


def toolbar():
    c = CTX
    narrow = shutil.get_terminal_size((80, 24)).columns < 70

    def eff(role):
        ch = chain(c.cfg, c.sess, role)
        return short(ch[0]) if ch else "—"
    mode = "total" if c.sess["mode"] == "total" else "normal"
    parts = []
    if not narrow:
        parts += [("class:tb.k", " ◆ "), ("class:tb.v", " " + c.ws.name[:18] + " "), ("class:tb.sep", "│")]
    parts += [("class:tb.plan", " A "), ("class:tb.v", eff("plan")), ("class:tb.sep", " │"),
              ("class:tb.work", " O "), ("class:tb.v", eff("code")), ("class:tb.sep", " │"),
              ("class:tb.fast", " R "), ("class:tb.v", eff("fast"))]
    if not narrow:
        parts += [("class:tb.sep", " │ "), ("class:tb.mode", mode + " ")]
    return parts


def read_input():
    lines = []
    while True:
        mark = "❯ " if not lines else "… "
        try:
            t = PS_MAIN.prompt([("class:pt.mark", mark)], completer=SlashCompleter(),
                               complete_while_typing=True, bottom_toolbar=toolbar)
        except KeyboardInterrupt:
            if lines:
                console.print(Text("  entrada cancelada", style="muted"))
                return ""
            console.print(Text("  Ctrl+C no cierra Codex Mobile · usa /salir", style="muted"))
            return ""
        except EOFError:
            console.print(Text("  Ctrl+D no cierra Codex Mobile · usa /salir", style="muted"))
            return ""
        if t.endswith("\\"):
            lines.append(t[:-1])
            continue
        lines.append(t)
        return "\n".join(lines).strip()


# ───────────────────────── Pantalla de inicio ─────────────────────────
LETTERS = {
    "C": ("┏━╸", "┃  ", "┗━╸"), "O": ("┏━┓", "┃ ┃", "┗━┛"), "D": ("╺┳┓", " ┃┃", "╺┻┛"),
    "E": ("┏━╸", "┣╸ ", "┗━╸"), "X": ("╻ ╻", "╺╋╸", "╹ ╹"),
}


def banner(cfg=None):
    lines = ["", "", ""]
    for ch in "CODEX":
        for i in range(3):
            lines[i] += LETTERS[ch][i]
    w = len(lines[0])
    c1, c2 = (0x7d, 0xcf, 0xff), (0xbb, 0x9a, 0xf7)
    logo = Text()
    for li, ln in enumerate(lines):
        for ci, chx in enumerate(ln):
            f = (ci + li) / (w + 2)
            r, g, b = (int(c1[k] + (c2[k] - c1[k]) * f) for k in range(3))
            logo.append(chx, style=f"bold #{r:02x}{g:02x}{b:02x}")
        logo.append("\n")
    logo.rstrip()
    console.print()
    console.print(Align.center(logo))
    console.print(Align.center(Text("M O B I L E", style="bold #c0caf5")))
    console.print(Align.center(Text(f"agente de código multi-modelo · v{VERSION}", style="muted")))
    console.print()


def info_panel(ctx):
    t = Table.grid(padding=(0, 2))
    t.add_column(style="muted", no_wrap=True)
    t.add_column(overflow="fold")
    t.add_row("sesión", Text(ctx.ws.name, style="title"))
    t.add_row("carpeta", Text(str(ctx.ws), style="accent"))
    t.add_row("keys", Text(", ".join(PROVIDERS[p]["name"] for p in PROVIDERS if ctx.cfg["keys"].get(p)) or "—", style="ok"))
    for r in ("plan", "code", "fast"):
        ch = chain(ctx.cfg, ctx.sess, r)
        t.add_row(ROLE_NAME[r].lower(), Text(ch[0] if ch else "—", style=ROLE_STYLE[r]))
    t.add_row("modo", Text(ctx.sess["mode"] + ("  (pide permiso para comandos)" if ctx.sess["mode"] != "total" else "  (sin pedir permiso)"),
                           style="warn"))
    console.print(Panel(t, border_style="accent", box=ROUNDED, title=Text(" Listo ", style="bold accent"),
                        title_align="left", padding=(0, 1)))
    console.print(Text("  /ayuda comandos · !cmd shell directo · \\ al final = otra línea", style="muted"))
    console.print()


# ───────────────────────── API keys (asistente) ─────────────────────────
def test_key(pid, key):
    P = PROVIDERS[pid]
    h = {"User-Agent": UA}
    if P["kind"] == "anthropic":
        h.update({"x-api-key": key, "anthropic-version": "2023-06-01"})
    else:
        h["Authorization"] = "Bearer " + key
    try:
        http_json(P["url"] + "/models", h, None, timeout=20, method="GET")
        return True, "válida"
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace").lower()
        except Exception:
            pass
        if e.code in (401, 403) or (e.code == 400 and ("api key" in body or "api_key" in body)):
            return False, f"rechazada (HTTP {e.code})"
        return True, f"no verificable (HTTP {e.code})"
    except Exception:
        return None, "sin conexión para verificar"


def ask_key(cfg, pid, n=None, total=None, startup=False):
    P = PROVIDERS[pid]
    head = Text()
    if n:
        head.append(f"{n}/{total} ", style="accent")
    head.append(P["name"], style="title")
    if P.get("free"):
        head.append(f"  [{P['free']}]", style="ok")
    head.append("   " + P["hint"], style="muted")
    console.print(head)
    have = cfg["keys"].get(pid)
    if have:
        console.print(Text(f"   ✓ ya configurada ({mask(have)})  ·  Enter = mantener · '-' = borrar", style="ok"))
    elif startup:
        console.print(Text("   Pega tu key (no se ve) · Enter = omitir ahora · n = no preguntar más · t = terminar",
                           style="muted"))
    else:
        console.print(Text("   Pega tu key (no se ve al pegar) · Enter = omitir", style="muted"))
    k = ask("key", password=True).strip().strip("'\"")
    if startup and k.lower() in ("n", "t"):
        if k.lower() == "t":
            return "stop"
        if pid not in cfg["skip"]:
            cfg["skip"].append(pid)
        save_cfg(cfg)
        console.print(Text("   ok, no vuelvo a preguntar por este proveedor (puedes cambiarlo en /claves)", style="muted"))
        return None
    if not k:
        return None
    if k == "-":
        cfg["keys"].pop(pid, None)
        save_cfg(cfg)
        console.print(Text("   key eliminada", style="warn"))
        return None
    ok, msg = test_key(pid, k)
    if ok is False:
        console.print(Text(f"   ✗ {msg}", style="err"))
        if ask("¿Guardarla de todos modos? (s/N)", default="n").lower() not in ("s", "si", "sí", "y"):
            return None
    else:
        console.print(Text(f"   ✓ {msg}", style="ok" if ok else "warn"))
    cfg["keys"][pid] = k
    cfg["skip"] = [x for x in cfg["skip"] if x != pid]
    save_cfg(cfg)
    return None


def startup_keys(cfg):
    """Al iniciar: pide las keys que falten. Se puede omitir cualquiera; basta con tener una."""
    first = not has_any(cfg)
    while True:
        missing = [p for p in PROVIDERS if not cfg["keys"].get(p) and p not in cfg["skip"]]
        go = bool(missing) and first
        if missing and not first:
            names = ", ".join(PROVIDERS[p]["name"] for p in missing)
            console.print(Text(f"  Sin key: {names}", style="muted"))
            go = ask("¿Añadir keys ahora? (s/N)", default="n").strip().lower() in ("s", "si", "sí", "y")
            console.print()
        if go:
            if first:
                msg = ("Bienvenido. Pega las API keys que tengas, una por una.\n"
                       "Enter = omitir ese proveedor · con UNA sola key ya funciona.\n"
                       "Cada key extra suma más modelos (los gratis se ordenan primero).")
            else:
                msg = ("Enter = omitir por ahora · n = no preguntar más por ese proveedor · t = terminar.\n"
                       "Todo sigue funcionando con las keys que ya tienes.")
            console.print(Panel(Text(msg, style="title"), title=Text(" API keys ", style="bold accent"),
                                title_align="left", border_style="accent", box=ROUNDED))
            for n, pid in enumerate(missing, 1):
                if ask_key(cfg, pid, n, len(missing), startup=True) == "stop":
                    break
                console.print()
        if has_any(cfg):
            break
        console.print(Text("  Necesitas al menos una API key para empezar (todas son gratis: Gemini, Groq, OpenRouter, NVIDIA, Mistral, Ollama…).\n",
                           style="err"))
        if ask("Enter = volver a intentar · escribe 'salir' para cerrar", default="salir").strip().lower() in ("salir", "exit", "q"):
            sys.exit(78)
        cfg["skip"] = []
        first = True
        save_cfg(cfg)
    if first:
        console.print(Text("  ✓ Configuración guardada en ~/.codex-mobile/config.json (permisos 600)\n", style="ok"))


# ───────────────────────── Sesiones ─────────────────────────
def new_sess_dict(name):
    return {"name": name, "created": datetime.now().isoformat(timespec="seconds"),
            "models": {"plan": "auto", "code": "auto", "fast": "auto"}, "mode": "normal",
            "route": "auto", "router_mode": "auto", "review": True, "history": [], "tokens": [0, 0]}


def load_sess(ws):
    s = json.loads((ws / ".codex" / "session.json").read_text())
    base = new_sess_dict(ws.name)
    for k, v in base.items():
        s.setdefault(k, v)
    for r in ("plan", "code", "fast"):
        s["models"].setdefault(r, "auto")
    return s


def list_sessions():
    root = storage_root()
    out = []
    for d in root.iterdir():
        f = d / ".codex" / "session.json"
        if f.is_file():
            try:
                out.append((f.stat().st_mtime, d, load_sess(d)))
            except Exception:
                pass
    out.sort(key=lambda x: x[0], reverse=True)
    return out


def create_session(cfg):
    console.print(Text(" Nueva sesión", style="title"))
    name = ask("Nombre (Enter = que la IA lo elija por ti)").strip()
    if not name:
        desc = ask("¿De qué va a tratar? (una línea)").strip()
        fast = ranked(cfg, "fast")
        if desc and fast:
            try:
                with console.status(Text("nombrando sesión…", style="fast"), spinner="dots"):
                    t, _ = chat(cfg, fast[0], "Devuelve SOLO un nombre de carpeta de 2 a 3 palabras en minúsculas "
                                "separadas por guiones, sin explicación ni comillas.",
                                [{"role": "user", "content": desc}], timeout=40)
                name = clean_text(t).split("\n")[0]
            except Exception:
                name = ""
        if not name:
            name = "sesion-" + datetime.now().strftime("%m%d-%H%M")
    slug = slugify(name)
    root = storage_root()
    ws, i = root / slug, 2
    while ws.exists():
        ws = root / f"{slug}-{i}"
        i += 1
    (ws / ".codex").mkdir(parents=True)
    sess = new_sess_dict(ws.name)
    (ws / ".codex" / "session.json").write_text(json.dumps(sess, ensure_ascii=False, indent=1))
    console.print(Text(f"  ✓ carpeta creada: {ws}\n", style="ok"))
    return ws, sess


def sessions_table(items):
    t = Table(box=ROUNDED, border_style="muted", header_style="bold accent", expand=False)
    t.add_column("#", justify="right", style="accent")
    t.add_column("sesión", style="title")
    t.add_column("último uso", style="muted")
    t.add_column("msgs", justify="right", style="muted")
    for i, (mt, d, s) in enumerate(items, 1):
        t.add_row(str(i), d.name, datetime.fromtimestamp(mt).strftime("%d/%m %H:%M"), str(len(s["history"]) // 2))
    return t


def pick_session(cfg):
    while True:
        items = list_sessions()
        if not items:
            return create_session(cfg)
        console.print(Text(" Tus sesiones", style="title"))
        console.print(sessions_table(items))
        sel = ask("número · n = nueva · Enter = la última").strip().lower()
        if sel in ("n", "nueva"):
            return create_session(cfg)
        if sel == "":
            return items[0][1], items[0][2]
        if sel.isdigit() and 1 <= int(sel) <= len(items):
            return items[int(sel) - 1][1], items[int(sel) - 1][2]
        console.print(Text("  opción no válida", style="err"))


def switch_to(ctx, ws, sess):
    ctx.ws, ctx.sess, ctx.always = ws, sess, False
    ctx.save()
    console.print(Text(f"  ✓ sesión activa: {ws.name}", style="ok"))
    info_panel(ctx)


# ───────────────────────── Comandos ─────────────────────────
def models_table(ctx):
    t = Table(box=ROUNDED, border_style="muted", header_style="bold accent")
    t.add_column("rol")
    t.add_column("modelo")
    t.add_column("origen", style="muted")
    desc = {"plan": "planifica y ordena", "code": "ejecuta el trabajo", "fast": "consultas fáciles"}
    for r in ("plan", "code", "fast"):
        ch = chain(ctx.cfg, ctx.sess, r)
        manual = ctx.sess["models"][r] != "auto"
        t.add_row(Text(f"{ROLE_NAME[r]}", style=f"bold {ROLE_STYLE[r]}"),
                  Text(ch[0] if ch else "—", style=ROLE_STYLE[r]),
                  ("manual" if manual else "auto") + " · " + desc[r])
    return t


def cmd_modelos(ctx):
    console.print(models_table(ctx))
    r = ask("cambiar: a = arquitecto · o = obrero · r = rápido · u = buscar modelos nuevos · Enter = no").strip().lower()
    if r == "u":
        refresh_models(ctx.cfg, force=True)
        return
    role = {"a": "plan", "o": "code", "r": "fast"}.get(r)
    if not role:
        return
    opts = ranked(ctx.cfg, role)
    shown = opts[:20]
    t = Table(box=ROUNDED, border_style="muted", header_style="bold accent")
    t.add_column("#", style="accent", justify="right")
    t.add_column("modelo")
    t.add_column("aptitud", style="muted")
    t.add_row("0", Text("auto", style="ok"), "elige el mejor disponible")
    i = ROLE_IDX[role]
    score = {f"{c[0]}:{c[1]}": c[i] for c in CAT}
    for n, o in enumerate(shown, 1):
        t.add_row(str(n), o, f"{score[o]}/10")
    console.print(t)
    if len(opts) > len(shown):
        console.print(Text(f"  … y {len(opts) - len(shown)} más: escríbelo como proveedor:modelo", style="muted"))
    s = ask("número · o escribe proveedor:modelo (ej. groq:openai/gpt-oss-120b)").strip()
    val = None
    if s == "0":
        val = "auto"
    elif s.isdigit() and 1 <= int(s) <= len(shown):
        val = shown[int(s) - 1]
    elif ":" in s and s.split(":", 1)[0] in PROVIDERS and ctx.cfg["keys"].get(s.split(":", 1)[0]):
        val = s
    elif s:
        console.print(Text("  proveedor sin key o formato incorrecto", style="err"))
    if val:
        ctx.sess["models"][role] = val
        ctx.save()
        console.print(Text(f"  ✓ {ROLE_NAME[role]} → {val}", style="ok"))


def cmd_claves(ctx):
    t = Table(box=ROUNDED, border_style="muted", header_style="bold accent")
    t.add_column("#", style="accent", justify="right")
    t.add_column("proveedor", style="title")
    t.add_column("tipo", style="muted")
    t.add_column("key")
    for n, (pid, P) in enumerate(PROVIDERS.items(), 1):
        k = ctx.cfg["keys"].get(pid)
        if k:
            st = Text(mask(k), style="ok")
        else:
            st = Text("omitido" if pid in ctx.cfg["skip"] else "—", style="muted")
        t.add_row(str(n), P["name"], P.get("free") or "pago", st)
    console.print(t)
    s = ask("número para añadir/cambiar · Enter = volver").strip()
    if s.isdigit() and 1 <= int(s) <= len(PROVIDERS):
        ask_key(ctx.cfg, list(PROVIDERS)[int(s) - 1])
        refresh_models(ctx.cfg, quiet=True)


def cmd_agregar(ctx):
    console.print(Text(" Añadir proveedor compatible con OpenAI (cualquier servicio con /chat/completions)", style="title"))
    name = ask("Nombre (ej. Kilo, SiliconFlow, OVH)").strip()
    if not name:
        return
    url = ask("URL base (ej. https://api.siliconflow.com/v1)").strip().rstrip("/")
    if not url.startswith("http"):
        console.print(Text("  la URL debe empezar con http(s)://", style="err"))
        return
    key = ask("API key (Enter = sin key)", password=True).strip().strip("'\"")
    model = ask("Modelo por defecto (Enter = detectar solo)").strip()
    cid = "c-" + slugify(name)
    ctx.cfg["custom"][cid] = {"name": name, "url": url, "model": model}
    ctx.cfg["keys"][cid] = key or "sin-key"
    save_cfg(ctx.cfg)
    apply_custom(ctx.cfg)
    refresh_models(ctx.cfg, force=True)
    console.print(Text(f"  ✓ {name} añadido · aparece en /modelos y en /claves", style="ok"))


def cmd_ver(ctx, arg):
    base = rp(ctx, arg or ".")
    if not base.is_dir():
        console.print(Text("  no es una carpeta", style="err"))
        return
    tree = Tree(Text(base.name + "/", style="bold accent"))
    count = [0]

    def rec(node, d, lvl):
        try:
            ents = sorted(d.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except Exception:
            return
        for p in ents:
            if p.name in IGN or count[0] > 250:
                continue
            count[0] += 1
            if p.is_dir():
                sub = node.add(Text(p.name + "/", style="accent"))
                if lvl < 3:
                    rec(sub, p, lvl + 1)
            else:
                try:
                    sz = human(p.stat().st_size)
                except Exception:
                    sz = ""
                node.add(Text.assemble((p.name, ""), ("  " + sz, "muted")))

    rec(tree, base, 1)
    console.print(tree)


def cmd_config(ctx):
    s = ctx.sess
    t = Table.grid(padding=(0, 2))
    t.add_column(style="muted")
    t.add_column()
    t.add_row("sesión", s["name"])
    t.add_row("carpeta", str(ctx.ws))
    t.add_row("modo", s["mode"])
    t.add_row("ruta", s["route"])
    t.add_row("router", s.get("router_mode", "auto"))
    t.add_row("revisión", "on" if s["review"] else "off")
    for r in ("plan", "code", "fast"):
        t.add_row(ROLE_NAME[r].lower(), s["models"][r])
    t.add_row("mensajes", str(len(s["history"]) // 2))
    console.print(Panel(t, title=" Configuración de la sesión ", border_style="accent", box=ROUNDED))


def cmd_ayuda():
    t = Table(box=ROUNDED, border_style="muted", header_style="bold accent")
    t.add_column("comando", style="accent", no_wrap=True)
    t.add_column("qué hace")
    for c, d in COMMANDS.items():
        t.add_row(c, d)
    t.add_row("!cmd", "ejecuta un comando de shell en el workspace")
    console.print(t)
    console.print(Text("  Rutas: rápido (consulta fácil) · directo (obrero) · plan (arquitecto → obrero → revisión)\n"
                       "  Router: auto usa reglas locales, smart usa Groq si está configurado y manual respeta /ruta.", style="muted"))


def command(ctx, line):
    parts = line.split(None, 1)
    cmd, arg = parts[0].lower(), (parts[1].strip() if len(parts) > 1 else "")
    if cmd in ("/ayuda", "/help", "/?"):
        cmd_ayuda()
    elif cmd == "/salir":
        if ask("¿Salir de Codex Mobile? (s/N)", default="n").lower() in ("s", "si", "sí", "y"):
            ctx.save()
            return "exit"
    elif cmd == "/sesiones":
        ctx.save()
        ws, s = pick_session(ctx.cfg)
        switch_to(ctx, ws, s)
    elif cmd == "/nueva":
        ctx.save()
        ws, s = create_session(ctx.cfg)
        switch_to(ctx, ws, s)
    elif cmd == "/modelos":
        cmd_modelos(ctx)
    elif cmd == "/claves":
        cmd_claves(ctx)
    elif cmd == "/agregar":
        cmd_agregar(ctx)
    elif cmd == "/modo":
        new = arg.lower() or ("total" if ctx.sess["mode"] != "total" else "normal")
        if new in ("normal", "total"):
            ctx.sess["mode"] = new
            ctx.save()
            console.print(Text(f"  modo → {new}" + ("  (⚠ ejecuta todo sin preguntar)" if new == "total" else ""),
                               style="warn"))
        else:
            console.print(Text("  uso: /modo normal | total", style="err"))
    elif cmd == "/ruta":
        m = {"auto": "auto", "rapido": "fast", "rápido": "fast", "directo": "exec", "plan": "full", "full": "full"}
        if arg.lower() in m:
            ctx.sess["route"] = m[arg.lower()]
            ctx.sess["router_mode"] = "auto" if m[arg.lower()] == "auto" else "manual"
            ctx.save()
            console.print(Text(f"  ruta → {arg.lower()} · router {ctx.sess['router_mode']}", style="ok"))
        else:
            console.print(Text("  uso: /ruta auto | rapido | directo | plan", style="err"))
    elif cmd == "/router":
        mode = arg.lower()
        if mode in ("auto", "manual", "smart"):
            ctx.sess["router_mode"] = mode
            if mode == "manual" and ctx.sess.get("route") == "auto":
                ctx.sess["route"] = "exec"
            ctx.save()
            console.print(Text(f"  router → {mode}" + (" (Groq GPT-OSS-20B; fallback local)" if mode == "smart" else ""),
                               style="ok"))
        else:
            console.print(Text("  uso: /router auto | manual | smart", style="err"))
    elif cmd == "/rollback":
        cmd_rollback(ctx, arg)
    elif cmd == "/revision":
        ctx.sess["review"] = arg.lower() not in ("off", "no", "0")
        ctx.save()
        console.print(Text(f"  revisión → {'on' if ctx.sess['review'] else 'off'}", style="ok"))
    elif cmd == "/plan":
        pf = ctx.ws / ".codex" / "PLAN.md"
        if pf.exists():
            answer_panel(pf.read_text(errors="replace"), "Plan actual", "plan")
        else:
            console.print(Text("  aún no hay plan (se crea en la ruta 'plan')", style="muted"))
    elif cmd == "/ver":
        cmd_ver(ctx, arg)
    elif cmd == "/costo":
        console.print(Text(f"  tokens entrada {ctx.sess['tokens'][0]:,} · salida {ctx.sess['tokens'][1]:,}", style="accent"))
    elif cmd == "/limpiar":
        ctx.sess["history"] = []
        ctx.save()
        console.clear()
        info_panel(ctx)
    elif cmd == "/copiar":
        if ctx.last_answer and shutil.which("termux-clipboard-set"):
            subprocess.run(["termux-clipboard-set"], input=ctx.last_answer.encode(), timeout=10)
            console.print(Text("  ✓ copiado al portapapeles", style="ok"))
        else:
            console.print(Text("  necesita Termux:API (pkg install termux-api) y una respuesta previa", style="warn"))
    elif cmd == "/config":
        cmd_config(ctx)
    else:
        console.print(Text(f"  comando desconocido: {cmd} · /ayuda", style="err"))
    return None


# ───────────────────────── Programa principal ─────────────────────────
def main():
    global CTX
    try:
        signal.signal(signal.SIGTSTP, signal.SIG_IGN)
    except Exception:
        pass
    init_prompts()
    cfg = load_cfg()
    apply_custom(cfg)
    console.clear()
    banner()
    startup_keys(cfg)
    refresh_models(cfg)
    ws, sess = pick_session(cfg)
    CTX = Ctx(cfg, ws, sess)
    CTX.save()
    console.clear()
    banner()
    info_panel(CTX)
    while True:
        try:
            line = read_input()
            if not line:
                continue
            if line.startswith("!"):
                try:
                    result = t_run(CTX, {"command": line[1:].strip(), "timeout": "300"})
                    head, _, out = result.partition("\n")
                    console.print(Text(out, style="muted"))
                    console.print(Text(f"  {head}", style="ok" if head == "exit=0" else "err"))
                except ToolError as e:
                    console.print(Text(f"  {e}", style="warn"))
            elif line.startswith("/"):
                if command(CTX, line) == "exit":
                    break
            else:
                if not chain(CTX.cfg, CTX.sess, "fast"):
                    console.print(Text("  No hay API keys configuradas · usa /claves", style="err"))
                    continue
                turn(CTX, line)
            console.print()
        except KeyboardInterrupt:
            console.print(Text("\n  ■ interrumpido", style="warn"))
        except Exception as e:  # la sesión nunca se cae
            console.print(Panel(Text(f"{type(e).__name__}: {e}"), title=" Error interno (la sesión sigue) ",
                                border_style="err", box=ROUNDED))
    console.print(Text("\n  Sesión guardada. Termux sigue abierto · vuelve con: codex-mobile\n", style="muted"))
    sys.exit(0)


if __name__ == "__main__":
    main()
PYEOF
python3 -m py_compile "$HOME/.codex-mobile/codex_mobile.py"

# ── Lanzador: la sesión NO se cierra ──────────────────────────
cat > "$PREFIX/bin/codex-mobile" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
# Mantiene el teléfono despierto y reinicia Codex Mobile si algo lo tumba.
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
export PYTHONIOENCODING=utf-8 COLORTERM=truecolor TERM="${TERM:-xterm-256color}"
trap '' HUP TSTP                                  # ignora cierre de terminal y Ctrl+Z
APP="$HOME/.codex-mobile/codex_mobile.py"

# Modo persistente: codex-mobile --tmux  → sobrevive aunque cierres Termux; vuelve a entrar con el mismo comando
if [ "$1" = "--tmux" ]; then
  shift
    tmux new-session -A -s codex "codex-mobile $*"
fi

while true; do
  python3 "$APP" "$@"
  code=$?
  if [ "$code" -eq 0 ] || [ "$code" -eq 78 ]; then break; fi
  echo -e "\n\e[33m⚠ Codex Mobile se cerró inesperadamente (código $code). Reiniciando en 3 s… (Ctrl+C = cancelar)\e[0m"
  sleep 3 || break
done
command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
echo "Sesión de Termux abierta. Vuelve cuando quieras con:  codex-mobile"
LAUNCH
chmod +x "$PREFIX/bin/codex-mobile"
ln -sf "$PREFIX/bin/codex-mobile" "$PREFIX/bin/cm"

echo
say "${C2}Instalación completa.${R}  Comandos:  ${C3}codex-mobile${R}  o  ${C3}cm${R}   (persistente: ${C3}cm --tmux${R})"
echo "   Al iniciar te pedirá las API keys que falten (puedes omitir las que no tengas)."
echo "   Consejo: desactiva la optimización de batería para Termux en Ajustes de Android."
echo
sleep 1
# La sesión queda abierta: se lanza Codex Mobile y, al salir, sigues en Termux.
codex-mobile || true
