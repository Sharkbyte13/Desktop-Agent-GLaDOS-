#!/usr/bin/env python3
"""
Wake phrase matching for the GLaDOS listener.

The old arrangement had one wake word baked into a neural model: whatever it
was trained on, said exactly that way, or nothing happened. This module takes
the other route - a transcript from Whisper, matched against a list of phrases
you can edit in a text file - which buys three things:

  * several ways in ("hey GLaDOS", "wake up GLaDOS", "good morning GLaDOS")
  * tolerance for how the name comes back from speech recognition, which is
    rarely "GLaDOS" and often "Gladys", "glad us", "gladiss" or "glottis"
  * a mood attached to each phrase, so being woken up sounds different from
    being greeted politely

Nothing here does any I/O or audio work, so all of it is testable.
"""

import json
import os
import re
import unicodedata
from difflib import SequenceMatcher

# Every spelling Whisper has been observed to produce for the name, plus the
# obvious neighbours. Order matters only in that longer patterns come first.
_NAME_PATTERNS = [
    r"\bglad\s*os\b",
    r"\bglad\s*us\b",
    r"\bglad\s*is\b",
    r"\bglad\s*ice\b",
    r"\bglad\s*dis\b",
    r"\bgla+d+(?:o|u|i|y|e)?s+\b",
    r"\bgladd?(?:y|i|e)s+\b",
    r"\bgladiss\b",
    r"\bgladdis\b",
    r"\bgladys\b",
    r"\bgladice\b",
    r"\bgl[ao]tt?is\b",
    r"\bcl[ae]d(?:o|u|i)s\b",
    r"\bclad\s*(?:os|us)\b",
    r"\bcl[ao]ud(?:o|u|i)s\b",
    r"\bclaudia?s\b",
    r"\bglaud(?:o|u|i)s\b",
    r"\bgallant\s*os\b",
    r"\bjarvis\b",
]
_NAME_RE = re.compile("|".join(_NAME_PATTERNS), re.IGNORECASE)

# Filler that changes nothing about what was meant.
_FILLER = {"uh", "um", "er", "ah", "please", "now", "just", "so", "well", "like"}

NAME_TOKEN = "glados"

DEFAULT_PHRASES = [
    {"match": "hey glados",            "mood": "neutral"},
    {"match": "hi glados",             "mood": "neutral"},
    {"match": "hello glados",          "mood": "neutral"},
    {"match": "okay glados",           "mood": "neutral"},
    {"match": "yo glados",             "mood": "casual"},
    {"match": "wake up glados",        "mood": "woken"},
    {"match": "glados wake up",        "mood": "woken"},
    {"match": "you awake glados",      "mood": "woken"},
    {"match": "are you awake glados",  "mood": "woken"},
    {"match": "good morning glados",   "mood": "morning"},
    {"match": "morning glados",        "mood": "morning"},
    {"match": "good evening glados",   "mood": "evening"},
    {"match": "are you there glados",  "mood": "checking"},
    {"match": "glados are you there",  "mood": "checking"},
    {"match": "you there glados",      "mood": "checking"},
    {"match": "excuse me glados",      "mood": "polite"},
    {"match": "sorry glados",          "mood": "polite"},
    {"match": "glados",                "mood": "curt"},
]


def normalise(text):
    """Lowercase, strip accents and punctuation, collapse whitespace."""
    if not text:
        return ""
    t = unicodedata.normalize("NFKD", str(text))
    t = "".join(c for c in t if not unicodedata.combining(c))
    t = t.lower()
    t = re.sub(r"[^a-z0-9\s']", " ", t)
    t = re.sub(r"\s+", " ", t)
    return t.strip()


def canonicalise(text):
    """Normalise, then rewrite every spelling of the name to one token."""
    t = normalise(text)
    if not t:
        return ""
    t = _NAME_RE.sub(NAME_TOKEN, t)
    words = [w for w in t.split() if w not in _FILLER]
    return " ".join(words)


def _similar(a, b):
    return SequenceMatcher(None, a, b).ratio()


def load_phrases(path=None):
    """Read the phrase file, falling back to the built-in list.

    A broken or missing file must never leave her deaf, so anything unreadable
    is reported by the caller and the defaults are used.
    """
    if not path or not os.path.isfile(path):
        return [dict(p) for p in DEFAULT_PHRASES], None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as exc:
        return [dict(p) for p in DEFAULT_PHRASES], str(exc)

    raw = data.get("phrases") if isinstance(data, dict) else data
    out = []
    for item in raw or []:
        if isinstance(item, str):
            out.append({"match": item, "mood": "neutral"})
        elif isinstance(item, dict) and item.get("match"):
            out.append({"match": str(item["match"]),
                        "mood": str(item.get("mood", "neutral"))})
    if not out:
        return [dict(p) for p in DEFAULT_PHRASES], "no usable phrases in the file"
    return out, None


def prepare(phrases):
    """Canonicalise the phrase list once, longest first.

    Longest first matters: "wake up glados" must win over the bare "glados",
    or being woken would always be reported as a curt summons.
    """
    prepped = []
    for p in phrases:
        canon = canonicalise(p.get("match", ""))
        if not canon:
            continue
        prepped.append({
            "match": p.get("match", ""),
            "canon": canon,
            "words": canon.split(),
            "mood": p.get("mood", "neutral"),
        })
    prepped.sort(key=lambda p: len(p["words"]), reverse=True)

    # Two phrases can boil down to the same thing: "please glados" loses its
    # filler word and becomes the bare "glados". Keep one - the one that was
    # written more plainly - so the mood reported is not a coin toss.
    seen = {}
    for p in prepped:
        prev = seen.get(p["canon"])
        if prev is None or len(p["match"]) < len(prev["match"]):
            seen[p["canon"]] = p
    out = [p for p in prepped if seen.get(p["canon"]) is p]
    return out


def match_wake(text, phrases, threshold=0.82):
    """Look for a wake phrase at the start of what was heard.

    Returns None, or a dict:
        phrase     the configured phrase that matched
        mood       its mood
        score      0..1, how close the match was
        rest       whatever was said after it, if anything
        wake_only  True when nothing followed the wake phrase

    The phrase must be at the START. "I was reading about GLaDOS yesterday"
    is someone talking about her, not to her, and she should stay out of it.
    """
    canon = canonicalise(text)
    if not canon:
        return None
    # Every phrase contains the name, so a transcript without it cannot match.
    # This one line removes almost every false positive an open microphone
    # would otherwise produce in a room where people are talking.
    if NAME_TOKEN not in canon.split():
        return None

    words = canon.split()
    best = None

    for p in phrases:
        n = len(p["words"])
        found = None

        # Try the exact length first. Only if that fails do we allow one word
        # of slack, and then only for a clearly better match - otherwise
        # "wake up glados set a timer" hands back "a timer", having quietly
        # eaten the verb.
        for take, need in ((n, threshold), (n - 1, threshold + 0.08), (n + 1, threshold + 0.08)):
            if take < 1 or take > len(words):
                continue
            head = " ".join(words[:take])
            if NAME_TOKEN not in head.split():
                continue
            score = _similar(head, p["canon"])
            if score < need:
                continue
            found = {
                "phrase": p["match"],
                "mood": p["mood"],
                "score": round(score, 3),
                "rest": " ".join(words[take:]).strip(),
                "words": take,
            }
            found["wake_only"] = not found["rest"]
            break

        if found is None:
            continue
        # The phrase that used more of the sentence wins, so "wake up glados"
        # beats the bare name it contains. Ties go to the closer match.
        if best is None or (found["words"], found["score"]) > (best["words"], best["score"]):
            best = found

    return best


# Whisper hears a command as whatever is most likely in general English, not
# what is most likely to be said to a desktop assistant. "Start a timer" came
# back as "Sudden timer", which is a perfectly ordinary English phrase and
# completely wrong here. The decoder is biased with a prompt (see listener.py);
# these are the ones that slip through it anyway.
_FIXES = [
    (r"\b(?:sudden|sud in|sort of|sought a|said a|sit a|set of|start of|"
     r"stop a|sudden a|sudd?en?)\s+(timer|alarm)\b", r"set a \1"),
    (r"\b(?:set|start|make|create)\s+(?:a\s+)?(?:new\s+)?(timer|alarm)\b", r"set a \1"),
    (r"\bsudden(?:ly)?\s+remind", "set a reminder"),
    (r"\b(?:cancel|kill|stop)\s+(?:the\s+)?(timer|alarm)\b", r"cancel the \1"),
    (r"\btimer for (\d+) (?:second|seconds|sec|secs)\b", r"timer for \1 seconds"),
    (r"\b(\d+)\s*(?:second|seconds|sec|secs)\b(?!\s*(?:timer|alarm))", r"\1 seconds"),
    (r"\b(\d+)\s*(?:minute|minutes|min|mins)\b(?!\s*(?:timer|alarm))", r"\1 minutes"),
    (r"\bset a alarm\b", "set an alarm"),
    (r"\bhalf a minute\b", "30 seconds"),
    (r"\b(?:read|red)\s+my\s+clip\s*board\b", "read my clipboard"),
    (r"\bwhat(?:'s| is)?\s+on\s+my\s+desk\s*top\b", "what is on my desktop"),
]
_FIXES = [(re.compile(pat, re.IGNORECASE), rep) for pat, rep in _FIXES]


def fix_command_text(text):
    """Correct the handful of mishearings that break a command outright.

    Deliberately small and deliberately boring: every rule here is one that
    turns a sentence which cannot work into the sentence that was meant. It
    does not paraphrase, and it never touches words it does not recognise.
    """
    if not text:
        return text
    out = str(text)
    for rx, rep in _FIXES:
        out = rx.sub(rep, out)
    out = re.sub(r"\s+", " ", out).strip()
    return out


def describe(phrases):
    """Human-readable summary, for the /wake command in the chat window."""
    by_mood = {}
    for p in phrases:
        by_mood.setdefault(p.get("mood", "neutral"), []).append(p.get("match", ""))
    lines = []
    for mood in sorted(by_mood):
        lines.append("%-9s : %s" % (mood, ", ".join(sorted(by_mood[mood]))))
    return "\n".join(lines)


if __name__ == "__main__":       # a quick manual probe: python wake_match.py "hey gladys"
    import sys
    ph = prepare(load_phrases(os.path.join(os.path.dirname(__file__), "wake_phrases.json"))[0])
    for arg in sys.argv[1:]:
        print("%-40r -> %s" % (arg, match_wake(arg, ph)))
