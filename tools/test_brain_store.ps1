#requires -version 5.1
# ===========================================================================
#  brain store round trip - regression test
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_brain_store.ps1
#
#  There is no WinForms in brain.ps1, which is what makes this possible: the
#  whole store can be exercised from a bare prompt against a scratch file.
#
#  What it is guarding: ConvertFrom-Json on Windows PowerShell 5.1 writes a
#  JSON array to the pipeline as a single object rather than enumerating it,
#  so @(...) around it produces an array holding the array. Every record then
#  arrives nested one level too deep. Hiding a timer wrote the flag onto the
#  wrapper instead of the timer and vanished; adding a second timer wrote the
#  first one out as {"value":[...],"Count":1} and the next startup "repaired"
#  it by deleting it. Both symptoms, one cause.
# ===========================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
function Write-Log { param([string]$Message) }

$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
. (Join-Path $root 'brain\brain.ps1')

$script:BrainTimers = Join-Path $env:TEMP 'glados_test_timers.json'
$script:BrainNotes  = Join-Path $env:TEMP 'glados_test_notes.json'
$script:Failed = 0

function Reset-Store {
    foreach ($p in @($script:BrainTimers, $script:BrainNotes, ($script:BrainTimers + '.bak'))) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

function Assert-True {
    param([string]$What, $Value)
    if ($Value) { Write-Host ('  ok   ' + $What) }
    else { Write-Host ('  FAIL ' + $What); $script:Failed++ }
}

function Assert-Equal {
    param([string]$What, $Expected, $Actual)
    if ([string]$Expected -eq [string]$Actual) { Write-Host ('  ok   ' + $What) }
    else {
        Write-Host ('  FAIL ' + $What + ' - expected [' + $Expected + '] got [' + $Actual + ']')
        $script:Failed++
    }
}

function Test-Hidden {
    param($Timer)
    if (-not $Timer) { return $false }
    if (-not (@($Timer.PSObject.Properties.Name) -contains 'hidden')) { return $false }
    return [bool]$Timer.hidden
}

Write-Host 'a record comes back as a record, not as a list'
Reset-Store
[void](Add-BrainTimer ((Get-Date).AddMinutes(10)) 'tea' 'timer')
$items = @(Get-BrainStore $script:BrainTimers)
Assert-Equal 'one timer in the store' 1 $items.Count
Assert-True  'it is an object, not an array' (-not ($items[0] -is [System.Collections.IList]))
Assert-Equal 'its id survived' 1 $items[0].id

Write-Host 'hiding a timer persists'
Reset-Store
$t = Add-BrainTimer ((Get-Date).AddMinutes(10)) 'tea' 'timer'
Assert-True 'Set-BrainTimerHidden reported success' (Set-BrainTimerHidden ([int]$t.id) $true)
Assert-True 'the flag is on disk afterwards' (Test-Hidden (Get-BrainTimer ([int]$t.id)))
Assert-True 'and it can be cleared again' `
    ((Set-BrainTimerHidden ([int]$t.id) $false) -and (-not (Test-Hidden (Get-BrainTimer ([int]$t.id)))))

Write-Host 'hiding survives a reload from the file'
Reset-Store
$t = Add-BrainTimer ((Get-Date).AddMinutes(10)) 'tea' 'timer'
[void](Set-BrainTimerHidden ([int]$t.id) $true)
$raw = Get-Content -LiteralPath $script:BrainTimers -Raw
Assert-True 'the word hidden is in the file' ($raw -match '"hidden"')
Assert-True 'and reads back true' (Test-Hidden (Get-BrainTimer ([int]$t.id)))

Write-Host 'a second timer does not corrupt the first'
Reset-Store
$a = Add-BrainTimer ((Get-Date).AddMinutes(10)) 'tea' 'timer'
$b = Add-BrainTimer ((Get-Date).AddMinutes(20)) 'pie' 'timer'
$raw = Get-Content -LiteralPath $script:BrainTimers -Raw
Assert-True 'no serialised collection in the file' (-not ($raw -match '"Count"'))
$items = @(Get-BrainStore $script:BrainTimers)
Assert-Equal 'both timers are readable' 2 $items.Count
Assert-Equal 'the first kept its label' 'tea' (Get-BrainTimer ([int]$a.id)).label
Assert-Equal 'the second kept its label' 'pie' (Get-BrainTimer ([int]$b.id)).label
Assert-Equal 'ids did not collide' 2 ([int]$b.id)

Write-Host 'hiding one of several touches only that one'
[void](Set-BrainTimerHidden ([int]$b.id) $true)
Assert-True 'the second is hidden' (Test-Hidden (Get-BrainTimer ([int]$b.id)))
Assert-True 'the first is not' (-not (Test-Hidden (Get-BrainTimer ([int]$a.id))))

Write-Host 'a full store survives a repair pass untouched'
$before = Get-Content -LiteralPath $script:BrainTimers -Raw
Assert-Equal 'repair dropped nothing' 0 (Repair-BrainStore $script:BrainTimers)
Assert-Equal 'repair left the file alone' $before (Get-Content -LiteralPath $script:BrainTimers -Raw)
Assert-True  'and wrote no .bak' (-not (Test-Path -LiteralPath ($script:BrainTimers + '.bak')))

Write-Host 'an empty store is not mistaken for a record'
Reset-Store
Set-Content -LiteralPath $script:BrainTimers -Value '[]' -Encoding UTF8
Assert-Equal 'nothing is read out of it' 0 (@(Get-BrainStore $script:BrainTimers)).Count
Assert-Equal 'and repair leaves it alone' 0 (Repair-BrainStore $script:BrainTimers)

Write-Host 'real wreckage is still removed'
Reset-Store
Set-Content -LiteralPath $script:BrainTimers -Encoding UTF8 -Value `
    '[{"value":[],"Count":0},{"id":7,"due":"2030-01-01T00:00:00","label":"real","fired":false}]'
Assert-Equal 'one entry dropped' 1 (Repair-BrainStore $script:BrainTimers)
$items = @(Get-BrainStore $script:BrainTimers)
Assert-Equal 'the real one is kept' 1 $items.Count
Assert-Equal 'with its id' 7 ([int]$items[0].id)

Write-Host 'notes round trip too'
Reset-Store
[void](Set-BrainStore $script:BrainNotes @((New-Object PSObject -Property @{ id = 1; text = 'one' })))
$n = @(Get-BrainStore $script:BrainNotes)
Assert-Equal 'one note back' 1 $n.Count
Assert-Equal 'with its text' 'one' $n[0].text

Reset-Store
Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'all good.' }
else { Write-Host ($script:Failed.ToString() + ' failed.') }
exit $script:Failed
