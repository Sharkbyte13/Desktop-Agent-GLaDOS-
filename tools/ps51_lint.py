"""Find PowerShell 6/7-only constructs in scripts that must run on Windows
PowerShell 5.1. My test harness is pwsh 7, which silently accepts all of these.
"""
import re, sys

# (pattern, what breaks on 5.1, the 5.1-safe form)
RULES = [
    (r'\[datetime\]::UnixEpoch',        'DateTime.UnixEpoch is .NET Core 2.1+ / PS6+', 'New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)'),
    (r'\[DateTime\]::UnixEpoch',        'DateTime.UnixEpoch is .NET Core 2.1+ / PS6+', 'New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)'),
    (r'\?\?=',                          'null-coalescing assignment is PS7+',          'explicit if test'),
    (r'(?<![\w"\'])\?\?(?!\?)',         'null-coalescing operator is PS7+',            'explicit if test'),
    (r'\$\w+\s*\?\.', 'null-conditional member access is PS7+',                        'explicit if test'),
    (r'ConvertFrom-Json\s[^|\r\n]*-AsHashtable', 'ConvertFrom-Json -AsHashtable is PS6+', 'walk PSObject.Properties'),
    (r'Get-Content\s[^|\r\n]*-AsByteStream', 'Get-Content -AsByteStream is PS6+',       'Get-Content -Encoding Byte'),
    (r'\bJoin-String\b',                'Join-String is PS6+',                         '-join operator'),
    (r'Split-Path\s[^|\r\n]*-LeafBase', 'Split-Path -LeafBase is PS6+',                '[IO.Path]::GetFileNameWithoutExtension()'),
    (r'\bTest-Json\b',                  'Test-Json is PS6+',                           'try { ConvertFrom-Json } catch'),
    (r'\$PSStyle',                      '$PSStyle is PS7+',                            'plain text'),
    (r'-Parallel\b',                    'ForEach-Object -Parallel is PS7+',            'runspaces'),
    (r'\bGet-Uptime\b',                 'Get-Uptime is PS6+',                          'CIM LastBootUpTime'),
    (r'\bRemove-Alias\b',               'Remove-Alias is PS6+',                        'Remove-Item alias:'),
    (r'\bConvertTo-Json\s[^|\r\n]*-EscapeHandling', '-EscapeHandling is PS6+',         'default escaping'),
    (r'::new\(',                        '::new() works on 5.1 but only for loaded types', '(usually fine - verify)'),
]

problems = 0
for path in sys.argv[1:]:
    try:
        src = open(path, encoding='utf-8').read()
    except OSError:
        continue

    # Two ways a file gets quietly corrupted by the tooling that edits it:
    # a non-ASCII character in a script with no byte-order mark, which 5.1
    # decodes as ANSI, and a stray control character - which is what a \b in
    # a non-raw Python string turns into when it is written into a regex.
    for i, ch in enumerate(src):
        code = ord(ch)
        if code > 127:
            line = src.count('\n', 0, i) + 1
            print(f"{path}:{line}")
            print(f"    U+{code:04X} {ch!r} in a script with no BOM")
            print("    ^ Windows PowerShell 5.1 reads it as ANSI and mangles it")
            print("      use: an escape - '\\uXXXX' inside the string\n")
            problems += 1
            break
    for i, ch in enumerate(src):
        code = ord(ch)
        if code < 32 and ch not in '\t\r\n':
            line = src.count('\n', 0, i) + 1
            print(f"{path}:{line}")
            print(f"    control character 0x{code:02X} in the source")
            print("    ^ almost always a \\b or \\a that went through a")
            print("      non-raw Python string on its way into this file\n")
            problems += 1
            break

    lines = src.splitlines()
    for i, line in enumerate(lines, 1):
        stripped = line.split('#')[0] if not line.strip().startswith('#') else ''
        for pat, why, fix in RULES:
            if re.search(pat, stripped):
                print(f"{path}:{i}")
                print(f"    {line.strip()[:100]}")
                print(f"    ^ {why}")
                print(f"      use: {fix}\n")
                problems += 1
print(f"{problems} potential 5.1 incompatibilities")
sys.exit(1 if problems else 0)
