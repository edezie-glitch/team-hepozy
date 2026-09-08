
import os
import json
import time
import asyncio
import logging
from datetime import datetime, timezone, timedelta

from fastapi import FastAPI, HTTPException, Header, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, EmailStr

from security     import hash_password, verify_password, create_token, decode_token
from db           import supabase
from orchestrator import orchestrate

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("hepozy")

app = FastAPI(title="Hepozy API", version="2.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

OLLAMA_URL   = os.environ.get("OLLAMA_URL",   "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3")

TOKEN_LIMIT        = 5000
WINDOW_HOURS       = 10



async def _run_sync(fn, *args, **kwargs):
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, lambda: fn(*args, **kwargs))




def _get_usage_sync(user_id: str) -> dict:
    """Reads tokens_used_window and window_started_at for this user."""
    row = supabase.table("users") \
        .select("tokens_used_window, window_started_at") \
        .eq("id", user_id).single().execute().data
    return row or {"tokens_used_window": 0, "window_started_at": None}


def _reset_window_sync(user_id: str):
    supabase.table("users").update({
        "tokens_used_window": 0,
        "window_started_at": datetime.now(timezone.utc).isoformat(),
    }).eq("id", user_id).execute()


def _increment_usage_sync(user_id: str, tokens: int):
    row = supabase.table("users") \
        .select("tokens_used_window") \
        .eq("id", user_id).single().execute().data
    current = (row or {}).get("tokens_used_window", 0)
    supabase.table("users").update({
        "tokens_used_window": current + tokens,
    }).eq("id", user_id).execute()


async def check_usage_limit(user_id: str) -> tuple[bool, str]:
    """
    Returns (allowed, message).
    allowed=False means the user has hit TOKEN_LIMIT within the current
    WINDOW_HOURS window — message is the exact plain-text sentence to
    send back to the frontend, nothing else.
    """
    usage = await _run_sync(_get_usage_sync, user_id)
    used  = usage.get("tokens_used_window", 0)
    started_raw = usage.get("window_started_at")

    now = datetime.now(timezone.utc)

    if started_raw:
        started = datetime.fromisoformat(started_raw.replace("Z", "+00:00"))
        elapsed = now - started
    else:
        elapsed = timedelta(hours=WINDOW_HOURS + 1)  # force a reset below

    # Window expired — reset and allow.
    if elapsed >= timedelta(hours=WINDOW_HOURS):
        await _run_sync(_reset_window_sync, user_id)
        return True, ""

    # Window active — check the cap.
    if used >= TOKEN_LIMIT:
        remaining_time = timedelta(hours=WINDOW_HOURS) - elapsed
        hours   = int(remaining_time.total_seconds() // 3600)
        minutes = int((remaining_time.total_seconds() % 3600) // 60)
        return False, f"You don't have enough tokens left. Come back in {hours}h {minutes}m."

    return True, ""


async def record_usage(user_id: str, total_tokens: int):
    await _run_sync(_increment_usage_sync, user_id, total_tokens)


# ══════════════════════════════════════════════════════════════════════
# AUTH DEPENDENCY
# ══════════════════════════════════════════════════════════════════════

def get_current_user(authorization: str = Header(...)) -> dict:
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid token")
    token = authorization.split(" ", 1)[1]
    try:
        return decode_token(token)
    except Exception:
        raise HTTPException(status_code=401, detail="Token invalid or expired")


# ══════════════════════════════════════════════════════════════════════
# SCHEMAS
# ══════════════════════════════════════════════════════════════════════

class SignupRequest(BaseModel):
    email: EmailStr
    username: str
    password: str

class LoginRequest(BaseModel):
    username: str
    password: str

class ChatRequest(BaseModel):
    conversation_id: str
    message: str

class TitleRequest(BaseModel):
    title: str


# ══════════════════════════════════════════════════════════════════════
# HEALTH
# ══════════════════════════════════════════════════════════════════════

@app.get("/")
def root():
    return {"status": "Hepozy API v2 running"}


# ══════════════════════════════════════════════════════════════════════
# AUTH
# ══════════════════════════════════════════════════════════════════════

@app.post("/auth/signup")
async def signup(body: SignupRequest):
    def _check_and_create():
        if supabase.table("users").select("id").eq("username", body.username).execute().data:
            return None, "Username already taken"
        if supabase.table("users").select("id").eq("email", body.email).execute().data:
            return None, "Email already registered"
        hashed = hash_password(body.password)
        user = supabase.table("users").insert({
            "email": body.email, "username": body.username, "password": hashed,
        }).execute().data[0]
        return user, None

    user, err = await _run_sync(_check_and_create)
    if err:
        raise HTTPException(status_code=400, detail=err)

    token = create_token({"sub": user["id"], "username": user["username"]})
    return {"token": token, "username": user["username"]}


@app.post("/auth/login")
async def login(body: LoginRequest):
    def _query():
        return supabase.table("users").select("*").eq("username", body.username).execute().data

    rows = await _run_sync(_query)
    if not rows:
        raise HTTPException(status_code=401, detail="Invalid username or password")
    user = rows[0]
    if not verify_password(body.password, user["password"]):
        raise HTTPException(status_code=401, detail="Invalid username or password")
    token = create_token({"sub": user["id"], "username": user["username"]})
    return {"token": token, "username": user["username"]}


# ══════════════════════════════════════════════════════════════════════
# CONVERSATIONS
# ══════════════════════════════════════════════════════════════════════

@app.post("/chat/conversations/new")
async def new_conversation(user: dict = Depends(get_current_user)):
    def _insert():
        return supabase.table("conversations").insert({
            "user_id": user["sub"], "title": "New conversation",
        }).execute()

    result = await _run_sync(_insert)
    return {"conversation": result.data[0]}


@app.get("/chat/conversations")
async def list_conversations(user: dict = Depends(get_current_user)):
    def _query():
        return supabase.table("conversations") \
            .select("id, title, created_at") \
            .eq("user_id", user["sub"]) \
            .order("created_at", desc=True) \
            .execute()

    result = await _run_sync(_query)
    return {"conversations": result.data}


@app.patch("/chat/conversations/{conversation_id}/title")
async def update_title(conversation_id: str, payload: TitleRequest,
                       user: dict = Depends(get_current_user)):
    def _update():
        supabase.table("conversations") \
            .update({"title": payload.title}) \
            .eq("id", conversation_id).eq("user_id", user["sub"]).execute()

    await _run_sync(_update)
    return {"ok": True}


@app.delete("/chat/conversations/{conversation_id}")
async def delete_conversation(conversation_id: str,
                              user: dict = Depends(get_current_user)):
    def _delete():
        supabase.table("messages").delete().eq("conversation_id", conversation_id).execute()
        supabase.table("conversations").delete() \
            .eq("id", conversation_id).eq("user_id", user["sub"]).execute()

    await _run_sync(_delete)
    return {"ok": True}


@app.get("/chat/history/{conversation_id}")
async def get_history(conversation_id: str,
                      user: dict = Depends(get_current_user)):
    def _query():
        return supabase.table("messages") \
            .select("role, content, created_at") \
            .eq("conversation_id", conversation_id) \
            .order("created_at", desc=False).execute()

    result = await _run_sync(_query)
    return {"messages": result.data}


# ══════════════════════════════════════════════════════════════════════
# CHAT — SEND MESSAGE (orchestrated SSE streaming)
# ══════════════════════════════════════════════════════════════════════

async def _load_memory(conversation_id: str) -> list:
    def _query():
        return supabase.table("messages") \
            .select("role, content") \
            .eq("conversation_id", conversation_id) \
            .order("created_at", desc=False) \
            .limit(10).execute().data or []

    return await _run_sync(_query)


def _save_message_sync(conversation_id: str, user_id: str, role: str, content: str):
    supabase.table("messages").insert({
        "conversation_id": conversation_id,
        "user_id":         user_id,
        "role":            role,
        "content":         content,
    }).execute()


@app.post("/chat/send")
async def send_message(
    body: ChatRequest,
    user: dict = Depends(get_current_user),
):
    query           = body.message.strip()
    conversation_id = body.conversation_id
    user_id         = user["sub"]

    if not query:
        raise HTTPException(status_code=400, detail="Empty message")

    # Usage limit check — separate from num_ctx (per-request context cap
    # in orchestrator.py). This is a cumulative, cross-message counter.
    allowed, limit_message = await check_usage_limit(user_id)
    if not allowed:
        async def limit_stream():
            payload = json.dumps({"type": "reply", "token": limit_message})
            yield f"data: {payload}\n\n"
            yield "data: [DONE]\n\n"
        return StreamingResponse(
            limit_stream(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    t0 = time.monotonic()
    log.info(f"[send] received | conv={conversation_id} | query={query[:60]!r}")

    memory = await _load_memory(conversation_id)
    log.info(f"[send] memory loaded (+{time.monotonic() - t0:.2f}s)")

    queue: asyncio.Queue = asyncio.Queue()

    async def save_fn(role: str, content: str):
        await _run_sync(_save_message_sync, conversation_id, user_id, role, content)

    async def stream_fn(event_type: str, token: str):
        # Intercept token_usage events to record real cumulative usage
        # against this user's rolling window, in addition to forwarding
        # the event downstream as before.
        if event_type == "token_usage":
            try:
                stats = json.loads(token)
                await record_usage(user_id, stats.get("total_tokens", 0))
            except (json.JSONDecodeError, KeyError):
                pass
        await queue.put((event_type, token))

    async def run_orchestrator():
        try:
            first_token_logged = False
            async def logged_stream_fn(event_type, token):
                nonlocal first_token_logged
                if event_type == "reply" and not first_token_logged:
                    log.info(f"[send] first token (+{time.monotonic() - t0:.2f}s)")
                    first_token_logged = True
                await stream_fn(event_type, token)

            await orchestrate(query, memory, save_fn, logged_stream_fn)
            log.info(f"[send] done (+{time.monotonic() - t0:.2f}s)")
        except Exception as e:
            log.exception("[send] orchestrator raised")
            await queue.put(("error", str(e)))
        finally:
            await queue.put(("__end__", ""))

    asyncio.create_task(run_orchestrator())

    async def stream():
        while True:
            event_type, token = await queue.get()
            if event_type == "__end__":
                yield "data: [DONE]\n\n"
                break
            payload = json.dumps({"type": event_type, "token": token})
            yield f"data: {payload}\n\n"

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ══════════════════════════════════════════════════════════════════════
# PDF GENERATION — only when user explicitly requests it
# ══════════════════════════════════════════════════════════════════════

@app.get("/chat/export/{conversation_id}")
async def export_pdf(conversation_id: str,
                     user: dict = Depends(get_current_user)):
    """
    Returns full conversation as structured JSON for PDF generation.
    Frontend renders and downloads the PDF.
    """
    def _query():
        messages = supabase.table("messages") \
            .select("role, content, created_at") \
            .eq("conversation_id", conversation_id) \
            .order("created_at", desc=False).execute()
        conv = supabase.table("conversations") \
            .select("title") \
            .eq("id", conversation_id) \
            .execute().data
        return messages, conv

    result, conv = await _run_sync(_query)
    title = conv[0]["title"] if conv else "Conversation"

    return {
        "title":    title,
        "messages": result.data,
    }


# ══════════════════════════════════════════════════════════════════════
# RUN
# ══════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("letigo:app", host="0.0.0.0", port=8001, reload=True)