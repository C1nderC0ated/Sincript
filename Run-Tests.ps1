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
        # matches:  if /i "%_k%"=="cleanup" ( ...
        $m = [regex]::Match($ln, '(?i)"%_k%"=="([^"]+)"')
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
            $m = [regex]::Match($ln, '%(_\w+)%')   # the prompt var this write is gated on
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
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        if ($t -notmatch '(?i)Invoke-WebRequest') { continue }
        Assert-True ($t -match '(?i)if\s+errorlevel\s+1\s+del\b') (":$r ignores the download exit code / keeps a partial file on failure (regression).")
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
    foreach ($r in 'DisableMitigations','EnableMitigations','NvmeFlags','DisableIPv6','GpuAmd','HagsOff','HagsOn') {
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
    $copyIdx  = $b.IndexOf('%script_dir%hosts')
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
    Assert-True (($cmd -join "`n") -match '(?im)^\s*set "PT_SELF=%~f0"') 'UAC relaunch no longer stages %~f0 in PT_SELF - an apostrophe in the script path would break Start-Process (regression).'
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
#     dispatcher routes it, and the submenu routes to both tools and back.
# ===============================================================================
Invoke-Test 'System tools menu reachable and wired' {
    $cmd = Read-Lines $CmdPath
    $text = ($cmd -join "`n")
    Assert-True ($text -match '(?m)^if "%sel%"=="12" goto MenuTools\s*$') 'Main-menu dispatcher does not route 12 -> MenuTools.'
    $mtText = (Get-RoutineBody -Lines $cmd -Label 'MenuTools_ask') -join "`n"
    Assert-True ($mtText -match '(?i)if "%sel%"=="1" goto PathEditor') 'MenuTools does not route 1 -> PathEditor.'
    Assert-True ($mtText -match '(?i)if "%sel%"=="2" goto LockFinder') 'MenuTools does not route 2 -> LockFinder.'
    Assert-True ($mtText -match '(?i)if "%sel%"=="0" goto MainMenu') 'MenuTools has no 0 -> back to MainMenu.'
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
#     permanent). This test guards BOTH halves of "be honest": the reasons stay
#     visible on the Excluded screen, and no code path ever writes the values.
# ===============================================================================
Invoke-Test 'Declined tweaks stay declined and stay documented' {
    $cmd = Read-Lines $CmdPath
    $excluded = (Get-RoutineBody -Lines $cmd -Label 'Excluded') -join "`n"

    foreach ($d in 'SvcHostSplitThresholdInKB','ServicesPipeTimeout','EnablePrefetcher') {
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
        Assert-True ($text -match ('(?i)call :CleanRoot ' + $r + ' "%' + $r + '%"')) ":DoCleanupCore no longer proves $r before deleting under it."
    }

    # Every delete that interpolates a variable must be gated. A single ungated one
    # is the whole bug back again.
    foreach ($ln in $code) {
        if ($ln -match '(?i)call :Run "del ') {
            Assert-True ($ln -match '(?i)^\s*if defined _clean(TEMP|SystemRoot|LocalAppData)\s') ("Ungated delete in :DoCleanupCore - if its root variable is unset this deletes from a drive root: " + $ln.Trim())
        }
    }
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
        Assert-True ($b -notmatch '(?i)call :RequireBundledFile') (":$r calls :RequireBundledFile, which aborts with 'goto MenuApps'. That would abandon a multi-step run part-way, skip :Summary and land the user on an unrelated menu with the machine half configured. Make :RequireBundledFile return a status before depending on it here.")
    }

    # and the guard must still actually abort rather than fall through
    $rbBody = Get-RoutineBody -Lines $cmd -Label 'RequireBundledFile'
    $rb = @($rbBody | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($rb -match '(?i)goto MenuApps') ':RequireBundledFile no longer aborts on a missing file - the caller would run on without it.'
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
        if ($ln -match '(?i)^\s*echo\b.*%~1') { $echoDepths += $depth }
        # update depth: a line ending in a bare ( opens; a lone ) closes
        $stripped = $s
        if ($stripped -match '\($' -and $stripped -notmatch '\^\($') { $depth++ }
        if ($stripped -eq ')' -or $stripped -match '^\)\s') { $depth-- }
    }
    Assert-True ($echoDepths.Count -ge 1) ':Summary no longer echoes %~1 at all - unexpected.'
    $bad = @($echoDepths | Where-Object { $_ -ne 0 })
    Assert-True ($bad.Count -eq 0) ":Summary echoes %~1 inside a ( ) block (depth $($bad -join ',')). A ')' in the caller's text - e.g. '(incl. Downfall/GDS)' - will close the block early and crash the script. Keep :Summary block-free (goto branching), do not use if(...)else(...)."

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
        $gateAt = $joined.IndexOf('if not exist "!_bkp!"')
        $writeAt = if ($r -eq 'SafeRegAdd') { $joined.IndexOf('reg add') } else { $joined.IndexOf('reg delete') }
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
    Assert-True ($joined -match 'if not exist "%PRESET_JSON_TMP%"') ':PresetBegin no longer verifies the JSON temp file landed (regression).'
    Assert-True ($code -match 'exit /b 1') ':PresetBegin no longer exits nonzero when the JSON temp is missing (regression).'
    Assert-True ($code -match 'PRESET_MODE=1') ':PresetBegin no longer sets PRESET_MODE=1 on the success path.'
    $gateAt = $joined.IndexOf('if not exist "%PRESET_JSON_TMP%"')
    $modeAt = $joined.IndexOf('set "PRESET_MODE=1"')
    Assert-True ($gateAt -ge 0 -and $modeAt -gt $gateAt) ':PresetBegin sets PRESET_MODE before verifying the JSON temp (regression).'

    foreach ($r in 'PresetLight','PresetModerate','PresetHeavy') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)call :PresetBegin') ":$r no longer calls :PresetBegin."
        Assert-True ($t -match '(?i)if errorlevel 1 goto MenuPresets') ":$r does not abort when :PresetBegin fails - it would apply with no JSON undo (regression)."
    }
    $all = $cmd -join "`n"
    Assert-True ($all -match '(?i)call :PresetBegin custom_%_pbase%[\s\S]{0,120}if errorlevel 1 goto MenuPresets') 'Custom preset apply does not abort when :PresetBegin fails (regression).'
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
    Assert-True ($code -match 'if errorlevel 1') ':SteamLight no longer branches on the shortcut PS exit code (regression).'
    Assert-True ($joined -match '\[WARN\].*shortcut') ':SteamLight lost its [WARN] when the Desktop shortcut fails (regression).'
    # Desktop claim must share the success branch with the errorlevel gate, not stand alone.
    Assert-True ($joined -match 'if errorlevel 1[\s\S]{0,400}shortcut was placed on your Desktop') ':SteamLight Desktop-shortcut [OK] is no longer gated on the shortcut PS exit code (regression).'
}

# ===============================================================================
# 67. Memory-compression disable must not swallow failures, and the preset path
#     must bump _FAILS so :Summary stays honest.
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
        Assert-True ($code -match 'if errorlevel 1') ":$r no longer branches on the PS exit code (regression)."
        Assert-True ($code -notmatch 'SilentlyContinue') ":$r still invokes Disable-MMAgent with SilentlyContinue (regression)."
    }
    $dmcBody = Get-RoutineBody -Lines $cmd -Label 'DoMemCompressOff'
    $dmc = (@($dmcBody) -join "`n")
    Assert-True ($dmc -match 'set /a _FAILS\+=1') ':DoMemCompressOff no longer bumps _FAILS on failure - preset :Summary would stay green (regression).'
}

# ===============================================================================
# 68. NVIDIA telemetry tasks are disabled by name prefix (like privacy extras),
#     never via hardcoded schtasks /TN GUID paths.
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
    Assert-True ($code -match 'NvDriverUpdateCheckDaily_') ':DisableNvidiaTelemetryTasks lost the NvDriverUpdateCheckDaily_ name prefix.'
    Assert-True ($code -notmatch '(?i)schtasks') ':DisableNvidiaTelemetryTasks INVOKES schtasks - use name lookup like :DisableTelemetryTasks.'
    $si = -1; $fi = -1; $oi = -1
    for ($i = 0; $i -lt $b.Count; $i++) {
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
    Assert-True ($perf -match '(?i)%_q12%') ':Performance Game Bar residual is not gated on _q12 (regression).'

    $gb = (Get-RoutineBody -Lines $cmd -Label 'DoGameBarOff') -join "`n"
    Assert-True ($gb.Length -gt 0) ':DoGameBarOff helper missing.'
    Assert-True ($gb -match '(?i)"AppCaptureEnabled"\s+REG_DWORD\s+0') ':DoGameBarOff missing AppCaptureEnabled=0.'
    Assert-True ($gb -match '(?i)"UseNexusForGameBarEnabled"\s+REG_DWORD\s+0') ':DoGameBarOff missing UseNexusForGameBarEnabled=0.'
    Assert-True ($gb -match '(?i)"ShowStartupPanel"\s+REG_DWORD\s+0') ':DoGameBarOff missing ShowStartupPanel=0.'

    $check = (Get-RoutineBody -Lines $cmd -Label 'PresetCheckLine') -join "`n"
    Assert-True ($check -match '(?i)"%_k%"=="gamebar_off"') 'Preset validator lost gamebar_off.'
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
    Assert-True ($check -match '(?i)"%_k%"=="edge_nudges_off"') 'Preset validator lost edge_nudges_off.'
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
    Assert-True ($joined -match '(?i)if defined _cleanLocalAppData if exist "%LocalAppData%\\CrashDumps') ':CrashDumps delete is not gated on _cleanLocalAppData.'
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
    Assert-True ($joined -match '(?i)%_sh%') ':Cleanup shader bucket not gated on a prompt var.'
    Assert-True ($joined -match '(?i)%_rb%') ':Cleanup Recycle Bin not gated on a prompt var.'
    Assert-True ($joined -match '(?i)%_cm%') ':Cleanup cleanmgr not gated on a prompt var.'
    Assert-True ($joined -match '(?i)%_ss%') ':Cleanup Storage Sense not gated on a prompt var.'
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
    $write = $code.IndexOf('copy /y "%_src%"')
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
    Assert-True ($chk -match '(?i)"%_k%"=="onedrive_off"') 'Preset validator lost the onedrive_off key.'
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
        $b = Get-RoutineBody -Lines $cmd -Label $r
        $b = @($b)
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
        Assert-True ($code -match '(?i)del /f /q "%TEMP%\\openasar_nightly\.asar"') ":$r leaves the downloaded nightly behind in %TEMP% (regression of F7)."
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
    Assert-True ($sw -match '(?i)if not defined _PWPLAN set "_PWPLAN=ultimate"') ':DoPowerPlanSwitch no longer defaults an unset request to ultimate - preset "power=1" and Apply-recommended would silently change meaning (regression).'
    Assert-True ($sw -match '(?i)"%_PWPLAN%"=="high"')     ':DoPowerPlanSwitch lost the High Performance branch (regression).'
    Assert-True ($sw -match '(?i)"%_PWPLAN%"=="balanced"') ':DoPowerPlanSwitch lost the Balanced branch - there would be no in-app way back to the Windows default plan (regression).'
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
    Assert-True ($code -notmatch '(?i)if /i not "%_c%"=="Y" goto MainMenu') ':Power sends a declined plan switch straight back to the main menu again - hibernation, min CPU state and throttling become unreachable (regression of the current-plan path).'
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
    Assert-True ($chk -match '(?i)"%_k%"=="power_timeouts"') 'Preset validator lost the power_timeouts key.'
    $all = ($cmd -join "`n")
    Assert-True ($all -match '(?i)if not defined _P_POWER if defined _P_PWTIMEOUTS call :DoPowerTimeouts') 'Custom presets no longer apply power_timeouts, or lost the guard that stops it running twice alongside power=1.'
    Assert-True ($chk -match '(?i)"%_k%"=="power_plan"') 'Preset validator lost the power_plan key - a preset could only ever get the hidden Ultimate default.'
    $pk = ((Get-RoutineBody -Lines $cmd -Label 'PChkPlan') -join "`n")
    Assert-True ($pk.Length -gt 0) ':PChkPlan is missing.'
    foreach ($v in 'ultimate','high','balanced') {
        Assert-True ($pk -match ('(?i)"%~1"=="' + $v + '"')) ":PChkPlan no longer accepts $v (regression)."
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
    Assert-True ($pb -match '(?i)powercfg -setacvalueindex') ':PowerBackup no longer emits restore commands into the undo file.'
    Assert-True ($pb -match '(?i)powercfg -setactive')       ':PowerBackup undo file no longer re-activates the captured scheme.'
    Assert-True ($pb -match '(?i)never explicitly set')      ':PowerBackup no longer honest-declines a setting the scheme never had - it would guess a value instead of leaving the default (regression).'
    # PROCTHROTTLEMIN is reachable on its own (decline the plan switch AND the timeouts, then
    # say yes to the minimum processor state), so leaving it out made the prompt promise an
    # undo that did not exist.
    Assert-True ($pb -match '(?i)893dee8e-2bef-41e0-89c6-b55d0929964c') ':PowerBackup no longer captures PROCTHROTTLEMIN - the minimum-processor-state prompt would imply an undo it does not have (regression).'
    # A partial run is the realistic failure here: the machine crashed part-way through the
    # restore and never reached -setactive, so the plan stayed switched. It goes back FIRST.
    $first = $pb.IndexOf('powercfg -setactive')
    $write = $pb.IndexOf('powercfg -setacvalueindex')
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
    $emitPc  = ([regex]::Matches($pb, "'powercfg -set")).Count
    $emitVia = ([regex]::Matches($pb, "'call :pt_do powercfg -set")).Count
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
        $b = Get-RoutineBody -Lines $cmd -Label $r
        $b = @($b)
        Assert-True ($b.Count -gt 0) (":$r body empty.")
        $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
        Assert-True ($code -match '(?i)set "_PWBAK_FILE="') ":$r does not clear _PWBAK_FILE, so a later power change in the same session would reuse a stale undo file and capture nothing (regression)."
    }
}

# ===============================================================================
# 93. The undo file is reachable from the UI - a backup nobody can run is not an
#     undo. Item 6 on Backups & status, with Manage moved to 7.
# ===============================================================================
Invoke-Test ':RestorePowerBackup is wired into the Backups menu' {
    $cmd = Read-Lines $CmdPath
    $mb = ((Get-RoutineBody -Lines $cmd -Label 'MenuBackups') -join "`n")
    Assert-True ($mb -match '(?i)6\.\s+Revert power settings') ':MenuBackups no longer offers the power revert item (regression).'
    Assert-True ($mb -match '(?i)7\.\s+Manage / open backup folder') ':MenuBackups lost the renumbered Manage item.'
    $ask = ((Get-RoutineBody -Lines $cmd -Label 'MenuBackups_ask') -join "`n")
    Assert-True ($ask -match '(?i)"%sel%"=="6" goto RestorePowerBackup') 'Backups menu item 6 no longer routes to :RestorePowerBackup (regression).'
    Assert-True ($ask -match '(?i)"%sel%"=="7" goto ManageBackups')      'Backups menu item 7 no longer routes to :ManageBackups (renumbering broke).'

    # :RestorePowerBackup_ask does not start with "_", so it ends the routine body - concatenate.
    $r1 = Get-RoutineBody -Lines $cmd -Label 'RestorePowerBackup'
    $r2 = Get-RoutineBody -Lines $cmd -Label 'RestorePowerBackup_ask'
    $rb = (@($r1) + @($r2)) -join "`n"
    Assert-True ($rb -match '(?i)PowerPlan_\*\.bat') ':RestorePowerBackup no longer lists the PowerPlan_*.bat undo files.'
    Assert-True ($rb -match '(?i)call "%_pfile%" /q')  ':RestorePowerBackup no longer runs the chosen undo file with /q (its own pause would block the menu).'
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
        if ($r.Length -ne 83) {
            $bad.Add(("{0} wide: {1}" -f $r.Length, $arg.Substring(0, [Math]::Min(44, $arg.Length))))
        }
    }
    Assert-True ($widths.Keys.Count -gt 0) 'No separator lines found - has the menu changed shape?'
    Assert-True ($bad.Count -eq 0) ("Separators must all render 83 columns or the menus look ragged. Offenders: " + (($bad | Select-Object -First 4) -join ' | '))
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
        foreach ($l in ($menu + $ask)) { if ($l -match 'if(?:\s+/i)?\s+"%\w+%"=="([0-9]+)"') { $handled += $Matches[1] } }

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

# ---- summary ------------------------------------------------------------------
Write-Host ""
if ($script:Failures.Count -eq 0) {
    Write-Host ("All {0} test(s) passed." -f $script:Total) -ForegroundColor Green
    exit 0
}
else {
    Write-Host ("{0} of {1} test(s) FAILED: {2}" -f $script:Failures.Count, $script:Total, ($script:Failures -join ', ')) -ForegroundColor Red
    exit 1
}

