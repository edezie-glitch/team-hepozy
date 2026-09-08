 

from pyswip import Prolog
from nlp import classify_intent, has_multiple_steps

prolog = Prolog()
prolog.consult("knowledge.pl")


def route_message(message: str) -> str:
    intent = classify_intent(message)
    multi_step = has_multiple_steps(message)

     
    prolog.assertz(f"intent({intent})")
    prolog.assertz(f"has_multiple_steps({str(multi_step).lower()})")

    results = list(prolog.query("output_type(X)"))
    output_type = results[0]["X"] if results else "reply"

    prolog.retractall(f"intent(_)")
    prolog.retractall("has_multiple_steps(_)")

    return output_type


if __name__ == "__main__":
    test_messages = [
        "How do I set up a Python virtual environment?",
        "Give me an example of a REST API call",
        "Should I use FastAPI or Flask for this?",
        "What's the capital of Japan?",
    ]
    for msg in test_messages:
        result = route_message(msg)
        print(f"{msg!r:55} -> output_type={result}")