import asyncio
import json
import os
import re
import logging
import httpx
from rank_bm25 import BM25Okapi
from bs4 import BeautifulSoup

log = logging.getLogger("hepozy")

OLLAMA_URL   = os.environ.get("OLLAMA_URL",   "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3")
NEWSAPI_KEY  = os.environ.get("NEWSAPI_KEY",  "")
GNEWS_KEY    = os.environ.get("GNEWS_KEY",    "")

# Single source of truth for how long we'll wait on Ollama before giving up.
# Was 120s (unbounded-feeling, silent). 30s is generous for a 3B model at
# ~14 tok/s on CPU (30s @ 14 tok/s ≈ 420 tokens of headroom before this
# fires) but caps the worst case so the frontend timeout (30s, see home.js)
# and this backend timeout roughly line up. Tune both together.
OLLAMA_TIMEOUT = 30

# ── INTENT DETECTION ─────────────────────────────────────────────────

INTENT_PATTERNS = {
    "instructions": [
        r"\bhow (do|to|can|should)\b",
        r"\bsteps?\b", r"\bguide\b", r"\btutorial\b",
        r"\bwalkthrough\b", r"\bprocedure\b", r"\bprocess\b",
    ],
    "workflow": [
        r"\bworkflow\b", r"\bpipeline\b", r"\bsequence\b",
        r"\bflowchart\b", r"\bdiagram\b", r"\barchitecture\b",
        r"\bsystem\b", r"\bstructure\b",
    ],
    "examples": [
        r"\bexample\b", r"\bsample\b", r"\binstance\b",
        r"\bshow me\b", r"\bdemonstrate\b", r"\billustrate\b",
        r"\buse case\b",
    ],
    "pdf": [
        r"\bpdf\b", r"\bexport\b", r"\bdownload\b",
        r"\bdocument\b", r"\breport\b", r"\bsave (as|to)\b",
    ],
}

def detect_intent(query: str) -> dict:
    """
    Returns which output types to generate.
    Always includes 'reply'. Others ONLY if the query's own wording
    matches a known intent keyword pattern.
    PDF is NEVER generated unless explicitly requested.
    """
    q = query.lower()
    intents = {"reply": True, "instructions": False, "workflow": False,
               "examples": False, "pdf": False}

    for intent, patterns in INTENT_PATTERNS.items():
        if any(re.search(p, q) for p in patterns):
            intents[intent] = True

    return intents


# ── FETCH ─────────────────────────────────────────────────────────────

async def _fetch(client: httpx.AsyncClient, url: str, params: dict) -> dict:
    try:
        r = await client.get(url, params=params, timeout=6)
        return r.json() if r.status_code == 200 else {}
    except Exception:
        return {}

async def fetch_newsapi(query: str, client: httpx.AsyncClient) -> list[str]:
    if not NEWSAPI_KEY:
        return []
    data = await _fetch(client, "https://newsapi.org/v2/everything", {
        "q": query, "pageSize": 4, "sortBy": "relevancy",
        "language": "en", "apiKey": NEWSAPI_KEY,
    })
    return [
        " ".join(filter(None, [a.get("title", ""), a.get("description", ""), a.get("content", "")]))
        for a in data.get("articles", [])
    ]

async def fetch_gnews(query: str, client: httpx.AsyncClient) -> list[str]:
    if not GNEWS_KEY:
        return []
    data = await _fetch(client, "https://gnews.io/api/v4/search", {
        "q": query, "max": 4, "lang": "en", "token": GNEWS_KEY,
    })
    return [a.get("title", "") + " " + a.get("description", "")
            for a in data.get("articles", [])]

async def fetch_wikipedia(query: str, client: httpx.AsyncClient) -> list[str]:
    try:
        r = await client.get(
            "https://en.wikipedia.org/api/rest_v1/page/summary/" + query.replace(" ", "_"),
            timeout=5,
        )
        extract = r.json().get("extract", "")
        return [extract] if extract else []
    except Exception:
        return []

async def fetch_all(query: str) -> list[str]:
    async with httpx.AsyncClient() as client:
        results = await asyncio.gather(
            fetch_newsapi(query, client),
            fetch_gnews(query, client),
            fetch_wikipedia(query, client),
            return_exceptions=True,
        )
    combined = []
    for r in results:
        if isinstance(r, list):
            combined.extend(r)
    return [t for t in combined if t and t.strip()]


# ── CLEAN + CHUNK + RANK ──────────────────────────────────────────────

def clean(raw: str) -> str:
    soup = BeautifulSoup(raw, "html.parser")
    return re.sub(r'\s+', ' ', soup.get_text(separator=" ")).strip()

def chunk(text: str, max_words: int = 100) -> list[str]:
    sentences = re.split(r'(?<=[.!?])\s+', text)
    chunks, cur, count = [], [], 0
    for s in sentences:
        words = s.split()
        if count + len(words) > max_words and cur:
            chunks.append(" ".join(cur))
            cur, count = [], 0
        cur.extend(words)
        count += len(words)
    if cur:
        chunks.append(" ".join(cur))
    return [c for c in chunks if len(c.split()) > 6]

def rank(query: str, chunks: list[str], top_k: int = 6) -> list[str]:
    if not chunks:
        return []
    bm25   = BM25Okapi([c.lower().split() for c in chunks])
    scores = bm25.get_scores(query.lower().split())
    ranked = sorted(zip(scores, chunks), reverse=True)
    return [c for _, c in ranked[:top_k]]

async def build_context(query: str) -> str:
    """Fetch + clean + chunk + rank. Runs once, reused by all pipelines."""
    raws   = await fetch_all(query)
    chunks = []
    for r in raws:
        chunks.extend(chunk(clean(r)))
    top = rank(query, chunks, top_k=6)
    return "\n\n".join(top) if top else ""


# ── PROMPT BUILDERS ───────────────────────────────────────────────────

SYSTEM = (
    "You are Hepozy, an advanced AI research and reasoning assistant. "
    "You are highly knowledgeable, precise, and educational. "
    "Use the provided context when available. "
    "Be thorough, structured, and clear. "
    "Never say you cannot help — always provide the best possible answer."
)

def _base_messages(context: str, memory: list[dict]) -> list[dict]:
    msgs = [{"role": "system", "content": SYSTEM}]
    msgs.extend(memory[-6:])  # last 6 turns for speed
    return msgs

def prompt_reply(query: str, context: str, memory: list[dict]) -> list[dict]:
    msgs = _base_messages(context, memory)
    content = query
    if context:
        content = (
            f"Context from real-time research:\n{context}\n\n"
            f"Question: {query}\n\n"
            f"Provide a comprehensive, well-structured answer."
        )
    msgs.append({"role": "user", "content": content})
    return msgs

def prompt_instructions(query: str, context: str, memory: list[dict]) -> list[dict]:
    msgs = _base_messages(context, memory)
    content = (
        f"{'Context: ' + context + chr(10) + chr(10) if context else ''}"
        f"Question: {query}\n\n"
        f"Provide clear, numbered step-by-step instructions. "
        f"Each step should be actionable and specific. "
        f"Format: Step 1: ... Step 2: ... etc."
    )
    msgs.append({"role": "user", "content": content})
    return msgs

def prompt_workflow(query: str, context: str, memory: list[dict]) -> list[dict]:
    msgs = _base_messages(context, memory)
    content = (
        f"{'Context: ' + context + chr(10) + chr(10) if context else ''}"
        f"Topic: {query}\n\n"
        f"Explain the workflow or process involved. "
        f"Describe each stage clearly: what happens, why it happens, and what comes next. "
        f"Use clear transitions between stages."
    )
    msgs.append({"role": "user", "content": content})
    return msgs

def prompt_examples(query: str, context: str, memory: list[dict]) -> list[dict]:
    msgs = _base_messages(context, memory)
    content = (
        f"{'Context: ' + context + chr(10) + chr(10) if context else ''}"
        f"Topic: {query}\n\n"
        f"Provide 2-3 concrete, worked examples that illustrate this topic. "
        f"Each example should be realistic and clearly explained."
    )
    msgs.append({"role": "user", "content": content})
    return msgs


# ── OLLAMA STREAM ─────────────────────────────────────────────────────

async def stream_ollama(messages: list[dict], stats: dict | None = None):
    """
    Generator that yields tokens from Ollama as fast as possible.
    Uses a single persistent httpx stream connection.

    Timeout tightened from 120s -> OLLAMA_TIMEOUT (30s). At ~14 tok/s on
    CPU that's still ~400+ tokens of headroom for a single generation
    call. If it fires, something is actually stuck (Ollama unresponsive,
    model swapping to disk, etc.) — not just "the model is thinking."

    TOKEN COUNTING: Ollama's final streamed line (where "done": true)
    includes exact counts — prompt_eval_count (tokens the model read: system
    prompt + memory + RAG context + user message) and eval_count (tokens it
    generated for the reply). These are the model's own real numbers, not
    an estimate. If a `stats` dict is passed in, this fills it with
    prompt_tokens / reply_tokens / total_tokens / num_ctx so the caller can
    log or stream real token usage instead of guessing with a word-count
    approximation.
    """
    try:
        async with httpx.AsyncClient(timeout=OLLAMA_TIMEOUT) as client:
            async with client.stream(
                "POST",
                f"{OLLAMA_URL}/api/chat",
                json={
                    "model":   OLLAMA_MODEL,
                    "messages": messages,
                    "stream":  True,
                    "options": {
                        "num_predict": 1024,
                        # Without this, Ollama defaults toward the model's
                        # max supported context (128K for Llama 3.2) and
                        # pre-allocates a KV cache sized for THAT, not your
                        # actual message — this was the ~14GB allocation
                        # failure. 4096 tokens is ample for chat history +
                        # RAG context + reply, and keeps memory use sane.
                        "num_ctx":     4096,
                        "temperature": 0.7,
                        "top_p":       0.9,
                        "repeat_penalty": 1.1,
                    },
                },
            ) as response:
                async for line in response.aiter_lines():
                    if not line.strip():
                        continue
                    try:
                        data  = json.loads(line)
                        token = data.get("message", {}).get("content", "")
                        if token:
                            yield token

                        # The last chunk of a streamed response has
                        # "done": true and carries the real token counts.
                        if data.get("done") and stats is not None:
                            prompt_tokens = data.get("prompt_eval_count", 0)
                            reply_tokens  = data.get("eval_count", 0)
                            stats["prompt_tokens"] = prompt_tokens
                            stats["reply_tokens"]  = reply_tokens
                            stats["total_tokens"]  = prompt_tokens + reply_tokens
                            stats["num_ctx"]       = 4096

                    except json.JSONDecodeError:
                        continue
    except httpx.TimeoutException:
        yield "\n[Error: Ollama took too long to respond (timeout). Check that the Ollama server is running and not overloaded.]"
    except httpx.ConnectError:
        yield "\n[Error: Could not connect to Ollama. Is the server running at " + OLLAMA_URL + "?]"
    except Exception as e:
        yield f"\n[Error: {str(e)}]"


# ── MAIN ORCHESTRATOR ─────────────────────────────────────────────────

async def orchestrate(
    query: str,
    memory: list[dict],
    save_fn,        # callable(role, content) — saves to DB
    stream_fn,      # callable(event_type, token) — sends to frontend
):
    """
    Main entry point. Called from letigo.py /chat/send endpoint.

    Flow:
      1. Detect intent (which outputs to generate) — keyword-based only
      2. Fetch + build context (once, shared) — capped at 5s
      3. Stream primary reply immediately
      4. If intent signals it, stream supplementary outputs after
      5. Save full reply to DB

    stream_fn receives: (event_type: str, token: str)
      event_type = "reply" | "instructions" | "workflow" | "examples" | "done" | "error"
    """
    # 1. Detect what outputs are needed
    intents = detect_intent(query)

    # 2. Build shared context (RAG) — 5s cap keeps this from stalling the
    #    whole pipeline if NewsAPI/GNews/Wikipedia are slow or down.
    context_task = asyncio.create_task(build_context(query))
    try:
        context = await asyncio.wait_for(context_task, timeout=5.0)
    except asyncio.TimeoutError:
        context = ""

    # 3. Save user message
    await save_fn("user", query)

    full_reply = ""

    # ── PRIMARY REPLY (always) ──────────────────────────────────────
    await stream_fn("reply_start", "")
    messages = prompt_reply(query, context, memory)
    stats: dict = {}
    async for token in stream_ollama(messages, stats):
        full_reply += token
        await stream_fn("reply", token)
    await stream_fn("reply_end", "")

    # Real token usage, straight from Ollama's own count — not an estimate.
    # NUM_CTX (4096) is the hard ceiling; prompt_tokens is everything sent
    # in (system + memory + RAG context + user message), reply_tokens is
    # what came back. If total_tokens gets close to 4096, the model is
    # running out of room and will start truncating/forgetting context.
    if stats:
        used      = stats.get("total_tokens", 0)
        remaining = 4096 - used
        log.info(
            f"[tokens] prompt={stats.get('prompt_tokens', 0)} "
            f"reply={stats.get('reply_tokens', 0)} "
            f"total={used}/4096 (remaining={remaining})"
        )
        if remaining < 300:
            log.warning(f"[tokens] budget nearly exhausted — {remaining} tokens left of 4096")
        await stream_fn("token_usage", json.dumps(stats | {"remaining": remaining, "num_ctx": 4096}))

    await save_fn("assistant", full_reply)

    # ── INSTRUCTIONS (only if keyword-matched) ──────────────────────
    if intents["instructions"]:
        instructions_text = ""
        await stream_fn("instructions_start", "")
        messages = prompt_instructions(query, context, memory)
        async for token in stream_ollama(messages):
            instructions_text += token
            await stream_fn("instructions", token)
        await stream_fn("instructions_end", "")

    # ── WORKFLOW (only if keyword-matched) ──────────────────────────
    if intents["workflow"]:
        workflow_text = ""
        await stream_fn("workflow_start", "")
        messages = prompt_workflow(query, context, memory)
        async for token in stream_ollama(messages):
            workflow_text += token
            await stream_fn("workflow", token)
        await stream_fn("workflow_end", "")

    # ── EXAMPLES (only if keyword-matched) ────────────────────────
    if intents["examples"]:
        examples_text = ""
        await stream_fn("examples_start", "")
        messages = prompt_examples(query, context, memory)
        async for token in stream_ollama(messages):
            examples_text += token
            await stream_fn("examples", token)
        await stream_fn("examples_end", "")

    # ── DONE ────────────────────────────────────────────────────────
    await stream_fn("done", "")