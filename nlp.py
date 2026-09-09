 
import re


HOW_TO_PATTERNS = [
    r"\bhow (do|can|should) i\b",
    r"\bhow to\b",
    r"\bwalk me through\b",
    r"\bsteps? (to|for)\b",
]

EXAMPLES_PATTERNS = [
    r"\bgive me (an? )?example",
    r"\bshow me (an? )?example",
    r"\bexamples? of\b",
    r"\bfor instance\b",
]

OPINION_PATTERNS = [
    r"\bwhat do you think\b",
    r"\bshould i\b",
    r"\bis it worth\b",
    r"\bwhich is better\b",
]

# rough signal for "this needs multiple ordered steps" vs a single
# short instruction — counts imperative-style verb starts per sentence
MULTI_STEP_VERBS = re.compile(
    r"\b(install|configure|then|after that|next|first|second|finally)\b",
    re.IGNORECASE,
)


def classify_intent(message: str) -> str:
    """Returns one of: how_to, show_examples, opinion_request,
    factual_question (default fallback)."""
    text = message.lower().strip()

    for pat in HOW_TO_PATTERNS:
        if re.search(pat, text):
            return "how_to"

    for pat in EXAMPLES_PATTERNS:
        if re.search(pat, text):
            return "show_examples"

    for pat in OPINION_PATTERNS:
        if re.search(pat, text):
            return "opinion_request"

    return "factual_question"


def has_multiple_steps(message: str) -> bool:
    """Rough heuristic: 2+ step-indicator words suggests a workflow,
    not a single instruction. This WILL be wrong sometimes — it's a
    heuristic, not a parser. Tune the threshold against real traffic."""
    hits = len(MULTI_STEP_VERBS.findall(message))
    return hits >= 2


if __name__ == "__main__":
    test_messages = [
        "How do I set up a Python virtual environment?",
        "How do I reset my password?",
        "Give me an example of a REST API call",
        "Should I use FastAPI or Flask for this?",
        "What's the capital of Japan?",
        "First install Docker, then configure the network, then start the container",
    ]
    for msg in test_messages:
        intent = classify_intent(msg)
        multi = has_multiple_steps(msg)
        print(f"{msg!r:60} -> intent={intent:18} multi_step={multi}")