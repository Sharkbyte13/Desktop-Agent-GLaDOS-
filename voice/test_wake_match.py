#!/usr/bin/env python3
"""Wake phrase matching, against transcripts Whisper actually produces.

Run: python test_wake_match.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wake_match as wm

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  -> " + str(detail)) if detail else ""))
    if not cond:
        fails.append(name)


phrases, err = wm.load_phrases(os.path.join(HERE, "wake_phrases.json"))
P = wm.prepare(phrases)

print("\n[the phrase file]")
check("it loads", err is None, err)
check("it has every mood", {p["mood"] for p in phrases} >= {
    "neutral", "casual", "woken", "morning", "evening", "checking", "polite", "curt"})
check("longest phrases are tried first", len(P[0]["words"]) >= len(P[-1]["words"]))
check("a missing file falls back to the defaults", wm.load_phrases("/nope.json")[0] == wm.DEFAULT_PHRASES)
bad = os.path.join(HERE, "_broken.json")
open(bad, "w").write("{ not json")
ph, e = wm.load_phrases(bad)
check("a broken file falls back rather than going deaf", ph == wm.DEFAULT_PHRASES and e is not None, e)
os.remove(bad)

print("\n[how Whisper spells her name]")
for heard in ["hey glados", "hey gladys", "hey gladiss", "hey glad os", "hey glad us",
              "Hey GLaDOS!", "hey gladdis", "hey glottis", "hey gladice", "hey claudos",
              "hey, gladys.", "HEY GLADYS", "hey  gladys  ", "hey gladdys"]:
    m = wm.match_wake(heard, P)
    check("wakes on %r" % heard, m is not None and m["mood"] == "neutral",
          (m or {}).get("mood"))

print("\n[the different ways in]")
cases = [
    ("hey gladys", "neutral"),
    ("hi gladys", "neutral"),
    ("hello glados", "neutral"),
    ("okay gladys", "neutral"),
    ("yo gladys", "casual"),
    ("hey there gladys", "casual"),
    ("wake up gladys", "woken"),
    ("wake up, glados!", "woken"),
    ("gladys wake up", "woken"),
    ("are you awake gladys", "woken"),
    ("you awake glados", "woken"),
    ("good morning gladys", "morning"),
    ("morning glados", "morning"),
    ("good evening gladys", "evening"),
    ("good night glados", "evening"),
    ("are you there gladys", "checking"),
    ("gladys are you there", "checking"),
    ("you there glados", "checking"),
    ("excuse me gladys", "polite"),
    ("sorry gladys", "polite"),
    ("gladys", "curt"),
    ("glados.", "curt"),
]
for heard, mood in cases:
    m = wm.match_wake(heard, P)
    check("%-26r -> %s" % (heard, mood), m is not None and m["mood"] == mood,
          (m or {}).get("mood", "no match"))

print("\n[wake and command in one breath]")
m = wm.match_wake("hey gladys what is on my desktop", P)
check("it wakes", m is not None)
check("the command survives", m and m["rest"] == "what is on my desktop", (m or {}).get("rest"))
check("and it is not treated as a bare wake", m and not m["wake_only"])
m = wm.match_wake("wake up gladys set a timer for ten minutes", P)
check("the mood is still the one used", m and m["mood"] == "woken", (m or {}).get("mood"))
check("with the command intact", m and m["rest"] == "set a timer for ten minutes", (m or {}).get("rest"))
m = wm.match_wake("gladys what time is it", P)
check("a bare name still carries a command", m and m["rest"] == "what time is it", (m or {}).get("rest"))
check("and reports the curt mood", m and m["mood"] == "curt", (m or {}).get("mood"))

print("\n[nothing after the wake phrase]")
for heard in ["hey gladys", "wake up gladys", "gladys"]:
    m = wm.match_wake(heard, P)
    check("%r is a bare summons" % heard, m and m["wake_only"], (m or {}).get("rest"))

print("\n[the longest phrase wins]")
m = wm.match_wake("wake up gladys", P)
check("'wake up glados' beats the bare name", m and m["mood"] == "woken", (m or {}).get("phrase"))
m = wm.match_wake("good morning gladys", P)
check("'good morning glados' beats 'morning glados'", m and m["mood"] == "morning" and m["wake_only"],
      (m or {}).get("phrase"))
m = wm.match_wake("are you there gladys", P)
check("the four-word form beats the three", m and m["phrase"] == "are you there glados",
      (m or {}).get("phrase"))

print("\n[things that must NOT wake her]")
for heard in [
    "what time is it",
    "i was reading about glados yesterday",
    "the cake is a lie",
    "hey can you pass me that",
    "so anyway the aperture science thing",
    "glad to see you",
    "i am glad that worked",
    "she said gladly",
    "hey jeff",
    "good morning everyone",
    "wake up its late",
    "",
    "   ",
    "uh",
]:
    m = wm.match_wake(heard, P)
    check("silent on %r" % heard, m is None, (m or {}).get("phrase"))

print("\n[talking about her, not to her]")
for heard in ["i told glados to do it", "ask glados about the timer",
              "my computer runs glados now"]:
    check("not at the start, not a wake: %r" % heard, wm.match_wake(heard, P) is None,
          (wm.match_wake(heard, P) or {}).get("phrase"))

print("\n[filler and sloppiness]")
for heard in ["uh hey gladys", "um wake up gladys", "hey gladys please",
              "okay uh gladys", "hey gladys,  "]:
    check("still wakes through filler: %r" % heard, wm.match_wake(heard, P) is not None)

print("\n[the threshold behaves]")
strict = wm.match_wake("hey gladys", P, threshold=0.99)
check("an exact phrase passes even a strict threshold", strict is not None)
loose = wm.match_wake("hey gladys what", P, threshold=0.2)
check("a loose threshold still needs the name", wm.match_wake("hey jeff what", P, threshold=0.2) is None)

print("\n[scores are reported]")
m = wm.match_wake("hey glados", P)
check("an exact match scores 1.0", m and m["score"] >= 0.99, (m or {}).get("score"))
m = wm.match_wake("hey gladdis", P)
check("a mangled one still scores well", m and m["score"] >= 0.82, (m or {}).get("score"))

print("\n[commands Whisper got wrong]")
# The one that started this: "start a timer for 30 seconds" came back as
# "Sudden timer for 30 seconds", which is ordinary English and useless.
cases = [
    ("Sudden timer for 30 seconds", "set a timer for 30 seconds"),
    ("sudden timer", "set a timer"),
    ("Sudden alarm for 5 minutes", "set an alarm for 5 minutes"),
    ("start a timer for 25 minutes", "set a timer for 25 minutes"),
    ("said a timer for ten minutes", "set a timer for ten minutes"),
    ("sit a timer", "set a timer"),
    ("set of timer", "set a timer"),
    ("make a timer for 3 minutes", "set a timer for 3 minutes"),
    ("create a new timer", "set a timer"),
    ("half a minute timer", "30 seconds timer"),
    ("set a timer for 90 sec", "set a timer for 90 seconds"),
    ("what is on my desk top", "what is on my desktop"),
    ("read my clip board", "read my clipboard"),
    ("kill the timer", "cancel the timer"),
]
for heard, want in cases:
    got = wm.fix_command_text(heard)
    check("%-34r -> %r" % (heard, want), got == want, got)

print("\n[it does not meddle with things that were fine]")
for ok in [
    "what time is it",
    "read my shopping list",
    "open notepad",
    "how many files are on my desktop",
    "set a timer for 25 minutes",
    "remind me at half past five",
    "I suddenly remembered the meeting",
    "",
]:
    got = wm.fix_command_text(ok)
    check("left alone: %r" % ok, got == ok, got)

print("\n[a real transcript, start to finish]")
heard = "Hey Gladys, sudden timer for 30 seconds"
hit = wm.match_wake(heard, P)
check("it wakes on the name", hit is not None)
check("the command is separated", hit and hit["rest"] == "sudden timer for 30 seconds",
      (hit or {}).get("rest"))
fixed = wm.fix_command_text(hit["rest"]) if hit else ""
check("and corrected before she sees it", fixed == "set a timer for 30 seconds", fixed)

print("\n[the summary the chat window shows]")
d = wm.describe(phrases)
check("it lists moods", "woken" in d and "curt" in d)
check("it lists phrases", "wake up glados" in d)

print("")
if fails:
    print("FAILURES (%d): %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("ALL PASS")
