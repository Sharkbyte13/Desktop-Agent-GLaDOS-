"""Find scriptblocks closed with GetNewClosure() that read or write $script:
variables from inside a function.

Why this matters, learned the hard way: GetNewClosure() gives the block its own
module scope. At the top level of a script that scope still resolves $script:
to the same place, so it looks fine. Created inside a function - which is where
every event handler is created - the closure gets a fresh scope where every
$script: variable reads as $null. The symptom on Windows is a WinForms dialog
saying "Cannot index into a null array" on the first click, with no line number.

The fix is not a different closure. It is to stop needing one: put the state on
the control's .Tag and read $this.Tag in a plain scriptblock.
"""
import re, sys


def strip_noise(src):
    """Blank out comments and string bodies so braces inside them do not count.
    Keeps the length identical, so every index still lines up with the source."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '#':                                  # line comment
            j = src.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c == '<' and src[i:i + 2] == '<#':        # block comment
            j = src.find('#>', i)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if src[k] != '\n':
                    out[k] = ' '
            i = j
        elif c in '"\'':                               # string
            quote = c
            j = i + 1
            while j < n:
                if src[j] == '`' and quote == '"':
                    j += 2
                    continue
                if src[j] == quote:
                    break
                if src[j] == '\n':
                    break
                j += 1
            for k in range(i, min(j + 1, n)):
                if src[k] != '\n':
                    out[k] = ' '
            i = min(j + 1, n)
        else:
            i += 1
    return ''.join(out)


def match_backwards(clean, close_idx):
    """Given the index of a }, return the index of its {."""
    depth = 0
    i = close_idx
    while i >= 0:
        if clean[i] == '}':
            depth += 1
        elif clean[i] == '{':
            depth -= 1
            if depth == 0:
                return i
        i -= 1
    return -1


def match_forwards(clean, open_idx):
    """Given the index of a {, return the index of its }."""
    depth = 0
    i = open_idx
    n = len(clean)
    while i < n:
        if clean[i] == '{':
            depth += 1
        elif clean[i] == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def function_spans(clean):
    spans = []
    for m in re.finditer(r'\bfunction\s+[\w-]+', clean):
        brace = clean.find('{', m.end())
        if brace < 0:
            continue
        end = match_forwards(clean, brace)
        if end > brace:
            spans.append((brace, end))
    return spans


problems = 0
for path in sys.argv[1:]:
    try:
        src = open(path, encoding='utf-8').read()
    except OSError:
        continue
    clean = strip_noise(src)
    spans = function_spans(clean)

    for m in re.finditer(r'\.GetNewClosure\(\)', clean):
        close = clean.rfind('}', 0, m.start())
        if close < 0:
            continue
        open_idx = match_backwards(clean, close)
        if open_idx < 0:
            continue

        body = src[open_idx:close + 1]
        refs = sorted(set(re.findall(r'\$script:[A-Za-z_]\w*', strip_noise(body))))
        if not refs:
            continue
        inside = any(a < open_idx < b for a, b in spans)
        if not inside:
            continue

        problems += 1
        line = src.count('\n', 0, open_idx) + 1
        print(f"{path}:{line}")
        print(f"    closure touches: {', '.join(refs)}")
        print("    ^ GetNewClosure() inside a function gets its own scope;")
        print("      these read as $null at run time.")
        print("      use: put state on the control's .Tag, read $this.Tag\n")

print(f"{problems} closures capturing script scope")
sys.exit(0)
