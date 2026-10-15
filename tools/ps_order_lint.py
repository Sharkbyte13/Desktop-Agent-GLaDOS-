"""Find top-level calls to functions that are defined LATER in the file.

PowerShell resolves a function name against what has been defined so far, so
a script that runs top to bottom will die on such a call. The parser accepts
it happily, which is how this reached the user twice.
"""
import re, sys

def check(path):
    lines = open(path, encoding='utf-8').read().splitlines()

    defs = {}                       # name -> line number of "function name {"
    for i, l in enumerate(lines, 1):
        m = re.match(r'^\s*function\s+([A-Za-z][\w-]*)\s*\{', l)
        if m and m.group(1) not in defs:
            defs[m.group(1)] = i
    if not defs:
        return []

    # Track brace depth so we only judge statements at script scope. A call
    # INSIDE another function is fine - it runs later, after everything exists.
    problems, depth = [], 0
    for i, l in enumerate(lines, 1):
        code = re.sub(r'#.*$', '', l)
        stripped = code.strip()
        if depth == 0 and stripped:
            m = re.match(r'^([A-Za-z][\w-]*)\b', stripped)
            if m:
                name = m.group(1)
                if name in defs and defs[name] > i:
                    problems.append((i, defs[name], name, stripped[:70]))
        depth += code.count('{') - code.count('}')
        depth = max(depth, 0)
    return problems

bad = 0
for p in sys.argv[1:]:
    for line, defline, name, text in check(p):
        print(f"{p}:{line}")
        print(f"    {text}")
        print(f"    ^ calls {name}(), which is not defined until line {defline}")
        print(f"      PowerShell will fail with \"term '{name}' is not recognized\"\n")
        bad += 1
print(f"{bad} call-before-definition problems")
sys.exit(1 if bad else 0)
