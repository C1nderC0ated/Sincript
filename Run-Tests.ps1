<#
.SYNOPSIS
    Static-analysis test harness for Sincript (PerfTweaks.cmd + bundled data files).

.DESCRIPTION
    PerfTweaks.cmd is a single large batch script, which is awkward to unit-test by
    execution (it mutates the real system, elevates, and is interactive). Instead this
    harness statically asserts the invariants that are most prone to silent regression:

      1. Label resolution   - every `goto X` / `call :X` targets a real `:X` label.
      2. boot.config keys    - no duplicate Unity directives (guards fix #1).
      3. Preset key drift     - every key in example.preset is one the script's validator
                                actually recognizes (catches README/example drift).
      4. Reg-backup honesty  - :CreateRegBackup verifies the export before printing [OK]
                                (regression guard for fix #2).

    No external modules (no Pester) so it runs on a stock Windows PowerShell 5.1.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1

.OUTPUTS
    Writes a PASS/FAIL line per test and a summary. Exit code 0 = all passed, 1 = failure.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- locate the files under test (this script lives in <repo>\sincript\tests) ----
$TestsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptRoot = Split-Path -Parent $TestsDir
$CmdPath    = Join-Path $ScriptRoot 'PerfTweaks.cmd'
$BootPath   = Join-Path $ScriptRoot 'boot.config'
$PresetPath = Join-Path $ScriptRoot 'sincript_presets\example.preset'
$SelfPath   = $MyInvocation.MyCommand.Path

# ---- tiny assertion framework -------------------------------------------------
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Total    = 0

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    $script:Total++
    try {
        & $Body
        Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
        Write-Host ("         {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        $script:Failures.Add($Name)
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-Lines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "File under test not found: $Path" }
    return [System.IO.File]::ReadAllLines($Path)
}

# ---- helper: pull a `:label` routine body (until the next top-level label) -----
function Get-RoutineBody {
    param([string[]]$Lines, [string]$Label)
    # Real routine entry points are non-underscore labels, plus any label reached via `call`.
    # Internal goto-only sub-labels (e.g. :_sraDoWrite, :_slWritten) belong to their parent
    # routine and must stay in the body - otherwise a routine that flat-flows through an
    # internal label gets sliced short and later checks see a truncated body (false regression).
    $callTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ln in $Lines) {
        foreach ($m in [regex]::Matches($ln, '(?i)\bcall\s+:(\w+)')) { [void]$callTargets.Add($m.Groups[1].Value) }
    }
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^:{0}\b' -f [regex]::Escape($Label))) { $start = $i; break }
    }
    if ($start -lt 0) { throw "Label :$Label not found" }
    $body = New-Object System.Collections.Generic.List[string]
    for ($j = $start + 1; $j -lt $Lines.Count; $j++) {
        if ($Lines[$j] -match '^:(\w+)') {
            $lbl = $Matches[1]
            if ($lbl -notmatch '^_' -or $callTargets.Contains($lbl)) { break }   # next real routine
        }
        $body.Add($Lines[$j])
    }
    return ,$body.ToArray()
}

function Get-BodyLines {
    <#
      Preferred way to slice a routine. Use this, not Get-RoutineBody, in new tests.

      Get-RoutineBody returns `,$array` so a pipeline cannot unroll it, which makes
      `$b = Get-RoutineBody ...` correct but `$b = @(Get-RoutineBody ...)` WRONG - the @()
      wraps the array in a second array, the whole routine becomes one element, and every
      per-line assertion built on it silently does nothing. That mistake has been made five
      times, including on a test written to catch it, and it is invisible on good code:
      the body reads as empty, an early `continue`/`if` guard skips, and the test reports
      [PASS] having asserted nothing.

      This wrapper emits the lines as INDIVIDUAL pipeline objects, so every shape works and
      there is nothing to get wrong:

          $b = Get-BodyLines -Lines $cmd -Label 'X'
          $b = @(Get-BodyLines -Lines $cmd -Label 'X')
          (Get-BodyLines -Lines $cmd -Label 'X') -join "`n"

      -CodeOnly strips `rem` lines, -NoEcho also strips `echo`. Use -CodeOnly for any
      NEGATIVE assertion or IndexOf ordering check: this codebase comments heavily and its
      comments routinely quote the very construct being banned, so a raw -notmatch trips on
      prose (trap 3b). Test 121 fails the harness if the misuse-prone form reappears.
    #>
    param(
        [string[]]$Lines,
        [string]$Label,
        [switch]$CodeOnly,
        [switch]$NoEcho
    )
    $body = Get-RoutineBody -Lines $Lines -Label $Label
    foreach ($l in $body) {
        if ($CodeOnly -or $NoEcho) { if ($l.Trim() -match '^(?i)rem\b') { continue } }
        if ($NoEcho)               { if ($l.Trim() -match '^(?i)echo\b') { continue } }
        $l
    }
}

Write-Host ""
Write-Host "Sincript static-analysis tests" -ForegroundColor Cyan
Write-Host ("Target: {0}" -f $CmdPath) -ForegroundColor DarkGray
Write-Host ""

# ===============================================================================
# 1. Every goto / call target resolves to a defined label
# ===============================================================================
Invoke-Test 'All goto/call targets resolve to a real label' {
    $lines = Read-Lines $CmdPath

    $defined = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ln in $lines) {
        if ($ln -match '^:(\w+)') { [void]$defined.Add($Matches[1]) }
    }
    Assert-True ($defined.Count -gt 0) 'No labels found - parser problem?'

    $missing = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        $trimmed = $ln.TrimStart()
        # skip comment lines so words inside :: / rem text are not read as references
        if ($trimmed -match '^(?i)(rem\b|::)') { continue }

        # Blank the payload of `powershell -Command "..."` before scanning. Its contents are
        # data for a child process, not this script's control flow - and :PowerBackup's
        # payload literally assembles a DIFFERENT batch file, whose ":pt_do" / ":pt_bad"
        # labels exist only in that generated output. Same class as pitfall 27's
        # strip_echoed(): text this script emits is not text this script runs. Only the
        # quoted payload is removed, so a real `& goto :typo` after the closing quote is
        # still scanned.
        $ci = $ln.IndexOf('-Command "')
        if ($ci -ge 0) {
            $close = $ln.LastIndexOf('"')
            if ($close -gt $ci + 9) { $ln = $ln.Substring(0, $ci) + $ln.Substring($close + 1) }
        }

        foreach ($m in [regex]::Matches($ln, '(?i)\bgoto\s+:?(\w+)')) {
            $t = $m.Groups[1].Value
            if ($t -ieq 'eof') { continue }
            if (-not $defined.Contains($t)) { $missing.Add(("line {0}: goto {1}" -f ($i+1), $t)) }
        }
        foreach ($m in [regex]::Matches($ln, '(?i)\bcall\s+:(\w+)')) {
            $t = $m.Groups[1].Value
            if ($t -ieq 'eof') { continue }
            if (-not $defined.Contains($t)) { $missing.Add(("line {0}: call :{1}" -f ($i+1), $t)) }
        }
    }
    Assert-True ($missing.Count -eq 0) ("Unresolved jump target(s):`n         " + ($missing -join "`n         "))
}

# ===============================================================================
# 2. boot.config has no duplicate keys  (guards fix #1)
# ===============================================================================
Invoke-Test 'boot.config has no duplicate keys' {
    $lines = Read-Lines $BootPath
    $seen = @{}
    $dupes = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        $key = ($line -split '=', 2)[0].Trim()
        if ($key -eq '') { continue }
        if ($seen.ContainsKey($key)) { $dupes.Add($key) } else { $seen[$key] = $true }
    }
    Assert-True ($dupes.Count -eq 0) ("Duplicate key(s) in boot.config: " + ($dupes -join ', '))
}

# ===============================================================================
# 3. example.preset only uses keys the script's validator recognizes
#    (recognized set is parsed straight out of :PresetCheckLine so the test
#     tracks the real validator, not a hand-maintained copy)
# ===============================================================================
Invoke-Test 'example.preset keys are all recognized by the validator' {
    $cmd = Read-Lines $CmdPath
    $checkBody = Get-RoutineBody -Lines $cmd -Label 'PresetCheckLine'

    $recognized = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ln in $checkBody) {
        # matches:  if /i "[%!]_k[%!]"=="cleanup" ( ...
        $m = [regex]::Match($ln, '(?i)"[%!]_k[%!]"=="([^"]+)"')
        if ($m.Success) { [void]$recognized.Add($m.Groups[1].Value) }
    }
    Assert-True ($recognized.Count -ge 10) ("Parsed too few recognized keys ({0}) - parser drift?" -f $recognized.Count)

    $preset = Read-Lines $PresetPath
    $unknown = New-Object System.Collections.Generic.List[string]
    $usedCount = 0
    foreach ($raw in $preset) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        $key = ($line -split '=', 2)[0].Trim()
        if ($key -eq '') { continue }
        $usedCount++
        if (-not $recognized.Contains($key)) { $unknown.Add($key) }
    }
    Assert-True ($usedCount -gt 0) 'example.preset has no active directives - parser problem?'
    Assert-True ($unknown.Count -eq 0) ("example.preset uses key(s) the validator rejects: " + ($unknown -join ', '))

    # The commented-out examples are the ones people actually enable, so they have to be valid
    # the moment the "#" comes off. This file once shipped "# power_timeouts=1   # explanation",
    # which uncomments into a value of "1   # explanation" - rejected by the very validator this
    # file is meant to demonstrate. Prose comment lines are skipped; only "key=value" shapes are
    # judged, and they are judged by the same three format rules the README documents.
    $badExamples = New-Object System.Collections.Generic.List[string]
    $commented = 0
    foreach ($raw in $preset) {
        $line = $raw.Trim()
        if (-not ($line.StartsWith('#') -or $line.StartsWith(';'))) { continue }
        $body = $line.TrimStart('#', ';').Trim()
        if ($body -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }   # prose, not a directive
        $k = $Matches[1]; $v = $Matches[2]
        $commented++
        if (-not $recognized.Contains($k)) { $badExamples.Add("unknown key -> $body"); continue }
        if ($v -match '#')                 { $badExamples.Add("inline comment becomes part of the value -> $body") }
        if ($body -match '\s=|=\s')        { $badExamples.Add("spaces around '=' -> $body") }
        if ($v.Trim() -eq '')              { $badExamples.Add("empty value -> $body") }
    }
    Assert-True ($commented -ge 5) "Only $commented commented example directive(s) found - the file lost its opt-in examples, or the detection broke."
    Assert-True ($badExamples.Count -eq 0) ("example.preset ships commented directives that are INVALID once uncommented: " + (($badExamples | Select-Object -First 3) -join ' | '))
}

# ===============================================================================
# 4. :CreateRegBackup verifies the export before declaring success (fix #2)
# ===============================================================================
Invoke-Test ':CreateRegBackup checks errorlevel/existence before [OK]' {
    $cmd = Read-Lines $CmdPath
    $body = Get-RoutineBody -Lines $cmd -Label 'CreateRegBackup'
    $text = ($body -join "`n")

    Assert-True ($text -match '(?i)\[OK\]') ':CreateRegBackup has no [OK] message - routine changed shape?'
    Assert-True ($text -match '(?i)errorlevel')  'No errorlevel check in :CreateRegBackup - export success is not verified (regression of fix #2).'
    Assert-True ($text -match '(?i)if not exist') 'No "if not exist" file check in :CreateRegBackup - a missing export would still report success (regression of fix #2).'
    Assert-True ($text -match '(?i)\[ERROR\]')   ':CreateRegBackup has no failure ([ERROR]) branch - it cannot report a failed backup (regression of fix #2).'
}

# ===============================================================================
# 5. :Performance — the Win32PrioritySeparation writes are one mutually-exclusive
#    choice, i.e. both SafeRegAdd calls are gated by the SAME prompt variable.
#    (The bug was two independent yes/no prompts, _q3 + _q3b, which let a single
#     pass apply 42 and then reset to 2, corrupting the reset's per-value backup.)
# ===============================================================================
Invoke-Test ':Performance gates Win32PrioritySeparation on a single choice' {
    $cmd  = Read-Lines $CmdPath
    $body = Get-RoutineBody -Lines $cmd -Label 'Performance'

    $gates = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $writes = 0
    foreach ($ln in $body) {
        if ($ln -match '(?i)SafeRegAdd' -and $ln -match '(?i)Win32PrioritySeparation') {
            $writes++
            $m = [regex]::Match($ln, '[%!](_\w+)[%!]')   # the prompt var this write is gated on
            Assert-True $m.Success ("Win32PrioritySeparation write is not gated by a prompt variable:`n         " + $ln.Trim())
            [void]$gates.Add($m.Groups[1].Value)
        }
    }
    Assert-True ($writes -ge 1) 'No Win32PrioritySeparation write found in :Performance - routine changed shape?'
    Assert-True ($gates.Count -le 1) ("Win32PrioritySeparation writes are gated by multiple prompts ({0}) - they must be one mutually-exclusive choice (regression of fix #3)." -f (($gates) -join ', '))
}

# ===============================================================================
# 6. :DoCleanupCore does not wipe the Prefetch folder (placebo; fix #4).
#    Checks for an actual delete of Prefetch, not the explanatory rem that
#    documents why it is skipped.
# ===============================================================================
Invoke-Test ':DoCleanupCore does not clear the Prefetch folder' {
    $cmd  = Read-Lines $CmdPath
    $body = Get-RoutineBody -Lines $cmd -Label 'DoCleanupCore'
    $bad = @($body | Where-Object { $_ -match '(?i)\bdel\b' -and $_ -match '(?i)Prefetch' })
    Assert-True ($bad.Count -eq 0) ("Prefetch is being deleted in :DoCleanupCore (placebo - regression of fix #4):`n         " + ($bad -join "`n         "))
}

# ===============================================================================
# 7. DNS apply/reset report the real outcome instead of an unconditional [OK].
#    Both routines must capture the child exit code and delegate to :DnsResult
#    (which has an [OK] and an [ERROR] branch), and must not print [OK] inline.
# ===============================================================================
Invoke-Test 'DNS apply/reset report real success, not an unconditional [OK]' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'ApplyDns', 'DnsAuto') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)errorlevel')  ":$r does not capture the PS exit code (errorlevel) - DNS success is unverified (regression)."
        Assert-True ($t -match '(?i):DnsResult') ":$r does not delegate to :DnsResult for honest reporting (regression)."
        Assert-True ($t -notmatch '(?i)echo\s+\[OK\]') ":$r echoes an inline [OK] again - it must report via :DnsResult based on the exit code (regression)."
    }
    $dr = ((Get-RoutineBody -Lines $cmd -Label 'DnsResult') -join "`n")
    Assert-True ($dr -match '(?i)\[OK\]')    ':DnsResult has no [OK] branch - routine changed shape?'
    Assert-True ($dr -match '(?i)\[ERROR\]') ':DnsResult has no [ERROR] branch - it cannot report a failed DNS change (regression).'
}

# ===============================================================================
# 8. :InstallAsarInto verifies which OpenAsar backup actually landed before
#    reporting it, and keeps the Documents-folder fallback. (The old code wrote
#    both backups with errors silenced, then always claimed the in-folder one -
#    which Controlled Folder Access / AV often blocks.)
# ===============================================================================
Invoke-Test ':InstallAsarInto verifies which OpenAsar backup landed' {
    $cmd = Read-Lines $CmdPath
    $b = ((Get-RoutineBody -Lines $cmd -Label 'InstallAsarInto') -join "`n")
    Assert-True ($b -match '(?i)_bakloc')      ':InstallAsarInto no longer tracks which backup landed (regression - it would blindly claim the in-folder .bak again).'
    Assert-True ($b -match '(?i)BACKUP_DIR')   ':InstallAsarInto no longer writes the Documents-folder fallback backup (regression).'
    Assert-True ($b -match '(?i)if exist .*_localbak') ':InstallAsarInto does not check that the in-folder backup exists before reporting it (regression).'
}

# ===============================================================================
# 9. cmd parse safety: no unescaped ')' inside a ( ) block closes it early.
#    Inside a block cmd treats a bare ')' as the block terminator even mid-text,
#    and whatever follows raises "was unexpected at this time." - which aborts
#    the whole batch (this crashed the hosts restore/reset until fixed).
#    Per-line simulation of cmd's block parsing: quotes protect, ^ escapes,
#    '(' opens a block only at a command position, ')' closes anywhere; after a
#    close only else / & / | / ) / > / < / end-of-line are legal.
# ===============================================================================
Invoke-Test "No unescaped ')' closes a block early (hosts-restore crash class)" {
    $lines = Read-Lines $CmdPath
    $ifCond = '(?i)\bif\s+(?:/i\s+)?(?:not\s+)?(?:errorlevel\s+\S+|exist\s+(?:"[^"]*"|\S+)|defined\s+\S+|(?:"[^"]*"|\S+?)\s*(?:==|\bEQU\b|\bNEQ\b|\bLSS\b|\bLEQ\b|\bGTR\b|\bGEQ\b)\s*(?:"[^"]*"|\S+?))\s*$'
    $bad = New-Object System.Collections.Generic.List[string]
    for ($ln = 0; $ln -lt $lines.Count; $ln++) {
        $raw = $lines[$ln]
        if ($raw.TrimStart() -match '^(?i)(rem\b|::|:\w)') { continue }
        $depth = 0; $inQ = $false; $closed = $false; $pre = ''; $i = 0
        while ($i -lt $raw.Length) {
            $c = $raw[$i]
            if (-not $inQ -and $c -eq '^') { $i += 2; $pre += ' '; continue }
            if ($c -eq '"') { $inQ = -not $inQ; $i++; $closed = $false; continue }
            if ($inQ) { $i++; continue }
            if ($closed -and $c -ne ' ' -and $c -ne "`t") {
                if ($raw.Substring($i) -match '^(?i)(else\b|&|\||\)|>|<)') { $closed = $false }
                else {
                    $bad.Add(("line {0}: '{1}' follows a block close" -f ($ln + 1), $raw.Substring($i, [Math]::Min(40, $raw.Length - $i))))
                    $closed = $false
                }
            }
            if ($c -eq '(') {
                $s = $pre.TrimEnd()
                if ($s -eq '' -or $s.EndsWith('&') -or $s.EndsWith('|') -or $s.EndsWith('(') -or $s -match '(?i)\b(do|else)$' -or $s -match $ifCond) { $depth++ }
            }
            elseif ($c -eq ')') {
                if ($depth -gt 0) { $depth--; $closed = $true }
            }
            $pre += $c; $i++
        }
    }
    Assert-True ($bad.Count -eq 0) ("Unescaped ')' ends a block early - escape literal parens as ^( ^) inside blocks:`n         " + ($bad -join "`n         "))
}

# ===============================================================================
# 10. :DoPowerCore duplicates Ultimate ONTO its canonical GUID. Without the
#     destination GUID every run minted another random-GUID "Ultimate
#     Performance" clone that /setactive (which targets the canonical GUID)
#     never used - plans piled up and High was silently activated instead.
# ===============================================================================
Invoke-Test ':DoPowerPlanSwitch duplicates Ultimate onto its canonical GUID' {
    # The scheme switch moved from :DoPowerCore into :DoPowerPlanSwitch when the power
    # action gained a current-plan path; :DoPowerCore is now the compatible aggregate.
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'DoPowerPlanSwitch') -join "`n")
    Assert-True ($b -match '(?i)duplicatescheme\s+e9a42b02-d5df-448d-aa00-03f14749eb61\s+e9a42b02-d5df-448d-aa00-03f14749eb61') 'duplicatescheme lost its destination GUID - every run would create another Ultimate clone and setactive would keep falling back to High (regression).'
}

# ===============================================================================
# 11. OpenAsar download honesty: a failed Invoke-WebRequest can leave a PARTIAL
#     file, and the old code only checked existence - so a broken .asar could be
#     installed into Discord. Both download paths must gate on the child exit
#     code and delete the leftover before the existence check.
# ===============================================================================
Invoke-Test 'OpenAsar download failure is detected and the partial file removed' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'OpenAsar', 'DoOpenAsarSilent') {
        # rem-stripped: the routines carry a comment QUOTING the old broken shape to explain
        # why it was wrong, and the negative assertion below would match that comment.
        $tAll = @(Get-BodyLines -Lines $cmd -Label $r)
        Assert-True ($tAll.Count -gt 5) ":$r body did not unroll - two-step Get-RoutineBody, or every assertion below is skipped."
        $t = @($tAll | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
        # Both routines download, so neither may take the skip path - without this the whole
        # test could `continue` past every assertion and still report PASS.
        Assert-True ($t -match '(?i)Invoke-WebRequest') ":$r no longer downloads the nightly - or its body was not read (regression)."
        # The exit code must be CAPTURED before anything else runs. "del" always resets
        # errorlevel to 0, so the old shape - "if errorlevel 1 del ..." followed by
        # "if errorlevel 1 goto fail" - had a dead second line: the del between them had
        # already cleared the code being tested. Only file existence was doing any work,
        # which is exactly the case that fails when the download half-succeeds AND the del
        # is blocked (antivirus holding the fresh file): a partial .asar then installs.
        Assert-True ($t -match '(?i)set "_dlrc=%errorlevel%"') (":$r no longer captures the download exit code before anything can clobber it (regression of F-E4).")
        Assert-True ($t -match '(?i)if not "%_dlrc%"=="0" del') (":$r no longer removes the partial file when the download failed (regression of F-E4).")
        Assert-True ($t -notmatch '(?i)if\s+errorlevel\s+1\s+del\b[\s\S]{0,120}?if\s+errorlevel\s+1') (":$r tests errorlevel again AFTER a del has already reset it - that second test can never fire (regression of F-E4).")
    }
}

# ===============================================================================
# 12. Startup manager: a flip must write the value's prior state to a .reg
#     backup BEFORE changing StartupApproved, and must write via the
#     literal-safe Registry SetValue (entry names containing [ ] * ? must not
#     misfire onto a different value).
# ===============================================================================
Invoke-Test ':StartupWorker backs up the prior state before flipping' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'StartupWorker') -join "`n")
    Assert-True ($b -match '(?i)StartupApproved') ':StartupWorker no longer targets StartupApproved - routine changed shape?'
    Assert-True ($b -match 'Windows Registry Editor Version 5.00') ':StartupWorker no longer writes a .reg backup of the prior value (regression - flips would stop being undoable).'
    Assert-True ($b -match '(?i)SetValue') ':StartupWorker no longer writes via the literal-safe Registry SetValue.'
    Assert-True ($b.IndexOf('Windows Registry Editor Version 5.00') -lt $b.ToLower().IndexOf('setvalue')) ':StartupWorker writes the new value before the backup (regression - a failed backup would no longer protect the flip).'
}

# ===============================================================================
# 13. Honest registry reporting (Critical #1): :SafeRegAdd / :SafeRegDelete must
#     surface a failed write - print an inline [FAIL] AND propagate the result
#     into _FAILS across their endlocal - instead of swallowing the errorlevel
#     and letting the caller print an unconditional [OK]. (The apply tails live
#     under the :_sraApply / :_srdApply sub-labels.)
# ===============================================================================
Invoke-Test ':SafeRegAdd / :SafeRegDelete surface a failed write (no silent [OK])' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in '_sraApply', '_srdApply') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)endlocal\s*&\s*set\s*/a\s*_FAILS\s*\+=') ":$r does not carry its result into _FAILS across endlocal - a failed reg write is invisible to the caller (regression of Critical #1)."
        Assert-True ($t -match '(?i)\[FAIL\]') ":$r no longer prints an inline [FAIL] when the write fails - failures would be silent (regression of Critical #1)."
    }
}

# ===============================================================================
# 14. :Summary consults _FAILS and has both an [OK] and a [WARN] branch, so an
#     action's final line reports the real outcome (fix for Critical #1).
# ===============================================================================
Invoke-Test ':Summary gates the final line on _FAILS (has [OK] and [WARN] branches)' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'Summary') -join "`n")
    # require the real statements, not a rem-comment mention of them
    Assert-True ($b -match '(?i)%_FAILS%')             ':Summary does not consult %_FAILS% - it cannot tell success from failure (regression of Critical #1).'
    Assert-True ($b -match '(?im)^\s*echo\s+\[OK\]')   ':Summary has no "echo [OK]" branch - routine changed shape?'
    Assert-True ($b -match '(?im)^\s*echo\s+\[WARN\]') ':Summary has no "echo [WARN]" branch - a failed write would still read as success (regression of Critical #1).'
}

# ===============================================================================
# 15. Registry actions reset _FAILS before their writes and route their final
#     line through :Summary (never a raw unconditional [OK]). Spot-checked on the
#     cleanly-bounded single-purpose routines, plus a global count sanity check.
# ===============================================================================
Invoke-Test 'Registry actions reset _FAILS and report via :Summary' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'DisableMitigations','EnableMitigations','NvmeFlags','DisableIPv6','GpuAmd','HagsOff','HagsOn','WuDrvOff','WuDrvOn') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)set "_FAILS=0"') ":$r does not reset _FAILS before its writes - a stale count would mis-report (regression of Critical #1)."
        Assert-True ($t -match '(?i)call :Summary')  ":$r prints an unconditional status instead of routing through :Summary (regression of Critical #1)."
        Assert-True ($t -notmatch '(?i)echo\s+\[OK\]') ":$r still echoes an inline [OK] - it must gate that line on :Summary (regression of Critical #1)."
    }
    $all = ($cmd -join "`n")
    $sum = ([regex]::Matches($all, '(?i)call :Summary')).Count
    $rst = ([regex]::Matches($all, '(?i)set "_FAILS=0"')).Count
    Assert-True ($sum -ge 13) ("Expected >=13 :Summary call sites, found {0} - registry actions may have lost honest reporting (regression of Critical #1)." -f $sum)
    Assert-True ($rst -ge 13) ("Expected >=13 _FAILS resets, found {0} - a gated action may be missing its reset (regression of Critical #1)." -f $rst)
}

# ===============================================================================
# 16. Preset crash guard (Critical #2): :PresetCheckLine must not run the
#     trailing-space strip as an UNGUARDED substring on a possibly-empty value -
#     an empty preset value (key=) made cmd throw "syntax of the command is
#     incorrect" and abort the WHOLE script. The strip must be guarded by
#     `if defined _v` and use delayed (!) expansion, which is empty-safe.
# ===============================================================================
Invoke-Test 'Preset parser guards an empty value (no whole-script crash)' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'PresetCheckLine') -join "`n")
    Assert-True ($b -notmatch '%_v:~')      ':PresetCheckLine still uses an UNGUARDED %_v:~..% substring - an empty preset value crashes the entire script (regression of Critical #2).'
    Assert-True ($b -match '(?i)if defined _v\b') ':PresetCheckLine no longer guards the trailing-space strip with "if defined _v" - an empty value would abort the parse (regression of Critical #2).'
}

# ===============================================================================
# 17. Elevation honesty (Batch 2): the admin probe sets _ELEV=1 on the elevated
#     path, :AdminWarn sets _ELEV=0 and offers an explicit limited-mode opt-in
#     (no more silent "Continuing anyway"), and :Summary tailors its [WARN] to
#     the elevation state.
# ===============================================================================
Invoke-Test 'Non-elevated run is flagged via _ELEV and reported honestly' {
    $cmd = Read-Lines $CmdPath
    $all = ($cmd -join "`n")
    Assert-True ($all -match '(?im)^\s*if not errorlevel 1 \( set "_ELEV=1"') 'The admin probe no longer sets _ELEV=1 on the elevated path (regression of the elevation fix).'
    $aw = ((Get-RoutineBody -Lines $cmd -Label 'AdminWarn') -join "`n")
    Assert-True ($aw -match '(?i)set "_ELEV=0"')      ':AdminWarn no longer sets _ELEV=0 for the non-elevated path (regression).'
    Assert-True ($aw -notmatch '(?i)Continuing anyway') ':AdminWarn still silently continues ("Continuing anyway") instead of an explicit limited-mode opt-in (regression).'
    $sm = ((Get-RoutineBody -Lines $cmd -Label 'Summary') -join "`n")
    Assert-True ($sm -match '(?i)%_ELEV%') ':Summary no longer tailors its [WARN] to the elevation state (_ELEV) (regression).'
}

# ===============================================================================
# 18. hosts data-loss guard (Batch 2): :ApplyHosts must confirm a backup actually
#     landed (_hbak) and ABORT before overwriting if none did - the overwrite of
#     the bundled hosts must come AFTER that guard.
# ===============================================================================
Invoke-Test ':ApplyHosts verifies a backup landed before overwriting the system hosts' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ApplyHosts') -join "`n").ToLower()
    Assert-True ($b -match '_hbak') ':ApplyHosts no longer tracks whether a hosts backup landed (regression - could overwrite with no backup).'
    $abortIdx = $b.IndexOf('!_hbak!"=="0"')
    $copyIdx  = $b.IndexOf('copy /y "!script_dir!hosts"')
    Assert-True ($abortIdx -ge 0) ':ApplyHosts has no "if no backup -> abort" guard on _hbak (regression - data-loss window).'
    Assert-True ($copyIdx  -ge 0) ':ApplyHosts no longer copies the bundled hosts over the system hosts - routine changed shape?'
    Assert-True ($abortIdx -lt $copyIdx) ':ApplyHosts overwrites the system hosts BEFORE confirming a backup landed (regression of the data-loss fix).'
}

# ===============================================================================
# 19. Preset-restore honesty (Batch 2): :RestorePresetJson must capture the
#     child's exit code and branch to [WARN]/[ERROR] instead of always printing
#     [OK]. (The restore logic lives under :RestorePresetJson_ask.)
# ===============================================================================
Invoke-Test ':RestorePresetJson reports the real restore outcome (not an unconditional [OK])' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'RestorePresetJson_ask') -join "`n")
    Assert-True ($b -match '(?i)errorlevel')          ':RestorePresetJson_ask does not capture the restore child exit code (regression - cannot tell success from failure).'
    Assert-True ($b -match '(?i)_prrc')               ':RestorePresetJson_ask no longer branches on the child result (_prrc) - [OK] would be unconditional again (regression).'
    Assert-True ($b -match '(?im)^\s*echo \[WARN\]')  ':RestorePresetJson_ask has no [WARN] branch for a partial/failed restore (regression).'
    Assert-True ($b -match '(?im)^\s*echo \[ERROR\]') ':RestorePresetJson_ask has no [ERROR] branch for an unreadable backup (regression).'
}

# ===============================================================================
# 20. OpenAsar build selection (Batch 2): :InstallAsarInto must pick the app-*
#     folder by real version, not an ASCII "dir /o-n" name sort (which targets
#     the OLD build at a version digit-rollover).
# ===============================================================================
Invoke-Test ':InstallAsarInto picks the Discord build by version, not ASCII name order' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'InstallAsarInto') -join "`n")
    Assert-True ($b -notmatch '(?i)dir /b /ad /o-n') ':InstallAsarInto still uses an ASCII "dir /o-n" sort for app-* - wrong build at a version digit-rollover (regression).'
    Assert-True ($b -match '(?i)Sort-Object')        ':InstallAsarInto no longer version-sorts the app-* folders (regression).'
    Assert-True ($b -match '(?i)\[version\]')         ':InstallAsarInto no longer parses folder names as [version] for the sort (regression).'
}

# ===============================================================================
# 21. Backup escaping (Batch 3): per-value backups must ESCAPE a quote in REG_SZ
#     data (" -> \"), not drop it - otherwise the prior value can't be restored.
#     :BackupValueLine writes the .reg; :_bvjSz writes the preset JSON (it used to
#     STRIP quotes, silently losing data).
# ===============================================================================
Invoke-Test 'Per-value backups escape quotes AND handle empty REG_SZ (undo integrity)' {
    $cmd = Read-Lines $CmdPath
    $bvl = ((Get-RoutineBody -Lines $cmd -Label 'BackupValueLine') -join "`n")
    Assert-True ($bvl -match '_sd:"=\\"')      ':BackupValueLine does not escape " to \" in REG_SZ data - a prior value containing a quote makes a corrupt .reg that will not restore (regression).'
    Assert-True ($bvl -match '(?i)if defined _rd') ':BackupValueLine does not guard the REG_SZ escape on "if defined _rd" - an EMPTY REG_SZ backs up as the literal \=\\ (corrupt .reg - regression).'
    $bvj = ((Get-RoutineBody -Lines $cmd -Label '_bvjSz') -join "`n")
    Assert-True ($bvj -match '_sz:"=\\"')       ':_bvjSz does not escape " to \" for the JSON backup - a prior REG_SZ with a quote is lost (regression).'
    Assert-True ($bvj -notmatch '_sz=!_rd:"=!') ':_bvjSz still STRIPS quotes from REG_SZ data instead of escaping them (data loss - regression).'
    Assert-True ($bvj -match '(?i)if defined _rd') ':_bvjSz does not guard the escape on "if defined _rd" - an EMPTY REG_SZ writes literal \=\\ (invalid JSON breaks the whole preset restore - regression).'
}

# ===============================================================================
# 22. Backup filename collisions (Batch 3): two values under one key share the
#     sanitized key prefix, so the per-value .reg name must use %RANDOM%%RANDOM%
#     (30-bit) - a single 15-bit %RANDOM% can birthday-collide within one apply
#     pass and one value's backup would overwrite another's.
# ===============================================================================
Invoke-Test 'Per-value backup filenames use %RANDOM%%RANDOM% (collision-resistant)' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'SafeRegAdd','SafeRegDelete') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '_%RANDOM%%RANDOM%\.reg') ":$r backup filename no longer uses %RANDOM%%RANDOM% - two values under one key can collide on a single %RANDOM% and lose a per-value backup (regression)."
    }
}

# ===============================================================================
# 23. Quote-safe preset restore (Batch 3): reg.exe invoked from PowerShell 5.1
#     mangles embedded quotes, so REG_SZ values must be restored via the native
#     Set-ItemProperty cmdlet (with the hive short-name -> PSDrive conversion),
#     not "reg add /d". DWORD/delete stay on reg.exe (no quotes to mangle).
# ===============================================================================
Invoke-Test ':RestorePresetJson restores REG_SZ quote-safely (Set-ItemProperty, not reg add)' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'RestorePresetJson_ask') -join "`n")
    Assert-True ($b -match '(?i)Set-ItemProperty')     ':RestorePresetJson no longer uses Set-ItemProperty for REG_SZ - reg.exe from PowerShell mangles embedded quotes and corrupts the restore (regression).'
    Assert-True ($b -match '(?i)Registry::HKEY_USERS') ':RestorePresetJson lost the hive short-name -> PSDrive path conversion needed by Set-ItemProperty (regression).'
}

# ===============================================================================
# 24. Honest :Run reporting (Batch 4): a nonzero exit is counted into _FAILS ONLY
#     when the action is tracked (_RUNTRACK) AND the session is not elevated
#     (_ELEV=0) - where the command definitely couldn't do its privileged work.
#     When elevated, nonzero is usually benign (already-in-desired-state), so it
#     must NOT be counted (no crying wolf). :Summary clears _RUNTRACK per action.
# ===============================================================================
Invoke-Test ':Run counts failures only when tracked AND not elevated (no crying wolf)' {
    $cmd = Read-Lines $CmdPath
    $r = ((Get-RoutineBody -Lines $cmd -Label 'Run') -join "`n")
    Assert-True ($r -match '(?i)_RUNTRACK')      ':Run does not consult _RUNTRACK - best-effort cleanup deletes would be counted as failures (regression).'
    Assert-True ($r -match '(?i)%_ELEV%')        ':Run does not gate failure-counting on elevation (%_ELEV%) - it would cry wolf on benign elevated nonzero exits (regression).'
    Assert-True ($r -match '(?i)set /a _FAILS')  ':Run does not fold real failures into _FAILS - a Run-based action still cannot report honestly (regression).'
    $s = ((Get-RoutineBody -Lines $cmd -Label 'Summary') -join "`n")
    Assert-True ($s -match '(?i)set "_RUNTRACK="') ':Summary no longer clears _RUNTRACK - tracking would leak into a later untracked action (e.g. cleanup) and cry wolf (regression).'
}

# ===============================================================================
# 25. Run-based actions (Batch 4): must set _RUNTRACK=1 and report via :Summary,
#     so their sc/schtasks/netsh/bcdedit/powercfg work is honestly reported (a
#     not-elevated run shows [WARN], not a misleading [OK]).
# ===============================================================================
Invoke-Test 'Run-based actions track failures (_RUNTRACK) and report via :Summary' {
    $cmd = Read-Lines $CmdPath
    # GpuNvidia used to be here: its schtasks /TN path went through :Run+_RUNTRACK. It now
    # disables NVIDIA tasks by name via :DisableNvidiaTelemetryTasks (test 68), which bumps
    # _FAILS itself - so _RUNTRACK is no longer the right contract for that action.
    foreach ($r in 'Power','NetworkApply','NetReset','BcdTimers','BcdRevert','Privacy') {
        # Region = from :<r> to the next TOP-LEVEL label (not one starting with '_'), so a
        # sub-label like :_netNagDone / :_privSvcDone can't truncate the action before its Summary.
        $start = -1
        for ($i = 0; $i -lt $cmd.Count; $i++) { if ($cmd[$i] -match ('^:{0}\b' -f [regex]::Escape($r))) { $start = $i; break } }
        Assert-True ($start -ge 0) "Routine :$r not found - test needs updating."
        $body = New-Object System.Collections.Generic.List[string]
        for ($j = $start + 1; $j -lt $cmd.Count; $j++) {
            if ($cmd[$j] -match '^:(?!_)\w') { break }   # next top-level (non-underscore) label
            $body.Add($cmd[$j])
        }
        $t = ($body -join "`n")
        Assert-True ($t -match '(?i)set "_RUNTRACK=1"') ":$r does not set _RUNTRACK=1 - its service/boot/network failures go uncounted, so it can print [OK] when not elevated (regression)."
        Assert-True ($t -match '(?i)call :Summary')      ":$r no longer reports via :Summary - it may print an unconditional [OK] (regression)."
    }
}

# ===============================================================================
# 26. Apostrophe-safe path hand-off (Batch 4 + elevation): any path that crosses
#     into PowerShell via a quoted literal breaks on a "'" (e.g. C:\Users\O'Brien\).
#     SteamLight stages the Steam folder in PT_SLDIR; UAC relaunch stages %~f0 in
#     PT_SELF. Both must be read as $env:PT_* inside the PS command - never
#     interpolated into the -Command string.
# ===============================================================================
Invoke-Test 'Apostrophe-safe path hand-off via env vars (SteamLight + elevation)' {
    $cmd = Read-Lines $CmdPath

    $b = ((Get-RoutineBody -Lines $cmd -Label 'SteamLight') -join "`n")
    Assert-True ($b.Length -gt 0) ':SteamLight body empty - cannot verify apostrophe-safe path hand-off.'
    Assert-True ($b -match '(?i)set "PT_SLDIR=') ':SteamLight no longer stages the Steam path in PT_SLDIR before the shortcut PS call (regression).'
    Assert-True ($b -match '(?i)\$env:PT_SLDIR')  ':SteamLight no longer reads the Steam path from $env:PT_SLDIR - it interpolates it into the PS string, which an apostrophe in the path would break (regression).'

    # Elevation relaunch lives above the first label - pin the invocation line itself.
    # The path is captured into _SELFPATH at the very top (before the argument loop shifts,
    # which renumbers %0 too) and staged into PT_SELF for the child. Both halves matter:
    # the early capture keeps it pointing at THIS script, the env var keeps an apostrophe in
    # the path from breaking the single-quoted PowerShell literals.
    $joinedCmd = $cmd -join "`n"
    Assert-True ($joinedCmd -match '(?im)^\s*set "_SELFPATH=%~f0"') 'The script path is no longer captured before the argument loop - after a shift, %~f0 names an argument rather than this file (regression of F-G1).'
    Assert-True ($joinedCmd -match '(?im)^\s*set "PT_SELF=!_SELFPATH!"') 'UAC relaunch no longer stages the captured path in PT_SELF - an apostrophe in the script path would break Start-Process (regression).'
    # nothing may re-derive %~dp0 / %~f0 after the argument loop has shifted
    $shiftAt = ($cmd | Select-String -Pattern '^\s*shift\s*$' | Select-Object -First 1)
    if ($shiftAt) {
        $after = @($cmd[$shiftAt.LineNumber..($cmd.Count-1)] | Select-String -Pattern '%~[df]*0' -AllMatches)
        $bad = @($after | Where-Object { $_.Line -notmatch '^\s*rem\b' })
        Assert-True ($bad.Count -eq 0) ("%~0-derived path(s) used AFTER the argument loop shifts, where %0 is no longer this script: '$(($bad | ForEach-Object { $_.Line.Trim() }) -join ' | ')' (regression of F-G1).")
    }
    $elevPs = @($cmd | Where-Object { $_ -match '(?i)Start-Process\b' -and $_ -match '(?i)-Verb\s+RunAs' })
    Assert-True ($elevPs.Count -ge 1) 'UAC relaunch Start-Process -Verb RunAs line missing - elevation path is gone.'
    Assert-True ($elevPs[0] -match '(?i)-FilePath\s+\$env:PT_SELF\b') 'UAC relaunch no longer passes -FilePath $env:PT_SELF - embedding the path in the PS string breaks on an apostrophe (regression).'
    Assert-True ($elevPs[0] -notmatch '%~f0') 'UAC relaunch still embeds %~f0 in the PowerShell -Command string - an apostrophe in the script path would kill the relaunch (regression).'
}

# ===============================================================================
# 27. Preset honesty (Batch 5): :PresetBegin resets _FAILS so each preset's final
#     line (routed through :Summary) reflects only that preset's registry writes -
#     no preset prints an unconditional [OK].
# ===============================================================================
Invoke-Test 'Preset apply reports via :Summary (gated on _FAILS), not a blind [OK]' {
    $cmd = Read-Lines $CmdPath
    $pb = ((Get-RoutineBody -Lines $cmd -Label 'PresetBegin') -join "`n")
    Assert-True ($pb -match '(?i)set "_FAILS=0"') ':PresetBegin does not reset _FAILS - a preset :Summary would carry a stale count from a prior action (regression).'
    $all = ($cmd -join "`n")
    Assert-True ($all -notmatch '(?i)echo \[OK\] (LIGHT|MODERATE|HEAVY|Custom) preset') 'A preset still prints an unconditional [OK] instead of routing through :Summary (regression).'
    foreach ($r in 'PresetLight','PresetModerate','PresetHeavy') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)call :Summary') ":$r no longer reports via :Summary (regression)."
    }
}

# ===============================================================================
# 28. Repair/PS-action honesty (Batch 5): the admin-requiring repair actions gate
#     their status on elevation (a not-elevated run shows [WARN], not a blind [OK]).
# ===============================================================================
Invoke-Test 'Repair actions gate their status on elevation (not a blind [OK])' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'SfcDism','WUReset','CompactWinSxS','MemCompress','StoreRepair') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?im)^\s*if "%_ELEV%"=="0"') ":$r no longer gates its result on elevation (%_ELEV%) - it prints a blind [OK] even when not elevated (regression)."
        Assert-True ($t -match '(?i)\[WARN\]') ":$r has no [WARN] branch for the not-elevated case (regression)."
    }
}

# ===============================================================================
# 29. DISM/SFC stream their output live: :SfcDism runs both
#     through :RunLive, whose exec line has NO redirect - the native progress
#     display is the only sign of life on a multi-minute run. :Run (the quiet
#     path) must stay suppressed, and :RunLive must keep :Run's full
#     bookkeeping (EXEC/FAIL logging + the conservative failure tally).
# ===============================================================================
Invoke-Test ':SfcDism streams DISM/SFC via :RunLive (no output suppression)' {
    $cmd = Read-Lines $CmdPath

    $sfc = (Get-RoutineBody -Lines $cmd -Label 'SfcDism') -join "`n"
    Assert-True ($sfc -match '(?i)call :RunLive "dism /online /cleanup-image /restorehealth"') ':SfcDism no longer runs DISM through :RunLive - its output is suppressed again (regression of v1.10 change 1).'
    Assert-True ($sfc -match '(?i)call :RunLive "sfc /scannow"') ':SfcDism no longer runs SFC through :RunLive - its output is suppressed again (regression of v1.10 change 1).'

    $live = Get-RoutineBody -Lines $cmd -Label 'RunLive'
    $exec = @($live | Where-Object { $_ -match '(?i)^\s*cmd /s /c' })
    Assert-True ($exec.Count -eq 1) ':RunLive must contain exactly one "cmd /s /c" exec line.'
    Assert-True ($exec[0] -notmatch '>') (':RunLive exec line redirects output - streaming is broken: ' + $exec[0].Trim())
    $liveText = $live -join "`n"
    Assert-True ($liveText -match '(?i)EXEC:') ':RunLive lost the EXEC log line - bookkeeping must match :Run.'
    Assert-True ($liveText -match '(?i)FAIL:') ':RunLive lost the FAIL log branch - bookkeeping must match :Run.'
    Assert-True ($liveText -match '(?i)if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS\+=1') ':RunLive lost the conservative _RUNTRACK/_ELEV failure tally.'

    $runExec = @( (Get-RoutineBody -Lines $cmd -Label 'Run') | Where-Object { $_ -match '(?i)^\s*cmd /s /c' } )
    Assert-True ($runExec.Count -eq 1 -and $runExec[0] -match '>nul 2>&1') ':Run (the quiet path) no longer suppresses output - short commands would spam the console.'
}

# ===============================================================================
# 30. Laptop-aware advisories: startup classifies the machine
#     (CmBatt battery presence, pure reg query), the start log records it, and
#     every battery-hostile action shows :LaptopAdvisory BEFORE its first
#     prompt. The advisory routines must stay warning-only - no prompts, no
#     writes, no commands - or the opt-in philosophy silently breaks.
# ===============================================================================
Invoke-Test 'Machine class detected at startup; advisories warning-only and pre-prompt' {
    $cmd  = Read-Lines $CmdPath
    $text = $cmd -join "`n"

    Assert-True ($text -match '(?i)set "MACHINE=unknown"') 'Startup no longer initializes MACHINE=unknown.'
    Assert-True ($text -match '(?i)Services\\CmBatt\\Enum') 'The CmBatt battery-presence probe is gone - machine class is never detected.'
    Assert-True ($text -match '(?i)PerfTweaks start[^"]*machine=%MACHINE%') 'The start log line no longer records machine= (cross-era parity with the C# port).'

    foreach ($adv in 'LaptopAdvisory','DesktopAdvisory') {
        $b = Get-RoutineBody -Lines $cmd -Label $adv
        $t = $b -join "`n"
        Assert-True ($t -match '(?i)if /i not "%MACHINE%"=="') ":$adv does not gate on MACHINE - it would fire on every machine."
        Assert-True ($t -match '\[ADVISORY\]') ":$adv lost its [ADVISORY] output line."
        foreach ($ln in $b) {
            Assert-True ($ln -notmatch '(?i)set /p|call :SafeReg|call :Run|reg add|powercfg|bcdedit|schtasks') (":$adv is no longer warning-only - it contains: " + $ln.Trim())
        }
    }

    foreach ($r in 'Power','BcdTimers','TimerResApply','ApplyRecommended','PresetModerate','PresetHeavy') {
        $b = Get-RoutineBody -Lines $cmd -Label $r
        $ai = -1; $pi = -1
        for ($i = 0; $i -lt $b.Count; $i++) {
            if ($ai -lt 0 -and $b[$i] -match '(?i)call :LaptopAdvisory') { $ai = $i }
            if ($pi -lt 0 -and $b[$i] -match '(?i)set /p ')             { $pi = $i }
        }
        Assert-True ($ai -ge 0) ":$r lost its call :LaptopAdvisory (it applies battery-hostile changes)."
        Assert-True ($pi -lt 0 -or $ai -lt $pi) ":$r shows the laptop advisory AFTER its first prompt - the user would confirm before seeing the warning."
    }

    $perf = Get-RoutineBody -Lines $cmd -Label 'Performance'
    $di = -1; $qi = -1
    for ($i = 0; $i -lt $perf.Count; $i++) {
        if ($di -lt 0 -and $perf[$i] -match '(?i)call :DesktopAdvisory') { $di = $i }
        if ($qi -lt 0 -and $perf[$i] -match '(?i)LargeSystemCache=1')    { $qi = $i }
    }
    Assert-True ($di -ge 0 -and $qi -ge 0 -and $di -lt $qi) ':Performance no longer shows :DesktopAdvisory before the LargeSystemCache prompt.'
}

# ===============================================================================
# 31. System tools menu is wired (Pass 1): the main menu offers 12, the
#     dispatcher routes it, and the submenu routes to all three tools (PATH
#     editor, lock finder, crash report) and back.
# ===============================================================================
Invoke-Test 'System tools menu reachable and wired' {
    $cmd = Read-Lines $CmdPath
    $text = ($cmd -join "`n")
    Assert-True ($text -match '(?m)^if "!sel!"=="12" goto MenuTools\s*$') 'Main-menu dispatcher does not route 12 -> MenuTools.'
    $mtText = (Get-RoutineBody -Lines $cmd -Label 'MenuTools_ask') -join "`n"
    Assert-True ($mtText -match '(?i)if "!sel!"=="1" goto PathEditor') 'MenuTools does not route 1 -> PathEditor.'
    Assert-True ($mtText -match '(?i)if "!sel!"=="2" goto LockFinder') 'MenuTools does not route 2 -> LockFinder.'
    Assert-True ($mtText -match '(?i)if "!sel!"=="3" goto CrashReport') 'MenuTools does not route 3 -> CrashReport.'
    Assert-True ($mtText -match '(?i)if "!sel!"=="0" goto MainMenu') 'MenuTools has no 0 -> back to MainMenu.'
}

# ===============================================================================
# 32. PATH editor never INVOKES setx (Pass 1). setx silently crops PATH at 1024
#     chars and rewrites REG_EXPAND_SZ as REG_SZ - the exact damage this feature
#     exists to avoid. A mention in an explanatory echo is fine; execution is not.
# ===============================================================================
Invoke-Test 'PATH editor never invokes setx' {
    $cmd = Read-Lines $CmdPath
    foreach ($lab in 'PathEditor','PathEditor_show','PathEditor_ask','PathEditor_add','PathEditor_remove','PathEditor_run','PathWorker') {
        foreach ($line in (Get-RoutineBody -Lines $cmd -Label $lab)) {
            $t = $line.Trim()
            if ($t -match '^(?i)(echo|rem)\b') { continue }
            Assert-True ($t -notmatch '(?i)\bsetx\b') ("PATH feature INVOKES setx in :" + $lab + ": " + $t)
        }
    }
}

# ===============================================================================
# 33. PATH worker round-trips REG_EXPAND_SZ (Pass 1): reads raw with
#     DoNotExpandEnvironmentNames (so %VAR% survives) and writes ExpandString
#     (so the type PATH requires is preserved).
# ===============================================================================
Invoke-Test 'PATH worker preserves REG_EXPAND_SZ (read raw, write ExpandString)' {
    $cmd = Read-Lines $CmdPath
    $pw = (Get-RoutineBody -Lines $cmd -Label 'PathWorker') -join "`n"
    Assert-True ($pw -match 'DoNotExpandEnvironmentNames') 'PATH worker does not read with DoNotExpandEnvironmentNames - %VAR% references would be lost.'
    Assert-True ($pw -match 'RegistryValueKind\]::ExpandString') 'PATH worker does not write ExpandString - PATH would be downgraded to REG_SZ.'
}

# ===============================================================================
# 34. PATH worker advertises the change (Pass 1): the WM_SETTINGCHANGE broadcast
#     must be INVOKED at the call site - SendMessageTimeout(HWND_BROADCAST 0xffff,
#     0x1A, ...) - not merely declared in the P/Invoke signature.
# ===============================================================================
Invoke-Test 'PATH worker broadcasts WM_SETTINGCHANGE on change' {
    $cmd = Read-Lines $CmdPath
    $pw = (Get-RoutineBody -Lines $cmd -Label 'PathWorker') -join "`n"
    Assert-True ($pw -match '(?i)SendMessageTimeout\(\[IntPtr\]0xffff\s*,\s*0x1A') 'PATH worker does not INVOKE SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, ...).'
}

# ===============================================================================
# 35. PATH edits back up first (Pass 1): :PathEditor_run must call
#     :BackupSingleValue BEFORE :PathWorker performs the write.
# ===============================================================================
Invoke-Test 'PATH edit backs up the value before writing' {
    $cmd = Read-Lines $CmdPath
    $run = Get-RoutineBody -Lines $cmd -Label 'PathEditor_run'
    $bkIdx = -1; $wkIdx = -1
    for ($i = 0; $i -lt $run.Count; $i++) {
        if ($bkIdx -lt 0 -and $run[$i] -match '(?i)call :BackupSingleValue') { $bkIdx = $i }
        if ($wkIdx -lt 0 -and $run[$i] -match '(?i)call :PathWorker')        { $wkIdx = $i }
    }
    Assert-True ($bkIdx -ge 0) ':PathEditor_run never calls :BackupSingleValue - an edit would have no undo.'
    Assert-True ($wkIdx -ge 0) ':PathEditor_run never calls :PathWorker - nothing performs the edit.'
    Assert-True ($bkIdx -lt $wkIdx) ':PathEditor_run backs up AFTER the write - the backup must come first.'
}

# ===============================================================================
# 36. The PATH backup must be a real backup. :BackupValueLine - the echo-based
#     writer every tweak uses - only knows REG_DWORD and REG_SZ and honestly
#     declines the rest. That is right for the tweaks (all DWORDs), but PATH is
#     REG_EXPAND_SZ, so routing PATH through it wrote a "not auto-restorable"
#     COMMENT into the .reg while the screen still printed [BACKUP]. A comment is
#     not an undo. :BackupSingleValue therefore uses reg export, which is exact for
#     every type and never passes the value through batch string handling at all
#     (so a PATH entry containing "!" cannot be eaten by delayed expansion either).
# ===============================================================================
Invoke-Test 'PATH backup is a real backup, not a decline comment' {
    $cmd = Read-Lines $CmdPath
    $body = Get-RoutineBody -Lines $cmd -Label 'BackupSingleValue'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"

    Assert-True ($code -match '(?i)reg export "!_rk!" "!_bkp!"') ':BackupSingleValue no longer uses reg export - the only writer here that handles REG_EXPAND_SZ.'
    Assert-True ($code -notmatch '(?i)call :BackupValueLine') ':BackupSingleValue routes PATH through :BackupValueLine again. PATH is REG_EXPAND_SZ, which that writer declines - the backup would be a comment.'
    Assert-True ($code -match '(?i)if not exist "!_bkp!" goto _bsvFail') ':BackupSingleValue does not verify the backup file landed before claiming [BACKUP].'
    Assert-True ($code -match '(?i)if errorlevel 1 goto _bsvFail') ':BackupSingleValue ignores reg export failing.'
    Assert-True ($code -match '(?i)set "_BSV_OK=1"') ':BackupSingleValue never signals success, so the caller cannot gate on it.'

    # ...and the tweak writer keeps its own decline, since :SafeRegAdd still uses it
    $bvl = (Get-RoutineBody -Lines $cmd -Label 'BackupValueLine') -join "`n"
    Assert-True ($bvl -match 'not auto-restorable') ':BackupValueLine lost its non-ASCII honest-decline marker.'
}

# ===============================================================================
# 37. No backup, no edit. :ApplyHosts already refuses to overwrite the system
#      hosts file unless its backup landed (test 18); a PATH edit is the same
#      bargain, and PATH is not something a user can reconstruct from memory.
# ===============================================================================
Invoke-Test 'PATH edit aborts when no backup could be written' {
    $cmd = Read-Lines $CmdPath
    $run = Get-RoutineBody -Lines $cmd -Label 'PathEditor_run'
    $clr = -1; $bk = -1; $gate = -1; $wk = -1
    for ($i = 0; $i -lt $run.Count; $i++) {
        if ($clr  -lt 0 -and $run[$i] -match '(?i)^\s*set "_BSV_OK="')        { $clr = $i }
        if ($bk   -lt 0 -and $run[$i] -match '(?i)call :BackupSingleValue')    { $bk = $i }
        if ($gate -lt 0 -and $run[$i] -match '(?i)if not defined _BSV_OK')     { $gate = $i }
        if ($wk   -lt 0 -and $run[$i] -match '(?i)call :PathWorker')           { $wk = $i }
    }
    Assert-True ($clr -ge 0)  ':PathEditor_run does not clear _BSV_OK first - a stale 1 from an earlier edit would wave a failed backup through.'
    Assert-True ($bk -ge 0)   ':PathEditor_run never calls :BackupSingleValue.'
    Assert-True ($gate -ge 0) ':PathEditor_run does not check _BSV_OK - it would edit PATH with no undo.'
    Assert-True ($wk -ge 0)   ':PathEditor_run never calls :PathWorker.'
    Assert-True ($clr -lt $bk -and $bk -lt $gate -and $gate -lt $wk) ':PathEditor_run has the order wrong - clear, back up, check, THEN edit.'
    Assert-True ((($run[$gate..$wk]) -join "`n") -match '(?i)goto :eof') ':PathEditor_run does not actually bail out when the backup is missing.'
}

# ===============================================================================
# 38. System-PATH edits are elevation-gated (Pass 1): the combined
#     machine-scope + not-elevated check must exist on one guard line, so a
#     non-admin save is refused up front instead of failing silently.
# ===============================================================================
Invoke-Test 'System PATH edit is gated on elevation' {
    $cmd = Read-Lines $CmdPath
    $gate = @($cmd | Where-Object { $_ -match '(?i)"%PT_PE_SCOPE%"=="machine"\s+if\s+"%_ELEV%"=="0"' })
    Assert-True ($gate.Count -ge 1) ':PathEditor_show does not gate machine-scope edits on _ELEV.'
}

# ===============================================================================
# 39. Lock finder uses the Restart Manager (Pass 1): the RM calls must be WIRED
#     (::RmStartSession( / ::RmRegisterResources( / ::RmGetList( invocations, not
#     just P/Invoke declarations), and neither openfiles nor handle.exe appears.
# ===============================================================================
Invoke-Test 'Lock finder uses Restart Manager, not openfiles/handle.exe' {
    $cmd = Read-Lines $CmdPath
    $lw = (Get-RoutineBody -Lines $cmd -Label 'LockWorker') -join "`n"
    Assert-True ($lw -match '(?i)::RmStartSession\(')      'LockWorker does not INVOKE RmStartSession.'
    Assert-True ($lw -match '(?i)::RmRegisterResources\(') 'LockWorker does not INVOKE RmRegisterResources.'
    Assert-True ($lw -match '(?i)::RmGetList\(')           'LockWorker does not INVOKE RmGetList.'
    # NB: Get-RoutineBody returns ,$arr - collecting via a pipeline keeps each result
    # as a String[] object and -join would stringify them as 'System.String[]'.
    # Concatenate the arrays directly instead.
    $lfAll = ((Get-RoutineBody -Lines $cmd -Label 'LockFinder') + (Get-RoutineBody -Lines $cmd -Label 'LockFinder_ask') + (Get-RoutineBody -Lines $cmd -Label 'LockWorker')) -join "`n"
    Assert-True ($lfAll -notmatch '(?i)\bopenfiles\b') 'Lock finder uses openfiles (needs a global flag + reboot).'
    Assert-True ($lfAll -notmatch '(?i)handle\.exe')   'Lock finder shells out to handle.exe (external dependency).'
}

# ===============================================================================
# 40. Critical-process refusal (Pass 1): the worker classifies RmCritical (1000)
#     and the menu BLOCKS a close on a critical row.
# ===============================================================================
Invoke-Test 'Lock finder refuses to kill critical system processes' {
    $cmd = Read-Lines $CmdPath
    $lw = (Get-RoutineBody -Lines $cmd -Label 'LockWorker') -join "`n"
    Assert-True ($lw -match 'Critical' -and $lw -match '1000') 'LockWorker does not classify RmCritical (1000).'
    $ask = (Get-RoutineBody -Lines $cmd -Label 'LockFinder_ask') -join "`n"
    # indexes with _lfi - the VALIDATED copy of the user's pick - not raw set /p input
    Assert-True ($ask -match '(?i)_lfcrit\[%_lfi%\]!"=="critical"') ':LockFinder_ask does not block a close on a critical process.'
    Assert-True ($ask -match '(?i)set "_lfi=%_lfk%"') ':LockFinder_ask no longer copies the validated pick into _lfi - raw set /p input would be indexing inside blocks again.'
    Assert-True ($ask -match '(?i)BLOCKED') ':LockFinder_ask has no BLOCKED message for a critical process.'
}

# ===============================================================================
# 41. Close is opt-in, per-PID, taskkill (Pass 1): one confirmed PID via
#     taskkill /PID, never RmShutdown (which shuts down every registered app).
# ===============================================================================
Invoke-Test 'Lock finder terminates one PID via taskkill, not RmShutdown' {
    $cmd = Read-Lines $CmdPath
    $lf = ((Get-RoutineBody -Lines $cmd -Label 'LockFinder') + (Get-RoutineBody -Lines $cmd -Label 'LockFinder_ask')) -join "`n"
    $lw = (Get-RoutineBody -Lines $cmd -Label 'LockWorker') -join "`n"
    Assert-True ($lf -match '(?i)taskkill /PID') 'Lock finder does not use taskkill /PID for the opt-in close.'
    Assert-True ($lf -match '(?i)Proceed\? \(Y/N\)') 'Lock finder close is not gated behind a Y/N confirm.'
    Assert-True (($lf + $lw) -notmatch 'RmShutdown') 'Lock finder calls RmShutdown - it must close one chosen PID only.'
}

# ===============================================================================
# 42. Worker hygiene (Pass 1): both workers clear their PT_* hand-off variables
#     after the child returns (same discipline as the DNS/Startup workers).
# ===============================================================================
Invoke-Test 'System-tools workers clear their PT_* hand-off variables' {
    $cmd = Read-Lines $CmdPath
    $pw = (Get-RoutineBody -Lines $cmd -Label 'PathWorker') -join "`n"
    foreach ($v in 'PT_PE_MODE','PT_PE_ARG','PT_PE_LIST','PT_PE_RES') {
        Assert-True ($pw -match ('(?i)set "' + $v + '="')) ("PathWorker does not clear " + $v + " after the child.")
    }
    $lw = (Get-RoutineBody -Lines $cmd -Label 'LockWorker') -join "`n"
    foreach ($v in 'PT_LF_LIST','PT_LF_FILE') {
        Assert-True ($lw -match ('(?i)set "' + $v + '="')) ("LockWorker does not clear " + $v + " after the child.")
    }
}

# ===============================================================================
# 43. Windows AI off by policy (Pass 2): :DoPrivacyCore writes the five-key
#     core - Copilot off in BOTH scopes (HKCU + HKLM TurnOffWindowsCopilot=1),
#     Recall blocked (AllowRecallEnablement=0, TurnOffSavingSnapshots=1,
#     DisableAIDataAnalysis=1) and Click to Do off.
# ===============================================================================
Invoke-Test ':DoPrivacyCore turns off Windows AI (Copilot/Recall) by policy' {
    $cmd = Read-Lines $CmdPath
    $pc = (Get-RoutineBody -Lines $cmd -Label 'DoPrivacyCore') -join "`n"
    Assert-True ($pc -match '(?i)"HKCU\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsCopilot" "TurnOffWindowsCopilot" REG_DWORD 1') 'Copilot user-policy (HKCU TurnOffWindowsCopilot=1) missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsCopilot" "TurnOffWindowsCopilot" REG_DWORD 1') 'Copilot machine-policy (HKLM TurnOffWindowsCopilot=1) missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"AllowRecallEnablement" REG_DWORD 0')  'Recall enablement is not blocked (AllowRecallEnablement=0 missing).'
    Assert-True ($pc -match '(?i)"TurnOffSavingSnapshots" REG_DWORD 1') 'Recall snapshots are not turned off (TurnOffSavingSnapshots=1 missing).'
    Assert-True ($pc -match '(?i)"DisableAIDataAnalysis" REG_DWORD 1')  'Recall data analysis is not turned off (DisableAIDataAnalysis=1 missing).'
    Assert-True ($pc -match '(?i)"DisableClickToDo" REG_DWORD 1')       'Click to Do is not turned off (DisableClickToDo=1 missing).'
}

# ===============================================================================
# 44. Input/speech personalization off (Pass 2): both AllowInputPersonalization
#     scopes = 0, RestrictImplicitTextCollection = 1, HarvestContacts = 0, and
#     online speech HasAccepted = 0.
# ===============================================================================
Invoke-Test ':DoPrivacyCore disables inking/typing/speech personalization' {
    $cmd = Read-Lines $CmdPath
    $pc = (Get-RoutineBody -Lines $cmd -Label 'DoPrivacyCore') -join "`n"
    Assert-True ($pc -match '(?i)"HKCU\\SOFTWARE\\Policies\\Microsoft\\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0') 'HKCU AllowInputPersonalization=0 missing.'
    Assert-True ($pc -match '(?i)"HKLM\\SOFTWARE\\Policies\\Microsoft\\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0') 'HKLM AllowInputPersonalization=0 missing.'
    Assert-True ($pc -match '(?i)"RestrictImplicitTextCollection" REG_DWORD 1') 'RestrictImplicitTextCollection=1 missing.'
    Assert-True ($pc -match '(?i)"HarvestContacts" REG_DWORD 0') 'HarvestContacts=0 missing.'
    Assert-True ($pc -match '(?i)OnlineSpeechPrivacy" "HasAccepted" REG_DWORD 0') 'Online speech HasAccepted=0 missing.'
}

# ===============================================================================
# 45. Telemetry-floor honesty (Pass 2): the Privacy screen must disclose that
#     Home/Pro clamp AllowTelemetry=0 to Basic (1) and only Enterprise/Education
#     honor 0 - the [OK]-honesty rule applied to copy, so the screen never
#     implies zero telemetry on editions that cannot reach it.
# ===============================================================================
Invoke-Test 'Privacy screen discloses the Home/Pro telemetry floor' {
    $cmd = Read-Lines $CmdPath
    $pv = (Get-RoutineBody -Lines $cmd -Label 'Privacy') -join "`n"
    Assert-True ($pv -match '(?i)Home/Pro') 'Privacy banner does not mention the Home/Pro editions.'
    Assert-True ($pv -match '(?i)Basic \(1\)') 'Privacy banner does not state the Basic (1) floor.'
    Assert-True ($pv -match '(?i)Enterprise') 'Privacy banner does not say which editions honor 0.'
}

# ===============================================================================
# 46. DiagTrack side-effect honesty (Pass 2): the Privacy screen must disclose
#     that stopping DiagTrack also stops Xbox achievement sync and Feedback Hub.
# ===============================================================================
Invoke-Test 'Privacy screen discloses the DiagTrack Xbox/Feedback Hub side effect' {
    $cmd = Read-Lines $CmdPath
    $pv = (Get-RoutineBody -Lines $cmd -Label 'Privacy') -join "`n"
    Assert-True ($pv -match '(?i)Xbox achievement') 'Privacy banner does not disclose the Xbox achievements side effect.'
    Assert-True ($pv -match '(?i)Feedback Hub') 'Privacy banner does not disclose the Feedback Hub side effect.'
}

# ===============================================================================
# 47. SysMain knob (Pass 3): the Windows disk is probed, :DiskAdvisory is shown
#     BEFORE the prompt, and that advisory stays warning-only - the same contract
#     test 30 holds :LaptopAdvisory to, just gated on SYSDISK instead of MACHINE.
#     SysMain genuinely helps a mechanical disk, so the hint must reach the user
#     before they answer, and must never block or change a default.
# ===============================================================================
Invoke-Test 'SysMain knob: disk probed, advisory warning-only and pre-prompt' {
    $cmd = Read-Lines $CmdPath

    # Code only - the routine's comment names Get-PhysicalDisk/Get-Partition to explain
    # why they are NOT the primary, so a body-wide match would assert against prose.
    $probeBody = Get-RoutineBody -Lines $cmd -Label 'DetectSysDisk'
    $probe = @($probeBody | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"

    Assert-True ($probe -match '(?i)set "SYSDISK=unknown"') ':DetectSysDisk no longer defaults SYSDISK=unknown - a failed probe must not masquerade as a known disk.'
    Assert-True ($probe -match '(?i)if defined SYSDISK goto :eof') ':DetectSysDisk lost its cache guard - it would relaunch PowerShell on every visit.'

    # The primary must be the seek-penalty IOCTL. It asks the device directly and does not
    # touch root\Microsoft\Windows\Storage - the namespace that threw CimException
    # "Invalid property" on real hardware (HP Omen, NVMe SSD) for EVERY cmdlet in it,
    # while this IOCTL answered correctly.
    Assert-True ($probe -match '\[PTDisk\.N\]::DeviceIoControl\(') ':DetectSysDisk no longer INVOKES the seek-penalty IOCTL (the P/Invoke declaration alone proves nothing) - it would be back to depending on the Storage CIM namespace, which a single broken vendor provider takes down.'
    Assert-True ($probe -match '\[PTDisk\.N\]::CreateFile\(')      ':DetectSysDisk no longer opens the volume handle the IOCTL needs.'
    Assert-True ($probe -match '0x2D1400')          ':DetectSysDisk lost IOCTL_STORAGE_QUERY_PROPERTY (0x2D1400).'
    Assert-True ($probe -match '\$q\.PropertyId=7') ':DetectSysDisk no longer queries StorageDeviceSeekPenaltyProperty (PropertyId 7) - the actual SSD-vs-spinning question.'

    # Polarity matters more than anything else here: a seek penalty IS the spinning platter.
    # Inverted, the advisory tells SSD owners to keep SysMain and HDD owners to drop it -
    # confidently backwards advice, which is worse than the "unknown" it replaced.
    Assert-True ($probe -match 'if\(\$d\.IncursSeekPenalty\)\{ \$t=''hdd'' \}else\{ \$t=''ssd'' \}') ':DetectSysDisk has the seek-penalty mapping backwards or reworded - a seek penalty means a spinning disk (hdd); no penalty means ssd.'

    # Regression guard for the exact chain that failed in the field: Get-Partition piped
    # into Get-Disk piped into Get-PhysicalDisk. The MediaType fallback may still name
    # Get-PhysicalDisk on its own, so pin the *chain*, not the cmdlet.
    Assert-True ($probe -notmatch '(?i)Get-Disk[^|]*\|\s*Get-PhysicalDisk') ':DetectSysDisk pipes Get-Disk into Get-PhysicalDisk again - that chain returned "unknown" on real hardware and there is no ByDisk parameter set for it.'

    # ...and MediaType must stay a fallback: it may only run when the IOCTL said nothing.
    Assert-True ($probe -match 'if\(\$t -eq ''unknown''\)') ':DetectSysDisk no longer gates the MediaType fallback on the IOCTL failing - the CIM path must never be the primary.'

    $adv = Get-RoutineBody -Lines $cmd -Label 'DiskAdvisory'
    $advText = $adv -join "`n"
    # A confirmed SSD must still return EARLY - the branch may print a positive line
    # first, but it must not fall through into the HDD/unknown caveat.
    $ssdIdx = -1; $eofIdx = -1; $hddIdx = -1
    for ($i = 0; $i -lt $adv.Count; $i++) {
        if ($ssdIdx -lt 0 -and $adv[$i] -match '(?i)if /i "%SYSDISK%"=="ssd"') { $ssdIdx = $i }
        if ($ssdIdx -ge 0 -and $eofIdx -lt 0 -and $adv[$i] -match '(?i)goto :eof')   { $eofIdx = $i }
        if ($hddIdx -lt 0 -and $adv[$i] -match '(?i)"%SYSDISK%"=="hdd"')             { $hddIdx = $i }
    }
    Assert-True ($ssdIdx -ge 0) ':DiskAdvisory no longer branches on a confirmed SSD.'
    Assert-True ($eofIdx -gt $ssdIdx) ':DiskAdvisory does not return early on a confirmed SSD - it would fall through and tell SSD users to keep SysMain enabled.'
    Assert-True ($hddIdx -lt 0 -or $eofIdx -lt $hddIdx) ':DiskAdvisory reaches the HDD branch on a confirmed SSD.'
    Assert-True ($advText -match '(?i)"%SYSDISK%"=="hdd"') ':DiskAdvisory lost its HDD branch - the one case where the hint actually matters.'
    Assert-True ($advText -match '\[ADVISORY\]') ':DiskAdvisory lost its [ADVISORY] output line.'
    foreach ($ln in $adv) {
        Assert-True ($ln -notmatch '(?i)set /p|call :SafeReg|call :Run|reg add|powercfg|bcdedit|schtasks') (':DiskAdvisory is no longer warning-only - it contains: ' + $ln.Trim())
    }

    # the knob itself, and the probe+advisory ordering ahead of its prompt
    $perf = Get-RoutineBody -Lines $cmd -Label 'Performance'
    $pi = -1; $ai = -1; $qi = -1
    for ($i = 0; $i -lt $perf.Count; $i++) {
        if ($pi -lt 0 -and $perf[$i] -match '(?i)call :DetectSysDisk') { $pi = $i }
        if ($ai -lt 0 -and $perf[$i] -match '(?i)call :DiskAdvisory')  { $ai = $i }
        if ($qi -lt 0 -and $perf[$i] -match '(?i)set /p "_q10=')       { $qi = $i }
    }
    Assert-True ($pi -ge 0) ':Performance never calls :DetectSysDisk - the SysMain advisory would have nothing to go on.'
    Assert-True ($ai -ge 0) ':Performance never calls :DiskAdvisory before the SysMain knob.'
    Assert-True ($qi -ge 0) ':Performance lost the SysMain prompt (_q10).'
    Assert-True ($pi -lt $ai -and $ai -lt $qi) ':Performance probes/advises AFTER the SysMain prompt - the user would answer before seeing the warning.'

    $perfText = $perf -join "`n"
    Assert-True ($perfText -match '(?i)"HKLM\\SYSTEM\\CurrentControlSet\\Services\\SysMain" "Start" REG_DWORD 4') 'The SysMain knob no longer disables the service via the backed-up :SafeRegAdd path.'
    Assert-True ($perfText -match '(?i)call :Run "sc stop SysMain"') 'The SysMain knob no longer stops the running service - it would look applied but change nothing until the next reboot.'
}

# ===============================================================================
# 48. Pass-3 policy knobs: CPU power throttling (in :Power, which test 30 already
#     proves shows the laptop advisory pre-prompt) and Delivery Optimization peer
#     sharing (in :NetworkApply). Both go through :SafeRegAdd so each is backed up
#     and reversible like every other registry change.
# ===============================================================================
Invoke-Test 'Power-throttling and Delivery-Optimization knobs write reversible policy' {
    $cmd = Read-Lines $CmdPath

    $pw = (Get-RoutineBody -Lines $cmd -Label 'Power') -join "`n"
    Assert-True ($pw -match '(?i)call :SafeRegAdd "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerThrottling" "PowerThrottlingOff" REG_DWORD 1') ':Power lost the CPU power-throttling knob (or it stopped using :SafeRegAdd, losing the backup).'

    $na = (Get-RoutineBody -Lines $cmd -Label 'NetworkApply') -join "`n"
    Assert-True ($na -match '(?i)call :SafeRegAdd "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization" "DODownloadMode" REG_DWORD 0') ':NetworkApply lost the Delivery Optimization knob (or it stopped using :SafeRegAdd, losing the backup).'
}

# ===============================================================================
# 49. Extra telemetry tasks (Pass 3) are disabled BY NAME. schtasks /Change needs a
#     task's full folder path; an unverified path fails quietly and the run still
#     looks clean while the task stays enabled. Get-ScheduledTask finds the task
#     wherever it lives, and the routine must report found/disabled honestly rather
#     than printing a blind [OK]. Safety: only the DiskDiagnostic DataCollector (it
#     uploads drive SMART data) may be listed - never the Resolver, which is what
#     warns you about a dying disk.
# ===============================================================================
Invoke-Test 'Extra telemetry tasks disabled by name; disk Resolver never touched' {
    $cmd = Read-Lines $CmdPath
    $b = Get-RoutineBody -Lines $cmd -Label 'DisableTelemetryTasks'
    $t = $b -join "`n"
    # Match CODE, never prose: this routine's comment names Get-ScheduledTask and schtasks
    # to explain the choice, so a body-wide -match would pass even with the code gutted.
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"

    Assert-True ($code -match 'Get-ScheduledTask')     ':DisableTelemetryTasks no longer looks tasks up by name.'
    Assert-True ($code -match 'Disable-ScheduledTask') ':DisableTelemetryTasks no longer disables anything.'
    Assert-True ($code -notmatch '(?i)schtasks')       ':DisableTelemetryTasks INVOKES schtasks - an unverified task path fails silently, which is why this routine looks tasks up by name.'

    Assert-True ($code -match 'Microsoft-Windows-DiskDiagnosticDataCollector') 'The disk SMART-telemetry collector is no longer in the task list.'
    Assert-True ($code -notmatch '(?i)DiskDiagnosticResolver') 'The DiskDiagnostic RESOLVER is in the disable list - that is the task that warns about a failing disk and must never be disabled.'

    # honest reporting: absent / found-but-failed / success are three distinct outcomes,
    # and the two guard branches must precede the [OK].
    $si = -1; $fi = -1; $oi = -1
    for ($i = 0; $i -lt $b.Count; $i++) {
        if ($si -lt 0 -and $b[$i] -match '\[SKIP\]') { $si = $i }
        if ($fi -lt 0 -and $b[$i] -match '\[FAIL\]') { $fi = $i }
        if ($oi -lt 0 -and $b[$i] -match '\[OK\]')   { $oi = $i }
    }
    Assert-True ($si -ge 0) ':DisableTelemetryTasks lost its [SKIP] branch - a task absent on this edition would be reported as a success.'
    Assert-True ($fi -ge 0) ':DisableTelemetryTasks lost its [FAIL] branch - found-but-not-disabled would be reported as a success.'
    Assert-True ($oi -ge 0) ':DisableTelemetryTasks never reports success.'
    Assert-True ($si -lt $oi -and $fi -lt $oi) ':DisableTelemetryTasks prints [OK] before its guard branches - that is an unconditional [OK].'
}

# ===============================================================================
# 50. DiagTrack firewall block (Pass 3) flips Windows' OWN built-in DiagTrack rule
#     group from Allow to Block - the same thing Sophia does. It must not invent a
#     netsh rule (nothing to name, nothing to clean up), and it must count what it
#     actually changed instead of assuming.
# ===============================================================================
Invoke-Test 'DiagTrack firewall flips the built-in rule group, honestly counted' {
    $cmd = Read-Lines $CmdPath
    $b = Get-RoutineBody -Lines $cmd -Label 'DiagTrackFirewall'
    # Code only - the undo comment names Set-NetFirewallRule, and prose must never
    # be able to satisfy an assertion about behaviour.
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"

    Assert-True ($code -match 'Get-NetFirewallRule -Group DiagTrack') ':DiagTrackFirewall no longer targets the built-in DiagTrack rule group.'
    Assert-True ($code -match 'Set-NetFirewallRule')                  ':DiagTrackFirewall no longer changes the rules.'
    Assert-True ($code -match '(?i)-Action Block')                    ':DiagTrackFirewall no longer blocks (Action Block is gone).'
    Assert-True ($code -notmatch '(?i)netsh advfirewall')             ':DiagTrackFirewall invents a netsh rule - it must flip the rules Windows already ships.'

    $si = -1; $fi = -1; $oi = -1
    for ($i = 0; $i -lt $b.Count; $i++) {
        if ($si -lt 0 -and $b[$i] -match '\[SKIP\]') { $si = $i }
        if ($fi -lt 0 -and $b[$i] -match '\[FAIL\]') { $fi = $i }
        if ($oi -lt 0 -and $b[$i] -match '\[OK\]')   { $oi = $i }
    }
    Assert-True ($si -ge 0 -and $fi -ge 0 -and $oi -ge 0) ':DiagTrackFirewall lost one of its three outcomes (no rules / none changed / blocked N).'
    Assert-True ($si -lt $oi -and $fi -lt $oi) ':DiagTrackFirewall prints [OK] before its guard branches - that is an unconditional [OK].'

    # the opt-in lives on the Privacy screen
    $pv = (Get-RoutineBody -Lines $cmd -Label 'Privacy') -join "`n"
    Assert-True ($pv -match '(?i)call :DiagTrackFirewall') 'The Privacy screen no longer offers the firewall block.'
}

# ===============================================================================
# 51. The Pass-3 declines stay declined. Each was checked against Microsoft's own
#     documentation and rejected: SvcHostSplitThresholdInKB (MS splits svchost on
#     purpose for inter-service isolation and reliability; regrouping buys a modest
#     RAM saving), ServicesPipeTimeout=30000 (30 s already IS the SCM default, so it
#     is a no-op, and it would undo a real 60000 fix), EnablePrefetcher=0 (same cost
#     as clearing the Prefetch folder, which this script already declines, made
#     permanent). TdrDelay / TdrLevel joined them with the crash report: Microsoft
#     documents them for driver testing and says end users should not change them
#     (TdrLevel=0 turns detection off); the report names them in echo text only.
#     This test guards BOTH halves of "be honest": the reasons stay visible on the
#     Excluded screen, and no code path ever writes the values.
# ===============================================================================
Invoke-Test 'Declined tweaks stay declined and stay documented' {
    $cmd = Read-Lines $CmdPath
    $excluded = (Get-RoutineBody -Lines $cmd -Label 'Excluded') -join "`n"

    foreach ($d in 'SvcHostSplitThresholdInKB','ServicesPipeTimeout','EnablePrefetcher','TdrDelay','TdrLevel') {
        Assert-True ($excluded -match [regex]::Escape($d)) ("The Excluded screen no longer explains why $d is left out - the decline became invisible to the user.")
        foreach ($ln in $cmd) {
            $s = $ln.Trim()
            if ($s -match '^(?i)(echo|rem)\b') { continue }   # explaining it is the point; writing it is not
            Assert-True ($s -notmatch [regex]::Escape($d)) ("$d is declined on the Excluded screen but written by: " + $s)
        }
    }
}

# ===============================================================================
# 52. Cleanup deletes can never fire on a collapsed path. Batch does not error on
#     an unset variable - it expands to nothing - so "del /f /s /q "%TEMP%\*.*""
#     silently becomes "del /f /s /q "\*.*"": a RECURSIVE delete from the root of
#     the current drive. Quoting does not help; the quotes are intact, the content
#     collapsed. Every root must therefore be proven up front and every delete
#     gated on its root. Six entry points inherit this (menu 1, Apply recommended,
#     all three built-in presets, and custom presets), so it is worth pinning hard.
# ===============================================================================
Invoke-Test 'Cleanup deletes are gated on a proven root' {
    $cmd  = Read-Lines $CmdPath
    $body = Get-RoutineBody -Lines $cmd -Label 'DoCleanupCore'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' })
    $text = $code -join "`n"

    foreach ($r in 'TEMP','SystemRoot','LocalAppData') {
        # :CleanRoot takes the variable NAME and reads the value itself, late - a path passed as
        # %2 lost a "!" in the user name (test 133 runs it).
        Assert-True ($text -match ('(?im)^\s*call :CleanRoot ' + $r + '\s*$')) ":DoCleanupCore no longer proves $r before deleting under it."
    }

    # Every delete that interpolates a variable must be gated. A single ungated one
    # is the whole bug back again. The deletes under the user profile hand :RunVar the
    # command by name (test 134) - gated the same way, on the same line.
    $n = 0
    foreach ($ln in $code) {
        if ($ln -match '(?i)call :Run "del ' -or $ln -match '(?i)set "_runcmd=del ') {
            $n++
            Assert-True ($ln -match '(?i)^\s*if defined _clean(TEMP|SystemRoot|LocalAppData)\s') ("Ungated delete in :DoCleanupCore - if its root variable is unset this deletes from a drive root: " + $ln.Trim())
        }
        if ($ln -match '(?i)set "_runcmd=del ') {
            Assert-True ($ln -match '(?i)& call :RunVar _runcmd\)\s*$') ("A delete in :DoCleanupCore sets its command but does not run it through :RunVar on the same gated line: " + $ln.Trim())
        }
    }
    Assert-True ($n -ge 10) ("Only $n deletes were found in :DoCleanupCore - the scan is not seeing them, so the gating check above proved nothing.")
}

# ===============================================================================
# 53. :CleanRoot only approves a root that cannot collapse: set, a real directory,
#     and not a drive root (%TEMP%=C:\ would turn the first delete into
#     "del /f /s /q "C:\*.*"" with /s still attached). The approval flag must be
#     set only after ALL three guards, and a refusal must be spoken, not silent.
# ===============================================================================
Invoke-Test ':CleanRoot refuses unset, non-directory and drive-root values' {
    $cmd = Read-Lines $CmdPath
    $b   = Get-RoutineBody -Lines $cmd -Label 'CleanRoot'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' })
    $text = $code -join "`n"

    Assert-True ($text -match '(?i)if not defined _crv')    ':CleanRoot no longer rejects an unset root - the collapse case this exists for.'
    Assert-True ($text -match 'if not exist "!_crv!\\"') ':CleanRoot no longer requires the root to be a real directory.'
    Assert-True ($text -match '(?i)if "!_crv:~3!"==""')     ':CleanRoot no longer rejects a drive root.'
    Assert-True ($text -match '(?i)set "_clean%~1=1"')      ':CleanRoot never approves anything - cleanup would silently do nothing.'

    # the approval must come last: after every guard, never before one
    $approve = -1; $guards = @()
    for ($i = 0; $i -lt $code.Count; $i++) {
        if ($approve -lt 0 -and $code[$i] -match '(?i)set "_clean%~1=1"') { $approve = $i }
        if ($code[$i] -match '(?i)if not defined _crv|if not exist "!_crv!|if "!_crv:~3!"==""') { $guards += $i }
    }
    Assert-True ($approve -ge 0)          ':CleanRoot lost its approval line.'
    Assert-True ($guards.Count -ge 3)     ':CleanRoot is missing one of its three guards (unset / not-a-directory / drive-root).'
    foreach ($g in $guards) {
        Assert-True ($g -lt $approve) ':CleanRoot approves the root before finishing its guards - a bad root would be approved anyway.'
    }

    # a refusal has to be visible, or cleanup silently does nothing and still says [OK]
    Assert-True ((($b | Where-Object { $_ -match '\[SKIP\]' }).Count) -ge 3) ':CleanRoot stopped reporting why it refused a root - the skip would be silent.'
}

# ===============================================================================
# 54. Nothing multi-step may depend on a bundled file. :RequireBundledFile aborts
#     with "goto MenuApps", which is correct ONLY because every caller today is a
#     single Apps-menu action that has not changed anything yet (:UnityBoot,
#     :ApplyHosts, :TimerResApply). Called from a *Core routine, a preset, or
#     Apply recommended, that same goto would abandon the run mid-way, skip
#     :Summary, and drop the user on an unrelated menu with the machine half
#     configured - a silent partial apply, which is the one thing this script
#     refuses to do. If a bundled-file dependency ever needs to move into a
#     multi-step path, :RequireBundledFile must return a status first.
# ===============================================================================
Invoke-Test 'Multi-step runs never depend on a bundled file' {
    $cmd = Read-Lines $CmdPath

    $multi = @($cmd | Where-Object { $_ -match '^:(Do\w+Core|Preset\w+|ApplyRecommended)\s*$' } |
                      ForEach-Object { $_.Trim().TrimStart(':') })
    Assert-True ($multi.Count -ge 5) 'Could not find the multi-step routines - this test would pass vacuously.'

    foreach ($r in $multi) {
        $rBody = Get-RoutineBody -Lines $cmd -Label $r
        $b = @($rBody | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($b.Length -gt 0) ("Could not read the body of :$r - this check would pass vacuously.")
        Assert-True ($b -notmatch '(?i)call :RequireBundledFile') (":$r depends on a bundled file. A multi-step run must not hinge on an OPTIONAL file being present - it would abandon the run part-way and skip :Summary. The guard returns a status now, so if this ever becomes deliberate the caller must check errorlevel and carry on rather than abort.")
    }

    # and the guard must still actually abort rather than fall through - but as a RETURN,
    # not a jump. See test 105 for why the old "goto MenuApps" was a call-stack leak.
    $rbBody = Get-RoutineBody -Lines $cmd -Label 'RequireBundledFile'
    $rb = @($rbBody | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($rb -match '(?i)exit /b 1') ':RequireBundledFile no longer aborts on a missing file - the caller would run on without it.'
    Assert-True ($rb -match '(?i)exit /b 0') ':RequireBundledFile no longer returns success explicitly - the caller would read a stale errorlevel from whatever ran last (regression of F-B1).'
}

# ===============================================================================
# 55. User input must never be percent-expanded inside a ( ) block. cmd expands
#     %var% at PARSE time - before it evaluates the condition, and before it works
#     out where the block ends. So a value containing ")" injects a bare paren into
#     the block structure and cmd aborts the whole script with "was unexpected at
#     this time". This is not hypothetical: typing
#         C:\Program Files (x86)\Steam\steam.exe
#     into the lock finder killed sincript outright, while a paren-free path worked
#     - and it happened whether or not the file existed, because the block is parsed
#     before the `if` is even tested.
#
#     !var! expands at RUN time, after the block is parsed, so the parens are data.
#     Quoting also works ("%var%") because cmd's block parser respects quotes - so
#     only UNQUOTED expansions are flagged here.
#
#     The static analyzer cannot catch this: the ")" arrives through a variable, so
#     there is nothing in the source text to see. Hence a test.
# ===============================================================================
Invoke-Test 'User input is never percent-expanded unquoted inside a block' {
    $cmd = Read-Lines $CmdPath

    # every variable that receives user input
    $userVars = @{}
    foreach ($ln in $cmd) {
        if ($ln -match '(?i)set\s+/p\s+"?(\w+)\s*=') { $userVars[$Matches[1].ToLower()] = $true }
    }
    Assert-True ($userVars.Count -ge 3) 'Found almost no set /p variables - this test would pass vacuously.'

    # walk multi-line blocks: a line ending in a bare "(" opens one
    $bad = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($cmd[$i] -notmatch '(?<![\^"])\(\s*$') { continue }
        if ($cmd[$i].Trim() -match '^(?i)(rem|::)') { continue }
        for ($j = $i + 1; $j -lt $cmd.Count -and $j -lt $i + 60; $j++) {
            if ($cmd[$j] -match '^\s*\)(\s|$)') { break }
            $ln = $cmd[$j]
            if ($ln.Trim() -match '^(?i)(rem|::)') { continue }
            # mark which positions are outside double quotes (a quote just toggles)
            $inq = $false; $free = @{}
            for ($k = 0; $k -lt $ln.Length; $k++) {
                if ($ln[$k] -eq '"') { $inq = -not $inq; continue }
                if (-not $inq) { $free[$k] = $true }
            }
            foreach ($m in [regex]::Matches($ln, '%(\w+)%')) {
                if ($userVars.ContainsKey($m.Groups[1].Value.ToLower()) -and $free.ContainsKey($m.Index)) {
                    $bad += "L$($j+1): $($ln.Trim())"
                }
            }
        }
    }
    Assert-True ($bad.Count -eq 0) ("User input percent-expanded UNQUOTED inside a ( ) block - a ')' in the value (e.g. a path under 'Program Files (x86)') ends the block early and aborts the script. Use !var! or quote it:`n  " + ($bad -join "`n  "))
}

# ===============================================================================
# 56. Win32PrioritySeparation values must match their labels. The value is a
#     bitfield; bits 3-2 are the quantum TYPE (1=variable, 2=fixed). Per Microsoft,
#     variable = the client default where the FOREGROUND app gets a longer quantum;
#     fixed = the Windows Server default, all apps equal. So a value sold as
#     "foreground" MUST have a variable quantum (bits 3-2 == 1), and Windows'
#     "Programs" radio writes exactly 38 (0x26). This test exists because 42 (0x2A)
#     was shipped labelled "strong foreground boost" while carrying a FIXED quantum
#     - so the Processor Scheduling dialog honestly showed "background services",
#     the opposite of the label. A number cannot lie about its own bits; the label
#     can, so pin the bits.
# ===============================================================================
Invoke-Test 'Win32PrioritySeparation foreground value has a variable quantum' {
    $cmd = Read-Lines $CmdPath

    function QuantumType([int]$v) { return ($v -shr 2) -band 3 }   # 1=variable, 2=fixed

    # :DoWin32_38 is the named "foreground/Programs" mode - it MUST write a variable
    # quantum, or it is mislabelled the way 42 was.
    $do38raw = Get-RoutineBody -Lines $cmd -Label 'DoWin32_38'
    $do38 = @($do38raw | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($do38.Length -gt 0) ':DoWin32_38 is missing - the honest foreground value (38/0x26) is gone.'
    Assert-True ($do38 -match 'REG_DWORD 38\b') ':DoWin32_38 no longer writes 38 - the "Programs"/foreground value.'
    Assert-True ((QuantumType 38) -eq 1) 'Sanity: 38 (0x26) must decode to a variable quantum.'

    # 38 is what the Windows "Programs" radio writes - hard-pin it so a future edit
    # cannot quietly swap in a fixed-quantum value under the foreground label.
    Assert-True ($do38 -notmatch 'REG_DWORD (?:24|26|42) ') ':DoWin32_38 writes a value other than 38 as its REG_DWORD operand - if it is the foreground mode it must stay 38 (0x26), a variable quantum.'

    # And the menu option that presents the foreground choice must write 38, not a
    # fixed-quantum value dressed up as foreground.
    $perfraw = Get-RoutineBody -Lines $cmd -Label 'Performance'
    $perf = @($perfraw | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($perf -match '(?i)Win32PrioritySeparation" REG_DWORD 38') ':Performance no longer offers the honest foreground value 38 (0x26, variable quantum).'

    # 42 remains valid and is allowed to be the default - but it is a FIXED quantum,
    # so it must NOT be the one carrying a "foreground"-only promise in its writer tag.
    Assert-True ((QuantumType 42) -eq 2) 'Sanity: 42 (0x2A) is a fixed quantum - it is the throughput value, not the foreground one.'
}

# ===============================================================================
# 57. CPU-mitigation values must set the right BITS and cover them with the mask.
#     FeatureSettingsOverride is a bitfield: bits 0-1 gate Spectre/Meltdown/MDS,
#     bit 25 (0x2000000) gates Downfall/GDS (Microsoft KB5029778). Windows only
#     honours override bits that are ALSO set in FeatureSettingsOverrideMask - so
#     an override that sets a bit the mask does not cover is written and then
#     ignored. That was the original bug: Override=3, Mask=3 left Downfall (bit 25)
#     untouched, so a second tool correctly reported it still mitigated. This test
#     decodes the actual numbers and checks the bit math, in both directions.
# ===============================================================================
Invoke-Test 'CPU-mitigation disable covers the Downfall bit and the mask agrees' {
    $cmd = Read-Lines $CmdPath
    $GDS = 0x2000000   # bit 25 - Downfall/GDS
    $SM  = 0x3         # bits 0-1 - Spectre/Meltdown/MDS/SSBD/L1TF

    function DwordFor([string[]]$body, [string]$valueName) {
        # find the SafeRegAdd line for this value name and pull its REG_DWORD operand
        foreach ($ln in $body) {
            if ($ln -match ('(?i)"' + [regex]::Escape($valueName) + '"\s+REG_DWORD\s+(\d+)')) {
                return [int64]$Matches[1]
            }
        }
        return -1
    }

    $disRaw = Get-RoutineBody -Lines $cmd -Label 'DisableMitigations'
    $dis = @($disRaw)
    $ovr = DwordFor $dis 'FeatureSettingsOverride'
    $msk = DwordFor $dis 'FeatureSettingsOverrideMask'
    Assert-True ($ovr -ge 0) ':DisableMitigations has no FeatureSettingsOverride write.'
    Assert-True ($msk -ge 0) ':DisableMitigations has no FeatureSettingsOverrideMask write.'

    # the override must actually set the Downfall bit AND the Spectre/Meltdown bits
    Assert-True (($ovr -band $GDS) -eq $GDS) ":DisableMitigations Override ($ovr) does not set the Downfall/GDS bit 0x2000000 - Downfall stays mitigated (the original bug)."
    Assert-True (($ovr -band $SM) -eq $SM)   ":DisableMitigations Override ($ovr) no longer sets the Spectre/Meltdown bits 0x3."

    # every bit the override sets MUST be covered by the mask, or Windows ignores it
    Assert-True (($ovr -band $msk) -eq $ovr) ":DisableMitigations mask ($msk) does not cover every override bit ($ovr) - the uncovered bits are written but ignored (this is exactly how Downfall was missed)."
    Assert-True (($msk -band $GDS) -eq $GDS) ":DisableMitigations mask ($msk) does not cover the Downfall bit 0x2000000."

    # re-enable: override back to 0 (all mitigations on), mask still covers the Downfall bit
    $enRaw = Get-RoutineBody -Lines $cmd -Label 'EnableMitigations'
    $en = @($enRaw)
    $eovr = DwordFor $en 'FeatureSettingsOverride'
    $emsk = DwordFor $en 'FeatureSettingsOverrideMask'
    Assert-True ($eovr -eq 0) ":EnableMitigations Override should be 0 to restore every mitigation, found $eovr."
    Assert-True (($emsk -band $GDS) -eq $GDS) ":EnableMitigations mask ($emsk) does not cover the Downfall bit - a machine set by the old disable path could keep a stale Downfall state."
}

# ===============================================================================
# 58. :Summary must never expand %~1 inside a parenthesised ( ) block. cmd parses
#     a block whole at parse time, so the FIRST unescaped ")" inside the argument
#     closes the block early and crashes the script ("was unexpected at this
#     time"). Callers legitimately pass "(incl. Downfall/GDS)", "()", etc. This is
#     the same class as test 55 (set /p value in a block) but through a ROUTINE
#     ARGUMENT, which 55 does not see. The routine is written with goto branching
#     for exactly this reason; this test fails if someone "tidies" it back into an
#     if(...)else(...) block, and separately proves a paren-laden arg is safe.
# ===============================================================================
Invoke-Test ':Summary echoes its argument outside any ( ) block' {
    $cmd = Read-Lines $CmdPath
    $bodyRaw = Get-RoutineBody -Lines $cmd -Label 'Summary'
    $body = @($bodyRaw)
    Assert-True ($body.Count -gt 0) ':Summary not found.'

    # Walk real block depth (ignore rem lines and ^-escaped / quoted parens). Assert every
    # line that echoes %~1 sits at depth 0.
    $depth = 0
    $echoDepths = @()
    foreach ($ln in $body) {
        $s = $ln.Trim()
        if ($s -match '^(?i)rem\b') { 
            if ($ln -match '%~1') { }   # rem mentioning %~1 is fine, skip depth work
            continue 
        }
        # does this line echo the argument (unquoted, so a ) in it would matter)?
        if ($ln -match '(?i)^\s*echo\b.*(%~1|!_sumtext!)') { $echoDepths += $depth }
        # update depth: a line ending in a bare ( opens; a lone ) closes
        $stripped = $s
        if ($stripped -match '\($' -and $stripped -notmatch '\^\($') { $depth++ }
        if ($stripped -eq ')' -or $stripped -match '^\)\s') { $depth-- }
    }
    Assert-True ($echoDepths.Count -ge 1) ':Summary no longer echoes the caller''s phrase at all - unexpected.'

    # The phrase must be echoed LATE (!_sumtext!), never as a bare %~1. "echo [OK] %~1"
    # re-parses the text after substitution, so an "&" in it split the line and RAN the
    # remainder - and :ProcPriority passes an executable name, where "&" is legal.
    $sumCode = @($body | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($sumCode -match 'set "_sumtext=%~1"') ':Summary no longer captures its argument before echoing it (regression).'
    $rawEcho = @($body | Where-Object { $_ -match '(?i)^\s*echo\b.*%~1' })
    Assert-True ($rawEcho.Count -eq 0) ':Summary echoes %~1 directly again - an "&" in the caller''s text splits the line and runs the remainder (regression).'
    $bad = @($echoDepths | Where-Object { $_ -ne 0 })
    Assert-True ($bad.Count -eq 0) ":Summary echoes the caller's phrase inside a ( ) block (depth $($bad -join ',')). Keep :Summary block-free (goto branching), do not use if(...)else(...) - a ')' in text like '(incl. Downfall/GDS)' closed the block early back when the phrase was substituted at parse time."

    # Positive: at least one real caller passes parens, proving the safe path is exercised.
    $parenCaller = @($cmd | Where-Object { $_ -match '(?i)call :Summary "[^"]*\([^"]*\)[^"]*"' })
    Assert-True ($parenCaller.Count -ge 1) 'No caller passes parenthesised Summary text - the regression that motivated this test is not represented; add/keep one (e.g. the mitigations "(incl. Downfall/GDS)" line).'
}

# 59. The doc-verified additions must stay present and correct. Each was checked
#     against Microsoft's documentation (NewsAndInterests / CloudContent / verbose
#     status policies), is reversible via the per-value backup, and rides the same
#     :SafeRegAdd path as every other tweak. This test fails if any is dropped or its
#     value drifts, and it pins the honesty helper for verbosestatus (which warns when
#     DisableStatusMessages=1 would override it) so the additions can't lose their
#     truthful reporting.
# ===============================================================================
Invoke-Test 'Documented additions present, correct, and honestly reported' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    # 1. Widgets off - HKLM Dsh AllowNewsAndInterests = 0
    Assert-True ($all -match '(?i)SafeRegAdd\s+"HKLM\\SOFTWARE\\Policies\\Microsoft\\Dsh"\s+"AllowNewsAndInterests"\s+REG_DWORD\s+0\b') 'Widgets (AllowNewsAndInterests=0) missing or wrong value.'

    # 2. Spotlight on lock screen off - HKCU CloudContent DisableWindowsSpotlightOnLockScreen = 1
    Assert-True ($all -match '(?i)SafeRegAdd\s+"HKCU\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent"\s+"DisableWindowsSpotlightOnLockScreen"\s+REG_DWORD\s+1\b') 'Spotlight lock-screen (DisableWindowsSpotlightOnLockScreen=1) missing or wrong value.'

    # 3. VerboseStatus - HKLM Policies\System verbosestatus = 1 (a diagnostic, opt-in)
    Assert-True ($all -match '(?i)SafeRegAdd\s+"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System"\s+"verbosestatus"\s+REG_DWORD\s+1\b') 'VerboseStatus (verbosestatus=1) missing or wrong value.'

    # 4. The honesty helper exists and checks the overriding key by name.
    $noteRaw = Get-RoutineBody -Lines $cmd -Label 'VerboseStatusNote'
    $note = @($noteRaw)
    Assert-True ($note.Count -gt 0) ':VerboseStatusNote helper missing - verbosestatus would lose its honest override warning.'
    $noteJoined = $note -join "`n"
    Assert-True ($noteJoined -match '(?i)DisableStatusMessages') ':VerboseStatusNote no longer checks DisableStatusMessages - the override caveat is gone.'
}

# ===============================================================================
# 60. Idempotent :SafeRegAdd (DWORD + REG_SZ): if the value already equals the
#     target, skip the backup + write. A redundant re-apply would otherwise
#     snapshot the already-tweaked value as its "prior" state and bury the
#     true-original undo. DWORD-only skip left MenuShowDelay / WaitToKill* /
#     Games REG_SZ unprotected on every re-run.
# ===============================================================================
Invoke-Test ':SafeRegAdd skips DWORD and REG_SZ writes already at the target' {
    $bodyRaw = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'SafeRegAdd'
    $body = @($bodyRaw)
    Assert-True ($body.Count -gt 0) ':SafeRegAdd body empty - cannot verify idempotent skip.'
    $joined = $body -join "`n"
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code.Length -gt 0) ':SafeRegAdd has no executable lines after stripping echo/rem.'

    # DWORD path
    Assert-True ($code -match '(?i)!_type!"=="REG_DWORD"') ':SafeRegAdd lost its REG_DWORD idempotence gate (regression).'
    Assert-True ($code -match '(?i)set\s+/a\s+_curdec=') ':SafeRegAdd no longer parses the current DWORD (_curdec) (regression).'
    Assert-True ($code -match '(?i)set\s+/a\s+_tgtdec=') ':SafeRegAdd no longer parses the target DWORD (_tgtdec) (regression).'
    Assert-True ($code -match '(?i)!_curdec!"=="!_tgtdec!"') ':SafeRegAdd no longer compares _curdec to _tgtdec (regression).'

    # REG_SZ path (must be a real branch, not just a comment naming REG_SZ)
    Assert-True ($code -match '(?i)!_type!"=="REG_SZ"') ':SafeRegAdd lost its REG_SZ idempotence gate - re-applying MenuShowDelay etc. would bury the true-original undo (regression).'
    Assert-True ($code -match '(?i)!_rd!"=="!_data!"') ':SafeRegAdd REG_SZ path no longer compares current (_rd) to target (_data) (regression).'

    Assert-True ($joined -match '(?im)^\s*echo\s+.*\[SKIP\].*already set') ':SafeRegAdd no longer prints [SKIP] ... already set (regression).'
    Assert-True ($code -match '(?i)endlocal\s*&\s*goto\s+:eof') ':SafeRegAdd idempotent path no longer endlocal & goto :eof (regression).'

    $skipAt = $joined.IndexOf('[SKIP]')
    $writeAt = $joined.IndexOf(':_sraDoWrite')
    if ($writeAt -lt 0) { $writeAt = $joined.IndexOf('_sraDoWrite') }
    Assert-True ($skipAt -ge 0) ':SafeRegAdd [SKIP] marker missing from body.'
    Assert-True ($writeAt -gt $skipAt) ':SafeRegAdd [SKIP] path is not before the write/backup entry (regression).'
}

# ===============================================================================
# 61. No backup, no registry write (mirrors PATH/hosts): :SafeRegAdd /
#     :SafeRegDelete must refuse the live write when the per-value .reg did not
#     land, and must refuse when the preset JSON temp is missing.
# ===============================================================================
Invoke-Test ':SafeRegAdd / :SafeRegDelete abort when the per-value backup did not land' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'SafeRegAdd','SafeRegDelete') {
        $body = Get-RoutineBody -Lines $cmd -Label $r
        $body = @($body)
        Assert-True ($body.Count -gt 0) ":$r body empty."
        $joined = $body -join "`n"
        $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($joined -match 'if not exist "!_bkp!"') ":$r no longer checks that the .reg backup landed before writing - CFA/disk-full would leave no undo (regression)."
        Assert-True ($joined -match 'FAIL backup') ":$r lost its abort/log path when the .reg backup is missing (regression)."
        Assert-True ($joined -match 'if not exist "!PRESET_JSON_TMP!"') ":$r no longer checks the preset JSON temp before writing in PRESET_MODE (regression)."
        # Order is measured on the rem-stripped view. These routines are heavily commented and
        # a comment mentioning "reg add" (there is one, explaining why large DWORDs are written
        # as hex) would otherwise be found first and read as the write happening before the gate.
        $gateAt = $code.IndexOf('if not exist "!_bkp!"')
        $writeAt = if ($r -eq 'SafeRegAdd') { $code.IndexOf('reg add') } else { $code.IndexOf('reg delete') }
        Assert-True ($gateAt -ge 0 -and $writeAt -gt $gateAt) ":$r backup-existence gate is not before the live registry write (regression)."
        Assert-True ($code.Length -gt 0) ":$r code view empty after stripping echo/rem."
    }
}

# ===============================================================================
# 62. :ResetHostsDefault must require a landed hosts.bak before overwriting
#     (same bargain as :ApplyHosts / test 18).
# ===============================================================================
Invoke-Test ':ResetHostsDefault aborts when hosts.bak could not be written' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ResetHostsDefault'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':ResetHostsDefault body empty.'
    $joined = $body -join "`n"
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match 'set "_hbak=1"') ':ResetHostsDefault no longer sets _hbak=1 on a successful copy (regression).'
    Assert-True ($code -match '&&') ':ResetHostsDefault no longer gates _hbak on the copy exit code via && (regression).'
    Assert-True ($code -match '!\s*_hbak!"=="0"|!_hbak!"=="0"') ':ResetHostsDefault no longer aborts when _hbak is 0 (regression).'
    Assert-True ($joined -match 'ABORT: hosts reset') ':ResetHostsDefault lost its abort log when backup fails (regression).'
    Assert-True ($code -match 'goto RestoreHosts') ':ResetHostsDefault does not bail to RestoreHosts when backup fails - it would still overwrite (regression).'
}

# ===============================================================================
# 63. :PresetBegin must verify the JSON temp landed before PRESET_MODE=1, and
#     every built-in/custom preset caller must honour a failed begin.
# ===============================================================================
Invoke-Test ':PresetBegin refuses to run when the JSON temp is unwritable' {
    $cmd = Read-Lines $CmdPath
    $pb = Get-RoutineBody -Lines $cmd -Label 'PresetBegin'
    $pb = @($pb)
    Assert-True ($pb.Count -gt 0) ':PresetBegin body empty.'
    $joined = $pb -join "`n"
    $code = @($pb | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($joined -match 'if not exist "!PRESET_JSON_TMP!"') ':PresetBegin no longer verifies the JSON temp file landed (regression).'
    Assert-True ($code -match 'exit /b 1') ':PresetBegin no longer exits nonzero when the JSON temp is missing (regression).'
    Assert-True ($code -match 'PRESET_MODE=1') ':PresetBegin no longer sets PRESET_MODE=1 on the success path.'
    $gateAt = $joined.IndexOf('if not exist "!PRESET_JSON_TMP!"')
    $modeAt = $joined.IndexOf('set "PRESET_MODE=1"')
    Assert-True ($gateAt -ge 0 -and $modeAt -gt $gateAt) ':PresetBegin sets PRESET_MODE before verifying the JSON temp (regression).'

    foreach ($r in 'PresetLight','PresetModerate','PresetHeavy') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)call :PresetBegin') ":$r no longer calls :PresetBegin."
        Assert-True ($t -match '(?i)if errorlevel 1 goto MenuPresets') ":$r does not abort when :PresetBegin fails - it would apply with no JSON undo (regression)."
    }
    $all = $cmd -join "`n"
    Assert-True ($all -match '(?i)call :PresetBegin "custom_!_pbase!"[\s\S]{0,160}if errorlevel 1 goto MenuPresets') 'Custom preset apply does not abort when :PresetBegin fails (regression).'
}

# ===============================================================================
# 64. :RestoreHostsBak must fall back to Documents hosts_*.bak when the local
#     hosts.bak is missing (ApplyHosts can succeed with doc-only undo).
# ===============================================================================
Invoke-Test ':RestoreHostsBak falls back to Documents hosts_*.bak' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'RestoreHostsBak'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':RestoreHostsBak body empty.'
    $joined = $body -join "`n"
    Assert-True ($joined -match 'hosts_\*\.bak') ':RestoreHostsBak no longer looks for Documents hosts_*.bak (regression).'
    Assert-True ($joined -match 'dir /b /od\b')   ':RestoreHostsBak no longer picks the OLDEST Documents hosts backup - newest-first restores the blocklist this script applied, not the user original (regression of F2).'
    Assert-True ($joined -notmatch 'dir /b /o-d') ':RestoreHostsBak reverted to newest-first (/o-d) - that is the poisoned copy (regression of F2).'
    Assert-True ($joined -match 'copy /y "!_hsrc!"') ':RestoreHostsBak no longer restores from the resolved _hsrc path (regression).'
}

# ===============================================================================
# 65. :TimerResApply and :TimerResRemove must route GlobalTimerResolutionRequests
#     through _FAILS + :Summary (no unconditional [OK] after :SafeRegAdd).
#     Apply was fixed first; Remove had the same honesty gap on the optional revert.
# ===============================================================================
Invoke-Test ':TimerResApply / :TimerResRemove report registry via :Summary (gated on _FAILS)' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'TimerResApply','TimerResRemove') {
        $body = Get-RoutineBody -Lines $cmd -Label $r
        $body = @($body)
        Assert-True ($body.Count -gt 0) ":$r body empty."
        $joined = $body -join "`n"
        $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($joined -match 'set "_FAILS=0"') ":$r does not reset _FAILS before SafeRegAdd (regression)."
        Assert-True ($joined -match 'call :SafeRegAdd') ":$r no longer writes GlobalTimerResolutionRequests via :SafeRegAdd."
        Assert-True ($joined -match 'call :Summary') ":$r prints an unconditional status instead of :Summary after the registry write (regression)."
        Assert-True ($code -notmatch '(?im)^\s*echo\s+\[OK\]\s+Reverted') ":$r still echoes unconditional [OK] Reverted after SafeRegAdd (regression)."
        Assert-True ($code -notmatch '(?im)^\s*echo\s+\[OK\]\s+Timer-resolution') ":$r still echoes an unconditional [OK] for the install line (regression)."
    }
}

# ===============================================================================
# 66. SteamLight must verify the Desktop .lnk landed before claiming it in [OK].
#     The launcher .bat is already gated; COM / Desktop-redirect failures must not
#     still print "shortcut was placed on your Desktop".
# ===============================================================================
Invoke-Test 'SteamLight verifies the Desktop shortcut before claiming it' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'SteamLight'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':SteamLight body empty.'
    $joined = $body -join "`n"
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($joined -match 'SteamLight\.lnk') ':SteamLight no longer targets SteamLight.lnk (regression).'
    Assert-True ($joined -match 'Test-Path -LiteralPath \$lnk') ':SteamLight no longer verifies the .lnk landed after Save() (regression).'
    Assert-True ($code -match 'set "_slrc=%errorlevel%"') ':SteamLight no longer captures the shortcut PS exit code (regression).'
    Assert-True ($code -match 'if not "%_slrc%"=="0"') ':SteamLight no longer branches on the captured shortcut exit code (regression).'
    # The capture has to come BEFORE the `set "PT_SLDIR="` cleanup. This is a .cmd file, and
    # there `set` resets errorlevel to 0 on success (a .bat leaves it alone), so reading it
    # after that line made the failure branch unreachable: a missing shortcut reported success.
    $iCap = ($body | Select-String -SimpleMatch 'set "_slrc=%errorlevel%"' | Select-Object -First 1)
    $iClr = ($body | Select-String -SimpleMatch 'set "PT_SLDIR="' | Select-Object -First 1)
    Assert-True ($null -ne $iCap -and $null -ne $iClr -and $iCap.LineNumber -lt $iClr.LineNumber) ':SteamLight reads the shortcut exit code after the PT_SLDIR cleanup set, which clears it in a .cmd file (regression).'
    Assert-True ($joined -match '\[WARN\].*shortcut') ':SteamLight lost its [WARN] when the Desktop shortcut fails (regression).'
    # Desktop claim must share the success branch with the errorlevel gate, not stand alone.
    Assert-True ($joined -match 'if not "%_slrc%"=="0"[\s\S]{0,400}shortcut was placed on your Desktop') ':SteamLight Desktop-shortcut [OK] is no longer gated on the shortcut PS exit code (regression).'
}

# ===============================================================================
# 67. Memory-compression disable must not swallow failures, and the preset path
#     must bump _FAILS so :Summary stays honest. Each switch has its own try and
#     the exit code says which failed (1 = compression, 2 = page combining): with
#     one shared try, a failure in the second call reported that neither change
#     was made, although memory compression was already off.
# ===============================================================================
Invoke-Test 'Memory compression disable reports real outcome (not SilentlyContinue)' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'MemCompress','DoMemCompressOff') {
        $body = Get-RoutineBody -Lines $cmd -Label $r
        $body = @($body)
        Assert-True ($body.Count -gt 0) ":$r body empty."
        $joined = $body -join "`n"
        $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($joined -match "ErrorActionPreference='Stop'") ":$r still uses SilentlyContinue - Disable-MMAgent failures would be invisible (regression)."
        Assert-True ($code -match 'set "_mmrc=%errorlevel%"') ":$r no longer captures the PS exit code (regression)."
        Assert-True ($code -match '"%_mmrc%"=="1"' -and $code -match '"%_mmrc%"=="2"') ":$r no longer says which switch failed - a partial success would read as a total failure (regression)."
        Assert-True ($joined -match 'try\{ Disable-MMAgent -MemoryCompression \}catch\{ \$e\+=1 \}' -and $joined -match 'try\{ Disable-MMAgent -PageCombining \}catch\{ \$e\+=2 \}') ":$r shares one try between the two switches again (regression)."
        Assert-True ($code -notmatch 'SilentlyContinue') ":$r still invokes Disable-MMAgent with SilentlyContinue (regression)."
    }
    $dmcBody = Get-RoutineBody -Lines $cmd -Label 'DoMemCompressOff'
    $dmc = (@($dmcBody) -join "`n")
    Assert-True ($dmc -match 'set /a _FAILS\+=1') ':DoMemCompressOff no longer bumps _FAILS on failure - preset :Summary would stay green (regression).'
}

# ===============================================================================
# 68. NVIDIA telemetry tasks are disabled by name prefix (like privacy extras),
#     never via hardcoded schtasks /TN GUID paths - and NvDriverUpdateCheckDaily_
#     is not one of them: it is NVIDIA's driver-update check, not telemetry, and it
#     was being turned off unannounced. An undo file is written before anything is
#     disabled (test 126 runs its generator).
# ===============================================================================
Invoke-Test 'NVIDIA telemetry tasks disabled by name, not hardcoded TN paths' {
    $cmd = Read-Lines $CmdPath
    $b = Get-RoutineBody -Lines $cmd -Label 'DisableNvidiaTelemetryTasks'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':DisableNvidiaTelemetryTasks helper missing.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match 'Get-ScheduledTask') ':DisableNvidiaTelemetryTasks no longer looks tasks up by name.'
    Assert-True ($code -match 'Disable-ScheduledTask') ':DisableNvidiaTelemetryTasks no longer disables anything.'
    Assert-True ($code -match 'NvTmRep_') ':DisableNvidiaTelemetryTasks lost the NvTmRep_ name prefix.'
    Assert-True ($code -match 'NvTmMon_') ':DisableNvidiaTelemetryTasks lost the NvTmMon_ name prefix.'
    Assert-True ($code -notmatch 'NvDriverUpdateCheckDaily_') ':DisableNvidiaTelemetryTasks disables NVIDIA''s driver-update check again - it is not telemetry (regression).'
    # schtasks appears in the generated undo file's TEXT (call :pt_do schtasks ... /Enable); the
    # routine itself must never run it.
    Assert-True ($code -notmatch '(?im)^\s*schtasks\b|call :Run "schtasks') ':DisableNvidiaTelemetryTasks INVOKES schtasks - use name lookup like :DisableTelemetryTasks.'
    Assert-True ($code -match 'PT_NV_UNDO' -and $code -match '(?i)Telemetry_nvidia_') ':DisableNvidiaTelemetryTasks no longer writes its undo file (regression).'
    $iUndo = $code.IndexOf('Set-Content -LiteralPath $env:PT_NV_UNDO')
    $iOff = $code.IndexOf('Disable-ScheduledTask -InputObject')
    Assert-True ($iUndo -ge 0 -and $iOff -gt $iUndo) ':DisableNvidiaTelemetryTasks disables the tasks BEFORE writing the undo file - it would record them as already disabled (regression).'
    # echo lines only: the PowerShell payload writes "[OK]" / "[FAIL]" into the undo file as
    # data, and that line comes first - it is not the routine reporting anything.
    $si = -1; $fi = -1; $oi = -1
    for ($i = 0; $i -lt $b.Count; $i++) {
        if ($b[$i] -notmatch '(?i)^\s*echo\b') { continue }
        if ($si -lt 0 -and $b[$i] -match '\[SKIP\]') { $si = $i }
        if ($fi -lt 0 -and $b[$i] -match '\[FAIL\]') { $fi = $i }
        if ($oi -lt 0 -and $b[$i] -match '\[OK\]')   { $oi = $i }
    }
    Assert-True ($si -ge 0 -and $fi -ge 0 -and $oi -ge 0) ':DisableNvidiaTelemetryTasks lost [SKIP]/[FAIL]/[OK] reporting.'
    Assert-True ($si -lt $oi -and $fi -lt $oi) ':DisableNvidiaTelemetryTasks prints [OK] before its guard branches.'

    foreach ($r in 'GpuNvidia','DoGpuTelemetryOff') {
        $tbody = Get-RoutineBody -Lines $cmd -Label $r
        $tbody = @($tbody)
        $t = $tbody -join "`n"
        Assert-True ($t -match 'call :DisableNvidiaTelemetryTasks') ":$r no longer calls :DisableNvidiaTelemetryTasks (regression)."
        $tcode = @($tbody | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($tcode -notmatch 'B2FE1952') ":$r still hardcodes the old NVIDIA task GUID path (regression)."
    }
}

# ===============================================================================
# 69. Win11 quiet surface in :DoPrivacyCore - extra ContentDeliveryManager /
#     Search box suggestions / TailoredExperiences keys (beyond the thin CDM
#     slice already guarded by widgets/spotlight tests).
# ===============================================================================
Invoke-Test ':DoPrivacyCore quiet surface (CDM / Search suggestions / TailoredExperiences)' {
    $pc = (Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'DoPrivacyCore') -join "`n"
    Assert-True ($pc -match '(?i)SubscribedContent-338387Enabled"\s+REG_DWORD\s+0') 'CDM SubscribedContent-338387Enabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)SubscribedContent-338393Enabled"\s+REG_DWORD\s+0') 'CDM SubscribedContent-338393Enabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)SubscribedContent-353694Enabled"\s+REG_DWORD\s+0') 'CDM SubscribedContent-353694Enabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)SubscribedContent-353696Enabled"\s+REG_DWORD\s+0') 'CDM SubscribedContent-353696Enabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"SoftLandingEnabled"\s+REG_DWORD\s+0') 'SoftLandingEnabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"PreInstalledAppsEnabled"\s+REG_DWORD\s+0') 'PreInstalledAppsEnabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"OemPreInstalledAppsEnabled"\s+REG_DWORD\s+0') 'OemPreInstalledAppsEnabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"RotatingLockScreenEnabled"\s+REG_DWORD\s+0') 'RotatingLockScreenEnabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"RotatingLockScreenOverlayEnabled"\s+REG_DWORD\s+0') 'RotatingLockScreenOverlayEnabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"DisableSearchBoxSuggestions"\s+REG_DWORD\s+1') 'DisableSearchBoxSuggestions=1 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"TailoredExperiencesWithDiagnosticDataEnabled"\s+REG_DWORD\s+0') 'TailoredExperiencesWithDiagnosticDataEnabled=0 missing from :DoPrivacyCore.'
    Assert-True ($pc -match '(?i)"DisableTailoredExperiencesWithDiagnosticData"\s+REG_DWORD\s+1') 'DisableTailoredExperiencesWithDiagnosticData=1 missing from :DoPrivacyCore.'
}

# ===============================================================================
# 70. Game Bar residual is opt-in (Performance prompt / :DoGameBarOff), never
#     folded into :DoPerformanceCore (recording is already off there).
# ===============================================================================
Invoke-Test 'Game Bar residual is prompt-gated via :DoGameBarOff (not in :DoPerformanceCore)' {
    $cmd = Read-Lines $CmdPath
    $core = (Get-RoutineBody -Lines $cmd -Label 'DoPerformanceCore') -join "`n"
    Assert-True ($core -notmatch '(?i)AppCaptureEnabled') ':DoPerformanceCore must not write AppCaptureEnabled - Game Bar residual is opt-in.'
    Assert-True ($core -notmatch '(?i)UseNexusForGameBarEnabled') ':DoPerformanceCore must not write UseNexusForGameBarEnabled - Game Bar residual is opt-in.'
    Assert-True ($core -notmatch '(?i)call :DoGameBarOff') ':DoPerformanceCore must not call :DoGameBarOff.'

    $perf = (Get-RoutineBody -Lines $cmd -Label 'Performance') -join "`n"
    Assert-True ($perf -match '(?i)call :DoGameBarOff') ':Performance no longer offers :DoGameBarOff (regression).'
    Assert-True ($perf -match '(?i)[%!]_q12[%!]') ':Performance Game Bar residual is not gated on _q12 (regression).'

    $gb = (Get-RoutineBody -Lines $cmd -Label 'DoGameBarOff') -join "`n"
    Assert-True ($gb.Length -gt 0) ':DoGameBarOff helper missing.'
    Assert-True ($gb -match '(?i)"AppCaptureEnabled"\s+REG_DWORD\s+0') ':DoGameBarOff missing AppCaptureEnabled=0.'
    Assert-True ($gb -match '(?i)"UseNexusForGameBarEnabled"\s+REG_DWORD\s+0') ':DoGameBarOff missing UseNexusForGameBarEnabled=0.'
    Assert-True ($gb -match '(?i)"ShowStartupPanel"\s+REG_DWORD\s+0') ':DoGameBarOff missing ShowStartupPanel=0.'

    $check = (Get-RoutineBody -Lines $cmd -Label 'PresetCheckLine') -join "`n"
    Assert-True ($check -match '(?i)"[%!]_k[%!]"=="gamebar_off"') 'Preset validator lost gamebar_off.'
}

# ===============================================================================
# 71. Edge nudges are opt-in (:DoEdgeNudgesOff + Privacy prompt + preset key);
#     documented Edge ADMX policy values only.
# ===============================================================================
Invoke-Test 'Edge nudges are opt-in via :DoEdgeNudgesOff (Privacy prompt + edge_nudges_off)' {
    $cmd = Read-Lines $CmdPath
    $core = (Get-RoutineBody -Lines $cmd -Label 'DoPrivacyCore') -join "`n"
    Assert-True ($core -notmatch '(?i)HubsSidebarEnabled') ':DoPrivacyCore must not force Edge HubsSidebarEnabled - Edge nudges are opt-in.'
    Assert-True ($core -notmatch '(?i)call :DoEdgeNudgesOff') ':DoPrivacyCore must not call :DoEdgeNudgesOff.'

    $priv = (Get-RoutineBody -Lines $cmd -Label 'Privacy') -join "`n"
    Assert-True ($priv -match '(?i)call :DoEdgeNudgesOff') ':Privacy no longer offers :DoEdgeNudgesOff (regression).'

    $edge = (Get-RoutineBody -Lines $cmd -Label 'DoEdgeNudgesOff') -join "`n"
    Assert-True ($edge.Length -gt 0) ':DoEdgeNudgesOff helper missing.'
    Assert-True ($edge -match '(?i)"HubsSidebarEnabled"\s+REG_DWORD\s+0') ':DoEdgeNudgesOff missing HubsSidebarEnabled=0.'
    Assert-True ($edge -match '(?i)"EdgeShoppingAssistantEnabled"\s+REG_DWORD\s+0') ':DoEdgeNudgesOff missing EdgeShoppingAssistantEnabled=0.'
    Assert-True ($edge -match '(?i)"HideFirstRunExperience"\s+REG_DWORD\s+1') ':DoEdgeNudgesOff missing HideFirstRunExperience=1.'
    Assert-True ($edge -match '(?i)SOFTWARE\\Policies\\Microsoft\\Edge') ':DoEdgeNudgesOff not writing under Policies\\Microsoft\\Edge.'

    $check = (Get-RoutineBody -Lines $cmd -Label 'PresetCheckLine') -join "`n"
    Assert-True ($check -match '(?i)"[%!]_k[%!]"=="edge_nudges_off"') 'Preset validator lost edge_nudges_off.'
}

# ===============================================================================
# 72. Cleanup core gained crash dumps / minidumps / DO cache; Prefetch still out;
#     free-space snap+report for non-outer (preset) callers.
# ===============================================================================
Invoke-Test ':DoCleanupCore adds safe regenerating junk; Prefetch stays excluded; free-space report' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'DoCleanupCore'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':DoCleanupCore body empty.'
    $joined = $body -join "`n"
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($joined -match '(?i)CrashDumps') ':DoCleanupCore missing CrashDumps cleanup.'
    Assert-True ($joined -match '(?i)Minidump') ':DoCleanupCore missing Minidump cleanup.'
    Assert-True ($joined -match '(?i)DeliveryOptimization\\Cache') ':DoCleanupCore missing DeliveryOptimization\Cache cleanup.'
    Assert-True ($joined -match '(?i)if defined _cleanLocalAppData if exist "!LocalAppData!\\CrashDumps') ':CrashDumps delete is not gated on _cleanLocalAppData.'
    Assert-True ($joined -match '(?i)if defined _cleanSystemRoot if exist "%SystemRoot%\\Minidump') ':Minidump delete is not gated on _cleanSystemRoot.'
    Assert-True ($joined -match '(?i)if defined _cleanSystemRoot if exist "%SystemRoot%\\SoftwareDistribution\\DeliveryOptimization\\Cache') ':DO Cache delete is not gated on _cleanSystemRoot.'
    $bad = @($body | Where-Object { $_ -match '(?i)\bdel\b' -and $_ -match '(?i)Prefetch' })
    Assert-True ($bad.Count -eq 0) 'Prefetch is being deleted in :DoCleanupCore (regression).'
    Assert-True ($joined -match 'call :FreeSpaceSnap') ':DoCleanupCore missing FreeSpaceSnap for preset path.'
    Assert-True ($joined -match 'call :FreeSpaceReport') ':DoCleanupCore missing FreeSpaceReport for preset path.'
    Assert-True ($code -notmatch '(?i)D3DSCache') ':DoCleanupCore must not clear D3DSCache - shader caches are interactive-only.'
    Assert-True ($code -notmatch '(?i)Clear-RecycleBin') ':DoCleanupCore must not empty Recycle Bin.'
    Assert-True ($code -notmatch '(?i)cleanmgr') ':DoCleanupCore must not launch cleanmgr.'
    Assert-True ($code -notmatch '(?i)storagesense') ':DoCleanupCore must not open Storage Sense.'
}

# ===============================================================================
# 73. Interactive :Cleanup optional buckets + OS tool launches; outer free-space.
# ===============================================================================
Invoke-Test ':Cleanup optional buckets and tool launches are prompt-gated; free-space bracketed' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'Cleanup'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':Cleanup body empty.'
    $joined = $body -join "`n"
    Assert-True ($joined -match 'set "_CLEAN_OUTER=1"') ':Cleanup no longer sets _CLEAN_OUTER for outer free-space bracket.'
    Assert-True ($joined -match 'call :FreeSpaceSnap') ':Cleanup missing FreeSpaceSnap.'
    Assert-True ($joined -match 'call :FreeSpaceReport') ':Cleanup missing FreeSpaceReport.'
    Assert-True ($joined -match '(?i)D3DSCache') ':Cleanup missing shader-cache optional.'
    Assert-True ($joined -match '(?i)Clear-RecycleBin') ':Cleanup missing Recycle Bin optional.'
    Assert-True ($joined -match '(?i)cleanmgr') ':Cleanup missing Disk Cleanup launch.'
    Assert-True ($joined -match '(?i)storagesense') ':Cleanup missing Storage Sense launch.'
    Assert-True ($joined -match '(?i)[%!]_sh[%!]') ':Cleanup shader bucket not gated on a prompt var.'
    Assert-True ($joined -match '(?i)[%!]_rb[%!]') ':Cleanup Recycle Bin not gated on a prompt var.'
    Assert-True ($joined -match '(?i)[%!]_cm[%!]') ':Cleanup cleanmgr not gated on a prompt var.'
    Assert-True ($joined -match '(?i)[%!]_ss[%!]') ':Cleanup Storage Sense not gated on a prompt var.'
    Assert-True ($joined -match 'call :CleanRoot ProgramData') ':Cleanup NVIDIA Downloader path missing ProgramData CleanRoot probe.'
}

# ===============================================================================
# 74. Free-space helpers exist and Status shows Disk + new tweak proxies.
# ===============================================================================
Invoke-Test ':FreeSpaceSnap / :FreeSpaceReport exist; :Status shows Disk and new proxies' {
    $cmd = Read-Lines $CmdPath
    $snap = Get-RoutineBody -Lines $cmd -Label 'FreeSpaceSnap'
    $snap = @($snap)
    Assert-True ($snap.Count -gt 0) ':FreeSpaceSnap missing.'
    $snapJ = $snap -join "`n"
    Assert-True ($snapJ -match 'Win32_LogicalDisk') ':FreeSpaceSnap has no Win32_LogicalDisk probe.'
    Assert-True ($snapJ -match '_FREE_BYTES') ':FreeSpaceSnap does not set _FREE_BYTES.'
    $rep = Get-RoutineBody -Lines $cmd -Label 'FreeSpaceReport'
    $rep = @($rep)
    Assert-True ($rep.Count -gt 0) ':FreeSpaceReport missing.'
    $repJ = $rep -join "`n"
    Assert-True ($repJ -match '_FREE_BEFORE') ':FreeSpaceReport does not consult _FREE_BEFORE.'
    Assert-True ($repJ -match '_FREE_AFTER') ':FreeSpaceReport does not consult _FREE_AFTER.'
    $st = Get-RoutineBody -Lines $cmd -Label 'Status'
    $st = @($st)
    $stJ = $st -join "`n"
    Assert-True ($stJ -match '(?i)\[Disk\]') ':Status missing [Disk] section.'
    Assert-True ($stJ -match 'call :FreeSpaceSnap') ':Status does not call FreeSpaceSnap.'
    Assert-True ($stJ -match 'AppCaptureEnabled') ':Status missing AppCaptureEnabled (Game Bar residual proxy).'
    Assert-True ($stJ -match 'DisableSearchBoxSuggestions') ':Status missing DisableSearchBoxSuggestions (quiet-surface proxy).'
}

# ===============================================================================
# 75. Cleanup deletes stay behind CleanRoot-proven flags.
# ===============================================================================
Invoke-Test 'Cleanup deletes stay behind CleanRoot-proven flags' {
    $cmd = Read-Lines $CmdPath
    $core = Get-RoutineBody -Lines $cmd -Label 'DoCleanupCore'
    $core = @($core)
    $coreJ = $core -join "`n"
    Assert-True ($coreJ -match 'call :CleanRoot TEMP') ':DoCleanupCore missing TEMP CleanRoot.'
    Assert-True ($coreJ -match 'call :CleanRoot SystemRoot') ':DoCleanupCore missing SystemRoot CleanRoot.'
    Assert-True ($coreJ -match 'call :CleanRoot LocalAppData') ':DoCleanupCore missing LocalAppData CleanRoot.'
    $coreDels = @($core | Where-Object { $_ -match '(?i)call :Run "del' -and $_ -match '%(TEMP|SystemRoot|LocalAppData)%' })
    foreach ($ln in $coreDels) {
        Assert-True ($ln -match '(?i)if defined _clean') (':DoCleanupCore has an ungated cleanup delete: ' + $ln.Trim())
    }
    $cu = Get-RoutineBody -Lines $cmd -Label 'Cleanup'
    $cu = @($cu)
    $cuJ = $cu -join "`n"
    Assert-True ($cuJ -match 'call :CleanRoot ProgramData') ':Cleanup NVIDIA path missing ProgramData CleanRoot.'
    $cuDels = @($cu | Where-Object { $_ -match '(?i)call :Run "del' -and $_ -match '%(LocalAppData|ProgramData)%' })
    foreach ($ln in $cuDels) {
        Assert-True ($ln -match '(?i)if defined _clean') (':Cleanup has an ungated cleanup delete: ' + $ln.Trim())
    }
}


# ===============================================================================
# 76. F1/F2: the beside-the-file hosts.bak is WRITE-ONCE. Re-running "apply hosts"
#     used to copy the already-applied blocklist over the pristine original, and
#     :RestoreHostsBak prefers that file - so the undo restored the blocklist onto
#     itself. Documents keeps a randomized per-run snapshot.
# ===============================================================================
Invoke-Test ':ApplyHosts keeps the pristine hosts.bak (write-once) + randomized doc snapshot' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ApplyHosts'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':ApplyHosts body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "%_HOSTS%\.bak" copy /y') ':ApplyHosts copies over hosts.bak unconditionally again - a re-run buries the true original (regression of F1).'
    Assert-True ($code -match '(?i)hosts_%RANDOM%%RANDOM%\.bak')          ':ApplyHosts doc snapshot is no longer randomized (regression of F1).'
    Assert-True ($code -match '(?i)_hbak!"=="0"')                          ':ApplyHosts lost its no-backup abort gate (regression of the data-loss guard).'
}

# ===============================================================================
# 77. F1: :ResetHostsDefault follows the same write-once rule and gained the
#     Documents snapshot it never had.
# ===============================================================================
Invoke-Test ':ResetHostsDefault is write-once and writes a Documents snapshot' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ResetHostsDefault'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':ResetHostsDefault body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "%_HOSTS%\.bak" copy /y') ':ResetHostsDefault overwrites the pristine hosts.bak again (regression of F1).'
    Assert-True ($code -match '(?i)hosts_%RANDOM%%RANDOM%\.bak')          ':ResetHostsDefault no longer writes a Documents snapshot (regression of F1).'
}

# ===============================================================================
# 78. F1/F4: :InstallAsarInto - both backups write-once (a re-run is the DOCUMENTED
#     workflow), and with an original present but no backup landed it must refuse
#     the write instead of overwriting and advising a Discord reinstall.
# ===============================================================================
Invoke-Test ':InstallAsarInto backups are write-once and gate the install' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'InstallAsarInto'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':InstallAsarInto body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "!_localbak!" copy /y') ':InstallAsarInto overwrites the local .bak again - a re-run backs up OpenAsar over the stock asar (regression of F1).'
    Assert-True ($code -match '(?i)if not exist "!_docbak!"\s+copy /y')  ':InstallAsarInto overwrites the Documents .bak again - the asar has no randomized fallback, so both copies die (regression of F1).'
    $gate = $code.IndexOf('if "!_hadorig!"=="1" if not defined _bakloc')
    # _asrc, not _src: the callers hold the same path in _SRC and cmd names are
    # case-insensitive, so the old name was literally the same variable (test 118)
    $write = $code.IndexOf('copy /y "!_asrc!"')
    Assert-True ($gate -ge 0)             ':InstallAsarInto lost the "no backup landed -> refuse" gate (regression of F4).'
    Assert-True ($write -ge 0)            ':InstallAsarInto install copy not found - routine changed shape?'
    Assert-True ($gate -lt $write)        ':InstallAsarInto gate no longer precedes the install copy - it overwrites first (regression of F4).'
}

# ===============================================================================
# 79. F1/F4: :UnityBoot - boot.config.bak write-once, aborts when no backup landed,
#     and no longer claims the .bak unconditionally.
# ===============================================================================
Invoke-Test ':UnityBoot backs up boot.config write-once and aborts without one' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'UnityBoot'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':UnityBoot body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "boot\.config\.bak" copy /y') ':UnityBoot copies over boot.config.bak unconditionally again (regression of F1).'
    Assert-True ($code -match '(?i)_ubbak!"=="0"')                              ':UnityBoot lost its no-backup abort gate (regression of F4).'
    $joined = $body -join "`n"
    Assert-True ($joined -notmatch '(?i)^echo\s+Old file') ':UnityBoot claims the .bak unconditionally again (regression of the false-success fix).'
}

# ===============================================================================
# 80. F4: :StartupWorker must confirm the undo .reg actually landed before it
#     flips the entry. ErrorActionPreference is SilentlyContinue, so a blocked
#     Out-File would otherwise fail silently and the flip would be unbacked -
#     while the result text still named a backup file that does not exist.
# ===============================================================================
Invoke-Test ':StartupWorker verifies the undo backup landed before flipping' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'StartupWorker'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':StartupWorker body empty.'
    $joined = $body -join "`n"
    $chk = $joined.IndexOf('Test-Path -LiteralPath $bak')
    $set = $joined.IndexOf('[Microsoft.Win32.Registry]::SetValue')
    Assert-True ($chk -ge 0)      ':StartupWorker no longer verifies the undo .reg landed (regression of F4).'
    Assert-True ($set -ge 0)      ':StartupWorker SetValue call not found - routine changed shape?'
    Assert-True ($chk -lt $set)   ':StartupWorker verifies the backup AFTER writing the new value (regression of F4).'
}

# ===============================================================================
# 81. F3: OneDrive file sync is opt-in, never part of the privacy core. It rode
#     "Apply recommended safe set" (no prompts) and the LIGHT preset ("nothing
#     risky") while appearing on no screen and in no README.
# ===============================================================================
Invoke-Test 'OneDrive sync block is opt-in, not in :DoPrivacyCore' {
    $cmd = Read-Lines $CmdPath
    $core = Get-RoutineBody -Lines $cmd -Label 'DoPrivacyCore'
    $core = @($core)
    Assert-True ($core.Count -gt 0) ':DoPrivacyCore body empty.'
    Assert-True (($core -join "`n") -notmatch '(?i)DisableFileSyncNGSC') ':DoPrivacyCore writes DisableFileSyncNGSC again - it would ride Apply-recommended and every preset unprompted (regression of F3).'

    $od = Get-RoutineBody -Lines $cmd -Label 'DoOneDriveSyncOff'
    $od = @($od)
    Assert-True ($od.Count -gt 0) ':DoOneDriveSyncOff is missing.'
    $odCode = @($od | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($odCode -match '(?i)call :SafeRegAdd .*DisableFileSyncNGSC') ':DoOneDriveSyncOff no longer writes the policy through :SafeRegAdd (so it would not be backed up).'

    $priv = (Get-RoutineBody -Lines $cmd -Label 'Privacy') -join "`n"
    Assert-True ($priv -match '(?i)call :DoOneDriveSyncOff') ':Privacy no longer offers OneDrive as an opt-in prompt (regression of F3).'

    $chk = (Get-RoutineBody -Lines $cmd -Label 'PresetCheckLine') -join "`n"
    Assert-True ($chk -match '(?i)"[%!]_k[%!]"=="onedrive_off"') 'Preset validator lost the onedrive_off key.'
    $all = ($cmd -join "`n")
    Assert-True ($all -match '(?i)if defined _P_ONEDRIVE\s+call :DoOneDriveSyncOff') 'Custom presets no longer apply onedrive_off.'
}

# ===============================================================================
# 82. F3: the privacy screen must name what the core actually changes beyond
#     telemetry - Widgets feed, Start app-launch tracking, dmwappushservice.
# ===============================================================================
Invoke-Test 'Privacy screen discloses Widgets / app-launch tracking / dmwappushservice' {
    $cmd = Read-Lines $CmdPath
    $pv = Get-RoutineBody -Lines $cmd -Label 'Privacy'
    $priv = (@($pv) | Where-Object { $_.Trim() -match '^(?i)echo\b' }) -join "`n"
    Assert-True ($priv.Length -gt 0) ':Privacy has no echo lines - routine changed shape?'
    Assert-True ($priv -match '(?i)widgets')          ':Privacy screen no longer discloses the Widgets / News and Interests write (regression of F3).'
    Assert-True ($priv -match '(?i)app-launch')       ':Privacy screen no longer discloses Start app-launch tracking (regression of F3).'
    Assert-True ($priv -match '(?i)dmwappushservice') ':Privacy screen no longer discloses dmwappushservice / its MDM caveat (regression of F3).'
    $core = Get-RoutineBody -Lines $cmd -Label 'DoPrivacyCore'
    $core = @($core) -join "`n"
    Assert-True ($core -match '(?i)AllowNewsAndInterests') ':DoPrivacyCore no longer writes AllowNewsAndInterests - screen text and code disagree.'
    Assert-True ($core -match '(?i)Start_TrackProgs')      ':DoPrivacyCore no longer writes Start_TrackProgs - screen text and code disagree.'
}


# ===============================================================================
# 83. F5: every action that tracks _FAILS also sets _RUNTRACK, so :Run can count a
#     failed sc/schtasks/powercfg call on a non-elevated run. Registry writes bump
#     _FAILS independently, so the gap only ever hid service-level failures - but
#     that is still an [OK] over a "sc stop" that did nothing.
# ===============================================================================
Invoke-Test 'Core actions set _RUNTRACK alongside _FAILS (service failures counted)' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'Privacy','Power','Performance','ApplyRecommended') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r)
        Assert-True ($b.Count -gt 0) (":$r body empty.")
        $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($code -match '(?i)set "_RUNTRACK=1"') ":$r no longer sets _RUNTRACK - a failed sc/schtasks/powercfg on a non-elevated run goes uncounted and the action can still print [OK] (regression of F5)."
        Assert-True ($code -match '(?i)set "_FAILS=0"')    ":$r no longer resets _FAILS before its writes (regression)."
    }
}

# ===============================================================================
# 84. F6/F7: OpenAsar - _DONE only means at least ONE flavor worked, so a per-flavor
#     failure tally is what keeps the closing line honest; and the downloaded
#     nightly is a temp file that used to be left behind after a successful install.
# ===============================================================================
Invoke-Test 'OpenAsar counts per-flavor failures and cleans up the downloaded nightly' {
    $cmd = Read-Lines $CmdPath
    $ia = Get-RoutineBody -Lines $cmd -Label 'InstallAsarInto'
    $ia = @($ia)
    Assert-True ($ia.Count -gt 0) ':InstallAsarInto body empty.'
    $iaCode = @($ia | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    $bumps = ([regex]::Matches($iaCode, '(?i)set /a _OAFAIL\+=1')).Count
    Assert-True ($bumps -ge 2) "::InstallAsarInto should bump _OAFAIL on BOTH failure exits (no-backup abort and copy-failed); found $bumps (regression of F6)."

    # :OpenAsar's install loop lives past :OA_HaveSrc, and that sub-label does NOT start
    # with '_', so it ends the routine body. Concatenate rather than assert on a stub.
    foreach ($r in 'OpenAsar','DoOpenAsarSilent') {
        if ($r -eq 'OpenAsar') {
            $b1 = Get-RoutineBody -Lines $cmd -Label 'OpenAsar'
            $b2 = Get-RoutineBody -Lines $cmd -Label 'OA_HaveSrc'
            $b = @($b1) + @($b2)
        } else {
            $b = Get-RoutineBody -Lines $cmd -Label $r
        }
        $b = @($b)
        Assert-True ($b.Count -gt 0) (":$r body empty.")
        $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($code -match '(?i)set "_OAFAIL=0"')  ":$r does not reset _OAFAIL before the install loop - a stale tally would carry over (regression of F6)."
        Assert-True ($code -match '(?i)_OAFAIL%"=="0"')   ":$r never reports the failure tally, so a partial install still reads as success (regression of F6)."
        Assert-True ($code -match '(?i)del /f /q "!_OADL!"') ":$r leaves the downloaded nightly behind in %TEMP% (regression of F7)."
    }
}

# ===============================================================================
# 85. F8: the Status hosts line is guarded on the file existing - it used to print
#     the [hosts file] header and then nothing at all when the file was missing.
# ===============================================================================
Invoke-Test ':Status hosts line is guarded on the file existing' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'Status'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':Status body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($code -match '(?i)if exist "%_hostsf%" for /f') ':Status runs the hosts line count unguarded again - a missing hosts prints an empty section (regression of F8).'
    Assert-True ($code -match '(?i)if not defined _hlines echo')  ':Status has no fallback line when the hosts count could not be taken (regression of F8).'
}

# ===============================================================================
# 86. F9: DisableStatusMessages is read numerically. findstr /C:"0x1" was a
#     SUBSTRING match, so 0x10 / 0x1a / 0x1f all read as "enabled".
# ===============================================================================
Invoke-Test ':VerboseStatusNote compares DisableStatusMessages numerically' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'VerboseStatusNote'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':VerboseStatusNote body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -notmatch '(?i)findstr /I /C:"0x1"') ':VerboseStatusNote is substring-matching "0x1" again - 0x10/0x1a would read as enabled (regression of F9).'
    Assert-True ($code -match '(?i)set /a _dsmval')          ':VerboseStatusNote no longer parses the value with set /a (regression of F9).'
    Assert-True ($code -match '(?i)if not "!_dsmval!"=="0" set "_dsmon=1"') ':VerboseStatusNote no longer treats any nonzero value as the override being in force (regression of F9).'
}

# ===============================================================================
# 87. F10: :BackupSingleValue maps all five hives, matching :SafeRegAdd. Only
#     HKLM/HKCU reach it today, but a half-map exports the wrong key the moment
#     this helper gains a second caller.
# ===============================================================================
Invoke-Test ':BackupSingleValue maps all five hives like :SafeRegAdd' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'BackupSingleValue'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':BackupSingleValue body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    foreach ($h in 'HKEY_LOCAL_MACHINE','HKEY_CURRENT_USER','HKEY_CLASSES_ROOT','HKEY_USERS','HKEY_CURRENT_CONFIG') {
        Assert-True ($code -match [regex]::Escape($h)) ":BackupSingleValue no longer maps $h - reg export would get a short-name key it cannot resolve (regression of F10)."
    }
}


# ===============================================================================
# 88. The power action is split by SCOPE: :DoPowerPlanSwitch changes which scheme
#     is active, :DoPowerTimeouts tunes whichever scheme IS active ("powercfg
#     -change" always targets the active one). :DoPowerCore stays the aggregate so
#     preset "power=1" and Apply-recommended keep their existing meaning.
# ===============================================================================
Invoke-Test 'Power action splits plan switch from plan-agnostic timeouts' {
    $cmd = Read-Lines $CmdPath
    $sw = ((Get-RoutineBody -Lines $cmd -Label 'DoPowerPlanSwitch') -join "`n")
    $to = ((Get-RoutineBody -Lines $cmd -Label 'DoPowerTimeouts')   -join "`n")
    $co = ((Get-RoutineBody -Lines $cmd -Label 'DoPowerCore')       -join "`n")
    Assert-True ($sw.Length -gt 0) ':DoPowerPlanSwitch is missing.'
    Assert-True ($to.Length -gt 0) ':DoPowerTimeouts is missing.'
    Assert-True ($sw -match '(?i)setactive')      ':DoPowerPlanSwitch no longer activates a scheme.'
    Assert-True ($sw -notmatch '(?i)powercfg -change') ':DoPowerPlanSwitch absorbed the timeout calls again - declining the plan switch would take the timeouts with it (regression of the split).'
    Assert-True ($to -notmatch '(?i)setactive')   ':DoPowerTimeouts switches the scheme - it must only tune the ACTIVE one, or the current-plan path silently changes plans (regression of the split).'
    $chg = ([regex]::Matches($to, '(?i)powercfg -change -')).Count
    Assert-True ($chg -eq 6) "::DoPowerTimeouts should hold all 6 monitor/standby/disk AC+DC calls; found $chg."
    Assert-True ($co -match '(?i)call :DoPowerPlanSwitch') ':DoPowerCore no longer switches the plan - preset "power=1" would quietly stop doing what it always did.'
    Assert-True ($co -match '(?i)call :DoPowerTimeouts')   ':DoPowerCore no longer applies the timeouts - preset "power=1" would quietly stop doing what it always did.'
    # Ultimate Performance is a workstation plan Windows hides on battery-powered machines,
    # so which plan gets activated is now an explicit choice rather than a hidden yes/no.
    Assert-True ($sw -match '(?i)if not defined _pwsel set "_pwsel=ultimate"') ':DoPowerPlanSwitch no longer defaults an unset request to ultimate - preset "power=1" and Apply-recommended would silently change meaning (regression).'
    Assert-True ($sw -match '(?i)"%_pwsel%"=="high"')     ':DoPowerPlanSwitch lost the High Performance branch (regression).'
    Assert-True ($sw -match '(?i)"%_pwsel%"=="balanced"') ':DoPowerPlanSwitch lost the Balanced branch - there would be no in-app way back to the Windows default plan (regression).'
    # _PWPLAN is an INPUT to this routine. It used to apply its own "ultimate" fallback by
    # WRITING the global, which made the fallback stick for the whole session: one pass
    # through here and every later caller inherited a plan choice nobody made on its screen.
    # Resolving into _pwsel keeps the default while leaving the caller's variable alone.
    $swCode = @((Get-RoutineBody -Lines $cmd -Label 'DoPowerPlanSwitch') | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($swCode -notmatch '(?i)set "_PWPLAN=') ':DoPowerPlanSwitch writes back to _PWPLAN - the fallback would persist for the rest of the session and steer later actions that never asked for a plan (regression of F-A2).'
    Assert-True ($swCode -match '(?i)set "_pwsel=%_PWPLAN%"') ':DoPowerPlanSwitch no longer reads the requested plan into a local (regression of F-A2).'
    Assert-True ($sw -match '(?i)381b4222-f694-41f0-9685-ff5bb260df2e') ':DoPowerPlanSwitch no longer knows the Balanced GUID (regression).'
    Assert-True ($sw -match '(?i)8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') ':DoPowerPlanSwitch no longer knows the High Performance GUID (regression).'
}

# ===============================================================================
# 89. Declining the plan switch must NOT end the action. Every other option on the
#     screen acts on the active scheme, so one "no" used to throw away four working
#     changes. The screen also shows the current plan before asking.
# ===============================================================================
Invoke-Test ':Power offers a current-plan path when the switch is declined' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'Power'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':Power body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($code -notmatch '(?i)if /i not "[%!]_c[%!]"=="Y" goto MainMenu') ':Power sends a declined plan switch straight back to the main menu again - hibernation, min CPU state and throttling become unreachable (regression of the current-plan path).'
    Assert-True ($code -match '(?i)set /p "_c2=')             ':Power no longer asks whether to apply changes to the CURRENT plan (regression).'
    Assert-True ($code -match '(?i)if defined _PWPLAN call :DoPowerPlanSwitch') ':Power no longer gates the scheme switch on the plan answer (regression).'
    Assert-True ($code -match '(?i)set "_PWPLAN="')           ':Power does not clear _PWPLAN first - a stale value from a previous visit would switch the plan without being asked.'
    Assert-True ($code -match '(?i)powercfg /getactivescheme') ':Power no longer shows the current plan before asking to change it (regression).'
    Assert-True ($code -match '(?i)call :Summary')            ':Power no longer reports through :Summary.'
    Assert-True ($code -match '(?i)set /p "_c=Choose \[1/2/3/N\]') ':Power no longer offers an explicit plan choice - a yes/no hides the fact that "yes" means a workstation plan (regression).'
    foreach ($v in 'ultimate','high','balanced') {
        Assert-True ($code -match ('(?i)set "_PWPLAN=' + $v + '"')) ":Power can no longer select the $v plan (regression)."
    }
    # The advisory lines are conditional (`if /i "%MACHINE%"=="laptop" echo ...`), so match
    # any line that echoes - but still drop rem, because this test's own subject is discussed
    # in the routine's comments and would satisfy the assertion without any user seeing it.
    $echoes = (@($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)\becho\b' }) -join "`n")
    Assert-True ($echoes -match '(?i)undervolt') ':Power no longer warns a laptop that a plan jump is where a stable undervolt fails - that is a real WHEA 0x124 on real hardware, not a theoretical caveat (regression).'
    Assert-True ($echoes -match '(?i)MACHINE|battery-powered') ':Power lost the machine-aware framing on the plan warning (regression).'
}

# ===============================================================================
# 90. Preset key power_timeouts = the timeouts WITHOUT the scheme switch, and it
#     must not double-run when power=1 already covered them.
# ===============================================================================
Invoke-Test 'Preset key power_timeouts applies timeouts without switching plans' {
    $cmd = Read-Lines $CmdPath
    $chk = ((Get-RoutineBody -Lines $cmd -Label 'PresetCheckLine') -join "`n")
    Assert-True ($chk -match '(?i)"[%!]_k[%!]"=="power_timeouts"') 'Preset validator lost the power_timeouts key.'
    $all = ($cmd -join "`n")
    Assert-True ($all -match '(?i)if not defined _P_POWER if defined _P_PWTIMEOUTS call :DoPowerTimeouts') 'Custom presets no longer apply power_timeouts, or lost the guard that stops it running twice alongside power=1.'
    Assert-True ($chk -match '(?i)"[%!]_k[%!]"=="power_plan"') 'Preset validator lost the power_plan key - a preset could only ever get the hidden Ultimate default.'
    $pk = ((Get-RoutineBody -Lines $cmd -Label 'PChkPlan') -join "`n")
    Assert-True ($pk.Length -gt 0) ':PChkPlan is missing.'
    foreach ($v in 'ultimate','high','balanced') {
        # accepts either the old argument form or the delayed-expansion one the validator
        # moved to, so user text never reaches parse-time expansion
        Assert-True ($pk -match ('(?i)"(?:%~1|!_v!)"=="' + $v + '"')) ":PChkPlan no longer accepts $v (regression)."
    }
    Assert-True ($pk -match '(?i)_perr\+=1') ':PChkPlan accepts an unrecognised plan name instead of reporting it (regression).'
    Assert-True ($all -match '(?i)if defined _P_PWPLAN\s+set "_PWPLAN=%_P_PWPLAN%"') 'Custom presets parse power_plan but never hand it to :DoPowerPlanSwitch (regression).'
}


# ===============================================================================
# 91. The power action captures an undo file BEFORE it changes anything - the last
#     "mutates state with no backup" gap in the script. The capture reads the
#     registry, not localized "powercfg /query" text, or it would silently record
#     nothing on a non-English Windows and hand back a file that restores less
#     than it claims.
# ===============================================================================
Invoke-Test ':PowerBackup captures an undo file before either power half changes anything' {
    $cmd = Read-Lines $CmdPath
    $pbAll = Get-RoutineBody -Lines $cmd -Label 'PowerBackup'
    $pbAll = @($pbAll)
    Assert-True ($pbAll.Count -gt 0) ':PowerBackup is missing.'
    # Strip rem/echo first: this routine's own comment explains WHY it avoids the localized
    # "Current AC Power Setting Index" text, which would satisfy the negative assertion below.
    $pb = @($pbAll | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($pb.Length -gt 0) ':PowerBackup has no code lines - only comments?'
    Assert-True ($pb -match '(?i)PowerSchemes')            ':PowerBackup no longer reads the scheme values from the registry (regression).'
    Assert-True ($pb -match '(?i)ACSettingIndex')          ':PowerBackup no longer captures the AC timeout values.'
    Assert-True ($pb -match '(?i)DCSettingIndex')          ':PowerBackup no longer captures the DC timeout values.'
    Assert-True ($pb -notmatch '(?i)Current AC Power Setting') ':PowerBackup parses localized powercfg text again - it would capture nothing on a non-English Windows (regression).'
    # The flags come from a table now (powercfg '+$s[1]+'), so assert the flags themselves.
    Assert-True ($pb -match '(?i)-setacvalueindex') ':PowerBackup no longer emits AC restore commands into the undo file.'
    Assert-True ($pb -match '(?i)-setdcvalueindex') ':PowerBackup no longer emits DC restore commands into the undo file.'
    Assert-True ($pb -match '(?i)powercfg -setactive')       ':PowerBackup undo file no longer re-activates the captured scheme.'
    # A setting the scheme never stored explicitly must still be restorable: sincript writes an
    # explicit 0 over it, so "leave it alone" left never-sleep in place after a revert. The chain
    # is per-scheme value -> that plan's default -> the value actually in effect, and only then a
    # comment. The last step reads powercfg /query as HEX, never its localized labels.
    Assert-True ($pb -match '(?i)DefaultPowerSchemeValues') ':PowerBackup no longer falls back to the plan default, so a setting the scheme never stored would go unrestored (regression).'
    Assert-True ($pb -match '0x\[0-9a-fA-F\]\{8\}') ':PowerBackup no longer reads the effective value as hex - on a custom or OEM plan there is neither a stored value nor a plan default, so that setting would go unrestored (regression).'
    Assert-True ($pb -match '(?i)could not be read at backup time') ':PowerBackup no longer honest-declines when nothing can be read at all - it would emit a guessed restore line (regression).'
    # PROCTHROTTLEMIN is reachable on its own (decline the plan switch AND the timeouts, then
    # say yes to the minimum processor state), so leaving it out made the prompt promise an
    # undo that did not exist.
    Assert-True ($pb -match '(?i)893dee8e-2bef-41e0-89c6-b55d0929964c') ':PowerBackup no longer captures PROCTHROTTLEMIN - the minimum-processor-state prompt would imply an undo it does not have (regression).'
    # A partial run is the realistic failure here: the machine crashed part-way through the
    # restore and never reached -setactive, so the plan stayed switched. It goes back FIRST.
    $first = $pb.IndexOf('powercfg -setactive')
    $write = $pb.IndexOf('-setacvalueindex')   # the flag now comes from a table, not a literal
    Assert-True ($first -ge 0 -and $write -ge 0) ':PowerBackup undo file lost its setactive / value writes (regression).'
    Assert-True ($first -lt $write) ':PowerBackup undo file re-activates the scheme only AFTER the value writes - a run that stops part-way leaves the plan switched (regression).'
    $reactivations = ([regex]::Matches($pb, '(?i)powercfg -setactive')).Count
    Assert-True ($reactivations -ge 2) ':PowerBackup undo file no longer re-activates the scheme after the writes - powercfg needs that for changed values to take effect (regression).'

    # The generated file is real cmd and gets the same honesty rule as the script that wrote
    # it: every restore goes through a counting helper and the summary reflects the count.
    # It used to print a flat "restored" line whatever happened, so a run that could write
    # nothing still read as success - pitfall 18, living inside generated output.
    # Assert EVERY emitted powercfg goes through the helper, not merely that one does -
    # replacing a single call site would otherwise leave this green.
    # The value-write flag comes from a table now, so match up to "powercfg " rather than the
    # literal "-set" that used to follow it - otherwise this counts 2 and misses the third.
    $emitPc  = ([regex]::Matches($pb, "'powercfg ")).Count
    $emitVia = ([regex]::Matches($pb, "'call :pt_do powercfg ")).Count
    Assert-True ($emitVia -ge 3)   ':PowerBackup emits fewer than three counted powercfg restores - the undo file lost commands (regression).'
    Assert-True ($emitPc -eq 0)    ':PowerBackup emits a powercfg restore that bypasses its counting helper - that failure would go unrecorded (regression).'
    Assert-True ($pb -match '(?i)\[OK\] Restored')         ':PowerBackup undo file lost its counted [OK] summary (regression).'
    Assert-True ($pb -match '(?i)\[WARN\]')                ':PowerBackup undo file has no [WARN] branch - a partial restore would still report success (regression).'
    # The DEFINITION, not the name - "call :pt_do" satisfies a bare name match, so deleting
    # the helper body would have left the old assertion green while the file failed to run.
    Assert-True ($pb -match "':pt_do','")                 ':PowerBackup undo file calls :pt_do but no longer emits its definition - the generated file would die on an unknown label (regression).'
    Assert-True ($pb -match "':pt_bad','")                ':PowerBackup undo file no longer emits the :pt_bad failure branch (regression).'
    # cmd-quoting: the payload lives inside powershell -Command "..." so a raw " truncates it
    Assert-True ($pb -notmatch 'set \"PT_OK') ':PowerBackup embeds a raw double quote in a cmd-quoted PowerShell payload - cmd ends the argument at the first one. Build quotes with [char]34 (regression).'

    $smp = ((Get-RoutineBody -Lines $cmd -Label 'SetMinProcState') -join "`n")
    Assert-True ($smp -match '(?i)call :PowerBackup') ':SetMinProcState no longer captures an undo file - it is reachable without the plan switch or the timeouts, so nothing else would have captured one (regression).'

    foreach ($r in 'DoPowerPlanSwitch','DoPowerTimeouts') {
        # Strip rem/echo before the ordering check: :DoPowerTimeouts' own comment quotes
        # "powercfg -change" while explaining why the timeouts are plan-agnostic, which
        # would otherwise be found as the first "change" and sit before the capture call.
        $bAll = Get-RoutineBody -Lines $cmd -Label $r
        $bAll = @($bAll)
        Assert-True ($bAll.Count -gt 0) ":$r body empty."
        $b = @($bAll | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        $cap = $b.IndexOf('call :PowerBackup')
        $chg = [regex]::Match($b, '(?i)powercfg [-/]')
        Assert-True ($cap -ge 0) ":$r no longer captures a power undo file (regression)."
        Assert-True ($chg.Success -and $cap -lt $chg.Index) ":$r changes power settings before capturing the undo file (regression)."
    }
}

# ===============================================================================
# 92. One undo file per action, not per routine (:DoPowerCore calls both halves),
#     so every entry point clears the marker and :PowerBackup no-ops if it is set.
# ===============================================================================
Invoke-Test 'Power undo file is captured once per action' {
    $cmd = Read-Lines $CmdPath
    $pb = ((Get-RoutineBody -Lines $cmd -Label 'PowerBackup') -join "`n")
    Assert-True ($pb -match '(?i)if defined _PWBAK_FILE goto :eof') ':PowerBackup lost its once-per-pass guard - :DoPowerCore would write two undo files for one action (regression).'
    foreach ($r in 'Power','ApplyRecommended','PresetBegin') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r)
        Assert-True ($b.Count -gt 0) (":$r body empty.")
        $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($code -match '(?i)set "_PWBAK_FILE="') ":$r does not clear _PWBAK_FILE, so a later power change in the same session would reuse a stale undo file and capture nothing (regression)."
    }
}

# ===============================================================================
# 93. The undo file is reachable from the UI - a backup nobody can run is not an
#     undo. Item 6 on Backups & status (telemetry is 7, Manage 8).
# ===============================================================================
Invoke-Test ':RestorePowerBackup is wired into the Backups menu' {
    $cmd = Read-Lines $CmdPath
    $mb = ((Get-RoutineBody -Lines $cmd -Label 'MenuBackups') -join "`n")
    Assert-True ($mb -match '(?i)6\.\s+Revert power settings') ':MenuBackups no longer offers the power revert item (regression).'
    Assert-True ($mb -match '(?i)7\.\s+Revert telemetry services / tasks') ':MenuBackups lost the telemetry revert item.'
    Assert-True ($mb -match '(?i)8\.\s+Manage / open backup folder') ':MenuBackups lost the renumbered Manage item.'
    $ask = ((Get-RoutineBody -Lines $cmd -Label 'MenuBackups_ask') -join "`n")
    Assert-True ($ask -match '(?i)"!sel!"=="6" goto RestorePowerBackup') 'Backups menu item 6 no longer routes to :RestorePowerBackup (regression).'
    Assert-True ($ask -match '(?i)"!sel!"=="7" goto RestoreTelemetryBackup') 'Backups menu item 7 no longer routes to :RestoreTelemetryBackup (renumbering broke).'
    Assert-True ($ask -match '(?i)"!sel!"=="8" goto ManageBackups')      'Backups menu item 8 no longer routes to :ManageBackups (renumbering broke).'

    # :RestorePowerBackup_ask does not start with "_", so it ends the routine body - concatenate.
    $r1 = Get-RoutineBody -Lines $cmd -Label 'RestorePowerBackup'
    $r2 = Get-RoutineBody -Lines $cmd -Label 'RestorePowerBackup_ask'
    $rb = (@($r1) + @($r2)) -join "`n"
    Assert-True ($rb -match '(?i)PowerPlan_\*\.bat') ':RestorePowerBackup no longer lists the PowerPlan_*.bat undo files.'
    # In a CHILD cmd, never `call`ed: a syntax error in a called batch file ends ALL batch
    # processing, the caller included - which is how a broken undo file closed sincript
    # (test 126). /q still suppresses the file's own pause, which would block the menu.
    $rbCode = (@(Get-BodyLines -Lines $cmd -Label 'RestorePowerBackup' -CodeOnly) + @(Get-BodyLines -Lines $cmd -Label 'RestorePowerBackup_ask' -CodeOnly)) -join "`n"
    Assert-True ($rbCode -match '(?i)cmd /d /v:off /s /c ""!_pfile!" /q"') ':RestorePowerBackup no longer runs the chosen undo file in a child cmd with /q - `call`ed, a syntax error in it ends sincript too, and without /q its own pause blocks the menu (regression).'
    Assert-True ($rbCode -notmatch '(?i)\bcall\s+"?[%!]_pfile') ':RestorePowerBackup `call`s the undo file again - a syntax error in it would end sincript too (regression).'
}

# ===============================================================================
# 94. Two disclosure fixes: AutoEndTasks is a data-loss trade-off sold as "faster
#     shutdown", and :Status shows the hardware probes that drive the advisories -
#     otherwise the user cannot see what sincript concluded about their machine.
# ===============================================================================
Invoke-Test 'AutoEndTasks trade-off and hardware probes are disclosed' {
    $cmd = Read-Lines $CmdPath
    $pf = Get-RoutineBody -Lines $cmd -Label 'Performance'
    $pf = @($pf)
    Assert-True ($pf.Count -gt 0) ':Performance body empty.'
    $pfEcho = (@($pf | Where-Object { $_.Trim() -match '^(?i)echo\b' }) -join "`n")
    Assert-True ($pfEcho -match '(?i)AutoEndTasks') ':Performance screen no longer discloses the AutoEndTasks trade-off - unsaved work is lost at shutdown and the screen only says "faster shutdown" (regression).'
    $core = ((Get-RoutineBody -Lines $cmd -Label 'DoPerformanceCore') -join "`n")
    Assert-True ($core -match '(?i)AutoEndTasks') ':DoPerformanceCore no longer writes AutoEndTasks - screen text and code disagree.'

    $st = Get-RoutineBody -Lines $cmd -Label 'Status'
    $st = @($st)
    Assert-True ($st.Count -gt 0) ':Status body empty.'
    $stCode = @($st | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($stCode -match '(?i)%MACHINE%')        ':Status no longer shows the detected machine class (regression).'
    Assert-True ($stCode -match '(?i)%SYSDISK%')        ':Status no longer shows the detected disk type (regression).'
    Assert-True ($stCode -match '(?i)call :DetectSysDisk') ':Status shows SYSDISK without probing for it - it would read as empty on a run that never hit the SysMain prompt (regression).'
}


# ===============================================================================
# 95. The main-menu header shows the detected disk type next to Build / Win11 /
#     GPU / Machine, and probes for it FIRST - printing %SYSDISK% without calling
#     :DetectSysDisk renders an empty slot on a fresh run.
# ===============================================================================
Invoke-Test 'Main menu header shows the detected disk type' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'MainMenu'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':MainMenu body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    $probe = $code.IndexOf('call :DetectSysDisk')
    $show  = $code.IndexOf('Disk=%SYSDISK%')
    Assert-True ($show -ge 0)      ':MainMenu header no longer shows the detected disk type (regression).'
    Assert-True ($probe -ge 0)     ':MainMenu prints Disk= without probing for it - the slot renders empty on a fresh run (regression).'
    Assert-True ($probe -lt $show) ':MainMenu probes the disk AFTER printing it (regression).'
}

# ===============================================================================
# 96. Every menu separator renders the same width. Batch has no layout engine, so
#     a ragged menu is a real defect and an invisible one in source - the widths
#     only diverge on screen. A caret escapes the next character, so "^&" occupies
#     one column but two source characters; count rendered width, not raw length.
# ===============================================================================
Invoke-Test 'Menu separators all render the same width' {
    $cmd = Read-Lines $CmdPath
    $bad = New-Object System.Collections.Generic.List[string]
    $widths = @{}
    foreach ($l in $cmd) {
        $trimmed = $l.TrimStart()
        if ($trimmed -notmatch '^echo [=-]{4,}') { continue }
        $arg = $trimmed.Substring(5)
        $r = [regex]::Replace($arg, '\^(.)', '$1')
        $widths[$r.Length] = $true
        if ($r.Length -ne 98) {
            $bad.Add(("{0} wide: {1}" -f $r.Length, $arg.Substring(0, [Math]::Min(44, $arg.Length))))
        }
    }
    Assert-True ($widths.Keys.Count -gt 0) 'No separator lines found - has the menu changed shape?'
    Assert-True ($bad.Count -eq 0) ("Separators must all render 98 columns or the menus look ragged. Offenders: " + (($bad | Select-Object -First 4) -join ' | '))
}


# ===============================================================================
# 97. :DetectSysDisk caches its answer per MACHINE, not per session. The probe is
#     correct but costs a runtime C# compile (Add-Type), which became visible the
#     moment the disk type moved onto the main-menu header. The cache must be
#     keyed on hardware so it self-invalidates, must reject a value the prober
#     could never emit, and must never persist a failed probe.
# ===============================================================================
Invoke-Test ':DetectSysDisk caches its answer, keyed on hardware, never caching a failure' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'DetectSysDisk'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':DetectSysDisk body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"

    Assert-True ($code -match '(?i)sysdisk\.cache')  ':DetectSysDisk no longer caches its result - every session pays the Add-Type compile again (regression).'
    Assert-True ($code -match '(?i)Services\\disk\\Enum') ':DetectSysDisk cache is no longer keyed on the disk hardware ID - it could not notice a drive swap (regression).'
    Assert-True ($code -match '(?i)if /i "%SYSDISK%"=="unknown" goto :eof') ':DetectSysDisk would cache an "unknown" - one failed probe becomes permanent (regression).'
    Assert-True ($code -match '(?i)if /i not "!_sdcv!"=="ssd" if /i not "!_sdcv!"=="hdd" goto _sdProbe') ':DetectSysDisk trusts a cached value the prober could never emit (regression).'
    Assert-True ($code -match '(?i)if not "!_sdck!"=="!_sdkey!" goto _sdProbe') ':DetectSysDisk no longer compares the cached hardware key before using the cache (regression).'

    # the cache read must precede the probe, or it saves nothing
    $hit   = $code.IndexOf('set "SYSDISK=!_sdcv!"')
    $probe = $code.IndexOf(':_sdProbe')
    Assert-True ($hit -ge 0 -and $probe -ge 0) ':DetectSysDisk lost its cache-hit / probe split (regression).'
    Assert-True ($hit -lt $probe) ':DetectSysDisk runs the probe before consulting the cache (regression).'

    # the write must use delayed expansion: a device instance path contains & and \
    Assert-True ($code -match '(?i)> "!_sdcache!" echo !_sdkey!\^\|!SYSDISK!') ':DetectSysDisk cache write no longer uses delayed expansion with an escaped separator - an & in the device path would be re-parsed as an operator (regression).'
}


# ===============================================================================
# 98. The FILE'S BYTES. Pure ASCII, uniform CRLF, no BOM - all three are
#     load-bearing and all three break silently. A BOM puts three invisible bytes
#     in front of "@echo off", so line 1 stops being a command. A lone LF before a
#     label can make `goto` miss it. Non-ASCII in an ASCII-only script renders as
#     mojibake under the console code page. Nothing else in this harness looks at
#     bytes, and an editor that "helpfully" normalises the file leaves no other
#     trace - the diff looks empty.
# ===============================================================================
Invoke-Test 'Shipped text files stay ASCII-only, uniform CRLF, no BOM' {
    # Every file that ships and is read on Windows, not just the script. example.preset was
    # edited once with a literal "`n" and picked up two bare LF endings that nothing noticed,
    # which is exactly the silent-damage case this test exists for.
    $targets = @(@{ Path = $CmdPath; Name = 'PerfTweaks.cmd'; Min = 1000 },
                 @{ Path = $PresetPath; Name = 'example.preset'; Min = 50 })
    $checked = 0
    foreach ($tgt in $targets) {
        if (-not (Test-Path -LiteralPath $tgt.Path)) { continue }
        $checked++
        $n = $tgt.Name
        $bytes = [System.IO.File]::ReadAllBytes($tgt.Path)
        Assert-True ($bytes.Length -gt $tgt.Min) "$n is suspiciously small - wrong path?"

        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-True (-not $hasBom) "$n has a UTF-8 BOM - three invisible bytes in front of the first line (regression)."

        $nonAscii = 0; $firstNon = -1; $loneLf = 0; $firstLf = -1; $loneCr = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $b = $bytes[$i]
            if ($b -gt 127) { $nonAscii++; if ($firstNon -lt 0) { $firstNon = $i } }
            if ($b -eq 10 -and ($i -eq 0 -or $bytes[$i-1] -ne 13)) { $loneLf++; if ($firstLf -lt 0) { $firstLf = $i } }
            if ($b -eq 13 -and ($i -eq $bytes.Length-1 -or $bytes[$i+1] -ne 10)) { $loneCr++ }
        }
        Assert-True ($nonAscii -eq 0) ("{0} is no longer ASCII-pure: {1} byte(s), first at offset {2}. It renders as mojibake under the console code page (regression)." -f $n, $nonAscii, $firstNon)
        Assert-True ($loneLf -eq 0)   ("{0} has {1} bare LF line ending(s), first at offset {2}. In the script a label after a lone LF can be missed by goto; in any shipped file it means an edit was written with the wrong newline (regression)." -f $n, $loneLf, $firstLf)
        Assert-True ($loneCr -eq 0)   ("{0} has {1} bare CR(s) - line endings are not uniform CRLF (regression)." -f $n, $loneCr)
    }
    Assert-True ($checked -ge 2) "Only $checked file(s) were byte-checked - a target path broke and this test was passing on less than it claims."
}

# ===============================================================================
# 99. Every number a menu PRINTS is a number it HANDLES, and vice versa. Renumber
#     a menu (item 6 was inserted into Backups & status, pushing Manage to 7) and
#     a stale branch leaves an option that silently does nothing, or a handler with
#     nothing to reach it. Both look completely fine in source.
#     Only statically-numbered menus are checked; pickers that build their list
#     with `for /l` have no literal items and are skipped by the >=3 threshold.
# ===============================================================================
Invoke-Test 'Menu items and their dispatch branches match exactly' {
    $cmd = Read-Lines $CmdPath
    $askLabels = @()
    foreach ($l in $cmd) { if ($l -match '^:(\w+)_ask\s*$') { $askLabels += $Matches[1] } }
    Assert-True ($askLabels.Count -gt 0) 'No :X_ask labels found - menus changed shape?'

    $checked = 0
    foreach ($m in $askLabels) {
        $menu = Get-RoutineBody -Lines $cmd -Label $m
        $menu = @($menu)
        $shown = @()
        foreach ($l in $menu) { if ($l -match '^echo\s+([0-9]+)\.\s') { $shown += $Matches[1] } }
        if ($shown.Count -lt 3) { continue }        # dynamic picker, not a static menu

        # Dispatch does not always live in :X_ask, and the variable is not always %sel% -
        # :PathEditor branches inline on %_pesc% before its list is even drawn. Scan the menu
        # body and the _ask body, and accept any "%<var>%"=="<n>" comparison.
        $ask = Get-RoutineBody -Lines $cmd -Label ($m + '_ask')
        $ask = @($ask)
        $handled = @()
        foreach ($l in ($menu + $ask)) { if ($l -match 'if(?:\s+/i)?\s+"[%!]\w+[%!]"=="([0-9]+)"') { $handled += $Matches[1] } }

        $missing = @($shown | Where-Object { $handled -notcontains $_ })
        $orphan  = @($handled | Where-Object { $shown -notcontains $_ })
        Assert-True ($missing.Count -eq 0) (":$m prints option(s) " + ($missing -join ',') + " with no dispatch branch - selecting them does nothing (regression).")
        Assert-True ($orphan.Count -eq 0)  (":${m}_ask dispatches option(s) " + ($orphan -join ',') + " that the menu never prints - dead branch, or a renumbering half-applied (regression).")
        $checked++
    }
    Assert-True ($checked -ge 8) ("Only $checked static menu(s) were checked - the detection broke and this test was passing vacuously.")
}

# ===============================================================================
# 100. EVERY registry write goes through :SafeRegAdd / :SafeRegDelete. That pair is
#      where the per-value .reg backup, the idempotent skip, the [FAIL] line and the
#      _FAILS tally all live, so a bare `reg add` anywhere else is a change with no
#      undo, no honesty and no record - it defeats the entire safety model in one
#      line that looks completely ordinary. The two permitted writes are the apply
#      tails themselves.
# ===============================================================================
Invoke-Test 'No registry write bypasses :SafeRegAdd / :SafeRegDelete' {
    $cmd = Read-Lines $CmdPath
    $offenders = New-Object System.Collections.Generic.List[string]
    $total = 0
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $l = $cmd[$i].Trim()
        if ($l -match '^(?i)rem\b') { continue }                       # a comment naming reg add is not a call
        if ($l -notmatch '^(?i)reg\s+(add|delete)\b') {
            # also catch it smuggled through the :Run helpers
            if ($l -match '(?i)call :Run(Live)?\s+"reg\s+(add|delete)\b') {
                $offenders.Add(("L{0}: {1}" -f ($i+1), $l)); }
            continue
        }
        $total++
        # walk back to the owning label
        $owner = '<none>'
        for ($j = $i; $j -ge 0; $j--) { if ($cmd[$j] -match '^:(\w+)') { $owner = $Matches[1]; break } }
        if ($owner -ne '_sraApply' -and $owner -ne '_srdApply') {
            $offenders.Add(("L{0} in :{1}: {2}" -f ($i+1), $owner, $l))
        }
    }
    Assert-True ($total -ge 2) "Expected at least the 2 wrapper writes, found $total - :SafeRegAdd / :SafeRegDelete changed shape and this test would pass vacuously."
    Assert-True ($offenders.Count -eq 0) ("Registry write outside the backed-up wrappers - no undo file, no [FAIL], no _FAILS tally: " + (($offenders | Select-Object -First 3) -join ' | '))
}

# ===============================================================================
# 101. A typed DNS resolver is free text on its way to a command line - the shape
#      that let & | < > be parsed as operators elsewhere. Two defences, both
#      asserted: :_ip4_ok allows nothing but digits and dots and range-checks all
#      four octets, and every use is late-expanded so even a value that got past
#      it stays literal. The preset key runs the same validator or it becomes the
#      way round the menu. Also: flushing the cache is its own action, and the
#      current-resolver line is a registry read, never localized netsh output.
# ===============================================================================
Invoke-Test 'Custom DNS input is validated before it reaches a command line' {
    $cmd = Read-Lines $CmdPath
    $v = Get-RoutineBody -Lines $cmd -Label '_ip4_ok'
    $v = @($v)
    Assert-True ($v.Count -gt 0) ':_ip4_ok is missing.'
    $vc = @($v | Where-Object { $_.Trim() -notmatch '^(?i)(echo\(|rem)\b' }) -join "`n"
    # The charset check must not go through a PIPE. cmd runs each side of a pipe in a child
    # and builds that child's command line from the already-expanded text, so the old
    # "echo(!_IPCHK!| findstr ..." split on "&" in the child: it RAN the injected remainder
    # and then handed findstr a clean "1.1.1.1", answering "valid". Verified both ways.
    Assert-True ($vc -notmatch '(?i)echo\(?!_IPCHK!\s*\|') ':_ip4_ok pipes the value into findstr again - the piped child re-parses it, so "1.1.1.1&command" executes the command and still validates (regression of F-J1).'
    # The eol= is part of the check, not decoration: for /f ignores a line whose first
    # character AFTER the leading delimiters is the eol character, and eol defaults to ";".
    # Without it "1.1.1.1;<anything>" produced no token at all and validated clean, and the
    # value went on to an elevated PowerShell command line. It must be an allowed character.
    Assert-True ($vc -match '(?i)for /f "eol=[0-9] delims=0123456789\." %%X in \("!_IPCHK!"\)') ':_ip4_ok lost its pipe-free charset check, or the eol= that closes the ";" hole (regression of F-J1).'
    Assert-True ($vc -match '(?i)if not "%%d"==""') ':_ip4_ok no longer requires a fourth octet - a missing token expands to empty, so "1.2.3." rebuilds to itself and passes (regression of F-J1).'
    # All four octets, not "at least one" - dropping a single check leaves the rest matching.
    # LEQ 255, not GTR 255: the checks are chained onto the four-part rebuild now, so they
    # only run once the shape is known good and never see a missing token.
    $oct = ([regex]::Matches($vc, '(?i)LEQ 255')).Count
    Assert-True ($oct -eq 4) "::_ip4_ok range-checks $oct octet(s), not 4 - the unchecked position accepts anything up to 999 (regression)."

    $d = Get-RoutineBody -Lines $cmd -Label 'DnsCustom'
    $d = @($d)
    Assert-True ($d.Count -gt 0) ':DnsCustom is missing.'
    $dc = @($d | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    # both prompts validated, and every use late-expanded so a metacharacter stays literal
    $checks = ([regex]::Matches($dc, '(?i)call :_ip4_ok')).Count
    Assert-True ($checks -ge 2) "::DnsCustom validates fewer than both resolvers ($checks) - the unchecked one reaches PowerShell (regression)."
    Assert-True ($dc -notmatch '%_dns1%' -and $dc -notmatch '%_dns2%') ':DnsCustom expands a typed resolver with %% instead of !! - cmd would parse & | < > in it as operators at parse time (regression).'
    Assert-True ($dc -match "(?i)DNSSRV='!_dns1!'") ':DnsCustom no longer builds DNSSRV from the validated value (regression).'

    # the preset door has to use the same validator, or it becomes the way round the menu
    $pk = ((Get-RoutineBody -Lines $cmd -Label 'PChkDns') -join "`n")
    Assert-True ($pk -match '(?i)call :_ip4_ok') 'Preset key dns accepts a literal address without the validator the menu uses (regression).'
    $pn = ((Get-RoutineBody -Lines $cmd -Label 'PresetDnsByName') -join "`n")
    Assert-True ($pn -match '(?i)set "DNSSRV="') ':PresetDnsByName does not clear DNSSRV first - a stale list from an earlier call would be applied instead (regression).'

    # flushing the cache is its own action, not something only a full stack reset can do
    $f = Get-RoutineBody -Lines $cmd -Label 'FlushDns'
    $f = @($f)
    Assert-True ($f.Count -gt 0) ':FlushDns is missing.'
    $fc = @($f | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($fc -match '(?i)call :Run "ipconfig /flushdns"') ':FlushDns no longer flushes (regression).'
    Assert-True ($fc -match '(?i)call :Summary')                  ':FlushDns reports without :Summary, so a failure could print as success (regression).'

    # the current-resolver line must stay a registry read, not localized netsh text
    # Strip rem first: this routine's comment explains WHY it avoids "show dnsservers",
    # which would satisfy the negative assertion below without any netsh call existing.
    $sAll = Get-RoutineBody -Lines $cmd -Label 'ShowCurrentDns'
    $sAll = @($sAll)
    Assert-True ($sAll.Count -gt 0) ':ShowCurrentDns is missing.'
    $s = @($sAll | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($s -match '(?i)Tcpip\\Parameters\\Interfaces') ':ShowCurrentDns no longer reads the interface keys (regression).'
    Assert-True ($s -notmatch '(?i)show dnsservers') ':ShowCurrentDns parses localized netsh output - it would show nothing on a translated Windows and read as "no DNS set" (pitfall 26 regression).'
}

# ===============================================================================
# 102. Custom-preset directives are plain globals, so applying one preset and then
#      another in the SAME session must not carry the first one's keys into the
#      second. :PresetCustom clears them up front from a hardcoded list, and that
#      list drifted: PWTIMEOUTS / ONEDRIVE / PWPLAN were validated and applied but
#      never cleared, so a preset with onedrive_off=1 poisoned every later preset
#      with a policy that STOPS OneDrive syncing - while the "Recognized directives"
#      count on screen honestly described the file that never asked for it.
#      Derived from the validators rather than restated, so it cannot drift again.
# ===============================================================================
Invoke-Test 'Every preset directive the validators set is cleared before a preset runs' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    # names the validators can define: `call :PVok NAME`, plus literal _P_NAME writes
    # (:PChkWin32 / :PChkPlan / :PChkDns). The dynamic `set "_P_%~1=1"` inside :PVok and
    # the reset loop's own `set "_P_%%K="` cannot match - % is outside the character class.
    $settable = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($all, '(?i)\bcall :PVok\s+([A-Za-z0-9_]+)')) { [void]$settable.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($all, '(?i)set "_P_([A-Za-z0-9_]+)='))       { [void]$settable.Add($m.Groups[1].Value) }
    Assert-True ($settable.Count -gt 0) 'Found no preset directive names at all - the validator shape changed.'

    $resetLine = $null
    foreach ($ln in $cmd) {
        if ($ln -match '(?i)^\s*for %%K in \(([^)]*)\) do set "_P_%%K="') { $resetLine = $Matches[1] }
    }
    Assert-True ($null -ne $resetLine) ':PresetCustom no longer clears the _P_* directives up front - every preset would inherit the previous one (regression of F-A1).'

    $cleared = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in ($resetLine -split '\s+')) { if ($n) { [void]$cleared.Add($n) } }

    $missing = @($settable | Where-Object { -not $cleared.Contains($_) } | Sort-Object)
    Assert-True ($missing.Count -eq 0) ("Preset directive(s) set by a validator but never cleared: {0}. Applying two presets in one session would silently apply the first one's keys to the second (regression of F-A1)." -f ($missing -join ', '))

    # and the reverse, so the list cannot rot into naming keys that no longer exist
    $stale = @($cleared | Where-Object { -not $settable.Contains($_) } | Sort-Object)
    Assert-True ($stale.Count -eq 0) ("Reset list clears _P_* name(s) no validator sets: {0} - the list has drifted from :PresetCheckLine." -f ($stale -join ', '))
}

# ===============================================================================
# 103. _PWPLAN decides WHICH power scheme :DoPowerPlanSwitch activates, and it is a
#      session global the Power menu writes. Any path that documents its own plan
#      must therefore clear it first, or menu history decides what a preset does:
#      pick Balanced on menu 4, run MODERATE, and the "recommended safe set" the
#      README documents as Ultimate quietly stayed on Balanced.
# ===============================================================================
Invoke-Test 'Power-plan choice cannot leak from the menu into presets or the safe set' {
    $cmd = Read-Lines $CmdPath

    foreach ($r in 'ApplyRecommended','PresetBegin') {
        # two steps on purpose: Get-RoutineBody returns `,$array`, so @(f) in ONE step wraps
        # the array instead of unrolling it and the whole body arrives as a single element.
        $body = Get-RoutineBody -Lines $cmd -Label $r
        $body = @($body)
        Assert-True ($body.Count -gt 0) (":$r is missing.")
        $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
        Assert-True ($code -match '(?i)set "_PWPLAN="') ":$r does not clear _PWPLAN - a plan picked on menu 4 earlier in the session would decide which scheme it activates (regression of F-A2)."
    }

    # every preset routes its power core through :PresetBegin, so the clear covers all four
    foreach ($p in 'PresetLight','PresetModerate','PresetHeavy') {
        $b = ((Get-RoutineBody -Lines $cmd -Label $p) -join "`n")
        Assert-True ($b -match '(?i)call :PresetBegin') ":$p no longer opens with :PresetBegin - it would skip the _PWPLAN reset (regression of F-A2)."
    }

    # :PresetCustom is the exception: its flow runs on through :PresetCustom_ask / :_pcHaveValid
    # / :_pcReady before it applies anything, and :PresetCustom_ask is a real (non-underscore)
    # label, so Get-RoutineBody stops before the apply block - correctly. Slice the whole flow
    # by file position instead, from :PresetCustom to the next real routine.
    $mS = @($cmd | Select-String -Pattern '^:PresetCustom\b')
    $mE = @($cmd | Select-String -Pattern '^:PresetCheckLine\b')
    Assert-True ($mS.Count -gt 0 -and $mE.Count -gt 0) 'Custom-preset flow labels not found - the preset section was restructured.'
    $pcBody = @($cmd[($mS[0].LineNumber - 1)..($mE[0].LineNumber - 2)])
    Assert-True ((($pcBody -join "`n") -match '(?i)call :PresetBegin')) ':PresetCustom no longer opens with :PresetBegin - it would skip the _PWPLAN reset (regression of F-A2).'

    # an explicit power_plan= key must still win, which means it is applied AFTER the reset
    $mBegin = @($pcBody | Select-String -SimpleMatch 'call :PresetBegin')
    $mPlan  = @($pcBody | Select-String -SimpleMatch 'set "_PWPLAN=%_P_PWPLAN%"')
    Assert-True ($mBegin.Count -gt 0) ':PresetCustom no longer calls :PresetBegin (regression).'
    Assert-True ($mPlan.Count  -gt 0) ':PresetCustom no longer applies the power_plan= key (regression).'
    Assert-True ($mPlan[0].LineNumber -gt $mBegin[0].LineNumber) ':PresetCustom applies power_plan= BEFORE :PresetBegin clears _PWPLAN, so the key is wiped and the preset silently falls back to ultimate (regression of F-A2).'
}

# ===============================================================================
# 104. _RUNTRACK is what lets :Run count a failed sc/schtasks/powercfg call, and
#      :Summary is the ONLY place it is cleared. So an action that turns it on and
#      never reports through :Summary leaves it on for the rest of the session, and
#      the next non-elevated cleanup counts its benign "del" failures as real ones -
#      the exact cry-wolf the :Run tally is written to avoid.
# ===============================================================================
Invoke-Test 'Tracking is turned off again: every _RUNTRACK=1 action reports via :Summary' {
    $cmd = Read-Lines $CmdPath

    $sum = ((Get-RoutineBody -Lines $cmd -Label 'Summary') -join "`n")
    Assert-True ($sum -match '(?i)set "_RUNTRACK="') ':Summary no longer clears _RUNTRACK - tracking would leak into every later action (regression).'

    $labels = @()
    foreach ($ln in $cmd) { if ($ln -match '^:(\w+)' -and $Matches[1] -notmatch '^_') { $labels += $Matches[1] } }
    $offenders = @()
    foreach ($L in ($labels | Select-Object -Unique)) {
        $b = ((Get-RoutineBody -Lines $cmd -Label $L) -join "`n")
        if ($b -match '(?i)set "_RUNTRACK=1"' -and $b -notmatch '(?i)call :Summary') { $offenders += $L }
    }
    Assert-True ($offenders.Count -eq 0) ("Routine(s) set _RUNTRACK=1 without reporting through :Summary, so tracking stays on for the rest of the session: {0} (regression of F-A3)." -f ($offenders -join ', '))

    # the action this was found in: it calls the undo .bat directly, never through :Run,
    # so tracking bought nothing there and only ever leaked
    $rp = @(Get-BodyLines -Lines $cmd -Label 'RestorePowerBackup')
    Assert-True ($rp.Count -gt 1) ':RestorePowerBackup is missing (or the body did not unroll).'
    $rpc = @($rp | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($rpc -notmatch '(?i)set "_RUNTRACK=1"') ':RestorePowerBackup turns tracking on again but never calls :Summary, so nothing turns it off (regression of F-A3).'
}

# ===============================================================================
# 105. A `call`ed routine must RETURN, never jump to a menu. cmd pops a call frame
#      on "goto :eof" / "exit /b" and never on a bare goto, so a subroutine that
#      ends with "goto MenuApps" leaves the frame its caller pushed pending for the
#      rest of the session. The next "exit /b" then returns INTO that frame instead
#      of ending the script - :ExitScript stops meaning exit, and the user lands
#      back inside the action they aborted. :RequireBundledFile did exactly this;
#      the guard is general because the shape is easy to reintroduce.
# ===============================================================================
Invoke-Test 'A called routine returns - it never jumps to a menu (call-stack integrity)' {
    $cmd = Read-Lines $CmdPath

    # menu labels = the screens an action can legitimately goto, but a SUBROUTINE cannot
    $menu = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ln in $cmd) {
        if ($ln -match '^:((?:Main)?Menu\w*|ExitScript)\s*$') { [void]$menu.Add($Matches[1]) }
    }
    Assert-True ($menu.Count -ge 8) "Found only $($menu.Count) menu labels - this test would barely check anything."

    # every label reached by `call` anywhere in the script, restricted to labels this file
    # actually defines. :PowerBackup builds a PowerPlan_*.bat whose text contains
    # "call :pt_do" - that is generated output for another file, not a subroutine here, and
    # test 91 checks it separately. A call target with no label in this file is never ours.
    $defined = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ln in $cmd) { if ($ln -match '^:(\w+)') { [void]$defined.Add($Matches[1]) } }
    $called = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ln in $cmd) {
        foreach ($m in [regex]::Matches($ln, '(?i)\bcall\s+:(\w+)')) {
            $t = $m.Groups[1].Value
            if ($t -ne 'eof' -and $defined.Contains($t)) { [void]$called.Add($t) }
        }
    }
    Assert-True ($called.Count -gt 20) 'Found suspiciously few call targets - the call convention changed.'

    $offenders = @()
    foreach ($L in $called) {
        $body = Get-RoutineBody -Lines $cmd -Label $L
        $body = @($body)
        foreach ($ln in $body) {
            if ($ln.Trim() -match '^(?i)rem\b') { continue }
            foreach ($g in [regex]::Matches($ln, '(?i)(?<![:\w])goto\s+:?(\w+)')) {
                if ($menu.Contains($g.Groups[1].Value)) { $offenders += ("{0} -> goto {1}" -f $L, $g.Groups[1].Value) }
            }
        }
    }
    Assert-True ($offenders.Count -eq 0) ("Called routine(s) jump to a menu instead of returning, leaving cmd's call stack one frame deep so a later 'exit /b' resumes the aborted caller instead of exiting: {0}. Return a status (exit /b 1) and let the caller own the goto (regression of F-B1)." -f ($offenders -join '; '))

    # the caller side of that contract: a status nobody reads is not a guard
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($cmd[$i] -notmatch '(?i)^\s*call :RequireBundledFile\b') { continue }
        $next = ''
        for ($j = $i + 1; $j -lt $cmd.Count; $j++) {
            if ($cmd[$j].Trim() -eq '' -or $cmd[$j].Trim() -match '^(?i)rem\b') { continue }
            $next = $cmd[$j]; break
        }
        Assert-True ($next -match '(?i)^\s*if errorlevel 1 goto \w+') ("Line $($i+1) calls :RequireBundledFile but the next statement does not check errorlevel - the action would carry on with the file missing. Found: '$($next.Trim())' (regression of F-B1).")
    }
}

# ===============================================================================
# 106. The backup folder is the whole tool's safety net: :SafeRegAdd refuses to
#      write a tweak whose per-value .reg did not land, and :Log writes into the
#      same folder. If `md` failed, every action reported [FAIL] for no visible
#      reason while ~100 log calls per session each printed "The system cannot
#      find the path specified." to the console, burying the real output.
# ===============================================================================
Invoke-Test 'A missing backup folder is reported once, not shouted on every log line' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    Assert-True ($all -match '(?i)set "_BAKOK=0"') 'Startup no longer verifies that the backup folder was actually created - the md result was never checked (regression of F-C1).'
    $warnIdx = ($cmd | Select-String -SimpleMatch 'The backup folder could not be created')
    Assert-True (@($warnIdx).Count -ge 1) 'The unwritable-backup-folder warning is gone - actions would fail with no stated reason (regression of F-C1).'

    # the warning block prints a path that can legitimately contain ")", so it must be
    # late-expanded or the if-block closes early at parse time and the script dies
    Assert-True ($all -notmatch '(?m)^\s*echo\s+%BACKUP_DIR%\s*$') 'The warning echoes %BACKUP_DIR% percent-expanded - a Documents path containing ")" would close the if-block and crash the script at startup.'

    # :Log must not be able to spew. The redirection failure is emitted by the command
    # processor as it sets the redirect up, so "2>nul" on the echo does NOT suppress it -
    # it has to sit on a CALL. Keep the write in its own routine, reached that way.
    $logBody = Get-RoutineBody -Lines $cmd -Label 'Log'
    $logBody = @($logBody)
    $logCode = @($logBody | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($logCode -match '(?i)call :_LogWrite 2>nul') ':Log no longer routes its write through a redirected call, so a missing backup folder prints an error for every log line (regression of F-C1).'

    # and nothing else may redirect into the log directly, or it reopens the same hole
    $bad = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($cmd[$i] -match '(?i)>>\s*"%LOGFILE%"') {
            $inWriter = $false
            for ($j = $i; $j -ge 0; $j--) { if ($cmd[$j] -match '^:(\w+)') { $inWriter = ($Matches[1] -eq '_LogWrite'); break } }
            if (-not $inWriter) { $bad += ($i + 1) }
        }
    }
    Assert-True ($bad.Count -eq 0) ("Line(s) $($bad -join ', ') redirect into %LOGFILE% outside :_LogWrite - that write cannot be silenced and will spew when the folder is missing (regression of F-C1).")
}

# ===============================================================================
# 107. Debloat is the ONE action with no undo - the README says so, you reinstall
#      from the Store. It used to pipe Get-AppxPackage into Remove-AppxPackage with
#      -ErrorAction SilentlyContinue and then print an unconditional "[OK] ...
#      removed where present.", so a run that removed nothing - because it was not
#      elevated, or every removal threw - read exactly like a run that worked.
# ===============================================================================
Invoke-Test 'Debloat reports what it actually removed, and refuses when not elevated' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    # the whole debloat flow spans several labels; slice it by file position
    $mS = @($cmd | Select-String -Pattern '^:Debloat\b')
    $mE = @($cmd | Select-String -Pattern '^:StartupMgr\b')
    Assert-True ($mS.Count -gt 0 -and $mE.Count -gt 0) 'Debloat flow labels not found - the section was restructured.'
    $flow = @($cmd[($mS[0].LineNumber - 1)..($mE[0].LineNumber - 2)])
    $code = @($flow | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"

    Assert-True ($code -match '(?i)if "%_ELEV%"=="0"') 'Debloat has no elevation guard - Get-AppxPackage -AllUsers needs Administrator, so unelevated it finds nothing and every group reports "none installed", a false SKIP that reads like good news (regression of F-C2).'
    Assert-True ($code -notmatch '(?i)removed where present') 'Debloat prints its old unconditional "[OK] ... removed where present." line again - that is the false success this fix removed (regression of F-C2).'

    # both package groups must go through the counting helper
    $runs = ([regex]::Matches($code, '(?i)call :DebloatRun')).Count
    Assert-True ($runs -ge 2) "Only $runs debloat group(s) go through :DebloatRun - a group removing packages without counting them cannot report honestly (regression of F-C2)."

    $rb = ((Get-RoutineBody -Lines $cmd -Label 'DebloatRun') -join "`n")
    Assert-True ($rb.Length -gt 0) ':DebloatRun is missing.'
    foreach ($tag in '\[OK\]','\[SKIP\]','\[FAIL\]') {
        Assert-True ($rb -match "(?i)$tag") ":DebloatRun lost its $tag branch - removed / not-installed / failed must stay distinguishable (regression of F-C2)."
    }
    Assert-True ($rb -match '(?i)Remove-AppxPackage -ErrorAction Stop') ':DebloatRun swallows removal errors again (-ErrorAction Stop is what makes a failure countable) (regression of F-C2).'

    # OneDrive: the uninstaller is 32-bit on many machines and lives only in SysWOW64
    Assert-True ($code -match '(?i)SysWOW64\\OneDriveSetup\.exe') 'The OneDrive uninstall only looks in System32 - on a 64-bit Windows the shipped OneDriveSetup.exe is commonly the 32-bit one in SysWOW64, so it silently did nothing while printing [OK] (regression of F-C2).'
    Assert-True ($code -match '(?i)\[WARN\] OneDrive') 'The OneDrive path no longer warns when the uninstaller could not be found (regression of F-C2).'
}

# ===============================================================================
# 108. A failed elevation must say so. The relaunch used to be a bare Start-Process
#      with its output discarded, followed by an unconditional "exit /b" - so a
#      declined UAC prompt or a blocked PowerShell just closed the window after
#      printing "Requesting Administrator privileges...", which is indistinguishable
#      from the script crashing.
# ===============================================================================
Invoke-Test 'A failed self-elevation is reported, not a silently closing window' {
    $cmd = Read-Lines $CmdPath
    # window sized from the file, not a fixed 80 lines - the argument loop grew and pushed
    # the elevation block past a hardcoded bound, which read as "the relaunch is gone"
    $adminAt = ($cmd | Select-String -Pattern '^:AdminOK$' | Select-Object -First 1)
    Assert-True ($null -ne $adminAt) ':AdminOK is missing - the startup section was restructured.'
    $head = @($cmd[0..($adminAt.LineNumber - 1)]) -join "`n"

    Assert-True ($head -match '(?i)Start-Process') 'The self-elevation relaunch is gone.'
    Assert-True ($head -match '(?i)-Verb RunAs')   'The relaunch no longer requests elevation.'
    Assert-True ($head -match '(?i)-ErrorAction Stop') 'Start-Process no longer uses -ErrorAction Stop, so a declined UAC prompt does not surface as a nonzero exit code (regression of F-C3).'
    Assert-True ($head -match '(?i)catch\{ exit 1 \}') 'The relaunch no longer converts a failure into an exit code (regression of F-C3).'
    Assert-True ($head -match '(?i)if not errorlevel 1 exit /b') 'The script exits unconditionally after attempting elevation, so the failure path is unreachable and stays silent (regression of F-C3).'
    Assert-True ($head -match '(?i)\[WARN\] The elevation prompt did not go through') 'A failed elevation no longer tells the user why the window is about to change behaviour (regression of F-C3).'
    Assert-True ($head -match '(?i)goto AdminWarn') 'A failed elevation no longer offers the limited-mode path that :AdminWarn already implements (regression of F-C3).'
}

# ===============================================================================
# 109. Resetting Windows Update renames SoftwareDistribution and catroot2 rather
#      than deleting them, which is correct - it keeps a rollback. What was wrong
#      is that nothing ever removed or even mentioned them, and SoftwareDistribution
#      is routinely 1-5 GB, so repeated resets quietly ate tens of GB inside
#      %SystemRoot%. Pruning is opt-in, runs BEFORE the rename so the newest
#      rollback always survives, and must never be able to match a LIVE folder.
# ===============================================================================
Invoke-Test 'Windows Update reset prunes only OLD leftovers, opt-in, never the live folders' {
    $cmd = Read-Lines $CmdPath

    $wr = Get-RoutineBody -Lines $cmd -Label 'WUReset'
    $wr = @($wr)
    Assert-True ($wr.Count -gt 0) ':WUReset is missing.'
    $iPrune = ($wr | Select-String -SimpleMatch 'call :WUPruneOld' | Select-Object -First 1)
    $iRen   = ($wr | Select-String -SimpleMatch 'SoftwareDistribution.bak_' | Select-Object -First 1)
    Assert-True ($null -ne $iPrune) ':WUReset never offers to clear earlier leftovers - each run adds another 1-5 GB folder that nothing removes (regression of F-D1).'
    Assert-True ($null -ne $iRen)   ':WUReset no longer renames SoftwareDistribution (regression).'
    Assert-True ($iPrune.LineNumber -lt $iRen.LineNumber) ':WUReset prunes AFTER creating this run''s rollback copy, so it would delete the very backup it just made (regression of F-D1).'

    $po = ((Get-RoutineBody -Lines $cmd -Label 'WUPruneOld') -join "`n")
    Assert-True ($po.Length -gt 0) ':WUPruneOld is missing.'
    Assert-True ($po -match '(?i)set /p') 'Leftover deletion is no longer opt-in - it must ask before removing anything (regression of F-D1).'

    # the safety property: every folder filter must be anchored on the ".bak_" suffix this
    # script itself creates, or a prune could match the LIVE SoftwareDistribution / catroot2
    $pw = ((Get-RoutineBody -Lines $cmd -Label 'WUPruneWorker') -join "`n")
    Assert-True ($pw.Length -gt 0) ':WUPruneWorker is missing.'
    $filters = @([regex]::Matches($pw, "(?i)-Filter\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($filters.Count -ge 2) "Expected at least two folder filters in :WUPruneWorker; found $($filters.Count)."
    foreach ($f in $filters) {
        Assert-True ($f -like '*.bak_*') "Folder filter '$f' is not anchored on the '.bak_' suffix sincript creates - it could match the LIVE SoftwareDistribution or catroot2 and delete a working component store (regression of F-D1)."
    }
    Assert-True ($pw -match '(?i)if\(\$del\)') ':WUPruneWorker no longer gates removal on delete mode - the counting pass would delete (regression of F-D1).'
    Assert-True ($pw -match '(?i)Remove-Item -LiteralPath') ':WUPruneWorker no longer removes by literal path - a wildcard removal here targets %SystemRoot% (regression of F-D1).'
}

# ===============================================================================
# 110. Two hygiene invariants, both derived rather than restated so they cannot
#      rot: every temp file a worker writes carries %RANDOM%, and every PT_*
#      variable handed to a PowerShell child is cleared again afterwards. Fixed
#      names meant two sincript windows read each other's results - and the first
#      to finish deleted the file the second was about to read. TEMP is matched
#      as %TEMP% and as !TEMP!: the late-read form is what the script uses now.
# ===============================================================================
Invoke-Test 'Worker temp files are per-call, and every PT_* handoff variable is cleared' {
    $cmd = Read-Lines $CmdPath

    $fixed = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        foreach ($m in [regex]::Matches($cmd[$i], "(?i)(?:[%!]TEMP[%!]\\|\`$env:TEMP\s+')pt_[a-z0-9_]+\.txt")) {
            if ($m.Value -notmatch '%RANDOM%') { $fixed += ("line {0}: {1}" -f ($i + 1), $m.Value) }
        }
    }
    Assert-True ($fixed.Count -eq 0) ("Fixed-name worker temp file(s): {0}. Two sincript windows would share them, and whichever finishes first deletes the file the other is about to read (regression of F-D2)." -f ($fixed -join '; '))

    $assigned = @{}; $cleared = @{}
    foreach ($l in $cmd) {
        foreach ($m in [regex]::Matches($l, 'set "(PT_[A-Za-z0-9_]+)=([^"]*)"')) {
            if ($m.Groups[2].Value -eq '') { $cleared[$m.Groups[1].Value] = $true }
            else { $assigned[$m.Groups[1].Value] = $true }
        }
    }
    Assert-True ($assigned.Count -gt 20) "Only $($assigned.Count) PT_* handoff variables found - the worker convention changed."
    $leaked = @($assigned.Keys | Where-Object { -not $cleared.ContainsKey($_) } | Sort-Object)
    Assert-True ($leaked.Count -eq 0) ("PT_* variable(s) set but never cleared: {0}. They stay in the environment for the rest of the session and are inherited by every child process sincript spawns (regression of F-D3)." -f ($leaked -join ', '))
}

# ===============================================================================
# 111. A machine can have two GPU vendors, and many do - an AMD APU with an NVIDIA
#      discrete card is an ordinary gaming laptop. Detection used to run two
#      unconditional probes writing the SAME variable, so the second one won and
#      such a machine always came out "amd": the Advanced menu offered the AMD
#      opt-out and the NVIDIA telemetry TASKS - the ones that actually run there -
#      were skipped entirely. Both vendors are now tracked separately.
# ===============================================================================
Invoke-Test 'GPU detection tracks both vendors independently, so a hybrid machine gets both' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    Assert-True ($all -match '(?i)set "GPU_NV=1"')  'NVIDIA is no longer tracked in its own flag - a second probe would overwrite it (regression of F-E1).'
    Assert-True ($all -match '(?i)set "GPU_AMD=1"') 'AMD is no longer tracked in its own flag (regression of F-E1).'
    Assert-True ($all -match '(?i)set "GPU=nvidia\+amd"') 'The both-vendors case no longer has its own label for the menu header (regression of F-E1).'
    # each vendor word must be written CONDITIONALLY, or "unknown" is clobbered on a machine
    # with neither and the header reports a GPU that is not there
    Assert-True ($all -match '(?i)if defined GPU_NV set "GPU=nvidia"')  'GPU=nvidia is assigned unconditionally, so a machine with no NVIDIA adapter still reports one (regression of F-E1).'
    Assert-True ($all -match '(?i)if defined GPU_AMD set "GPU=amd"')    'GPU=amd is assigned unconditionally (regression of F-E1).'

    # the recursive class-key query is the slowest probe at startup; it must run once
    $probes = ([regex]::Matches($all, '(?i)reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\\{4d36e968')).Count
    Assert-True ($probes -eq 1) "The display-class registry tree is queried $probes times at startup; it should be read once into a file and scanned twice (regression of F-E1)."

    # both the menu and the preset path must branch on the flags, not the single word
    foreach ($r in 'GpuTelemetry','DoGpuTelemetryOff') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r)
        $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
        Assert-True ($code -match '(?i)defined GPU_(NV|AMD)') ":$r still branches on %GPU% alone, so a machine with both vendors only gets whichever probe wrote it last (regression of F-E1)."
        Assert-True ($code -notmatch '(?i)"%GPU%"=="nvidia"') ":$r still compares %GPU% to a single vendor - that is the test that fails on a hybrid machine (regression of F-E1)."
    }
    # and declining NVIDIA must not skip the AMD half
    $nv = ((Get-RoutineBody -Lines $cmd -Label 'GpuNvidia') -join "`n")
    Assert-True ($nv -match '(?i)goto GpuAmd') ':GpuNvidia never continues to the AMD opt-out, so on a hybrid machine one screen silently swallows the other (regression of F-E1).'
    # ...and DECLINING NVIDIA must reach that continuation too, not jump straight to the menu -
    # otherwise one "no" throws away an unrelated vendor's opt-out
    Assert-True ($nv -notmatch '(?i)if /i not "[%!]_c[%!]"=="Y" goto MenuAdvanced') ':GpuNvidia sends a declined NVIDIA prompt straight back to the menu, so on a hybrid machine it skips the AMD opt-out entirely (regression of F-E1).'
    Assert-True ($nv -match '(?i)if /i not "!_c!"=="Y" goto _gpuNvDone') ':GpuNvidia no longer routes a declined prompt through the shared continuation point (regression of F-E1).'
}

# ===============================================================================
# 112. Two input-robustness invariants. The preset file is the only untrusted
#      input this script parses, and its validator was the last place that
#      percent-expanded user text inside ( ) blocks - cmd resolves that at PARSE
#      time, so an unpaired " in a key or value aborted the whole run with "was
#      unexpected at this time" (verified against the old shape: exit code 255,
#      before it printed anything). And set /a saturates above 2^31, which made
#      any two large DWORDs compare equal.
# ===============================================================================
Invoke-Test 'Untrusted preset text and large DWORDs never reach parse-time expansion' {
    $cmd = Read-Lines $CmdPath

    $b = @(Get-BodyLines -Lines $cmd -Label 'PresetCheckLine')
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($b.Count -gt 5) ':PresetCheckLine body did not unroll - use the two-step Get-RoutineBody idiom.'
    Assert-True ($code.Length -gt 0) ':PresetCheckLine body empty.'
    Assert-True ($code -notmatch '%_k%') ':PresetCheckLine percent-expands the preset KEY again - inside an ( ) block cmd resolves that before the block structure is known, so an unpaired " aborts the run (regression of F-E2).'
    Assert-True ($code -notmatch '%_v%') ':PresetCheckLine percent-expands the preset VALUE again (regression of F-E2).'
    Assert-True ($code -match '(?i)"!_k!"==') ':PresetCheckLine no longer compares the key with delayed expansion (regression of F-E2).'

    # the value must not travel as a call argument either - that is parse-time expansion
    # one level down, and it is how an embedded " unbalanced the call itself
    $callsites = @($cmd | Select-String -Pattern '(?i)call :PresetCheckLine')
    Assert-True ($callsites.Count -ge 1) 'Nothing calls :PresetCheckLine.'
    foreach ($c in $callsites) {
        Assert-True ($c.Line -notmatch '(?i)call :PresetCheckLine\s+\S') ':PresetCheckLine is called with arguments again - the key/value must be assigned from the for-variables, which are substituted after parsing (regression of F-E2).'
    }
    foreach ($h in 'PVok','PChkWin32','PChkPlan','PChkDns') {
        $hc = (Get-BodyLines -Lines $cmd -Label $h -CodeOnly) -join "`n"
        Assert-True ($hc -match '!_v!') ":$h no longer reads the value with delayed expansion from the caller's scope (regression of F-E2)."
        # and the percent form must be GONE - asserting only that !_v! appears somewhere is
        # satisfied by the error-message line while the comparison silently reverts
        Assert-True ($hc -notmatch '%_v%') ":$h percent-expands the preset value again; cmd resolves that at parse time, before it knows where a ( ) block ends (regression of F-E2)."
    }

    # set /a is 32-bit signed and SATURATES when it dereferences an out-of-range variable,
    # so without this guard any two values >= 2^31 compare equal and a real difference
    # would be skipped as "already set"
    $idem = ((Get-RoutineBody -Lines $cmd -Label 'SafeRegAdd') -join "`n")
    Assert-True ($idem -match '(?i)"!_curdec!"=="2147483647"') 'The DWORD idempotence check no longer detects set /a saturation, so two different values at or above 2^31 compare equal and the write is silently skipped (regression of F-E3).'
    Assert-True ($idem -match '(?i)if /i not "!_curtok!"=="!_data!" goto _sraDoWrite') 'The saturation fallback no longer compares the raw tokens as text (regression of F-E3).'
    # ...which only works if large values are written as hex, matching what reg query returns
    $all = $cmd -join "`n"
    Assert-True ($all -notmatch '(?i)REG_DWORD 4294967295') 'A large DWORD is written as decimal again; reg query returns hex, so the saturation fallback cannot match it and the value is re-written every run (regression of F-E3).'
}

# ===============================================================================
# 113. Every menu prompt that re-asks itself needs a way out. set /p cannot tell an
#      exhausted stdin from a bare Enter - both leave the variable unset and both
#      return errorlevel 1 - so "if not defined sel goto MenuX_ask" had no exit at
#      all once stdin was redirected or closed, and spun at 100% CPU forever.
#      Verified: the real script under "< nul" now exits in ~5s instead of hanging.
# ===============================================================================
Invoke-Test 'Every self-repeating prompt can give up when stdin is exhausted' {
    $cmd = Read-Lines $CmdPath

    $niAll = @(Get-BodyLines -Lines $cmd -Label 'NoInput')
    Assert-True ($niAll.Count -gt 5) ':NoInput body did not unroll - two-step Get-RoutineBody.'
    # rem-stripped: the routine's comment QUOTES the broken loop shape it exists to fix, and
    # the negative assertion below would match that prose rather than any real code.
    $ni = @($niAll | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($ni.Length -gt 0) ':NoInput is missing - nothing bounds the menu prompt loops (regression of F-F1).'
    Assert-True ($ni -match '(?i)set /a _NOIN\+=1') ':NoInput no longer counts consecutive empty reads (regression of F-F1).'
    Assert-True ($ni -match '(?i)exit /b 1') ':NoInput never reports "give up", so the loops it guards can still spin forever (regression of F-F1).'
    Assert-True ($ni -match '(?i)exit /b 0') ':NoInput no longer reports "ask again" (regression of F-F1).'
    # the limit must actually be REACHABLE - an "exit /b 1" behind a threshold nothing can
    # hit is the same unbounded loop with extra steps
    $lim = [regex]::Match($ni, '(?i)if !_NOIN! lss (\d+) exit /b 0')
    Assert-True ($lim.Success) ':NoInput no longer bounds the retry count with a literal limit (regression of F-F1).'
    $n = [int]$lim.Groups[1].Value
    Assert-True ($n -ge 10 -and $n -le 1000) ":NoInput's give-up threshold is $n - outside 10..1000 it is either hair-trigger for a person pressing Enter, or so high that an exhausted stdin still spins effectively forever (regression of F-F1)."
    # it is CALLED, so it must return rather than jump - see test 105
    Assert-True ($ni -notmatch '(?i)(?<![:\w])goto\s+:?(MainMenu|Menu\w+|ExitScript)\b') ':NoInput jumps to a menu instead of returning a status, unbalancing the call stack (regression of F-B1).'

    # the counter has to be cleared somewhere reachable, or one stray Enter per screen
    # eventually accumulates to the limit over a long session
    $logo = ((Get-RoutineBody -Lines $cmd -Label 'Logo') -join "`n")
    Assert-True ($logo -match '(?i)set "_NOIN=0"') ':Logo no longer clears the empty-read counter, so it accumulates across unrelated screens (regression of F-F1).'

    # EVERY prompt that loops back to its own label must consult the guard first
    $unguarded = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($cmd[$i] -notmatch '^\s*if not defined (\w+) goto (\w+)\s*$') { continue }
        $var = $Matches[1]; $tgt = $Matches[2]
        $lbl = @($cmd | Select-String -Pattern ("^:" + [regex]::Escape($tgt) + "$") | Select-Object -First 1)
        if ($lbl.Count -eq 0 -or $lbl[0].LineNumber -gt ($i + 1)) { continue }   # forward jump = not a loop
        # What matters is that the CYCLE is bounded, not that every line carries a guard.
        # Walking from the target label down to this jump, the path must pass through either
        # :NoInput (a guarded prompt) or :Logo (a screen redraw, which re-enters a guarded
        # prompt and resets the counter). A secondary "that number is not in the list" check
        # loops back to its own already-guarded prompt, so its cycle is bounded too.
        $seg = $cmd[($lbl[0].LineNumber - 1)..$i] -join "`n"
        if ($seg -match '(?i)call :(Logo|NoInput)\b') { continue }
        $unguarded += ("line {0}: if not defined {1} goto {2}" -f ($i+1), $var, $tgt)
    }
    Assert-True ($unguarded.Count -eq 0) ("Self-repeating prompt(s) with no way out when stdin is empty - these spin at 100% CPU forever under redirected or closed stdin: {0} (regression of F-F1)." -f ($unguarded -join '; '))

    # and the courtesy pause must not announce its own failure on a non-interactive exit
    $bad = @($cmd | Select-String -Pattern '(?i)timeout /t \d+ >nul\s*$')
    Assert-True ($bad.Count -eq 0) ("timeout call(s) suppress stdout but not stderr, so a redirected stdin prints 'Input redirection is not supported' as the last line of an otherwise clean exit: line(s) $(($bad | ForEach-Object { $_.LineNumber }) -join ', ') (regression of F-F1).")
}

# ===============================================================================
# 114. The /preset: command line must apply EXACTLY what the menu applies, and it
#      must warn about the one change that can take a machine down. The preset
#      bodies are shared routines for the first reason; :LaptopAdvisory and the
#      /plan: option exist for the second - unattended there is no prompt to
#      reconsider at, and Ultimate Performance on an undervolted laptop is a real
#      bugcheck 0x124, not a theoretical caveat.
# ===============================================================================
Invoke-Test 'The /preset: command line shares the menu bodies and warns before the power plan' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    # ---- one definition of each preset, used by both paths ----
    foreach ($b in 'PresetBodyLight','PresetBodyModerate','PresetBodyHeavy') {
        $body = ((Get-RoutineBody -Lines $cmd -Label $b) -join "`n")
        Assert-True ($body.Length -gt 0) ":$b is missing - the menu and the command line would each need their own copy of the tweak list (regression of F-H1)."
        $n = ([regex]::Matches($body, '(?i)call :Do\w+')).Count
        Assert-True ($n -ge 3) ":$b calls only $n Do* routines - it looks emptied out (regression of F-H1)."
    }
    foreach ($p in 'PresetLight','PresetModerate','PresetHeavy') {
        $menu = ((Get-RoutineBody -Lines $cmd -Label $p) -join "`n")
        $expected = 'call :PresetBody' + $p.Substring(6)
        Assert-True ($menu -match ('(?i)' + [regex]::Escape($expected))) ":$p no longer calls $expected - the menu has its own copy of the list again and the two paths will drift (regression of F-H1)."
    }
    $cliBody = ((Get-RoutineBody -Lines $cmd -Label 'CliRun') -join "`n")
    Assert-True ($cliBody.Length -gt 0) ':CliRun is missing.'
    foreach ($b in 'PresetBodyLight','PresetBodyModerate','PresetBodyHeavy','PresetApplyDirectives') {
        Assert-True ($cliBody -match ('(?i)call :' + $b + '\b')) ":CliRun does not go through :$b - the command line would apply a different set than the menu (regression of F-H1)."
    }

    # ---- the safety half ----
    $cliCode = @((Get-RoutineBody -Lines $cmd -Label 'CliRun') | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($cliCode -match '(?i)call :LaptopAdvisory') ':CliRun never shows the laptop advisory. Unattended there is no prompt to reconsider at, so this line is the only warning that a portable machine is about to be pinned at sustained max clocks (regression of F-H2).'
    Assert-True ($cliCode -match '(?i)/plan:') ':CliRun lost the /plan: option, so an unattended run cannot choose anything but the hidden Ultimate default (regression of F-H2).'
    Assert-True ($all -match '(?i)set "_CLIPLAN=!_a:~6!"') 'The argument loop no longer parses /plan: (regression of F-H2).'
    # /plan: must be applied AFTER :PresetBegin, which deliberately clears _PWPLAN
    $iBegin = ($cliBody -split "`n" | Select-String -SimpleMatch 'call :PresetBegin' | Select-Object -First 1)
    $iPlan  = ($cliBody -split "`n" | Select-String -SimpleMatch 'set "_PWPLAN=!_CLIPLAN!"' | Select-Object -First 1)
    Assert-True ($null -ne $iBegin -and $null -ne $iPlan) ':CliRun no longer wires /plan: into _PWPLAN (regression of F-H2).'
    Assert-True ($iPlan.LineNumber -gt $iBegin.LineNumber) ':CliRun sets _PWPLAN before :PresetBegin, which clears it - the /plan: choice would be silently discarded and the run would fall back to Ultimate (regression of F-H2).'
    Assert-True ($cliCode -match '(?i)set "_P_PWPLAN=!_CLIPLAN!"') ':CliRun does not override a custom preset''s power_plan= with /plan: - the more specific instruction must win (regression of F-H2).'

    # ---- validation before side effects ----
    $iRp = ($cliBody -split "`n" | Select-String -SimpleMatch 'call :CreateRestorePoint' | Select-Object -First 1)
    Assert-True ($null -ne $iRp) ':CliRun no longer offers a restore point.'
    foreach ($guard in 'exit /b 3','No such preset') {
        $g = ($cliBody -split "`n" | Select-String -SimpleMatch $guard | Select-Object -First 1)
        Assert-True ($null -ne $g -and $g.LineNumber -lt $iRp.LineNumber) "':CliRun' does its '$guard' check after creating a System Restore Point - a run that was always going to abort must not change anything first (regression of F-H3)."
    }
    # a preset name becomes a path, so it must be constrained to a bare file name
    # A whitelist, and not through a pipe. The first version blacklisted path separators and
    # wildcards but not "&", and the piped child re-parsed the name and ran the remainder.
    Assert-True ($cliCode -match '(?i)for /f "eol=[A-Za-z0-9_.\-] delims=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_\.-" %%X in \("!_CLIPRESET!"\)') ':CliRun no longer holds the preset name to a whitelist without a pipe, or lost the eol= that closes the ";" hole - so /preset:..\..\x, a name containing "&", or anything after a ";" gets through (regression of F-H3).'
    Assert-True ($cliCode -notmatch '(?i)echo\(?!_CLIPRESET!\s*\|') ':CliRun pipes the preset name into findstr again - the piped child re-parses it and an "&" in the name executes (regression of F-J1).'
    # and the name must never reach :Summary, whose "echo [OK] %~1" re-parses its argument
    Assert-True ($cliCode -notmatch '(?i)call :Summary "Preset !_CLIPRESET!') ':CliRun passes the preset name to :Summary again - it ends in "echo [OK] %~1", and %~1 is substituted during parsing, so an "&" in the text splits the line (regression of F-J2).'
    Assert-True ($cliCode -match '(?i)_CLIPRESET:\.\.=') ':CliRun no longer rejects ".." in a preset name (regression of F-H3).'

    # ---- an option that parses to nothing must not fall through to the menu ----
    # "/preset:" with no name, or a typo like /bogus, used to leave every _CLI* variable
    # empty, and the script then quietly opened the interactive menu. For an unattended
    # caller that is the worst outcome available: it neither works nor reports a problem,
    # it just sits at a prompt until something kills it.
    $argStart = ($cmd | Select-String -Pattern '^:_argLoop$' | Select-Object -First 1)
    $argEnd   = ($cmd | Select-String -Pattern '^:_argDone$' | Select-Object -First 1)
    Assert-True ($null -ne $argStart -and $null -ne $argEnd) 'The argument loop is missing.'
    $argBody = @($cmd[($argStart.LineNumber - 1)..($argEnd.LineNumber - 2)])
    $iElev = ($argBody | Select-String -SimpleMatch '"/elevated"' | Select-Object -First 1)
    $iAny  = ($argBody | Select-String -SimpleMatch 'set "_CLIANY=1"' | Select-Object -First 1)
    Assert-True ($null -ne $iAny) 'The argument loop no longer records that a command-line option was seen, so an option that parses to nothing opens the interactive menu instead of failing (regression of F-H5).'
    Assert-True ($null -ne $iElev -and $iAny.LineNumber -gt $iElev.LineNumber) '/elevated is counted as a command-line request - it is the interactive relaunch marker, so it must not put the script into command-line mode (regression of F-H5).'
    Assert-True ($all -match '(?i)if defined _CLIANY goto CliRun') 'The startup dispatches on _CLIPRESET rather than "any option given", so a typo or an empty value silently opens the menu (regression of F-H5).'
    foreach ($v in '_CLIPRESET','_CLIDNS','_CLIPLAN') {
        Assert-True (($argBody -join "`n") -match ('(?i)if not defined ' + $v + ' set "_CLIBAD=!_a!"')) "An empty value for the option behind $v is accepted silently instead of being reported as bad usage (regression of F-H5)."
    }
    Assert-True ($cliCode -match '(?i)if not defined _CLIPRESET \(') ':CliRun does not refuse a command line with no /preset: - options like /norestore alone have nothing to apply (regression of F-H5).'

    # ---- a path from the user's Documents folder can contain & or ) ----
    Assert-True ($all -notmatch '(?i)Registry backup: %PRESET_LAST%') 'The "Registry backup:" line percent-expands PRESET_LAST - it is built from the Documents folder, so "C:\Users\Bob & Alice\..." would be re-parsed as a command separator (regression of F-H4).'
}

# ===============================================================================
# 115. The backup-folder size total divided each file by 1 MB and added THAT, so
#      integer division discarded the remainder per file: every export under a
#      megabyte counted as zero, and ten 900 KB exports totalled "0 MB" on a line
#      that also said there were ten of them. Sum KB, convert once at the end.
# ===============================================================================
Invoke-Test 'Backup size total sums kilobytes, so sub-megabyte exports are not lost' {
    $cmd = Read-Lines $CmdPath

    # no @() on the first line - Get-RoutineBody returns `,$array` and wrapping it there
    # keeps the whole body as ONE element, which makes every assertion below vacuous
    $add = @(Get-BodyLines -Lines $cmd -Label '_mbAddFull')
    Assert-True ($add.Count -gt 3) ':_mbAddFull body did not unroll.'
    $code = @($add | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"

    Assert-True ($code -notmatch '1048576') ':_mbAddFull divides each file by 1 MB again - integer division drops the remainder per file, so anything under a megabyte counts as zero (regression of F-I1).'
    Assert-True ($code -match '(?i)_kbFull\+=') ':_mbAddFull no longer accumulates kilobytes (regression of F-I1).'
    # the size must go through a variable: set /a saturates an out-of-range VARIABLE at
    # INT_MAX but ERRORS on an out-of-range literal, and an error drops the file entirely
    Assert-True ($code -match '(?i)set "_fsz=%~1"') ':_mbAddFull no longer stages the byte count in a variable - an oversized file would error out of set /a and vanish from the total rather than being capped (regression of F-I1).'
    Assert-True ($code -notmatch '(?i)\+=%~1') ':_mbAddFull puts the raw argument straight into the set /a expression again (regression of F-I1).'

    # and the caller converts once, keeping a tenth so a small folder does not read "0 MB"
    $all = $cmd -join "`n"
    Assert-True ($all -match '(?i)set /a _mbW=_kbFull/1024') 'The KB total is no longer converted to whole MB by the caller (regression of F-I1).'
    Assert-True ($all -match '(?i)set /a _mbF=\(_kbFull\*10/1024\)%%10') 'The MB total lost its tenths, so a few hundred KB of exports reads as a flat "0 MB" beside a nonzero count (regression of F-I1).'
    Assert-True ($all -match '(?i)set "_mbFull=!_mbW!\.!_mbF!"') 'The displayed MB total is no longer assembled from the whole and fractional parts (regression of F-I1).'
}

# ===============================================================================
# 116. No value may be VALIDATED by piping it into findstr. cmd runs each side of a
#      pipe in a child process and builds that child's command line from the
#      already-expanded text - which is then parsed again, operators and all. So
#          echo(!v!| findstr ...
#      with v = "1.1.1.1&some-command" ran some-command and handed findstr a clean
#      "1.1.1.1", answering "valid". Three routines did this, including :_ip4_ok,
#      whose comment claimed no metacharacter could survive it. The value never
#      reached findstr at all. Use "for /f delims=" (no child) or a file.
# ===============================================================================
Invoke-Test 'No validator pipes a variable into findstr - the piped child re-parses it' {
    $cmd = Read-Lines $CmdPath

    $piped = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $ln = $cmd[$i]
        if ($ln.Trim() -match '^(?i)rem\b') { continue }
        # echo of a delayed-expanded variable feeding a pipe
        if ($ln -match '(?i)echo\(?\s*![A-Za-z0-9_]+!\s*\|') { $piped += ("line {0}: {1}" -f ($i+1), $ln.Trim()) }
    }
    Assert-True ($piped.Count -eq 0) ("Value(s) piped into a command for validation - the piped child re-parses the expanded text, so a '&' in the value executes and the checker judges the wrong string: {0}. Use `"for /f delims=`" or redirect through a file (regression of F-J1)." -f ($piped -join '; '))

    # the three that had it must each still validate, by the safe route
    $ip4 = ((Get-RoutineBody -Lines $cmd -Label '_ip4_ok') -join "`n")
    Assert-True ($ip4 -match '(?i)for /f "eol=[0-9] delims=0123456789\."') ':_ip4_ok lost its pipe-free charset check, or the eol= that closes the ";" hole (regression of F-J1).'
    $na = ((Get-RoutineBody -Lines $cmd -Label 'NonAsciiCheck') -join "`n")
    Assert-True ($na.Length -gt 0) ':NonAsciiCheck is missing - the non-ASCII test went back inline through a pipe (regression of F-J1).'
    # Pipe-free AND actually able to fire. `findstr /r "[^ -~]"` never flagged anything (without
    # /c: the space splits the pattern in two), adding /c: hangs, and findstr ranges follow
    # collation order rather than character codes - [^!-~] flags plain ASCII. So: pure batch,
    # a for /f over a printable-ASCII delimiter whitelist, with an eol that is itself allowed.
    Assert-True ($na -match '(?i)for /f "eol=[^"]*delims=[^"]*" %%c in \("!_rd!"\)') ':NonAsciiCheck no longer scans the value with a pipe-free for /f whitelist (regression of F-J1).'
    # Against CODE only: the routine's own comment explains why findstr is not used, and
    # that prose would otherwise decide this assertion. -CodeOnly is the helper that
    # unrolls properly; @(Get-RoutineBody ...) would make the whole routine one element.
    $naCode = (Get-BodyLines -Lines $cmd -Label 'NonAsciiCheck' -CodeOnly) -join "`n"
    Assert-True ($naCode.Length -gt 0) ':NonAsciiCheck has no code lines - only comments?'
    Assert-True ($naCode -notmatch '(?i)findstr') ':NonAsciiCheck went back to findstr - collation-order ranges mean it either never fires or flags plain ASCII (regression).'
    Assert-True ($na -notmatch '(?i)echo\(!_rd!\s*\|') ':NonAsciiCheck pipes the value into a child again - the child re-parses it (regression of F-J1).'
    $all = $cmd -join "`n"
    Assert-True ($all -match '(?i)for /f "eol=[0-9] delims=0123456789" %%X in \("!_in!"\)') 'The Unity job-worker prompt pipes typed input into findstr again, or lost its eol= (regression of F-J1).'
}

# ===============================================================================
# 117. The startup manager addresses entries by NUMBER, and the toggle pass
#      re-enumerates from scratch. If anything added or removed a Run entry
#      between drawing the list and confirming the flip, number N pointed at a
#      different entry than the confirm prompt had just named - and the wrong
#      program got disabled. Only the bounds were checked, which catches a list
#      that got shorter and nothing else. The list pass now fingerprints the whole
#      enumeration and the toggle pass refuses on a mismatch.
# ===============================================================================
Invoke-Test 'Flipping a startup entry refuses if the list changed since it was shown' {
    $cmd = Read-Lines $CmdPath

    $w = @(Get-BodyLines -Lines $cmd -Label 'StartupWorker')
    Assert-True ($w.Count -gt 3) ':StartupWorker body did not unroll.'
    $code = @($w | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"

    Assert-True ($code -match '(?i)\$sg=\[BitConverter\]::ToString') ':StartupWorker no longer fingerprints the enumeration, so a list that changed between display and flip is undetectable (regression of F-K1).'
    Assert-True ($code -match '(?i)\$sg \| Out-File -FilePath \$env:PT_SU_SIG') 'The list pass no longer publishes the fingerprint (regression of F-K1).'
    Assert-True ($code -match '(?i)if\(\$env:PT_SU_SIGIN -and \$env:PT_SU_SIGIN -ne \$sg\)') 'The toggle pass no longer compares the fingerprint it was given (regression of F-K1).'
    # the refusal must happen BEFORE anything is written
    $iCheck = ($code -split "`n" | Select-String -SimpleMatch 'PT_SU_SIGIN -ne $sg' | Select-Object -First 1)
    $iWrite = ($code -split "`n" | Select-String -SimpleMatch 'Registry]::SetValue' | Select-Object -First 1)
    Assert-True ($null -ne $iCheck -and $null -ne $iWrite) ':StartupWorker lost either the staleness check or the write.'
    Assert-True ($iCheck.LineNumber -le $iWrite.LineNumber) ':StartupWorker checks the fingerprint after writing the new state (regression of F-K1).'
    # the fingerprint is derived from source+name, never the raw name through cmd
    # literal match, escaped - hand-writing this as a regex invites getting the backslash
    # count wrong, which reads as a real failure
    $sigExpr = [regex]::Escape('$_[0]+''\''+$_[2]')
    Assert-True ($code -match $sigExpr) 'The fingerprint no longer covers both the source and the entry name, so an entry renamed between two sources would slip through (regression of F-K1).'

    # caller side: capture the fingerprint, hand it back, and clear the handoff vars
    $mgr = ((Get-RoutineBody -Lines $cmd -Label 'StartupMgr') -join "`n")
    Assert-True ($mgr -match '(?i)for /f "usebackq delims=" %%S in \("!_susigf!"\) do set "_susigv=%%S"') ':StartupMgr no longer reads the fingerprint the list pass produced (regression of F-K1).'
    $all = $cmd -join "`n"
    Assert-True ($all -match '(?i)set "PT_SU_SIGIN=%_susigv%"') 'The fingerprint is never handed back to the toggle pass, so the check can never fire (regression of F-K1).'
    # a null -FilePath makes Out-File PROMPT for it, in a minimized window nobody can answer
    $wCode = ((Get-RoutineBody -Lines $cmd -Label 'StartupWorker') -join "`n")
    Assert-True ($wCode -match '(?i)if\(\$env:PT_SU_SIG\)\{ \$sg \| Out-File') 'The fingerprint write is no longer guarded on the path being set - Out-File prompts for a null -FilePath, and the whole screen then waits for input that cannot arrive (regression of F-K2).'
    Assert-True ($all -match '(?i)set "PT_SU_SIG=" & set "PT_SU_SIGIN="') 'The startup fingerprint handoff variables are no longer cleared (regression of F-D3).'
}

# ===============================================================================
# 118. No two batch variables may differ only by CASE. cmd variable names are
#      case-insensitive, so `_susigf` and `_SUSIGF` are one variable - a pair that
#      reads like "the path" and "the value" is actually one slot, and setting
#      either clears the other. It cost a screen that rendered nothing until a key
#      was pressed: the blanked path reached PowerShell as a null -FilePath, which
#      makes Out-File PROMPT for it, in a minimized window nobody can answer.
# ===============================================================================
Invoke-Test 'No two batch variables differ only by case (cmd names are case-insensitive)' {
    $cmd = Read-Lines $CmdPath
    $names = @{}
    foreach ($ln in $cmd) {
        if ($ln.Trim() -match '^(?i)rem\b') { continue }
        foreach ($m in [regex]::Matches($ln, '(?i)\bset\s+"([A-Za-z_][A-Za-z0-9_]*)=')) {
            $n = $m.Groups[1].Value
            $k = $n.ToLowerInvariant()
            if (-not $names.ContainsKey($k)) { $names[$k] = New-Object 'System.Collections.Generic.HashSet[string]' }
            [void]$names[$k].Add($n)
        }
    }
    Assert-True ($names.Count -gt 50) "Found only $($names.Count) assigned variables - the scan is not matching."
    $clash = @($names.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } |
                ForEach-Object { "{0} ({1})" -f $_.Key, (($_.Value | Sort-Object) -join ' / ') })
    Assert-True ($clash.Count -eq 0) ("Variable name(s) that differ only by case, and are therefore THE SAME variable: {0}. Assigning one silently clears the other (regression of F-K2)." -f ($clash -join '; '))
}

# ===============================================================================
# 119. Two screens that were asking the user to choose blind: the HAGS toggle
#      offered on/off without saying which it already was, and Status carried a
#      shorter machine header than the main menu, so the two disagreed about what
#      had been probed.
# ===============================================================================
Invoke-Test 'The HAGS screen states the stored value, and Status carries the main-menu header' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    $h = @(Get-BodyLines -Lines $cmd -Label 'HagsToggle')
    Assert-True ($h.Count -gt 5) ':HagsToggle body did not unroll.'
    $hj = $h -join "`n"
    Assert-True ($hj -match '(?i)reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers" /v HwSchMode') ':HagsToggle no longer reads the current HwSchMode, so the screen asks the user to choose blind (regression of F-L1).'
    foreach ($v in '0x1','0x2') {
        Assert-True ($hj -match ('(?i)"!_hags!"=="' + $v + '"')) ":HagsToggle lost the $v branch of its current-state line (regression of F-L1)."
    }
    Assert-True ($hj -match '(?i)if not defined _hags') ':HagsToggle does not handle an absent HwSchMode, which is the Windows default rather than an error (regression of F-L1).'
    # no PowerShell here - this screen should draw instantly. Comment-stripped, because the
    # routine's own comment says "no PowerShell" and would satisfy a raw -notmatch (trap 3b).
    $hCode = @($h | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($hCode -notmatch '(?i)powershell') ':HagsToggle spawns PowerShell to read one DWORD (regression of F-L1).'

    # the two headers must agree; both are built from the same probes
    $hdr = '(?i)echo   Build %WIN_BUILD%   Win11=%IS_WIN11%   CPU=%CPU%   GPU=%GPU%   Disk=%SYSDISK%'
    Assert-True (([regex]::Matches($all, $hdr)).Count -ge 2) 'The Status screen no longer carries the same machine header as the main menu, so the two can disagree about what was probed (regression of F-L2).'
    Assert-True (([regex]::Matches($all, '(?i)echo   Machine=%MACHINE%   Undervolt tool: !_uvhdr!')).Count -ge 2) 'The second header line no longer shows Machine= beside the undervolt tool on both screens.'
    # CPU vendor from the registry value Windows fills in at boot - locale-free, no WMI/PowerShell
    Assert-True ($all -match '(?i)reg query "HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0" /v VendorIdentifier') 'CPU= is no longer read from CentralProcessor\0 VendorIdentifier.'
    Assert-True ($all -match '(?i)if /i "!_cpuv!"=="GenuineIntel" set "CPU=intel"' -and $all -match '(?i)if /i "!_cpuv!"=="AuthenticAMD" set "CPU=amd"') 'The CPU vendor strings no longer map to intel / amd.'
    $st = ((Get-RoutineBody -Lines $cmd -Label 'Status') -join "`n")
    Assert-True ($st -match '(?i)call :DetectSysDisk') ':Status no longer resolves the disk type before printing it (regression of F-L2).'
    Assert-True ($st -match '(?i)call :DetectUndervolt') ':Status no longer resolves the undervolt probe before printing it (regression of F-L2).'
}

# ===============================================================================
# 120. The undervolt probe reports a TOOL, never a voltage - nothing here can read
#      an actual offset. So "none found" must never be presented as "not
#      undervolted": a BIOS/EFI offset leaves no signature, and a false negative is
#      exactly how someone gets talked into Ultimate Performance on the machine
#      where that produced a WHEA 0x124.
# ===============================================================================
Invoke-Test 'The undervolt probe can only strengthen the warning, never soften it' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    $d = @(Get-BodyLines -Lines $cmd -Label 'DetectUndervolt')
    Assert-True ($d.Count -gt 5) ':DetectUndervolt body did not unroll.'
    $code = @($d | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"

    Assert-True ($code -match '(?i)if defined UVPROBED goto :eof') ':DetectUndervolt no longer caches, so every caller re-probes (regression of F-L3).'
    Assert-True ($code -notmatch '(?i)powershell') ':DetectUndervolt spawns PowerShell - it runs at startup and must stay cheap (regression of F-L3).'
    foreach ($t in 'XTU3SERVICE','AMDRyzenMasterDriver') {
        Assert-True ($code -match ('(?i)' + [regex]::Escape($t))) ":DetectUndervolt no longer looks for $t (regression of F-L3)."
    }
    # ThrottleStop is portable, so BOTH of its autostart routes must be probed - asserting
    # the name appears somewhere is not enough, the Startup-folder .lnk check alone satisfies it
    Assert-True ($code -match '(?i)findstr /I "ThrottleStop"') ':DetectUndervolt no longer scans the Run keys for ThrottleStop - the Startup-folder check alone misses the Run-entry autostart (regression of F-L3).'
    Assert-True ($code -match '(?i)Startup\\ThrottleStop\.lnk') ':DetectUndervolt no longer checks the Startup folder for ThrottleStop (regression of F-L3).'
    # every hit is recorded, not just the first - two tools on one machine is normal
    Assert-True ($code -match '(?i)call :_uvAdd') ':DetectUndervolt no longer accumulates its hits, so a machine with two tools reports only one (regression of F-L3).'
    $add = ((Get-RoutineBody -Lines $cmd -Label '_uvAdd') -join "`n")
    Assert-True ($add -match '(?i)set "UVTOOL=!UVTOOL! \+ %~1"') ':_uvAdd no longer appends, so later tools overwrite earlier ones (regression of F-L3).'

    # the advisory fires only on a POSITIVE find, and Status refuses to call a miss a "no"
    $lap = ((Get-RoutineBody -Lines $cmd -Label 'LaptopAdvisory') -join "`n")
    Assert-True ($lap -match '(?i)call :DetectUndervolt') ':LaptopAdvisory no longer consults the undervolt probe (regression of F-L3).'
    Assert-True ($lap -match '(?i)if not defined UVTOOL goto :eof') ':LaptopAdvisory says something when NO tool was found - a missing tool is not evidence of a missing undervolt, so silence is the only honest option there (regression of F-L3).'
    Assert-True ($lap -match '(?i)0x124') ':LaptopAdvisory lost the machine-check consequence, which is the whole reason this probe exists (regression of F-L3).'
    Assert-True ($all -match '(?i)Treat it as "unknown", not "no"') 'Status no longer warns that a negative probe is not proof - without that line "no known tool found" reads as "not undervolted" (regression of F-L3).'
}

# ===============================================================================
# 121. The harness checks ITSELF. `@(Get-RoutineBody ...)` in one step wraps the
#      returned array instead of unrolling it, so the whole routine arrives as a
#      single element and every per-line assertion built on it silently passes.
#      It has been written five times, once on a test whose job was catching that
#      class. Reading cannot find it and mutation-testing only finds it if you
#      happen to mutate that routine, so the harness greps its own source.
# ===============================================================================
Invoke-Test 'The harness itself never uses the misuse-prone body slicer' {
    Assert-True (Test-Path -LiteralPath $SelfPath) 'Could not locate the harness source to self-check.'
    $self = [System.IO.File]::ReadAllLines($SelfPath)

    # Skip comments - both `#` lines and `<# #>` blocks. Get-BodyLines' own doc comment
    # spells the banned form out on purpose, and a scan that cannot tell code from prose
    # would flag the explanation instead of a defect. This is trap 3b applied to the
    # harness's own source, which is a fair test of whether the rule was understood.
    $bad = @(); $inBlock = $false
    for ($i = 0; $i -lt $self.Count; $i++) {
        $ln = $self[$i]
        if ($inBlock) { if ($ln -match '#>') { $inBlock = $false }; continue }
        if ($ln -match '<#') { if ($ln -notmatch '#>') { $inBlock = $true }; continue }
        if ($ln -match '^\s*#') { continue }
        if ($ln -match '@\(Get-RoutineBody') { $bad += ("line {0}: {1}" -f ($i + 1), $ln.Trim()) }
    }
    Assert-True ($bad.Count -eq 0) ("Misuse-prone one-step slice(s) - @() wraps the returned array instead of unrolling it, so the routine becomes ONE element and every assertion on it passes vacuously. Use Get-BodyLines: {0}" -f ($bad -join '; '))

    # and the safe wrapper must actually behave, or switching to it buys nothing
    $cmd = Read-Lines $CmdPath
    $direct = @(Get-BodyLines -Lines $cmd -Label 'Summary')
    $viaVar = Get-BodyLines -Lines $cmd -Label 'Summary'
    Assert-True ($direct.Count -gt 3) "Get-BodyLines under @() yielded $($direct.Count) element(s) - it is not unrolling."
    Assert-True (@($viaVar).Count -eq $direct.Count) 'Get-BodyLines disagrees with itself between assignment and @() - the whole point is that both work.'
    $joined = (Get-BodyLines -Lines $cmd -Label 'Summary') -join "`n"
    Assert-True ($joined -match '(?i)_FAILS') 'Get-BodyLines output does not join into readable text.'
    # -CodeOnly must drop rem lines and keep code
    $all  = @(Get-BodyLines -Lines $cmd -Label 'Summary')
    $code = @(Get-BodyLines -Lines $cmd -Label 'Summary' -CodeOnly)
    Assert-True ($code.Count -lt $all.Count) '-CodeOnly did not strip anything from a routine that has comments.'
    Assert-True ((@($code) -join "`n") -notmatch '(?im)^\s*rem\b') '-CodeOnly left rem lines in.'
    $noEcho = @(Get-BodyLines -Lines $cmd -Label 'Summary' -NoEcho)
    Assert-True ((@($noEcho) -join "`n") -notmatch '(?im)^\s*echo\b') '-NoEcho left echo lines in.'
}

# ===============================================================================
# 122. A lone " typed at any prompt used to abort the entire script. `if
#      "%sel%"=="1"` substitutes the typed value BEFORE the line is parsed, so
#      one double quote left the line unbalanced and cmd stopped dead - from any
#      of 189 comparisons. `!sel!` is substituted AFTER parsing, so the quote
#      stays data and the comparison just says "no". This test reads the set /p
#      targets out of the script rather than hard-coding them, so a new prompt is
#      covered the day it is added.
# ===============================================================================
Invoke-Test 'Typed input is compared late-expanded, so a lone quote cannot abort the script' {
    $cmd = Read-Lines $CmdPath
    $targets = @{}
    foreach ($ln in $cmd) {
        foreach ($m in [regex]::Matches($ln, '(?i)\bset\s+/p\s+"?([A-Za-z_][A-Za-z0-9_]*)=')) {
            $targets[$m.Groups[1].Value.ToLower()] = $true
        }
    }
    Assert-True ($targets.Count -gt 20) "Only $($targets.Count) set /p target(s) found - the scan is not seeing the prompts, so the rest of this test proves nothing."
    $bad = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $ln = $cmd[$i]
        if ($ln.Trim() -match '^(?i)(rem\b|::)') { continue }
        foreach ($m in [regex]::Matches($ln, '(?i)(?:==\s*)"%([A-Za-z_][A-Za-z0-9_]*)%"|"%([A-Za-z_][A-Za-z0-9_]*)%"(?:\s*==)')) {
            $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if ($targets.ContainsKey($name.ToLower())) {
                $bad += ("line {0}: {1}" -f ($i + 1), $ln.Trim())
            }
        }
    }
    Assert-True ($bad.Count -eq 0) ("Typed input is compared with %var% instead of !var!, so a lone double quote at that prompt aborts the script: " + ($bad -join ' | '))

    # A validator that splices the typed value into its own code breaks the same way. In
    # `for /f "..." %%x in ("%v%")` a quote in the value ends the string early and the line no
    # longer parses: the timer-resolution prompt closed the script on `"` or `1"2`. And `50!0`
    # passed as a number there, because delayed expansion dropped the lone `!` after `%v%`
    # had spliced it in. `!v!` is substituted after parsing and taken verbatim.
    $spliced = @()
    $late = 0
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $ln = $cmd[$i]
        if ($ln.Trim() -match '^(?i)(rem\b|::)' -or $ln -notmatch '(?i)\bfor\s+/f\b' -or $ln -match '(?i)usebackq') { continue }
        foreach ($m in [regex]::Matches($ln, '(?i)\bin\s*\(\s*"([%!])([A-Za-z_][A-Za-z0-9_]*)[%!]"\s*\)')) {
            if (-not $targets.ContainsKey($m.Groups[2].Value.ToLower())) { continue }
            if ($m.Groups[1].Value -eq '%') { $spliced += ("line {0}: {1}" -f ($i + 1), $ln.Trim()) } else { $late++ }
        }
    }
    Assert-True ($late -ge 1) 'No for /f validator over typed input was found at all - the scan is not seeing them, so the check below proves nothing.'
    Assert-True ($spliced.Count -eq 0) ("A for /f validator splices typed input in with %var%, so a lone double quote at that prompt aborts the script and a '!' slips past the check: " + ($spliced -join ' | '))

    # Nor may anything between the prompt and the end of the validator's rejection branch read
    # the value early. With `echo [ERROR] "%v%" ...` inside `if defined bad ( ... )`, a typed
    # `")` closed the block and aborted the script, and `"&echo X` ran the command (measured).
    $zones = 0
    $early = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $m = [regex]::Match($cmd[$i], '(?i)^\s*for\s+/f\s+"[^"]*"\s+%%\w\s+in\s*\(\s*"!([A-Za-z_][A-Za-z0-9_]*)!"\s*\)\s*do\s+set\s+"([A-Za-z_][A-Za-z0-9_]*)=1"')
        if (-not $m.Success -or -not $targets.ContainsKey($m.Groups[1].Value.ToLower())) { continue }
        $v = $m.Groups[1].Value
        $flag = $m.Groups[2].Value
        $start = -1
        for ($k = $i - 1; $k -ge [Math]::Max(0, $i - 30); $k--) {
            if ($cmd[$k] -match ('(?i)\bset\s+/p\s+"' + [regex]::Escape($v) + '=')) { $start = $k; break }
        }
        $open = -1
        for ($k = $i + 1; $k -le [Math]::Min($cmd.Count - 1, $i + 5); $k++) {
            if ($cmd[$k] -match ('(?i)^\s*if\s+defined\s+' + [regex]::Escape($flag) + '\s*\(\s*$')) { $open = $k; break }
        }
        if ($start -lt 0 -or $open -lt 0) { continue }
        $end = -1
        for ($k = $open + 1; $k -lt $cmd.Count; $k++) { if ($cmd[$k].Trim() -eq ')') { $end = $k; break } }
        if ($end -lt 0) { continue }
        $zones++
        for ($k = $start + 1; $k -le $end; $k++) {
            if ($cmd[$k].Trim() -match '^(?i)(rem\b|::)') { continue }
            if ($cmd[$k] -match ('(?i)%' + [regex]::Escape($v) + '%')) { $early += ("line {0}: {1}" -f ($k + 1), $cmd[$k].Trim()) }
        }
    }
    Assert-True ($zones -ge 2) ("Found {0} prompt(s) with a for /f validator and a rejection branch - the timer-resolution and Unity job-worker prompts should both be here, so the scan is not seeing them." -f $zones)
    Assert-True ($early.Count -eq 0) ("Typed input is read with %var% between its prompt and the end of its rejection branch - a quote in it can close the block or run a command: " + ($early -join ' | '))
}

# ===============================================================================
# 123. The shipped hosts and boot.config are read on Windows too, and nothing
#      was checking their bytes. hosts in particular ended mid-entry with no
#      final newline, so the next ">> hosts" append by a user or another tool
#      glued onto the last blocked name - "echo 192.168.1.10 nas >> hosts" would
#      have blocked "nas". hosts is LF-only by convention (it comes from an
#      upstream blocklist) so uniform-CRLF is NOT asserted here; ASCII, no BOM
#      and a final newline are.
# ===============================================================================
Invoke-Test 'Shipped data files are ASCII, BOM-free and end with a newline' {
    $dir = Split-Path -Parent $CmdPath
    $checked = 0
    foreach ($name in @('hosts', 'boot.config')) {
        $p = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $checked++
        $bytes = [System.IO.File]::ReadAllBytes($p)
        Assert-True ($bytes.Length -gt 10) "$name is suspiciously small - wrong path?"
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-True (-not $hasBom) "$name has a UTF-8 BOM."
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        Assert-True ($nonAscii -eq 0) "$name is not ASCII-pure ($nonAscii byte(s))."
        $last = $bytes[$bytes.Length - 1]
        Assert-True ($last -eq 10 -or $last -eq 13) "$name does not end with a newline - the next '>> $name' append would glue onto its last line (regression)."
    }
    Assert-True ($checked -gt 0) 'Neither hosts nor boot.config was found next to the script - the paths are wrong, so this test proved nothing.'
}

# ===============================================================================
# 124. The telemetry undo file. Privacy disables two services and nine scheduled
#      tasks, and until now that was the one corner of the script with nothing
#      captured first - `sc config` and `schtasks /Change` leave no .reg behind
#      the way :SafeRegAdd does. What matters here is the ORDER (capture before
#      disable, or the file faithfully records "already disabled"), reading state
#      from the registry and Get-ScheduledTask rather than localized command
#      output, and the generated file counting its own failures instead of
#      printing a flat [OK].
# ===============================================================================
Invoke-Test 'Telemetry disables are captured first, into a self-checking undo file' {
    $cmd = Read-Lines $CmdPath

    $priv = (Get-BodyLines -Lines $cmd -Label 'DoPrivacyCore' -CodeOnly) -join "`n"
    $iCap = $priv.IndexOf('call :TelemetryBackup')
    $iSvc = $priv.IndexOf('sc config DiagTrack start= disabled')
    Assert-True ($iCap -ge 0) ':DoPrivacyCore no longer captures a telemetry undo file (regression).'
    Assert-True ($iSvc -ge 0) ':DoPrivacyCore no longer disables DiagTrack - routine changed shape?'
    Assert-True ($iCap -lt $iSvc) ':DoPrivacyCore disables the telemetry services BEFORE capturing their state, so the undo file would record them as already disabled and restore nothing (regression).'

    $tb = (Get-BodyLines -Lines $cmd -Label 'TelemetryBackup' -CodeOnly) -join "`n"
    Assert-True ($tb.Length -gt 0) ':TelemetryBackup is missing.'
    Assert-True ($tb -match '(?i)CurrentControlSet.{0,2}Services') ':TelemetryBackup no longer reads service start types from the registry (regression).'
    Assert-True ($tb -match '(?i)Get-ScheduledTask') ':TelemetryBackup no longer reads task state from Get-ScheduledTask (regression).'
    Assert-True ($tb -notmatch '(?i)sc qc|schtasks /Query') ':TelemetryBackup parses localized service/task text again - it would capture nothing on a translated Windows and hand back an empty undo file (regression).'
    Assert-True ($tb -match '(?i)pt_do') ':TelemetryBackup no longer routes the generated restore commands through the counting helper, so the undo file could print a blind [OK] (regression).'
    Assert-True ($tb -match '_TLBAK_FILE') ':TelemetryBackup lost its one-file-per-visit guard (regression).'
    Assert-True ($tb -match '(?i)already disabled') ':TelemetryBackup no longer distinguishes "already disabled before sincript" from "disabled by sincript" - reverting would undo the user own earlier choice (regression).'

    # The body slicer stops at any label that does not start with "_", and
    # :RestoreTelemetryBackup_ask does not - so the half after the prompt, which is where the
    # undo file is actually run, is invisible unless both halves are concatenated.
    $rt = ((Get-BodyLines -Lines $cmd -Label 'RestoreTelemetryBackup' -CodeOnly) +
           (Get-BodyLines -Lines $cmd -Label 'RestoreTelemetryBackup_ask' -CodeOnly)) -join "`n"
    Assert-True ($rt.Length -gt 0) ':RestoreTelemetryBackup is missing.'
    Assert-True ($rt -match '(?i)Telemetry_\*\.bat') ':RestoreTelemetryBackup no longer lists the Telemetry_*.bat undo files (regression).'
    Assert-True ($rt -match '(?i)cmd /d /v:off /s /c ""!_tfile!" /q"') ':RestoreTelemetryBackup no longer runs the chosen file in a child cmd with /q - `call`ed, a syntax error in it ends sincript too, and without /q its own pause blocks the menu (regression).'
    Assert-True ($rt -notmatch '(?i)\bcall\s+"?[%!]_tfile') ':RestoreTelemetryBackup `call`s the undo file again - a syntax error in it would end sincript too (regression; see test 126).'
    Assert-True ($rt -match '_RUNTRACK=') ':RestoreTelemetryBackup no longer clears _RUNTRACK, so the next cleanup counts benign failures as real ones (regression).'
}

# ===============================================================================
# 125. Every set /p prompt fits the console width the script asks for. cmd puts
#      the input caret at (prompt length mod console width), so a prompt as wide
#      as the console puts the caret inside the question, and the first
#      keystroke overwrites the text the user is reading.
# ===============================================================================
Invoke-Test 'Every set /p prompt fits the console width the script asks for' {
    $cmd = Read-Lines $CmdPath
    # Read the width out of the script instead of hard-coding it: if `mode con` ever changes,
    # this follows rather than quietly testing the wrong number.
    $width = 0
    foreach ($ln in $cmd) {
        $m = [regex]::Match($ln, '(?i)^\s*mode con:\s*cols=(\d+)')
        if ($m.Success) { $width = [int]$m.Groups[1].Value }
    }
    Assert-True ($width -gt 0) 'No "mode con: cols=" line found, so there is no width to measure against.'

    $checked = 0
    $bad = @()
    foreach ($ln in $cmd) {
        if ($ln -match '^\s*rem\b') { continue }
        foreach ($m in [regex]::Matches($ln, '(?i)set\s+/p\s+"([A-Za-z_][A-Za-z0-9_]*)=([^"]*)"')) {
            # colour variables expand to ANSI escapes, which take no screen columns, and a
            # doubled %% renders as a single %
            $vis = [regex]::Replace($m.Groups[2].Value, '%(?:ESC|[A-Za-z][A-Za-z0-9]?|gold)%', '')
            $vis = $vis.Replace('%%', '%')
            $checked++
            if ($vis.Length -ge $width) {
                $bad += ('{0} ({1} cols)' -f $m.Groups[1].Value, $vis.Length)
            }
        }
    }
    Assert-True ($checked -gt 80) "Only $checked prompt(s) were measured - the scan is not finding them, so the rest of this test proves nothing."
    Assert-True ($bad.Count -eq 0) ("A set /p prompt at least as wide as the ${width}-column console makes cmd put the caret at (length mod width) - typing then overwrites the question instead of following it. Too long: " + ($bad -join ', '))
}

# ===============================================================================
# 126. The undo files are RUN here, not only read (power, telemetry, and the
#      NVIDIA tasks). Every other test reads the
#      generators' text, and that is how :PowerBackup came to write a broken
#      file: its payload reused $q - the double quote the generated lines are
#      built with - as the cache for the `powercfg /query` fallback, so every
#      PowerPlan_*.bat ended in `if %~1== pause`, a syntax error. Reached through
#      `call`, that error ended sincript too, right after the restore.
#      Both generator payloads run here in a child Windows PowerShell and write
#      to %TEMP%. `powercfg` and Get-ScheduledTask are faked, so nothing depends
#      on this machine's plans or tasks, and the fake plan has no stored values:
#      every setting takes the /query fallback, the path that reused $q.
#      Anything that could change the system ends the child instead. Each
#      generated file is then dry-run the way the Backups menu runs it (a child
#      cmd, /q) with every restore command turned into an echo, and its own
#      report and exit code are checked. The power generator runs six times,
#      with Get-ItemProperty answering the hibernation state from the test: on,
#      off, only Windows' default recorded, and unreadable - then off and on
#      again with PT_HBOFF set, as when the Power screen turned hibernation off
#      after a failed capture and a later capture on the same visit retries.
# ===============================================================================
Invoke-Test 'The undo-file generators write batch files that run to the end' {
    $cmd = Read-Lines $CmdPath
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $pwFile = Join-Path ([System.IO.Path]::GetTempPath()) ('PT126_PowerPlan_{0}.bat' -f $tag)
    $tlFile = Join-Path ([System.IO.Path]::GetTempPath()) ('PT126_Telemetry_{0}.bat' -f $tag)
    $nvFile = Join-Path ([System.IO.Path]::GetTempPath()) ('PT126_Telemetry_nvidia_{0}.bat' -f $tag)
    $nvRes = Join-Path ([System.IO.Path]::GetTempPath()) ('PT126_nvres_{0}.txt' -f $tag)
    $fakeGuid = '1d2c3b4a-0126-4126-8126-000000000126'

    # Runs a program with stdin closed - a stray `pause` then reads end-of-file instead of
    # hanging the harness - and returns its exit code and output.
    $runProc = {
        param([string]$File, [string]$Arguments)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw ('test 126: {0} did not finish within 60 s.' -f (Split-Path -Leaf $File)) }
        [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err.Result }
    }
    $encoded = { param([string]$Text) '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Text)) }

    # Loaded ahead of each payload in the child. The fakes answer for this test's plan and
    # tasks; everything a generator could use to change the system exits the child with 126.
    $prelude = @'
foreach ($n in @('powercfg.exe', 'sc.exe', 'schtasks', 'schtasks.exe', 'reg', 'reg.exe', 'Set-Service', 'Start-Service', 'Stop-Service', 'Restart-Service', 'Enable-ScheduledTask', 'Disable-ScheduledTask', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item', 'Start-Process')) {
    Set-Item -Path ('function:global:' + $n) -Value ([scriptblock]::Create("[Console]::Error.WriteLine('test 126: the generator tried to run $n'); [Environment]::Exit(126)"))
}
function global:powercfg {
    if ($args[0] -eq '/getactivescheme') { return 'Power Scheme GUID: FAKEGUID  (test 126)' }
    if ($args[0] -eq '/query') { return @('    Current AC Power Setting Index: 0x0000012c', '    Current DC Power Setting Index: 0x000000b4') }
    [Console]::Error.WriteLine('test 126: unexpected powercfg ' + ($args -join ' ')); [Environment]::Exit(126)
}
function global:Get-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName)
    if (-not $TaskName) {
        return @(
            [pscustomobject]@{ TaskPath = '\NVIDIA\'; TaskName = 'NvTmRep_PT126'; State = 'Ready' },
            [pscustomobject]@{ TaskPath = '\NVIDIA\'; TaskName = 'NvTmRep_CrashReport2_PT126'; State = 'Ready' },
            [pscustomobject]@{ TaskPath = '\NVIDIA\'; TaskName = 'NvTmMon_PT126'; State = 'Disabled' },
            [pscustomobject]@{ TaskPath = '\NVIDIA\'; TaskName = 'NvDriverUpdateCheckDaily_PT126'; State = 'Ready' },
            [pscustomobject]@{ TaskPath = '\PT126\'; TaskName = 'Unrelated'; State = 'Ready' })
    }
    if ($TaskName -like '*absent*') { return }
    $state = 'Ready'
    if ($TaskName -like '*off*') { $state = 'Disabled' }
    [pscustomobject]@{ TaskPath = '\PT126\'; TaskName = $TaskName; State = $state }
}
function global:Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath)
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -and $global:PT126_HIB) {
        switch ($global:PT126_HIB) {
            'on'      { return [pscustomobject]@{ HibernateEnabled = 1; HibernateEnabledDefault = 0 } }
            'off'     { return [pscustomobject]@{ HibernateEnabled = 0; HibernateEnabledDefault = 1 } }
            'hbon'    { return [pscustomobject]@{ HibernateEnabled = 1; HibernateEnabledDefault = 0 } }
            'hboff'   { return [pscustomobject]@{ HibernateEnabled = 0; HibernateEnabledDefault = 1 } }
            'default' { return [pscustomobject]@{ HibernateEnabledDefault = 1 } }
            default   { return $null }
        }
    }
    Microsoft.PowerShell.Management\Get-ItemProperty -LiteralPath $LiteralPath -ErrorAction SilentlyContinue
}
'@
    $prelude = $prelude.Replace('FAKEGUID', $fakeGuid)

    # Pull each payload out of its `powershell -Command "..."` line and undo the one thing
    # cmd does to it: %% becomes %. Anything else cmd would change, this test cannot copy.
    $payload = @{}
    foreach ($key in @('PT_PWBAK', 'PT_TLBAK', 'PT_NV_UNDO')) {
        $hits = @($cmd | Where-Object { $_.TrimStart() -notmatch '^(?i)rem\b' -and $_.Contains('Set-Content -LiteralPath $env:' + $key + ' ') })
        Assert-True ($hits.Count -eq 1) ('Expected one generator line writing $env:{0}, found {1} - it moved or was split, so this test is not running it.' -f $key, $hits.Count)
        $m = [regex]::Match($hits[0], '-Command "(.*)"\s*$')
        Assert-True $m.Success ('The {0} generator lost the -Command "..." shape this test extracts.' -f $key)
        $raw = $m.Groups[1].Value
        Assert-True (-not $raw.Contains('"')) ('The {0} payload holds a double quote, which would end cmd''s quoting of it.' -f $key)
        Assert-True (-not $raw.Contains('!')) ('The {0} payload holds a "!" - delayed expansion would change it before PowerShell saw it, and this test cannot copy that.' -f $key)
        Assert-True (-not $raw.Replace('%%', '').Contains('%')) ('The {0} payload holds a single "%" that cmd would expand - this test cannot copy that.' -f $key)
        $payload[$key] = $raw.Replace('%%', '%')
    }

    # Dry-runs a generated file the way the Backups menu runs it, with every restore command
    # turned into an echo, after checking that nothing else in it could do anything.
    $dryRun = {
        param([string]$File, [string]$Unit)
        $name = Split-Path -Leaf $File
        $lines = [System.IO.File]::ReadAllLines($File)
        $safe = '^(|rem|rem .*|@echo off|setlocal|set "PT_(OK|FAIL)=0"|call :pt_do [^&|<>^]+|if (not )?"?%PT_FAIL%"?=="?0"? echo [^&|<>^]*|if "?%~1"?==(""|) pause|exit /b|exit /b %PT_FAIL%|:pt_do|:pt_bad|%\*|if errorlevel 1 goto :pt_bad|set /a PT_(OK|FAIL)\+=1|echo   \[FAIL\] %\*)$'
        $unknown = @($lines | Where-Object { $_ -cnotmatch $safe })
        Assert-True ($unknown.Count -eq 0) ('{0} has line(s) this test does not know to be safe to dry-run - check them, then extend the list: {1}' -f $name, ($unknown -join ' | '))
        $n = @($lines | Where-Object { $_.StartsWith('call :pt_do ') }).Count
        Assert-True ($n -ge 2) ('{0} restores {1} thing(s) - too few for the dry run to prove anything.' -f $name, $n)
        $dry = $File + '.dry.bat'
        [System.IO.File]::WriteAllLines($dry, [string[]]@($lines | ForEach-Object { $_ -replace '^call :pt_do ', 'call :pt_do echo ' }), [System.Text.Encoding]::ASCII)
        $r = & $runProc $cmdExe ('/d /v:off /s /c ""' + $dry + '" /q"')
        $shown = (($r.Out + $r.Err).Trim() -replace '\s*\r?\n\s*', ' | ')
        Assert-True ($r.Code -eq 0) ('{0}, run the way the Backups menu runs it, ended with exit {1}, not 0: {2}' -f $name, $r.Code, $shown)
        Assert-True ($r.Out.Contains(('[OK] Restored {0} {1}' -f $n, $Unit))) ('{0} did not report all {1} restore command(s) as done: {2}' -f $name, $n, $shown)
    }

    try {
        # ---- power: a plan with nothing stored, so every value takes the /query fallback
        $r = & $runProc $psExe (& $encoded ($prelude + "`n`$global:PT126_HIB = 'on'`n`$env:PT_HBOFF = `$null`n`$env:PT_PWBAK = '" + $pwFile.Replace("'", "''") + "'`n" + $payload['PT_PWBAK']))
        Assert-True ($r.Code -ne 126) ('The power generator tried to change the system: ' + $r.Err.Trim())
        Assert-True ($r.Code -eq 0 -and (Test-Path -LiteralPath $pwFile)) ('The power generator wrote no undo file (exit {0}): {1}' -f $r.Code, $r.Err.Trim())
        $pw = [System.IO.File]::ReadAllLines($pwFile)
        Assert-True ($pw -contains 'if "%~1"=="" pause') 'The power undo file''s last check is not `if "%~1"=="" pause` - the generator lost its quote character. It came out as `if %~1== pause` when the /query cache reused $q: a syntax error that ended sincript right after a restore (regression).'
        $unq = @($pw | Where-Object { $_ -match '^if ' -and $_ -notmatch '^if (not )?"' -and $_ -notmatch '^if errorlevel ' })
        Assert-True ($unq.Count -eq 0) ('Unquoted comparison(s) in the power undo file: ' + ($unq -join ' | '))
        $vals = @($pw | Where-Object { $_ -match '^call :pt_do powercfg -set(ac|dc)valueindex ' })
        $notes = @($pw | Where-Object { $_ -match 'not stored on this plan; this is the value that was in effect' })
        Assert-True ($vals.Count -ge 2 -and $notes.Count -eq $vals.Count) ('Every value of the fake plan should come from the /query fallback - the path that reused $q - but {0} of {1} did, so this test is not exercising it.' -f $notes.Count, $vals.Count)
        Assert-True (@($vals | Where-Object { $_ -match ('^call :pt_do powercfg -setacvalueindex {0} \S+ \S+ 300$' -f $fakeGuid) }).Count -ge 1) 'The /query fallback no longer reads 0x0000012c as 300 on AC - the first index is AC.'
        Assert-True (@($vals | Where-Object { $_ -match ('^call :pt_do powercfg -setdcvalueindex {0} \S+ \S+ 180$' -f $fakeGuid) }).Count -ge 1) 'The /query fallback no longer reads 0x000000b4 as 180 on battery - AC and DC may be swapped.'
        Assert-True (@($pw | Where-Object { $_ -eq 'call :pt_do powercfg /hibernate on' }).Count -eq 1) 'The power undo file does not turn hibernation back on although it was on at backup time (regression).'
        Assert-True (@($pw | Where-Object { $_ -match 'HibernateEnabledDefault' }).Count -eq 0) 'The power undo file says it used Windows'' default although HibernateEnabled was set - the stored value must win.'
        & $dryRun $pwFile 'power setting'

        # ---- power again, three more hibernation states: already off (the user's own choice,
        #      never reversed), only HibernateEnabledDefault recorded (Windows goes by it), and
        #      nothing readable (the file must say so and name the manual command, not guess).
        #      Then PT_HBOFF, set when the Power screen turned hibernation off with no capture
        #      landed: a retried capture that reads "off" may be reading sincript's own change,
        #      so it must say the earlier state is unknown, never "already off before sincript";
        #      one that reads "on" still restores it. The 4th item is a line that must NOT appear.
        $alreadyOff = 'rem  hibernation was already off before sincript - left alone'
        foreach ($hc in @(
                @('off', 0, $alreadyOff, ''),
                @('default', 1, 'rem  HibernateEnabled was not set, so this is the Windows default (HibernateEnabledDefault).', ''),
                @('unreadable', 0, 'rem  turn it back on from an elevated prompt with:  powercfg /hibernate on', ''),
                @('hboff', 0, 'rem  prompt with:  powercfg /hibernate on', $alreadyOff),
                @('hbon', 1, 'rem  hibernation was on before sincript - turn it back on', 'rem  prompt with:  powercfg /hibernate on'))) {
            $hf = $pwFile + '.' + $hc[0] + '.bat'
            $hbEnv = "`$env:PT_HBOFF = `$null"
            if ($hc[0] -like 'hb*') { $hbEnv = "`$env:PT_HBOFF = '1'" }
            $r = & $runProc $psExe (& $encoded ($prelude + "`n`$global:PT126_HIB = '" + $hc[0] + "'`n" + $hbEnv + "`n`$env:PT_PWBAK = '" + $hf.Replace("'", "''") + "'`n" + $payload['PT_PWBAK']))
            Assert-True ($r.Code -ne 126) ('The power generator tried to change the system: ' + $r.Err.Trim())
            Assert-True ($r.Code -eq 0 -and (Test-Path -LiteralPath $hf)) ('The power generator wrote no undo file with hibernation {0} (exit {1}): {2}' -f $hc[0], $r.Code, $r.Err.Trim())
            $hl = [System.IO.File]::ReadAllLines($hf)
            $hon = @($hl | Where-Object { $_ -match '^call :pt_do .*hibernate' }).Count
            Assert-True ($hon -eq $hc[1]) ('With hibernation {0} at backup time, the power undo file has {1} hibernation restore line(s), not {2} (regression).' -f $hc[0], $hon, $hc[1])
            Assert-True (@($hl | Where-Object { $_ -eq $hc[2] }).Count -eq 1) ('With hibernation {0} at backup time, the power undo file no longer says: {1}' -f $hc[0], $hc[2])
            if ($hc[3]) { Assert-True (@($hl | Where-Object { $_ -eq $hc[3] }).Count -eq 0) ('With hibernation {0} at backup time, the power undo file says: {1} (regression).' -f $hc[0], $hc[3]) }
            & $dryRun $hf 'power setting'
        }

        # ---- telemetry: a service that is missing, one every Windows runs, and three tasks
        $setup = "`$env:PT_TLBAK = '" + $tlFile.Replace("'", "''") + "'`n`$env:PT_TL_SVC = 'PT126NoSuchService|EventLog'`n`$env:PT_TL_TASKS = 'PT126 task|PT126 off task|PT126 absent task'`n"
        $r = & $runProc $psExe (& $encoded ($prelude + "`n" + $setup + $payload['PT_TLBAK']))
        Assert-True ($r.Code -ne 126) ('The telemetry generator tried to change the system: ' + $r.Err.Trim())
        Assert-True ($r.Code -eq 0 -and (Test-Path -LiteralPath $tlFile)) ('The telemetry generator wrote no undo file (exit {0}): {1}' -f $r.Code, $r.Err.Trim())
        $tl = [System.IO.File]::ReadAllLines($tlFile)
        Assert-True ($tl -contains 'if "%~1"=="" pause') 'The telemetry undo file''s last check is not `if "%~1"=="" pause` - check the quote character in its generator (regression).'
        Assert-True ($tl -contains 'call :pt_do schtasks /Change /TN "\PT126\PT126 task" /Enable') 'The telemetry undo file no longer re-enables, quoted, a task that was enabled (regression).'
        Assert-True (@($tl | Where-Object { $_ -like '*PT126 off task was already disabled before sincript*' }).Count -eq 1) 'The telemetry undo file no longer leaves alone a task that was already disabled (regression).'
        Assert-True (@($tl | Where-Object { $_ -like '*PT126NoSuchService is not on this machine*' }).Count -eq 1) 'The telemetry undo file no longer notes a service that does not exist.'
        Assert-True (@($tl | Where-Object { $_ -like 'call :pt_do sc config EventLog start= *' }).Count -eq 1) 'The telemetry undo file wrote no start-type restore for EventLog, which every working Windows runs - the service branch of the generator is not being exercised.'
        & $dryRun $tlFile 'item'

        # ---- NVIDIA tasks: disabling fake task objects is the routine's job, so here - and only
        #      here - Disable-ScheduledTask is a no-op instead of the guard that ends the child
        $setup = "`$env:PT_NV_UNDO = '" + $nvFile.Replace("'", "''") + "'`n`$env:PT_NV_RES = '" + $nvRes.Replace("'", "''") + "'`nfunction global:Disable-ScheduledTask { [CmdletBinding()] param(`$InputObject) }`n"
        $r = & $runProc $psExe (& $encoded ($prelude + "`n" + $setup + $payload['PT_NV_UNDO']))
        Assert-True ($r.Code -ne 126) ('The NVIDIA tasks generator tried to change the system: ' + $r.Err.Trim())
        Assert-True ($r.Code -eq 0 -and (Test-Path -LiteralPath $nvFile)) ('The NVIDIA tasks generator wrote no undo file (exit {0}): {1}' -f $r.Code, $r.Err.Trim())
        $nv = [System.IO.File]::ReadAllLines($nvFile)
        Assert-True ($nv -contains 'call :pt_do schtasks /Change /TN "\NVIDIA\NvTmRep_PT126" /Enable') 'The NVIDIA undo file no longer re-enables, quoted, a telemetry task that was enabled (regression).'
        Assert-True (@($nv | Where-Object { $_ -like '*NvTmMon_PT126 was already disabled before sincript*' }).Count -eq 1) 'The NVIDIA undo file no longer leaves alone a task that was already disabled.'
        Assert-True (@($nv | Where-Object { $_ -match 'NvDriverUpdateCheckDaily|Unrelated' }).Count -eq 0) 'The NVIDIA undo file lists a task the routine must not touch - the driver-update check or an unrelated task (regression).'
        Assert-True ((Get-Content -LiteralPath $nvRes -Raw).Trim() -eq '3 3 1') ('The NVIDIA worker should report 3 found, 3 disabled, undo file written - it said: ' + (Get-Content -LiteralPath $nvRes -Raw).Trim())
        & $dryRun $nvFile 'item'
    }
    finally {
        $hibFiles = @('off', 'default', 'unreadable', 'hboff', 'hbon') | ForEach-Object { ($pwFile + '.' + $_ + '.bat'), ($pwFile + '.' + $_ + '.bat.dry.bat') }
        foreach ($f in @($pwFile, $tlFile, $nvFile, $nvRes, ($pwFile + '.dry.bat'), ($tlFile + '.dry.bat'), ($nvFile + '.dry.bat')) + @($hibFiles)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        }
    }
}

# ===============================================================================
# 127. The script's own path is read late everywhere after its capture. It is
#      captured with delayed expansion OFF so a "!" in the folder survives - and
#      then every %SCRIPT_DIR% / %_SELFPATH% read put it back into a line before
#      delayed expansion ran, which ate the "!" again. Measured from a folder
#      named "sin!cript test": the elevated relaunch pointed at a file that did
#      not exist, both cd's failed silently, and hosts, boot.config,
#      SetTimerResolution.exe, app.asar and every preset file were "not found".
#      A value built from the path must also not travel as a call argument: the
#      callee's %~1 is read under delayed expansion and loses the "!" there, so
#      the three routines that took one read it by reference now.
# ===============================================================================
Invoke-Test 'The script''s own path survives a "!" in its folder' {
    $cmd = Read-Lines $CmdPath
    $iCap = -1
    for ($i = 0; $i -lt $cmd.Count; $i++) { if ($cmd[$i] -match '^\s*set "SCRIPT_DIR=%~dp0"\s*$') { $iCap = $i; break } }
    Assert-True ($iCap -gt 0) 'The SCRIPT_DIR capture is gone or changed shape.'
    Assert-True ($cmd[$iCap - 1].Trim() -ieq 'setlocal DisableDelayedExpansion') 'SCRIPT_DIR is no longer captured right after "setlocal DisableDelayedExpansion" - with delayed expansion on, a "!" in the folder is eaten at the capture itself (regression).'
    Assert-True ($cmd[$iCap + 1] -match '^\s*set "_SELFPATH=%~f0"\s*$') '_SELFPATH is no longer captured next to SCRIPT_DIR, under the same setlocal.'

    $early = @()
    $late = 0
    $viaCall = @()
    for ($i = $iCap + 2; $i -lt $cmd.Count; $i++) {
        $ln = $cmd[$i]
        if ($ln.Trim() -match '^(?i)(rem\b|::)') { continue }
        if ($ln -match '(?i)%SCRIPT_DIR%|%_SELFPATH%|(?<!%)%~dp0|(?<!%)%~f0') { $early += ("line {0}: {1}" -f ($i + 1), $ln.Trim()) }
        $late += ([regex]::Matches($ln, '(?i)!SCRIPT_DIR!|!_SELFPATH!')).Count
        # the path itself as a call argument - :Log excepted, where a mangled "!" costs a log line
        if ($ln -match '(?i)\bcall\s+:(\w+)[^\r\n]*[!%](SCRIPT_DIR|_SELFPATH)[!%]' -and $Matches[1] -ine 'Log') { $viaCall += ("line {0}: {1}" -f ($i + 1), $ln.Trim()) }
    }
    Assert-True ($late -ge 10) ("Only {0} late read(s) of the script's path were found - the scan is not seeing them, so the checks below prove nothing." -f $late)
    Assert-True ($early.Count -eq 0) ("The script's own path is read with % after its capture, so a ""!"" in the folder is eaten again: " + ($early -join ' | '))
    Assert-True ($viaCall.Count -eq 0) ("The script's path is handed to a routine as a call argument, where the callee's %~1 loses a ""!"" to delayed expansion: " + ($viaCall -join ' | '))

    # The three routines that used to take such a value as %N read it by reference now.
    $ia = @(Get-BodyLines -Lines $cmd -Label 'InstallAsarInto' -CodeOnly) -join "`n"
    Assert-True ($ia -match '(?i)set "_asrc=!_SRC!"') ':InstallAsarInto no longer reads the source .asar from _SRC by reference (regression).'
    Assert-True ($ia -notmatch '%~3') ':InstallAsarInto reads a %~3 again - a bundled app.asar in a folder with "!" would not survive it (regression).'
    $iaCalls = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)call :InstallAsarInto\b' })
    Assert-True ($iaCalls.Count -ge 2) 'Expected both OpenAsar install loops to call :InstallAsarInto.'
    Assert-True (@($iaCalls | Where-Object { $_ -match '(?i)call :InstallAsarInto\s+"[^"]*"\s+"[^"]*"\s+\S' }).Count -eq 0) 'A caller passes :InstallAsarInto a third argument again - the source path belongs in _SRC.'

    $pb = @(Get-BodyLines -Lines $cmd -Label 'PrepareBootConfig' -CodeOnly) -join "`n"
    Assert-True ($pb.Length -gt 0) ':PrepareBootConfig is missing.'
    Assert-True ($pb -notmatch '%~[123]') ':PrepareBootConfig reads its paths from call arguments again - the source sits in the script folder, and a "!" in it is lost that way (regression).'
    $pbCall = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)call :PrepareBootConfig\b' })
    Assert-True ($pbCall.Count -ge 1 -and @($pbCall | Where-Object { $_ -notmatch '(?i)call :PrepareBootConfig\s*$' }).Count -eq 0) ':PrepareBootConfig is called with arguments again - the caller must set PT_SRC / PT_OUT / PT_JW instead.'
    Assert-True (@($cmd | Where-Object { $_ -match '^\s*set "PT_SRC=!SCRIPT_DIR!boot\.config"' }).Count -eq 1) 'The Unity caller no longer hands the bundled boot.config over in PT_SRC, read late.'

    $lw = @(Get-BodyLines -Lines $cmd -Label 'LockWorker' -CodeOnly) -join "`n"
    Assert-True ($lw -match 'PT_LF_FILE') ':LockWorker no longer reads PT_LF_FILE.'
    Assert-True ($lw -notmatch '(?i)set "PT_LF_FILE=%~2"') ':LockWorker takes the file path from %~2 again - a typed path like Wow!.pdf loses its "!" there (regression).'
    $lwCalls = 0
    $lwBad = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($cmd[$i].Trim() -match '^(?i)rem\b' -or $cmd[$i] -notmatch '(?i)call :LockWorker\b') { continue }
        $lwCalls++
        if ($cmd[$i - 1] -notmatch '^\s*set "PT_LF_FILE=!_lfpath!"\s*$') { $lwBad += ("line {0}" -f ($i + 1)) }
    }
    Assert-True ($lwCalls -ge 2) 'Expected both lock-finder passes to call :LockWorker.'
    Assert-True ($lwBad.Count -eq 0) ("A :LockWorker call is not preceded by set ""PT_LF_FILE=!_lfpath!"": " + ($lwBad -join ', '))
    $lf = @(Get-BodyLines -Lines $cmd -Label 'LockFinder' -CodeOnly) -join "`n"
    Assert-True ($lf -match '(?i)if not exist "!_lfpath!"') ':LockFinder no longer checks the typed path late - "Wow!.pdf" would be "No such file" (regression).'

    $pc = @(Get-BodyLines -Lines $cmd -Label 'PresetCustom' -CodeOnly) -join "`n"
    Assert-True ($pc -match '(?i)set "_pnm\[!_pn!\]=%%~nxF"') ':PresetCustom no longer stores the preset names - routine changed shape?'
    Assert-True ($pc -notmatch '(?i)%%~fF') ':PresetCustom stores full paths from %%~fF again - they carry the script folder into a delayed-expansion line, and a "!" in it is eaten (regression).'
}

# ===============================================================================
# 128. SteamLight keeps Steam's browser sandbox unless the user turns it off. Its
#      launch flags included -cef-disable-sandbox and -no-cef-sandbox, and
#      -cef-single-process does the same less visibly: Chromium's docs say
#      single-process mode "prevents the use of the sandbox". None of it was on the
#      screen, which sold the flags as RAM and CPU savings. The three now come only
#      from an explicit, disclosed opt-in whose safe answer is No, and the Excluded
#      screen - which says security-weakening changes are left out - names it.
# ===============================================================================
Invoke-Test 'SteamLight keeps Steam''s browser sandbox unless the user turns it off' {
    $cmd = Read-Lines $CmdPath
    $flags = @('-cef-single-process', '-cef-disable-sandbox', '-no-cef-sandbox')
    $sl = @(Get-BodyLines -Lines $cmd -Label 'SteamLight')
    Assert-True ($sl.Count -gt 20) ':SteamLight is missing or truncated.'
    $base = @($sl | Where-Object { $_ -match '^\s*set "_SLFLAGS=-' })
    Assert-True ($base.Count -eq 1) 'Expected exactly one default "set _SLFLAGS=" line in :SteamLight.'
    foreach ($f in $flags) {
        Assert-True ($base[0] -notmatch [regex]::Escape($f)) ("The default SteamLight flags include $f again - Steam's web pages would run without the sandbox for everyone (regression).")
    }
    # The opt-in: a cleared variable, the trade-off on screen before the question, a Y-only branch.
    $iAsk = -1
    $v = ''
    for ($i = 0; $i -lt $sl.Count; $i++) {
        if ($sl[$i] -match '(?i)^\s*set /p "(_\w+)=[^"]*sandbox') { $iAsk = $i; $v = $Matches[1]; break }
    }
    Assert-True ($iAsk -gt 0) 'SteamLight no longer asks, naming the sandbox, before turning it off.'
    $before = @($sl[0..($iAsk - 1)])
    Assert-True (@($before | Where-Object { $_ -match ('^\s*set "' + [regex]::Escape($v) + '="\s*$') }).Count -ge 1) ("The sandbox question's variable $v is not cleared before the prompt - a stale Y from earlier would answer it.")
    Assert-True (@($before | Where-Object { $_ -match '(?i)^\s*echo\b.*sandbox' }).Count -ge 1) 'The screen no longer explains the sandbox trade-off before asking.'
    $optin = @($sl | Where-Object { $_ -match ('(?i)^\s*if /i "!' + [regex]::Escape($v) + '!"=="Y" set "_SLFLAGS=!_SLFLAGS! ') })
    Assert-True ($optin.Count -eq 1) 'The sandbox-off flags are no longer added only on an explicit Y.'
    foreach ($f in $flags) { Assert-True ($optin[0] -match [regex]::Escape($f)) ("The opt-in no longer adds $f - the combination the flags were tested in changed.") }
    $elsewhere = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' -and $_ -match '(?i)-cef-single-process|-cef-disable-sandbox|-no-cef-sandbox' -and -not $_.Contains('"!' + $v + '!"=="Y"') })
    Assert-True ($elsewhere.Count -eq 0) ('A sandbox-off Steam flag appears outside the opt-in: ' + ($elsewhere -join ' | '))
    $ex = @(Get-BodyLines -Lines $cmd -Label 'Excluded') -join "`n"
    Assert-True ($ex -match '(?i)SteamLight') 'The "What was excluded" screen no longer names SteamLight''s single-process mode among the opt-in exceptions - it would claim every security-weakening change is left out.'
}

# ===============================================================================
# 129. Four maintenance actions report what happened. Windows Update reset,
#      Compact WinSxS and DISM + SFC printed "[OK] ... finished. See the output
#      above" whenever the window was elevated - but :Run swallows the output, so
#      there was nothing above to see - and Cleanup ended in "[OK] Cleanup done."
#      even when clearing the event logs, its one irreversible step, had failed.
#      Each now checks its own critical step. The reset's renames are checked
#      BEFORE the services start (they recreate the folders); DISM's exit code
#      decides DISM's line, 3010 counting as done; SFC's codes are undocumented,
#      so it is pointed to its own verdict rather than guessed at.
# ===============================================================================
Invoke-Test 'Maintenance actions report what happened, not a blanket [OK]' {
    $cmd = Read-Lines $CmdPath
    $next = {
        param([string[]]$Body, [string]$Pattern)
        for ($i = 0; $i -lt $Body.Count - 1; $i++) { if ($Body[$i] -match $Pattern) { return $Body[$i + 1].Trim() } }
        return $null
    }
    foreach ($r in 'WUReset', 'CompactWinSxS', 'SfcDism', 'Cleanup') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly)
        Assert-True ($b.Count -gt 5) ":$r is missing or truncated."
        Assert-True ((($b -join "`n") -notmatch '(?i)see the output above')) ":$r points at 'the output above' again - :Run swallows the output, so there is nothing there (regression)."
    }

    $wu = @(Get-BodyLines -Lines $cmd -Label 'WUReset' -CodeOnly) -join "`n"
    $iRen  = $wu.IndexOf('ren ""%SystemRoot%\SoftwareDistribution""')
    $iChk1 = $wu.IndexOf('if exist "%SystemRoot%\SoftwareDistribution\"')
    $iChk2 = $wu.IndexOf('if exist "%SystemRoot%\System32\catroot2\"')
    $iStart = $wu.IndexOf('call :Run "net start %%S"')
    Assert-True ($iRen -ge 0 -and $iStart -ge 0) ':WUReset lost its rename or its service restart - routine changed shape?'
    Assert-True ($iChk1 -gt $iRen -and $iChk2 -gt $iRen) ':WUReset no longer checks that SoftwareDistribution and catroot2 were actually renamed (regression).'
    Assert-True ($iChk1 -lt $iStart -and $iChk2 -lt $iStart) ':WUReset checks the renames AFTER the services start - they recreate both folders, so the check proves nothing there (regression).'
    Assert-True ($wu -match '(?i)if defined _wufail \(\s*\n\s*echo \[FAIL\]') ':WUReset has no [FAIL] branch for a rename that did not land.'
    Assert-True ($wu.IndexOf('if defined _wufail') -lt $wu.IndexOf('echo [OK] Windows Update reset')) ':WUReset prints [OK] before checking the renames (regression).'

    $cw = @(Get-BodyLines -Lines $cmd -Label 'CompactWinSxS' -CodeOnly)
    Assert-True ((& $next $cw 'call :Run "dism /online /cleanup-image /startcomponentcleanup"') -eq 'set "_cwrc=!_runrc!"') ':CompactWinSxS no longer captures DISM''s exit code straight after it runs.'
    Assert-True ((& $next $cw 'call :Run "compact\.exe /compactos:always"') -eq 'if /i "!_co!"=="Y" set "_corc=!_runrc!"') ':CompactWinSxS no longer captures CompactOS''s exit code straight after it runs.'
    $cwj = $cw -join "`n"
    Assert-True ($cwj -match '"!_cwrc!"=="3010"') ':CompactWinSxS no longer treats DISM''s 3010 (done, restart to finish) as success - it would report a failure that is not one.'
    Assert-True ($cwj -match '(?i)echo \[FAIL\] DISM component cleanup' -and $cwj -match '(?i)echo \[FAIL\] CompactOS') ':CompactWinSxS lost a [FAIL] line - a failed step would read as success (regression).'

    $sd = @(Get-BodyLines -Lines $cmd -Label 'SfcDism' -CodeOnly)
    Assert-True ((& $next $sd 'call :RunLive "dism /online /cleanup-image /restorehealth"') -eq 'set "_dismrc=!_runrc!"') ':SfcDism no longer captures DISM''s exit code straight after it runs.'
    $sdj = $sd -join "`n"
    Assert-True ($sdj -match '"!_dismrc!"=="3010"' -and $sdj -match '(?i)echo \[FAIL\] DISM RestoreHealth') ':SfcDism no longer maps DISM''s exit code to [OK] / [FAIL] (regression).'
    Assert-True ($sdj -notmatch '(?i)\[OK\] DISM \+ SFC finished') ':SfcDism prints the blanket "[OK] DISM + SFC finished" again (regression).'
    Assert-True ($sdj -match '(?i)SFC reports its own result') ':SfcDism no longer points to SFC''s own verdict - its exit codes are undocumented, so that is the only honest source.'

    $cl = @(Get-BodyLines -Lines $cmd -Label 'Cleanup' -CodeOnly)
    $clj = $cl -join "`n"
    # Pinned on the counting line itself: _evok / _evbad also appear where they are set to 0 and
    # reported, so their mere presence survived deleting the count (mutation-tested).
    Assert-True ($clj -match '(?i)wevtutil cl') ':Cleanup no longer clears the event logs - routine changed shape?'
    Assert-True ($clj -match '(?im)^\s*if "!_runrc!"=="0" \(set /a _evok\+=1\) else \(set /a _evbad\+=1\)\s*$') ':Cleanup no longer counts each event log by its own exit code (regression) - the report would print numbers nothing incremented.'
    Assert-True ($clj -match '(?i)echo\s+\[FAIL\] No event log could be cleared') ':Cleanup has no [FAIL] line for an event-log clear that did nothing.'
    Assert-True (@($cl | Where-Object { $_.Trim() -eq 'echo [OK] Cleanup done.' }).Count -eq 0) ':Cleanup ends in the unconditional "[OK] Cleanup done." again (regression).'
    Assert-True ($clj -match '(?i)echo \[WARN\] Cleanup ran without Administrator rights') ':Cleanup no longer says when it ran without the rights to clean the Windows folders.'
}

# ===============================================================================
# 130. Partial and failed results are reported as such (audit, low findings).
#      OneDrive's uninstaller returning non-zero printed [OK]; choosing Ultimate
#      silently activated High Performance when Ultimate was unavailable; the lock
#      finder said "free" when its Restart Manager query failed; a failed preset
#      JSON conversion showed the PREVIOUS preset's backup path; the backup prune
#      counted delete attempts as deletions; and the exit screen said "Log saved
#      to" when no log could be written.
# ===============================================================================
Invoke-Test 'Partial and failed results are reported as such' {
    $cmd = Read-Lines $CmdPath

    $od = @(Get-BodyLines -Lines $cmd -Label 'DebloatOneDrive' -CodeOnly) -join "`n"
    Assert-True ($od -match '(?i)else if not "!_odrc!"=="0" \(') ':DebloatOneDrive no longer separates a non-zero uninstaller exit from success - "[OK] ... uninstaller exit 1" is back (regression).'
    Assert-True ($od -notmatch '(?i)\[OK\][^\r\n]*uninstaller exit') ':DebloatOneDrive prints [OK] with the uninstaller exit code in it again (regression).'

    $sw = @(Get-BodyLines -Lines $cmd -Label 'DoPowerPlanSwitch' -CodeOnly) -join "`n"
    Assert-True ($sw -notmatch 'e9a42b02-d5df-448d-aa00-03f14749eb61 >nul 2>&1 \|\| powercfg') ':DoPowerPlanSwitch falls back from Ultimate to High silently again (|| on one line) (regression).'
    Assert-True ($sw -match '(?i)echo\s+\[WARN\] Ultimate Performance could not be activated') ':DoPowerPlanSwitch no longer says when High Performance was activated instead of Ultimate (regression).'

    $lw = @(Get-BodyLines -Lines $cmd -Label 'LockWorker' -CodeOnly) -join "`n"
    Assert-True ($lw -match 'RmStartSession\(\[ref\]\$h,0,\$key\) -ne 0\)\{ exit 4 \}') ':LockWorker no longer exits 4 when the Restart Manager session cannot start (regression).'
    Assert-True ($lw -match '\}catch\{ \$bad=\$true \}' -and $lw -match 'if\(\$bad\)\{ exit 4 \}; \$out \| Wu8 \$env:PT_LF_LIST') ':LockWorker writes a list after a failed query again - an empty list reads as "free" (regression).'
    Assert-True ($lw -notmatch '@\(\) \| (Out-File|Wu8)') ':LockWorker writes an empty list on failure again (regression).'
    $la = @(Get-BodyLines -Lines $cmd -Label 'LockFinder_ask' -CodeOnly) -join "`n"
    Assert-True ($la -match '(?i)if not exist "!_lflist!" goto _lfRecheckFail') ':LockFinder''s re-check no longer tells a failed query from "nothing holds the file" (regression).'

    $pe = @(Get-BodyLines -Lines $cmd -Label 'PresetEnd' -CodeOnly) -join "`n"
    Assert-True ($pe -match '(?i):_presetEndKeep[\s\S]*set "PRESET_LAST="[\s\S]*:_presetEndClear') ':PresetEnd no longer clears PRESET_LAST when the conversion fails - the next line names the previous preset''s backup (regression).'
    $shows = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match 'Registry backup: !PRESET_LAST!' })
    Assert-True ($shows.Count -ge 5) ('Expected the five preset screens to show the backup path, found {0}.' -f $shows.Count)
    Assert-True (@($shows | Where-Object { $_ -notmatch '^\s*if defined PRESET_LAST \(' }).Count -eq 0) 'A "Registry backup:" line prints PRESET_LAST without checking it is defined (regression).'

    $pr = @(Get-BodyLines -Lines $cmd -Label '_mbPrune' -CodeOnly)
    Assert-True (@($pr | Where-Object { $_.Trim() -eq 'set /a _delN+=1' }).Count -eq 0) ':_mbPrune counts a delete attempt as a deletion again (regression).'
    Assert-True (@($pr | Where-Object { $_ -match '(?i)^\s*if not exist "!BACKUP_DIR!\\!_prN!" set /a _delN\+=1' }).Count -eq 1) ':_mbPrune no longer counts only the files that are actually gone (regression).'

    $ex = @(Get-BodyLines -Lines $cmd -Label 'ExitScript' -CodeOnly) -join "`n"
    Assert-True ($ex -match '(?i)if exist "!LOGFILE!" \(echo   Log saved to:') ':ExitScript says "Log saved to" without checking the log exists (regression).'
    Assert-True ($ex -notmatch '(?im)^\s*echo\s+Log saved to:') ':ExitScript prints an unconditional "Log saved to" again (regression).'
}

# ===============================================================================
# 131. Small correctness fixes stay fixed (audit, low findings). The HKCU copy
#      of the Storage Sense policy did nothing - Microsoft's Policy CSP lists
#      AllowStorageSenseGlobal as device scope only - yet printed its own [REG]
#      line; `call :Log "... 5%%"` logged "5", because call parses its arguments
#      a second time; the debloat screen called Microsoft.Xbox.TCUI "the Xbox
#      game-bar component"; and %y% / %w% were used but never defined.
# ===============================================================================
Invoke-Test 'Small correctness fixes stay fixed' {
    $cmd = Read-Lines $CmdPath
    $code = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem\b|::)' })
    Assert-True ($code.Count -gt 1000) 'The script body was not read - the scans below would prove nothing.'

    $hkcu = @($code | Where-Object { $_ -match '(?i)"HKCU\\[^"]*StorageSense"\s+"AllowStorageSenseGlobal"' })
    Assert-True ($hkcu.Count -eq 0) 'AllowStorageSenseGlobal is written under HKCU again - the policy is device scope, so that write does nothing but print a [REG] line and leave a backup (regression).'
    Assert-True (@($code | Where-Object { $_ -match '(?i)"HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\StorageSense"\s+"AllowStorageSenseGlobal"' }).Count -eq 1) 'The machine-wide Storage Sense policy write is gone - routine changed shape?'

    $logPct = @($code | Where-Object { $_ -match '(?i)\bcall :Log "[^"]*%%' })
    Assert-True ($logPct.Count -eq 0) ('A call :Log argument holds %% - call parses its arguments a second time and the log loses the percent sign: ' + ($logPct -join ' | '))

    $dbo = @(Get-BodyLines -Lines $cmd -Label 'DebloatOpt') -join "`n"
    Assert-True ($dbo -match 'Microsoft\.Xbox\.TCUI') ':DebloatOpt no longer removes Microsoft.Xbox.TCUI - routine changed shape?'
    Assert-True ($dbo -notmatch '(?i)game-bar component') ':DebloatOpt calls Microsoft.Xbox.TCUI "the Xbox game-bar component" again - that is Microsoft.XboxGamingOverlay, which it does not remove (regression).'

    # The script defines no colour variables, so a short %x% / %xy% is always an undefined one.
    $short = @()
    foreach ($ln in $code) { foreach ($m in [regex]::Matches($ln, '(?<!%)%([A-Za-z][A-Za-z0-9]?)%(?!%)')) { $short += $m.Value } }
    $defined = @($short | Where-Object { $n = $_.Trim('%'); @($cmd | Where-Object { $_ -match ('(?i)^\s*set\s+"?' + [regex]::Escape($n) + '=') }).Count -gt 0 })
    Assert-True (@($short | Where-Object { $defined -notcontains $_ }).Count -eq 0) ('Short variable(s) used but never defined - they expand to nothing: ' + (($short | Sort-Object -Unique) -join ', '))
}

# ===============================================================================
# 132. Profile paths are read late everywhere. TEMP, LocalAppData, USERPROFILE,
#      the Documents / backup folder and every file built from them live under
#      the Windows user name, and a %X% read put such a path into its line before
#      delayed expansion ran - which ate a "!" in the name: "Bo!b" became "Bob"
#      (test 133 shows what that deleted). The set of profile-derived variables is
#      rebuilt from the script's own set lines, so a new one is covered the day it
#      is added. DOCS / BACKUP_DIR are captured with delayed expansion off, next to
#      SCRIPT_DIR; the routines that take a value as %~1 read it with delayed
#      expansion off; :CleanRoot and :InstallAsarInto take a name, not a path.
# ===============================================================================
Invoke-Test 'Profile paths are read late everywhere (a "!" in the user name survives)' {
    $cmd = Read-Lines $CmdPath
    $isCode = { param($s) $s.Trim() -notmatch '^(?i)(rem\b|::)' }
    $derived = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in 'TEMP','TMP','USERPROFILE','LOCALAPPDATA','APPDATA','HOMEPATH','ONEDRIVE','USERNAME','DOCS') { [void]$derived.Add($n) }
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($s in $cmd) {
            if (-not (& $isCode $s)) { continue }
            foreach ($m in [regex]::Matches($s, '(?i)\bset\s+"?([A-Za-z_]\w*)(\[[^\]]*\])?=(.*)')) {
                $n = $m.Groups[1].Value
                if ($derived.Contains($n)) { continue }
                foreach ($r in [regex]::Matches($m.Groups[3].Value, '[%!]([A-Za-z_]\w*)(\[[^\]]*\])?(?::[^%!]*)?[%!]')) {
                    if ($derived.Contains($r.Groups[1].Value)) { [void]$derived.Add($n); $grew = $true; break }
                }
            }
        }
    }
    Assert-True ($derived.Count -ge 50) ("Only {0} profile-derived variables were found - the scan is not seeing them, so the rest of this test proves nothing." -f $derived.Count)

    $iDE = [Array]::IndexOf($cmd, 'setlocal EnableDelayedExpansion')
    Assert-True ($iDE -gt 0) 'The top "setlocal EnableDelayedExpansion" is gone - the capture block changed shape.'
    $early = @()
    $late = 0
    for ($i = $iDE + 1; $i -lt $cmd.Count; $i++) {
        $s = $cmd[$i]
        if (-not (& $isCode $s)) { continue }
        foreach ($m in [regex]::Matches($s, '(?<!%)%([A-Za-z_]\w*)(?::[^%]*)?%(?!%)')) {
            if ($derived.Contains($m.Groups[1].Value)) { $early += ("line {0}: {1}" -f ($i + 1), $s.Trim()) }
        }
        foreach ($m in [regex]::Matches($s, '!([A-Za-z_]\w*)(?::[^!]*)?!')) { if ($derived.Contains($m.Groups[1].Value)) { $late++ } }
    }
    Assert-True ($late -ge 200) ("Only {0} late reads of profile paths were found - the scan is not seeing them." -f $late)
    Assert-True ($early.Count -eq 0) ("A profile path is read with %X% under delayed expansion - a ""!"" in the user name is eaten there: " + (($early | Select-Object -First 5) -join ' | '))

    # DOCS / BACKUP_DIR are captured with delayed expansion OFF, and only there
    $iDDE = [Array]::IndexOf($cmd, 'setlocal DisableDelayedExpansion')
    foreach ($v in 'DOCS', 'BACKUP_DIR') {
        $sets = @(for ($i = 0; $i -lt $cmd.Count; $i++) { if ((& $isCode $cmd[$i]) -and $cmd[$i] -match ('(?i)^\s*(call\s+)?set\s+"' + $v + '=')) { $i } })
        Assert-True ($sets.Count -ge 1) "$v is never set - the capture changed shape."
        Assert-True (@($sets | Where-Object { $_ -lt $iDDE -or $_ -gt $iDE }).Count -eq 0) ("$v is set outside the delayed-expansion-off capture block (line {0}) - a ""!"" in the Documents path would be eaten there (regression)." -f (($sets | Where-Object { $_ -lt $iDDE -or $_ -gt $iDE } | Select-Object -First 1) + 1))
    }

    # the routines that take a value as %~1 read it with delayed expansion off, then only late
    foreach ($r in 'Log', 'Run', 'RunLive') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly)
        $j = -1
        for ($k = 0; $k -lt $b.Count - 2; $k++) {
            if ($b[$k].Trim() -eq 'setlocal DisableDelayedExpansion' -and $b[$k + 1] -match '^\s*set "_\w+=%~1"\s*$' -and $b[$k + 2].Trim() -eq 'setlocal EnableDelayedExpansion') { $j = $k; break }
        }
        Assert-True ($j -ge 0) ":$r no longer reads %~1 with delayed expansion off - a ""!"" in the path it is given is eaten (regression)."
        Assert-True (@($b | Where-Object { $_ -match '%_cmd(log)?(:[^%]*)?%' }).Count -eq 0) ":$r reads its command with %_cmd% again - that puts it into the line before delayed expansion runs (regression)."
    }
    $lw = @(Get-BodyLines -Lines $cmd -Label '_LogWrite' -CodeOnly) -join "`n"
    Assert-True ($lw -match '>>"!LOGFILE!"') ':_LogWrite no longer writes to !LOGFILE! - with %LOGFILE% the log goes to another user''s Documents (regression).'
    foreach ($r in 'Run', 'RunLive') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly) -join "`n"
        Assert-True ($b -match '(?m)^endlocal & endlocal & set "_runrc=%_runrc%" & set "_FAILS=%_FAILS%"\s*$') ":$r no longer hands back only the exit code and the failure tally across its two endlocals."
    }

    # :CleanRoot and :InstallAsarInto take a name, not a path
    $cr = @(Get-BodyLines -Lines $cmd -Label 'CleanRoot' -CodeOnly) -join "`n"
    Assert-True ($cr -match 'set "_crv=!%~1!"') ':CleanRoot no longer reads the root late from its NAME (regression).'
    Assert-True (@($cmd | Where-Object { (& $isCode $_) -and $_ -match '(?i)call :CleanRoot \w+\s+"' }).Count -eq 0) 'A caller hands :CleanRoot the path itself again - a "!" in it is lost in %~2 (regression).'
    $ia = @(Get-BodyLines -Lines $cmd -Label 'InstallAsarInto' -CodeOnly) -join "`n"
    Assert-True ($ia -match '(?i)set "_base=!LOCALAPPDATA!\\%~1"') ':InstallAsarInto no longer builds its base folder late from LOCALAPPDATA (regression).'
    Assert-True (@($cmd | Where-Object { (& $isCode $_) -and $_ -match '(?i)call :InstallAsarInto "[^"]*"\s+"' }).Count -eq 0) 'A caller hands :InstallAsarInto a path again - a "!" in LocalAppData is lost in %~1 (regression).'
}

# ===============================================================================
# 133. A "!", "%", "^" or "&" in the user name reaches the user's own folders -
#      RUN, not read. With every profile path read as %X% under delayed expansion,
#      a user "Bo!b" had the cleanup delete the temp files of a user "Bob", if one
#      existed, and write the log into Bob's Documents; sincript runs elevated, so
#      nothing stopped it. A "&" did worse: the old :Run cut every delete at the
#      "&", so for "Bob & Co" it ran on C:\Users\Bob instead and emptied that
#      profile, hidden files too. A "%" was lost where the path rode a call
#      argument, so "Bo%b & Co" cleaned "Bob & Co"; a "^" was doubled there, so
#      nothing was cleaned. This runs the real :DoCleanupCore, :CleanRoot, :RunVar,
#      :Run, :Log and :LogVar for the users "Bo!b & Co", "Bo%b & Co" and
#      "Bo^b & Co", each in a fake profile tree under %TEMP% next to "Bob & Co"
#      and "Bob" (where the old code landed). TEMP, LocalAppData and SystemRoot all
#      point inside the tree, the driver refuses to run unless they do, and it runs
#      in the tree. The tree's path may hold no space, because a cut path would
#      split there as well. The driver takes the backup folder from USERPROFILE,
#      never from its own text, where a "%" would be lost. ipconfig /flushdns and
#      the free-space probes are stubbed out.
# ===============================================================================
Invoke-Test 'A "!", "%", "^" or "&" in the user name reaches the user''s own folders (cleanup run in a fake profile)' {
    # TEMP is usually LocalAppData\Temp under its 8.3 short name: that folder is cleaned once, not twice
    $cc0 = @(Get-BodyLines -Lines (Read-Lines $CmdPath) -Label 'DoCleanupCore' -CodeOnly) -join "`n"
    Assert-True ($cc0 -match 'if /i "%%~fsA"=="%%~fsB" set "_tmpsame=1"' -and $cc0 -match 'if defined _cleanTEMP if not defined _tmpsame \(') ':DoCleanupCore deletes TEMP again when it is LocalAppData\Temp under its short name (regression).'
    $cmd = Read-Lines $CmdPath
    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '\s') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    Assert-True ($tmp -notmatch '\s') ("test 133 cannot run safely here: the temp folder path holds a space and has no short name ({0})." -f $tmp)
    $base = Join-Path $tmp ('PT133_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    # a routine: from ":Label" to the next label that is not one of its own (listed) sub-labels
    $grab = {
        param([string]$Label, [string[]]$Own)
        $i = [Array]::IndexOf($cmd, ':' + $Label)
        if ($i -lt 0) { throw "test 133: :$Label not found." }
        $j = $i + 1
        while ($j -lt $cmd.Count) {
            if ($cmd[$j] -match '^:(\w+)' -and -not ($Own -contains $Matches[1])) { break }
            $j++
        }
        $cmd[$i..($j - 1)]
    }
    $core = @(& $grab 'DoCleanupCore' @('_clCoreBody') | ForEach-Object { $_ -replace 'call :Run "ipconfig /flushdns"', 'rem (flushdns stubbed)' })
    $body = @('@echo off', 'setlocal DisableDelayedExpansion', 'set "BACKUP_DIR=%USERPROFILE%\Documents\PerfTweaks_Backups"',
              'setlocal EnableDelayedExpansion', 'set "LOGFILE=!BACKUP_DIR!\PerfTweaks_t133.log"', 'set "_CLEAN_OUTER=1"', 'set "_ELEV=1"',
              'for %%V in (TEMP LocalAppData SystemRoot) do if "!%%V:PT133_=!"=="!%%V!" (echo refusing: %%V is outside the fake tree& exit /b 99)',
              'call :DoCleanupCore', 'exit /b 0') +
            $core + @(& $grab 'CleanRoot' @()) + @(& $grab 'RunVar' @()) + @(& $grab 'Run' @('_runBody', '_runLate', '_runRc')) +
            @(& $grab 'Log' @()) + @(& $grab '_LogWrite' @()) + @(& $grab 'LogVar' @()) +
            @(':FreeSpaceSnap', 'exit /b 0', ':FreeSpaceReport', 'exit /b 0')
    try {
        $k = 0
        foreach ($name in 'Bo!b & Co', 'Bo%b & Co', 'Bo^b & Co') {
            $k++
            $root = Join-Path $base $k
            $user = Join-Path $root ('Users\' + $name)
            $other = Join-Path $root 'Users\Bob & Co'
            $bob = Join-Path $root 'Users\Bob'
            foreach ($u in $user, $other) {
                foreach ($sub in 'AppData\Local\Temp', 'AppData\Local\Microsoft\Windows\Explorer', 'Documents\PerfTweaks_Backups') {
                    [void](New-Item -ItemType Directory -Force -Path (Join-Path $u $sub))
                }
                [System.IO.File]::WriteAllText((Join-Path $u 'AppData\Local\Temp\tmp.txt'), 'x')
                [System.IO.File]::WriteAllText((Join-Path $u 'AppData\Local\Microsoft\Windows\Explorer\thumbcache_1.db'), 'x')
            }
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $bob 'Documents'))
            [System.IO.File]::WriteAllText((Join-Path $bob 'Documents\thesis.docx'), 'x')
            [System.IO.File]::WriteAllText((Join-Path $bob 'hidden.ini'), 'x')
            [System.IO.File]::SetAttributes((Join-Path $bob 'hidden.ini'), [System.IO.FileAttributes]::Hidden)
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'Windows\Temp'))
            $drv = Join-Path $root 'drv.cmd'
            [System.IO.File]::WriteAllLines($drv, [string[]]$body, [System.Text.Encoding]::ASCII)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $psi.Arguments = '/d /c "' + $drv + '"'
            $psi.WorkingDirectory = $root
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['USERPROFILE'] = $user
            $psi.EnvironmentVariables['TEMP'] = Join-Path $user 'AppData\Local\Temp'
            $psi.EnvironmentVariables['TMP'] = Join-Path $user 'AppData\Local\Temp'
            $psi.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $user 'AppData\Local'
            $psi.EnvironmentVariables['SystemRoot'] = Join-Path $root 'Windows'
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $err = $p.StandardError.ReadToEndAsync()
            $out = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(120000)) { $p.Kill(); throw ('test 133: the cleanup driver for "{0}" did not finish within 120 s.' -f $name) }
            Assert-True ($p.ExitCode -ne 99) ('test 133 refused to run for "{0}" - a root was outside the fake tree: {1}' -f $name, $out.Trim())
            Assert-True ($p.ExitCode -eq 0) ('The cleanup driver for "{0}" failed (exit {1}): {2} {3}' -f $name, $p.ExitCode, $out.Trim(), $err.Result.Trim())
            $ownLeft = @(Get-ChildItem -LiteralPath $user -Recurse -File | Where-Object { $_.Extension -in '.txt', '.db' })
            $otherLeft = @(Get-ChildItem -LiteralPath $other -Recurse -File | Where-Object { $_.Extension -in '.txt', '.db' })
            Assert-True ($otherLeft.Count -eq 2) ('Cleanup for "{0}" deleted files of ANOTHER user ("Bob & Co") - part of the name was lost and the path pointed at the wrong profile (regression). Left there: {1}' -f $name, (($otherLeft | ForEach-Object Name) -join ', '))
            $bobLeft = @(Get-ChildItem -LiteralPath $bob -Recurse -File -Force)
            Assert-True ($bobLeft.Count -eq 2) ('Cleanup for "{0}" emptied ANOTHER profile ("Bob") - a delete was cut at the "&" and ran on ...\Users\Bob instead (regression). Left there: {1}' -f $name, (($bobLeft | ForEach-Object Name) -join ', '))
            Assert-True ($ownLeft.Count -eq 0) ('Cleanup did not clean the own folders of "{0}" - a special character in the name broke the delete (regression). Left: {1}' -f $name, (($ownLeft | ForEach-Object Name) -join ', '))
            $log = Join-Path $user 'Documents\PerfTweaks_Backups\PerfTweaks_t133.log'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $other 'Documents\PerfTweaks_Backups\PerfTweaks_t133.log'))) ('The log for "{0}" was written into ANOTHER user''s Documents (regression).' -f $name)
            Assert-True (Test-Path -LiteralPath $log) ('The log for "{0}" was not written into the user''s own backup folder (regression).' -f $name)
            Assert-True ((Get-Content -LiteralPath $log -Raw) -match [regex]::Escape($name)) ('The log lost part of the user name "{0}" in the paths it recorded - a call argument parsed it a second time (regression).' -f $name)
        }
        Assert-True ($k -eq 3) 'test 133 did not run all three user names.'
    }
    finally {
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
    }
}

# ===============================================================================
# 134. No path under the profile or the script's folder rides a call argument, so
#      a "%" or "^" in the user name survives. call parses its arguments a second
#      time: it swallows a "%" and doubles a quoted "^" - for a user "Bo%b" the
#      cleanup deletes pointed at C:\Users\Bob and the log said "Bob". Such values
#      go by name instead: :RunVar for commands (its child cmd expands the command
#      late, /v:on), :LogVar for log lines. The Documents capture keeps its
#      "call set" only for a value the registry returned unexpanded (test 135 runs
#      it). The variables are rebuilt from the script's own set lines, as in 132,
#      with the script's own folder added - it usually sits under the profile too.
# ===============================================================================
Invoke-Test 'No profile path rides a call argument (a "%" or "^" in the user name survives)' {
    $cmd = Read-Lines $CmdPath
    $isCode = { param($s) $s.Trim() -notmatch '^(?i)(rem\b|::)' }
    $derived = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in 'TEMP','TMP','USERPROFILE','LOCALAPPDATA','APPDATA','HOMEPATH','ONEDRIVE','USERNAME','DOCS','SCRIPT_DIR','_SELFPATH') { [void]$derived.Add($n) }
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($s in $cmd) {
            if (-not (& $isCode $s)) { continue }
            foreach ($m in [regex]::Matches($s, '(?i)\bset\s+"?([A-Za-z_]\w*)(\[[^\]]*\])?=(.*)')) {
                $n = $m.Groups[1].Value
                if ($derived.Contains($n)) { continue }
                # a value read by NAME ("!%~1!", as :CleanRoot reads a root) can be any of them
                if ($m.Groups[3].Value -match '!%~?[0-9]!') { [void]$derived.Add($n); $grew = $true; continue }
                foreach ($r in [regex]::Matches($m.Groups[3].Value, '[%!]([A-Za-z_]\w*)(\[[^\]]*\])?(?::[^%!]*)?[%!]')) {
                    if ($derived.Contains($r.Groups[1].Value)) { [void]$derived.Add($n); $grew = $true; break }
                }
            }
        }
    }
    Assert-True ($derived.Count -ge 50) ("Only {0} path variables were found - the scan is not seeing them, so the rest of this test proves nothing." -f $derived.Count)

    $capture = 'if "%DOCS:~0,1%"=="%%" call set "DOCS=%DOCS%"'
    $calls = 0
    $bad = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $s = $cmd[$i]
        if (-not (& $isCode $s) -or $s.Trim() -eq $capture) { continue }
        foreach ($m in [regex]::Matches($s, '(?i)(?:^|[\s(&|])call\s+(\S+)(.*)')) {
            $calls++
            foreach ($r in [regex]::Matches($m.Groups[2].Value, '[%!]([A-Za-z_]\w*)(?:\[[^\]]*\])?(?::[^%!]*)?[%!]')) {
                if ($derived.Contains($r.Groups[1].Value)) { $bad += ("line {0}: {1}" -f ($i + 1), $s.Trim()); break }
            }
        }
    }
    Assert-True ($calls -ge 400) ("Only {0} call statements were found - the scan is not seeing them." -f $calls)
    Assert-True ($bad.Count -eq 0) ('A path under the profile or the script''s folder rides a call argument - call parses it a second time and loses a "%" in the user name: ' + (($bad | Select-Object -First 5) -join ' | '))

    # the capture calls "call set" only for an unexpanded value, and nothing else uses call set
    $cs = @($cmd | Where-Object { (& $isCode $_) -and $_ -match '(?i)\bcall\s+set\b' })
    Assert-True ($cs.Count -eq 1 -and $cs[0].Trim() -eq $capture) ('The Documents capture no longer limits "call set" to an unexpanded registry value - an expanded path loses a "%" in the user name there (regression): ' + ($cs -join ' | '))

    # :RunVar and :LogVar take a NAME and read it late; the child cmd gets the command unparsed
    $rv = @(Get-BodyLines -Lines $cmd -Label 'RunVar' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($rv -contains 'set "_cmd=!%~1!"' -and $rv -contains 'set "_runlate=1"' -and $rv -contains 'goto _runBody') ':RunVar no longer reads its command by name and joins the body of :Run (regression).'
    $run = @(Get-BodyLines -Lines $cmd -Label 'Run' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($run -contains 'set "_runlate="' -and $run -contains 'if defined _runlate goto _runLate') ':Run no longer keeps its own commands on the re-parsing child and :RunVar''s on the late one (regression).'
    Assert-True ($run -contains 'cmd /d /v:on /s /c "^!_cmd^!" >nul 2>&1') ':RunVar''s command no longer reaches the child cmd unparsed - "^!_cmd^!" with /v:on lets the child expand it late (regression).'
    $lv = @(Get-BodyLines -Lines $cmd -Label 'LogVar' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($lv -contains 'set "_LOGLN=!%~1!"' -and $lv -contains 'call :_LogWrite 2>nul') ':LogVar no longer copies its message by name into :_LogWrite (regression).'
    foreach ($r in 'Run', 'RunLive') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly) -join "`n"
        Assert-True ($b -notmatch '(?i)\bcall :Log\b') (":$r logs its command through a call argument again - a ""%"" in it is lost there (regression).")
        Assert-True (([regex]::Matches($b, '(?i)call :LogVar _runlog')).Count -eq 3) (":$r no longer logs EXEC, FAIL and OK by name.")
    }

    # the deletes under the profile go through :RunVar
    $core = @(Get-BodyLines -Lines $cmd -Label 'DoCleanupCore' -CodeOnly) -join "`n"
    foreach ($p in '!TEMP!\*.*', '!LocalAppData!\Temp\*.*', '!LocalAppData!\Microsoft\Windows\Explorer\*.db', '!LocalAppData!\Microsoft\Windows\WebCache\*.*', '!LocalAppData!\CrashDumps\*.*') {
        Assert-True ($core -match ('set "_runcmd=del [^"]*"' + [regex]::Escape($p) + '"" & call :RunVar _runcmd\)')) ("The :DoCleanupCore delete of $p no longer goes to :RunVar by name (regression).")
    }
}

# ===============================================================================
# 135. The Documents capture keeps a "!", "%", "^" and "&" in the user name - RUN,
#      not read. Its "call set" once took every value, and call parses its
#      arguments a second time: for a user "Bo%b" the backups and the log went to
#      C:\Users\Bob\Documents. This runs the script's own capture lines, with the
#      registry answer faked by a file: an unexpanded "%USERPROFILE%\Documents"
#      (call set must expand it), expanded paths holding the special characters or
#      a "%OS%" (it must leave them alone), and no answer at all.
# ===============================================================================
Invoke-Test 'The Documents capture keeps "!", "%", "^" and "&" in the user name (run with a faked registry)' {
    $cmd = Read-Lines $CmdPath
    $i0 = [Array]::IndexOf($cmd, 'set "DOCS=%USERPROFILE%\Documents"')
    $i1 = [Array]::IndexOf($cmd, 'set "BACKUP_DIR=%DOCS%\PerfTweaks_Backups"')
    Assert-True ($i0 -gt 0 -and $i1 -gt $i0 -and ($i1 - $i0) -lt 12) 'The Documents capture changed shape - test 135 cannot find it.'
    $reg = '''reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Personal 2^>nul ^| findstr /I "Personal"'''
    $block = @($cmd[$i0..$i1])
    Assert-True (@($block | Where-Object { $_.Contains($reg) }).Count -eq 1) 'The capture no longer asks the registry the way test 135 fakes it.'
    # the fake answer's path is written into the driver's text, where a "%" would be lost
    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '[\s%]') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT135_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Assert-True ($dir -notmatch '%') ("test 135 cannot run here: the temp folder path holds a ""%"" and has no short name ({0})." -f $dir)
    $prof = Join-Path $dir 'Users\Bo!b %x^y & Co'
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        $fake = Join-Path $dir 'reg.txt'
        $drv = Join-Path $dir 'drv.cmd'
        $lines = @('@echo off', 'setlocal DisableDelayedExpansion') + @($block | ForEach-Object { $_.Replace($reg, "'type ""$fake""'") }) +
                 @('setlocal EnableDelayedExpansion', 'echo [!BACKUP_DIR!]')
        [System.IO.File]::WriteAllLines($drv, [string[]]$lines, [System.Text.Encoding]::ASCII)
        $cases = @(
            @('%USERPROFILE%\Documents', "$prof\Documents"),
            @("$prof\Documents", "$prof\Documents"),
            @('D:\Sync\50%OS%x\Documents', 'D:\Sync\50%OS%x\Documents'),
            @('', "$prof\Documents"))
        foreach ($c in $cases) {
            $answer = if ($c[0]) { "`r`n    Personal    REG_SZ    " + $c[0] + "`r`n" } else { '' }
            [System.IO.File]::WriteAllText($fake, $answer, [System.Text.Encoding]::ASCII)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $psi.Arguments = '/d /c "' + $drv + '"'
            $psi.WorkingDirectory = $dir
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['USERPROFILE'] = $prof
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $err = $p.StandardError.ReadToEndAsync()
            $out = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'test 135: the capture driver did not finish within 60 s.' }
            $got = @($out -split "`r?`n" | Where-Object { $_.StartsWith('[') })
            $want = '[' + $c[1] + '\PerfTweaks_Backups]'
            Assert-True ($got.Count -eq 1 -and $got[0] -eq $want) ('The Documents capture turned the registry answer "{0}" into {1}, not {2} (regression). {3}' -f $c[0], ($got -join ' '), $want, $err.Result.Trim())
        }
    }
    finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

# ===============================================================================
# 136. The DNS screen states its real undo and lists every typed-in resolver,
#      named by adapter, IPv4 and IPv6 - RUN with a faked registry. It said
#      "Fully reversible." while the only way back is option 4 (DHCP), which
#      keeps nothing the user typed in, and its one "Currently set" line kept
#      only the LAST NameServer the /s scan printed: on a real machine that was
#      a Wi-Fi Direct adapter's value, and it hid the router address on the
#      adapter actually in use. An unreadable registry must give a [WARN], never
#      "none - DHCP", and a value it cannot name must be counted, not hidden.
# ===============================================================================
Invoke-Test 'The DNS screen states its real undo and lists every typed-in resolver (run with a faked registry)' {
    $cmd = Read-Lines $CmdPath
    $menu = @(Get-BodyLines -Lines $cmd -Label 'MenuDns' -CodeOnly)
    $menuEcho = @($menu | Where-Object { $_.Trim() -match '^(?i)echo\b' }) -join "`n"
    Assert-True ($menu.Count -gt 5 -and $menuEcho.Length -gt 200) ':MenuDns did not unroll, or lost its text.'
    Assert-True ($menuEcho -match '(?i)option 4' -and $menuEcho -cmatch 'NOT saved') ':MenuDns no longer says that option 4 (DHCP) is the undo and that a typed-in server is NOT saved (regression).'
    Assert-True ($menuEcho -notmatch '(?i)fully reversible') ':MenuDns claims "Fully reversible." again - option 4 goes back to DHCP and a typed-in resolver is saved nowhere (regression).'
    Assert-True ($menuEcho -match '(?i)physical') ':MenuDns no longer says it changes the physical adapters (connected or not) and leaves virtual ones alone.'
    $iShow = -1; $iOpt = -1
    for ($i = 0; $i -lt $menu.Count; $i++) {
        if ($iShow -lt 0 -and $menu[$i] -match '(?i)^\s*call :ShowCurrentDns\s*$') { $iShow = $i }
        if ($iOpt -lt 0 -and $menu[$i] -match '^echo\s+1\.\s') { $iOpt = $i }
    }
    Assert-True ($iShow -ge 0 -and $iOpt -gt $iShow) ':MenuDns no longer lists the typed-in resolvers BEFORE offering to replace them (regression).'
    # the preset DNS picker replaces them too, so it lists them first as well
    $pd = @(Get-BodyLines -Lines $cmd -Label 'PresetDnsChoice' -CodeOnly)
    $iShow = -1; $iAsk = -1
    for ($i = 0; $i -lt $pd.Count; $i++) {
        if ($iShow -lt 0 -and $pd[$i] -match '(?i)^\s*call :ShowCurrentDns\s*$') { $iShow = $i }
        if ($iAsk -lt 0 -and $pd[$i] -match '(?i)set /p "_dc=') { $iAsk = $i }
    }
    Assert-True ($iShow -ge 0 -and $iAsk -gt $iShow) ':PresetDnsChoice replaces the DNS servers without listing the current ones first (regression).'
    Assert-True ((@($pd | Where-Object { $_.Trim() -match '^(?i)echo\b' }) -join "`n") -match '(?i)keeps them') ':PresetDnsChoice no longer says that 4 (skip) keeps the servers it just listed.'
    foreach ($r in 'ApplyDns', 'DnsAuto') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly)
        $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)echo\b' }) -join "`n"
        Assert-True ($code -match '(?i)Get-NetAdapter -Physical') ":$r no longer selects Get-NetAdapter -Physical - make its screen text match what it changes now."
    }
    foreach ($r in 'ApplyDns', 'DnsAuto', 'DnsResult') {
        $echo = @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly | Where-Object { $_ -match '(?i)(^|\s)echo(\s|\.)' }) -join "`n"
        Assert-True ($echo -match '(?i)physical') ":$r lost its text, or no longer names the physical adapters it works on."
        Assert-True ($echo -notmatch '(?i)\bactive (network )?adapter') ":$r says 'active adapter' again, but -Physical includes disconnected adapters and skips VPN ones (regression)."
    }
    $scd = (@('ShowCurrentDns', '_scdScan', '_scdShow', '_scdTrim') | ForEach-Object { Get-BodyLines -Lines $cmd -Label $_ -CodeOnly }) -join "`n"
    Assert-True ($scd -match '(?i)Tcpip\\Parameters\\Interfaces' -and $scd -match '(?i)Tcpip6\\Parameters\\Interfaces') ':ShowCurrentDns no longer reads both the IPv4 and the IPv6 interface keys (regression).'
    Assert-True ($scd -notmatch '(?i)powershell') ':ShowCurrentDns starts PowerShell on every DNS menu draw - measured 1.9 s just to start, 4.7 s with Get-NetAdapter.'
    Assert-True ($scd -notmatch '(?i)dnsservers') ':ShowCurrentDns parses localized netsh output (pitfall 26).'

    # ---- run it: each reg query becomes a "type" of a fake answer. The folder travels in an
    #      environment variable, read late, so a "^", "&" or "!" in the temp path stays data.
    $i0 = [Array]::IndexOf($cmd, ':ShowCurrentDns')
    Assert-True ($i0 -ge 0) ':ShowCurrentDns not found.'
    $j = $i0 + 1
    while ($j -lt $cmd.Count -and -not ($cmd[$j] -match '^:' -and $cmd[$j] -notmatch '^:_scd')) { $j++ }
    $routine = @($cmd[$i0..($j - 1)])
    Assert-True (@($routine | Where-Object { $_ -match '^:_scd(Scan|Show|Trim)\s*$' }).Count -eq 3) 'The listing''s helpers moved away from :ShowCurrentDns - test 136 cannot extract them.'
    $scan = '''reg query "!_scdRoot!" /s /v NameServer 2^>nul'''
    $name = '''reg query "HKLM\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}\!_scdGuid!\Connection" /v Name 2^>nul'''
    foreach ($c in $scan, $name) {
        Assert-True (@($routine | Where-Object { $_.Contains($c) }).Count -eq 1) ('The listing no longer asks the registry the way test 136 fakes it: ' + $c)
    }
    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '[\s%]') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT136_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Assert-True ($dir -notmatch '%') ('test 136 cannot run here: the temp folder path holds a "%" and has no short name ({0}).' -f $dir)
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        $body = $routine | ForEach-Object { $_.Replace($scan, '''type "!PT136_DIR!\scan_!_scdFam!.txt" 2^>nul''').Replace($name, '''type "!PT136_DIR!\name_!_scdGuid!.txt" 2^>nul''') }
        $drv = Join-Path $dir 'drv.cmd'
        [System.IO.File]::WriteAllLines($drv, [string[]](@('@echo off', 'setlocal EnableDelayedExpansion', 'call :ShowCurrentDns', 'exit /b 0') + $body), [System.Text.Encoding]::ASCII)
        $run = {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
            # /s and doubled quotes: with plain /c "...", cmd strips the quotes when the path holds
            # an & or ^, and the path then splits (measured with a TEMP named c^d&e!f).
            $psi.Arguments = '/d /s /c ""' + $drv + '""'
            $psi.WorkingDirectory = $dir
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['PT136_DIR'] = $dir
            $p = [System.Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
            $err = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'test 136: the listing driver did not finish within 30 s.' }
            [pscustomobject]@{ Lines = @($out -split "`r?`n" | Where-Object { $_ -ne '' }); Err = $err.Result.Trim() }
        }
        $k4 = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\'
        $k6 = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\'
        $kn = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}\'
        $g1 = '{11111111-0136-4136-8136-000000000001}'   # live adapter, nothing typed in
        $g2 = '{22222222-0136-4136-8136-000000000002}'   # adapter in use: IPv4, and IPv6 padded with spaces
        $g3 = '{33333333-0136-4136-8136-000000000003}'   # per-network record nested under g2
        $g4 = '{44444444-0136-4136-8136-000000000004}'   # removed adapter - sorts LAST, as on the real machine
        $w = { param($f, $t) [System.IO.File]::WriteAllText((Join-Path $dir $f), $t, [System.Text.Encoding]::ASCII) }
        & $w "name_$g1.txt" ("`r`n$kn$g1\Connection`r`n    Name    REG_SZ    Ethernet`r`n")
        & $w "name_$g2.txt" ("`r`n$kn$g2\Connection`r`n    Name    REG_SZ    Wi-Fi (home) & Co`r`n")
        $cases = @(
            @('every typed-in value, named by adapter, with the unnamed ones counted',
              ("`r`n$k4$g1`r`n    NameServer    REG_SZ    `r`n`r`n$k4$g2`r`n    NameServer    REG_SZ    8.8.8.8,9.9.9.9,192.168.0.1`r`n`r`n$k4$g2\$g3`r`n    NameServer    REG_SZ    10.9.9.9`r`n`r`n$k4$g4`r`n    NameServer    REG_SZ    10.1.1.1`r`n`r`nEnd of search: 4 match(es) found.`r`n"),
              ("`r`n$k6$g2`r`n    NameServer    REG_SZ    fd00::53,fd00::54        `r`n`r`nEnd of search: 1 match(es) found.`r`n"),
              @(' DNS servers typed in by hand, per adapter - write down any you want to keep:',
                '   IPv4  8.8.8.8,9.9.9.9,192.168.0.1   (Wi-Fi (home) & Co)',
                '   IPv6  fd00::53,fd00::54   (Wi-Fi (home) & Co)',
                '   (not shown: 2 stored for no adapter in Network Connections now)')),
            @('nothing typed in on any adapter',
              ("`r`n$k4$g1`r`n    NameServer    REG_SZ    `r`n`r`n$k4$g2`r`n    NameServer    REG_SZ    `r`n"), '',
              @(' DNS servers typed in by hand: none - every adapter gets its DNS from DHCP.')),
            @('a value only on a removed adapter',
              ("`r`n$k4$g1`r`n    NameServer    REG_SZ    `r`n`r`n$k4$g4`r`n    NameServer    REG_SZ    10.1.1.1`r`n"), '',
              @(' DNS servers typed in by hand: none on a current adapter. Not shown: 1 stored for no',
                ' adapter in Network Connections now (removed adapters, per-network records).')),
            # nothing skipped: the "(not shown: N ...)" note must stay away, not read "0"
            @('values only on current adapters',
              ("`r`n$k4$g1`r`n    NameServer    REG_SZ    `r`n`r`n$k4$g2`r`n    NameServer    REG_SZ    192.168.0.1`r`n"), '',
              @(' DNS servers typed in by hand, per adapter - write down any you want to keep:',
                '   IPv4  192.168.0.1   (Wi-Fi (home) & Co)')),
            @('a registry read that printed nothing', '', '',
              @(' [WARN] Could not read the IPv4 DNS settings from the registry, so they are not listed.',
                '        Note your DNS servers in Windows'' network settings before changing anything.')))
        foreach ($c in $cases) {
            & $w 'scan_IPv4.txt' $c[1]
            & $w 'scan_IPv6.txt' $c[2]
            $r = & $run
            Assert-True (($r.Lines -join "`n") -ceq ($c[3] -join "`n")) ('With {0}, the DNS listing printed [{1}], not [{2}] (regression). {3}' -f $c[0], ($r.Lines -join ' | '), ($c[3] -join ' | '), $r.Err)
        }
    }
    finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

# ===============================================================================
# 137. The power revert screen names, on screen, every power change its undo
#      file does not cover, and the file captures hibernation. It said
#      "Hibernation and CPU power throttling are the separate items - see
#      'Reverting changes' in the README", whose table had no hibernation row -
#      and the README is not on the machine the menu runs on. Hibernation is now
#      captured before it is turned off (test 126 runs that capture six ways),
#      and the capture's failure [WARN] names the one command that brings it back.
#      When that capture fails, :SetMinProcState retries it later on the same
#      visit, and the retry read sincript's own "off" as "already off before
#      sincript": a flag, handed to the payload as PT_HBOFF, now stops that.
# ===============================================================================
Invoke-Test 'The power revert screen names what its undo file does not cover, and hibernation is captured first' {
    $cmd = Read-Lines $CmdPath
    $rp = @(Get-BodyLines -Lines $cmd -Label 'RestorePowerBackup' -CodeOnly)
    $rpEcho = @($rp | Where-Object { $_.Trim() -match '^(?i)echo\b' }) -join "`n"
    Assert-True ($rpEcho.Length -gt 200) ':RestorePowerBackup did not unroll, or lost its text.'
    Assert-True ($rpEcho -match '(?i)powercfg /hibernate on') ':RestorePowerBackup no longer says how to turn hibernation back on when the file cannot (regression).'
    Assert-True ($rpEcho -match '(?i)could not read it') ':RestorePowerBackup no longer says that a file which could not read hibernation does not restore it.'
    Assert-True ($rpEcho -match '(?i)its earlier\s+(echo\s+)?state is unknown') ':RestorePowerBackup no longer says that a file which calls the earlier hibernation state unknown does not restore it.'
    Assert-True ($rpEcho -match '(?i)Restore a single value backup') ':RestorePowerBackup no longer points CPU power throttling at its value backup (regression).'
    Assert-True ($rpEcho -notmatch '(?i)README') ':RestorePowerBackup sends the user to the README for an undo again (regression).'
    $pw = @(Get-BodyLines -Lines $cmd -Label 'Power' -CodeOnly)
    $iHb = -1
    for ($i = 0; $i -lt $pw.Count; $i++) { if ($pw[$i] -match '(?i)set /p "_hb=') { $iHb = $i; break } }
    Assert-True ($iHb -gt 0) ':Power lost its hibernation prompt - routine changed shape?'
    Assert-True ($pw[$iHb - 1] -match '(?i)^\s*echo\b.*(hibernate on|undo file)') ':Power asks to disable hibernation without saying, right above the question, how it is undone (regression).'
    $iCap = -1; $offs = @()
    for ($i = 0; $i -lt $pw.Count; $i++) {
        if ($pw[$i].Trim() -match '^(?i)echo\b') { continue }
        if ($iCap -lt 0 -and $pw[$i] -match '^\s*if /i "!_hb!"=="Y" call :PowerBackup\s*$') { $iCap = $i }
        if ($pw[$i] -match '(?i)powercfg /hibernate off') { $offs += $i }
    }
    Assert-True ($offs.Count -eq 1) (':Power should turn hibernation off in exactly one place, found {0}.' -f $offs.Count)
    Assert-True ($iCap -ge 0 -and $offs[0] -gt $iCap) ':Power turns hibernation off without capturing it into the power undo file first (regression).'
    $iClr = -1; $iFlag = -1
    for ($i = 0; $i -lt $pw.Count; $i++) {
        if ($iClr -lt 0 -and $pw[$i] -match '^\s*set "_PWHBOFF="\s*$') { $iClr = $i }
        if ($pw[$i] -match '^\s*if /i "!_hb!"=="Y" if not defined _PWBAK_FILE set "_PWHBOFF=1"\s*$') { $iFlag = $i }
    }
    Assert-True ($iClr -ge 0 -and $iClr -lt $iCap) ':Power does not clear _PWHBOFF before its hibernation capture - the flag of an earlier visit would carry over (regression).'
    Assert-True ($iFlag -gt $offs[0]) ':Power no longer flags a hibernation off that ran with no capture landed - the capture :SetMinProcState retries would write "already off before sincript" about sincript''s own change (regression).'
    $pbAll = @(Get-BodyLines -Lines $cmd -Label 'PowerBackup' -CodeOnly)
    $pb = @($pbAll | Where-Object { $_.Trim() -notmatch '^(?i)echo\b' }) -join "`n"
    $pbEcho = @($pbAll | Where-Object { $_.Trim() -match '^(?i)echo\b' }) -join "`n"
    Assert-True ($pb.Length -gt 1000 -and $pbEcho.Length -gt 0) ':PowerBackup did not unroll, or lost its payload.'
    Assert-True ($pb -match '\$hb\.HibernateEnabled\b') ':PowerBackup no longer reads HibernateEnabled, so the undo file cannot put hibernation back (regression).'
    Assert-True ($pb -match '\$hb\.HibernateEnabledDefault\b') ':PowerBackup no longer falls back to HibernateEnabledDefault when HibernateEnabled is absent - the file would say it could not read a state Windows does record (regression).'
    Assert-True ($pb.Contains("'call :pt_do powercfg /hibernate on'")) ':PowerBackup no longer emits a counted hibernation restore (regression).'
    Assert-True ($pb.Contains("'rem  turn it back on from an elevated prompt with:  powercfg /hibernate on'")) ':PowerBackup no longer names the manual command when it cannot read the hibernation state.'
    Assert-True ($pbEcho -match '(?i)powercfg /hibernate on') ':PowerBackup''s failure [WARN] no longer names the command that turns hibernation back on - Control Panel has no switch for it.'
    Assert-True ($pbEcho -notmatch '(?i)remain reversible') ':PowerBackup''s failure [WARN] says power options "remain reversible" through Control Panel again - hibernation is not (regression).'
    $iSet = -1; $iGen = -1; $iUnset = -1
    for ($i = 0; $i -lt $pbAll.Count; $i++) {
        if ($iSet -lt 0 -and $pbAll[$i] -match '^\s*set "PT_HBOFF=!_PWHBOFF!"\s*$') { $iSet = $i }
        if ($iGen -lt 0 -and $pbAll[$i].Contains('Set-Content -LiteralPath $env:PT_PWBAK ')) { $iGen = $i }
        if ($iUnset -lt 0 -and $pbAll[$i] -match '^\s*set "PT_HBOFF="\s*$') { $iUnset = $i }
    }
    Assert-True ($iSet -ge 0 -and $iGen -gt $iSet -and $iUnset -gt $iGen) ':PowerBackup no longer hands _PWHBOFF to its payload as PT_HBOFF (set before the generator, cleared after) - a retried capture cannot tell sincript''s own "off" from the user''s (regression).'
    Assert-True ($pb.Contains('elseif($env:PT_HBOFF){')) ':PowerBackup''s payload no longer reads PT_HBOFF, so a retried capture writes "already off before sincript" about sincript''s own change (regression).'
}

# ===============================================================================
# 138. No screen promises an undo the code does not have. An audit found
#      "reversible", "harmless", "revert from their own menus", "old one saved as
#      hosts.bak" and "enough for a full restore" on screens where the code did
#      not back them, and one-way actions (TCP tuning, the network-stack reset)
#      that did not say so. Each rule requires the replacement wording AND bans
#      the false wording, so a rule cannot pass on a routine that lost its text.
# ===============================================================================
Invoke-Test 'Screens promise no undo the code does not have' {
    $cmd = Read-Lines $CmdPath
    $never = '(?!)'   # a rule whose screen had nothing false, only something missing
    $rules = @(
        @(@('MenuAdvanced'),                               '(?i)\bReversible,',                                       '(?i)no in-app undo'),
        @(@('MenuTools'),                                  '(?i)reversible',                                          '(?i)cannot be undone'),
        @(@('CompactWinSxS'),                              '(?i)reversible',                                          '(?is)cleanup cannot.*compactos:never'),
        @(@('Performance'),                                '(?i)pick this to undo',                                   '(?i)exact value you'),
        @(@('Power'),                                      '(?i)Balanced undoes|pick this to undo|Reset it under',    '(?i)Revert power settings'),
        @(@('NetworkApply'),                               $never,                                                    '(?s)NOT saved.*netsh int tcp show global.*netsh int tcp show heuristics'),
        @(@('NetReset'),                                   $never,                                                    '(?i)cannot be undone'),
        @(@('DnsCustom'),                                  '(?i)left exactly as it is|puts everything back',          '(?i)does not bring back'),
        @(@('ApplyHosts'),                                 '(?i)next to it AND',                                      '(?i)never overwrite'),
        @(@('ResetHostsDefault'),                          '(?i)old one saved as hosts\.bak',                         '(?i)The file it replaced'),
        @(@('DisableMitigations'),                         '(?i)Reversible \(option 2\)',                             '(?i)Memory_Management_'),
        @(@('BcdTimers'),                                  '(?i)Reversible \(option 4\)',                             '(?i)Windows defaults'),
        @(@('NvmeFlags'),                                  '(?i)harmless',                                            '(?i)then reboot'),
        @(@('DisableIPv6'),                                '(?i)delete that value or set it to 0',                    '(?i)single value backup'),
        @(@('ApplyRecommended'),                           $never,                                                    '(?i)Ultimate Performance'),
        @(@('CliHelp'),                                    '(?i)aggressive-but-reversible',                           '(?i)/preset:heavy'),
        @(@('Debloat'),                                    '(?i)to get an app back you|reinstall it from the Microsoft Store', '(?i)LTSC editions have no Store'),
        @(@('DebloatDone'),                                '(?i)Any removed app',                                     '(?i)OneDrive comes back'),
        @(@('PathEditor'),                                 '(?i)whole PATH value',                                    '(?i)whole Environment key'),
        @(@('LaptopAdvisory'),                             '(?i)reversible',                                          '\[ADVISORY\]'),
        @(@('MenuPresets'),                                '(?i)from their own menu',                                 '(?is)TCP tuning.*deletes files for good'),
        @(@('PresetLight'),                                '(?i)reversible',                                          '(?is)TCP tuning is not saved.*deletes files for good'),
        @(@('PresetHeavy'),                                '(?i)but reversible|from their own menu',                  '(?is)Enable-MMAgent.*deletes files for good'),
        @(@('RestorePresetJson', 'RestorePresetJson_ask'), '(?i)from their own menu',                                 '(?is)TCP tuning.*memory compression.*Not restored here'),
        @(@('ManageBackups'),                              '(?i)enough for a full restore',                           '(?i)only copy of values')
    )
    foreach ($rule in $rules) {
        $lines = @($rule[0] | ForEach-Object { Get-BodyLines -Lines $cmd -Label $_ -CodeOnly })
        $said = @($lines | Where-Object { $_ -match '(?i)(^|\s)echo(\s|\.|\()' }) -join "`n"
        $who = ':' + ($rule[0] -join ' / :')
        Assert-True ($said -match $rule[2]) ("$who lost the wording that says what its undo really is (expected /{0}/), or the routine changed shape." -f $rule[2])
        Assert-True ($said -notmatch $rule[1]) ("$who promises an undo the code does not have again (matched /{0}/)." -f $rule[1])
    }

    # The hosts reset names the file that really holds what it replaced. hosts.bak is write-once,
    # so after the first run the replaced file is only the snapshot - or nowhere, if that copy
    # failed - while the message still said "saved as hosts.bak". And _hbakdoc is set by
    # :ApplyHosts too, so without clearing it a stale snapshot could be named.
    $rh = @(Get-BodyLines -Lines $cmd -Label 'ResetHostsDefault' -CodeOnly)
    Assert-True ($rh.Count -gt 20) ':ResetHostsDefault did not unroll.'
    $iClr = -1; $iNew = -1; $iSet = -1
    for ($i = 0; $i -lt $rh.Count; $i++) {
        if ($iClr -lt 0 -and $rh[$i] -match '^\s*set "_hbakdoc="\s*$') { $iClr = $i }
        if ($iNew -lt 0 -and $rh[$i] -match '^\s*set "_hbnew="\s*$') { $iNew = $i }
        if ($iSet -lt 0 -and $rh[$i] -match 'set "_hbakdoc=!BACKUP_DIR!') { $iSet = $i }
    }
    Assert-True ($iClr -ge 0 -and $iNew -ge 0 -and $iSet -gt $iClr -and $iSet -gt $iNew) ':ResetHostsDefault does not clear _hbakdoc and _hbnew before it may set them - the reset message could name the snapshot an earlier Apply hosts took (regression).'
    Assert-True (@($rh | Where-Object { $_ -match '(?i)^\s*if not exist "%_HOSTS%\.bak" copy /y "%_HOSTS%" "%_HOSTS%\.bak" >nul 2>&1 && set "_hbnew=1"\s*$' }).Count -eq 1) ':ResetHostsDefault no longer records (on the copy''s own success) that THIS run wrote hosts.bak - the message cannot tell a fresh hosts.bak from an old one (regression).'
    $gates = @(
        @('The file it replaced is saved as !_hbakdoc!', @('if exist "!_hbakdoc!"')),
        @('The file it replaced is saved as hosts.bak',  @('if not exist "!_hbakdoc!"', 'if defined _hbnew')),
        @('The file it replaced could NOT be saved',      @('if not exist "!_hbakdoc!"', 'if not defined _hbnew')))
    foreach ($g in $gates) {
        $hit = @($rh | Where-Object { $_.Contains($g[0]) })
        Assert-True ($hit.Count -eq 1) (':ResetHostsDefault should say "{0}" on exactly one line, found {1}.' -f $g[0], $hit.Count)
        foreach ($cond in $g[1]) {
            Assert-True ($hit[0].Contains($cond)) (':ResetHostsDefault says "{0}" without the gate {1} - it can name a file that does not hold the replaced hosts (regression).' -f $g[0], $cond)
        }
    }
}

# ===============================================================================
# 139. The Windows Update driver toggle writes ONE documented policy, spelled the
#      one way Windows reads it, under the one key it reads it from - and "on"
#      DELETES the value ("Not configured", the Windows default) instead of writing
#      0 (the policy's "Disabled" state). Both halves read the value back and COUNT
#      a wrong or unreadable end state into _FAILS before :Summary, so an inline
#      [FAIL] can never sit above an [OK]; only then do they ask whether the Group
#      Policy Editor will write its own value back (the write path, nowhere else).
#      The toggle stays menu-only: no preset, no safe set, no /preset:.
# ===============================================================================
Invoke-Test 'Windows Update driver toggle: one documented policy, deleted to turn back on, end state counted, menu-only' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"
    $key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $val = 'ExcludeWUDriversInQualityUpdate'

    # One spelling everywhere, comments included. Microsoft's Autopatch pages print the registry
    # name as ...From...Updates; Windows reads nothing by that name, so a write of it would print
    # [OK] and change nothing.
    $names = @([regex]::Matches($all, '(?i)ExcludeWUDrivers\w*') | ForEach-Object { $_.Value })
    Assert-True ($names.Count -ge 6) ("Only {0} mention(s) of {1} - the feature is missing or the scan broke." -f $names.Count, $val)
    $wrong = @($names | Where-Object { $_ -ine $val } | Sort-Object -Unique)
    Assert-True ($wrong.Count -eq 0) ("Misspelled driver-policy name(s): {0}. Windows reads only {1} (regression)." -f ($wrong -join ', '), $val)

    $off = @(Get-BodyLines -Lines $cmd -Label 'WuDrvOff' -CodeOnly | ForEach-Object { $_.Trim() })
    $on  = @(Get-BodyLines -Lines $cmd -Label 'WuDrvOn' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($off.Count -gt 10 -and $on.Count -gt 10) ':WuDrvOff / :WuDrvOn are missing or did not unroll.'
    $offj = $off -join "`n"; $onj = $on -join "`n"
    Assert-True ($offj -match ('(?i)call :SafeRegAdd "' + [regex]::Escape($key) + '" "' + $val + '" REG_DWORD 1 "')) ':WuDrvOff no longer writes REG_DWORD 1 to the documented key through :SafeRegAdd (regression).'
    Assert-True ($onj -match ('(?i)call :SafeRegDelete "' + [regex]::Escape($key) + '" "' + $val + '" "')) ':WuDrvOn no longer DELETES the value through :SafeRegDelete - "on" means Not configured, the Windows default (regression).'
    $writes = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' -and $_ -match ('(?i)call :SafeReg(Add|Delete)\s+"[^"]*"\s+"' + $val + '"') })
    Assert-True ($writes.Count -eq 2) ("Expected exactly two writes of {0} (block, unblock), found {1}: {2}" -f $val, $writes.Count, ($writes -join ' | '))
    foreach ($w in $writes) {
        Assert-True ($w -match ('(?i)"' + [regex]::Escape($key) + '"\s')) ("{0} is written under the wrong key - Windows reads it only from {1} (the AU subkey is a different policy set): {2}" -f $val, $key, $w.Trim())
        Assert-True ($w -notmatch '(?i)REG_DWORD\s+0\b') ("{0} is written as 0 - that is the policy's Disabled state; turning drivers back on must delete it: {1}" -f $val, $w.Trim())
    }

    # The end state, read back and COUNTED, then the Group Policy Editor check, then :Summary.
    foreach ($r in @(@{ n = 'WuDrvOff'; b = $off; want = 'blocked' }, @{ n = 'WuDrvOn'; b = $on; want = 'unset' })) {
        $b = $r.b
        $iReset = [Array]::IndexOf($b, 'set "_FAILS=0"')
        $iWrite = -1; for ($i = 0; $i -lt $b.Count; $i++) { if ($b[$i] -match '^(?i)call :SafeReg(Add|Delete) ') { $iWrite = $i; break } }
        $iRead  = [Array]::IndexOf($b, 'call :WuDrvRead')
        $iCheck = [Array]::IndexOf($b, ('if "%_FAILS%"=="0" if not "!_wdst!"=="' + $r.want + '" ('))
        $iGp    = [Array]::IndexOf($b, ('if "%_FAILS%"=="0" call :WuDrvGpCheck ' + $r.want))
        $iSum   = -1; for ($i = 0; $i -lt $b.Count; $i++) { if ($b[$i] -match '^(?i)call :Summary "') { $iSum = $i; break } }
        Assert-True ($iReset -ge 0 -and $iReset -lt $iWrite) (":{0} does not reset _FAILS before its write (regression)." -f $r.n)
        Assert-True ($iRead -gt $iWrite -and $iCheck -gt $iRead -and $iCheck -lt $iSum) (":{0} does not read the value back and check it is '{1}' before :Summary - its [OK] would report the absence of an error, not the end state (regression)." -f $r.n, $r.want)
        Assert-True ($iCheck + 3 -lt $b.Count -and $b[$iCheck + 1] -match '^echo\s+\[FAIL\]\s' -and $b[$iCheck + 2] -eq 'set /a _FAILS+=1' -and $b[$iCheck + 3] -eq ')') (":{0} no longer counts a wrong read-back into _FAILS inside its check - the user would see an inline [FAIL] and then :Summary's [OK] (regression)." -f $r.n)
        Assert-True ($iGp -gt $iCheck + 3 -and $iGp -lt $iSum) (":{0} no longer asks, once the value is in place and before :Summary, whether the Group Policy Editor sets it too - Group Policy would write its value back after an [OK] (regression)." -f $r.n)
        Assert-True (@($b | Where-Object { $_ -match '^(?i)echo\s+\[OK\]' }).Count -eq 0) (":{0} echoes a bare [OK] instead of going through :Summary (regression)." -f $r.n)
    }

    # Where the effect cannot be vouched for, only "written" is honest: an edition Microsoft does
    # not list (Home, unread), a build before 1607, or MDM telling Windows Update to ignore Group
    # Policy. Each branch is taken before the one summary that promises the effect.
    $iPromise = -1; for ($i = 0; $i -lt $off.Count; $i++) { if ($off[$i] -match '^call :Summary "Windows Update will stop offering drivers') { $iPromise = $i; break } }
    Assert-True ($iPromise -gt 0) ':WuDrvOff lost its summary for the case where the block is documented to work.'
    foreach ($g in 'if defined _wdign goto _wdOffIgnored', 'if not "!_wdedc!"=="listed" goto _wdOffUnverified', 'if defined WIN_BUILD if !WIN_BUILD! LSS 14393 goto _wdOffUnverified') {
        $ig = [Array]::IndexOf($off, $g)
        Assert-True ($ig -ge 0 -and $ig -lt $iPromise) (":WuDrvOff promises the block works without first ruling out '{0}' - there only ""written"" is honest (regression)." -f $g)
    }
    $unv = @($off | Where-Object { $_ -match '^call :Summary "' -and $_ -notmatch 'will stop offering drivers' -and $_ -notmatch 'Group Policy Editor' })
    Assert-True ($unv.Count -eq 2 -and @($unv | Where-Object { $_ -match 'unverified' }).Count -eq 2) (':WuDrvOff should have exactly two "written ... unverified" summaries besides the promise and the Group Policy Editor one, found: ' + ($unv -join ' | '))
    Assert-True ([Array]::IndexOf($on, 'if defined _wdign goto _wdOnIgnored') -ge 0) ':WuDrvOn no longer says, where MDM tells Windows Update to ignore Group Policy, that removing the local value decides nothing (regression).'

    # A Group Policy Editor conflict is decided FIRST. The value was written and read back, so the
    # promise ("will stop offering ... restart Windows") and the other summaries are wrong there - a
    # restart is when Group Policy writes its value back. Its flag is cleared before each write,
    # because the check that sets it is skipped after a failed write. Each conflict summary hands
    # :Summary a cause (_SUMCAUSE), which replaces the "could NOT be applied ... protected keys" tail.
    $okOn = -1; for ($i = 0; $i -lt $on.Count; $i++) { if ($on[$i] -match '^call :Summary "Driver updates back to the Windows default') { $okOn = $i; break } }
    Assert-True ($okOn -gt 0) ':WuDrvOn lost its summary for the plain "back to the default" case.'
    foreach ($r in @(@{ n = 'WuDrvOff'; b = $off; first = @('if defined _wdgpc goto _wdOffGp'); gates = @('if defined _wdign goto _wdOffIgnored', 'if not "!_wdedc!"=="listed" goto _wdOffUnverified', 'if defined WIN_BUILD if !WIN_BUILD! LSS 14393 goto _wdOffUnverified'); promise = $iPromise; nGp = 1 },
                     @{ n = 'WuDrvOn'; b = $on; first = @('if "!_wdgpc!"=="keep" goto _wdOnGpKeep', 'if "!_wdgpc!"=="block" goto _wdOnGpBlock', 'if defined _wdgpc goto _wdOnGp'); gates = @('if defined _wdign goto _wdOnIgnored'); promise = $okOn; nGp = 3 })) {
        $b = $r.b
        $iReset = [Array]::IndexOf($b, 'set "_FAILS=0"'); $iClr = [Array]::IndexOf($b, 'set "_wdgpc="')
        $iWrite = -1; for ($i = 0; $i -lt $b.Count; $i++) { if ($b[$i] -match '^(?i)call :SafeReg(Add|Delete) ') { $iWrite = $i; break } }
        Assert-True ($iClr -gt $iReset -and $iClr -lt $iWrite) (":{0} no longer clears _wdgpc before its write - after a failed write the check is skipped, and an earlier conflict would pick this summary (regression)." -f $r.n)
        $iGp = -1; for ($i = 0; $i -lt $b.Count; $i++) { if ($b[$i] -match '^if "%_FAILS%"=="0" call :WuDrvGpCheck ') { $iGp = $i; break } }
        foreach ($f in $r.first) {
            $iF = [Array]::IndexOf($b, $f)
            Assert-True ($iF -gt $iGp -and $iF -lt $r.promise) (":{0} no longer routes a Group Policy Editor conflict ('{1}') after the check and before its normal summary (regression)." -f $r.n, $f)
            foreach ($g in $r.gates) { Assert-True ($iF -lt [Array]::IndexOf($b, $g)) (":{0} tests '{1}' before the Group Policy Editor conflict - the conflict must decide the summary first (regression)." -f $r.n, $g) }
        }
        $gpSum = @(); for ($i = 1; $i -lt $b.Count; $i++) { if ($b[$i] -match '^call :Summary "[^"]*Group Policy Editor') { $gpSum += $i } }
        Assert-True ($gpSum.Count -eq $r.nGp) (":{0} should have {1} Group Policy Editor summar(ies), found {2}." -f $r.n, $r.nGp, $gpSum.Count)
        foreach ($i in $gpSum) {
            Assert-True ($b[$i - 1] -match '^set "_SUMCAUSE=[^"]+"$') (":{0}: the Group Policy Editor summary is not preceded by its cause - :Summary would print ""could NOT be applied ... protected or held by Windows"" under a value that was written and read back (regression): {1}" -f $r.n, $b[$i])
            Assert-True ($b[$i] -notmatch '(?i)restart Windows|will stop offering|back to the Windows default') (":{0}: the Group Policy Editor summary promises the effect or says ""restart Windows"" - a restart is when Group Policy writes its own value back (regression): {1}" -f $r.n, $b[$i])
        }
    }

    # "That MDM value now applies" only when the read-back shows the Group Policy value GONE: while
    # it is still there (a failed delete), Group Policy still wins by default.
    $applies = @($on | Where-Object { $_ -match '(?i)now applies' })
    Assert-True ($applies.Count -eq 1) (':WuDrvOn should say on exactly one line that the MDM value now applies, found {0}.' -f $applies.Count)
    Assert-True ($applies[0] -match '^if defined _wdmdm if "!_wdst!"=="unset" if not defined _wdgpc echo\s') (':WuDrvOn says the MDM value "now applies" without checking that the read-back shows the local value gone and that the Group Policy Editor will not write one back - either way Group Policy wins, contradicting the [WARN] above it (regression): ' + $applies[0])

    # The Group Policy Editor check starts PowerShell, so it is called from the two handlers only.
    $gpCalls = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($cmd[$i].Trim() -match '^(?i)rem\b' -or $cmd[$i] -notmatch '(?i)call :WuDrvGpCheck\b') { continue }
        $own = '<none>'
        for ($j = $i; $j -ge 0; $j--) { if ($cmd[$j] -match '^:(\w+)' -and $Matches[1] -notmatch '^_') { $own = $Matches[1]; break } }
        $gpCalls += $own
    }
    Assert-True ($gpCalls.Count -eq 2 -and $gpCalls -contains 'WuDrvOff' -and $gpCalls -contains 'WuDrvOn') ('The Group Policy Editor check must be called by :WuDrvOff and :WuDrvOn only (the write path) - it starts PowerShell. Callers found: ' + ($gpCalls -join ', '))

    # Menu-only. Every code line that names the value, or jumps to its handlers, must live in the
    # toggle's own routines - never in a preset body, a core, the safe set or :CliRun.
    $allowed = 'WuDrivers_ask', 'WuDrvOff', 'WuDrvOn', 'WuDrvRead', 'WuDrvGpCheck'
    $seen = 0; $bad = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $s = $cmd[$i].Trim()
        if ($s -match '^(?i)(rem|echo)\b') { continue }
        if ($s -notmatch ('(?i)' + $val + '|\bgoto\s+WuDrv(Off|On)\b|\bcall\s+:WuDrv(Off|On)\b|\b(goto\s+|call\s+:)WuDrivers\b')) { continue }
        $seen++
        $own = '<none>'
        for ($j = $i; $j -ge 0; $j--) { if ($cmd[$j] -match '^:(\w+)' -and $Matches[1] -notmatch '^_') { $own = $Matches[1]; break } }
        if ($allowed -notcontains $own -and -not ($own -eq 'MenuAdvanced_ask' -and $s -eq 'if "!sel!"=="11" goto WuDrivers')) { $bad += ("line {0} in :{1}: {2}" -f ($i + 1), $own, $s) }
    }
    Assert-True ($seen -ge 7) "Only $seen code line(s) reference the driver policy or its screens - the scan is not seeing them."
    Assert-True ($bad.Count -eq 0) ("The driver policy is reachable outside its own menu screen - the author kept it out of presets, the safe set and /preset: (regression): " + ($bad -join ' | '))
    $pcl = (Get-BodyLines -Lines $cmd -Label 'PresetCheckLine' -CodeOnly) -join "`n"
    Assert-True ($pcl.Length -gt 0) ':PresetCheckLine is missing - the preset-key half of this check proves nothing.'
    Assert-True ($pcl -notmatch '(?i)"[%!]_k[%!]"=="[^"]*driver') 'A preset key for driver updates exists - the toggle was meant to stay menu-only (regression).'
    if (Test-Path -LiteralPath $PresetPath) {
        # Setting lines only, as test 3 reads them: every non-comment line, plus commented "key=value"
        # examples (the ones people uncomment). Prose saying why there is no driver key is fine.
        $presetLines = Read-Lines $PresetPath
        $settings = @()
        foreach ($raw in $presetLines) {
            $t = $raw.Trim()
            if ($t -eq '') { continue }
            if ($t.StartsWith('#') -or $t.StartsWith(';')) {
                $t = $t.TrimStart('#', ';').Trim()
                if ($t -notmatch '^[A-Za-z_][A-Za-z0-9_]*\s*=') { continue }
            }
            $settings += $t
        }
        Assert-True ($settings.Count -ge 10) ("Only {0} setting line(s) found in example.preset - the driver-key check would prove nothing." -f $settings.Count)
        $drv = @($settings | Where-Object { $_ -match '(?i)driver' })
        Assert-True ($drv.Count -eq 0) ('example.preset has a driver setting - the toggle was meant to stay menu-only (regression): ' + ($drv -join ' | '))
    }
    $ask = @(Get-BodyLines -Lines $cmd -Label 'MenuAdvanced_ask' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($ask -contains 'if "!sel!"=="11" goto WuDrivers') 'Advanced item 11 no longer dispatches to :WuDrivers (regression).'
    # _SUMCAUSE turns :Summary's "a write failed" tail into "not a failed write". It belongs only to the
    # Group Policy Editor conflict outcomes, where the change DID land and was read back - anywhere else it
    # would explain away a real failure. Each set sits directly under a :_wd*Gp* label and directly above a
    # :Summary that names the Group Policy Editor.
    $causes = @(for ($i = 0; $i -lt $cmd.Count; $i++) { if ($cmd[$i] -match '^\s*set "_SUMCAUSE=.+"') { $i } })
    Assert-True ($causes.Count -ge 1) 'No code sets _SUMCAUSE - the Group Policy Editor outcomes lost their explanation.'
    foreach ($i in $causes) {
        Assert-True ($i -gt 0 -and $cmd[$i - 1] -match '^:_wd(Off|On)Gp\w*$') ("line {0} sets _SUMCAUSE outside a Group Policy Editor outcome - it would explain away a real failure (regression)." -f ($i + 1))
        Assert-True ($cmd[$i + 1] -match '^\s*call :Summary ".*Group Policy Editor') ("line {0}: _SUMCAUSE is not followed directly by the Group Policy Editor summary it belongs to (regression)." -f ($i + 1))
    }
}

# ===============================================================================
# 140. The driver-policy screen says what it costs BEFORE it asks: the whole driver
#      offer (firmware included), Microsoft's recommendation, what it does not undo
#      and what still gets through, that the Group Policy Editor writes its own
#      value back - and the stored value, read with no PowerShell. Its advisories
#      are warning-only. The Group Policy Editor check reads Registry.pol (a binary
#      file, not localized text) and runs on the write path only. Status reads the
#      value through the same routines, "What was excluded" tells this one scoped
#      policy apart from disabling Windows Update, and the menus fit the console.
# ===============================================================================
Invoke-Test 'The driver-policy screen discloses before it asks; the gpedit check is write-path only; Status, Excluded and the menus agree' {
    $cmd = Read-Lines $CmdPath
    $width = 0; $height = 0
    foreach ($ln in $cmd) { $m = [regex]::Match($ln, '(?i)^\s*mode con:\s*cols=(\d+)\s+lines=(\d+)'); if ($m.Success) { $width = [int]$m.Groups[1].Value; $height = [int]$m.Groups[2].Value } }
    Assert-True ($width -gt 0 -and $height -gt 0) 'No "mode con: cols=N lines=M" line - nothing to measure against.'
    $unesc = { param([string]$s) [regex]::Replace($s, '\^(.)', '$1') }

    $scr = @(Get-BodyLines -Lines $cmd -Label 'WuDrivers' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($scr.Count -gt 15) ':WuDrivers is missing or did not unroll.'
    $iOpt = -1
    for ($i = 0; $i -lt $scr.Count; $i++) { if ($scr[$i] -match '^echo\s+1\.\s') { $iOpt = $i; break } }
    Assert-True ($iOpt -gt 0) ':WuDrivers no longer prints its numbered choices - screen changed shape?'
    $before = $scr[0..($iOpt - 1)]
    # the disclosure as it reads on screen: line breaks become spaces, carets are gone
    $disc = (@($before | Where-Object { $_ -match '^(?i)echo\s' } | ForEach-Object { (& $unesc ($_ -replace '^(?i)echo\s+', '')) }) -join ' ')
    foreach ($p in 'OFFERING drivers', 'firmware', 'security fixes', 'Microsoft recommends leaving driver updates on', 'does not remove what is installed', 'feature update', 'not affected', 'Group Policy Editor (gpedit.msc)', 'writes its own value back', 'reboot') {
        Assert-True ($disc.Contains($p)) ("The driver-policy screen no longer says '{0}' before its choices - the user would decide without it (regression)." -f $p)
    }
    foreach ($c in 'call :WuDrvRead', 'call :WuDrvStateLine', 'call :WuDrvEditionNote', 'call :WuDrvFirmwareAdvisory') {
        Assert-True (@($before | Where-Object { $_ -eq $c }).Count -eq 1) ("The driver-policy screen no longer runs '{0}' before its choices (regression)." -f $c)
    }
    Assert-True (@($before | Where-Object { $_ -match '^if defined WIN_BUILD if !WIN_BUILD! LSS 14393 echo\s+\[ADVISORY\]' }).Count -eq 1) 'The driver-policy screen no longer warns, before its choices, on a build older than 1607 (14393), where Microsoft does not list the policy (regression).'

    # No PowerShell on the screen or the reader: it is one DWORD and a few strings, and Status runs
    # it too. The one PowerShell worker, the Group Policy Editor check, stays off the draw path.
    foreach ($r in 'WuDrivers', 'WuDrivers_ask', 'WuDrvOff', 'WuDrvOn', 'WuDrvRead', 'WuDrvStateLine', 'WuDrvEditionNote', 'WuDrvFirmwareAdvisory') {
        $b = (Get-BodyLines -Lines $cmd -Label $r -CodeOnly) -join "`n"
        Assert-True ($b.Length -gt 0) ":$r is missing."
        Assert-True ($b -notmatch '(?i)powershell|Add-Type') (":{0} spawns PowerShell - reading a registry value must stay instant (regression)." -f $r)
    }
    foreach ($r in 'WuDrivers', 'WuDrvRead', 'WuDrvStateLine', 'WuDrvEditionNote', 'WuDrvFirmwareAdvisory', 'Status') {
        $b = (Get-BodyLines -Lines $cmd -Label $r -CodeOnly) -join "`n"
        Assert-True ($b -notmatch '(?i)WuDrvGpCheck') (":{0} runs the Group Policy Editor check - it starts PowerShell and belongs to the write path only (regression)." -f $r)
    }
    $gp = @(Get-BodyLines -Lines $cmd -Label 'WuDrvGpCheck' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($gp.Count -gt 10) ':WuDrvGpCheck is missing or did not unroll.'
    $gpj = $gp -join "`n"
    $ps = @($gp | Where-Object { $_ -match '(?i)\bpowershell\b' })
    Assert-True ($ps.Count -eq 1 -and $ps[0].StartsWith('start "" /min /wait powershell -NoProfile -Command "')) ':WuDrvGpCheck should run exactly one house-pattern worker (start "" /min /wait powershell).'
    Assert-True ($gpj -notmatch '(?i)Add-Type') ':WuDrvGpCheck compiles C# - a byte search needs none.'
    Assert-True ($gp -contains 'set "_wdpolsrc=!SystemRoot!\System32\GroupPolicy\Machine\Registry.pol"') ':WuDrvGpCheck no longer reads the local Group Policy file (System32\GroupPolicy\Machine\Registry.pol).'
    foreach ($p in 'ReadAllBytes($env:PT_WDPOLSRC)', 'catch [IO.FileNotFoundException]', 'GetEncoding(28591)', '[Text.Encoding]::Unicode', "'**del.'", "'**delvals'", 'OrdinalIgnoreCase', "'[Software\Policies\Microsoft\Windows\WindowsUpdate'") {
        Assert-True ($ps[0].Contains($p)) (":WuDrvGpCheck's worker no longer contains '{0}' - it must read Registry.pol as bytes, find the UTF-16 key and value (and both delete markers) case-insensitively, and tell a missing file from an unreadable one." -f $p)
    }
    # the answer file is deleted once it is read - every Block or Allow would leave one in %TEMP%
    $iRd = -1; for ($i = 0; $i -lt $gp.Count; $i++) { if ($gp[$i] -match '^if exist "!_wdpolf!" for /f ') { $iRd = $i; break } }
    Assert-True ($iRd -ge 0 -and $iRd + 1 -lt $gp.Count -and $gp[$iRd + 1] -eq 'del "!_wdpolf!" >nul 2>&1') ':WuDrvGpCheck no longer deletes its answer file right after reading it - each change would leave a pt_wdpol_*.txt in %TEMP% (regression).'
    Assert-True ($ps[0] -notmatch '[!%^]') ':WuDrvGpCheck''s worker holds a "!", "%" or "^" - cmd would eat it before PowerShell sees the command.'

    # The reader: MDM from current\device (never \default, which exists everywhere), the ignore
    # switch, the edition, the type before the number, and "unread" when reg answered nothing.
    $rd = @(Get-BodyLines -Lines $cmd -Label 'WuDrvRead' -CodeOnly | ForEach-Object { $_.Trim() })
    $rdj = $rd -join "`n"
    Assert-True ($rdj -match '(?i)PolicyManager\\current\\device\\Update" /v ExcludeWUDriversInQualityUpdate') ':WuDrvRead no longer looks for an MDM value - a managed PC would be told nothing about its organization''s setting (regression).'
    Assert-True ($rdj -match '(?i)PolicyManager\\current\\device\\Update" /v IgnoreWindowsUpdateGroupPolicies') ':WuDrvRead no longer reads IgnoreWindowsUpdateGroupPolicies - where MDM tells Windows Update to ignore Group Policy, a local block reads back as BLOCKED and does nothing (regression).'
    Assert-True ($rdj -notmatch '(?i)PolicyManager\\default') ':WuDrvRead reads PolicyManager\default - that key holds this policy''s metadata on every machine, so every PC would look managed.'
    Assert-True ($rdj -match '(?i)"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion" /v EditionID') ':WuDrvRead no longer reads EditionID - Home could not be told apart (regression).'
    Assert-True ($rdj -match '(?i)if /i not "!_wdtype!"=="REG_DWORD" goto') ':WuDrvRead compares the number without checking the type first - a REG_SZ "1" would read as blocked (regression).'
    Assert-True ($rd -contains 'if not defined _wded if "!_wdst!"=="unset" set "_wdst=unread"') ':WuDrvRead reports "not set - the Windows default" when the registry could not be read at all (EditionID missing too) - "none found" for a failed read (regression).'

    # One vocabulary. Every word a caller compares _wdst / _wdedc against must be one :WuDrvRead
    # can set - a caller testing for a word the reader never produces is a branch that never runs.
    # _wdgpc the same way, against :WuDrvGpCheck - the handlers pick their summary by its words.
    foreach ($vv in @(@{ v = '_wdst'; src = $rdj; min = 4; who = 'WuDrvRead'; must = 'unread'; umin = 4 }, @{ v = '_wdedc'; src = $rdj; min = 4; who = 'WuDrvRead'; must = 'unread'; umin = 4 }, @{ v = '_wdgpc'; src = $gpj; min = 3; who = 'WuDrvGpCheck'; must = 'keep'; umin = 2 })) {
        $v = $vv.v
        $made = @([regex]::Matches($vv.src, ('(?i)set "' + $v + '=(\w+)"')) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Assert-True ($made.Count -ge $vv.min) ("Found only {0} value(s) :{1} assigns to {2} - the scan is not seeing them." -f $made.Count, $vv.who, $v)
        Assert-True ($made -contains $vv.must) (":{0} can no longer set {1} to '{2}' (regression)." -f $vv.who, $v, $vv.must)
        $used = @()
        foreach ($ln in $cmd) {
            if ($ln.Trim() -match '^(?i)rem\b') { continue }
            foreach ($m in [regex]::Matches($ln, ('(?i)"!' + $v + '!"=="(\w+)"'))) { $used += $m.Groups[1].Value }
        }
        Assert-True ($used.Count -ge $vv.umin) ("Found only {0} comparison(s) against {1} - the scan is not seeing them." -f $used.Count, $v)
        $dead = @($used | Where-Object { $made -notcontains $_ } | Sort-Object -Unique)
        Assert-True ($dead.Count -eq 0) ("{0} is compared against value(s) :{1} never sets: {2} (it sets {3}) - those branches can never run (regression)." -f $v, $vv.who, ($dead -join ', '), ($made -join ', '))
    }

    # Warning-only helpers: they print; they never ask, write, run or leave the screen.
    foreach ($a in 'WuDrvStateLine', 'WuDrvEditionNote', 'WuDrvFirmwareAdvisory') {
        foreach ($ln in @(Get-BodyLines -Lines $cmd -Label $a -CodeOnly)) {
            Assert-True ($ln -notmatch '(?i)set /p|call :SafeReg|call :Run|\breg\s+(add|delete)\b|goto\s+(Main)?Menu|powershell') (":{0} is no longer warning-only - it contains: {1}" -f $a, $ln.Trim())
        }
    }
    $fw = (Get-BodyLines -Lines $cmd -Label 'WuDrvFirmwareAdvisory' -CodeOnly) -join "`n"
    Assert-True ($fw -match '(?i)if /i not "%MACHINE%"=="laptop" goto :eof') ':WuDrvFirmwareAdvisory is no longer gated on the laptop probe (regression).'
    Assert-True ($fw -match '\[ADVISORY\]' -and $fw -match '(?i)firmware') ':WuDrvFirmwareAdvisory lost its [ADVISORY] firmware line (regression).'

    # Every fixed line the feature prints fits the console, and none holds an unescaped redirect
    # or command separator (an "echo ... > 11" writes a file named 11 and prints nothing).
    # Variables are counted at a stated maximum: edition 26, a DWORD 10, a type name 30
    # (REG_RESOURCE_REQUIREMENTS_LIST), a build 5, the gpedit value 26; test 141 measures the
    # real rendered lines.
    $maxv = @{ '_wded' = 26; '_wdmdm' = 10; '_wdraw' = 10; '_wdtype' = 30; 'WIN_BUILD' = 5; '_wdgpd' = 26 }
    $lines = @()
    foreach ($r in 'WuDrivers', 'WuDrvOff', 'WuDrvOn', 'WuDrvStateLine', 'WuDrvEditionNote', 'WuDrvFirmwareAdvisory', 'WuDrvGpCheck') {
        foreach ($ln in @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly)) { $lines += ,@($r, $ln.Trim()) }
    }
    $st = @(Get-BodyLines -Lines $cmd -Label 'Status' -CodeOnly | ForEach-Object { $_.Trim() })
    $stHdr = @($st | Where-Object { $_ -match '^echo \[Windows Update drivers\]' })
    Assert-True ($stHdr.Count -eq 1) ':Status lost its [Windows Update drivers] section.'
    $lines += ,@('Status', $stHdr[0])
    $ex = @(Get-BodyLines -Lines $cmd -Label 'Excluded' | Where-Object { $_ -match '(?i)Fully disabling Windows Update' } | ForEach-Object { $_.Trim() })
    Assert-True ($ex.Count -eq 1) '"What was excluded" no longer lists fully disabling Windows Update (regression).'
    $lines += ,@('Excluded', $ex[0])
    $mm = @(Get-BodyLines -Lines $cmd -Label 'MainMenu' -CodeOnly | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^echo\s+7\.\s+Advanced\b' })
    Assert-True ($mm.Count -eq 1) 'The main menu lost its Advanced line.'
    $lines += ,@('MainMenu', $mm[0])
    $wide = @(); $ops = @(); $n = 0; $nCause = 0
    foreach ($pair in $lines) {
        $t = $pair[1]
        $txt = $null
        $em = [regex]::Match($t, '(?i)^(?:if\s.*?\s)?echo\s(.*)$')
        if ($em.Success) { $txt = $em.Groups[1].Value }
        $sm = [regex]::Match($t, '(?i)call :Summary "([^"]*)"')
        # measured as the longer [WARN] form: a Group Policy Editor summary prints only as [WARN],
        # and with a _SUMCAUSE there is no generic tail after it - its cause line comes next
        if ($sm.Success) { $txt = '[WARN] ' + $sm.Groups[1].Value }
        $cm = [regex]::Match($t, '(?i)^set "_SUMCAUSE=([^"]*)"$')
        if ($cm.Success) { $txt = '       ' + $cm.Groups[1].Value; $nCause++ }
        if ($null -eq $txt) { continue }
        $n++
        if ($em.Success) {
            $bare = [regex]::Replace([regex]::Replace($txt, '\^.', ''), '"[^"]*"', '')
            if ($bare -match '[<>|&]') { $ops += ('{0}: {1}' -f $pair[0], $t) }
        }
        $txt = & $unesc $txt
        $txt = [regex]::Replace($txt, '!(\w+)!', { param($m) if ($maxv.ContainsKey($m.Groups[1].Value)) { 'x' * $maxv[$m.Groups[1].Value] } else { 'x' * 30 } })
        if ($txt.Length -ge $width) { $wide += ('{0} ({1} cols): {2}' -f $pair[0], $txt.Length, $t.Substring(0, [Math]::Min(50, $t.Length))) }
    }
    Assert-True ($n -ge 50) "Only $n printed line(s) measured - the scan is not seeing the feature."
    Assert-True ($nCause -ge 4) "Only $nCause _SUMCAUSE line(s) measured - the Group Policy Editor summaries lost their cause, or the scan is not seeing them."
    Assert-True ($wide.Count -eq 0) ("Driver-policy line(s) as wide as the ${width}-column console wrap onto the next row: " + ($wide -join ' | '))
    Assert-True ($ops.Count -eq 0) ('Driver-policy echo line(s) with an unescaped < > | or & - cmd would redirect or split them: ' + ($ops -join ' | '))

    # Status: same reader, same wording as the screen.
    $iR = [Array]::IndexOf($st, 'call :WuDrvRead'); $iL = [Array]::IndexOf($st, 'call :WuDrvStateLine')
    Assert-True ($iR -ge 0 -and $iL -gt $iR) ':Status no longer shows the driver policy through :WuDrvRead then :WuDrvStateLine - the two screens could describe the same value differently (regression).'
    Assert-True ($st -contains 'if "!_wdst!"=="blocked" if not "!_wdedc!"=="listed" call :WuDrvEditionNote') ':Status no longer adds the edition note when the block is on for an edition Microsoft does not list.'

    # What was excluded: the scoped policy is not "fully disabling Windows Update".
    Assert-True ((& $unesc $ex[0]) -match 'Advanced > 11' -and $ex[0] -match 'DRIVER') '"What was excluded" no longer tells the driver-only policy under Advanced > 11 apart from disabling Windows Update (regression).'

    # The menus: the main-menu hint names it, Advanced prints it, and Advanced still fits.
    Assert-True ($mm[0] -match 'WU drivers') 'The main menu''s Advanced hint no longer names the Windows Update driver toggle.'
    $adv = @(Get-BodyLines -Lines $cmd -Label 'MenuAdvanced' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True (@($adv | Where-Object { $_ -match '^echo\s+11\.\s+Windows Update driver installs' }).Count -eq 1) 'The Advanced menu no longer prints item 11, Windows Update driver installs.'
    $logo = @(Get-BodyLines -Lines $cmd -Label 'Logo' -CodeOnly | Where-Object { $_.Trim() -match '^(?i)echo[ .]' }).Count
    $advN = @($adv | Where-Object { $_ -match '^(?i)echo[ .]' }).Count
    Assert-True ($logo -ge 5 -and $advN -ge 12) "The Advanced menu or the logo did not unroll (logo $logo, menu $advN)."
    Assert-True (($logo + $advN + 1) -le $height) ("The Advanced menu needs {0} rows with its prompt; the console has {1} (regression)." -f ($logo + $advN + 1), $height)
}

# ===============================================================================
# 141. The driver-policy screen is RUN, with the registry faked, for twenty stored
#      states: only a REG_DWORD 1 reads as blocked (not a REG_SZ "1", not 0x10, not a
#      saturated 0xffffffff, not a DWORD with no data, not a big-endian DWORD); Home
#      is told apart from the editions Microsoft lists; with no Group Policy value an
#      MDM value is what the state line reports; a registry that answered nothing
#      reads as UNKNOWN, never "not set"; MDM's ignore-Group-Policy switch is named;
#      a build before 1607 gets its advisory; and the rendered screen - logo,
#      disclosure, state, advisories, choices and prompt - fits the console the
#      script sets, in rows and in columns. The four reg queries in :WuDrvRead are
#      replaced by `type` of files (the folder travels in an environment variable,
#      read late); the driver refuses to run if a real reg command or PowerShell
#      survives, and :WuDrivers is cut before its prompt. One child cmd runs them all.
# ===============================================================================
Invoke-Test 'The driver-policy screen classifies and fits the console (run with a faked registry)' {
    $cmd = Read-Lines $CmdPath
    $width = 0; $height = 0
    foreach ($ln in $cmd) { $m = [regex]::Match($ln, '(?i)^\s*mode con:\s*cols=(\d+)\s+lines=(\d+)'); if ($m.Success) { $width = [int]$m.Groups[1].Value; $height = [int]$m.Groups[2].Value } }
    Assert-True ($width -gt 0 -and $height -gt 0) 'test 141: no "mode con: cols=N lines=M" line - there is no screen size to measure against.'

    $q = [ordered]@{
        gp  = 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate'
        mdm = 'reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /v ExcludeWUDriversInQualityUpdate'
        ign = 'reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /v IgnoreWindowsUpdateGroupPolicies'
        ed  = 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID'
    }
    $read = @(Get-BodyLines -Lines $cmd -Label 'WuDrvRead')
    Assert-True ($read.Count -gt 10) ':WuDrvRead is missing or did not unroll.'
    foreach ($k in $q.Keys) {
        $n = @($read | Where-Object { $_.Contains($q[$k]) }).Count
        Assert-True ($n -eq 1) ("test 141: :WuDrvRead no longer asks the registry the way this test fakes it ({0} x {1}) - the test would read the real registry." -f $n, $q[$k])
    }
    $sub = { param([string[]]$L) @($L | ForEach-Object { $s = $_; foreach ($k in $q.Keys) { $s = $s.Replace($q[$k], ('type "!PT141_CASE!\{0}.txt"' -f $k)) }; $s }) }
    $screen = @(Get-BodyLines -Lines $cmd -Label 'WuDrivers' | ForEach-Object { if ($_.Trim() -ieq 'cls') { 'rem cls stubbed' } else { $_ } })
    Assert-True ($screen.Count -gt 15) ':WuDrivers is missing or did not unroll.'
    Assert-True (@($screen | Where-Object { $_ -match '(?i)^\s*set\s+/p' }).Count -eq 0) 'test 141: the :WuDrivers slice reaches a prompt - it would block (the menu must stay in :WuDrivers_ask).'
    $helpers = @()
    foreach ($h in 'Logo', 'WuDrvRead', 'WuDrvStateLine', 'WuDrvEditionNote', 'WuDrvFirmwareAdvisory') {
        $helpers += ':' + $h
        $helpers += @(& $sub @(Get-BodyLines -Lines $cmd -Label $h))
    }

    $regOut = { param([string]$Key, [string]$Name, [string]$Type, [string]$Data) "`r`n$Key`r`n    $Name    $Type    $Data`r`n`r`n" }
    $v = 'ExcludeWUDriversInQualityUpdate'
    $kGp = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $kMdm = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $kEd = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    # gp: $null = absent, else @(type, data); mdm / ign / ed: $null = absent; b = WIN_BUILD ($null = unset).
    # st / edc / ign = what :WuDrvRead must conclude; has / hasnt = what the screen must (not) say.
    $cases = @(
        @{ gp = $null;                          mdm = $null; ign = $null; ed = 'Professional';            m = 'desktop'; b = '26100'; st = 'unset';   edc = 'listed'; ig = ''; has = @('Currently: ALLOWED  (not set - the Windows default)', '[i] Windows edition: Professional - Microsoft documents'); hasnt = @('[ADVISORY]', 'MDM', 'Microsoft lists this policy from') },
        @{ gp = @('REG_DWORD','0x1');           mdm = $null; ign = $null; ed = 'Core';                    m = 'laptop';  b = '22631'; st = 'blocked'; edc = 'home';   ig = ''; has = @('Currently: BLOCKED  (ExcludeWUDriversInQualityUpdate = 1)', '[ADVISORY] Windows edition: Core - a Home edition', '[ADVISORY] This machine looks like a laptop'); hasnt = @() },
        @{ gp = @('REG_DWORD','0x0');           mdm = '0x1'; ign = $null; ed = 'CoreCountrySpecific';     m = 'laptop';  b = '19045'; st = 'allow0';  edc = 'home';   ig = ''; has = @('0 = "Disabled", as the Group Policy Editor writes it', 'Your organization also sets this policy to 0x1', 'By default Group Policy wins over MDM'); hasnt = @('BLOCKED') },
        @{ gp = @('REG_SZ','1');                mdm = $null; ign = $null; ed = 'IoTEnterpriseS';          m = 'desktop'; b = '26100'; st = 'badtype'; edc = 'listed'; ig = ''; has = @('Currently: UNKNOWN  (not a DWORD: REG_SZ'); hasnt = @('BLOCKED') },
        @{ gp = @('REG_SZ','x REG_DWORD 0x1');  mdm = $null; ign = $null; ed = 'EnterpriseS';             m = 'desktop'; b = $null;   st = 'badtype'; edc = 'listed'; ig = ''; has = @('UNKNOWN'); hasnt = @('BLOCKED', 'Microsoft lists this policy from') },
        @{ gp = @('REG_QWORD','0x1');           mdm = $null; ign = $null; ed = 'Education';               m = 'desktop'; b = '26100'; st = 'badtype'; edc = 'listed'; ig = ''; has = @('not a DWORD: REG_QWORD'); hasnt = @('BLOCKED') },
        @{ gp = @('REG_DWORD','0x10');          mdm = $null; ign = $null; ed = 'ProfessionalWorkstation'; m = 'unknown'; b = '26100'; st = 'other';   edc = 'listed'; ig = ''; has = @('Currently: ALLOWED  (value 0x10'); hasnt = @('BLOCKED', '[ADVISORY]') },
        @{ gp = @('REG_DWORD','0xffffffff');    mdm = $null; ign = $null; ed = 'ServerRdsh';              m = 'desktop'; b = '26100'; st = 'other';   edc = 'other';  ig = ''; has = @('does not list it for this policy'); hasnt = @('BLOCKED') },
        @{ gp = @('REG_DWORD','0x2');           mdm = $null; ign = $null; ed = 'CloudEdition';            m = 'desktop'; b = '26100'; st = 'other';   edc = 'other';  ig = ''; has = @('[i] Windows edition: CloudEdition'); hasnt = @() },
        @{ gp = @('REG_DWORD','0x1');           mdm = '0x0'; ign = $null; ed = $null;                     m = 'laptop';  b = '26100'; st = 'blocked'; edc = 'unread'; ig = ''; has = @('The Windows edition could not be read', 'Your organization also sets this policy to 0x0'); hasnt = @() },
        @{ gp = @('REG_DWORD','0x1');           mdm = '0x1'; ign = '0x0'; ed = 'ServerAzureStackHCICorN'; m = 'laptop';  b = '26100'; st = 'blocked'; edc = 'other';  ig = ''; has = @('BLOCKED', 'By default Group Policy wins over MDM'); hasnt = @('ignore Group Policy') },
        @{ gp = @('REG_DWORD','');              mdm = $null; ign = $null; ed = 'Professional';            m = 'desktop'; b = '26100'; st = 'other';   edc = 'listed'; ig = ''; has = @('ALLOWED'); hasnt = @('"Disabled"') },
        @{ gp = $null;                          mdm = '0x1'; ign = $null; ed = 'Enterprise';              m = 'desktop'; b = '26100'; st = 'unset';   edc = 'listed'; ig = ''; has = @('Currently: BLOCKED by your organization  (no local value; its MDM policy sets 1)'); hasnt = @('(not set - the Windows default)', 'By default Group Policy wins') },
        @{ gp = $null;                          mdm = '0x0'; ign = $null; ed = 'Enterprise';              m = 'desktop'; b = '26100'; st = 'unset';   edc = 'listed'; ig = ''; has = @('Currently: ALLOWED  (no local value; your organization''s MDM policy sets 0x0)'); hasnt = @('(not set - the Windows default)', 'BLOCKED') },
        @{ gp = @('REG_DWORD_BIG_ENDIAN','0x01000000'); mdm = $null; ign = $null; ed = 'Professional';    m = 'desktop'; b = '26100'; st = 'badtype'; edc = 'listed'; ig = ''; has = @('Currently: UNKNOWN  (not a DWORD: REG_DWORD_BIG_ENDIAN'); hasnt = @('BLOCKED') },
        @{ gp = $null;                          mdm = $null; ign = $null; ed = $null;                     m = 'desktop'; b = '26100'; st = 'unread';  edc = 'unread'; ig = ''; has = @('Currently: UNKNOWN - the registry could not be read.'); hasnt = @('ALLOWED', 'BLOCKED') },
        @{ gp = @('REG_DWORD','0x1');           mdm = '0x1'; ign = '0x1'; ed = 'Professional';            m = 'desktop'; b = '26100'; st = 'blocked'; edc = 'listed'; ig = '1'; has = @('Your organization also sets this policy to 0x1', 'set Windows Update to ignore Group Policy: a local value does nothing'); hasnt = @('By default Group Policy wins') },
        @{ gp = $null;                          mdm = $null; ign = '0x1'; ed = 'Professional';            m = 'desktop'; b = '26100'; st = 'unset';   edc = 'listed'; ig = '1'; has = @('Currently: ALLOWED  (not set', 'ignore Group Policy'); hasnt = @('MDM') },
        @{ gp = $null;                          mdm = $null; ign = $null; ed = 'Professional';            m = 'desktop'; b = '10586'; st = 'unset';   edc = 'listed'; ig = ''; has = @('[ADVISORY] Microsoft lists this policy from Windows 10 1607 (build 14393); this is build 10586.'); hasnt = @() },
        # the tallest screen that can happen: Disabled + MDM + Home + an old build + a laptop
        @{ gp = @('REG_DWORD','0x0');           mdm = '0x1'; ign = $null; ed = 'CoreSingleLanguage';      m = 'laptop';  b = '10240'; st = 'allow0';  edc = 'home';   ig = ''; has = @('[ADVISORY] Windows edition: CoreSingleLanguage', 'this is build 10240', '[ADVISORY] This machine looks like a laptop'); hasnt = @() }
    )

    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '[\s%]') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT141_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Assert-True ($dir -notmatch '%') ('test 141 cannot run here: the temp folder path holds a "%" and has no short name ({0}).' -f $dir)
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        $w = { param($f, $t) [System.IO.File]::WriteAllText($f, $t, [System.Text.Encoding]::ASCII) }
        $drvCases = @()
        for ($k = 1; $k -le $cases.Count; $k++) {
            $c = $cases[$k - 1]
            $cd = Join-Path $dir ("c$k")
            [void](New-Item -ItemType Directory -Force -Path $cd)
            & $w (Join-Path $cd 'gp.txt')  $(if ($c.gp) { & $regOut $kGp $v $c.gp[0] $c.gp[1] } else { '' })
            & $w (Join-Path $cd 'mdm.txt') $(if ($c.mdm) { & $regOut $kMdm $v 'REG_DWORD' $c.mdm } else { '' })
            & $w (Join-Path $cd 'ign.txt') $(if ($c.ign) { & $regOut $kMdm 'IgnoreWindowsUpdateGroupPolicies' 'REG_DWORD' $c.ign } else { '' })
            & $w (Join-Path $cd 'ed.txt')  $(if ($c.ed) { & $regOut $kEd 'EditionID' 'REG_SZ' $c.ed } else { '' })
            $drvCases += ('set "PT141_CASE=!PT141_DIR!\c{0}"' -f $k)
            $drvCases += ('set "MACHINE={0}"' -f $c.m)
            $drvCases += $(if ($c.b) { 'set "WIN_BUILD={0}"' -f $c.b } else { 'set "WIN_BUILD="' })
            $drvCases += ('echo [CASE#{0}]' -f $k)
            $drvCases += 'call :WuDrivers'
            $drvCases += ('echo [STATE#{0}#!_wdst!#!_wdedc!#!_wdign!#]' -f $k)
        }
        $body = @('@echo off', 'setlocal EnableDelayedExpansion') + $drvCases + @('exit /b 0', ':WuDrivers') + $screen + @('goto :eof') + $helpers
        $live = @($body | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)\breg\s+(query|add|delete)\b|powershell' })
        Assert-True ($live.Count -eq 0) ('test 141: the driver still contains a real reg command or PowerShell - refusing to run it: ' + ($live -join ' | '))
        $drv = Join-Path $dir 'drv.cmd'
        [System.IO.File]::WriteAllLines($drv, [string[]]$body, [System.Text.Encoding]::ASCII)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c ""' + $drv + '""'
        $psi.WorkingDirectory = $dir
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PT141_DIR'] = $dir
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'test 141: the screen driver did not finish within 120 s.' }
        Assert-True ($p.ExitCode -eq 0) ("test 141: the screen driver failed (exit {0}): {1}" -f $p.ExitCode, $err.Result.Trim())
        Assert-True ($err.Result.Trim() -eq '') ("test 141: the screen wrote to stderr: {0}" -f $err.Result.Trim())
        $all = @($out -split "`r?`n")
        $tallest = 0
        for ($k = 1; $k -le $cases.Count; $k++) {
            $c = $cases[$k - 1]
            $i0 = [Array]::IndexOf($all, ('[CASE#{0}]' -f $k))
            $i1 = -1; for ($i = [Math]::Max($i0, 0); $i -lt $all.Count; $i++) { if ($all[$i].StartsWith(('[STATE#{0}#' -f $k))) { $i1 = $i; break } }
            Assert-True ($i0 -ge 0 -and $i1 -gt $i0) "test 141 case ${k}: no state line - the screen did not run to the end."
            $f = $all[$i1].Split('#')
            $what = $(if ($c.gp) { $c.gp -join ' ' } else { 'no value' })
            Assert-True ($f[2] -eq $c.st)  ("test 141 case {0}: {1} (MDM {2}, edition {3}) read as state '{4}', expected '{5}' (regression)." -f $k, $what, $c.mdm, $c.ed, $f[2], $c.st)
            Assert-True ($f[3] -eq $c.edc) ("test 141 case {0}: edition '{1}' classified '{2}', expected '{3}' (regression)." -f $k, $c.ed, $f[3], $c.edc)
            Assert-True ($f[4] -eq $c.ig)  ("test 141 case {0}: IgnoreWindowsUpdateGroupPolicies {1} read as '{2}', expected '{3}' (regression)." -f $k, $c.ign, $f[4], $c.ig)
            $scr = @($all[($i0 + 1)..($i1 - 1)])
            $text = $scr -join "`n"
            foreach ($h in $c.has)   { Assert-True ($text.Contains($h))      ("test 141 case {0}: the screen does not say '{1}'." -f $k, $h) }
            foreach ($h in $c.hasnt) { Assert-True (-not $text.Contains($h)) ("test 141 case {0}: the screen says '{1}' and must not." -f $k, $h) }
            $wide = @($scr | Where-Object { $_.Length -ge $width })
            Assert-True ($wide.Count -eq 0) ("test 141 case {0}: line(s) as wide as the {1}-column console wrap: {2}" -f $k, $width, ($wide -join ' | '))
            $rows = $scr.Count + 1   # + the "Choose: " prompt line in :WuDrivers_ask
            if ($rows -gt $tallest) { $tallest = $rows }
            Assert-True ($rows -le $height) ("test 141 case {0}: the screen needs {1} rows with its prompt; the console has {2} - its top, the disclosure, scrolls away before the user chooses." -f $k, $rows, $height)
        }
        Assert-True ($tallest -ge 30) "test 141: the tallest screen measured only $tallest rows - the driver did not render the advisories."
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# ===============================================================================
# 142. The toggle's two handlers are RUN, with :SafeRegAdd / :SafeRegDelete
#      stubbed (they only rewrite a fake answer file - nothing here can write the
#      real policy), the real :WuDrvRead, :WuDrvGpCheck and :Summary, :LogVar
#      stubbed into a per-case file, the registry faked by files and Registry.pol
#      faked under a fake SystemRoot. A write that reads back as intended ends in
#      [OK]; one that does not - a wrong value, an unreadable registry - ends in
#      [FAIL] and [WARN], never [OK]; a failed write skips the Group Policy Editor
#      check; "that value now applies" appears only when the Group Policy value is
#      really gone and gpedit will not write one back; a Group Policy Editor setting
#      that differs from the change is a counted, logged [WARN] whose summary says
#      what Group Policy will do - never "restart Windows", "could NOT be applied"
#      or "protected keys", and no stale conflict reaches the next run.
#      :WuDrvGpCheck also runs alone against seventeen Registry.pol files: missing,
#      header-only, empty, a DWORD 0 / 1, two values (the last wins), the delete
#      marker, a marker / value / marker run, "**DelVals" after a value and
#      "**delvals." before one, another key, other letter case, a string, a later
#      marker after a value, and a file locked so it cannot be read. Each case runs
#      with TEMP pointing into its own folder, which must hold no pt_wdpol_* file
#      afterwards. The worker's own command text is run in a fresh runspace in this
#      process for every case (PowerShell takes about 2 s to start here), so it sees
#      none of this test's variables, and its answer is handed to the batch through
#      a file; one case starts the real worker line from cmd, which proves the text
#      reaches PowerShell intact.
# ===============================================================================
Invoke-Test 'The driver toggle reports the end state, and the gpedit check reads Registry.pol right (run with stubbed writes)' {
    $cmd = Read-Lines $CmdPath
    $q = [ordered]@{
        gp  = 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate'
        mdm = 'reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /v ExcludeWUDriversInQualityUpdate'
        ign = 'reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /v IgnoreWindowsUpdateGroupPolicies'
        ed  = 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID'
    }
    $worker = 'start "" /min /wait powershell -NoProfile -Command'
    $payload = $null
    $code = @()
    foreach ($h in 'WuDrvOff', 'WuDrvOn', 'WuDrvRead', 'WuDrvGpCheck', 'Summary') {
        $b = @(Get-BodyLines -Lines $cmd -Label $h)
        Assert-True ($b.Count -gt 5) ":$h is missing or did not unroll."
        if ($h -eq 'WuDrvRead') { foreach ($k in $q.Keys) { Assert-True (@($b | Where-Object { $_.Contains($q[$k]) }).Count -eq 1) ('test 142: :WuDrvRead no longer asks the registry the way this test fakes it: ' + $q[$k]) } }
        if ($h -eq 'WuDrvGpCheck') {
            Assert-True (@($b | Where-Object { $_.Contains('!SystemRoot!') }).Count -eq 2) 'test 142: :WuDrvGpCheck no longer builds the Registry.pol path from !SystemRoot! (System32 and Sysnative) the way this test redirects it.'
            $wl = @($b | Where-Object { $_.Contains($worker) })
            Assert-True ($wl.Count -eq 1) 'test 142: :WuDrvGpCheck no longer starts its worker the way this test runs it.'
            $pm = [regex]::Match($wl[0], '-Command "([^"]+)"\s*$')
            Assert-True ($pm.Success) 'test 142: the worker''s -Command "..." text could not be isolated.'
            $payload = $pm.Groups[1].Value
        }
        $code += ':' + $h
        foreach ($s in $b) {
            foreach ($k in $q.Keys) { $s = $s.Replace($q[$k], ('type "!PT142_CASE!\{0}.txt"' -f $k)) }
            $s = $s.Replace('!SystemRoot!', '!PT142_CASE!')
            if ($s.Trim() -ieq 'pause') { $code += 'rem pause stubbed'; continue }
            if ($s.Contains($worker)) {
                # the same command text - in this hidden console for the one real run, otherwise the
                # answer the same text gave in this process
                $code += ('if defined PT142_REALPS ' + $s.Trim().Replace($worker, 'powershell -NoProfile -NonInteractive -Command'))
                $code += 'if not defined PT142_REALPS copy /y "!PT142_CASE!\polres.txt" "!_wdpolf!" >nul'
                continue
            }
            $code += $s
        }
    }
    $gpLine = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $stubs = @(
        ':SafeRegAdd', 'echo   [REG] %~5', 'if not defined FAKEFAIL goto _stubAddOk', 'echo         [FAIL] stub: the write failed', 'set /a _FAILS+=1', 'exit /b 1', ':_stubAddOk',
        'if defined FAKESTUCK exit /b 0', ('>"!PT142_CASE!\gp.txt" echo ' + $gpLine), '>>"!PT142_CASE!\gp.txt" echo     ExcludeWUDriversInQualityUpdate    REG_DWORD    0x1', 'exit /b 0',
        ':SafeRegDelete', 'echo   [REG] %~3', 'if not defined FAKEFAIL goto _stubDelOk', 'echo         [FAIL] stub: the write failed', 'set /a _FAILS+=1', 'exit /b 1', ':_stubDelOk',
        'if defined FAKESTUCK exit /b 0', 'type nul >"!PT142_CASE!\gp.txt"', 'exit /b 0',
        ':LogVar', '>>"!PT142_CASE!\log.txt" echo !%~1!', 'exit /b 0',
        ':MenuAdvanced', 'exit /b 0')

    # ---- fake answers
    $regOut = { param([string]$Key, [string]$Name, [string]$Type, [string]$Data) "`r`n$Key`r`n    $Name    $Type    $Data`r`n`r`n" }
    $u = [System.Text.Encoding]::Unicode
    $wuKey = 'Software\Policies\Microsoft\Windows\WindowsUpdate'
    # one argument per entry, each @(key, value name, type, [byte[]] data) - never a list of
    # entries, which a pair of grouping parentheses would unwrap when it holds just one
    $polBytes = {
        $bytes = New-Object 'System.Collections.Generic.List[byte]'
        $bytes.AddRange([byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0))
        foreach ($e in $args) {
            $bytes.AddRange($u.GetBytes('[' + $e[0] + [char]0 + ';' + $e[1] + [char]0 + ';'))
            $bytes.AddRange([BitConverter]::GetBytes([uint32]$e[2])); $bytes.AddRange($u.GetBytes(';'))
            $bytes.AddRange([BitConverter]::GetBytes([uint32]$e[3].Length)); $bytes.AddRange($u.GetBytes(';'))
            $bytes.AddRange([byte[]]$e[3]); $bytes.AddRange($u.GetBytes(']'))
        }
        , $bytes.ToArray()
    }
    $dw = { param([uint32]$n) , [BitConverter]::GetBytes($n) }
    $v = 'ExcludeWUDriversInQualityUpdate'
    $n1 = @($wuKey, 'DeferQualityUpdates', 4, (& $dw 1))
    $n2 = @('Software\Policies\Microsoft\Windows\DataCollection', 'Blob', 3, [byte[]](1, 2, 3))   # odd length
    $delMark = @($wuKey, ('**del.' + $v), 1, $u.GetBytes(' ' + [char]0))
    # "**DelVals" deletes every value in the key: spelled so in Microsoft's format page. The worker
    # matches it as a prefix, so the form with a trailing "." (as "**del." has) must count too
    $valsDoc = @($wuKey, '**DelVals', 1, $u.GetBytes(' ' + [char]0))
    $valsDot = @($wuKey, '**delvals.', 1, $u.GetBytes(' ' + [char]0))
    $pol = @{
        set0       = & $polBytes $n1 $n2 @($wuKey, $v, 4, (& $dw 0))
        set1       = & $polBytes $n2 @($wuKey, $v, 4, (& $dw 1)) $n1
        del        = & $polBytes $n2 $delMark
        otherkey   = & $polBytes @(($wuKey + '\AU'), $v, 4, (& $dw 1))
        lower0     = & $polBytes @($wuKey.ToLowerInvariant(), $v.ToLowerInvariant(), 4, (& $dw 0))
        sz         = & $polBytes @($wuKey, $v, 1, $u.GetBytes('1' + [char]0))
        setThenDel = & $polBytes @($wuKey, $v, 4, (& $dw 1)) $n2 $delMark
        # the LAST entry wins - a first-match search answers 'set 0' / 'set 1' / 'set 0' here
        set0then1   = & $polBytes @($wuKey, $v, 4, (& $dw 0)) $n1 @($wuKey, $v, 4, (& $dw 1))
        delSetDel   = & $polBytes $delMark @($wuKey, $v, 4, (& $dw 1)) $n2 $delMark
        valsThenSet = & $polBytes $valsDot $n1 @($wuKey, $v, 4, (& $dw 0))
        setThenVals = & $polBytes @($wuKey, $v, 4, (& $dw 1)) $n2 $valsDoc
        header  = [byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0)
        empty   = [byte[]]@()
    }
    $vG = { param([string]$d) & $regOut 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 'REG_DWORD' $d }
    $vM = { param([string]$d) & $regOut 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device\Update' 'ExcludeWUDriversInQualityUpdate' 'REG_DWORD' $d }
    $vI = { param([string]$d) & $regOut 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device\Update' 'IgnoreWindowsUpdateGroupPolicies' 'REG_DWORD' $d }
    $vE = { param([string]$d) & $regOut 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID' 'REG_SZ' $d }

    $ok = '[OK] Windows Update will stop offering drivers once it rereads its policy'
    $okOn = '[OK] Driver updates back to the Windows default'
    $gpWarn = '[WARN] The Group Policy Editor (gpedit.msc) also sets this policy, to '
    $same = '[i] The Group Policy Editor (gpedit.msc) configures this value the same way, so it stays.'
    $applies = 'that value now applies'
    # a conflict with the Group Policy Editor: the value was written and read back, so the summary
    # names what Group Policy will do, and :Summary's generic failure tail must not follow it
    $offGp = '[WARN] Block written, but the Group Policy Editor will override it - change it in gpedit.msc.'
    $onKeep = '[WARN] Drivers stay allowed, but the Group Policy Editor will put its own value back.'
    $onBlock = '[WARN] Value deleted, but the Group Policy Editor will put its 1 (block) back - change it there.'
    $onGp = '[WARN] Value deleted, but the Group Policy Editor will put its own value back - change it there.'
    $cause = '       Not a failed write: the change was made and read back. The [WARN] above is the reason.'
    $tail = @('could NOT be applied', 'See the [FAIL]', 'protected or held by Windows', 'NOT elevated', 'restart Windows')
    # run: Off / On / a gpedit check wanting blocked|unset. gp/mdm/ign/ed = fake reg answers ('' = none),
    # b = WIN_BUILD, fail = the write fails (not elevated), stuck = the write "succeeds" but changes nothing,
    # pol = the fake Registry.pol ($null = none, 'lock' = held open so it cannot be read),
    # gpc = what _wdgpc must hold afterwards ('' = nothing), log = what the log must hold.
    $cases = @(
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = $null;  fails = 0; has = @($ok); hasnt = @('[FAIL]', '[WARN]', 'Group Policy Editor') },
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = $null;  stuck = 1; fails = 1; has = @('[FAIL] The value did not read back as a DWORD 1', '[WARN] Windows Update will stop offering drivers'); hasnt = @('[OK]', 'Group Policy Editor') },
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = 'set0'; fail = 1; fails = 1; has = @('[WARN] Windows Update will stop offering drivers', 'NOT elevated'); hasnt = @('[OK]', 'Group Policy Editor', 'did not read back') },
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Core');         b = '26100'; pol = $null;  fails = 0; has = @('[OK] Policy written, but its effect on this edition or build is unverified'); hasnt = @('will stop offering') },
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Professional'); b = '10586'; pol = $null;  fails = 0; has = @('[OK] Policy written, but its effect on this edition or build is unverified'); hasnt = @('will stop offering') },
        @{ run = 'Off'; gp = '';           mdm = (& $vM '0x1'); ign = (& $vI '0x1'); ed = (& $vE 'Professional'); b = '26100'; pol = $null; fails = 0; has = @('[OK] Policy written, but Windows Update is set to ignore Group Policy here'); hasnt = @('will stop offering') },
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = 'set0'; fails = 1; gpc = 'replace'; has = @(($gpWarn + '0.'), 're-applies it at its next refresh or restart', $offGp, $cause); hasnt = @('[OK]', 'will stop offering drivers') + $tail },
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = 'set1'; fails = 0; has = @($same, $ok); hasnt = @('[WARN]') },
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = '';                     b = '26100'; pol = $null;  stuck = 1; fails = 1; has = @('[FAIL] The value did not read back as a DWORD 1'); hasnt = @('[OK]') },
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = '';          ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = $null;  fails = 0; has = @($okOn); hasnt = @($applies, '[FAIL]', '[WARN]') },
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = (& $vM '0x1'); ign = '';         ed = (& $vE 'Professional'); b = '26100'; pol = $null;  stuck = 1; fails = 1; has = @('[FAIL] The value did not read back as deleted', '[WARN] Driver updates back to the Windows default'); hasnt = @($applies, '[OK]') },
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = (& $vM '0x1'); ign = '';         ed = (& $vE 'Professional'); b = '26100'; pol = $null;  fails = 0; has = @($okOn, "[i] Your organization's MDM policy sets this to 0x1 - that value now applies."); hasnt = @('[WARN]') },
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = '';          ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = 'set0'; fails = 1; gpc = 'keep'; has = @(($gpWarn + '0.'), $onKeep, $cause); hasnt = @('[OK]', 'back to the Windows default') + $tail },
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = '';          ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = 'del';  fails = 0; has = @($same, $okOn); hasnt = @('[WARN]') },
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = (& $vM '0x1'); ign = (& $vI '0x1'); ed = (& $vE 'Professional'); b = '26100'; pol = $null; fails = 0; has = @('[OK] Policy value removed; Windows Update is set to ignore Group Policy here, so MDM decides.', $applies); hasnt = @('back to the Windows default') },
        @{ run = 'On';  gp = '';           mdm = '';           ign = '';           ed = '';                     b = '26100'; pol = $null;  fails = 1; has = @('[FAIL] The value did not read back as deleted'); hasnt = @('[OK]') },
        # gpedit puts the block back: no "now applies" for MDM (Group Policy wins again), no default
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = (& $vM '0x1'); ign = '';         ed = (& $vE 'Professional'); b = '26100'; pol = 'set1'; fails = 1; gpc = 'block'; has = @(($gpWarn + '1.'), $onBlock, $cause); hasnt = @($applies, '[OK]', 'back to the Windows default', 'Drivers stay allowed') + $tail },
        # right after a conflict, a failed write skips the check: the old conflict and its cause must not leak
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Professional'); b = '26100'; pol = 'set0'; fail = 1; fails = 1; has = @('[WARN] Windows Update will stop offering drivers', 'could NOT be applied', 'NOT elevated'); hasnt = @('[OK]', 'Group Policy Editor', 'Not a failed write') },
        # the conflict decides before the edition gate and before the ignore switch
        @{ run = 'Off'; gp = '';           mdm = '';           ign = '';           ed = (& $vE 'Core');         b = '26100'; pol = 'set0'; fails = 1; gpc = 'replace'; has = @($offGp, $cause); hasnt = @('[OK]', 'unverified') + $tail },
        @{ run = 'On';  gp = (& $vG '0x1'); mdm = (& $vM '0x1'); ign = (& $vI '0x1'); ed = (& $vE 'Professional'); b = '26100'; pol = 'sz'; fails = 1; gpc = 'replace'; has = @(($gpWarn + 'a non-DWORD value.'), $onGp, $cause); hasnt = @('[OK]', 'MDM decides', $applies) + $tail },
        # res = what the worker must answer for that Registry.pol; real = start the worker line itself
        @{ run = 'blocked'; pol = $null;      res = 'none';   fails = 0; has = @(); hasnt = @('Group Policy Editor', 'Could not check') },
        @{ run = 'blocked'; pol = 'header';   res = 'none';   fails = 0; has = @(); hasnt = @('Group Policy Editor', 'Could not check') },
        @{ run = 'blocked'; pol = 'empty';    res = 'none';   fails = 0; has = @(); hasnt = @('Group Policy Editor', 'Could not check') },
        @{ run = 'blocked'; pol = 'set0';     res = 'set 0';  fails = 1; gpc = 'replace'; has = @(($gpWarn + '0.')); hasnt = @(); real = 1 },
        @{ run = 'blocked'; pol = 'set1';     res = 'set 1';  fails = 0; has = @($same); hasnt = @('[WARN]') },
        @{ run = 'unset';   pol = 'set1';     res = 'set 1';  fails = 1; gpc = 'block'; has = @(($gpWarn + '1.')); hasnt = @() },
        @{ run = 'unset';   pol = 'del';      res = 'del';    fails = 0; has = @($same); hasnt = @('[WARN]') },
        @{ run = 'blocked'; pol = 'del';      res = 'del';    fails = 1; gpc = 'replace'; has = @('[WARN] The Group Policy Editor (gpedit.msc) is set to delete this policy value.'); hasnt = @() },
        @{ run = 'blocked'; pol = 'otherkey'; res = 'none';   fails = 0; has = @(); hasnt = @('Group Policy Editor') },
        @{ run = 'unset';   pol = 'lower0';   res = 'set 0';  fails = 1; gpc = 'keep'; has = @(($gpWarn + '0.')); hasnt = @() },
        @{ run = 'blocked'; pol = 'sz';       res = 'set ?';  fails = 1; gpc = 'replace'; has = @(($gpWarn + 'a non-DWORD value.')); hasnt = @() },
        @{ run = 'blocked'; pol = 'setThenDel'; res = 'del';  fails = 1; gpc = 'replace'; has = @('is set to delete this policy value'); hasnt = @('also sets this policy') },
        @{ run = 'blocked'; pol = 'set0then1';  res = 'set 1'; fails = 0; has = @($same); hasnt = @('[WARN]') },
        @{ run = 'unset';   pol = 'delSetDel';  res = 'del';   fails = 0; has = @($same); hasnt = @('[WARN]') },
        @{ run = 'blocked'; pol = 'setThenVals'; res = 'del';  fails = 1; gpc = 'replace'; has = @('is set to delete this policy value'); hasnt = @('also sets this policy') },
        @{ run = 'unset';   pol = 'valsThenSet'; res = 'set 0'; fails = 1; gpc = 'keep'; has = @(($gpWarn + '0.')); hasnt = @('is set to delete') },
        @{ run = 'blocked'; pol = 'lock';     res = 'unread'; fails = 0; log = 'INFO: could not read Registry.pol'; has = @('[i] Could not check whether the Group Policy Editor also sets this policy (Registry.pol).'); hasnt = @('[WARN]') }
    )

    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '[\s%]') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT142_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Assert-True ($dir -notmatch '%') ('test 142 cannot run here: the temp folder path holds a "%" and has no short name ({0}).' -f $dir)
    $lock = $null
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        $w = { param($f, $t) [System.IO.File]::WriteAllText($f, $t, [System.Text.Encoding]::ASCII) }
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($k = 1; $k -le $cases.Count; $k++) {
            $c = $cases[$k - 1]
            # the gpedit-only cases leave the registry answers out; StrictMode wants every key present
            foreach ($f in 'gp', 'mdm', 'ign', 'ed') { if (-not $c.ContainsKey($f)) { $c[$f] = '' } }
            foreach ($f in 'b', 'fail', 'stuck', 'res', 'real', 'log') { if (-not $c.ContainsKey($f)) { $c[$f] = $null } }
            if (-not $c.ContainsKey('gpc')) { $c['gpc'] = '' }
            $cd = Join-Path $dir ("c$k")
            [void](New-Item -ItemType Directory -Force -Path $cd)
            foreach ($f in 'gp', 'mdm', 'ign', 'ed') { & $w (Join-Path $cd "$f.txt") $c[$f] }
            if ($null -ne $c.pol) {
                $pd = Join-Path $cd 'System32\GroupPolicy\Machine'
                [void](New-Item -ItemType Directory -Force -Path $pd)
                $pf = Join-Path $pd 'Registry.pol'
                if ($c.pol -eq 'lock') {
                    [System.IO.File]::WriteAllBytes($pf, $pol['set0'])
                    $lock = [System.IO.File]::Open($pf, 'Open', 'Read', 'None')
                } else { [System.IO.File]::WriteAllBytes($pf, [byte[]]$pol[$c.pol]) }
            }
            # the worker's own text, run the way PowerShell runs it (no strict mode, errors go on) in a
            # fresh runspace: in this test's scope it could read $b, $c, $i ... wherever it forgot to
            # assign one first, and pass here while failing in a real powershell -NoProfile
            $res = Join-Path $cd 'polres.txt'
            $env:PT_WDPOLSRC = Join-Path $cd 'System32\GroupPolicy\Machine\Registry.pol'
            $env:PT_WDPOL = $res
            $iso = [powershell]::Create()
            try { [void]$iso.AddScript($payload); [void]$iso.Invoke() }
            finally { $iso.Dispose(); Remove-Item Env:\PT_WDPOLSRC, Env:\PT_WDPOL -ErrorAction SilentlyContinue }
            Assert-True (Test-Path -LiteralPath $res) "test 142 case ${k}: the worker wrote no answer."
            $got = ([System.IO.File]::ReadAllText($res)).Trim()
            if ($null -ne $c.res) { Assert-True ($got -eq $c.res) ("test 142 case {0}: for the Registry.pol '{1}' the worker answered '{2}', expected '{3}' (regression)." -f $k, $c.pol, $got, $c.res) }
            # the real run must produce its own answer: nothing to copy
            if ($c.real) { Remove-Item -LiteralPath $res -Force }
            $drv += ('set "PT142_CASE=!PT142_DIR!\c{0}"' -f $k)
            # the worker's answer file goes to !TEMP!: keep it in this case's folder, where the test can
            # see whether it was deleted - and out of the real %TEMP%
            $drv += 'set "TEMP=!PT142_CASE!" & set "TMP=!PT142_CASE!" & set "_wdpolf="'
            $drv += $(if ($c.real) { 'set "PT142_REALPS=1"' } else { 'set "PT142_REALPS="' })
            $drv += ('set "MACHINE=desktop" & set "WIN_BUILD={0}" & set "_FAILS=0"' -f $(if ($c.b) { $c.b } else { '26100' }))
            $drv += $(if ($c.fail) { 'set "FAKEFAIL=1" & set "_ELEV=0"' } else { 'set "FAKEFAIL=" & set "_ELEV=1"' })
            $drv += $(if ($c.stuck) { 'set "FAKESTUCK=1"' } else { 'set "FAKESTUCK="' })
            $drv += ('echo [CASE#{0}]' -f $k)
            $drv += $(switch ($c.run) { 'Off' { 'call :WuDrvOff' } 'On' { 'call :WuDrvOn' } default { 'call :WuDrvGpCheck ' + $c.run } })
            $drv += ('echo [POLF#{0}#]!_wdpolf!' -f $k)
            $drv += ('echo [END#{0}#!_FAILS!#!_wdgpc!#]' -f $k)
        }
        $body = $drv + @('exit /b 0') + $code + $stubs
        $live = @($body | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and ($_ -match '(?i)\breg\s+(query|add|delete)\b|\bstart\b.*powershell|!SystemRoot!|%SystemRoot%') })
        Assert-True (@($body | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)powershell' }).Count -eq 1 -and @($cases | Where-Object { $_.real }).Count -eq 1) 'test 142: expected exactly one real worker line and one case that runs it.'
        Assert-True ($live.Count -eq 0) ('test 142: the driver still contains a real reg command, a minimized worker window or the real SystemRoot - refusing to run it: ' + ($live -join ' | '))
        $drvPath = Join-Path $dir 'drv.cmd'
        [System.IO.File]::WriteAllLines($drvPath, [string[]]$body, [System.Text.Encoding]::ASCII)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c ""' + $drvPath + '""'
        $psi.WorkingDirectory = $dir
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PT142_DIR'] = $dir
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(180000)) { $p.Kill(); throw 'test 142: the handler driver did not finish within 180 s.' }
        Assert-True ($p.ExitCode -eq 0) ("test 142: the handler driver failed (exit {0}): {1}" -f $p.ExitCode, $err.Result.Trim())
        Assert-True ($err.Result.Trim() -eq '') ("test 142: the handlers wrote to stderr: {0}" -f $err.Result.Trim())
        $all = @($out -split "`r?`n")
        for ($k = 1; $k -le $cases.Count; $k++) {
            $c = $cases[$k - 1]
            $i0 = [Array]::IndexOf($all, ('[CASE#{0}]' -f $k))
            $i1 = -1; for ($i = [Math]::Max($i0, 0); $i -lt $all.Count; $i++) { if ($all[$i].StartsWith(('[END#{0}#' -f $k))) { $i1 = $i; break } }
            Assert-True ($i0 -ge 0 -and $i1 -gt $i0) "test 142 case ${k}: no end line - the handler did not run to the end."
            $pfx = '[POLF#{0}#]' -f $k
            $pl = @($all[$i0..$i1] | Where-Object { $_.StartsWith($pfx) })
            Assert-True ($pl.Count -eq 1) "test 142 case ${k}: no [POLF] line - the driver changed shape."
            $polf = $pl[0].Substring($pfx.Length)
            $text = $(if ($i1 -gt $i0 + 1) { @($all[($i0 + 1)..($i1 - 1)] | Where-Object { -not $_.StartsWith($pfx) }) -join "`n" } else { '' })
            $got = $all[$i1].Split('#')[2]
            $gotGpc = $all[$i1].Split('#')[3]
            $who = '{0} {1}' -f $c.run, $(if ($c.pol) { 'pol=' + $c.pol } else { '' })
            Assert-True ($got -eq [string]$c.fails) ("test 142 case {0} ({1}): _FAILS is {2}, expected {3} - an outcome was miscounted (regression). Output: {4}" -f $k, $who, $got, $c.fails, ($text -replace "`n", ' | '))
            Assert-True ($gotGpc -eq $c.gpc) ("test 142 case {0} ({1}): _wdgpc is '{2}', expected '{3}' - the handler would pick the wrong summary, or an earlier conflict leaked into this run (regression)." -f $k, $who, $gotGpc, $c.gpc)
            # the check ran exactly when it should (a failed write skips it), in this case's folder,
            # and left no answer file behind
            $cd = Join-Path $dir ("c$k")
            $ran = ($c.run -eq 'blocked' -or $c.run -eq 'unset' -or $c.fails -eq 0 -or $c.gpc -ne '')
            Assert-True ($ran -eq ($polf -ne '')) ("test 142 case {0} ({1}): the Group Policy Editor check {2} (answer file '{3}')." -f $k, $who, $(if ($ran) { 'did not run' } else { 'ran after a failed write' }), $polf)
            if ($ran) { Assert-True ($polf.StartsWith($cd + '\pt_wdpol_', [StringComparison]::OrdinalIgnoreCase)) ("test 142 case {0}: the answer file '{1}' is not in the case folder - TEMP was not redirected, and a leftover could not be seen." -f $k, $polf) }
            $left = @(Get-ChildItem -LiteralPath $cd -Filter 'pt_wdpol_*' -Force -ErrorAction SilentlyContinue)
            Assert-True ($left.Count -eq 0) ("test 142 case {0} ({1}): the Group Policy Editor check left its answer file behind ({2}) - every change would leave one in %TEMP% (regression)." -f $k, $who, (($left | ForEach-Object { $_.Name }) -join ', '))
            # a counted conflict is logged; nothing else logs a conflict
            $lf = Join-Path $cd 'log.txt'
            $logText = $(if (Test-Path -LiteralPath $lf) { [System.IO.File]::ReadAllText($lf) } else { '' })
            if ($c.gpc -ne '') { Assert-True ($logText.Contains('WARN: Registry.pol (gpedit.msc) holds ExcludeWUDriversInQualityUpdate as: ')) ("test 142 case {0} ({1}): the Group Policy Editor conflict is not in the log (regression). Log: {2}" -f $k, $who, $logText.Trim()) }
            else { Assert-True (-not $logText.Contains('WARN: Registry.pol')) ("test 142 case {0} ({1}): a conflict was logged where there is none. Log: {2}" -f $k, $who, $logText.Trim()) }
            if ($c.log) { Assert-True ($logText.Contains($c.log)) ("test 142 case {0} ({1}): the log does not say '{2}'. Log: {3}" -f $k, $who, $c.log, $logText.Trim()) }
            foreach ($h in $c.has)   { Assert-True ($text.Contains($h))      ("test 142 case {0} ({1}): the output does not say '{2}'. Output: {3}" -f $k, $who, $h, ($text -replace "`n", ' | ')) }
            foreach ($h in $c.hasnt) { Assert-True (-not $text.Contains($h)) ("test 142 case {0} ({1}): the output says '{2}' and must not. Output: {3}" -f $k, $who, $h, ($text -replace "`n", ' | ')) }
        }
    }
    finally {
        if ($null -ne $lock) { $lock.Dispose() }
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

# ---- helpers for tests 143-146: the [Page file] section of Status ----------------------------
# The page-file worker is the one code line that hands its answer back through $env:PT_PGF_RES.
function Get-PgfWorker {
    param([string[]]$Lines)
    $Lines | Where-Object { $_.TrimStart() -notmatch '^(?i)rem\b' -and $_.Contains('$env:PT_PGF_RES') -and $_ -match '(?i)powershell -NoProfile -Command "' }
}

# The worker's payload is held to an ALLOWLIST read by PowerShell's own parser: the commands and
# the shape of each call, the parameters, the method calls, the static members (type and name),
# the types it names or casts to, the variables it qualifies or assigns, and the one C#
# declaration. The first draft's denylist of writers missed Clear-ItemProperty, module-qualified
# names, aliases, [Microsoft.Win32.Registry] and WMI .Put(). The first allowlist missed a method
# run through ForEach-Object -MemberName, a static property read, a $script:r or foreach-loop $r
# fed to & $r, and a > redirection. Tests 144 and 146 RUN this payload, with writers also blocked
# at run time, so this is what keeps an accidental writer away from the real registry. It guards
# against regressions; it is not a proof against a writer disguised on purpose.
# Returns what is off the list (nothing = read-only).
function Get-PgfPayloadProblems {
    param([string]$Payload)
    $bad = New-Object System.Collections.Generic.List[string]
    $tok = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Payload, [ref]$tok, [ref]$perr)
    if (@($perr).Count -gt 0) { $bad.Add('it does not parse: ' + $perr[0].Message); return $bad.ToArray() }
    $all = @($ast.FindAll({ param($n) $true }, $true))
    $cmds = @($all | Where-Object { $_ -is [System.Management.Automation.Language.CommandAst] })
    if ($cmds.Count -lt 10) { $bad.Add(('only {0} command(s) found - the scan is not reading the worker' -f $cmds.Count)) }
    $okCmd = @('Get-ItemProperty', 'Get-CimInstance', 'New-Object', 'Add-Type', 'Out-File', 'Sort-Object', 'ForEach-Object', 'Where-Object', 'Cl', 'Nm')
    foreach ($c in $cmds) {
        $n = $c.GetCommandName(); $e = @($c.CommandElements)
        if ($null -eq $n) {
            # the one call without a name is & $r, the reader of GetPerformanceInfo's buffer
            if (-not ($c.InvocationOperator -eq 'Ampersand' -and $e[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $e[0].VariablePath.UserPath -eq 'r')) { $bad.Add('a call with no command name: ' + $c.Extent.Text) }
            continue
        }
        if ($okCmd -notcontains $n) { $bad.Add('command ' + $n); continue }
        # one script block and nothing else: -MemberName, or a bare member name, runs a method no other check sees
        if (@('ForEach-Object', 'Where-Object') -contains $n -and -not ($e.Count -eq 2 -and $e[1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { $bad.Add($n + ' with anything but one script block: ' + $c.Extent.Text) }
        if ($n -eq 'Sort-Object' -and $c.Extent.Text -cne 'Sort-Object -Unique') { $bad.Add('Sort-Object with anything but -Unique: ' + $c.Extent.Text) }
        if ($n -eq 'Add-Type' -and -not ($e.Count -eq 3 -and $e[1] -is [System.Management.Automation.Language.CommandParameterAst] -and $e[1].ParameterName -eq 'TypeDefinition')) { $bad.Add('Add-Type with anything but -TypeDefinition: ' + $c.Extent.Text) }
        if ($n -eq 'New-Object') {
            $par = @($e | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
            if ($e.Count -lt 2 -or $par.Count -gt 0 -or -not ($e[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or @('Collections.Generic.List[string]', 'byte[]') -notcontains $e[1].Extent.Text) { $bad.Add('New-Object other than a string list or a byte array: ' + $c.Extent.Text) }
        }
        if ($n -eq 'Out-File' -and $c.Extent.Text -cne 'Out-File -FilePath $env:PT_PGF_RES -Encoding ASCII') { $bad.Add('Out-File to something other than its answer file: ' + $c.Extent.Text) }
    }
    # parameters: only the ones the worker uses (-OutVariable, -OutputAssembly and the like are off)
    $okPar = @('ClassName', 'Encoding', 'ErrorAction', 'FilePath', 'LiteralPath', 'TypeDefinition', 'Unique')
    foreach ($p in @($all | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })) { if ($okPar -notcontains $p.ParameterName) { $bad.Add('parameter -' + $p.ParameterName) } }
    # methods by name; static members by type and name, [IntPtr]::Size the one static property read
    $okCall = @('Add', 'Substring', 'ToUpper', 'Trim')
    $okStatic = @('[BitConverter]::ToUInt32', '[BitConverter]::ToUInt64', '[math]::Floor', '[PTPf.N]::GPI', '[regex]::Match')
    foreach ($m in @($all | Where-Object { $_ -is [System.Management.Automation.Language.MemberExpressionAst] })) {
        $call = $m -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
        if (-not $call -and -not $m.Static) { continue }
        if (-not ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst])) { $bad.Add('a member with a computed name: ' + $m.Extent.Text); continue }
        if (-not $m.Static) { if ($okCall -notcontains $m.Member.Value) { $bad.Add('method ' + $m.Member.Value) }; continue }
        $key = $m.Expression.Extent.Text + '::' + $m.Member.Value
        $ok = $m.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $(if ($call) { $okStatic -contains $key } else { $key -eq '[IntPtr]::Size' })
        if (-not $ok) { $bad.Add('static member ' + $m.Extent.Text) }
    }
    # types: a cast can run a constructor ([IO.StreamWriter]'x' creates the file), so every type
    # literal and cast is listed, and -as / -is take a type literal only; no redirection
    $okType = @('BitConverter', 'char', 'double', 'int', 'int64', 'IntPtr', 'math', 'pscustomobject', 'PTPf.N', 'regex', 'string', 'type')
    foreach ($t in @($all | Where-Object { $_ -is [System.Management.Automation.Language.TypeExpressionAst] -or $_ -is [System.Management.Automation.Language.TypeConstraintAst] })) { if ($okType -notcontains $t.TypeName.FullName) { $bad.Add('type [' + $t.TypeName.FullName + ']') } }
    foreach ($b in @($all | Where-Object { $_ -is [System.Management.Automation.Language.BinaryExpressionAst] -and @('As', 'Is', 'IsNot') -contains [string]$_.Operator -and -not ($_.Right -is [System.Management.Automation.Language.TypeExpressionAst]) })) { $bad.Add('a conversion to a computed type: ' + $b.Extent.Text) }
    foreach ($x in @($all | Where-Object { $_ -is [System.Management.Automation.Language.RedirectionAst] })) { $bad.Add('a redirection: ' + $x.Extent.Text) }
    # variables: the only qualified ones are the two environment values it reads, and an
    # assignment sets a plain variable or a property of one
    foreach ($v in @($all | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $_.VariablePath.IsUnqualified })) {
        if (@('env:SystemDrive', 'env:PT_PGF_RES') -notcontains $v.VariablePath.UserPath) { $bad.Add('variable $' + $v.VariablePath.UserPath) }
    }
    foreach ($a in @($all | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] })) {
        $l = $a.Left
        if ($l -is [System.Management.Automation.Language.MemberExpressionAst] -and -not $l.Static) { $l = $l.Expression }
        if (-not ($l -is [System.Management.Automation.Language.VariableExpressionAst] -and $l.VariablePath.IsUnqualified)) { $bad.Add('an assignment to ' + $a.Left.Extent.Text) }
    }
    # $r and $q are each set once, to the buffer reader and to a double quote; $r only ever runs
    # as & $r, and $q is read only inside the Add-Type (a foreach or param named r or q fails too)
    $at = @($cmds | Where-Object { $_.GetCommandName() -eq 'Add-Type' })
    foreach ($vn in @('r', 'q')) {
        $set = 0
        foreach ($v in @($all | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.VariablePath.UserPath -eq $vn })) {
            $pa = $v.Parent
            if ($pa -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($pa.Left, $v)) {
                $set++
                $want = $(if ($vn -eq 'r') { '^\{param\(\$i\)' } else { '^\[char\]34$' })
                if ($pa.Operator -ne 'Equals' -or $pa.Right.Extent.Text -notmatch $want) { $bad.Add(('${0} is set by {1}' -f $vn, $pa.Extent.Text)) }
            }
            elseif ($vn -eq 'r' -and -not ($pa -is [System.Management.Automation.Language.CommandAst] -and $pa.InvocationOperator -eq 'Ampersand' -and [object]::ReferenceEquals($pa.CommandElements[0], $v))) { $bad.Add('$r used other than as & $r: ' + $pa.Extent.Text) }
            elseif ($vn -eq 'q' -and -not ($at.Count -eq 1 -and $v.Extent.StartOffset -ge $at[0].Extent.StartOffset -and $v.Extent.EndOffset -le $at[0].Extent.EndOffset)) { $bad.Add('$q used outside the Add-Type: ' + $pa.Extent.Text) }
        }
        if ($set -ne 1) { $bad.Add(('${0} is set {1} time(s), expected once' -f $vn, $set)) }
    }
    if ($at.Count -ne 1) { $bad.Add(('{0} Add-Type calls, expected the one for GetPerformanceInfo' -f $at.Count)) }
    else {
        $vars = @($at[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique)
        $decl = @($at[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord' }, $true) | ForEach-Object { $_.Value }) -join ''
        $one = 'using System.Runtime.InteropServices;namespace PTPf{public static class N{[DllImport(kernel32.dll,EntryPoint=K32GetPerformanceInfo)]public static extern bool GPI([Out] byte[] b,int cb);}}'
        if (($vars -join ',') -ne 'q' -or $decl -cne $one) { $bad.Add('Add-Type compiles something other than the one read-only GetPerformanceInfo import: ' + $decl) }
    }
    $bad.ToArray()
}

# Runs $Script in a child Windows PowerShell, with the worker payload in PT_T_PAYLOAD. The script
# goes to a temp .ps1 run with -File (encoded, it would pass the 32767 characters a command line
# may hold), in ASCII on purpose: Windows PowerShell reads a BOM-less .ps1 as ANSI.
function Invoke-PgfChild {
    param([string]$Script, [string]$Payload, [string]$Tag)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $runner = Join-Path ([IO.Path]::GetTempPath()) ('{0}_{1}.ps1' -f $Tag, [guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($runner, $Script, [Text.Encoding]::ASCII)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runner + '"'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PT_T_PAYLOAD'] = $Payload
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw ('{0}: the child PowerShell did not finish within 120 s.' -f $Tag) }
        @{ Exit = $p.ExitCode; Out = $out.Result; Err = $err.Result.Trim() }
    }
    finally { if (Test-Path -LiteralPath $runner) { Remove-Item -LiteralPath $runner -Force } }
}

# ===============================================================================
# 143. The [Page file] section of Status: wired in, read-only, and every verdict
#      comes from the worker. sincript SHOWS the page-file and crash-dump settings
#      and must never write them. Two halves hold that: the page-file and crash-dump
#      names (PagingFiles, CrashControl, Win32_PageFileSetting ...) appear in ONE
#      code line of the whole script - the worker - and that worker's payload uses
#      only commands, methods and types on a read-only allowlist, read with
#      PowerShell's own parser. The worker follows the house hand-off (per-call temp,
#      stale file deleted first, PT_* cleared), the display prints nothing unless the
#      worker wrote its closing END record, [ADVISORY] exists only in the advisory
#      branches, and the verdicts the worker can emit are the ones the display handles.
# ===============================================================================
Invoke-Test 'Page file status: wired in, read-only, verdicts only from the worker' {
    $cmd = Read-Lines $CmdPath

    # --- wiring: Status calls it once, right after [Memory compression], and nothing else calls it
    $st = @(Get-BodyLines -Lines $cmd -Label 'Status' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($st.Count -gt 40) (':Status body did not unroll ({0} lines).' -f $st.Count)
    Assert-True (@($cmd | Where-Object { $_ -match '(?i)\bcall\s+:PageFileStatus\b' }).Count -eq 1 -and @($st | Where-Object { $_ -ieq 'call :PageFileStatus' }).Count -eq 1) ':Status no longer calls :PageFileStatus exactly once, or something else calls it too - the [Page file] section is gone, doubled or moved (regression).'
    $iMma = -1; $iCall = -1; $iHosts = -1
    for ($i = 0; $i -lt $st.Count; $i++) {
        if ($st[$i] -like 'echo `[Memory compression`]*') { $iMma = $i }
        if ($st[$i] -ieq 'call :PageFileStatus') { $iCall = $i }
        if ($st[$i] -like 'echo `[hosts file`]*') { $iHosts = $i }
    }
    Assert-True ($iMma -ge 0 -and $iCall -gt $iMma -and $iHosts -gt $iCall) (':Status shows [Page file] somewhere other than between [Memory compression] and [hosts file] (lines {0}/{1}/{2}).' -f $iMma, $iCall, $iHosts)
    $pf = (Get-BodyLines -Lines $cmd -Label 'PageFileStatus' -CodeOnly) -join "`n"
    Assert-True ($pf.Length -gt 200) ':PageFileStatus has no code.'
    # A leftover file is deleted before the worker runs (it must never be read as this run's
    # answer), and the result is deleted only after it has been shown. Each step is searched
    # for AFTER the previous one, so the two identical deletes are told apart.
    $order = @('set "_pgfres=!TEMP!\pt_pgf_%RANDOM%%RANDOM%.txt"', 'del "!_pgfres!" >nul 2>&1', 'set "PT_PGF_RES=!_pgfres!"', 'start "" /min /wait powershell -NoProfile -Command "', 'set "PT_PGF_RES="', 'call :_pgfShow', 'del "!_pgfres!" >nul 2>&1')
    $pos = -1
    foreach ($step in $order) {
        $next = $pf.IndexOf($step, $pos + 1)
        Assert-True ($next -gt $pos) (':PageFileStatus lost "{0}", or runs it out of order - per-call name, stale-file delete, hand-off, worker, clear, show, delete is the only safe order (regression).' -f $step)
        $pos = $next
    }

    # --- nothing is shown or judged unless the worker finished
    $sh = (Get-BodyLines -Lines $cmd -Label '_pgfShow' -CodeOnly) -join "`n"
    $g1 = $sh.IndexOf('findstr /b /l /c:"END|ok" "!_pgfres!"'); $g2 = $sh.IndexOf('if not defined _pgfok goto _pgfNone'); $g3 = $sh.IndexOf('for /f "usebackq tokens=1-6 delims=|"')
    Assert-True ($g1 -ge 0 -and $g2 -gt $g1 -and $g3 -gt $g2) ':_pgfShow reads records before proving the worker wrote its END record - a half-written file would be half-judged (regression).'

    # --- [ADVISORY] appears only under a _pgfAdv* label, in all three bodies of the section, on
    #     any non-rem line ("if x echo [ADVISORY]" is the likely stray shape); and every verdict
    #     the worker can emit has exactly one branch, and no branch is dead
    $raw = @(':PageFileStatus') + @(Get-BodyLines -Lines $cmd -Label 'PageFileStatus') + @(':_pgfShow') + @(Get-BodyLines -Lines $cmd -Label '_pgfShow') + @(':_pgfRec') + @(Get-BodyLines -Lines $cmd -Label '_pgfRec')
    Assert-True ($raw.Count -gt 100) ('The page-file section did not unroll ({0} lines).' -f $raw.Count)
    $cur = ''; $stray = @(); $advN = 0
    foreach ($l in $raw) {
        if ($l -match '^:(\w+)') { $cur = $Matches[1]; continue }
        if ($l.Trim() -notmatch '^(?i)rem\b' -and $l.Contains('[ADVISORY]')) { $advN++; if ($cur -notlike '_pgfAdv?*') { $stray += $cur } }
    }
    Assert-True ($stray.Count -eq 0) ('[ADVISORY] printed outside an advisory branch ({0}) - a verdict must come from an ADV record the worker emitted (regression).' -f ($stray -join ', '))
    Assert-True ($advN -ge 8) ('Only {0} [ADVISORY] line(s) in the page-file section - verdicts or their after-the-restart wording are gone.' -f $advN)
    $wk = @(Get-PgfWorker -Lines $cmd)
    Assert-True ($wk.Count -eq 1) ('Expected one page-file worker line, found {0}.' -f $wk.Count)
    $emit = @([regex]::Matches($wk[0], "'ADV\|([a-z]+)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $handle = @($raw | ForEach-Object { if ($_ -match '^if "!_pgf1!"=="([a-z]+)" goto _pgfAdv\w+') { $Matches[1] } } | Sort-Object -Unique)
    Assert-True ($emit.Count -ge 6) ('Only {0} verdict code(s) found in the worker - the record format changed.' -f $emit.Count)
    Assert-True (($emit -join ',') -ceq ($handle -join ',')) ('Verdicts the worker emits [{0}] and the display handles [{1}] differ - one is never shown, or one is dead (regression).' -f ($emit -join ','), ($handle -join ','))

    # --- the worker reads documented, locale-free sources, and compiles only behind its type guard
    $w = $wk[0]
    foreach ($need in @('PagingFiles', 'ExistingPageFiles', 'Win32_PageFileUsage', 'Win32_OperatingSystem', 'Win32_PhysicalMemory', 'CrashControl', 'CrashDumpEnabled', 'FilterPages', 'DedicatedDumpFile', 'K32GetPerformanceInfo')) {
        Assert-True ($w.Contains($need)) ('The page-file worker no longer reads {0} (regression).' -f $need)
    }
    Assert-True ($w -notmatch '(?i)\b(Get-Counter|systeminfo|wmic|fsutil|powercfg|Get-WmiObject)\b') 'The page-file worker calls a tool whose output is localized text or deprecated - read registry values and WMI properties instead (pitfall 26).'
    Assert-True (([regex]::Matches($w, 'Add-Type')).Count -eq 1 -and $w.IndexOf("'PTPf.N' -as [type]") -ge 0 -and $w.IndexOf("'PTPf.N' -as [type]") -lt $w.IndexOf('Add-Type')) 'The page-file worker compiles GetPerformanceInfo without first checking the type is already there.'

    # --- READ-ONLY, half 1: the payload uses only allowlisted, read-only commands and methods
    $m = [regex]::Match($w, '-Command "(.*)"\s*$')
    Assert-True $m.Success 'The page-file worker lost the -Command "..." shape this test reads.'
    $probs = @(Get-PgfPayloadProblems -Payload $m.Groups[1].Value.Replace('%%', '%'))
    Assert-True ($probs.Count -eq 0) ('The page-file worker uses something off its read-only allowlist - it may only read the registry and WMI and write its own answer file: ' + ($probs -join ' | '))

    # --- READ-ONLY, half 2: no other code line in the script even names a page-file or
    #     crash-dump setting. rem lines are prose, and so is a plain or if-guarded echo line that,
    #     with its ^x escape pairs removed, holds no &, |, < or >. Any other line naming one - a reg
    #     add, a :SafeRegAdd, a set that stages the name, a second worker, an echo that writes a
    #     reg add into a .bat - fails, whatever command it would write with. (The first version
    #     looked only for an & or | without a ^ before it, which let "echo reg add ... PagingFiles
    #     ... /f>>file" and "echo ^^& reg add ..." through.)
    $targets = '(?i)PagingFiles|ExistingPageFiles|TempPageFile|AutomaticManagedPagefile|Win32_PageFileSetting|pagefileset|ClearPageFileAtShutdown|CrashControl|CrashDumpEnabled|DedicatedDumpFile|DumpFileSize|FilterPages'
    $echoLine = '(?i)^\s*(if\s+(/i\s+)?(not\s+)?(defined\s+\S+|exist\s+"[^"]*"|"[^"]*"==\s*"[^"]*")\s+)*echo([\s.:;,(]|$)'
    $code = @($cmd | Where-Object { $t = $_.Trim(); $t -ne '' -and $t -notmatch '^(?i)(rem\b|::)' -and -not ($_ -match $echoLine -and ($_ -replace '\^.', '') -notmatch '[&|<>]') })
    Assert-True ($code.Count -gt 2000 -and @($code | Where-Object { $_ -ceq $w }).Count -eq 1) 'The read-only scan found too little code, or not the worker - it would pass vacuously.'
    $named = @($code | Where-Object { $_ -match $targets -and $_ -cne $w })
    Assert-True ($named.Count -eq 0) ('A code line outside the read-only worker names a page-file or crash-dump setting - sincript shows them and must never change them: ' + (($named | ForEach-Object { $_.Trim().Substring(0, [Math]::Min(90, $_.Trim().Length)) }) -join ' | '))
    Assert-True (@($code | Where-Object { $_ -match '(?i)Win32_PageFileSetting|pagefileset|AutomaticManagedPagefile' }).Count -eq 0) 'Code touches Win32_PageFileSetting / AutomaticManagedPagefile - the WMI write surface for the page file. The status needs neither.'
}

# ===============================================================================
# 144. The page-file CLASSIFIER is RUN on synthetic machines. Its payload is pulled
#      out of the script, checked against test 143's read-only allowlist (it is not
#      run otherwise) and run in a child Windows PowerShell where the registry
#      (Get-ItemProperty) and WMI (Get-CimInstance) answer from test cases - a
#      function outranks a cmdlet - and GetPerformanceInfo is a stand-in that counts
#      its calls. Every writer the allowlist would miss, Add-Type included once the
#      stand-in is loaded, ends the child with 126. Each case pins the exact
#      verdicts: a system-managed file is never judged small; an unrecognised,
#      unreadable or ABSENT setting is never judged; a complete dump "cannot be
#      written" only below RAM + 1 MB and "may be cut short" up to RAM + 257 MB;
#      there is no small-dump rule; a growable file's soft limit is never called
#      full; the commit verdict fires at exactly 90%; a pending change turns the
#      no-page-file verdicts into "after the next restart" and suppresses the
#      commit verdict; an in-use state WMI and the registry disagree on is unknown,
#      and an unknown one gets the "after the next restart" wording too (true
#      whatever is in use now);
#      a CrashDumpEnabled that is not a DWORD is unrecognised, not unreadable; the
#      Windows drive comes from SystemDrive; and the C# compile runs only where the
#      commit verdict can fire. Every record meets the contract the display relies on
#      (whitelisted characters, no empty field, at most 6 fields, 8-digit numbers,
#      30-character names, 40-character entries), and the MEM / DMP records are
#      pinned field by field where it matters.
# ===============================================================================
Invoke-Test 'Page file classifier: synthetic machines get exactly the documented verdicts' {
    $cmd = Read-Lines $CmdPath
    $hits = @(Get-PgfWorker -Lines $cmd)
    Assert-True ($hits.Count -eq 1) ('Expected one worker line writing $env:PT_PGF_RES, found {0} - it moved or was split, so this test is not running it.' -f $hits.Count)
    Assert-True ($hits[0].Length -lt 8000) ('The page-file worker line is {0} characters; cmd refuses a line over 8191, so it has to shrink, not grow.' -f $hits[0].Length)
    $m = [regex]::Match($hits[0], '-Command "(.*)"\s*$')
    Assert-True $m.Success 'The page-file worker lost the -Command "..." shape this test extracts.'
    $raw = $m.Groups[1].Value
    Assert-True (-not $raw.Contains('"')) 'The page-file payload holds a double quote, which would end cmd''s quoting of it.'
    Assert-True (-not $raw.Contains('!')) 'The page-file payload holds a "!" - :Status runs with delayed expansion on, which would eat it.'
    Assert-True (-not $raw.Replace('%%', '').Contains('%')) 'The page-file payload holds a single "%" that cmd would expand.'
    $payload = $raw.Replace('%%', '%')
    $probs = @(Get-PgfPayloadProblems -Payload $payload)
    Assert-True ($probs.Count -eq 0) ('test 144 refuses to run a page-file worker that is off its read-only allowlist: ' + ($probs -join ' | '))

    $prelude = @'
$global:PTOdd = New-Object System.Collections.Generic.List[string]
Add-Type -TypeDefinition @"
namespace PTPf { public static class N {
    public static int Calls;
    static void Put(byte[] b, int i, ulong v) { if (System.IntPtr.Size == 8) System.BitConverter.GetBytes(v).CopyTo(b, 8 + 8 * i); else System.BitConverter.GetBytes((uint)v).CopyTo(b, 4 + 4 * i); }
    public static bool GPI(byte[] b, int cb) {
        Calls++;
        string pk = System.Environment.GetEnvironmentVariable("PT_T_PEAK");
        if (string.IsNullOrEmpty(pk)) return false;
        Put(b, 0, ulong.Parse(System.Environment.GetEnvironmentVariable("PT_T_NOW")) * 256);
        Put(b, 1, ulong.Parse(System.Environment.GetEnvironmentVariable("PT_T_LIM")) * 256);
        Put(b, 2, ulong.Parse(pk) * 256);
        Put(b, 9, 4096);
        return true;
    }
} }
"@
function global:Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath, [string[]]$Name)
    if ($Name) { $global:PTOdd.Add('Get-ItemProperty -Name') }
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management') { $v = $global:PTCase.MM }
    elseif ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl') { $v = $global:PTCase.CC }
    else { $global:PTOdd.Add('key ' + $LiteralPath); return }
    if ($v -is [string] -and $v -eq 'throw') { throw 'test 144: unreadable key' }
    return $v
}
function global:Get-CimInstance {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName)
    switch ($ClassName) {
        'Win32_PageFileUsage'   { $v = $global:PTCase.USE }
        'Win32_OperatingSystem' { $v = $global:PTCase.OS }
        'Win32_PhysicalMemory'  { $v = $global:PTCase.PM }
        default { $global:PTOdd.Add('class ' + $ClassName); return }
    }
    if ($v -is [string] -and $v -eq 'throw') { throw 'test 144: WMI failed' }
    return $v
}
# Every command that could change the system ends this child with 126 - Add-Type too, now that
# the stand-in is loaded. Set-Item comes last: this loop uses it to define the others.
foreach ($n in @('Set-ItemProperty','New-ItemProperty','Remove-ItemProperty','Clear-ItemProperty','Rename-ItemProperty','Copy-ItemProperty','Move-ItemProperty','Remove-Item','New-Item','Clear-Item','Copy-Item','Move-Item','Rename-Item','Set-Content','Add-Content','Clear-Content','Set-CimInstance','New-CimInstance','Remove-CimInstance','Invoke-CimMethod','Get-WmiObject','Set-WmiInstance','Invoke-WmiMethod','Remove-WmiObject','Invoke-Expression','Invoke-Item','Start-Process','Stop-Process','reg','reg.exe','wmic','wmic.exe','cmd','cmd.exe','powershell','powershell.exe','Add-Type','Set-Item')) {
    Set-Item -Path ('function:global:' + $n) -Value ([scriptblock]::Create("[Console]::Error.WriteLine('test 144: the page-file worker tried to run $n'); [Environment]::Exit(126)"))
}
function global:PTUse($n, $a, $c, $p, $t) { [pscustomobject]@{ Name = $n; AllocatedBaseSize = [uint32]$a; CurrentUsage = [uint32]$c; PeakUsage = [uint32]$p; TempPageFile = [bool]$t } }
function global:PTOs($visMB, $limMB, $nowMB) { [pscustomobject]@{ TotalVisibleMemorySize = [uint64]($visMB * 1024); TotalVirtualMemorySize = [uint64]($limMB * 1024); FreeVirtualMemory = [uint64](($limMB - $nowMB) * 1024) } }
function global:PTMm([string[]]$pf, [string[]]$ex) { $h = [ordered]@{}; if ($null -ne $pf) { $h.PagingFiles = $pf }; if ($null -ne $ex) { $h.ExistingPageFiles = $ex }; [pscustomobject]$h }
function global:PTCc($type, $filter, $ded) { $h = [ordered]@{}; if ($null -ne $type) { $h.CrashDumpEnabled = [int]$type }; if ($null -ne $filter) { $h.FilterPages = [int]$filter }; if ($ded) { $h.DedicatedDumpFile = $ded }; [pscustomobject]$h }
$pm16 = @([pscustomobject]@{ Capacity = [uint64]17179869184 })
$os16 = PTOs 16257 32641 12000
$fixC = { param($mb) @{ MM = (PTMm @("C:\pagefile.sys $mb $mb")); USE = @(PTUse 'C:\pagefile.sys' $mb 10 20 $false) } }

# Each case: the registry (MM, CC) and WMI (USE, OS, PM) answers, the fake commit peak and
# limit in MB (Peak, Lim; Peak $null = GetPerformanceInfo fails), SystemDrive (Sd, default C:),
# and what must come out: Want = the exact ADV records in order; WantSet / WantUse = the exact
# SET / USE records; WantMem / WantDmp = the exact MEM / DMP record; WantPnd = the pending-
# restart record; Gpi = how many times GetPerformanceInfo was called. usable RAM is 16257 MB.
$cases = [ordered]@{
  'system-managed on all drives, dumps and peak that would fire anywhere else' = @{ MM = (PTMm @('?:\pagefile.sys') @('\??\C:\pagefile.sys')); CC = (PTCc 1 $null $null); USE = @(PTUse 'C:\pagefile.sys' 300 290 300 $false); OS = (PTOs 16257 16557 16500); PM = $pm16; Peak = 16550; Lim = 16557; Want = @(); WantSet = @('SET|auto'); Gpi = 0 }
  'system-managed size on C: - never judged small' = @{ MM = (PTMm @('C:\pagefile.sys 0 0')); CC = (PTCc 1 $null $null); USE = @(PTUse 'C:\pagefile.sys' 256 250 256 $false); OS = (PTOs 16257 16513 16500); PM = $pm16; Peak = 16510; Lim = 16513; Want = @(); WantSet = @('SET|sys|C'); Gpi = 0 }
  'no page file, dumps on, peak at 95 percent' = @{ MM = (PTMm @('') @()); CC = (PTCc 7 $null $null); USE = @(); OS = (PTOs 16257 16000 9000); PM = $pm16; Peak = 15200; Lim = 16000; Want = @('ADV|none|now', 'ADV|nodump|C|now', 'ADV|commit|15200|16000'); WantSet = @('SET|none'); WantUse = @('USE|none'); WantMem = 'MEM|16257|16384|1000|16000|15200'; WantDmp = 'DMP|7|0|7'; Gpi = 1 }
  'no page file but a dedicated dump file, peak low' = @{ MM = (PTMm ([string[]]@()) @()); CC = (PTCc 7 $null 'D:\dedicated.sys'); USE = @(); OS = $os16; PM = $pm16; Peak = 4000; Lim = 16000; Want = @('ADV|none|now'); WantDmp = 'DMP|7|1|7'; Gpi = 1 }
  'no page file and crash dumps off' = @{ MM = (PTMm @('') @()); CC = (PTCc 0 $null $null); USE = @(); OS = $os16; PM = $pm16; Peak = $null; Want = @('ADV|none|now'); WantDmp = 'DMP|0|0|0'; Gpi = 1 }
  'PagingFiles value absent - unrecognised, nothing judged' = @{ MM = (PTMm $null $null); CC = (PTCc 7 $null $null); USE = @(); OS = $os16; PM = $pm16; Peak = 15900; Lim = 16000; Want = @(); WantSet = @('SET|absent'); WantUse = @('USE|none'); Gpi = 0 }
  'fixed 4096 MB on C:, complete dump - below RAM + 1 MB, cannot be written' = (& $fixC 4096) + @{ CC = (PTCc 1 0 $null); OS = (PTOs 16257 20353 8000); PM = $pm16; Peak = 9000; Lim = 20353; Want = @('ADV|dumpsize|C|16258|4096'); WantSet = @('SET|custom|C|4096|4096'); WantDmp = 'DMP|1|0|1'; Gpi = 1 }
  'fixed 1 MB under the complete-dump floor' = (& $fixC 16257) + @{ CC = (PTCc 1 $null $null); OS = $os16; PM = $pm16; Peak = 9000; Lim = 32514; Want = @('ADV|dumpsize|C|16258|16257'); Gpi = 1 }
  'fixed exactly at the complete-dump floor - may be cut short only' = (& $fixC 16258) + @{ CC = (PTCc 1 $null $null); OS = $os16; PM = $pm16; Peak = 9000; Lim = 32515; Want = @('ADV|dumpshort|C|16514|16258'); Gpi = 1 }
  'page file the size of installed RAM, complete dump - may be cut short, not cannot be written' = (& $fixC 16384) + @{ CC = (PTCc 1 $null $null); OS = $os16; PM = $pm16; Peak = 9000; Lim = 32641; Want = @('ADV|dumpshort|C|16514|16384'); Gpi = 1 }
  'fixed at RAM + 257 MB - nothing to say' = (& $fixC 16514) + @{ CC = (PTCc 1 $null $null); OS = $os16; PM = $pm16; Peak = 9000; Lim = 32771; Want = @(); Gpi = 1 }
  'complete dump with a dedicated dump file - no size verdict' = (& $fixC 4096) + @{ CC = (PTCc 1 $null 'D:\dd.sys'); OS = $os16; PM = $pm16; Peak = 9000; Lim = 20353; Want = @(); WantDmp = 'DMP|1|1|1'; Gpi = 1 }
  'small dump on a 1 MB page file - there is no small-dump rule' = (& $fixC 1) + @{ CC = (PTCc 3 $null $null); OS = $os16; PM = $pm16; Peak = 9000; Lim = 16258; Want = @(); WantDmp = 'DMP|3|0|3'; Gpi = 1 }
  'fixed 16384 MB on C:, small dump, peak at 92 percent' = @{ MM = (PTMm @('c:\pagefile.sys 16384 16384')); CC = (PTCc 3 $null $null); USE = @(PTUse 'C:\pagefile.sys' 16384 9000 12000 $false); OS = (PTOs 16257 32641 20000); PM = $pm16; Peak = 30100; Lim = 32641; Want = @('ADV|commit|30100|32641'); WantMem = 'MEM|16257|16384|1000|32641|30100'; Gpi = 1 }
  'commit peak at exactly 90 percent' = (& $fixC 4096) + @{ CC = (PTCc 0 $null $null); OS = $os16; PM = $pm16; Peak = 9000; Lim = 10000; Want = @('ADV|commit|9000|10000'); Gpi = 1 }
  'commit peak just under 90 percent' = (& $fixC 4096) + @{ CC = (PTCc 0 $null $null); OS = $os16; PM = $pm16; Peak = 8999; Lim = 10000; Want = @(); Gpi = 1 }
  'custom that can still grow - the limit is soft, no commit verdict' = @{ MM = (PTMm @('C:\pagefile.sys 1024 8192')); CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 1000 1024 $false); OS = (PTOs 16257 17281 17000); PM = $pm16; Peak = 17200; Lim = 17281; Want = @(); WantSet = @('SET|custom|C|1024|8192'); WantMem = 'MEM|16257|16384|17000|17281|-'; Gpi = 0 }
  'page file only on D:, dumps on' = @{ MM = (PTMm @('D:\pagefile.sys 4096 4096')); CC = (PTCc 7 $null $null); USE = @(PTUse 'D:\pagefile.sys' 4096 10 20 $false); OS = (PTOs 16257 20353 8000); PM = $pm16; Peak = 9000; Lim = 20353; Want = @('ADV|nodump|C|now'); Gpi = 1 }
  'Windows on D:, page file only on C: - the Windows drive comes from SystemDrive' = (& $fixC 4096) + @{ Sd = 'D:'; CC = (PTCc 7 $null $null); OS = $os16; PM = $pm16; Peak = 9000; Lim = 20353; Want = @('ADV|nodump|D|now'); Gpi = 1 }
  'size change waiting for a restart - no commit verdict' = @{ MM = (PTMm @('C:\pagefile.sys 4096 4096')); CC = (PTCc 3 $null $null); USE = @(PTUse 'C:\pagefile.sys' 8192 10 20 $false); OS = (PTOs 16257 24449 24000); PM = $pm16; Peak = 24400; Lim = 24449; Want = @(); WantPnd = $true; Gpi = 0 }
  'drive change waiting for a restart - after the next restart' = @{ MM = (PTMm @('D:\pagefile.sys 0 0')); CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 2048 10 20 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @('ADV|nodump|C|next'); WantPnd = $true; Gpi = 0 }
  'no page file set, one still in use - after the next restart' = @{ MM = (PTMm @('') @('\??\C:\pagefile.sys')); CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 2048 10 20 $false); OS = $os16; PM = $pm16; Peak = 15900; Lim = 16000; Want = @('ADV|none|next', 'ADV|nodump|C|next'); WantUse = @('USE|C:\pagefile.sys|2048|10|20'); WantPnd = $true; Gpi = 0 }
  'unrecognised entries are shown and never judged' = @{ MM = (PTMm @('C:\pagefile.sys 4096', 'garbage !%^&| text', 'C:\pagefile.sys 8192 4096')); CC = (PTCc 1 $null $null); USE = @(PTUse 'C:\pagefile.sys' 4096 10 20 $false); OS = $os16; PM = $pm16; Peak = 16000; Lim = 16100; Want = @(); WantSet = @('SET|unrec|C:\pagefile.sys 4096', 'SET|unrec|garbage  text', 'SET|unrec|C:\pagefile.sys 8192 4096'); Gpi = 0 }
  'custom sizes on "any drive" (?:) are unrecognised, never judged' = @{ MM = (PTMm @('?:\pagefile.sys 1024 1124')); CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $false); OS = $os16; PM = $pm16; Peak = 16000; Lim = 16100; Want = @(); WantSet = @('SET|unrec|?:\pagefile.sys 1024 1124'); Gpi = 0 }
  'a nine-digit size is unrecognised, so no number outgrows the display' = @{ MM = (PTMm @('C:\pagefile.sys 100000000 100000000')); CC = (PTCc 1 $null $null); USE = @(PTUse 'C:\pagefile.sys' 4096 10 20 $false); OS = $os16; PM = $pm16; Peak = 16000; Lim = 16100; Want = @(); WantSet = @('SET|unrec|C:\pagefile.sys 100000000 100000000'); Gpi = 0 }
  'an entry without a drive letter blocks the no-dump verdict' = @{ MM = (PTMm @('garbage')); CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 1 2 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @(); WantSet = @('SET|unrec|garbage'); Gpi = 0 }
  'registry unreadable - nothing about the setting is judged' = @{ MM = 'throw'; CC = (PTCc 1 $null $null); USE = @(); OS = $os16; PM = $pm16; Peak = 16000; Lim = 16100; Want = @(); WantSet = @('SET|unreadable'); WantUse = @('USE|none'); Gpi = 0 }
  'WMI down - in-use from ExistingPageFiles, no sizes, no commit verdict' = @{ MM = (PTMm @('C:\pagefile.sys 4096 4096') @('\??\C:\pagefile.sys')); CC = (PTCc 3 $null $null); USE = 'throw'; OS = 'throw'; PM = 'throw'; Peak = 16000; Lim = 16100; Want = @(); WantUse = @('USE|C:\pagefile.sys|-|-|-'); WantMem = 'MEM|-|-|-|-|-'; Gpi = 0 }
  'WMI down and no ExistingPageFiles, no page file set - in use unknown, after the next restart, no commit verdict' = @{ MM = (PTMm @('') $null); CC = (PTCc 0 $null $null); USE = 'throw'; OS = $os16; PM = $pm16; Peak = 15900; Lim = 16000; Want = @('ADV|none|next'); WantUse = @('USE|unknown'); Gpi = 0 }
  'WMI lists no page file but the registry lists one, dumps on - in use unknown, after the next restart, no commit verdict' = @{ MM = (PTMm @('') @('\??\C:\pagefile.sys')); CC = (PTCc 7 $null $null); USE = @(); OS = $os16; PM = $pm16; Peak = 15900; Lim = 16000; Want = @('ADV|none|next', 'ADV|nodump|C|next'); WantUse = @('USE|disagree'); WantDmp = 'DMP|7|0|7'; Gpi = 0 }
  'a fixed file WMI does not list but the registry does - unknown, not pending' = @{ MM = (PTMm @('C:\pagefile.sys 4096 4096') @('\??\C:\pagefile.sys')); CC = (PTCc 7 $null $null); USE = @(); OS = $os16; PM = $pm16; Peak = 16000; Lim = 16100; Want = @(); WantUse = @('USE|disagree'); Gpi = 0 }
  'a temporary page file is reported' = @{ MM = (PTMm @('?:\pagefile.sys')); CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $true); OS = $os16; PM = $pm16; Peak = $null; Want = @('ADV|temp'); Gpi = 0 }
  'active dump on a tiny fixed file - no numeric rule for it' = (& $fixC 512) + @{ CC = (PTCc 1 1 $null); OS = $os16; PM = $pm16; Peak = 1000; Lim = 16769; Want = @(); WantDmp = 'DMP|A|0|1'; Gpi = 1 }
  'RAM unknown - no complete-dump size verdict' = (& $fixC 512) + @{ CC = (PTCc 1 $null $null); OS = 'throw'; PM = 'throw'; Peak = 1000; Lim = 16769; Want = @(); WantMem = 'MEM|-|-|1000|16769|1000'; Gpi = 1 }
  'crash-dump key unreadable - no dump verdicts' = @{ MM = (PTMm @('')); CC = 'throw'; USE = @(); OS = $os16; PM = $pm16; Peak = $null; Want = @('ADV|none|now'); WantDmp = 'DMP|R|0|-'; Gpi = 1 }
  'CrashDumpEnabled as a string - unrecognised, not unreadable' = @{ MM = (PTMm @('')); CC = [pscustomobject]@{ CrashDumpEnabled = '1' }; USE = @(); OS = $os16; PM = $pm16; Peak = $null; Want = @('ADV|none|now'); WantDmp = 'DMP|X|0|-'; Gpi = 1 }
  'CrashDumpEnabled 0xFFFFFFFF - unrecognised' = @{ MM = (PTMm @('?:\pagefile.sys')); CC = (PTCc -1 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @(); WantDmp = 'DMP|X|0|-'; Gpi = 0 }
  'CrashDumpEnabled 4 - unrecognised, shown as found' = @{ MM = (PTMm @('?:\pagefile.sys')); CC = (PTCc 4 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @(); WantDmp = 'DMP|X|0|4'; Gpi = 0 }
  'CrashDumpEnabled not set' = @{ MM = (PTMm @('?:\pagefile.sys')); CC = (PTCc $null 1 $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @(); WantDmp = 'DMP|U|0|-'; Gpi = 0 }
}
$fails = New-Object System.Collections.Generic.List[string]
$sb = [scriptblock]::Create($env:PT_T_PAYLOAD)
foreach ($name in $cases.Keys) {
    $c = $cases[$name]
    $global:PTCase = $c
    $env:SystemDrive = 'C:'; if ($c.ContainsKey('Sd')) { $env:SystemDrive = $c.Sd }
    $env:PT_T_PEAK = ''; if ($null -ne $c.Peak) { $env:PT_T_PEAK = [string]$c.Peak; $env:PT_T_LIM = [string]$c.Lim; $env:PT_T_NOW = '1000' }
    $env:PT_PGF_RES = Join-Path ([IO.Path]::GetTempPath()) ('PT144_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $before = [PTPf.N]::Calls
    & $sb
    $calls = [PTPf.N]::Calls - $before
    if (-not (Test-Path -LiteralPath $env:PT_PGF_RES)) { $fails.Add($name + ': no output file'); continue }
    $bytes = [IO.File]::ReadAllBytes($env:PT_PGF_RES)
    $lines = @([IO.File]::ReadAllLines($env:PT_PGF_RES))
    [IO.File]::Delete($env:PT_PGF_RES)
    if (@($bytes | Where-Object { $_ -gt 126 -or ($_ -lt 32 -and $_ -ne 13 -and $_ -ne 10) }).Count -gt 0) { $fails.Add($name + ': output is not printable ASCII') }
    if ($lines.Count -eq 0 -or $lines[-1] -ne 'END|ok') { $fails.Add($name + ': output does not end in END|ok') }
    foreach ($l in $lines) {
        if ($l -notmatch '^(SET|USE|MEM|DMP|PND|ADV|END)(\|[A-Za-z0-9 :.?_\\-]+)+$') { $fails.Add(('{0}: malformed record [{1}] - empty field, unknown tag or a character outside the whitelist' -f $name, $l)) }
        $f = $l.Split('|')
        if ($f.Count -gt 6) { $fails.Add(('{0}: record [{1}] has more than the 6 fields the display reads' -f $name, $l)) }
        foreach ($x in $f[1..($f.Count - 1)]) { if ($x -match '^\d+$' -and $x.Length -gt 8) { $fails.Add(('{0}: number {1} is wider than the 8 digits the display is sized for' -f $name, $x)) } }
        if ($f[0] -eq 'USE' -and $f[1].Length -gt 30) { $fails.Add(('{0}: file name wider than 30' -f $name)) }
        if ($f[0] -eq 'SET' -and $f[1] -eq 'unrec' -and $f[2].Length -gt 40) { $fails.Add(('{0}: unrecognised entry wider than 40' -f $name)) }
    }
    $adv = @($lines | Where-Object { $_ -like 'ADV|*' })
    if (($adv -join ';') -cne (@($c.Want) -join ';')) { $fails.Add(('{0}: advisories [{1}], expected [{2}]' -f $name, ($adv -join ';'), (@($c.Want) -join ';'))) }
    foreach ($k in @('Set', 'Use', 'Mem', 'Dmp')) {
        if (-not $c.ContainsKey('Want' + $k)) { continue }
        $got = @($lines | Where-Object { $_ -like ($k.ToUpper() + '|*') })
        $want = @($c['Want' + $k])
        if (($got -join ';') -cne ($want -join ';')) { $fails.Add(('{0}: {1} records [{2}], expected [{3}]' -f $name, $k.ToUpper(), ($got -join ';'), ($want -join ';'))) }
    }
    $pnd = @($lines | Where-Object { $_ -eq 'PND|1' }).Count -eq 1
    if ($pnd -ne [bool]$c.WantPnd) { $fails.Add(('{0}: pending-restart record {1}, expected {2}' -f $name, $pnd, [bool]$c.WantPnd)) }
    if ($calls -ne $c.Gpi) { $fails.Add(('{0}: GetPerformanceInfo called {1} time(s), expected {2} - it costs a C# compile, so it must run only where the commit verdict can fire' -f $name, $calls, $c.Gpi)) }
}
if ($global:PTOdd.Count -gt 0) { $fails.Add('the worker read something this test does not fake: ' + (($global:PTOdd | Select-Object -Unique) -join ', ')) }
'CASES ' + $cases.Count
$fails | ForEach-Object { 'FAIL ' + $_ }
'@

    $r = Invoke-PgfChild -Script $prelude -Payload $payload -Tag 'PT144'
    Assert-True ($r.Exit -ne 126) ('The page-file worker tried to change the system: ' + $r.Err)
    Assert-True ($r.Exit -eq 0) ('The classifier run failed (exit {0}): {1}' -f $r.Exit, ($r.Err + ' ' + $r.Out.Trim()))
    $outLines = @($r.Out -split "`r?`n" | Where-Object { $_ -ne '' })
    $cnt = @($outLines | Where-Object { $_ -match '^CASES (\d+)$' })
    Assert-True ($cnt.Count -eq 1 -and [int]($cnt[0].Split(' ')[1]) -ge 39) ('The classifier run did not report its case count - it stopped early: ' + $r.Out.Trim() + ' ' + $r.Err)
    $bad = @($outLines | Where-Object { $_ -like 'FAIL *' })
    Assert-True ($bad.Count -eq 0) ('Page-file classifier: ' + ($bad -join ' | '))
}

# ===============================================================================
# 145. The page-file DISPLAY is RUN on synthetic records. :_pgfShow and :_pgfRec
#      are copied out of the script into a driver that is handed a record file by
#      NAME (an environment variable read late, so the test's own folder - which
#      holds a "!" on purpose - survives delayed expansion). No worker, no system
#      access. Every record shape the worker writes, at its widest (8-digit numbers,
#      a 30-character file name, a 40-character entry), must render within 98
#      columns and the console width, ASCII only, with nothing on stderr and no
#      empty-echo line (its local text is captured, not written in English). Every
#      field lands where it belongs: sentinel records must render to exact lines. Every
#      verdict code the worker can emit (read out of the worker itself) prints exactly
#      one [ADVISORY] plus the line saying sincript changes neither setting, the
#      no-page-file verdicts say "after the next restart" only when told to, an
#      unknown tag or code prints nothing, and a file without the closing END record,
#      an empty one or none at all prints only the could-not-read line.
# ===============================================================================
Invoke-Test 'Page file display: every record renders within the console, verdicts only when complete' {
    $cmd = Read-Lines $CmdPath
    $width = 0
    foreach ($ln in $cmd) { $mc = [regex]::Match($ln, '(?i)^\s*mode con:\s*cols=(\d+)'); if ($mc.Success) { $width = [int]$mc.Groups[1].Value } }
    Assert-True ($width -gt 0) 'test 145: no "mode con: cols=N" line - there is no width to measure against.'
    $limit = [Math]::Min(98, $width - 1)
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $show = @(Get-BodyLines -Lines $cmd -Label '_pgfShow')
    $rec  = @(Get-BodyLines -Lines $cmd -Label '_pgfRec')
    Assert-True ($show.Count -gt 5 -and $rec.Count -gt 60) (':_pgfShow / :_pgfRec did not slice ({0} / {1} lines) - renamed or restructured?' -f $show.Count, $rec.Count)
    $calls = @([regex]::Matches((($show + $rec) -join "`n"), '(?i)\bcall\s+:(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True (@($calls | Where-Object { $_ -ne '_pgfRec' }).Count -eq 0) ('The page-file display now calls {0} - add it to this test''s driver.' -f ($calls -join ', '))
    $echoLine = '(?i)^\s*(if\s+(/i\s+)?(not\s+)?(defined\s+\S+|exist\s+"[^"]*"|"[^"]*"==\s*"[^"]*")\s+)*echo([\s.:;,(]|$)'
    $live = @(($show + $rec) | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and -not ($_ -match $echoLine -and ($_ -replace '\^.', '') -notmatch '[&|<>]') -and $_ -match '(?i)\bpowershell\b|\breg(\.exe)?\s|\bstart\s+"|\bdel\s' })
    Assert-True ($live.Count -eq 0) ('test 145: the display code now starts or deletes something - refusing to run it: ' + ($live -join ' | '))
    $wk = @(Get-PgfWorker -Lines $cmd)
    Assert-True ($wk.Count -eq 1) 'The page-file worker line is missing or split.'
    $codes = @([regex]::Matches($wk[0], "'ADV\|([a-z]+)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True ($codes.Count -ge 6) ('Only {0} advisory code(s) found in the worker - the record format changed.' -f $codes.Count)

    $tmp = [IO.Path]::GetTempPath()
    if ($tmp -match '%') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT145_b!ng_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Assert-True ($dir -notmatch '%') ('test 145 cannot run here: the temp folder path holds a "%" and has no short name ({0}).' -f $dir)
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = Join-Path $dir 'drv.cmd'
        $txt = @('@echo off', 'setlocal EnableDelayedExpansion', 'set "_pgfres=!PT_T_REC!"', 'call :_pgfShow', 'exit /b 0', ':_pgfShow') + $show + @(':_pgfRec') + $rec
        [IO.File]::WriteAllText($drv, (($txt -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
        $runCmd = {
            param([string]$Script, [string]$Rec)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $cmdExe; $psi.Arguments = '/d /s /c ""' + $Script + '""'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['PT_T_REC'] = $Rec
            $p = [System.Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
            # read both streams while waiting, and stop a driver that does not end - a display
            # stuck in a goto loop would otherwise print until this process runs out of memory
            $err = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEndAsync()
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'test 145: the display driver did not end within 30 s.' }
            Assert-True ($err.Result.Trim() -eq '') ('The page-file display wrote to stderr: ' + $err.Result.Trim())
            ,@($out.Result -split "`r?`n" | Where-Object { $_ -ne '' })
        }
        # what an echo with nothing to print shows on this Windows, in its own language
        $eo = Join-Path $dir 'eo.cmd'
        [IO.File]::WriteAllText($eo, "@echo off`r`necho`r`n", [Text.Encoding]::ASCII)
        $echoOff = & $runCmd $eo ''
        Assert-True ($echoOff.Count -eq 1 -and $echoOff[0].Trim() -ne '') 'test 145: could not capture the text of an empty echo.'
        $empty = $echoOff[0].Trim()
        $render = {
            param([string[]]$Records, [switch]$NoFile)
            $f = Join-Path $dir ('r{0}.txt' -f [guid]::NewGuid().ToString('N').Substring(0, 6))
            if ($null -eq $Records) { $Records = @() }
            if (-not $NoFile) { [IO.File]::WriteAllLines($f, [string[]]$Records, [Text.Encoding]::ASCII) }
            $o = & $runCmd $drv $f
            Assert-True (@($o | Where-Object { $_.Trim() -eq $empty }).Count -eq 0) ('The page-file display printed an empty echo ("{0}") - a field it prints was empty.' -f $empty)
            $wide = @($o | Where-Object { $_.Length -gt $limit })
            Assert-True ($wide.Count -eq 0) (('Page-file lines wider than {0} columns (the console is {1}): ' -f $limit, $width) + (($wide | ForEach-Object { '{0}: {1}' -f $_.Length, $_.Trim().Substring(0, 30) }) -join ' | '))
            ,$o
        }

        # --- every record shape at its widest
        $n8 = '99999999'; $name30 = 'Z:\' + ('p' * 23) + '.sys'; $raw40 = 'X' * 40
        $all = @('SET|auto', 'SET|none', 'SET|sys|C', "SET|custom|C|$n8|$n8", "SET|custom|C|1|$n8", "SET|unrec|$raw40", 'SET|absent', 'SET|unreadable',
                 'USE|none', 'USE|unknown', 'USE|disagree', "USE|$name30|-|-|-", "USE|$name30|$n8|$n8|$n8",
                 'MEM|-|-|-|-|-', "MEM|-|$n8|-|$n8|-", "MEM|$n8|-|-|$n8|-", "MEM|$n8|-|$n8|$n8|-", "MEM|$n8|$n8|$n8|$n8|$n8",
                 'DMP|0|0|0', 'DMP|1|1|1', 'DMP|2|0|2', 'DMP|3|0|3', 'DMP|7|0|7', 'DMP|A|0|1', "DMP|X|0|$n8", 'DMP|X|1|-', 'DMP|U|0|-', 'DMP|R|0|-',
                 'PND|1', 'ADV|none|now', 'ADV|none|next', 'ADV|nodump|C|now', 'ADV|nodump|C|next', "ADV|dumpsize|C|$n8|$n8", "ADV|dumpshort|C|$n8|$n8", "ADV|commit|$n8|$n8", 'ADV|temp') + @($codes | ForEach-Object { 'ADV|' + $_ }) + @('ZZZ|ignored', 'ADV|nosuchcode', 'END|ok')
        $out = & $render $all
        Assert-True ($out.Count -gt 60) ('The display printed only {0} line(s) for every record shape - it is not rendering them.' -f $out.Count)
        Assert-True (@($out | Where-Object { $_ -match '[^\x20-\x7E]' }).Count -eq 0) 'The page-file display printed a non-ASCII character.'

        # --- every record that is not a verdict renders to its exact lines, sentinels in the fields:
        #     a field in the wrong place, a dropped tag or a lost branch changes the text
        $exact = [ordered]@{
            'SET|auto'                     = @('  Setting   : system-managed - Windows picks the drive and the size (the default)')
            'SET|none'                     = @('  Setting   : NO page file')
            'SET|sys|Q'                    = @('  Setting   : Q: system-managed size')
            'SET|custom|Q|1111|2222'       = @('  Setting   : Q: custom, 1111 MB, can grow to 2222 MB')
            'SET|custom|Q|3333|3333'       = @('  Setting   : Q: custom, fixed at 3333 MB')
            'SET|unrec|odd entry 1'        = @('  Setting   : unrecognised entry "odd entry 1" - not judged')
            'SET|absent'                   = @('  Setting   : unrecognised - the registry holds no PagingFiles value; not judged')
            'SET|unreadable'               = @('  Setting   : could not be read from the registry - not judged')
            'USE|none'                     = @('  In use    : none right now')
            'USE|unknown'                  = @('  In use    : could not be read - WMI and the registry both failed')
            'USE|disagree'                 = @('  In use    : unknown - WMI lists none, but the registry lists a page file in use')
            'USE|Z:\f.sys|6666|7777|8888'  = @('  In use    : Z:\f.sys  6666 MB, 7777 MB used, peak 8888 MB')
            'USE|Z:\g.sys|-|-|-'           = @('  In use    : Z:\g.sys  (size not available - WMI did not answer)')
            'MEM|1111|2222|3333|4444|5555' = @('  RAM       : 1111 MB usable by Windows, 2222 MB installed', '  Committed : 3333 MB of a 4444 MB limit (RAM plus page files), peak 5555 MB')
            'MEM|1111|-|3333|4444|-'       = @('  RAM       : 1111 MB usable by Windows', '  Committed : 3333 MB of a 4444 MB limit (RAM plus page files)')
            'MEM|-|2222|-|4444|-'          = @('  RAM       : 2222 MB installed (how much of it Windows can use is not available)', '  Committed : the limit is 4444 MB (RAM plus page files); the amount in use is not available')
            'MEM|-|-|3333|-|-'             = @('  RAM       : not available', '  Committed : not available')
            'DMP|0|0|0'                    = @('  Crash dump: off - Windows writes no memory dump after a blue screen')
            'DMP|1|0|1'                    = @('  Crash dump: complete memory dump (CrashDumpEnabled=1)')
            'DMP|2|0|2'                    = @('  Crash dump: kernel memory dump (CrashDumpEnabled=2)')
            'DMP|3|0|3'                    = @('  Crash dump: small memory dump (CrashDumpEnabled=3)')
            'DMP|7|1|7'                    = @('  Crash dump: automatic memory dump, the Windows default (CrashDumpEnabled=7)', '              plus a dedicated dump file (DedicatedDumpFile is set)')
            'DMP|A|0|1'                    = @('  Crash dump: active memory dump (CrashDumpEnabled=1 with FilterPages=1)')
            'DMP|X|0|4242'                 = @('  Crash dump: unrecognised value CrashDumpEnabled=4242 - not judged')
            'DMP|X|0|-'                    = @('  Crash dump: CrashDumpEnabled holds an unrecognised value - not judged')
            'DMP|U|0|-'                    = @('  Crash dump: CrashDumpEnabled is not set - not judged')
            'DMP|R|0|-'                    = @('  Crash dump: the CrashControl key could not be read - not judged')
            'PND|1'                        = @('  [i] The setting differs from the page file(s) in use: a change is waiting for a restart,', '      or Windows could not create a configured file. The figures above are for the files in use.')
        }
        $sent = & $render (@($exact.Keys) + @('END|ok'))
        $want = @($exact.Values | ForEach-Object { $_ })
        Assert-True (($sent -join "`n") -ceq ($want -join "`n")) ("The page-file display lost a record, put a field in the wrong place or changed a line. Got:`n" + ($sent -join "`n"))
        $adv = (& $render @('ADV|dumpsize|Q|11111111|22222222', 'ADV|dumpshort|Q|33333333|44444444', 'ADV|commit|55555555|66666666', 'END|ok')) -join "`n"
        foreach ($re in @('on Q: is set to at most 22222222 MB, but', 'needs at least 11111111 MB there', 'on Q: is set to at most 44444444 MB\. Microsoft', '\s33333333 MB for a complete memory dump', 'peaked at 55555555 MB', 'its 66666666 MB limit')) {
            Assert-True ($adv -match $re) ('A size verdict put a number in the wrong place (no "{0}"): {1}' -f $re, $adv)
        }

        # --- every verdict code prints one [ADVISORY] and the where-to-change-it line
        foreach ($c in $codes) {
            $one = & $render @("ADV|$c|C|1|2", 'END|ok')
            Assert-True (@($one | Where-Object { $_ -match '^\s+\[ADVISORY\] ' }).Count -eq 1) ("The worker can emit ADV|$c but the display prints no [ADVISORY] for it - a verdict nobody sees.")
            Assert-True (@($one | Where-Object { $_ -match '^\s+\[i\] sincript changes neither setting' }).Count -eq 1) ("ADV|$c printed without the line saying sincript does not change the setting.")
        }
        # --- the no-page-file verdicts speak of the next restart exactly when the worker says so
        foreach ($pair in @(@('ADV|none|now', 'ADV|none|next', 'No page file: Windows caps'), @('ADV|nodump|Q|now', 'ADV|nodump|Q|next', 'the Windows drive Q: has no page file'))) {
            $now = (& $render @($pair[0], 'END|ok')) -join "`n"
            $nxt = & $render @($pair[1], 'END|ok')
            Assert-True ($now.Contains($pair[2]) -and $now -notmatch '(?i)next restart') ('{0} does not describe the page file in use now: {1}' -f $pair[0], $now)
            Assert-True (@($nxt | Where-Object { $_ -match '^\s+\[ADVISORY\] ' }).Count -eq 1 -and ($nxt -join "`n") -match '(?i)after the next restart' -and -not ($nxt -join "`n").Contains($pair[2])) ('{0} does not say the change takes effect after the next restart - it contradicts the In use line above it: {1}' -f $pair[1], ($nxt -join ' | '))
        }

        # --- unknown records print nothing; an unfinished, empty or missing file prints one line
        $none = & $render @('SET|auto', 'USE|none', 'MEM|1|-|1|2|-', 'DMP|7|0|7', 'ZZZ|x', 'ADV|nosuchcode', 'END|ok')
        Assert-True ($none.Count -eq 5) ('The display printed {0} line(s) for four known records (five lines) and two unknown ones: {1}' -f $none.Count, ($none -join ' | '))
        Assert-True (@($none | Where-Object { $_ -match '\[ADVISORY\]|\[i\] sincript|nosuchcode|ZZZ' }).Count -eq 0) 'An unknown tag or advisory code printed something - only a known record may.'
        foreach ($bad in @(@{ n = 'a file without END|ok'; r = @('SET|none', 'USE|none', 'ADV|none|now') }, @{ n = 'an empty file'; r = @() })) {
            $cut = & $render $bad.r
            Assert-True ($cut.Count -eq 1 -and $cut[0] -match 'Could not read the page-file state') ('{0} must print only the could-not-read line, nothing judged - got: {1}' -f $bad.n, ($cut -join ' | '))
        }
        $gone = & $render @() -NoFile
        Assert-True ($gone.Count -eq 1 -and $gone[0] -match 'Could not read the page-file state') ('A missing result file must print only the could-not-read line - got: ' + ($gone -join ' | '))
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ===============================================================================
# 146. The worker's real C# compile and GetPerformanceInfo call are RUN once. Test
#      144 pre-loads a stand-in for the compiled type, so it never compiles the
#      DllImport, never calls K32GetPerformanceInfo and reads the buffer at the
#      offsets the stand-in itself wrote: a broken import, quoting, BOOL return or
#      offset would only turn the peak into "-" and silence the commit verdict. Here
#      the payload (allowlisted first, as in 144) runs in a child Windows PowerShell
#      with no stand-in and with the registry and WMI faked to "no page file" and
#      impossible sentinel sizes, and every writer except Add-Type blocked (exit
#      126). The compile must happen; the limit and the charge must be GetPerformance-
#      Info's, not the WMI sentinels; the limit must match Win32_OperatingSystem's
#      TotalVirtualMemorySize within 2%; and the peak must be the one this harness
#      reads itself, through psapi's GetPerformanceInfo and a declared struct - a
#      second, independent reading. The peak only grows, so the worker's must lie
#      between the harness's readings before and after it. The commit verdict must
#      appear exactly when that peak is at 90% of the limit. Both calls only read.
# ===============================================================================
Invoke-Test 'Page file worker: the real GetPerformanceInfo compile and call answer' {
    $cmd = Read-Lines $CmdPath
    $hits = @(Get-PgfWorker -Lines $cmd)
    Assert-True ($hits.Count -eq 1) ('Expected one page-file worker line, found {0}.' -f $hits.Count)
    $m = [regex]::Match($hits[0], '-Command "(.*)"\s*$')
    Assert-True $m.Success 'The page-file worker lost the -Command "..." shape this test extracts.'
    $payload = $m.Groups[1].Value.Replace('%%', '%')
    $probs = @(Get-PgfPayloadProblems -Payload $payload)
    Assert-True ($probs.Count -eq 0) ('test 146 refuses to run a page-file worker that is off its read-only allowlist: ' + ($probs -join ' | '))
    # the harness's own reading: psapi's export (the worker uses kernel32's K32 one), a declared
    # PERFORMANCE_INFORMATION struct (the worker reads raw offsets), whole MB rounded down as the
    # worker rounds them
    if (-not ('PT146.Perf' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace PT146 { public static class Perf {
    [StructLayout(LayoutKind.Sequential)] public struct PI { public uint cb; public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable, SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize; public uint HandleCount, ProcessCount, ThreadCount; }
    [DllImport("psapi.dll")] static extern bool GetPerformanceInfo(out PI pi, uint cb);
    public static ulong[] Mb() { PI p; if (!GetPerformanceInfo(out p, (uint)Marshal.SizeOf(typeof(PI)))) return null; ulong s = p.PageSize.ToUInt64(); return new ulong[] { p.CommitTotal.ToUInt64() * s / 1048576, p.CommitLimit.ToUInt64() * s / 1048576, p.CommitPeak.ToUInt64() * s / 1048576 }; }
} }
'@
    }
    $pa = [PT146.Perf]::Mb()
    $limA = [double](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).TotalVirtualMemorySize / 1024
    Assert-True ($null -ne $pa -and $pa[2] -gt 0) 'test 146: the harness''s own GetPerformanceInfo call failed - there is nothing to compare the worker with.'

    $prelude = @'
$global:PTOdd = New-Object System.Collections.Generic.List[string]
function global:Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath, [string[]]$Name)
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management') { return [pscustomobject]@{ PagingFiles = [string[]]@('') } }
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl') { return [pscustomobject]@{ CrashDumpEnabled = [int]0 } }
    $global:PTOdd.Add('key ' + $LiteralPath)
}
function global:Get-CimInstance {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName)
    switch ($ClassName) {
        'Win32_PageFileUsage'   { return }
        'Win32_OperatingSystem' { return [pscustomobject]@{ TotalVisibleMemorySize = [uint64](5 * 1024); TotalVirtualMemorySize = [uint64](7 * 1024); FreeVirtualMemory = [uint64](4 * 1024) } }
        'Win32_PhysicalMemory'  { return @([pscustomobject]@{ Capacity = [uint64](6 * 1MB) }) }
        default { $global:PTOdd.Add('class ' + $ClassName) }
    }
}
foreach ($n in @('Set-ItemProperty','New-ItemProperty','Remove-ItemProperty','Clear-ItemProperty','Rename-ItemProperty','Copy-ItemProperty','Move-ItemProperty','Remove-Item','New-Item','Clear-Item','Copy-Item','Move-Item','Rename-Item','Set-Content','Add-Content','Clear-Content','Set-CimInstance','New-CimInstance','Remove-CimInstance','Invoke-CimMethod','Get-WmiObject','Set-WmiInstance','Invoke-WmiMethod','Remove-WmiObject','Invoke-Expression','Invoke-Item','Start-Process','Stop-Process','reg','reg.exe','wmic','wmic.exe','cmd','cmd.exe','powershell','powershell.exe','Set-Item')) {
    Set-Item -Path ('function:global:' + $n) -Value ([scriptblock]::Create("[Console]::Error.WriteLine('test 146: the page-file worker tried to run $n'); [Environment]::Exit(126)"))
}
if ('PTPf.N' -as [type]) { 'FAIL the compiled type was there before the worker ran'; exit 3 }
$env:PT_PGF_RES = Join-Path ([IO.Path]::GetTempPath()) ('PT146_{0}.txt' -f [guid]::NewGuid().ToString('N'))
& ([scriptblock]::Create($env:PT_T_PAYLOAD))
if (-not ('PTPf.N' -as [type])) { 'FAIL the worker did not compile its GetPerformanceInfo import' }
if (Test-Path -LiteralPath $env:PT_PGF_RES) { [IO.File]::ReadAllLines($env:PT_PGF_RES) | ForEach-Object { 'REC ' + $_ }; [IO.File]::Delete($env:PT_PGF_RES) }
if ($global:PTOdd.Count -gt 0) { 'FAIL the worker read something this test does not fake: ' + (($global:PTOdd | Select-Object -Unique) -join ', ') }
'DONE'
'@

    $r = Invoke-PgfChild -Script $prelude -Payload $payload -Tag 'PT146'
    $pb = [PT146.Perf]::Mb()
    Assert-True ($r.Exit -ne 126) ('The page-file worker tried to change the system: ' + $r.Err)
    Assert-True ($r.Exit -eq 0) ('The real GetPerformanceInfo run failed (exit {0}): {1}' -f $r.Exit, ($r.Err + ' ' + $r.Out.Trim()))
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_ -ne '' })
    Assert-True (@($lines | Where-Object { $_ -eq 'DONE' }).Count -eq 1) ('The real GetPerformanceInfo run stopped early: ' + ($lines -join ' | ') + ' ' + $r.Err)
    $bad = @($lines | Where-Object { $_ -like 'FAIL *' })
    Assert-True ($bad.Count -eq 0) ('Page-file worker, real run: ' + ($bad -join ' | '))
    $recs = @($lines | Where-Object { $_ -like 'REC *' } | ForEach-Object { $_.Substring(4) })
    Assert-True ($recs.Count -gt 0 -and $recs[-1] -eq 'END|ok') ('The real run wrote no complete answer: ' + ($recs -join ' | '))
    $mem = @($recs | Where-Object { $_ -like 'MEM|*' })
    Assert-True ($mem.Count -eq 1) ('The real run wrote {0} MEM records.' -f $mem.Count)
    $f = $mem[0].Split('|')
    Assert-True ($f.Count -eq 6 -and $f[1] -eq '5' -and $f[2] -eq '6') ('The MEM record does not carry the faked RAM figures where the display reads them: ' + $mem[0])
    Assert-True ($f[5] -match '^\d+$' -and [int64]$f[5] -gt 0) ('GetPerformanceInfo gave no commit peak - the compile, the import or the call is broken, and the commit verdict can never fire: ' + $mem[0])
    Assert-True ($f[4] -match '^\d+$' -and $f[4] -ne '7' -and $f[3] -match '^\d+$' -and $f[3] -ne '3') ('The commit limit and charge are still the WMI sentinels (7 / 3 MB) - GetPerformanceInfo''s answer was not used: ' + $mem[0])
    $limB = [double](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).TotalVirtualMemorySize / 1024
    $lo = [Math]::Min($limA, $limB) * 0.98; $hi = [Math]::Max($limA, $limB) * 1.02
    Assert-True ([double]$f[4] -ge $lo -and [double]$f[4] -le $hi) ('GetPerformanceInfo''s commit limit ({0} MB) is not Win32_OperatingSystem''s ({1:N0}-{2:N0} MB) - the buffer is read at the wrong offsets or scaled by the wrong page size.' -f $f[4], $limA, $limB)
    Assert-True ($null -ne $pb -and [uint64]$f[5] -ge $pa[2] -and [uint64]$f[5] -le $pb[2]) ('The worker read a commit peak of {0} MB; this harness read {1} MB before it and {2} MB after it, and the peak only grows - the worker reads it from the wrong place.' -f $f[5], $pa[2], $(if ($pb) { $pb[2] } else { '?' }))
    Assert-True ([int64]$f[5] -ge [int64]$f[3] -and [int64]$f[3] -le [int64]$f[4]) ('Commit charge {0} MB, peak {1} MB, limit {2} MB: the peak is below the charge or the charge above the limit - the fields are read from the wrong places.' -f $f[3], $f[5], $f[4])
    $want = [int64]$f[5] * 10 -ge [int64]$f[4] * 9
    $got = @($recs | Where-Object { $_ -eq ('ADV|commit|{0}|{1}' -f $f[5], $f[4]) }).Count -eq 1
    Assert-True ($got -eq $want) ('The commit verdict is {0} for a real peak of {1} of {2} MB.' -f $(if ($got) { 'present' } else { 'missing' }), $f[5], $f[4])
    Assert-True (@($recs | Where-Object { $_ -eq 'ADV|none|now' }).Count -eq 1) ('The faked no-page-file machine did not get its no-page-file verdict: ' + ($recs -join ' | '))
}

# ===============================================================================
# 147. The crash report is wired into System tools and it only READS. Its three
#      workers are single -Command lines cmd can hold (8191) and delayed expansion
#      cannot alter; they read events through EventLogReader - never Get-WinEvent,
#      whose -FilterHashtable answers an unreadable log with NoMatchingEventsFound,
#      the same answer as "nothing happened" (measured under a basic-user token) -
#      and never the rendered message text. Each log's oldest record is read before
#      the main query, and the main queries run newest first, so an event cap keeps
#      the latest events. SCM 7045's ImagePath (a service command line can hold a
#      secret) is used for nothing but the .sys test, and ServiceType (localized
#      text) is not read at all. WHEA events are classified by ID in the collector
#      alone (id 29 is fatal at the warning level), and its query keeps WHEA levels
#      1-3: an informational record (level 4, id 3) would fail closed into
#      UNCORRECTED. The summary and timeline never look at a level, share one Ntfs
#      98 test, and do not repeat the cap.
# ===============================================================================
Invoke-Test 'Crash report is wired into System tools and only reads' {
    $cmd = Read-Lines $CmdPath
    $mt = @(Get-BodyLines -Lines $cmd -Label 'MenuTools')
    Assert-True (($mt -join "`n") -match '(?m)^echo\s+3\.\s+Crash \^& hardware-error report') ':MenuTools no longer lists the crash report as item 3.'
    $ask = @(Get-BodyLines -Lines $cmd -Label 'MenuTools_ask' -CodeOnly) -join "`n"
    Assert-True ($ask -match '(?m)^if "!sel!"=="3" goto CrashReport\s*$') ':MenuTools_ask does not route 3 -> CrashReport.'

    $s = [Array]::IndexOf($cmd, ':CrashReport'); $e = [Array]::IndexOf($cmd, ':CrashTimeline')
    Assert-True ($s -gt 0 -and $e -gt $s) 'The crash report section (:CrashReport .. :CrashTimeline) is missing or reordered.'
    $j = $e + 1; while ($j -lt $cmd.Count -and $cmd[$j] -notmatch '^:\w') { $j++ }
    $sec = @($cmd[$s..($j - 1)])
    $code = @($sec | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' })
    $noecho = @($code | Where-Object { $_.Trim() -notmatch '^(?i)echo\b' })
    Assert-True ($code.Count -gt 100) "The crash report section is only $($code.Count) code lines - the slice is wrong."
    $bad = @($noecho | Where-Object { $_ -match '(?i)\b(reg\s+(add|delete|import)|wevtutil|call :SafeReg\w*|Clear-EventLog|Limit-EventLog|Remove-Item|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Set-Content|Stop-Process|Start-Process|sc\s+config|schtasks|bcdedit|powercfg)\b' })
    Assert-True ($bad.Count -eq 0) ('The read-only crash report runs something that changes the system: ' + (($bad | Select-Object -First 2 | ForEach-Object { $_.Trim().Substring(0, [Math]::Min(90, $_.Trim().Length)) }) -join ' | '))

    $workers = [ordered]@{ 'PT_CR_OUT' = 'CrashCollect'; 'PT_CR_SUM' = 'CrashSummary'; 'PT_CR_LT' = 'CrashTimeline' }
    $pay = @{}
    foreach ($k in $workers.Keys) {
        $lab = $workers[$k]
        $b = @(Get-BodyLines -Lines $cmd -Label $lab -CodeOnly)
        $w = @($b | Where-Object { $_ -match '^start "" /min /wait powershell -NoProfile -Command "' })
        Assert-True ($w.Count -eq 1) (":$lab should start exactly one PowerShell worker; found $($w.Count).")
        Assert-True ($w[0].Contains('$env:' + $k)) (":$lab worker does not use `$env:$k.")
        Assert-True ($w[0].Length -lt 8000) (":$lab worker line is $($w[0].Length) characters; cmd refuses a line over 8191, so keep headroom.")
        $raw = [regex]::Match($w[0], '-Command "(.*)"\s*$').Groups[1].Value
        Assert-True ($raw.Length -gt 1000) (":$lab payload was not extracted.")
        Assert-True (-not $raw.Contains('"') -and -not $raw.Contains('!') -and -not $raw.Replace('%%', '').Contains('%') -and -not $raw.Contains('#')) (":$lab payload holds a double quote, a '!', a single '%' or a '#' - cmd would change the first three before PowerShell saw them, and a '#' would comment out the rest of the one-line payload.")
        Assert-True ($raw -match '^\$ErrorActionPreference=''SilentlyContinue''; if\(-not \$env:[^)]*\)\{ exit 2 \};' -and $raw -match ('^[^;]*; if\([^)]*-not \$env:' + $k + '\b')) (":$lab payload no longer refuses to run without its hand-off variable - an unset path makes a cmdlet prompt in a minimized window (pitfall 45).")
        Assert-True (@($b | Where-Object { $_ -match ('(^|& )set "' + $k + '="') }).Count -ge 1) (":$lab does not clear $k after the child.")
        $pay[$lab] = $raw
    }

    $col = $pay['CrashCollect']
    Assert-True ($col -match 'System\.Diagnostics\.Eventing\.Reader\.EventLogReader') 'The collector no longer uses EventLogReader.'
    Assert-True ($col -notmatch '(?i)Get-WinEvent|Get-EventLog|\.Message\b|FormatDescription|wevtutil') 'The collector reads events through Get-WinEvent / Get-EventLog / message text again: -FilterHashtable reports an unreadable log as NoMatchingEventsFound (measured), and message text is localized and slow.'
    Assert-True ($col -match '\[UnauthorizedAccessException\]' -and $col -match 'EventLogNotFoundException') 'The collector no longer tells "access refused" and "log missing" apart from a clean read.'
    $probe = $col.IndexOf("`$r=xRd `$l '*'; "); $main = $col.IndexOf('Kernel-Power')
    Assert-True ($probe -ge 0 -and $main -gt $probe) 'The collector does not read each log''s oldest record (forward, no reverse flag) before the main query - a failed read could then look like "nothing found".'
    Assert-True ($col.Contains('if($v){ $q.ReverseDirection=$true }') -and ([regex]::Matches($col, [regex]::Escape("+`$w+']]') 1;"))).Count -eq 2) 'The main System and Application queries no longer read newest first - at the event cap the LATEST events would be the ones dropped.'
    Assert-True ($col.Contains("xD `$x 'ImagePath'") -and ([regex]::Matches($col, 'ImagePath')).Count -eq 1) 'SCM 7045 ImagePath is used for more than the .sys test - a service command line can hold a secret and must never be written out.'
    Assert-True ($col -notmatch "'ServiceType'|'StartType'") 'The collector reads ServiceType / StartType - those fields are localized text (measured on a ru-RU machine).'
    Assert-True ($col.Contains('$wco=@(2,17,19,21,23,25,27,28,41,43,45,47,49)') -and $col.Contains('$wcpu=@(18,19,28,29)') -and $col.Contains("`$A='uncorrected'; if(`$wco -contains `$id){ `$A='corrected' }")) 'The collector no longer classifies WHEA events by the manifest''s corrected IDs, failing closed to "uncorrected" (id 29 is fatal at the warning level).'
    Assert-True ($col.Contains("('(Provider[@Name='+`$ap+'Microsoft-Windows-WHEA-Logger'+`$ap+'] and (Level=1 or Level=2 or Level=3))')")) 'The collector''s WHEA query no longer keeps levels 1-3 only - an informational record (level 4, id 3 "A hardware event has occurred") would fail closed into UNCORRECTED and raise the hardware-error hint.'
    foreach ($lab in 'CrashSummary', 'CrashTimeline') {
        Assert-True ($pay[$lab] -notmatch '\bLvl\b') (":$lab reads the event level - WHEA must be classified by ID (in the collector), and id 29 is a fatal error logged at level 3.")
        Assert-True ($pay[$lab].Contains("(`$_.A -match '^[0-9]+`$' -and `$_.A -ne '0')")) (":$lab no longer uses the shared Ntfs 98 test - the summary and the timeline would disagree about which 98 events are corruption.")
    }
    $cm = [regex]::Matches($col, '\$cap=([0-9]+);')
    Assert-True ($cm.Count -eq 1) 'The collector should set its event cap exactly once.'
    $capv = $cm[0].Groups[1].Value
    Assert-True ([int]$capv -le 30000) ("The event cap is $capv; the summary and timeline were timed at 2-4 s each on 30,000 rows and up to 5.7 s on 50,000 - raise it only after timing them again.")
    Assert-True (-not $pay['CrashSummary'].Contains($capv) -and -not $pay['CrashTimeline'].Contains($capv) -and @($noecho | Where-Object { $_.Contains($capv) -and $_ -notmatch '\$env:PT_CR_OUT' }).Count -eq 0) ("The cap value $capv is repeated outside the collector - it is handed on in the W row, so a second copy can only drift (pitfall 28).")
    Assert-True ($col.Contains("-notlike 'FullReg_*'") -and $col -notmatch '\.Extension -eq') 'The undo-file count no longer skips FullReg_* exports - a full registry backup changes nothing, yet would read as "sincript made changes".'

    $tmps = @($sec | Where-Object { $_ -match 'set "_cr\w+=!TEMP!\\pt_cr' })
    Assert-True ($tmps.Count -ge 6 -and @($tmps | Where-Object { $_ -notmatch '%RANDOM%%RANDOM%' }).Count -eq 0) 'Crash report temp files must be per-call (%RANDOM%%RANDOM%).'
}

# ===============================================================================
# 148. The classification is RUN on synthetic events. The summary and timeline
#      payloads are taken from the script and fed hand-written events files (the
#      same CSV the collector writes). A: every category; one crash's Kernel-Power
#      41 + WER 1001 (+ EventLog 6008) counted ONCE; a 41 with no code next to a
#      WER 1001 that has one is a bugcheck, not a "no code" restart; WHEA id 29 is
#      UNCORRECTED although logged at level 3 (the collector's class, never the
#      level); only Processor Core ids count as machine checks; a healthy or
#      state-less Ntfs 98 is ignored by both workers; a 2004 without its numbers
#      says "low virtual memory". B: an unreadable System or Application log is
#      never "None found" / "none", and its line - every reason, the longer log
#      name - ends whole (the worker cuts lines at 96, so a width check alone
#      cannot see a cut). C: a log holding exactly ONE event - a function
#      returning @(x) unrolls to x, and a lone PSCustomObject has no .Count in
#      PowerShell 5.1, so a single Kernel-Power 41 once read as "None found:
#      unexpected restarts" (measured). D: nothing outside the week before the
#      first crash is blamed - a corrected WHEA error is not a crash, and a driver
#      10 days before it or after it, a service, a sincript session after it or
#      one that wrote no undo file name nothing. E: a capped read says so, with
#      the cap from the W row, and bounds "None found" by the days actually read;
#      an Application log the System log left no room for under the shared cap
#      says NOT READ, never "stopped at" or "none".
# ===============================================================================
Invoke-Test 'Crash report classification is honest on synthetic events (run)' {
    $cmd = Read-Lines $CmdPath
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $payload = @{}
    foreach ($key in 'PT_CR_SUM', 'PT_CR_LT') {
        $hits = @($cmd | Where-Object { $_.TrimStart() -notmatch '^(?i)rem\b' -and $_.Contains('-Command "') -and $_.Contains('$env:' + $key) })
        Assert-True ($hits.Count -eq 1) ('Expected one worker line using $env:{0}, found {1}.' -f $key, $hits.Count)
        $m = [regex]::Match($hits[0], '-Command "(.*)"\s*$')
        Assert-True $m.Success ('The {0} worker lost the -Command "..." shape this test extracts.' -f $key)
        $payload[$key] = $m.Groups[1].Value.Replace('%%', '%')
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('PT148_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $tmp)
    $run = {
        param([string]$Name, [string[]]$Rows, [switch]$SummaryOnly)
        $in = Join-Path $tmp ($Name + '_ev.txt')
        [IO.File]::WriteAllLines($in, [string[]](@('"K","T","Log","Prov","Id","Lvl","A","B","C"') + $Rows), [Text.Encoding]::ASCII)
        $envs = @{ PT_CR_IN = $in; PT_CR_SUM = (Join-Path $tmp ($Name + '_sum.txt')); PT_CR_STAT = (Join-Path $tmp ($Name + '_stat.txt')); PT_CR_LT = (Join-Path $tmp ($Name + '_lt.txt')); PT_CR_TL = (Join-Path $tmp ($Name + '_tl.txt')) }
        $keys = @('PT_CR_SUM', 'PT_CR_LT'); if ($SummaryOnly) { $keys = @('PT_CR_SUM') }
        foreach ($key in $keys) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $psExe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload[$key]))
            foreach ($k in $envs.Keys) { $psi.EnvironmentVariables[$k] = $envs[$k] }
            $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close(); $null = $p.StandardError.ReadToEndAsync(); $null = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "test 148: the $key worker did not finish within 60 s." }
            Assert-True ($p.ExitCode -eq 0) "test 148 ($Name): the $key worker exited $($p.ExitCode)."
        }
        $st = @{}
        foreach ($l in [IO.File]::ReadAllLines($envs['PT_CR_STAT'])) { $i = $l.IndexOf('='); if ($i -gt 0) { $st[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
        $sum = [IO.File]::ReadAllLines($envs['PT_CR_SUM'])
        if ($SummaryOnly) { return [pscustomobject]@{ Sum = ($sum -join "`n"); All = @($sum); Tl = ''; St = $st } }
        [pscustomobject]@{ Sum = ($sum -join "`n"); All = @($sum + [IO.File]::ReadAllLines($envs['PT_CR_LT']) + [IO.File]::ReadAllLines($envs['PT_CR_TL'])); Tl = ([IO.File]::ReadAllLines($envs['PT_CR_TL']) -join "`n"); St = $st }
    }
    $MW = 'Microsoft-Windows-'
    $W = '"W","2026-01-31 12:00","","","","","30","20260131_1200","0"'
    $okS = '"L","2025-12-01 00:00","System","","","","ok","30",""'
    $okA = '"L","2025-12-01 00:00","Application","","","","ok","30",""'
    $narrow = { param($r, $tag) Assert-True (@($r.All | Where-Object { $_.Length -gt 96 -or $_ -match '[^\x20-\x7e]' }).Count -eq 0) "${tag}: a report line is wider than 96 columns or not plain ASCII." }
    try {
        # ---- A: every category; one crash logged three ways; a paired no-code 41; WHEA 29 at level 3
        $r = & $run 'A' @($W, $okS, $okA,
            '"E","2026-01-18 09:00:00","System","Service Control Manager","7045","4","SomeDrv","driver",""',
            '"S","2026-01-19 21:00:00","","sincript","","","3","",""',
            ('"E","2026-01-20 10:00:05","System","' + $MW + 'Kernel-Power","41","1","0x00000124","0","WHEA_UNCORRECTABLE_ERROR"'),
            ('"E","2026-01-20 10:00:07","System","' + $MW + 'WHEA-Logger","18","2","uncorrected","cpu",""'),
            '"E","2026-01-20 10:00:10","System","EventLog","6008","2","","",""',
            ('"E","2026-01-20 10:01:00","System","' + $MW + 'WER-SystemErrorReporting","1001","2","0x00000124","","WHEA_UNCORRECTABLE_ERROR"'),
            ('"E","2026-01-21 11:00:00","System","' + $MW + 'WHEA-Logger","19","3","corrected","cpu",""'),
            ('"E","2026-01-21 11:05:00","System","' + $MW + 'WHEA-Logger","19","3","corrected","cpu",""'),
            ('"E","2026-01-21 12:00:00","System","' + $MW + 'WHEA-Logger","17","3","corrected","",""'),
            ('"E","2026-01-22 08:00:00","System","' + $MW + 'Kernel-Power","41","1","","133000000000000000",""'),
            '"E","2026-01-23 20:00:00","System","Display","4101","3","nvlddmkm","",""',
            '"E","2026-01-24 01:00:00","System","disk","153","3","Harddisk1","",""',
            '"E","2026-01-24 01:01:00","System","storahci","129","3","RaidPort0","",""',
            '"E","2026-01-24 01:02:00","System","disk","7","2","Harddisk1","",""',
            ('"E","2026-01-25 09:00:00","System","' + $MW + 'Kernel-Power","41","1","","0",""'),
            '"E","2026-01-25 09:00:30","System","Ntfs","55","2","C:","",""',
            ('"E","2026-01-25 09:00:31","System","' + $MW + 'Ntfs","98","4","0","C:",""'),
            ('"E","2026-01-25 09:00:32","System","' + $MW + 'Ntfs","98","4","2","D:",""'),
            ('"E","2026-01-25 09:00:33","System","' + $MW + 'Ntfs","98","4","","E:",""'),
            ('"E","2026-01-26 03:00:00","System","' + $MW + 'WHEA-Logger","29","3","uncorrected","cpu",""'),
            ('"E","2026-01-26 14:00:00","System","' + $MW + 'Resource-Exhaustion-Detector","2004","3","17179869184","17448304640",""'),
            ('"E","2026-01-26 15:00:00","System","' + $MW + 'Resource-Exhaustion-Detector","2004","3","","",""'),
            '"E","2026-01-27 07:00:00","System","volmgr","46","2","","",""',
            ('"E","2026-01-27 20:00:00","System","' + $MW + 'Kernel-Power","41","1","","0",""'),
            ('"E","2026-01-27 20:01:00","System","' + $MW + 'WER-SystemErrorReporting","1001","2","0x0000009F","","DRIVER_POWER_STATE_FAILURE"'),
            '"E","2026-01-28 07:00:00","System","EventLog","6008","2","","",""',
            '"E","2026-01-29 18:00:00","Application","Application Error","1000","2","game.exe","nvwgf2umx.dll","c0000005"',
            '"E","2026-01-29 18:30:00","Application","Application Error","1000","2","game.exe","nvwgf2umx.dll","c0000005"')
        $s = $r.Sum
        Assert-True ($s -match '(?m)^  Unexpected restarts\s+5  2 bugcheck, 1 power button held, 1 no code, 1 lone 6008$') "A: 4 Kernel-Power 41 + 1 lone 6008 should be 5 restarts - the 6008 logged with a 41 is the same restart, and the code-less 41 next to a coded WER 1001 is a bugcheck. Got:`n$s"
        $bl = @($r.Sum -split "`n" | Where-Object { $_ -match '^  Bugchecks \(blue screens\)' })
        Assert-True ($bl.Count -eq 1 -and $bl[0] -match '\s2  0x(00000124 WHEA_UNCORRECTABLE_ERROR|0000009F DRIVER_POWER_STATE_FAILURE), 0x' -and $bl[0].Contains('0x00000124') -and $bl[0].Contains('0x0000009F')) ('A: one crash''s 41 and 1001 must count once, each bugcheck shown by code and named from it (the line is cut at 96 columns). Got: ' + ($bl -join ' | '))
        Assert-True ($s -match '(?m)^  Hardware errors, UNCORRECTED\s+2  WHEA-Logger (id 18, id 29|id 29, id 18)$') "A: WHEA id 29 is a fatal error logged at level 3 - it must be counted as UNCORRECTED next to id 18 (the class, not the level). Got:`n$s"
        Assert-True ($s -match '(?m)^  Hardware errors, corrected\s+3  WHEA-Logger id 19 x2, id 17$') 'A: corrected WHEA errors, raw ids with counts.'
        Assert-True ($s -match '(?m)^  Display driver resets \(TDR\)\s+1  Display 4101: nvlddmkm$') 'A: Display 4101 counted with its driver name.'
        Assert-True ($s -match '(?m)^  Disk retries / resets\s+2  ' -and $s -match '(?m)^  Disk bad blocks\s+1  disk 7: Harddisk1$') 'A: disk 153 + storahci 129 are retries/resets; disk 7 is a bad block.'
        Assert-True ($s -match '(?m)^  NTFS corruption reported\s+2  ') 'A: Ntfs 55 and a non-zero Ntfs 98 count; a state-0 ("volume is healthy") or state-less 98 must not.'
        Assert-True ($s -match '(?m)^  Low virtual memory\s+2  ' -and $s -match '(?m)^  Crash-dump setup failed\s+1  volmgr 46$') 'A: both 2004 events and volmgr 46 counted.'
        Assert-True ($s -notmatch 'None found') 'A: a None-found line appeared although every category has events.'
        Assert-True ($s -match '(?m)^  App crashes \(Application log\)\s+2  game\.exe / nvwgf2umx\.dll x2$') 'A: app crashes grouped by app / module.'
        $st = $r.St
        Assert-True ($st['sys'] -eq 'ok' -and $st['app'] -eq 'ok' -and $st['stamp'] -eq '20260131_1200' -and $st['capped'] -eq '0') 'A: both logs ok, not capped, stamp passed through.'
        Assert-True ($st['hw'] -eq '3' -and $st['mce'] -eq '5' -and $st['nocode'] -eq '1' -and $st['vm46'] -eq '1' -and $st['disk'] -eq '3' -and $st['ntfs'] -eq '2' -and $st['rex'] -eq '2' -and $st['tdr'] -eq '1') ('A: the hint counts are wrong (hw = uncorrected WHEA + 0x124; mce = Processor Core WHEA + 0x124; nocode leaves out the paired 41): ' + (($st.Keys | Sort-Object | ForEach-Object { $_ + '=' + $st[$_] }) -join ' '))
        Assert-True ($st['drv'] -eq 'SomeDrv' -and $st['drvdate'] -eq '2026-01-18' -and $st['sin'] -eq '2026-01-19') 'A: the driver installed, and the sincript session that wrote undo files, in the week before the first crash are not reported.'
        Assert-True ($r.Tl -match 'Kernel-Power 41\s+bugcheck 0x00000124' -and $r.Tl -match 'WHEA-Logger 29\s+UNCORRECTED hardware error') 'A: the timeline lost the 41''s code, or calls WHEA 29 corrected.'
        Assert-True ($r.Tl -notmatch 'state 0' -and $r.Tl -notmatch 'volume E:') 'A: the timeline lists a healthy or state-less Ntfs 98 that the summary does not count - the two workers must use one test.'
        Assert-True ($r.Tl -match 'Resource-Exh 2004\s+commit 16\.0 of 16\.[23] GB' -and $r.Tl -match 'Resource-Exh 2004\s+low virtual memory') 'A: a 2004 with its numbers shows them, and one without them must say "low virtual memory" (not "commit 0.0 of 0.0 GB").'
        & $narrow $r 'A'

        # ---- B: neither log could be read (System refused, Application missing) - never "nothing found" or "none"
        $r = & $run 'B' @($W, '"L","","System","","","","denied","0",""', '"L","","Application","","","","missing","0",""') -SummaryOnly
        Assert-True ($r.Sum -match '(?m)^  System log: COULD NOT BE READ \(access refused\) - finding nothing there proves nothing\.$' -and $r.Sum -match '(?m)^  Application log: COULD NOT BE READ \(no such log\) - finding nothing there proves nothing\.$') "B: an unreadable log is not said out loud with its reason, or its line was cut at 96 columns. Got:`n$($r.Sum)"
        Assert-True ($r.Sum -match 'NOT DONE' -and $r.Sum -notmatch 'None found') 'B: an unreadable log produced a None-found line - a failed read reported as good news.'
        Assert-True ($r.Sum -match '(?m)^  App crashes \(Application log\)\s+-  NOT READ' -and $r.Sum -notmatch 'none in the') 'B: an unreadable Application log reads as "no app crashes".'
        Assert-True ($r.St['sys'] -eq 'fail' -and $r.St['app'] -eq 'fail') 'B: stat sys / app is not fail, so the final line would not be [FAIL].'
        & $narrow $r 'B'
        $r = & $run 'B2' @($W, '"L","","System","","","","error","0",""', '"L","","Application","","","","error","0",""') -SummaryOnly
        Assert-True ($r.Sum -match '(?m)^  System log: COULD NOT BE READ \(the read failed\) - finding nothing there proves nothing\.$' -and $r.Sum -match '(?m)^  Application log: COULD NOT BE READ \(the read failed\) - finding nothing there proves nothing\.$') "B2: the longest COULD NOT BE READ line (Application, the read failed) was cut at 96 columns or lost its reason. Got:`n$($r.Sum)"
        Assert-True ($r.St['sys'] -eq 'fail' -and $r.St['app'] -eq 'fail') 'B2: a log whose read failed for another reason is not fail.'
        & $narrow $r 'B2'

        # ---- C: exactly ONE event, a System log cleared a day ago, an empty Application log
        $r = & $run 'C' @($W, '"L","2026-01-30 22:09","System","","","","ok","1","2026-01-30 22:09"', '"L","","Application","","","","empty","0",""',
            ('"E","2026-01-31 05:31:12","System","' + $MW + 'Kernel-Power","41","1","","134346042600109507",""'))
        Assert-True ($r.Sum -match '(?m)^  Unexpected restarts\s+1  1 power button held$') "C: a single Kernel-Power 41 is not counted - the @() unroll trap (a lone PSCustomObject has no .Count in PowerShell 5.1). Got:`n$($r.Sum)"
        Assert-True ($r.Sum -match 'None found in the 1 day\(s\) the System log covers' -and $r.Sum -notmatch 'covers: unexpected restarts') 'C: None-found is not bounded by the covered day, or lists what WAS found.'
        Assert-True (($r.Sum -replace '\n    ', ' ') -match 'disk retries or resets \(Windows storage drivers only\)') 'C: the None-found list no longer says the disk-reset check covers only Windows'' own storage drivers.'
        Assert-True ($r.Sum -match 'It was cleared 2026-01-30 22:09' -and $r.Sum -match 'Application log: EMPTY') 'C: a cleared or empty log is not said.'
        Assert-True ($r.St['sys'] -eq 'short' -and $r.St['app'] -eq 'short') 'C: a partial read is reported as ok.'

        # ---- D: evidence outside the week before the first crash (Kernel-Power 41 with a code, 2026-01-20)
        #      blames nothing: a corrected WHEA error before it is not a crash, DrvOld is 10 days before
        #      it, DrvLate and the session that wrote undo files come after it, SvcNear is a service,
        #      and the session before it wrote no undo file
        $r = & $run 'D' @($W, $okS, $okA,
            '"E","2026-01-10 08:00:00","System","Service Control Manager","7045","4","DrvOld","driver",""',
            '"E","2026-01-13 08:00:00","System","Service Control Manager","7045","4","DrvEdge","driver",""',
            ('"E","2026-01-12 09:00:00","System","' + $MW + 'WHEA-Logger","19","3","corrected","cpu",""'),
            '"E","2026-01-18 09:00:00","System","Service Control Manager","7045","4","SvcNear","service",""',
            '"S","2026-01-19 21:00:00","","sincript","","","0","",""',
            ('"E","2026-01-20 10:00:05","System","' + $MW + 'Kernel-Power","41","1","0x0000009F","0","DRIVER_POWER_STATE_FAILURE"'),
            '"E","2026-01-20 10:30:00","System","Service Control Manager","7045","4","DrvSoon","driver",""',
            '"S","2026-01-20 12:00:00","","sincript","","","2","",""',
            '"S","2026-01-21 21:00:00","","sincript","","","2","",""',
            '"E","2026-01-22 09:00:00","System","Service Control Manager","7045","4","DrvLate","driver",""')
        $st = $r.St
        Assert-True ($st.ContainsKey('drv') -and $st.ContainsKey('drvdate') -and $st.ContainsKey('sin')) 'D: the timeline worker did not append drv / drvdate / sin - the checks below would prove nothing.'
        Assert-True ($r.Tl -match 'SCM 7045\s+DrvOld \(driver\)' -and $r.Tl -match 'SCM 7045\s+DrvLate \(driver\)' -and $r.Tl -match 'SCM 7045\s+SvcNear \(service\)' -and $r.Tl -match 'WHEA-Logger 19\s+corrected hardware error' -and $r.Tl -match 'Kernel-Power 41\s+bugcheck 0x0000009F' -and ([regex]::Matches($r.Tl, 'sincript session')).Count -eq 3 -and $r.Tl -match 'SCM 7045\s+DrvEdge \(driver\)' -and $r.Tl -match 'SCM 7045\s+DrvSoon \(driver\)') "D: the timeline does not list the fixture's installs, sessions and events - the checks below would prove nothing. Got:`n$($r.Tl)"
        Assert-True ($st['drv'] -eq '' -and $st['drvdate'] -eq '') ("D: a driver was blamed on evidence outside the week before the first crash (a Kernel-Power 41 on 2026-01-20; the corrected WHEA error on 01-12 is not a crash; DrvOld is 10 days earlier, DrvLate later, SvcNear a service). Got drv='{0}' drvdate='{1}'." -f $st['drv'], $st['drvdate'])
        Assert-True ($st['sin'] -eq '') ("D: sincript was blamed for a session after the first crash, or for one that wrote no undo file. Got sin='{0}'." -f $st['sin'])
        Assert-True ($st['hw'] -eq '0' -and $st['mce'] -eq '1') ('D: a corrected WHEA error was counted as uncorrected, or the Processor Core one was not a machine check: ' + (($st.Keys | Sort-Object | ForEach-Object { $_ + '=' + $st[$_] }) -join ' '))
        Assert-True ($r.Sum -match '(?m)^  Application log: read, covers the full 30 days\.$' -and $r.Sum -match '(?m)^  App crashes \(Application log\)\s+0  none in the 30 day\(s\) that log covers$' -and $r.Sum -notmatch 'NOT READ') "D: a fully read Application log with no app crash is not said as read and empty. Got:`n$($r.Sum)"
        & $narrow $r 'D'
        foreach ($fc in @('"E","2026-01-20 10:00:00","System","EventLog","6008","2","","",""',
                ('"E","2026-01-20 10:00:00","System","' + $MW + 'WER-SystemErrorReporting","1001","2","0x0000009F","","DRIVER_POWER_STATE_FAILURE"'),
                ('"E","2026-01-20 10:00:00","System","' + $MW + 'WHEA-Logger","18","2","uncorrected","cpu",""'))) {
            $r = & $run 'D2' @($W, $okS, $okA,
                '"E","2026-01-19 08:00:00","System","Service Control Manager","7045","4","DrvPre","driver",""',
                '"S","2026-01-19 21:00:00","","sincript","","","1","",""',
                $fc,
                '"E","2026-01-24 09:00:00","System","Service Control Manager","7045","4","DrvMid","driver",""',
                ('"E","2026-01-27 20:00:00","System","' + $MW + 'Kernel-Power","41","1","","0",""'))
            Assert-True ($r.St['drv'] -eq 'DrvPre' -and $r.St['drvdate'] -eq '2026-01-19' -and $r.St['sin'] -eq '2026-01-19') ("D2: a first crash logged only as {0} was not taken as the first crash. Got drv='{1}' drvdate='{2}' sin='{3}'." -f $fc, $r.St['drv'], $r.St['drvdate'], $r.St['sin'])
        }

        # ---- E: reading stopped at the cap: stated per log, the cap taken from the W row, days bounded
        $r = & $run 'E' @('"W","2026-01-31 12:00","","","","","30","20260131_1200","12345"', '"L","2025-12-01 00:00","System","","","","capped","2",""', '"L","2025-12-01 00:00","Application","","","","capped","0",""',
            ('"E","2026-01-31 11:00:00","System","' + $MW + 'WHEA-Logger","17","3","corrected","",""'))
        Assert-True ($r.Sum -match '(?m)^  System log: stopped at the shared 12345-event cap \(newest first\) - covers 2 day\(s\)\.$') "E: a capped log is not said, or its cap is not the one the collector wrote. Got:`n$($r.Sum)"
        Assert-True ($r.Sum -match '(?m)^  Application log: NOT READ - the System log used up the shared 12345-event cap\.$' -and $r.Sum -notmatch 'Application log: stopped at') "E: the System log used up the shared cap and no Application event was read - 'stopped at' the cap would claim 12345 events of its own. Got:`n$($r.Sum)"
        Assert-True ($r.Sum -match 'None found in the 2 day\(s\) the System log covers' -and $r.Sum -match '(?m)^  App crashes \(Application log\)\s+-  NOT READ - the event cap was reached first$' -and $r.Sum -notmatch 'none in the') "E: None-found is not bounded by the days actually read before the cap, or an unread Application log reads as 'none'. Got:`n$($r.Sum)"
        Assert-True ($r.St['capped'] -eq '12345' -and $r.St['sys'] -eq 'short' -and $r.St['app'] -eq 'short') ('E: a capped read must pass the cap on and never count as a full read: ' + (($r.St.Keys | Sort-Object | ForEach-Object { $_ + '=' + $r.St[$_] }) -join ' '))
        & $narrow $r 'E'

        # ---- E2: the Application log reached the shared cap itself, after some of it was read
        $r = & $run 'E2' @('"W","2026-01-31 12:00","","","","","30","20260131_1200","12345"', $okS, '"L","2025-12-01 00:00","Application","","","","capped","3",""',
            '"E","2026-01-30 18:00:00","Application","Application Error","1000","2","game.exe","nvwgf2umx.dll","c0000005"') -SummaryOnly
        Assert-True ($r.Sum -match '(?m)^  Application log: stopped at the shared 12345-event cap \(newest first\) - covers 3 day\(s\)\.$' -and $r.Sum -notmatch 'NOT READ' -and $r.Sum -match '(?m)^  App crashes \(Application log\)\s+1  game\.exe / nvwgf2umx\.dll$') "E2: an Application log read up to the cap must say where it stopped and show what it read, never NOT READ. Got:`n$($r.Sum)"
        Assert-True ($r.St['sys'] -eq 'ok' -and $r.St['app'] -eq 'short' -and $r.St['capped'] -eq '12345') 'E2: a capped Application log counted as a full read.'
        & $narrow $r 'E2'
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
}

# ===============================================================================
# 149. The collector is RUN against a faked event-log reader. New-Object is a
#      cmdlet, so a global function of that name wins, and it hands the payload
#      fake EventLogQuery / EventLogReader objects that honour ReverseDirection:
#      a System log whose oldest record is a clear notice, events carrying their
#      data by field name (and the classic providers' positional strings), and an
#      Application log refused twice over - at the oldest-record probe while its
#      query would quietly return nothing (the Get-WinEvent -FilterHashtable
#      shape), and after a good probe. Both must come out as "denied", never as a
#      log with no events. WHEA events get their class from the ID (29 is fatal,
#      an unknown id fails closed). Only undo files written before a change count
#      toward a sincript session - a FullReg_* export does not. With the cap cut
#      to 3, the NEWEST three events are kept and the days covered shrink to them.
#      Anything that could change the system ends the child (exit 149).
# ===============================================================================
Invoke-Test 'Crash report collector: unreadable is "denied", fields by name, no paths, newest first at the cap (run with a faked reader)' {
    $cmd = Read-Lines $CmdPath
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $hits = @($cmd | Where-Object { $_.TrimStart() -notmatch '^(?i)rem\b' -and $_.Contains('-Command "') -and $_.Contains('$env:PT_CR_OUT') })
    Assert-True ($hits.Count -eq 1) "Expected one collector line using `$env:PT_CR_OUT, found $($hits.Count)."
    $raw = [regex]::Match($hits[0], '-Command "(.*)"\s*$').Groups[1].Value.Replace('%%', '%')
    $capm = [regex]::Matches($raw, '\$cap=[0-9]+;')
    Assert-True ($capm.Count -eq 1) 'The collector no longer sets its cap in one "$cap=N;" statement this test can shrink.'
    $raw3 = $raw.Replace($capm[0].Value, '$cap=3;')
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('PT149_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $bak = Join-Path $tmp 'bak'; [void](New-Item -ItemType Directory -Force -Path $bak)
    $csv = Join-Path $tmp 'ev.txt'
    $t0 = (Get-Date).AddDays(-2)
    $lg = Join-Path $bak 'PerfTweaks_1.log'; [IO.File]::WriteAllText($lg, 'x')
    [IO.File]::SetCreationTime($lg, $t0); [IO.File]::SetLastWriteTime($lg, $t0.AddMinutes(5))
    # written in that session: four undo files of the four families, and three that are not undo files
    foreach ($n in 'HKCU_Software_PT_Test_12345.reg', 'Preset_moderate_678.json', 'PowerPlan_91.bat', 'Telemetry_nvidia_55.bat', 'FullReg_HKLM_4321.reg', 'notes.bat', 'CrashReport_x.txt') {
        $f = Join-Path $bak $n; [IO.File]::WriteAllText($f, 'x'); [IO.File]::SetCreationTime($f, $t0.AddMinutes(2))
    }
    $old = Join-Path $bak 'PerfTweaks_2.log'; [IO.File]::WriteAllText($old, 'x'); [IO.File]::SetCreationTime($old, (Get-Date).AddDays(-40))
    $prelude = @'
foreach ($n in @('reg', 'reg.exe', 'wevtutil', 'wevtutil.exe', 'Clear-EventLog', 'Limit-EventLog', 'Remove-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Content', 'Start-Process', 'Stop-Process')) {
    Set-Item -Path ('function:global:' + $n) -Value ([scriptblock]::Create("[Console]::Error.WriteLine('test 149: the collector tried to run $n'); [Environment]::Exit(149)"))
}
$global:PTNS = 'http://schemas.microsoft.com/win/2004/08/events/event'
function global:PTEv($prov, $id, $lvl, $ageDays, $inner) {
    $o = [pscustomobject]@{ ProviderName = $prov; Id = $id; Level = $lvl; TimeCreated = (Get-Date).AddDays(-$ageDays); X = ('<Event xmlns=''' + $global:PTNS + '''><System/>' + $inner + '</Event>') }
    $o | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $this.X }
    $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    $o
}
# events are listed oldest first, as a log holds them; a reverse-direction query reads them newest first
function global:PTRd($evs, $rev) {
    $a = @($evs); if ($rev) { [array]::Reverse($a) }
    $q = New-Object System.Collections.Queue; foreach ($e in $a) { $q.Enqueue($e) }
    $r = [pscustomobject]@{ Q = $q }
    $r | Add-Member -MemberType ScriptMethod -Name ReadEvent -Value { if ($this.Q.Count -gt 0) { $this.Q.Dequeue() } else { $null } }
    $r
}
function global:New-Object {
    param([string]$TypeName, [object[]]$ArgumentList)
    if ($TypeName -like '*EventLogQuery') { return [pscustomobject]@{ Log = [string]$ArgumentList[0]; Q = [string]$ArgumentList[2]; ReverseDirection = $false } }
    if ($TypeName -like '*EventLogReader') {
        $a = $ArgumentList[0]; $rv = [bool]$a.ReverseDirection
        if ($a.Log -eq 'Application') {
            # probe mode: the oldest-record probe is refused while the query itself would quietly return
            # nothing - the Get-WinEvent -FilterHashtable shape the probe exists to catch.
            # query mode: the probe works and the real query is refused.
            if (($env:PT149_MODE -eq 'probe' -and $a.Q -eq '*') -or ($env:PT149_MODE -eq 'query' -and $a.Q -ne '*')) { throw [System.UnauthorizedAccessException]::new('test 149: access denied') }
            if ($a.Q -eq '*') { return (PTRd @((PTEv 'Application Error' 1000 2 60 ''), (PTEv 'Application Error' 1000 2 1 '')) $rv) }
            return (PTRd @((PTEv 'Application Error' 1000 2 3 '<EventData><Data Name=''AppName''>a.exe</Data><Data Name=''ModuleName''>m.dll</Data><Data Name=''ExceptionCode''>c0000005</Data></EventData>')) $rv)
        }
        if ($a.Q -eq '*') { return (PTRd @((PTEv 'Microsoft-Windows-Eventlog' 104 4 45 ''), (PTEv 'Microsoft-Windows-Kernel-Power' 41 1 1 '')) $rv) }
        if ($a.Q -like '*EventID=104*') { return (PTRd @(PTEv 'Microsoft-Windows-Eventlog' 104 4 45 '<UserData><LogFileCleared xmlns=''http://manifests.microsoft.com/win/2004/08/windows/eventlog''><Channel>System</Channel></LogFileCleared></UserData>') $rv) }
        if ($a.Q -like '*Kernel-Power*') {
            if ($env:PT149_MODE -eq 'cap') {
                return (PTRd @((PTEv 'Microsoft-Windows-WHEA-Logger' 17 3 10.5 ''), (PTEv 'Microsoft-Windows-WHEA-Logger' 17 3 8.5 ''), (PTEv 'Microsoft-Windows-WHEA-Logger' 17 3 6.5 ''), (PTEv 'Microsoft-Windows-WHEA-Logger' 17 3 4.5 ''), (PTEv 'Microsoft-Windows-WHEA-Logger' 17 3 2.5 '')) $rv)
            }
            return (PTRd @(
                (PTEv 'Service Control Manager' 7045 4 5 '<EventData><Data Name=''ServiceName''>Svc&amp;Name!%x</Data><Data Name=''ImagePath''>"C:\Program Files\Vpn\svc.exe" tunnel "PrivateKey = SECRETPT149"</Data><Data Name=''ServiceType''>localized text</Data></EventData>'),
                (PTEv 'Service Control Manager' 7045 4 5 '<EventData><Data Name=''ServiceName''>FakeDrv</Data><Data Name=''ImagePath''>\SystemRoot\System32\drivers\fakedrv.sys</Data></EventData>'),
                (PTEv 'Display' 4101 3 4 '<EventData><Data>nvlddmkm</Data><Data></Data></EventData>'),
                (PTEv 'disk' 153 3 4 '<EventData><Data>\Device\Harddisk1\DR1</Data><Data>0x10</Data></EventData>'),
                (PTEv 'Microsoft-Windows-WHEA-Logger' 29 3 3.4 '<EventData><Data Name=''ErrorSource''>1</Data></EventData>'),
                (PTEv 'Microsoft-Windows-WHEA-Logger' 19 3 3.3 ''),
                (PTEv 'Microsoft-Windows-WHEA-Logger' 17 3 3.2 ''),
                (PTEv 'Microsoft-Windows-WHEA-Logger' 99 2 3.1 ''),
                (PTEv 'Microsoft-Windows-Kernel-Power' 41 1 3 '<EventData><Data Name=''BugcheckCode''>292</Data><Data Name=''PowerButtonTimestamp''>0</Data></EventData>'),
                (PTEv 'Microsoft-Windows-WER-SystemErrorReporting' 1001 2 3 '<EventData><Data Name=''param1''>0x0000009f (0x0000000000000003, 0xffff)</Data><Data Name=''param2''>C:\Windows\Minidump\x.dmp</Data></EventData>')) $rv)
        }
        return (PTRd @() $rv)
    }
    if ($null -ne $ArgumentList) { Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList } else { Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName }
}
'@
    $collect = {
        param([string]$Mode, [string]$Code)
        if (Test-Path -LiteralPath $csv) { Remove-Item -LiteralPath $csv -Force }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prelude + "`n" + $Code))
        $psi.EnvironmentVariables['PT_CR_OUT'] = $csv; $psi.EnvironmentVariables['PT_CR_BAK'] = $bak; $psi.EnvironmentVariables['PT_CR_DAYS'] = '30'
        $psi.EnvironmentVariables['PT149_MODE'] = $Mode
        $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close(); $err = $p.StandardError.ReadToEndAsync(); $null = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'test 149: the collector did not finish within 60 s.' }
        Assert-True ($p.ExitCode -ne 149) ('The collector tried to change the system: ' + $err.Result.Trim())
        Assert-True ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $csv)) ('The collector wrote no events file (exit {0}, mode {1}).' -f $p.ExitCode, $Mode)
        $rows = @(Import-Csv -LiteralPath $csv)
        $L = @{}; foreach ($r in @($rows | Where-Object { $_.K -eq 'L' })) { $L[$r.Log] = $r }
        [pscustomobject]@{ Text = [IO.File]::ReadAllText($csv); Rows = $rows; L = $L; W = @($rows | Where-Object { $_.K -eq 'W' }) }
    }
    try {
        # refused mid-read: the probe works, the real query throws - the path the "$A overwrote $a" XPath bug took
        $q = & $collect 'query' $raw
        Assert-True ($q.L['Application'].A -eq 'denied') ('Application refused AFTER a good probe must still come out as "denied", never as a log with no events. Got: ' + $q.L['Application'].A)
        Assert-True (@($q.Rows | Where-Object { $_.Log -eq 'Application' -and $_.K -eq 'E' }).Count -eq 0) 'Application events were written although the query failed.'
        # refused at the probe
        $c = & $collect 'probe' $raw
        $text = $c.Text; $rows = $c.Rows; $L = $c.L
        Assert-True ($L['System'].A -eq 'ok' -and $L['System'].B -eq '30' -and $L['System'].C -ne '') ('System: a readable log whose OLDEST record is older than the window must cover all 30 days (the probe reads forward), and its last clear must be recorded. Got: ' + $L['System'].A + ' ' + $L['System'].B)
        Assert-True ($L['Application'].A -eq 'denied') ('Application: UnauthorizedAccessException at the probe must come out as "denied", never as a log with no events. Got: ' + $L['Application'].A)
        Assert-True ($c.W.Count -eq 1 -and $c.W[0].C -eq '0') 'The W row must say the read was not capped (C = 0).'
        $kp = @($rows | Where-Object { $_.Id -eq '41' })
        Assert-True ($kp.Count -eq 1 -and $kp[0].A -eq '0x00000124' -and $kp[0].C -eq 'WHEA_UNCORRECTABLE_ERROR') 'Kernel-Power 41: BugcheckCode 292 (decimal, read by field name) must become 0x00000124, named WHEA_UNCORRECTABLE_ERROR.'
        $we = @($rows | Where-Object { $_.Id -eq '1001' })
        Assert-True ($we.Count -eq 1 -and $we[0].A -eq '0x0000009F' -and $we[0].C -eq 'DRIVER_POWER_STATE_FAILURE') 'WER 1001: param1 must yield 0x0000009F, named DRIVER_POWER_STATE_FAILURE.'
        Assert-True (@($rows | Where-Object { $_.Id -eq '4101' })[0].A -eq 'nvlddmkm' -and @($rows | Where-Object { $_.Id -eq '153' })[0].A -eq 'Harddisk1') 'Classic providers: the display driver name and the disk token are not extracted.'
        $wh = @{}; foreach ($x in @($rows | Where-Object { $_.Prov -eq 'Microsoft-Windows-WHEA-Logger' })) { $wh[$x.Id] = $x.A + '/' + $x.B }
        Assert-True ($wh['29'] -eq 'uncorrected/cpu' -and $wh['19'] -eq 'corrected/cpu' -and $wh['17'] -eq 'corrected/' -and $wh['99'] -eq 'uncorrected/') ('WHEA: 29 (fatal, logged at level 3) must be uncorrected, 19 corrected, both Processor Core; 17 corrected PCIe; an unknown id uncorrected (fail closed). Got: ' + (($wh.Keys | Sort-Object | ForEach-Object { $_ + '=' + $wh[$_] }) -join ' '))
        $svc = @($rows | Where-Object { $_.Id -eq '7045' })
        Assert-True (@($svc | Where-Object { $_.A -eq 'Svc?Name??x' -and $_.B -eq 'service' }).Count -eq 1 -and @($svc | Where-Object { $_.A -eq 'FakeDrv' -and $_.B -eq 'driver' }).Count -eq 1) 'SCM 7045: service names must be sanitized (no & ! %) and a .sys image must read as a driver.'
        Assert-True ($text -notmatch 'SECRETPT149|Program Files|Minidump|localized') 'An image path, a dump path or localized field text leaked into the events file - it ends up in a saved report.'
        $ses = @($rows | Where-Object { $_.K -eq 'S' })
        Assert-True ($ses.Count -eq 1 -and $ses[0].A -eq '4') ('sincript sessions: only the one inside the window, with the 4 undo files it wrote - a FullReg_* export, a stray .bat and a saved report are not undo files. Got: ' + (($ses | ForEach-Object { $_.A }) -join ','))
        Assert-True ($text -notmatch '[^\x09\x0a\x0d\x20-\x7e]') 'The events file is not plain ASCII.'

        # the cap, cut to 3: newest first, days covered shrink to what was read, the Application log gets nothing
        $k = & $collect 'cap' $raw3
        $se = @($k.Rows | Where-Object { $_.K -eq 'E' -and $_.Log -eq 'System' })
        $ages = @($se | ForEach-Object { ((Get-Date) - [datetime]::ParseExact($_.T, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)).TotalDays } | Sort-Object)
        Assert-True ($se.Count -eq 3 -and $ages[0] -lt 3 -and $ages[2] -lt 7) ('At the cap the collector must keep the NEWEST three events (read newest first); ages kept: ' + (($ages | ForEach-Object { '{0:N1}' -f $_ }) -join ', '))
        Assert-True ($k.L['System'].A -eq 'capped' -and $k.L['System'].B -eq '6') ('A capped System log must say so and cover only the 6 whole days it read. Got: ' + $k.L['System'].A + ' ' + $k.L['System'].B)
        Assert-True ($k.L['Application'].A -eq 'capped' -and $k.L['Application'].B -eq '0' -and @($k.Rows | Where-Object { $_.K -eq 'E' -and $_.Log -eq 'Application' }).Count -eq 0) 'The shared cap was already reached: the Application log must read as capped with 0 days covered, not as a full read.'
        Assert-True ($k.W.Count -eq 1 -and $k.W[0].C -eq '3') 'The W row must carry the cap value, for the summary and the final line to print.'
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
}

# ===============================================================================
# 150. Two PowerShell name traps, checked in all three workers. An ALIAS runs
#      instead of a function of the same name (about_Command_Precedence): the first
#      draft's helper "R" was Invoke-History, so the collector wrote an empty file,
#      and "Rd" was Remove-Item. And variable names are case-insensitive: "$A" (an
#      event field) overwrote "$a" (the apostrophe every XPath was built with), so
#      the Application query broke and read as "error". Both were measured.
# ===============================================================================
Invoke-Test 'Crash report workers: no helper named like an alias, no two variables differing only by case' {
    $cmd = Read-Lines $CmdPath
    $n = 0
    foreach ($key in 'PT_CR_OUT', 'PT_CR_SUM', 'PT_CR_LT') {
        $line = @($cmd | Where-Object { $_.TrimStart() -notmatch '^(?i)rem\b' -and $_.Contains('-Command "') -and $_.Contains('$env:' + $key) })
        Assert-True ($line.Count -eq 1) "Expected one worker line using `$env:$key, found $($line.Count)."
        $raw = [regex]::Match($line[0], '-Command "(.*)"\s*$').Groups[1].Value
        $fn = @([regex]::Matches($raw, '(?i)\bfunction\s+([A-Za-z_][\w-]*)') | ForEach-Object { $_.Groups[1].Value })
        Assert-True ($fn.Count -ge 3) "The $key worker defines only $($fn.Count) helper(s) - the scan is not seeing them."
        $hit = @($fn | Where-Object { Get-Alias -Name $_ -ErrorAction SilentlyContinue })
        Assert-True ($hit.Count -eq 0) ("The $key worker names helper(s) like a PowerShell alias, and the alias runs instead: " + (($hit | ForEach-Object { $_ + ' -> ' + (Get-Alias -Name $_).Definition }) -join ', ') + '. Prefix helpers with x.')
        $vars = @([regex]::Matches($raw, '\$([A-Za-z_]\w*)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(?i)(env|true|false|null|_)$' })
        Assert-True ($vars.Count -ge 20) "Only $($vars.Count) variable reads found in the $key worker - the scan is not seeing them."
        $col = @($vars | Sort-Object -Unique -CaseSensitive | Group-Object { $_.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group -join '/' })
        Assert-True ($col.Count -eq 0) ("The $key worker uses variables that differ only by case - PowerShell names are case-insensitive, so one overwrites the other: " + ($col -join ', '))
        $n++
    }
    Assert-True ($n -eq 3) 'Not all three crash report workers were checked.'
}

# ===============================================================================
# 151. The batch side of the report stays honest, checked in the text AND run.
#      :_crVerdict, :CrashHints, :_crWrite and :_crHintsFile only echo and
#      redirect, so they are copied into a driver and RUN in a contained cmd. The
#      final line is [FAIL] for an unreadable System log and, in its own words,
#      for an unreadable Application log (which never reaches the "not all days"
#      text); [WARN] for a capped read and, separately, for a short one; [OK] only
#      for a full read. Every hint prints on its own evidence and on nothing else
#      - a goto retargeted to the wrong label shows up as a missing or extra hint -
#      and the undervolt hint needs BOTH a found tool and a machine-check count.
#      The saved report carries the final line. A hints file that cannot be
#      written is caught one call level down (pitfall 44: nothing on stderr) and
#      flagged, never shown as "No hints". Also: no worker output is [FAIL], not
#      an empty screen; TdrDelay / TdrLevel appear in echo text only; the stat
#      reader takes whitelisted keys only; a save is verified before [OK];
#      Cleanup's clear-all-logs prompt says it erases this history; and every
#      printed line fits 96 columns with the longest values.
# ===============================================================================
Invoke-Test 'Crash report verdict and hints: [FAIL]/[WARN] before [OK], each hint on its own evidence (run)' {
    $cmd = Read-Lines $CmdPath
    $v = @(Get-BodyLines -Lines $cmd -Label '_crVerdict' -CodeOnly)
    Assert-True ($v.Count -gt 10) ':_crVerdict is missing or did not unroll.'
    $vj = $v -join "`n"
    $order = @('if /i "!_cr_sys!"=="fail" goto _crvFail', 'if /i "!_cr_app!"=="fail" goto _crvAppFail', 'if not "!_cr_capped!"=="0" goto _crvCap', 'if /i not "!_cr_sys!"=="ok" goto _crvShort', 'if /i not "!_cr_app!"=="ok" goto _crvShort', 'echo  [OK]')
    $at = @($order | ForEach-Object { $vj.IndexOf($_) })
    Assert-True (@($at | Where-Object { $_ -lt 0 }).Count -eq 0) (':_crVerdict lost a check: ' + (@(for ($i = 0; $i -lt $order.Count; $i++) { if ($at[$i] -lt 0) { $order[$i] } }) -join ' | '))
    for ($i = 1; $i -lt $at.Count; $i++) { Assert-True ($at[$i] -gt $at[$i - 1]) (':_crVerdict checks "{0}" before "{1}" - [FAIL] must come first, then the cap, then coverage, then [OK].' -f $order[$i], $order[$i - 1]) }
    foreach ($b in 'Fail', 'AppFail', 'Cap', 'Short') { Assert-True ($vj -match ('(?m)^:_crv' + $b + '\s*\n\s*echo\s+\[(FAIL|WARN)\]')) ":_crVerdict lost its _crv$b branch." }
    $show = @(Get-BodyLines -Lines $cmd -Label 'CrashReport_show' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($show -contains 'call :_crVerdict') ':CrashReport_show no longer prints the final line.'
    $wr = @(Get-BodyLines -Lines $cmd -Label '_crWrite' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($wr -contains '>>"!_crout!" (call :_crVerdict)') ':_crWrite no longer files the final line - a saved report of a failed read would not say so.'

    $cr = @(Get-BodyLines -Lines $cmd -Label 'CrashReport' -CodeOnly | ForEach-Object { $_.Trim() })
    foreach ($g in 'if not exist "!_crcsv!" goto _crNoRead', 'if not exist "!_crsum!" goto _crNoRead', 'if not defined _cr_sys goto _crNoRead') {
        Assert-True ($cr -contains $g) (":CrashReport lost its guard '$g' - a worker that wrote nothing would show an empty report instead of [FAIL].")
    }
    $hseq = @('set "_crnh=0"', 'set "_crhbad="', 'call :_crHintsFile 2>nul', 'if not exist "!_crhnt!" set "_crhbad=1"')
    $hi = @($hseq | ForEach-Object { [Array]::IndexOf($cr, $_) })
    Assert-True (@($hi | Where-Object { $_ -lt 0 }).Count -eq 0 -and $hi[1] -gt $hi[0] -and $hi[2] -gt $hi[1] -and $hi[3] -eq $hi[2] + 1) ':CrashReport no longer writes the hints one call level down and flags a hints file that did not land.'
    $hf = @(Get-BodyLines -Lines $cmd -Label '_crHintsFile' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($hf -contains '>"!_crhnt!" (call :CrashHints)') ':_crHintsFile no longer holds the hints redirect.'
    $ask = @(Get-BodyLines -Lines $cmd -Label 'CrashReport_ask' -CodeOnly)
    $askj = $ask -join "`n"
    Assert-True ($askj -match '(?m)^:_crNoRead[\s\S]*?echo\s+\[FAIL\][\s\S]*?NOT a clean') 'The no-output path no longer prints [FAIL] and says it is not a clean bill of health.'
    Assert-True (@($ask | Where-Object { $_ -match 'No hints:' -and $_ -notmatch '^if not defined _crhbad if "!_crnh!"=="0" echo' }).Count -eq 0 -and @($ask | Where-Object { $_ -match 'No hints:' }).Count -eq 1) 'The H page can say "No hints" when the hints file was never written.'

    $h = @(Get-BodyLines -Lines $cmd -Label 'CrashHints' -CodeOnly)
    Assert-True ($h.Count -gt 30) ':CrashHints is missing or did not unroll.'
    # every gate's goto lands after its own hint and before the next gate
    $gl = @(for ($i = 0; $i -lt $h.Count; $i++) { if ($h[$i] -match '^if (not defined \w+|"!_cr_\w+!"=="0") goto (\S+)\s*$') { ,@($i, $Matches[2]) } })
    Assert-True ($gl.Count -eq 11) "Expected 11 hint gates in :CrashHints (10 hints, the undervolt one with two), found $($gl.Count)."
    for ($i = 0; $i -lt $gl.Count; $i++) {
        $gi = $gl[$i][0]; $tg = $gl[$i][1]
        $li = if ($tg -eq ':eof') { $h.Count } else { [Array]::IndexOf($h, ':' + $tg) }
        $ni = if ($i + 1 -lt $gl.Count) { $gl[$i + 1][0] } else { $h.Count }
        if ($i + 1 -lt $gl.Count -and $gl[$i + 1][0] -eq $gi + 1) { $ni = $h.Count; for ($k = $i + 2; $k -lt $gl.Count; $k++) { $ni = $gl[$k][0]; break } }
        $txt = @($h[($gi + 1)..([Math]::Max($gi + 1, $li - 1))] | Where-Object { $_ -match '^echo\s+\[i\]' })
        Assert-True ($li -gt $gi -and $txt.Count -eq 1 -and ($li -le $ni -or $ni -eq $h.Count)) ("The :CrashHints gate '{0}' jumps to {1}, which does not skip exactly its own hint - a hint would print on another hint's evidence." -f $h[$gi].Trim(), $tg)
    }
    Assert-True (@($h | Where-Object { $_ -match '(?i)\bTdr(Delay|Level)\b' -and $_.Trim() -notmatch '^(?i)echo\b' }).Count -eq 0) 'TdrDelay / TdrLevel appear outside echo text in :CrashHints.'
    Assert-True ([regex]::Matches(($h -join "`n"), 'set /a _crnh\+=1').Count -eq 10) ':CrashHints no longer counts each of its 10 hints.'

    $rs = @(Get-BodyLines -Lines $cmd -Label '_crReadStat' -CodeOnly) -join "`n"
    Assert-True ($rs.Contains('for %%K in (!_crkeys!) do if /i "%%a"=="%%K" set "_cr_%%K=%%b"')) ':_crReadStat no longer restricts KEY=VALUE lines to its whitelist.'

    $iw = $askj.IndexOf('call :_crWrite 2>nul'); $ic = $askj.IndexOf('if not exist "!_crout!" goto _crSaveFail'); $io = $askj.IndexOf('echo  [OK] Saved:')
    Assert-True ($iw -ge 0 -and $ic -gt $iw -and $io -gt $ic) 'The saved report is claimed before it is checked to exist.'
    Assert-True ($askj.Contains('for /f "eol=_ delims=0123456789_" %%X in ("!_cr_stamp!") do set "_crbad=1"')) 'The file-name stamp from the worker is no longer checked before it becomes part of a path.'

    $cl = @(Get-BodyLines -Lines $cmd -Label 'Cleanup')
    $pi = -1; for ($i = 0; $i -lt $cl.Count; $i++) { if ($cl[$i] -match 'set /p "_ev=') { $pi = $i; break } }
    Assert-True ($pi -gt 0 -and $cl[$pi - 1] -match '(?i)^\s*echo\s+Clearing the event logs\b.*crash.*report') 'Cleanup''s clear-all-event-logs prompt no longer says, before it asks, that clearing the logs erases the history the crash report reads.'

    $s = [Array]::IndexOf($cmd, ':CrashReport'); $e = [Array]::IndexOf($cmd, ':CrashCollect')
    Assert-True ($s -gt 0 -and $e -gt $s) 'The crash report section could not be sliced for the width check.'
    $worst = @{ '!_cr_drv!' = 40; '!_cr_drvdate!' = 10; '!_cr_sin!' = 10; '!UVTOOL!' = 44; '!_cr_days!' = 3; '!_crnh!' = 2; '!_cr_gen!' = 16; '!_cr_capped!' = 6 }
    $wide = @(); $seen = 0
    foreach ($l in $cmd[$s..$e]) {
        $t = $l.Trim()
        if ($t -notmatch '^(?i)(if .*? )?(>>?\s*"[^"]*"\s*)?echo[ .]') { continue }
        $r = [regex]::Replace($t.Substring($t.IndexOf('echo') + 5), '\^(.)', '$1')
        if ($r -match '^[=-]{10}' -or $r.Contains('!_crout!') -or $r.Contains('!BACKUP_DIR!')) { continue }
        foreach ($k in $worst.Keys) { $r = $r.Replace($k, ('x' * $worst[$k])) }
        $seen++
        if ($r.Length -gt 96) { $wide += ('{0} cols: {1}' -f $r.Length, $t.Substring(0, [Math]::Min(60, $t.Length))) }
    }
    Assert-True ($seen -ge 40) "Only $seen echo lines were measured - the scan is not seeing them."
    Assert-True ($wide.Count -eq 0) ('Crash report line(s) wider than 96 columns with the longest values filled in: ' + ($wide -join ' | '))

    # ---- RUN the four routines in a contained cmd (they only echo, set and redirect)
    $rt = [ordered]@{ '_crVerdict' = @(Get-BodyLines -Lines $cmd -Label '_crVerdict'); 'CrashHints' = @(Get-BodyLines -Lines $cmd -Label 'CrashHints'); '_crWrite' = @(Get-BodyLines -Lines $cmd -Label '_crWrite'); '_crHintsFile' = @(Get-BodyLines -Lines $cmd -Label '_crHintsFile') }
    $all = @($rt.Values | ForEach-Object { $_ })
    $calls = @([regex]::Matches(($all -join "`n"), '(?i)\bcall\s+:(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True (@($calls | Where-Object { -not $rt.Contains($_) }).Count -eq 0) ('The report routines now call {0} - add it to this test''s driver.' -f ($calls -join ', '))
    $live = @($all | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)\bpowershell\b|\breg(\.exe)?\s|\bstart\s+"|\bdel\s|\bwevtutil\b|\bsc\s' })
    Assert-True ($live.Count -eq 0) ('test 151: the report routines now start or delete something - refusing to run them: ' + ($live -join ' | '))
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $tmp = [IO.Path]::GetTempPath()
    if ($tmp -match '%') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT151_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Assert-True ($dir -notmatch '[%!]') ('test 151 cannot run here: the temp folder path holds a "%" or "!" ({0}).' -f $dir)
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $zero = 'set "_cr_hw=0" & set "_cr_mce=0" & set "_cr_nocode=0" & set "_cr_vm46=0" & set "_cr_disk=0" & set "_cr_ntfs=0" & set "_cr_rex=0" & set "_cr_tdr=0" & set "_cr_drv=" & set "_cr_drvdate=" & set "_cr_sin=" & set "UVTOOL="'
        $hint = [ordered]@{ hw = 'Uncorrected hardware error or bugcheck 0x124'; uv = 'Undervolt tool found: Intel XTU'; nocode = 'Restart with no bugcheck code'; vm46 = 'volmgr 46:'; disk = 'Disk retries, resets or bad blocks'; ntfs = 'NTFS reported corruption'; rex = 'Low virtual memory:'; tdr = 'Display driver resets (TDR)'; drv = 'A driver was installed'; sin = 'sincript made changes on 2026-01-19' }
        $hcase = [ordered]@{
            'none'    = @('', @())
            'hw'      = @('set "_cr_hw=1"', @('hw'))
            'uvtool'  = @('set "UVTOOL=Intel XTU"', @())
            'uvmce'   = @('set "_cr_mce=4"', @())
            'uv'      = @('set "UVTOOL=Intel XTU" & set "_cr_mce=1"', @('uv'))
            'nocode'  = @('set "_cr_nocode=2"', @('nocode'))
            'vm46'    = @('set "_cr_vm46=1"', @('vm46'))
            'disk'    = @('set "_cr_disk=3"', @('disk'))
            'ntfs'    = @('set "_cr_ntfs=1"', @('ntfs'))
            'rex'     = @('set "_cr_rex=1"', @('rex'))
            'tdr'     = @('set "_cr_tdr=1"', @('tdr'))
            'drv'     = @('set "_cr_drv=SomeDrv" & set "_cr_drvdate=2026-01-18"', @('drv'))
            'sin'     = @('set "_cr_sin=2026-01-19"', @('sin'))
            'all'     = @('set "_cr_hw=1" & set "_cr_mce=1" & set "UVTOOL=Intel XTU" & set "_cr_nocode=1" & set "_cr_vm46=1" & set "_cr_disk=1" & set "_cr_ntfs=1" & set "_cr_rex=1" & set "_cr_tdr=1" & set "_cr_drv=SomeDrv" & set "_cr_drvdate=2026-01-18" & set "_cr_sin=2026-01-19"', @($hint.Keys))
        }
        $vcase = [ordered]@{
            'sysfail'      = @('fail', 'ok', '0', ' [FAIL] The System log could not be read')
            'bothfail'     = @('fail', 'fail', '0', ' [FAIL] The System log could not be read')
            'appfail'      = @('ok', 'fail', '0', ' [FAIL] The Application log could not be read')
            'appfailshort' = @('short', 'fail', '0', ' [FAIL] The Application log could not be read')
            'appfailcap'   = @('short', 'fail', '30000', ' [FAIL] The Application log could not be read')
            'cap'          = @('short', 'short', '30000', ' [WARN] Reading stopped at 30000 matching events')
            'syshort'      = @('short', 'ok', '0', ' [WARN] Read, but not all 30 days of both logs')
            'appshort'     = @('ok', 'short', '0', ' [WARN] Read, but not all 30 days of both logs')
            'ok'           = @('ok', 'ok', '0', ' [OK] Both logs were read and cover the full 30 days.')
        }
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        foreach ($k in $hcase.Keys) { $drv += @(('echo ###H ' + $k), $zero, $hcase[$k][0], 'set "_crnh=0"', 'call :CrashHints', 'echo ###NH !_crnh!') }
        foreach ($k in $vcase.Keys) { $drv += @(('echo ###V ' + $k), ('set "_cr_sys={0}" & set "_cr_app={1}" & set "_cr_capped={2}" & set "_cr_days=30"' -f $vcase[$k][0], $vcase[$k][1], $vcase[$k][2]), 'call :_crVerdict') }
        # the saved report files the final line; a hints file that cannot be opened is caught quietly and flagged
        $drv += @('echo ###W', 'set "_crsum=!PT_T_DIR!\sum.txt" & set "_crtl=!PT_T_DIR!\tl.txt" & set "_crout=!PT_T_DIR!\out.txt" & set "_cr_gen=2026-01-31 12:00"',
            '>"!_crsum!" echo SUMMARY-LINE', '>"!_crtl!" echo TIMELINE-LINE',
            'set "_cr_sys=fail" & set "_cr_app=ok" & set "_cr_capped=0" & set "_crhnt=!PT_T_DIR!\nodir\h.txt" & set "_crhbad="',
            $zero, 'set "_cr_tdr=1" & set "_crnh=0"', 'call :_crHintsFile 2>nul', 'if not exist "!_crhnt!" set "_crhbad=1"', 'echo ###HB [!_crhbad!] [!_crnh!]',
            'call :_crWrite 2>nul', 'set "_crhnt=!PT_T_DIR!\h.txt" & set "_crhbad=" & set "_crnh=0"', 'call :_crHintsFile 2>nul', 'if not exist "!_crhnt!" set "_crhbad=1"', 'echo ###HG [!_crhbad!] [!_crnh!]', 'exit /b 0')
        foreach ($k in $rt.Keys) { $drv += @((':' + $k)) + $rt[$k] }
        $drvPath = Join-Path $dir 'drv.cmd'
        [IO.File]::WriteAllText($drvPath, (($drv -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmdExe; $psi.Arguments = '/d /s /c ""' + $drvPath + '""'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PT_T_DIR'] = $dir
        $p = [System.Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'test 151: the driver did not end within 30 s.' }
        Assert-True ($err.Result.Trim() -eq '') ('The report routines wrote to stderr - a hints file that cannot be opened must be caught one call level down (pitfall 44): ' + $err.Result.Trim())
        $o = @($out.Result -split "`r?`n")
        $blocks = @{}; $cur = $null
        foreach ($l in $o) { if ($l -match '^###(H|V|W)\s*(\S*)') { $cur = $Matches[1] + ':' + $Matches[2]; $blocks[$cur] = New-Object System.Collections.Generic.List[string]; continue }; if ($null -ne $cur) { $blocks[$cur].Add($l) } }
        foreach ($k in $hcase.Keys) {
            $b = $blocks['H:' + $k]
            Assert-True ($null -ne $b) "test 151: the driver printed nothing for hint case '$k'."
            $got = @($b | Where-Object { $_ -match '^  \[i\] ' })
            $want = @($hcase[$k][1])
            $nh = @($b | Where-Object { $_ -match '^###NH' })
            foreach ($w in $want) { Assert-True (@($got | Where-Object { $_.Contains($hint[$w]) }).Count -eq 1) ("Hint case '{0}': the {1} hint did not print on its own evidence. Printed: {2}" -f $k, $w, ($got -join ' | ')) }
            Assert-True ($got.Count -eq $want.Count) ("Hint case '{0}': {1} hint(s) printed where {2} belong - a hint printed without its evidence: {3}" -f $k, $got.Count, $want.Count, ($got -join ' | '))
        }
        $nhl = @($o | Where-Object { $_ -match '^###NH (\d+)$' } | ForEach-Object { [int]($_ -replace '^###NH ', '') })
        Assert-True ($nhl.Count -eq $hcase.Count -and $nhl[0] -eq 0 -and $nhl[$nhl.Count - 1] -eq 10) ('The hint counter _crnh does not match the hints printed: ' + ($nhl -join ','))
        foreach ($k in $vcase.Keys) {
            $b = @($blocks['V:' + $k])
            $tags = @($b | Where-Object { $_ -match '^ \[(OK|WARN|FAIL)\]' })
            Assert-True ($tags.Count -eq 1 -and $tags[0].StartsWith($vcase[$k][3])) ("Verdict case '{0}' (sys={1} app={2} capped={3}) should print exactly one final line starting '{4}'. Got: {5}" -f $k, $vcase[$k][0], $vcase[$k][1], $vcase[$k][2], $vcase[$k][3].Trim(), ($tags -join ' | '))
        }
        Assert-True (@($blocks['V:appfailshort'] | Where-Object { $_ -match '(?i)none found|not all 30 days' }).Count -eq 0 -and @($blocks['V:appfailcap'] | Where-Object { $_ -match '(?i)none found|not all 30 days|Reading stopped' }).Count -eq 0) 'An unreadable Application log reached the "not all days" or cap text - it was not read at all.'
        Assert-True (@($o | Where-Object { $_ -eq '###HB [1] [0]' }).Count -eq 1) ('A hints file that cannot be opened must leave _crhbad set (and no hint counted: the redirected block never ran). Got: ' + (@($o | Where-Object { $_ -like '###HB*' }) -join ' '))
        Assert-True (@($o | Where-Object { $_ -eq '###HG [] [1]' }).Count -eq 1 -and ([IO.File]::ReadAllText((Join-Path $dir 'h.txt'))).Contains('Display driver resets (TDR)')) 'A hints file that can be written must land with its hint, and not be flagged.'
        $saved = [IO.File]::ReadAllText((Join-Path $dir 'out.txt'))
        Assert-True ($saved.Contains('SUMMARY-LINE') -and $saved.Contains('TIMELINE-LINE') -and $saved.Contains(' [FAIL] The System log could not be read')) 'The saved report does not carry the final [FAIL] line - a saved report of a failed read would look clean.'
        Assert-True ($saved.Contains('[WARN] The hints could not be prepared')) 'The saved report does not say its hints could not be prepared.'
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# ===============================================================================
# 152. The refresh rate on the main-menu header never makes the menu wait. Starting
#      PowerShell alone took about 2 s on the reference laptop, so the first draw
#      starts one worker in the background and every draw after that only looks for
#      its answer (:DetectRefresh). The worker reads WinRT's DisplayManager, which gives
#      each display's exact rate - not Win32_VideoController (one value per adapter,
#      truncated 143.998 Hz to 143 there) and not a C# shim (Add-Type compiles on every
#      launch). The path reaches it through the environment, the answer comes back in a
#      file, and nothing is cached across sessions: a refresh rate is a setting.
# ===============================================================================
Invoke-Test 'The refresh-rate header never makes the menu wait, reads DisplayManager and keeps no cache' {
    $cmd = Read-Lines $CmdPath
    $hdr = 'echo   Build %WIN_BUILD%   Win11=%IS_WIN11%   CPU=%CPU%   GPU=%GPU%   Disk=%SYSDISK%   Refresh=!REFRESH!'
    foreach ($r in 'MainMenu', 'Status') {
        $b = @(Get-BodyLines -Lines $cmd -Label $r -CodeOnly)
        Assert-True ($b.Count -gt 10) ":$r body did not unroll."
        $j = $b -join "`n"
        $iCall = $j.IndexOf('call :DetectRefresh'); $iShow = $j.IndexOf($hdr)
        Assert-True ($iShow -ge 0) ":$r header no longer shows Refresh=!REFRESH! after Disk= (regression)."
        Assert-True ($iCall -ge 0 -and $iCall -lt $iShow) ":$r prints Refresh= without collecting it first (regression)."
        Assert-True ($j -notmatch '(?i)call :ProbeRefresh') ":$r starts the refresh worker itself instead of collecting the session's one measurement (regression)."
        if ($r -eq 'MainMenu') { Assert-True ($j -notmatch '(?i)\bpowershell\b|/wait') ':MainMenu starts or waits for a process - it runs on every draw (regression).' }
    }
    $dr = @(Get-BodyLines -Lines $cmd -Label 'DetectRefresh' -CodeOnly)
    Assert-True ($dr.Count -gt 5) ':DetectRefresh body did not unroll.'
    $drj = $dr -join "`n"
    Assert-True ($drj -match '(?m)^if not defined HZSTATE call :ProbeRefresh\s*$') ':DetectRefresh no longer starts the worker once, on first use (regression).'
    Assert-True ($drj -match '(?m)^if exist "!_hzres!" goto _hzCollect\s*$') ':DetectRefresh no longer just looks for the answer file (regression).'
    Assert-True ($drj -notmatch '(?i)\bpowershell\b|/wait|\bstart\b') ':DetectRefresh starts or waits for a process in the draw path (regression).'
    Assert-True ($drj -match '(?m)^set "_hzlim=10"\s*$' -and $drj -match '(?m)^if exist "!_hzres!\.run" set "_hzlim=30"\s*$') ':DetectRefresh no longer gives up on a worker that never started, or gives a started one too little time (regression).'
    $pr = @(Get-BodyLines -Lines $cmd -Label 'ProbeRefresh' -CodeOnly)
    Assert-True ($pr.Count -gt 8) ':ProbeRefresh body did not unroll.'
    $starts = @($pr | Where-Object { $_ -match '^\s*start\s' })
    Assert-True ($starts.Count -eq 1) ("':ProbeRefresh has {0} worker lines, not one." -f $starts.Count)
    $w = $starts[0]
    Assert-True ($w -match '^start "" /min powershell -NoProfile -Command "') ':ProbeRefresh no longer starts its worker minimized and WITHOUT /wait (regression).'
    Assert-True (($pr -join "`n") -match '(?m)^set "PT_HZ_RES=!_hzres!"\s*$' -and ($pr -join "`n") -match '(?m)^set "PT_HZ_RES="\s*$') ':ProbeRefresh no longer hands the answer path over through the environment and clears it (regression).'
    $ps = $w.Substring($w.IndexOf('-Command "') + 10)
    Assert-True ($ps.EndsWith('"')) ':ProbeRefresh payload is not closed by the line''s last quote.'
    $ps = $ps.Substring(0, $ps.Length - 1)
    Assert-True ($ps.IndexOfAny([char[]]'!^%"') -lt 0) ':ProbeRefresh payload holds ! ^ % or a double quote - delayed expansion or the -Command quoting would change it (regression).'
    foreach ($need in 'Windows.Devices.Display.Core.DisplayManager', 'TryReadCurrentStateForAllTargets()', 'PresentationRate', 'VerticalSyncRate.Denominator -gt 0', 'GlassSessionId', "`$env:PT_HZ_RES", "(`$f+'.run')", "Move-Item -LiteralPath `$t -Destination `$f", "catch { `$o+='E' }", '$m.Dispose()') {
        Assert-True ($ps.Contains($need)) ":ProbeRefresh worker no longer contains $need (regression)."
    }
    foreach ($no in 'Add-Type', 'Win32_VideoController', 'Win32_DisplayConfiguration', 'Get-CimInstance', 'Get-WmiObject', 'wmic') {
        Assert-True (-not $ps.Contains($no)) ":ProbeRefresh worker uses $no - a compile on every launch, or a per-adapter / truncated / removed source (regression)."
    }
    $all = (@($pr) + $dr + @(Get-BodyLines -Lines $cmd -Label '_hzParse' -CodeOnly) + @(Get-BodyLines -Lines $cmd -Label '_hzRec' -CodeOnly)) -join "`n"
    Assert-True ($all -notmatch '(?i)LOCALAPPDATA|\.cache\b') 'The refresh-rate probe keeps an answer across sessions (regression).'
    $pa = @(Get-BodyLines -Lines $cmd -Label '_hzParse' -CodeOnly) -join "`n"
    Assert-True ($pa -match '(?m)^\s+if not defined _hzbad call :_hzRec\s*$') ':_hzParse hands a record to :_hzRec as call arguments - call parses text from a user-writable file a second time (regression).'
    Assert-True ($pa -match '(?m)^findstr /l /c:"\^!" "!_hzres!" >nul 2>&1\s*$') ':_hzParse no longer rejects an answer file holding "!" before reading it (regression).'
    $st = @(Get-BodyLines -Lines $cmd -Label 'Status' -CodeOnly) -join "`n"
    Assert-True ($st -match '(?m)^call :_hzShow\s*$') ':Status no longer shows the [Display] section (regression).'
    $sh = @(Get-BodyLines -Lines $cmd -Label '_hzShow') -join "`n"
    Assert-True ($sh -match 'Refresh rate  = !REFRESH_ALL!' -and $sh -match 'in the order Windows lists them' -and $sh -match 'Dynamic Refresh Rate can run a panel below it') ':_hzShow lost its value line or its honest caveats (regression).'
    $ex = @(Get-BodyLines -Lines $cmd -Label 'ExitScript' -CodeOnly) -join "`n"
    Assert-True ($ex -match '(?m)^if defined _hzres del "!_hzres!" "!_hzres!\.run" "!_hzres!\.tmp"') ':ExitScript no longer removes an answer the worker left in TEMP (regression).'
}

# ===============================================================================
# 153. The main-menu header fits the console at its widest. Each variable's widest
#      value is read from the script's own literal set lines, so a new GPU word is
#      covered the day it is added; REFRESH's 14 columns is what test 154 proves the
#      parser can produce, and WIN_BUILD is a five-digit build number.
# ===============================================================================
Invoke-Test 'The main-menu header fits the console at its widest' {
    $cmd = Read-Lines $CmdPath
    $width = 0
    foreach ($ln in $cmd) { $m = [regex]::Match($ln, '(?i)^\s*mode con:?\s*cols=(\d+)'); if ($m.Success) { $width = [int]$m.Groups[1].Value } }
    Assert-True ($width -gt 0) 'No "mode con cols=" line found.'
    $h = @(Get-BodyLines -Lines $cmd -Label 'MainMenu' -CodeOnly | Where-Object { $_ -match '^\s*echo   Build ' })
    Assert-True ($h.Count -eq 1) ("Expected one header line in :MainMenu, found {0}." -f $h.Count)
    $text = $h[0].TrimStart().Substring(5)
    $computed = @{ 'WIN_BUILD' = 5; 'REFRESH' = 14 }
    $vars = @([regex]::Matches($text, '[%!]([A-Za-z_]\w*)[%!]') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($vars.Count -ge 6) ("Only {0} variables found on the header - the scan is not seeing them." -f $vars.Count)
    $code = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem\b|::)' })
    $rendered = $text
    foreach ($v in $vars) {
        $max = 0
        foreach ($ln in $code) {
            foreach ($m in [regex]::Matches($ln, '(?i)\bset "' + [regex]::Escape($v) + '=([^"%!]*)"')) { if ($m.Groups[1].Value.Length -gt $max) { $max = $m.Groups[1].Value.Length } }
        }
        if ($computed.ContainsKey($v)) { $max = [Math]::Max($max, $computed[$v]) }
        Assert-True ($max -gt 0) "Nothing assigns a value to $v, yet the header prints it."
        $rendered = $rendered -replace ('[%!]' + [regex]::Escape($v) + '[%!]'), ('x' * $max)
    }
    Assert-True ($rendered.Length -le 98 -and $rendered.Length -lt $width) ("At its widest the main-menu header is {0} columns - past the 98-column separators, or it wraps at {1}: {2}" -f $rendered.Length, $width, $rendered)
}

# ===============================================================================
# 154. The refresh-rate parser is RUN on synthetic worker answers. It decides what
#      the header claims, and its input is a file in the user's TEMP, so it is checked,
#      not trusted. This extracts :_hzParse, :_hzRec and :_hzJoin and feeds them every
#      answer the worker can give and many it never gives, including records holding
#      & ) " % ! - each must come out "unknown", with nothing else printed. Every header
#      value must fit 14 columns, and the 64-display case must reach exactly 14 (test
#      153 relies on it). The answer path reaches the driver through the environment.
# ===============================================================================
Invoke-Test 'The refresh-rate parser turns synthetic worker answers into honest values (run)' {
    $cmd = Read-Lines $CmdPath
    $grab = {
        param([string]$Label, [string[]]$Own)
        $i = [Array]::IndexOf($cmd, ':' + $Label)
        if ($i -lt 0) { throw "test 154: :$Label not found." }
        $j = $i + 1
        while ($j -lt $cmd.Count) { if ($cmd[$j] -match '^:(\w+)' -and -not ($Own -contains $Matches[1])) { break }; $j++ }
        $cmd[$i..($j - 1)]
    }
    $parts = @(& $grab '_hzParse' @('_hzUnknown')) + @(& $grab '_hzRec' @('_hzRecKeep')) + @(& $grab '_hzJoin' @())
    $pc = @($parts | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($pc.Length -gt 500) 'The parser routines did not unroll.'
    Assert-True ($pc -notmatch '(?i)\bstart\b|powershell|call :(?!_hz)') 'The parser starts a process or calls outside itself.'
    $body = @('@echo off', 'setlocal EnableDelayedExpansion', 'set "_hzres=!PT154_ANS!"', 'call :_hzParse', 'echo [!REFRESH!]^|[!REFRESH_ALL!]', 'exit /b 0') + $parts
    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '[\s%]') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT154_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $big = @(1..64 | ForEach-Object { 'S 9999' })
    $over = @(1..65 | ForEach-Object { 'S 60' })
    $cases = @(
        @('single',            @('S 144'),                 '144Hz',          '144Hz'),
        @('two',               @('S 144', 'S 60'),         '144/60Hz',       '144/60Hz'),
        @('three',             @('S 144', 'S 60', 'S 75'), '144/60Hz+1',     '144/60/75Hz'),
        @('hw default 0',      @('S 0'),                   'unknown',        'unknown'),
        @('hw default 1, mix', @('S 1', 'S 60'),           '?/60Hz',         '?/60Hz'),
        @('unreadable',        @('S ?'),                   'unknown',        'unknown'),
        @('unreadable, mix',   @('S 144', 'S ?'),          '144/?Hz',        '144/?Hz'),
        @('remote',            @('R', 'S 32'),             'remote',         'remote'),
        @('remote, failed',    @('R', 'E'),                'remote',         'remote'),
        @('failed',            @('E'),                     'unknown',        'unknown'),
        @('no display',        @('N'),                     'unknown',        'unknown'),
        @('N beside a rate',   @('N', 'S 60'),             'unknown',        'unknown'),
        @('empty answer',      @(),                        'unknown',        'unknown'),
        @('64 displays',       $big,                       '9999/9999Hz+62', '9999/9999/9999/9999/9999/9999/9999/9999Hz+56'),
        @('over the cap',      $over,                      'unknown',        'unknown'),
        @('leading zero',      @('S 0144'),                'unknown',        'unknown'),
        @('five digits',       @('S 12345'),               'unknown',        'unknown'),
        @('negative',          @('S -1'),                  'unknown',        'unknown'),
        @('letter in rate',    @('S 6x0'),                 'unknown',        'unknown'),
        @('unknown record',    @('X 60'),                  'unknown',        'unknown'),
        @('old P record',      @('P 60'),                  'unknown',        'unknown'),
        @('lower-case record', @('s 60'),                  'unknown',        'unknown'),
        @('extra token',       @('S 60 extra'),            'unknown',        'unknown'),
        @('two R',             @('R', 'R'),                'unknown',        'unknown'),
        @('two E',             @('E', 'E'),                'unknown',        'unknown'),
        @('R with a value',    @('R 1', 'S 60'),           'unknown',        'unknown'),
        @('record, no rate',   @('S'),                     'unknown',        'unknown'),
        @('ampersand',         @('S 6&0'),                 'unknown',        'unknown'),
        @('paren',             @('S 1)0'),                 'unknown',        'unknown'),
        @('quote',             @('S "60"'),                'unknown',        'unknown'),
        @('percent',           @('S 60%OS%'),              'unknown',        'unknown'),
        @('bang',              @('S 6!0'),                 'unknown',        'unknown'))
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        $drv = Join-Path $dir 'drv.cmd'
        [System.IO.File]::WriteAllLines($drv, [string[]]$body, [System.Text.Encoding]::ASCII)
        $ran = 0; $widest = 0
        foreach ($c in $cases) {
            $ans = Join-Path $dir 'answer.txt'
            $lines = @($c[1])
            [System.IO.File]::WriteAllText($ans, $(if ($lines.Count) { ($lines -join "`r`n") + "`r`n" } else { '' }), [System.Text.Encoding]::ASCII)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $psi.Arguments = '/d /c "' + $drv + '"'
            $psi.WorkingDirectory = $dir
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['PT154_ANS'] = $ans
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $err = $p.StandardError.ReadToEndAsync()
            $out = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw ("test 154: the parser did not finish for case '{0}'." -f $c[0]) }
            $want = '[' + $c[2] + ']|[' + $c[3] + ']'
            $outl = @($out -split "`r?`n" | Where-Object { $_.Trim() })
            Assert-True ($outl.Count -eq 1 -and $outl[0] -eq $want) ("Case '{0}': the parser printed {1}, not only {2} (regression). {3}" -f $c[0], ($outl -join ' / '), $want, $err.Result.Trim())
            Assert-True ($err.Result.Trim() -eq '') ("Case '{0}': cmd reported an error while parsing: {1}" -f $c[0], $err.Result.Trim())
            $hv = $c[2].Length; if ($hv -gt $widest) { $widest = $hv }
            Assert-True ($hv -le 14) ("Case '{0}': a {1}-column header value - test 153 assumes 14 at most." -f $c[0], $hv)
            $ran++
        }
        Assert-True ($ran -eq $cases.Count -and $ran -ge 30) "test 154 ran only $ran case(s)."
        Assert-True ($widest -eq 14) "The widest header value reached $widest, not 14 - test 153's constant no longer matches the parser."
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# ===============================================================================
# 155. The refresh-rate state machine is RUN over simulated main-menu draws, with the
#      worker stubbed out (no process starts). An answer that lands at draw 3 must be
#      shown from then on and its files deleted; with no worker marker the header must
#      give up to "unknown" at draw 10, and an answer landing later must still replace
#      it; a worker that started (".run" present) must stay "pending" through draw 29.
# ===============================================================================
Invoke-Test 'The refresh-rate state machine collects, gives up and recovers across draws (run)' {
    $cmd = Read-Lines $CmdPath
    $grab = {
        param([string]$Label, [string[]]$Own)
        $i = [Array]::IndexOf($cmd, ':' + $Label)
        if ($i -lt 0) { throw "test 155: :$Label not found." }
        $j = $i + 1
        while ($j -lt $cmd.Count) { if ($cmd[$j] -match '^:(\w+)' -and -not ($Own -contains $Matches[1])) { break }; $j++ }
        $cmd[$i..($j - 1)]
    }
    $parts = @(& $grab 'DetectRefresh' @()) + @(& $grab '_hzCollect' @()) + @(& $grab '_hzParse' @('_hzUnknown')) + @(& $grab '_hzRec' @('_hzRecKeep')) + @(& $grab '_hzJoin' @())
    Assert-True (($parts -join "`n") -match 'if not defined HZSTATE call :ProbeRefresh') 'test 155: :DetectRefresh did not unroll.'
    # :ProbeRefresh is replaced by a stub that sets the same state and starts nothing
    $stub = @(':ProbeRefresh', 'set "_hzres=!PT155_DIR!\ans.txt"', 'set "HZSTATE=pending"', 'set "_hzdraws=0"', 'set "REFRESH=pending"', 'set "REFRESH_ALL=pending"', 'goto :eof', ':LogVar', 'goto :eof')
    $body = @('@echo off', 'setlocal EnableDelayedExpansion',
              'for /l %%D in (1,1,32) do (',
              '  if "%%D"=="!PT155_LAND!" (>"!PT155_DIR!\ans.txt" echo S 144)',
              '  if "%%D"=="1" if defined PT155_RUN (>"!PT155_DIR!\ans.txt.run" echo run)',
              '  call :DetectRefresh',
              '  if exist "!PT155_DIR!\ans.txt" (set "_f=file") else (set "_f=nofile")',
              '  echo D%%D !REFRESH! !_f!',
              ')', 'exit /b 0') + $stub + $parts
    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '[\s%]') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT155_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $run = {
        param([string]$Land, [string]$RunMarker)
        Get-ChildItem -LiteralPath $dir -Filter 'ans.txt*' -ErrorAction SilentlyContinue | Remove-Item -Force
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /c "' + (Join-Path $dir 'drv.cmd') + '"'
        $psi.WorkingDirectory = $dir
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PT155_DIR'] = $dir
        $psi.EnvironmentVariables['PT155_LAND'] = $Land
        if ($RunMarker) { $psi.EnvironmentVariables['PT155_RUN'] = '1' }
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'test 155: the state-machine driver did not finish.' }
        $st = @{}
        foreach ($l in ($out -split "`r?`n")) { $m = [regex]::Match($l, '^D(\d+) (\S+) (\S+)$'); if ($m.Success) { $st[[int]$m.Groups[1].Value] = @($m.Groups[2].Value, $m.Groups[3].Value) } }
        Assert-True ($st.Count -eq 32) ("test 155: expected 32 draws, got {0}. {1}" -f $st.Count, $err.Result.Trim())
        $st
    }
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        [System.IO.File]::WriteAllLines((Join-Path $dir 'drv.cmd'), [string[]]$body, [System.Text.Encoding]::ASCII)
        # (a) the answer lands at draw 3
        $s = & $run '3' ''
        Assert-True ($s[1][0] -eq 'pending' -and $s[2][0] -eq 'pending') 'Before the answer lands the header must say pending.'
        foreach ($d in 3..32) { Assert-True ($s[$d][0] -eq '144Hz') ("Draw ${d}: the header says {0}, not the collected 144Hz (regression)." -f $s[$d][0]) }
        Assert-True ($s[3][1] -eq 'nofile') 'The answer file is not deleted once it has been collected (regression).'
        # (b) no worker marker: give up at draw 10, recover when an answer lands at draw 12
        $s = & $run '12' ''
        foreach ($d in 1..9) { Assert-True ($s[$d][0] -eq 'pending') ("Draw ${d}: the header gave up too early ({0})." -f $s[$d][0]) }
        Assert-True ($s[10][0] -eq 'unknown' -and $s[11][0] -eq 'unknown') 'A worker that never started must turn the header to unknown at draw 10 (regression).'
        foreach ($d in 12..32) { Assert-True ($s[$d][0] -eq '144Hz') ("Draw ${d}: an answer that landed after the give-up did not replace unknown (regression).") }
        # (c) the worker started (.run present) but no answer: pending through draw 29, unknown at 30
        $s = & $run '99' '1'
        foreach ($d in 1..29) { Assert-True ($s[$d][0] -eq 'pending') ("Draw ${d}: a started worker was given up on too early ({0})." -f $s[$d][0]) }
        Assert-True ($s[30][0] -eq 'unknown') 'A started worker that never answers must still give up at draw 30 (regression).'
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# ===============================================================================
# 156. Non-ASCII names survive. Adapter, startup-entry, PATH and lock-holder names
#      used to show as ? on a PC whose code page for non-Unicode programs lacks
#      their letters (437 under a Russian UI). Every read that can carry one now
#      switches the console to UTF-8 and back, and the workers behind them write
#      UTF-8 and keep every letter. RUN in a hidden console from code page 437 -
#      chcp needs a console: a UTF-8 file read through :Utf8On comes back intact,
#      and :Utf8Off puts 437 back.
# ===============================================================================
Invoke-Test 'Non-ASCII names survive every screen that shows them, and the code page is restored (run)' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"
    $on = @(Get-BodyLines -Lines $cmd -Label 'Utf8On' -CodeOnly) -join "`n"
    $off = @(Get-BodyLines -Lines $cmd -Label 'Utf8Off' -CodeOnly) -join "`n"
    Assert-True ($on -match 'chcp 65001 >nul' -and $on -match 'set "_cpSaved=!_cpRaw!"') ':Utf8On no longer saves the code page before switching to UTF-8.'
    Assert-True ($on -match 'eol=0 delims=0123456789') ':Utf8On switches without checking that chcp printed a number.'
    Assert-True ($off -match 'chcp !_cpSaved! >nul' -and $off -match 'set "_cpSaved="') ':Utf8Off no longer restores the saved code page.'
    $scd = @(Get-BodyLines -Lines $cmd -Label 'ShowCurrentDns' -CodeOnly) -join "`n"
    $i1 = $scd.IndexOf('call :Utf8On'); $i2 = $scd.IndexOf('call :_scdScan'); $i3 = $scd.LastIndexOf('call :Utf8Off'); $i4 = $scd.LastIndexOf('call :_scdScan')
    Assert-True ($i1 -ge 0 -and $i1 -lt $i2 -and $i3 -gt $i4) ':ShowCurrentDns reads adapter names through reg without UTF-8 (regression: they show as ?).'
    foreach ($f in '_dnsf', '_sures', '_peres') {
        Assert-True ($all -match ('(?m)^call :Utf8On\nif exist "!' + $f + '!" type "!' + $f + '!"\ncall :Utf8Off$')) "The $f display is not wrapped in :Utf8On / :Utf8Off."
    }
    foreach ($f in '_sulist', '_pelist', '_lflist') {
        Assert-True ($all -match ('(?m)^call :Utf8On\nfor /f "usebackq tokens=[^"]+" %%a in \("!' + $f + '!"\) do \(')) "The $f read is not preceded by call :Utf8On."
    }
    foreach ($v in 'PT_DNSF', 'PT_SU_LIST', 'PT_SU_RES', 'PT_PE_LIST', 'PT_PE_RES', 'PT_LF_LIST') {
        $w = @($cmd | Where-Object { $_ -match ('\$env:' + $v + '\b') -and $_ -match '(?i)powershell' })
        Assert-True ($w.Count -ge 1) "No worker writes $v."
        foreach ($l in $w) {
            Assert-True ($l -notmatch ('Out-File -FilePath \$env:' + $v + ' -Encoding ASCII')) "$v is written as ASCII again - non-ASCII names become ? (regression)."
            Assert-True ($l -match 'function Wu8\(\$p\)' -and $l -match 'UTF8Encoding \$false') "The worker writing $v lost its UTF-8 writer (no BOM: a BOM would glue itself to the first field)."
            Assert-True ($l -notmatch '\[\^\\x20-\\x7e\]') "The worker writing $v turns non-ASCII letters into ? again (regression)."
        }
    }

    # RUN
    $grab = {
        param([string]$Label)
        $i = [Array]::IndexOf($cmd, ':' + $Label)
        if ($i -lt 0) { throw "test 156: :$Label not found." }
        $j = $i + 1
        while ($j -lt $cmd.Count -and $cmd[$j] -notmatch '^:\w') { $j++ }
        $cmd[$i..($j - 1)]
    }
    $body = @('@echo off', 'setlocal EnableDelayedExpansion', 'chcp 437 >nul', 'call :Utf8On',
        'for /f "usebackq delims=" %%L in ("!PT156_IN!") do set "V=%%L"', 'call :Utf8Off',
        "for /f `"tokens=2 delims=:`" %%p in ('chcp') do set `"CPA=%%p`"",
        'chcp 65001 >nul', '>"!PT156_OUT!" echo [!V!]^|[!CPA: =!]', 'exit /b 0') + @(& $grab 'Utf8On') + @(& $grab 'Utf8Off')
    $tmp = [System.IO.Path]::GetTempPath()
    if ($tmp -match '[\s%]') { $tmp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($tmp).ShortPath }
    $dir = Join-Path $tmp ('PT156_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $name = -join [char[]](0x0411,0x0435,0x0441,0x043F,0x0440,0x043E,0x0432,0x043E,0x0434,0x043D,0x0430,0x044F,0x20,0x0441,0x0435,0x0442,0x044C)
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        $drv = Join-Path $dir 'drv.cmd'; $in = Join-Path $dir 'in.txt'; $outf = Join-Path $dir 'out.txt'
        [System.IO.File]::WriteAllLines($drv, [string[]]$body, [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText($in, $name + "`r`n", (New-Object System.Text.UTF8Encoding $false))
        $env:PT156_IN = $in; $env:PT156_OUT = $outf
        try {
            $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/d /c "' + $drv + '"') -WindowStyle Hidden -PassThru
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'test 156: the driver did not finish within 30 s.' }
        }
        finally { $env:PT156_IN = $null; $env:PT156_OUT = $null }
        Assert-True (Test-Path -LiteralPath $outf) 'test 156: the driver wrote no result.'
        $got = [System.IO.File]::ReadAllText($outf, [System.Text.Encoding]::UTF8).Trim()
        Assert-True ($got -ceq ('[' + $name + ']|[437]')) ("A UTF-8 name read through :Utf8On came back as {0}, not [{1}]|[437] - either the letters or the code page were lost (regression)." -f $got, $name)
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# ---- summary ------------------------------------------------------------------------------
Write-Host ""
if ($script:Failures.Count -eq 0) {
    Write-Host ("All {0} test(s) passed." -f $script:Total) -ForegroundColor Green
    exit 0
}
else {
    Write-Host ("{0} of {1} test(s) FAILED: {2}" -f $script:Failures.Count, $script:Total, ($script:Failures -join ', ')) -ForegroundColor Red
    exit 1
}

