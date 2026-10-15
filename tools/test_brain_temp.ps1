#requires -version 5.1
# ===========================================================================
#  Sampling temperature - regression test
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_brain_temp.ps1
#
#  What it is guarding, in order of how quietly each one fails:
#
#  1. The decimal separator. "$x" on a double follows the current culture, so
#     on a machine set to a comma locale a temperature of 0.9 goes into the
#     request body as {"temperature":0,9}. Ollama rejects the whole body as
#     malformed and she simply stops answering, with nothing in glados.log
#     that points at a number. The test sets the thread culture to German and
#     checks the output is still dotted.
#  2. The ceiling. The Anthropic Messages API 400s on a temperature above 1.0
#     rather than clamping it, so that caller passes its own Max.
#  3. The junk. config.json is hand-editable and will eventually contain an
#     empty string, a missing key, or the word "high".
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

Write-Host ''
Write-Host 'Format-BrainTemp: ordinary values'
Assert-Eq 'a plain double'            (Format-BrainTemp 0.9 0.7)      '0.9'
Assert-Eq 'a string from config.json' (Format-BrainTemp '1.15' 0.7)   '1.15'
Assert-Eq 'a whole number'            (Format-BrainTemp 1 0.7)        '1'
Assert-Eq 'zero is a real setting'    (Format-BrainTemp 0 0.7)        '0'

Write-Host ''
Write-Host 'Format-BrainTemp: nothing usable, so the default stands'
Assert-Eq 'a missing config key' (Format-BrainTemp $null 0.9)   '0.9'
Assert-Eq 'an empty string'      (Format-BrainTemp '' 0.9)      '0.9'
Assert-Eq 'someone typed a word' (Format-BrainTemp 'high' 0.6)  '0.6'

Write-Host ''
Write-Host 'Format-BrainTemp: clamped, because an 8B model stops making sentences'
Assert-Eq 'a cheerful 5.0 is pulled back' (Format-BrainTemp 5.0 0.9)      '1.5'
Assert-Eq 'a negative is pulled up'       (Format-BrainTemp -2 0.9)       '0'
Assert-Eq 'the Anthropic ceiling'         (Format-BrainTemp 1.4 0.9 1.0)  '1'
Assert-Eq 'under the ceiling is untouched' (Format-BrainTemp 0.9 0.7 1.0) '0.9'

Write-Host ''
Write-Host 'Format-BrainTemp: a comma-decimal locale must not corrupt the body'
$was = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = `
        New-Object System.Globalization.CultureInfo('de-DE')
    Assert-Eq 'a double under de-DE'   (Format-BrainTemp 0.9 0.7)    '0.9'
    Assert-Eq 'a default under de-DE'  (Format-BrainTemp $null 1.15) '1.15'
    # A config.json written on a comma machine is the other half of this: the
    # value arrives as the string "0,9" and must not be read as nine.
    Assert-Eq 'a comma string is not nine' (Format-BrainTemp '0,9' 0.7) '0.7'
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $was
}

Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'all good.' }
else { Write-Host ($script:Failed.ToString() + ' failed.') }
exit $script:Failed
