import os
import re
import asyncio
import httpx
from bs4 import BeautifulSoup
from rank_bm25 import BM25Okapi

NEWSAPI_KEY = os.environ.get("NEWSAPI_KEY", "")
GNEWS_KEY   = os.environ.get("GNEWS_KEY",   "")


# ── FETCH ────────────────────────────────────────────────────────────

async def fetch_newsapi(query: str) -> list:
    if not NEWSAPI_KEY:
        return []
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            r = await client.get(
                "https://newsapi.org/v2/everything",
                params={
                    "q":        query,
                    "pageSize": 5,
                    "sortBy":   "relevancy",
                    "language": "en",
                    "apiKey":   NEWSAPI_KEY,
                },
            )
            articles = r.json().get("articles", [])
        return [
            " ".join(filter(None, [
                a.get("title",       ""),
                a.get("description", ""),
                a.get("content",     ""),
            ]))
            for a in articles
        ]
    except Exception:
        return []


async def fetch_gnews(query: str) -> list:
    if not GNEWS_KEY:
        return []
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            r = await client.get(
                "https://gnews.io/api/v4/search",
                params={"q": query, "max": 5, "lang": "en", "token": GNEWS_KEY},
            )
            articles = r.json().get("articles", [])
        return [
            a.get("title", "") + " " + a.get("description", "")
            for a in articles
        ]
    except Exception:
        return []


async def fetch_wikipedia(query: str) -> list:
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            r = await client.get(
                "https://en.wikipedia.org/api/rest_v1/page/summary/"
                + query.replace(" ", "_")
            )
            extract = r.json().get("extract", "")
        return [extract] if extract else []
    except Exception:
        return []


async def fetch_all(query: str) -> list:
    results = await asyncio.gather(
        fetch_newsapi(query),
        fetch_gnews(query),
        fetch_wikipedia(query),
    )
    combined = []
    for source in results:
        combined.extend(source)
    return [t for t in combined if t.strip()]


# ── CLEAN ────────────────────────────────────────────────────────────

def clean_text(raw: str) -> str:
    soup = BeautifulSoup(raw, "html.parser")
    text = soup.get_text(separator=" ")
    return re.sub(r"\s+", " ", text).strip()


# ── CHUNK ────────────────────────────────────────────────────────────

def chunk_text(text: str, max_words: int = 120) -> list:
    sentences = re.split(r"(?<=[.!?])\s+", text)
    chunks, current, count = [], [], 0
    for sentence in sentences:
        words = sentence.split()
        if count + len(words) > max_words and current:
            chunks.append(" ".join(current))
            current, count = [], 0
        current.extend(words)
        count += len(words)
    if current:
        chunks.append(" ".join(current))
    return [c for c in chunks if len(c.split()) > 8]


# ── RANK ─────────────────────────────────────────────────────────────

def rank_chunks(query: str, chunks: list, top_k: int = 5) -> list:
    if not chunks:
        return []
    tokenized = [c.lower().split() for c in chunks]
    bm25      = BM25Okapi(tokenized)
    scores    = bm25.get_scores(query.lower().split())
    ranked    = sorted(zip(scores, chunks), reverse=True)
    return [chunk for _, chunk in ranked[:top_k]]


# ── FULL PIPELINE ────────────────────────────────────────────────────

async def run_rag(query: str) -> str:
    raw_texts  = await fetch_all(query)
    all_chunks = []
    for raw in raw_texts:
        cleaned = clean_text(raw)
        all_chunks.extend(chunk_text(cleaned))
    top_chunks = rank_chunks(query, all_chunks, top_k=5)
    return "\n\n".join(top_chunks) if top_chunks else ""