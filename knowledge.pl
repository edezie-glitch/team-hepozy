% ============================================================
% knowledge.pl — Hepozy output-type routing rules
%
% SCOPE: this file decides ONE thing — which of the four
% output types (reply / instructions / workflow / examples)
% a message should become. It does NOT answer questions,
% does NOT verify facts, does NOT touch retrieved RAG content.
% ============================================================

% ---- facts about what each intent implies ----
% intent(Intent) is asserted at query time by Python, per-message.
% has_multiple_steps(true/false) is also asserted at query time,
% derived from the NLP layer (e.g. count of imperative verbs found).

% ---- routing rules ----
output_type(workflow) :-
    intent(how_to),
    has_multiple_steps(true).

output_type(instructions) :-
    intent(how_to),
    has_multiple_steps(false).

output_type(examples) :-
    intent(show_examples).

output_type(reply) :-
    intent(factual_question).

output_type(reply) :-
    intent(opinion_request).

% fallback: if nothing matched, default to reply rather than
% silently returning nothing — routing should never produce
% a hard refusal, only content-answering should.
output_type(reply) :-
    \+ intent(how_to),
    \+ intent(show_examples),
    \+ intent(factual_question),
    \+ intent(opinion_request).