#requires -version 5.1
# ===========================================================================
#  The two local backends - regression test
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_brain_wire.ps1
#
#  She can think with Ollama or with LM Studio. Everything they disagree about
#  lives in the flavour functions at the end of uilogic.ps1, and this is what
#  stops those disagreements being rediscovered one outage at a time.
#
#  What it is guarding, in order of how quietly each one fails:
#
#  1. Tool arguments, which travel in opposite forms and were written the
#     wrong way round once already. Ollama wants an object. The OpenAI shape
#     wants a string containing JSON, both when it hands a call to you and
#     when you send that call back - and an object there is refused with a
#     bare 400 and an empty response body. Gemma's template *does* insist on
#     an object ("arguments must be a JSON object (mapping), not a string"),
#     but LM Studio converts the string before the template sees it, so that
#     error is about a layer below the wire and is not advice about it.
#     Getting this wrong breaks the second half of every tool call she makes,
#     with nothing anywhere to say why.
#  2. The tool result's name field. Ollama reads tool_name, the OpenAI shape
#     reads name or tool_call_id. Send the wrong one and nothing errors: the
#     field is ignored, Gemma substitutes the word "unknown", and every tool
#     result she ever gets back says it came from a tool called unknown.
#  3. Where the reply sits. .message on one, .choices[0].message on the other.
#  4. ttl. LM Studio wants whole seconds where Ollama wants "5m", and a
#     duration string sent as-is is silently ignored - so the model sits on
#     the card for LM Studio's own default instead of hers, which looks like
#     game mode having stopped working.
#  5. The decimal separator, again. Same hazard as test_brain_temp.ps1: a
#     comma locale turns 0.9 into 0,9 and both servers reject the whole body.
#  6. How a captured frame is carried. Ollama has an "images" array; the
#     OpenAI shape puts a data URI inside content. The wrong one is not an
#     error either: the field is ignored and the model, asked about a picture
#     it was never shown, describes one it made up.
# ===========================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
function Write-Log { param([string]$Message) }

$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
. (Join-Path $root 'uilogic.ps1')

$script:Failed = 0

function Assert-Eq {
    param([string]$What, $Got, $Want)
    if ([string]$Got -eq [string]$Want) { Write-Host ('  ok   ' + $What) }
    else {
        Write-Host ('  FAIL ' + $What + ' - wanted "' + $Want + '", got "' + $Got + '"')
        $script:Failed++
    }
}

function Assert-Like {
    param([string]$What, [string]$Got, [string]$Pattern)
    if ($Got -like $Pattern) { Write-Host ('  ok   ' + $What) }
    else {
        Write-Host ('  FAIL ' + $What + ' - "' + $Got + '" does not match ' + $Pattern)
        $script:Failed++
    }
}

function Assert-Starts {
    <#  A plain prefix check. -like cannot do this one: the shape being
        checked contains a [ and -like reads that as a character class, which
        throws rather than failing - so the check that mattered most was the
        one that quietly never ran. #>
    param([string]$What, [string]$Got, [string]$Prefix)
    if ($Got.StartsWith($Prefix)) { Write-Host ('  ok   ' + $What) }
    else {
        Write-Host ('  FAIL ' + $What + ' - "' + $Got + '" does not start with ' + $Prefix)
        $script:Failed++
    }
}

function Assert-NotLike {
    param([string]$What, [string]$Got, [string]$Pattern)
    if ($Got -notlike $Pattern) { Write-Host ('  ok   ' + $What) }
    else {
        Write-Host ('  FAIL ' + $What + ' - "' + $Got + '" should not match ' + $Pattern)
        $script:Failed++
    }
}

Write-Host ''
Write-Host 'Endpoints'
$o = Get-BrainEndpoint 'ollama' 'http://127.0.0.1:11434'
Assert-Eq 'ollama chat'   $o.chat   'http://127.0.0.1:11434/api/chat'
Assert-Eq 'ollama probe'  $o.probe  'http://127.0.0.1:11434/api/version'
Assert-Eq 'ollama loaded' $o.loaded 'http://127.0.0.1:11434/api/ps'

$l = Get-BrainEndpoint 'lmstudio' 'http://127.0.0.1:1234'
Assert-Eq 'lmstudio chat'   $l.chat   'http://127.0.0.1:1234/v1/chat/completions'
Assert-Eq 'lmstudio probe'  $l.probe  'http://127.0.0.1:1234/v1/models'
Assert-Eq 'lmstudio loaded' $l.loaded 'http://127.0.0.1:1234/api/v0/models'

# A trailing slash in config.json is the commonest hand-edit there is, and
# doubling it gives a 404 that reads like the server being down.
Assert-Eq 'trailing slash trimmed' (Get-BrainEndpoint 'lmstudio' 'http://127.0.0.1:1234/').chat `
    'http://127.0.0.1:1234/v1/chat/completions'
Assert-Eq 'empty url falls back' (Get-BrainEndpoint 'lmstudio' '').base 'http://127.0.0.1:1234'
Assert-Eq 'empty ollama url falls back' (Get-BrainEndpoint 'ollama' '').base 'http://127.0.0.1:11434'
# An unknown name is Ollama, because that is what she started as.
Assert-Eq 'unknown flavour is ollama' (Get-BrainEndpoint 'something' '').flavour 'ollama'

Write-Host ''
Write-Host 'Durations'
Assert-Eq '5m'      (ConvertTo-BrainSeconds '5m')      300
Assert-Eq '90s'     (ConvertTo-BrainSeconds '90s')     90
Assert-Eq '1h'      (ConvertTo-BrainSeconds '1h')      3600
Assert-Eq 'bare 30' (ConvertTo-BrainSeconds '30')      30
Assert-Eq 'zero'    (ConvertTo-BrainSeconds '0')       0
Assert-Eq 'blank'   (ConvertTo-BrainSeconds '')        300
Assert-Eq 'junk'    (ConvertTo-BrainSeconds 'soonish') 300
Assert-Eq 'junk keeps the caller default' (ConvertTo-BrainSeconds 'soonish' 42) 42
Assert-Eq 'negative refused' (ConvertTo-BrainSeconds '-5m') 300
Assert-Eq 'fractional minutes' (ConvertTo-BrainSeconds '0.5m') 30

Write-Host ''
Write-Host 'Sampling block'
$so = Get-BrainSamplingJson 'ollama' '0.9' 7 '5m'
Assert-Like 'ollama nests under options' $so '*"options":{"temperature":0.9,"seed":7*'
Assert-Like 'ollama keeps keep_alive'    $so '*"keep_alive":"5m"*'
Assert-NotLike 'ollama has no ttl'       $so '*ttl*'

$sl = Get-BrainSamplingJson 'lmstudio' '0.9' 7 '5m'
Assert-Like 'lmstudio temperature at the top level' $sl '*,"temperature":0.9,*'
Assert-Like 'lmstudio converts the keep-alive'      $sl '*"ttl":300*'
Assert-NotLike 'lmstudio has no options block'      $sl '*options*'
Assert-NotLike 'lmstudio has no keep_alive'         $sl '*keep_alive*'
# repeat_penalty is an Ollama option name; frequency_penalty is a different
# quantity and guessing at it would change her voice without saying so.
Assert-NotLike 'lmstudio sends no penalty' $sl '*penalty*'

Write-Host ''
Write-Host 'Tool arguments'
Assert-Eq 'null'            (ConvertTo-BrainArgsJson $null) '{}'
Assert-Eq 'empty string'    (ConvertTo-BrainArgsJson '') '{}'
Assert-Eq 'a JSON string passes through' `
    (ConvertTo-BrainArgsJson '{"path":"notes.txt"}') '{"path":"notes.txt"}'
Assert-Eq 'whitespace is trimmed' `
    (ConvertTo-BrainArgsJson '  {"a":1}  ') '{"a":1}'
# Valid JSON that is not an object is not a set of arguments.
Assert-Eq 'a bare number is refused' (ConvertTo-BrainArgsJson '5') '{}'
Assert-Eq 'a bare array is refused'  (ConvertTo-BrainArgsJson '[1,2]') '{}'
Assert-Eq 'malformed is refused'     (ConvertTo-BrainArgsJson '{"a":') '{}'
$obj = '{"path":"notes.txt"}' | ConvertFrom-Json
Assert-Like 'an object is encoded' (ConvertTo-BrainArgsJson $obj) '*"path":*"notes.txt"*'

Write-Host ''
Write-Host 'Reading a reply'
$ollamaReply = '{"message":{"content":"Oh good, you are back.","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"notes.txt"}}}]}}' | ConvertFrom-Json
$r = ConvertFrom-BrainResponse 'ollama' $ollamaReply
Assert-Eq 'ollama ok'   $r.ok $true
Assert-Eq 'ollama text' $r.text 'Oh good, you are back.'
Assert-Eq 'ollama tool' $r.toolName 'read_file'
Assert-Like 'ollama args' $r.toolArgs '*"path":*"notes.txt"*'

# The LM Studio shape, with arguments as a string, which is the whole reason
# ConvertTo-BrainArgsJson exists.
$lmReply = '{"choices":[{"message":{"content":"Fine.","tool_calls":[{"id":"call_abc","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"notes.txt\"}"}}]}}]}' | ConvertFrom-Json
$r2 = ConvertFrom-BrainResponse 'lmstudio' $lmReply
Assert-Eq 'lmstudio ok'   $r2.ok $true
Assert-Eq 'lmstudio text' $r2.text 'Fine.'
Assert-Eq 'lmstudio tool' $r2.toolName 'read_file'
Assert-Eq 'lmstudio id'   $r2.toolId 'call_abc'
Assert-Eq 'string arguments are unwrapped, not re-encoded' $r2.toolArgs '{"path":"notes.txt"}'
# The failure this replaces: a quoted string where an object belongs.
Assert-NotLike 'arguments are not double-encoded' $r2.toolArgs '"*'

$plain = '{"choices":[{"message":{"content":"No tools today."}}]}' | ConvertFrom-Json
$r3 = ConvertFrom-BrainResponse 'lmstudio' $plain
Assert-Eq 'no tool call' $r3.toolName ''
Assert-Eq 'plain text'   $r3.text 'No tools today.'

$r4 = ConvertFrom-BrainResponse 'lmstudio' $null
Assert-Eq 'nothing at all is not ok' $r4.ok $false
# Reading an Ollama reply as if it were LM Studio's is what a stale
# $script:Pending.flavour would do, and it must not throw.
$r5 = ConvertFrom-BrainResponse 'lmstudio' $ollamaReply
Assert-Eq 'wrong shape fails cleanly' $r5.ok $false
Assert-Like 'and says why' $r5.err '*no message*'

Write-Host ''
Write-Host 'Writing the messages'
$co = Format-BrainToolCall 'ollama' 'read_file' '{"path":"n.txt"}' 'call_1'
Assert-Starts 'ollama call keeps its old shape' $co '{"role":"assistant","content":"","tool_calls":[{"function":'
Assert-NotLike 'ollama call carries no id'    $co '*"id":*'

$cl = Format-BrainToolCall 'lmstudio' 'read_file' '{"path":"n.txt"}' 'call_1'
Assert-Like 'lmstudio call carries its id'   $cl '*"id":"call_1"*'
Assert-Like 'lmstudio call is typed'         $cl '*"type":"function"*'
# A string on the wire, escaped - see Format-BrainToolCall. Assert-Eq on
# Contains rather than -like, because the pattern needs a literal backslash.
Assert-Eq 'arguments go as a JSON string'    ($cl.Contains('"arguments":"{\"path\":\"n.txt\"}"')) $true

$to = Format-BrainToolResult 'ollama' 'read_file' 'call_1' 'four lines'
Assert-Like 'ollama result uses tool_name' $to '*"tool_name":"read_file"*'

$tl = Format-BrainToolResult 'lmstudio' 'read_file' 'call_1' 'four lines'
Assert-Like 'lmstudio result uses name'         $tl '*"name":"read_file"*'
Assert-Like 'lmstudio result carries the id'    $tl '*"tool_call_id":"call_1"*'
Assert-NotLike 'and not the Ollama spelling'    $tl '*tool_name*'

# Both must be valid JSON, or the whole request body is rejected and the only
# symptom is silence.
foreach ($pair in @(@('ollama', $co), @('ollama', $to), @('lmstudio', $cl), @('lmstudio', $tl))) {
    $ok = $true
    try { [void]($pair[1] | ConvertFrom-Json) } catch { $ok = $false }
    Assert-Eq ($pair[0] + ' message parses as JSON') $ok $true
}

# Empty arguments are an empty object, not an empty string: "arguments":""
# is the one thing Gemma's template refuses by name.
Assert-Like 'missing arguments become an object' `
    (Format-BrainToolCall 'lmstudio' 'system_status' '' 'call_9') '*"arguments":"{}"*'

Write-Host ''
Write-Host 'End to end: a reply becomes the next request'
# The round trip. Parse LM Studio's answer, write the call back onto the wire,
# and the arguments have to be a JSON *string* again - that is what the API
# validates, and an object is a 400 with an empty body. Verified live against
# LM Studio: of five variations of this message, the stringified one was the
# only one it accepted.
$again = Format-BrainToolCall 'lmstudio' $r2.toolName $r2.toolArgs $r2.toolId
Assert-Eq 'round trip restringifies for the wire' `
    ($again.Contains('"arguments":"{\"path\":\"notes.txt\"}"')) $true
Assert-NotLike 'and does not send a bare object' $again '*"arguments":{*'
# The body still has to be valid JSON with the escaping in it.
$ok = $true
try { [void]($again | ConvertFrom-Json) } catch { $ok = $false }
Assert-Eq 'the escaped call parses' $ok $true
$back = ($again | ConvertFrom-Json).tool_calls[0].function.arguments
Assert-Eq 'and unwraps to the same arguments' $back '{"path":"notes.txt"}'
# Ollama is the other way round and must not be touched.
Assert-Like 'ollama still sends an object' `
    (Format-BrainToolCall 'ollama' 'read_file' '{"path":"n.txt"}' 'call_1') '*"arguments":{"path":"n.txt"}*'
$answer = Format-BrainToolResult 'lmstudio' $r2.toolName $r2.toolId 'the file says hello'
Assert-Like 'the result answers that same call' $answer '*"tool_call_id":"call_abc"*'

Write-Host ''
Write-Host 'Reasoning blocks'
# qwen3's spelling, and Gemma 4's, which the <think> pattern does not touch.
# Left in, a thinking channel goes through ConvertTo-SpeakableText as ordinary
# prose and she reads her own reasoning out loud in her own voice.
Assert-Eq 'qwen think block'   (ConvertFrom-ThinkTags '<think>hmm</think>Hello.') 'Hello.'
Assert-Eq 'qwen, multi-line'   (ConvertFrom-ThinkTags "<think>
hmm
so
</think>
Hello.") 'Hello.'
Assert-Eq 'gemma channel'      (ConvertFrom-ThinkTags '<|channel>thought I should be rude<channel|>Hello.') 'Hello.'
Assert-Eq 'gemma, text first'  (ConvertFrom-ThinkTags 'Hello.<|channel>thought more<channel|>') 'Hello.'
# Cut off mid-thought: everything from the opening marker goes.
Assert-Eq 'unclosed qwen'      (ConvertFrom-ThinkTags 'Hello.<think>and then') 'Hello.'
Assert-Eq 'unclosed gemma'     (ConvertFrom-ThinkTags 'Hello.<|channel>thought and then') 'Hello.'
Assert-Eq 'nothing to strip'   (ConvertFrom-ThinkTags 'Hello.') 'Hello.'
Assert-Eq 'empty in, empty out' (ConvertFrom-ThinkTags '') ''
Assert-Eq 'null in, empty out' (ConvertFrom-ThinkTags $null) ''
# A reply that is nothing but reasoning leaves nothing, and the caller
# substitutes its own line rather than speaking an empty string.
Assert-Eq 'all thought'        (ConvertFrom-ThinkTags '<think>only this</think>') ''

Write-Host ''
Write-Host 'A frame on its way to a model'
# The eye's reason for existing, now that one model does both jobs. Ollama
# takes a bare base64 in a sibling "images" array; the OpenAI shape carries it
# inside content, as a part, wrapped in a data URI. Sent the wrong way round
# nothing errors - the unknown field is ignored, the model is asked about a
# picture it never got, and it invents one and describes that instead.
$b64 = 'AAECAwQFBgc='
$oi = Format-BrainImageMessage 'ollama' 'Describe it.' $b64
Assert-Like 'ollama: content is a plain string' $oi '*"content":"Describe it."*'
# Not -like: the pattern contains a [ , which -like reads as a character class
# and quietly matches nothing. Same trap Assert-Starts exists for.
Assert-Eq 'ollama: images sits beside it' ($oi.Contains('"images":["' + $b64 + '"]')) $true
Assert-NotLike 'ollama: no data URI'            $oi '*data:image*'

$li = Format-BrainImageMessage 'lmstudio' 'Describe it.' $b64
Assert-Like 'lmstudio: content is parts'     $li '*"content":*"type":"text"*'
Assert-Like 'lmstudio: the image is a part'  $li '*"type":"image_url"*'
Assert-Like 'lmstudio: wrapped in a data URI' $li ('*"url":"data:image/jpeg;base64,' + $b64 + '"*')
Assert-NotLike 'lmstudio: no images array'   $li '*"images":*'
Assert-Like 'a mime type can be overridden' `
    (Format-BrainImageMessage 'lmstudio' 'x' $b64 'image/png') '*data:image/png;base64,*'

# Both shapes have to be valid JSON on their own, because they are pasted into
# a body by hand. A quote in the text is the way that stops being true.
foreach ($pair in @(@('ollama', $oi), @('lmstudio', $li))) {
    $ok = $true
    try { [void]($pair[1] | ConvertFrom-Json) } catch { $ok = $false }
    Assert-Eq ($pair[0] + ': parses as JSON') $ok $true
}
$quoted = Format-BrainImageMessage 'lmstudio' 'She said "no".' $b64
$ok = $true
try { [void]($quoted | ConvertFrom-Json) } catch { $ok = $false }
Assert-Eq 'a quote in the prompt is escaped' $ok $true

# No frame is not an error: it is a text-only message, and the caller decides
# whether it wanted a picture.
Assert-Eq 'no frame, ollama' (Format-BrainImageMessage 'ollama' 'Hello.' '') `
    '{"role":"user","content":"Hello."}'
Assert-Eq 'no frame, lmstudio' (Format-BrainImageMessage 'lmstudio' 'Hello.' '') `
    '{"role":"user","content":"Hello."}'

# Start-EyeVisionCall builds the body before the frame exists and substitutes
# the base64 inside the runspace that captured it. That only works while the
# marker cannot occur in base64's alphabet, and while the substitution leaves
# valid JSON behind.
$tpl = Format-BrainImageMessage 'lmstudio' 'Their screen, right now.' '@@FRAME@@'
Assert-Like 'the placeholder survives into the body' $tpl '*base64,@@FRAME@@"*'
$filled = $tpl.Replace('@@FRAME@@', $b64)
Assert-Like 'and is replaced by the frame' $filled ('*base64,' + $b64 + '"*')
$ok = $true
try { [void]($filled | ConvertFrom-Json) } catch { $ok = $false }
Assert-Eq 'the filled body is still JSON' $ok $true
# Not a style note: if '@' were in the alphabet, a frame could contain the
# marker and the next glance would substitute into the middle of an image.
Assert-Eq 'base64 cannot contain the marker' `
    ([System.Convert]::ToBase64String([byte[]](0..255 | ForEach-Object { $_ % 256 })).Contains('@')) $false

Write-Host ''
Write-Host 'Under a comma-decimal culture'
$was = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $t = Format-BrainTemp 0.9 0.9
    Assert-Eq 'temperature is still dotted' $t '0.9'
    Assert-Like 'and the body built from it is too' `
        (Get-BrainSamplingJson 'lmstudio' $t 7 '5m') '*"temperature":0.9,*'
    # '0.5m' is parsed, not just printed: [double]'0.5' is 5 under de-DE, so a
    # careless parse turns half a minute into five minutes.
    Assert-Eq 'durations parse invariantly' (ConvertTo-BrainSeconds '0.5m') 30
    Assert-Eq 'whole seconds are still whole' (ConvertTo-BrainSeconds '5m') 300
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $was
}

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host ('FAILED: ' + $script:Failed + ' check(s)')
    exit 1
}
Write-Host 'All wire-format checks passed.'
exit 0
