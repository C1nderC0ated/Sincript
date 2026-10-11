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

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File D:\anywhere\Run-Tests.ps1 -Root "D:\Tools\sincript"

.PARAMETER Root
    The folder that holds PerfTweaks.cmd. Optional: without it the harness looks beside itself,
    then one folder up (its usual home is <sincript>\tests), then in the current folder.

.OUTPUTS
    Writes a PASS/FAIL line per test and a summary. Exit code 0 = all passed, 1 = failure,
    2 = PerfTweaks.cmd was not found.
#>
[CmdletBinding()]
param([string]$Root)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- locate the files under test: -Root, else beside this file, one folder up, the current folder ----
$SelfPath   = $MyInvocation.MyCommand.Path
$TestsDir   = Split-Path -Parent $SelfPath
$cands = @(if ($Root) { $Root } else { $TestsDir; (Split-Path -Parent $TestsDir); (Get-Location).ProviderPath })
$ScriptRoot = $null
foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'PerfTweaks.cmd'))) { $ScriptRoot = (Resolve-Path -LiteralPath $c).ProviderPath; break } }
if (-not $ScriptRoot) {
    Write-Host ('PerfTweaks.cmd was not found in: ' + ($cands -join ' ; ') + ' - pass the sincript folder with -Root.') -ForegroundColor Red
    exit 2
}
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
    # Entry points are non-underscore labels plus any label reached via `call`; goto-only
    # sub-labels (:_x) stay in their parent's body, or the body is sliced short.
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

# Runs a generated batch driver in a child cmd; refuses one that holds a real system command.
# -Allow exempts lines that only hand a command to a routine the driver stubs (call :RunLive "dism ...");
# anchor it through the closing quote. -Real is what counts as a real system command.
function Invoke-CmdDriver {
    param([string[]]$Lines, [string]$Dir, [int]$Seconds = 30, [string]$Allow = '^$', [string]$Real = '(?i)\b(reg\s+(query|add|delete|import)|powershell|schtasks|bitsadmin|dism|bcdedit|powercfg|net\s+(stop|start)|sc(\.exe)?\s+(stop|start|config|delete)|takeown|icacls|ipconfig|netsh|wevtutil|taskkill|vssadmin|reagentc|compact(\.exe)?\s+/compactos)\b')
    $live = @($Lines | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_.Trim() -notmatch $Allow -and -not ($_.Trim() -match '^(?i)((if .*?)?echo\b|call :Log\b)' -and ($_ -replace '"[^"]*"', '') -notmatch '(?<!\^)[&|)]') -and $_ -match $Real })
    if ($live.Count -gt 0) { throw ('the driver contains a real system command - refusing to run it: ' + ($live -join ' | ')) }
    $path = Join-Path $Dir 'drv.cmd'
    [System.IO.File]::WriteAllLines($path, $Lines, [System.Text.Encoding]::ASCII)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /s /c ""' + $path + '""'
    $psi.WorkingDirectory = $Dir
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    # System32 first: a harness started from Git Bash or MSYS hands the child a PATH where GNU find, sort
    # and timeout shadow Windows' own; GNU find reads `/c` as the C: drive and walks it past any limit.
    $psi.EnvironmentVariables['Path'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:Path
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEndAsync()
    $outT = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) { $p.Kill(); throw "the driver did not finish within $Seconds s." }
    $out = $outT.Result
    [pscustomobject]@{ Exit = $p.ExitCode; Out = [string[]]@($out -split "`r?`n"); Err = $err.Result.Trim() }
}

# Splits driver output at [CASE#0]..[CASE#n-1] and [END]; one string per case.
function Get-CaseSections {
    param([string[]]$Out, [int]$Count)
    $m = @(@(0..($Count - 1) | ForEach-Object { [Array]::IndexOf($Out, "[CASE#$_]") }) + @([Array]::IndexOf($Out, '[END]')))
    $secs = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Count; $i++) {
        if ($m[$i] -lt 0 -or $m[$i + 1] -le $m[$i]) { throw 'the driver did not run every case in order.' }
        $secs.Add($(if ($m[$i + 1] -gt $m[$i] + 1) { ($Out[($m[$i] + 1)..($m[$i + 1] - 1)]) -join "`n" } else { '' }))
    }
    return ,$secs.ToArray()
}
# A gate is only as good as its exit: each block opened by a code line matching $Open must hold a
# line matching $Exit before its closing ')'. rem and echo lines are dropped, so prose cannot count.
function Test-BlockExit {
    param([string[]]$Lines, [string]$Open, [string]$Exit)
    $code = @($Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -notmatch '^(?i)(rem|echo)\b' })
    $hits = 0
    for ($i = 0; $i -lt $code.Count; $i++) {
        if ($code[$i] -notmatch $Open) { continue }
        $hits++; $ok = $false
        for ($j = $i + 1; $j -lt $code.Count -and $code[$j] -ne ')'; $j++) { if ($code[$j] -match $Exit) { $ok = $true } }
        if (-not $ok) { return 0 }
    }
    return $hits
}

# 1. Every goto / call target resolves to a defined label.
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

        # Blank the payload of `powershell -Command "..."`: it is data for a child (:PowerBackup's
        # builds another .bat with its own labels). A `& goto` after the closing quote is still scanned.
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

# 2. boot.config has no duplicate keys.
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

# 3. example.preset uses only keys the validator recognizes (parsed from :PresetCheckLine).
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

    # Commented-out examples get uncommented, so each must be valid as it stands
    # ("# x=1   # note" uncomments into the value "1   # note"). Only key=value shapes are judged.
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

# 4. :CreateRegBackup verifies the export before declaring success.
Invoke-Test ':CreateRegBackup checks errorlevel/existence before [OK]' {
    $cmd = Read-Lines $CmdPath
    $body = Get-RoutineBody -Lines $cmd -Label 'CreateRegBackup'
    $text = ($body -join "`n")

    Assert-True ($text -match '(?i)\[OK\]') ':CreateRegBackup has no [OK] message - routine changed shape?'
    Assert-True ($text -match '(?i)errorlevel')  'No errorlevel check in :CreateRegBackup - export success is not verified (regression of fix #2).'
    Assert-True ($text -match '(?i)if not exist') 'No "if not exist" file check in :CreateRegBackup - a missing export would still report success (regression of fix #2).'
    Assert-True ($text -match '(?i)\[ERROR\]')   ':CreateRegBackup has no failure ([ERROR]) branch - it cannot report a failed backup (regression of fix #2).'
}

# 5. The Win32PrioritySeparation writes are one mutually exclusive choice.
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

# 6. :DoCleanupCore does not wipe the Prefetch folder.
Invoke-Test ':DoCleanupCore does not clear the Prefetch folder' {
    $cmd  = Read-Lines $CmdPath
    $body = Get-RoutineBody -Lines $cmd -Label 'DoCleanupCore'
    $bad = @($body | Where-Object { $_ -match '(?i)\bdel\b' -and $_ -match '(?i)Prefetch' })
    Assert-True ($bad.Count -eq 0) ("Prefetch is being deleted in :DoCleanupCore (placebo - regression of fix #4):`n         " + ($bad -join "`n         "))
}

# 7. DNS apply and reset report the real outcome, never an unconditional [OK].
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

# 8. :InstallAsarInto reports the backup that actually landed; Documents fallback kept.
Invoke-Test ':InstallAsarInto verifies which OpenAsar backup landed' {
    $cmd = Read-Lines $CmdPath
    $b = ((Get-RoutineBody -Lines $cmd -Label 'InstallAsarInto') -join "`n")
    Assert-True ($b -match '(?i)_bakloc')      ':InstallAsarInto no longer tracks which backup landed (regression - it would blindly claim the in-folder .bak again).'
    Assert-True ($b -match '(?i)BACKUP_DIR')   ':InstallAsarInto no longer writes the Documents-folder fallback backup (regression).'
    Assert-True ($b -match '(?i)if exist .*_localbak') ':InstallAsarInto does not check that the in-folder backup exists before reporting it (regression).'
}

# 9. No unescaped ')' inside a ( ) block closes it early.
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

# 10. :DoPowerCore duplicates Ultimate onto its canonical GUID, so clones never pile up.
Invoke-Test ':DoPowerPlanSwitch duplicates Ultimate onto its canonical GUID' {
    # The scheme switch moved from :DoPowerCore into :DoPowerPlanSwitch when the power
    # action gained a current-plan path; :DoPowerCore is now the compatible aggregate.
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'DoPowerPlanSwitch') -join "`n")
    Assert-True ($b -match '(?i)duplicatescheme\s+e9a42b02-d5df-448d-aa00-03f14749eb61\s+e9a42b02-d5df-448d-aa00-03f14749eb61') 'duplicatescheme lost its destination GUID - every run would create another Ultimate clone and setactive would keep falling back to High (regression).'
}

# 11. A failed OpenAsar download leaves no partial .asar behind to install.
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
        # Capture the exit code before anything runs: `del` resets errorlevel to 0, so a check after
        # it is dead, and a half-downloaded .asar whose delete was blocked got installed.
        Assert-True ($t -match '(?i)set "_dlrc=%errorlevel%"') (":$r no longer captures the download exit code before anything can clobber it (regression of F-E4).")
        Assert-True ($t -match '(?i)if not "%_dlrc%"=="0" del') (":$r no longer removes the partial file when the download failed (regression of F-E4).")
        Assert-True ($t -notmatch '(?i)if\s+errorlevel\s+1\s+del\b[\s\S]{0,120}?if\s+errorlevel\s+1') (":$r tests errorlevel again AFTER a del has already reset it - that second test can never fire (regression of F-E4).")
    }
}

# 12. Startup flips back up the prior state first and write via literal-safe SetValue.
Invoke-Test ':StartupWorker backs up the prior state before flipping' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'StartupWorker') -join "`n")
    Assert-True ($b -match '(?i)StartupApproved') ':StartupWorker no longer targets StartupApproved - routine changed shape?'
    Assert-True ($b -match 'Windows Registry Editor Version 5.00') ':StartupWorker no longer writes a .reg backup of the prior value (regression - flips would stop being undoable).'
    Assert-True ($b -match '(?i)SetValue') ':StartupWorker no longer writes via the literal-safe Registry SetValue.'
    Assert-True ($b.IndexOf('Windows Registry Editor Version 5.00') -lt $b.ToLower().IndexOf('setvalue')) ':StartupWorker writes the new value before the backup (regression - a failed backup would no longer protect the flip).'
}

# 13. :SafeRegAdd / :SafeRegDelete surface a failed write: [FAIL], _FAILS across endlocal.
Invoke-Test ':SafeRegAdd / :SafeRegDelete surface a failed write (no silent [OK])' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in '_sraApply', '_srdApply') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)endlocal\s*&\s*set\s*/a\s*_FAILS\s*\+=') ":$r does not carry its result into _FAILS across endlocal - a failed reg write is invisible to the caller (regression of Critical #1)."
        Assert-True ($t -match '(?i)\[FAIL\]') ":$r no longer prints an inline [FAIL] when the write fails - failures would be silent (regression of Critical #1)."
    }
}

# 14. :Summary consults _FAILS and has both an [OK] and a [WARN] branch.
Invoke-Test ':Summary gates the final line on _FAILS (has [OK] and [WARN] branches)' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'Summary') -join "`n")
    # require the real statements, not a rem-comment mention of them
    Assert-True ($b -match '(?i)%_FAILS%')             ':Summary does not consult %_FAILS% - it cannot tell success from failure (regression of Critical #1).'
    Assert-True ($b -match '(?im)^\s*echo\s+\[OK\]')   ':Summary has no "echo [OK]" branch - routine changed shape?'
    Assert-True ($b -match '(?im)^\s*echo\s+\[WARN\]') ':Summary has no "echo [WARN]" branch - a failed write would still read as success (regression of Critical #1).'
}

# 15. Registry actions reset _FAILS first and end through :Summary.
Invoke-Test 'Registry actions reset _FAILS and report via :Summary' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'DisableMitigations','EnableMitigations','NvmeFlags','DisableIPv6','GpuAmd','HagsOff','HagsOn','WuDrvOff','WuDrvOn','ProcPriority') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?i)set "_FAILS=0"') ":$r does not reset _FAILS before its writes - a stale count would mis-report (regression of Critical #1)."
        Assert-True ($t -match '(?i)call :Summary')  ":$r prints an unconditional status instead of routing through :Summary (regression of Critical #1)."
        Assert-True ($t -notmatch '(?i)echo\s+\[OK\]') ":$r still echoes an inline [OK] - it must gate that line on :Summary (regression of Critical #1)."
    }
    $all = ($cmd -join "`n")
    $sum = ([regex]::Matches($all, '(?i)call :Summary')).Count
    $rst = ([regex]::Matches($all, '(?i)set "_FAILS=0"')).Count
    Assert-True ($sum -eq 40) ("Expected exactly 40 :Summary call sites (update the count when an action is added or removed), found {0} - registry actions may have lost honest reporting (regression of Critical #1)." -f $sum)
    Assert-True ($rst -eq 33) ("Expected exactly 33 _FAILS resets (update the count when an action is added or removed), found {0} - a gated action may be missing its reset (regression of Critical #1)." -f $rst)
}

# 16. An empty preset value (key=) cannot crash :PresetCheckLine.
Invoke-Test 'Preset parser guards an empty value (no whole-script crash)' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'PresetCheckLine') -join "`n")
    Assert-True ($b -notmatch '%_v:~')      ':PresetCheckLine still uses an UNGUARDED %_v:~..% substring - an empty preset value crashes the entire script (regression of Critical #2).'
    Assert-True ($b -match '(?i)if defined _v\b') ':PresetCheckLine no longer guards the trailing-space strip with "if defined _v" - an empty value would abort the parse (regression of Critical #2).'
}

# 17. Elevation is honest: _ELEV on both paths, limited mode opt-in, :Summary says why.
Invoke-Test 'Non-elevated run is flagged via _ELEV and reported honestly' {
    $cmd = Read-Lines $CmdPath
    $all = ($cmd -join "`n")
    Assert-True ($all -match '(?im)^\s*if not errorlevel 1 \( set "_ELEV=1"') 'The admin probe no longer sets _ELEV=1 on the elevated path (regression of the elevation fix).'
    $aw = ((Get-RoutineBody -Lines $cmd -Label 'AdminWarn') -join "`n")
    Assert-True ($aw -match '(?i)set "_ELEV=0"')      ':AdminWarn no longer sets _ELEV=0 for the non-elevated path (regression).'
    Assert-True ($aw -notmatch '(?i)Continuing anyway') ':AdminWarn still silently continues ("Continuing anyway") instead of an explicit limited-mode opt-in (regression).'
    $awc = @(Get-BodyLines -Lines $cmd -Label 'AdminWarn' -NoEcho | ForEach-Object { $_.Trim() })
    $ia = -1; for ($i = 0; $i -lt $awc.Count; $i++) { if ($awc[$i].StartsWith('set /p "_lc=')) { $ia = $i; break } }
    Assert-True ($ia -ge 0 -and $awc[$ia + 1] -ceq 'if /i not "!_lc!"=="Y" exit /b') ':AdminWarn starts limited mode without the user saying yes - the answer is not checked right after the question.'
    $sm = ((Get-RoutineBody -Lines $cmd -Label 'Summary') -join "`n")
    Assert-True ($sm -match '(?i)%_ELEV%') ':Summary no longer tailors its [WARN] to the elevation state (_ELEV) (regression).'
}

# 18. :ApplyHosts aborts before overwriting when no hosts backup landed.
Invoke-Test ':ApplyHosts verifies a backup landed before overwriting the system hosts' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ApplyHosts') -join "`n").ToLower()
    Assert-True ($b -match '_hbak') ':ApplyHosts no longer tracks whether a hosts backup landed (regression - could overwrite with no backup).'
    $abortIdx = $b.IndexOf('!_hbak!"=="0"')
    $copyIdx  = $b.IndexOf('copy /y "!script_dir!hosts"')
    Assert-True ($abortIdx -ge 0) ':ApplyHosts has no "if no backup -> abort" guard on _hbak (regression - data-loss window).'
    Assert-True ($copyIdx  -ge 0) ':ApplyHosts no longer copies the bundled hosts over the system hosts - routine changed shape?'
    Assert-True ($abortIdx -lt $copyIdx) ':ApplyHosts overwrites the system hosts BEFORE confirming a backup landed (regression of the data-loss fix).'
    $ah = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ApplyHosts'
    Assert-True ((Test-BlockExit -Lines $ah -Open '^if exist "%_HOSTS%" if "!_hbak!"=="0" \($' -Exit '^goto MenuApps$') -eq 1) ':ApplyHosts no-backup gate no longer leaves the routine - it falls through to the overwrite (regression of the data-loss guard).'
}

# 19. :RestorePresetJson branches on the child's exit code, never a blind [OK].
Invoke-Test ':RestorePresetJson reports the real restore outcome (not an unconditional [OK])' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'RestorePresetJson_ask') -join "`n")
    Assert-True ($b -match '(?i)errorlevel')          ':RestorePresetJson_ask does not capture the restore child exit code (regression - cannot tell success from failure).'
    Assert-True ($b -match '(?i)_prrc')               ':RestorePresetJson_ask no longer branches on the child result (_prrc) - [OK] would be unconditional again (regression).'
    Assert-True ($b -match '(?im)^\s*echo \[WARN\]')  ':RestorePresetJson_ask has no [WARN] branch for a partial/failed restore (regression).'
    Assert-True ($b -match '(?im)^\s*echo \[ERROR\]') ':RestorePresetJson_ask has no [ERROR] branch for an unreadable backup (regression).'
}

# 20. :InstallAsarInto picks the Discord app-* folder by version, not by name sort.
Invoke-Test ':InstallAsarInto picks the Discord build by version, not ASCII name order' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'InstallAsarInto') -join "`n")
    Assert-True ($b -notmatch '(?i)dir /b /ad /o-n') ':InstallAsarInto still uses an ASCII "dir /o-n" sort for app-* - wrong build at a version digit-rollover (regression).'
    Assert-True ($b -match '(?i)Sort-Object')        ':InstallAsarInto no longer version-sorts the app-* folders (regression).'
    Assert-True ($b -match '(?i)\[version\]')         ':InstallAsarInto no longer parses folder names as [version] for the sort (regression).'
}

# 21. Per-value backups escape a quote in REG_SZ data instead of dropping it.
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

# 22. Per-value backup names use two %RANDOM%s, so one pass cannot overwrite a backup.
Invoke-Test 'Per-value backup filenames use %RANDOM%%RANDOM% (collision-resistant)' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'SafeRegAdd','SafeRegDelete') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '_%RANDOM%%RANDOM%\.reg') ":$r backup filename no longer uses %RANDOM%%RANDOM% - two values under one key can collide on a single %RANDOM% and lose a per-value backup (regression)."
    }
}

# 23. REG_SZ values are restored with Set-ItemProperty, not reg.exe from PowerShell.
Invoke-Test ':RestorePresetJson restores REG_SZ quote-safely (Set-ItemProperty, not reg add)' {
    $b = ((Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'RestorePresetJson_ask') -join "`n")
    Assert-True ($b -match '(?i)Set-ItemProperty')     ':RestorePresetJson no longer uses Set-ItemProperty for REG_SZ - reg.exe from PowerShell mangles embedded quotes and corrupts the restore (regression).'
    Assert-True ($b -match '(?i)Registry::HKEY_USERS') ':RestorePresetJson lost the hive short-name -> PSDrive path conversion needed by Set-ItemProperty (regression).'
}

# 24. :Run counts a nonzero exit only for a tracked action on a non-elevated run.
Invoke-Test ':Run counts failures only when tracked AND not elevated (no crying wolf)' {
    $cmd = Read-Lines $CmdPath
    $r = ((Get-RoutineBody -Lines $cmd -Label 'Run') -join "`n")
    Assert-True ($r -match '(?i)_RUNTRACK')      ':Run does not consult _RUNTRACK - best-effort cleanup deletes would be counted as failures (regression).'
    Assert-True ($r -match '(?i)%_ELEV%')        ':Run does not gate failure-counting on elevation (%_ELEV%) - it would cry wolf on benign elevated nonzero exits (regression).'
    Assert-True ($r -match '(?i)set /a _FAILS')  ':Run does not fold real failures into _FAILS - a Run-based action still cannot report honestly (regression).'
    $rc = @(Get-BodyLines -Lines $cmd -Label 'Run' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True (@($rc | Where-Object { $_ -ceq 'if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS+=1' }).Count -eq 1 -and @($rc | Where-Object { $_ -match '"%_ELEV%"=="1"' }).Count -eq 0) ':Run counts failures the wrong way round - it must count a nonzero exit only on an unelevated run (regression).'
    $s = ((Get-RoutineBody -Lines $cmd -Label 'Summary') -join "`n")
    Assert-True ($s -match '(?i)set "_RUNTRACK="') ':Summary no longer clears _RUNTRACK - tracking would leak into a later untracked action (e.g. cleanup) and cry wolf (regression).'
}

# 25. Run-based actions set _RUNTRACK and report through :Summary.
Invoke-Test 'Run-based actions track failures (_RUNTRACK) and report via :Summary' {
    $cmd = Read-Lines $CmdPath
    # GpuNvidia is not here: it disables its tasks by name (test 68) and bumps _FAILS itself.
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

# 26. A path holding an apostrophe crosses into PowerShell safely.
Invoke-Test 'Apostrophe-safe path hand-off via env vars (SteamLight + elevation)' {
    $cmd = Read-Lines $CmdPath

    $b = ((Get-RoutineBody -Lines $cmd -Label 'SteamLight') -join "`n")
    Assert-True ($b.Length -gt 0) ':SteamLight body empty - cannot verify apostrophe-safe path hand-off.'
    Assert-True ($b -match '(?i)set "PT_SLDIR=') ':SteamLight no longer stages the Steam path in PT_SLDIR before the shortcut PS call (regression).'
    Assert-True ($b -match '(?i)\$env:PT_SLDIR')  ':SteamLight no longer reads the Steam path from $env:PT_SLDIR - it interpolates it into the PS string, which an apostrophe in the path would break (regression).'

    # The elevation relaunch sits above the first label. Pin both halves: _SELFPATH captured
    # before the argument loop shifts %0, and PT_SELF so an apostrophe cannot break the literal.
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

# 27. :PresetBegin resets _FAILS, so each preset reports only its own writes.
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

# 28. Admin-only repair actions gate their status on elevation.
Invoke-Test 'Repair actions gate their status on elevation (not a blind [OK])' {
    $cmd = Read-Lines $CmdPath
    foreach ($r in 'SfcDism','WUReset','CompactWinSxS','MemCompress','StoreRepair') {
        $t = ((Get-RoutineBody -Lines $cmd -Label $r) -join "`n")
        Assert-True ($t -match '(?im)^\s*if "%_ELEV%"=="0"') ":$r no longer gates its result on elevation (%_ELEV%) - it prints a blind [OK] even when not elevated (regression)."
        Assert-True ($t -match '(?i)\[WARN\]') ":$r has no [WARN] branch for the not-elevated case (regression)."
    }
}

# 29. DISM and SFC stream their progress live through :RunLive.
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

# 30. Battery-hostile actions show :LaptopAdvisory before their first prompt.
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
        $want = @{ LaptopAdvisory = 'if /i not "%MACHINE%"=="laptop" goto _lapUv'; DesktopAdvisory = 'if /i not "%MACHINE%"=="desktop" goto :eof' }[$adv]
        Assert-True (@($b | Where-Object { $_.Trim() -ceq $want }).Count -eq 1) ":$adv gates on the wrong machine class - expected: $want"
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

# 31. System tools is wired into the main menu and routes to all three tools.
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

# 32. The PATH editor never invokes setx.
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

# 33. The PATH worker keeps REG_EXPAND_SZ and unexpanded %VAR% entries.
Invoke-Test 'PATH worker preserves REG_EXPAND_SZ (read raw, write ExpandString)' {
    $cmd = Read-Lines $CmdPath
    $pw = (Get-RoutineBody -Lines $cmd -Label 'PathWorker') -join "`n"
    Assert-True ($pw -match 'DoNotExpandEnvironmentNames') 'PATH worker does not read with DoNotExpandEnvironmentNames - %VAR% references would be lost.'
    Assert-True ($pw -match 'RegistryValueKind\]::ExpandString') 'PATH worker does not write ExpandString - PATH would be downgraded to REG_SZ.'
}

# 34. The PATH worker invokes the WM_SETTINGCHANGE broadcast, not just declares it.
Invoke-Test 'PATH worker broadcasts WM_SETTINGCHANGE on change' {
    $cmd = Read-Lines $CmdPath
    $pw = (Get-RoutineBody -Lines $cmd -Label 'PathWorker') -join "`n"
    Assert-True ($pw -match '(?i)SendMessageTimeout\(\[IntPtr\]0xffff\s*,\s*0x1A') 'PATH worker does not INVOKE SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, ...).'
}

# 35. PATH edits back the value up before writing.
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

# 36. The PATH backup must be a real backup.
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

# 37. No PATH backup, no PATH edit.
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

# 38. System-PATH edits are refused up front when not elevated.
Invoke-Test 'System PATH edit is gated on elevation' {
    $cmd = Read-Lines $CmdPath
    $gate = @($cmd | Where-Object { $_ -match '(?i)"%PT_PE_SCOPE%"=="machine"\s+if\s+"%_ELEV%"=="0"' })
    Assert-True ($gate.Count -ge 1) ':PathEditor_show does not gate machine-scope edits on _ELEV.'
}

# 39. The lock finder invokes the Restart Manager; no openfiles, no handle.exe.
Invoke-Test 'Lock finder uses Restart Manager, not openfiles/handle.exe' {
    $cmd = Read-Lines $CmdPath
    $lw = (Get-RoutineBody -Lines $cmd -Label 'LockWorker') -join "`n"
    Assert-True ($lw -match '(?i)::RmStartSession\(')      'LockWorker does not INVOKE RmStartSession.'
    Assert-True ($lw -match '(?i)::RmRegisterResources\(') 'LockWorker does not INVOKE RmRegisterResources.'
    Assert-True ($lw -match '(?i)::RmGetList\(')           'LockWorker does not INVOKE RmGetList.'
    # Get-RoutineBody returns ,$arr: concatenate the arrays, never collect them through a pipeline.
    $lfAll = ((Get-RoutineBody -Lines $cmd -Label 'LockFinder') + (Get-RoutineBody -Lines $cmd -Label 'LockFinder_ask') + (Get-RoutineBody -Lines $cmd -Label 'LockWorker')) -join "`n"
    Assert-True ($lfAll -notmatch '(?i)\bopenfiles\b') 'Lock finder uses openfiles (needs a global flag + reboot).'
    Assert-True ($lfAll -notmatch '(?i)handle\.exe')   'Lock finder shells out to handle.exe (external dependency).'
}

# 40. The lock finder refuses to close a critical process.
Invoke-Test 'Lock finder refuses to kill critical system processes' {
    $cmd = Read-Lines $CmdPath
    $lw = (Get-RoutineBody -Lines $cmd -Label 'LockWorker') -join "`n"
    Assert-True ($lw.Contains("`$crit=if(`$p.AppType -eq [PTR.AT]::Critical){'critical'}else{'normal'}")) 'LockWorker no longer maps RmCritical to "critical" - the declaration Critical=1000 alone protects nothing.'
    $ask = (Get-RoutineBody -Lines $cmd -Label 'LockFinder_ask') -join "`n"
    # indexes with _lfi - the VALIDATED copy of the user's pick - not raw set /p input
    Assert-True ($ask -match '(?i)_lfcrit\[%_lfi%\]!"=="critical"') ':LockFinder_ask does not block a close on a critical process.'
    Assert-True ($ask -match '(?i)set "_lfi=%_lfk%"') ':LockFinder_ask no longer copies the validated pick into _lfi - raw set /p input would be indexing inside blocks again.'
    Assert-True ($ask -match '(?i)BLOCKED') ':LockFinder_ask has no BLOCKED message for a critical process.'
    $askb = Get-RoutineBody -Lines $cmd -Label 'LockFinder_ask'
    Assert-True ((Test-BlockExit -Lines $askb -Open '^if /i "!_lfcrit\[%_lfi%\]!"=="critical" \($' -Exit '^goto LockFinder_ask$') -eq 1) ':LockFinder_ask prints BLOCKED but goes on to close the critical process anyway.'
}

# 41. Closing a lock holder is opt-in: one confirmed PID, via taskkill.
Invoke-Test 'Lock finder terminates one PID via taskkill, not RmShutdown' {
    $cmd = Read-Lines $CmdPath
    $lf = ((Get-RoutineBody -Lines $cmd -Label 'LockFinder') + (Get-RoutineBody -Lines $cmd -Label 'LockFinder_ask')) -join "`n"
    $lw = (Get-RoutineBody -Lines $cmd -Label 'LockWorker') -join "`n"
    Assert-True ($lf -match '(?i)taskkill /PID') 'Lock finder does not use taskkill /PID for the opt-in close.'
    Assert-True ($lf -match '(?i)Proceed\? \(Y/N\)') 'Lock finder close is not gated behind a Y/N confirm.'
    $lfc = @((Get-BodyLines -Lines $cmd -Label 'LockFinder_ask' -NoEcho) | ForEach-Object { $_.Trim() })
    $iy = [Array]::IndexOf($lfc, 'if /i not "!_lc!"=="Y" goto LockFinder_ask'); $ik = -1
    for ($i = 0; $i -lt $lfc.Count; $i++) { if ($lfc[$i].StartsWith('call :Run "taskkill /PID')) { $ik = $i; break } }
    Assert-True ($iy -ge 0 -and $ik -gt $iy -and $lfc[$iy - 1].StartsWith('set /p "_lc=')) 'Lock finder runs taskkill without checking the yes right after its question.'
    Assert-True (($lf + $lw) -notmatch 'RmShutdown') 'Lock finder calls RmShutdown - it must close one chosen PID only.'
}

# 42. Both System-tools workers clear their PT_* hand-off variables.
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

# 43. Windows AI is off by policy: Copilot in both scopes, Recall, Click to Do.
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

# 44. Input and speech personalization are off in every scope.
Invoke-Test ':DoPrivacyCore disables inking/typing/speech personalization' {
    $cmd = Read-Lines $CmdPath
    $pc = (Get-RoutineBody -Lines $cmd -Label 'DoPrivacyCore') -join "`n"
    Assert-True ($pc -match '(?i)"HKCU\\SOFTWARE\\Policies\\Microsoft\\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0') 'HKCU AllowInputPersonalization=0 missing.'
    Assert-True ($pc -match '(?i)"HKLM\\SOFTWARE\\Policies\\Microsoft\\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0') 'HKLM AllowInputPersonalization=0 missing.'
    Assert-True ($pc -match '(?i)"RestrictImplicitTextCollection" REG_DWORD 1') 'RestrictImplicitTextCollection=1 missing.'
    Assert-True ($pc -match '(?i)"HarvestContacts" REG_DWORD 0') 'HarvestContacts=0 missing.'
    Assert-True ($pc -match '(?i)OnlineSpeechPrivacy" "HasAccepted" REG_DWORD 0') 'Online speech HasAccepted=0 missing.'
}

# 45. The Privacy screen says Home and Pro cannot go below Basic telemetry.
Invoke-Test 'Privacy screen discloses the Home/Pro telemetry floor' {
    $cmd = Read-Lines $CmdPath
    $pv = (Get-RoutineBody -Lines $cmd -Label 'Privacy') -join "`n"
    Assert-True ($pv -match '(?i)Home/Pro') 'Privacy banner does not mention the Home/Pro editions.'
    Assert-True ($pv -match '(?i)Basic \(1\)') 'Privacy banner does not state the Basic (1) floor.'
    Assert-True ($pv -match '(?i)Enterprise') 'Privacy banner does not say which editions honor 0.'
}

# 46. The Privacy screen says stopping DiagTrack also stops Xbox achievements and Feedback Hub.
Invoke-Test 'Privacy screen discloses the DiagTrack Xbox/Feedback Hub side effect' {
    $cmd = Read-Lines $CmdPath
    $pv = (Get-RoutineBody -Lines $cmd -Label 'Privacy') -join "`n"
    Assert-True ($pv -match '(?i)Xbox achievement') 'Privacy banner does not disclose the Xbox achievements side effect.'
    Assert-True ($pv -match '(?i)Feedback Hub') 'Privacy banner does not disclose the Feedback Hub side effect.'
}

# 47. The SysMain prompt shows the disk advisory first, and the advisory only warns.
Invoke-Test 'SysMain knob: disk probed, advisory warning-only and pre-prompt' {
    $cmd = Read-Lines $CmdPath

    # Code only - the routine's comment names Get-PhysicalDisk/Get-Partition to explain
    # why they are NOT the primary, so a body-wide match would assert against prose.
    $probeBody = Get-RoutineBody -Lines $cmd -Label 'DetectSysDisk'
    $probe = @($probeBody | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"

    Assert-True ($probe -match '(?i)set "SYSDISK=unknown"') ':DetectSysDisk no longer defaults SYSDISK=unknown - a failed probe must not masquerade as a known disk.'
    Assert-True ($probe -match '(?i)if defined SYSDISK goto :eof') ':DetectSysDisk lost its cache guard - it would relaunch PowerShell on every visit.'

    # The primary must be the seek-penalty IOCTL: the Storage CIM namespace failed for every
    # cmdlet on real hardware while the IOCTL answered.
    Assert-True ($probe -match '\[PTDisk\.N\]::DeviceIoControl\(') ':DetectSysDisk no longer INVOKES the seek-penalty IOCTL (the P/Invoke declaration alone proves nothing) - it would be back to depending on the Storage CIM namespace, which a single broken vendor provider takes down.'
    Assert-True ($probe -match '\[PTDisk\.N\]::CreateFile\(')      ':DetectSysDisk no longer opens the volume handle the IOCTL needs.'
    Assert-True ($probe -match '0x2D1400')          ':DetectSysDisk lost IOCTL_STORAGE_QUERY_PROPERTY (0x2D1400).'
    Assert-True ($probe -match '\$q\.PropertyId=7') ':DetectSysDisk no longer queries StorageDeviceSeekPenaltyProperty (PropertyId 7) - the actual SSD-vs-spinning question.'

    # Polarity: a seek penalty IS a spinning disk. Inverted, SSD owners would be told to keep SysMain.
    Assert-True ($probe -match 'if\(\$d\.IncursSeekPenalty\)\{ \$t=''hdd'' \}else\{ \$t=''ssd'' \}') ':DetectSysDisk has the seek-penalty mapping backwards or reworded - a seek penalty means a spinning disk (hdd); no penalty means ssd.'

    # Pin the chain that failed in the field (Get-Partition|Get-Disk|Get-PhysicalDisk), not a cmdlet.
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

# 48. CPU power throttling and Delivery Optimization peer sharing are wired in.
Invoke-Test 'Power-throttling and Delivery-Optimization knobs write reversible policy' {
    $cmd = Read-Lines $CmdPath

    $pw = (Get-RoutineBody -Lines $cmd -Label 'Power') -join "`n"
    Assert-True ($pw -match '(?i)call :SafeRegAdd "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerThrottling" "PowerThrottlingOff" REG_DWORD 1') ':Power lost the CPU power-throttling knob (or it stopped using :SafeRegAdd, losing the backup).'

    $na = (Get-RoutineBody -Lines $cmd -Label 'NetworkApply') -join "`n"
    Assert-True ($na -match '(?i)call :SafeRegAdd "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization" "DODownloadMode" REG_DWORD 0') ':NetworkApply lost the Delivery Optimization knob (or it stopped using :SafeRegAdd, losing the backup).'
}

# 49. Extra telemetry tasks are disabled by name, with their full folder path.
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

# 50. The DiagTrack firewall block flips Windows' own built-in rule group.
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

# 51. The declined tweaks stay declined.
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

# 52. Cleanup deletes can never fire on a collapsed path.
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

    # Every delete that interpolates a variable is gated; profile deletes go through :RunVar (134).
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

# 53. :CleanRoot approves only a root that is set, a real folder and not a drive root.
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
    foreach ($g in '^if not defined _crv \($', '^if not exist "!_crv!\\" \($', '^if "!_crv:~3!"=="" \($') {
        Assert-True ((Test-BlockExit -Lines $b -Open $g -Exit '^goto :eof$') -eq 1) (':CleanRoot reports a refusal but goes on to approve the root: ' + $g)
    }
    # run it: unset, missing, a drive root and a real folder; only the last is approved
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt053_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path (Join-Path $dir 'real'))
    try {
        $vals = @('', (Join-Path $dir 'missing'), ($env:SystemDrive + '\'), (Join-Path $dir 'real'))
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $vals.Count; $c++) { $drv += @(('set "FOO=' + $vals[$c] + '"'), 'set "_cleanFOO="', "echo [CASE#$c]", 'call :CleanRoot FOO', 'if defined _cleanFOO (echo [APPROVED]) else (echo [REFUSED])') }
        $drv += @('echo [END]', 'exit /b 0', ':CleanRoot') + @($b) + @(':Log', 'goto :eof', ':LogVar', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 53: the driver failed: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $vals.Count
        $got = @($sec | ForEach-Object { if ($_ -match '\[APPROVED\]') { 'A' } else { 'R' } }) -join ''
        Assert-True ($got -ceq 'RRRA') (':CleanRoot approved the wrong roots (unset, missing, drive root, real folder = ' + $got + ', expected RRRA) - a drive root reaching del /s is the case this guard exists for.')
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 54. Nothing multi-step may depend on a bundled file.
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

# 55. User input is never percent-expanded inside a ( ) block.
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

# 56. Win32PrioritySeparation values match their labels.
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

# 57. CPU-mitigation values set the right bits and cover them with the mask.
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

# 58. :Summary never expands %~1 inside a ( ) block.
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

    # Echo the phrase late (!_sumtext!), never %~1: an "&" in it (an .exe name) split the line and ran.
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

# 59. The doc-verified additions stay present and correct.
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
    $noteCode = @(Get-BodyLines -Lines $cmd -Label 'VerboseStatusNote' -NoEcho) -join "`n"
    Assert-True ($noteCode -match '(?i)reg query "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v "DisableStatusMessages"') ':VerboseStatusNote no longer reads DisableStatusMessages - the override caveat is gone.'
}

# 60. :SafeRegAdd skips the backup and the write when the value already matches.
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

# 61. No backup, no registry write: per value, and per preset JSON.
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
        # Measure order on the rem-stripped view: a comment mentioning "reg add" would come first.
        $gateAt = $code.IndexOf('if not exist "!_bkp!"')
        $writeAt = if ($r -eq 'SafeRegAdd') { $code.IndexOf('reg add') } else { $code.IndexOf('reg delete') }
        Assert-True ($gateAt -ge 0 -and $writeAt -gt $gateAt) ":$r backup-existence gate is not before the live registry write (regression)."
        Assert-True ($code.Length -gt 0) ":$r code view empty after stripping echo/rem."
        $exitRe = '^endlocal & set /a _FAILS\+=1 & exit /b 1$'
        Assert-True ((Test-BlockExit -Lines $body -Open '^if not exist "!_bkp!" \($' -Exit $exitRe) -eq 1) ":$r reports a missing backup but writes anyway - the abort after the [FAIL] is gone."
        Assert-True ((Test-BlockExit -Lines $body -Open '^if not exist "!PRESET_JSON_TMP!" \($' -Exit $exitRe) -eq 1) ":$r reports a missing preset backup but writes anyway."
        $ct = @($body | ForEach-Object { $_.Trim() })
        $iw = [Array]::IndexOf($ct, 'call :_BakWrite 2>nul'); $id = [Array]::IndexOf($ct, 'if !_bkn! LSS 4 del "!_bkp!" >nul 2>&1'); $ig = [Array]::IndexOf($ct, 'if not exist "!_bkp!" (')
        Assert-True ($iw -ge 0 -and $id -gt $iw -and $ig -gt $id) ":$r no longer writes its backup through :_BakWrite and drops a backup with no value line before the exist check."
    }
}

# 62. :ResetHostsDefault requires a landed hosts.bak before overwriting.
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

# 63. :PresetBegin verifies its JSON temp landed; every caller honours a failed begin.
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

# 64. :RestoreHostsBak falls back to the Documents snapshot.
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

# 65. The timer-resolution registry writes report through _FAILS and :Summary.
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

# 66. SteamLight confirms the Desktop shortcut landed before claiming it.
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
    # Capture before `set "PT_SLDIR="`: in a .cmd a successful set resets errorlevel to 0.
    $iCap = ($body | Select-String -SimpleMatch 'set "_slrc=%errorlevel%"' | Select-Object -First 1)
    $iClr = ($body | Select-String -SimpleMatch 'set "PT_SLDIR="' | Select-Object -First 1)
    Assert-True ($null -ne $iCap -and $null -ne $iClr -and $iCap.LineNumber -lt $iClr.LineNumber) ':SteamLight reads the shortcut exit code after the PT_SLDIR cleanup set, which clears it in a .cmd file (regression).'
    Assert-True ($joined -match '\[WARN\].*shortcut') ':SteamLight lost its [WARN] when the Desktop shortcut fails (regression).'
    # Desktop claim must share the success branch with the errorlevel gate, not stand alone.
    Assert-True ($joined -match 'if not "%_slrc%"=="0"[\s\S]{0,400}shortcut was placed on your Desktop') ':SteamLight Desktop-shortcut [OK] is no longer gated on the shortcut PS exit code (regression).'
}

# 67. Disabling memory compression counts its failures, in the menu and in presets.
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

# 68. NVIDIA telemetry tasks are found by name prefix; the driver-update check is left alone.
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

# 69. The Windows 11 quiet-surface keys are in the privacy core.
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

# 70. Game Bar leftovers are opt-in, never in the performance core.
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

# 71. Edge nudges are opt-in and use documented Edge policy values only.
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

# 72. The cleanup core's buckets; Prefetch still out; free space reported.
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

# 73. Interactive Cleanup: optional buckets, tool launches, free-space report.
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
    $cc = @($body | ForEach-Object { $_.Trim() })
    foreach ($t in @(@('_rb', '_clRbDone', '^start "" /min /wait powershell -NoProfile -Command ".*\bClear-RecycleBin -Force\b'),
                     @('_cm', '_clCmDone', '^start "" cleanmgr\.exe /d %_drv%$'), @('_ss', '_clSsDone', '^start "" ms-settings:storagesense$'))) {
        $ig = [Array]::IndexOf($cc, ('if /i not "!{0}!"=="Y" goto {1}' -f $t[0], $t[1])); $il = [Array]::IndexOf($cc, (':' + $t[1])); $ix = -1
        for ($i = 0; $i -lt $cc.Count; $i++) { if ($cc[$i] -match $t[2]) { $ix = $i } }
        Assert-True ($ig -ge 0 -and $ix -gt $ig -and $il -gt $ix) (':Cleanup no longer launches the ' + $t[1] + ' tool between its question and its label - a log line or prompt text would still satisfy a name match.')
    }
}

# 74. Free-space helpers exist, and Status shows the disk and the newer tweaks.
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

# 75. Cleanup deletes stay behind CleanRoot-proven flags.
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


# 76. The beside-the-file hosts.bak is write-once.
Invoke-Test ':ApplyHosts keeps the pristine hosts.bak (write-once) + randomized doc snapshot' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ApplyHosts'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':ApplyHosts body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "%_HOSTS%\.bak" copy /y') ':ApplyHosts copies over hosts.bak unconditionally again - a re-run buries the true original (regression of F1).'
    Assert-True ($code -match '(?i)hosts_%RANDOM%%RANDOM%\.bak')          ':ApplyHosts doc snapshot is no longer randomized (regression of F1).'
    Assert-True ($code -match '(?i)_hbak!"=="0"')                          ':ApplyHosts lost its no-backup abort gate (regression of the data-loss guard).'
}

# 77. :ResetHostsDefault is write-once too and keeps a Documents snapshot.
Invoke-Test ':ResetHostsDefault is write-once and writes a Documents snapshot' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'ResetHostsDefault'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':ResetHostsDefault body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "%_HOSTS%\.bak" copy /y') ':ResetHostsDefault overwrites the pristine hosts.bak again (regression of F1).'
    Assert-True ($code -match '(?i)hosts_%RANDOM%%RANDOM%\.bak')          ':ResetHostsDefault no longer writes a Documents snapshot (regression of F1).'
}

# 78. OpenAsar backups are write-once, and no backup means no write.
Invoke-Test ':InstallAsarInto backups are write-once and gate the install' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'InstallAsarInto'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':InstallAsarInto body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "!_localbak!" copy /y') ':InstallAsarInto overwrites the local .bak again - a re-run backs up OpenAsar over the stock asar (regression of F1).'
    Assert-True ($code -match '(?i)if not exist "!_docbak!"\s+copy /y')  ':InstallAsarInto overwrites the Documents .bak again - the asar has no randomized fallback, so both copies die (regression of F1).'
    Assert-True ($code -match 'set "_docbak=!BACKUP_DIR!\\%_flav%_!_appdir!_!_target!\.bak"' -and $code -match 'set "_appdir=%%A"') ':InstallAsarInto names its backup-folder copy without the Discord version - the write-once copy would stay the first version ever seen, and a revert would put an old asar into a new app folder.'
    $gate = $code.IndexOf('if "!_hadorig!"=="1" if not defined _bakloc')
    # _asrc, not _src: the callers hold the same path in _SRC and cmd names are
    # case-insensitive, so the old name was literally the same variable (test 118)
    $write = $code.IndexOf('copy /y "!_asrc!"')
    Assert-True ($gate -ge 0)             ':InstallAsarInto lost the "no backup landed -> refuse" gate (regression of F4).'
    Assert-True ($write -ge 0)            ':InstallAsarInto install copy not found - routine changed shape?'
    Assert-True ($gate -lt $write)        ':InstallAsarInto gate no longer precedes the install copy - it overwrites first (regression of F4).'
}

# 79. :UnityBoot's boot.config.bak is write-once, and no backup means no write.
Invoke-Test ':UnityBoot backs up boot.config write-once and aborts without one' {
    $body = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'UnityBoot'
    $body = @($body)
    Assert-True ($body.Count -gt 0) ':UnityBoot body empty.'
    $code = @($body | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -match '(?i)if not exist "boot\.config\.bak" copy /y') ':UnityBoot copies over boot.config.bak unconditionally again (regression of F1).'
    Assert-True ($code -match '(?i)_ubbak!"=="0"')                              ':UnityBoot lost its no-backup abort gate (regression of F4).'
    Assert-True ((Test-BlockExit -Lines $body -Open '^if exist "boot\.config" if "!_ubbak!"=="0" \($' -Exit '^goto MenuApps$') -eq 1) ':UnityBoot no-backup gate no longer leaves the routine - it falls through to the overwrite (regression of F4).'
    $joined = $body -join "`n"
    Assert-True ($joined -notmatch '(?i)^echo\s+Old file') ':UnityBoot claims the .bak unconditionally again (regression of the false-success fix).'
}

# 80. :StartupWorker confirms the undo .reg landed before it flips an entry.
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
    $gm = [regex]::Match($joined, 'if\(-not \(Test-Path -LiteralPath \$bak\)\)\{[^}]*;\s*exit 1 \}')
    Assert-True ($gm.Success -and $gm.Index -lt $set) ':StartupWorker reports a missing undo backup but flips the entry anyway - the exit 1 is gone.'
}

# 81. The OneDrive file-sync block is opt-in, never in the privacy core.
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

# 82. The Privacy screen names everything the core changes beyond telemetry.
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


# 83. Every action that tracks _FAILS also sets _RUNTRACK.
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

# 84. OpenAsar tallies failures per flavor and deletes the downloaded nightly.
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

# 85. The Status hosts line prints only when the file exists.
Invoke-Test ':Status hosts line is guarded on the file existing' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'Status'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':Status body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($code -match '(?i)if exist "%_hostsf%" for /f') ':Status runs the hosts line count unguarded again - a missing hosts prints an empty section (regression of F8).'
    Assert-True ($code -match '(?i)if not defined _hlines echo')  ':Status has no fallback line when the hosts count could not be taken (regression of F8).'
}

# 86. DisableStatusMessages is read numerically.
Invoke-Test ':VerboseStatusNote compares DisableStatusMessages numerically' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'VerboseStatusNote'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':VerboseStatusNote body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($code -notmatch '(?i)findstr /I /C:"0x1"') ':VerboseStatusNote is substring-matching "0x1" again - 0x10/0x1a would read as enabled (regression of F9).'
    Assert-True ($code -match '(?i)set /a _dsmval')          ':VerboseStatusNote no longer parses the value with set /a (regression of F9).'
    Assert-True ($code -match '(?i)if not "!_dsmval!"=="0" set "_dsmon=1"') ':VerboseStatusNote no longer treats any nonzero value as the override being in force (regression of F9).'
}

# 87. :BackupSingleValue maps all five hives, matching :SafeRegAdd.
Invoke-Test ':BackupSingleValue maps all five hives like :SafeRegAdd' {
    $b = Get-RoutineBody -Lines (Read-Lines $CmdPath) -Label 'BackupSingleValue'
    $b = @($b)
    Assert-True ($b.Count -gt 0) ':BackupSingleValue body empty.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    foreach ($h in 'HKEY_LOCAL_MACHINE','HKEY_CURRENT_USER','HKEY_CLASSES_ROOT','HKEY_USERS','HKEY_CURRENT_CONFIG') {
        Assert-True ($code -match [regex]::Escape($h)) ":BackupSingleValue no longer maps $h - reg export would get a short-name key it cannot resolve (regression of F10)."
    }
}


# 88. The power action is split by scope: the scheme switch vs the active scheme's settings.
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
    # _PWPLAN is an input: the fallback goes into _pwsel. Writing the global made one pass's
    # default stick for the rest of the session.
    $swCode = @((Get-RoutineBody -Lines $cmd -Label 'DoPowerPlanSwitch') | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($swCode -notmatch '(?i)set "_PWPLAN=') ':DoPowerPlanSwitch writes back to _PWPLAN - the fallback would persist for the rest of the session and steer later actions that never asked for a plan (regression of F-A2).'
    Assert-True ($swCode -match '(?i)set "_pwsel=%_PWPLAN%"') ':DoPowerPlanSwitch no longer reads the requested plan into a local (regression of F-A2).'
    Assert-True ($sw -match '(?i)381b4222-f694-41f0-9685-ff5bb260df2e') ':DoPowerPlanSwitch no longer knows the Balanced GUID (regression).'
    Assert-True ($sw -match '(?i)8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') ':DoPowerPlanSwitch no longer knows the High Performance GUID (regression).'
}

# 89. Declining the plan switch does not end the power action.
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
    # The advisory lines are conditional echoes, so match any echo line - but drop rem: the
    # routine's comments discuss the subject and would satisfy this on their own.
    $echoes = (@($b | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)\becho\b' }) -join "`n")
    Assert-True ($echoes -match '(?i)undervolt') ':Power no longer warns a laptop that a plan jump is where a stable undervolt fails - that is a real WHEA 0x124 on real hardware, not a theoretical caveat (regression).'
    Assert-True ($echoes -match '(?i)MACHINE|battery-powered') ':Power lost the machine-aware framing on the plan warning (regression).'
}

# 90. power_timeouts applies the timeouts alone and never runs twice with power=1.
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


# 91. The power action writes its undo file before it changes anything.
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
    # A value the scheme never stored must still be restorable: per-scheme value -> plan default ->
    # value in effect -> a comment. powercfg /query is read as HEX, never its localized labels.
    Assert-True ($pb -match '(?i)DefaultPowerSchemeValues') ':PowerBackup no longer falls back to the plan default, so a setting the scheme never stored would go unrestored (regression).'
    Assert-True ($pb -match '0x\[0-9a-fA-F\]\{8\}') ':PowerBackup no longer reads the effective value as hex - on a custom or OEM plan there is neither a stored value nor a plan default, so that setting would go unrestored (regression).'
    Assert-True ($pb -match '(?i)could not be read at backup time') ':PowerBackup no longer honest-declines when nothing can be read at all - it would emit a guessed restore line (regression).'
    # PROCTHROTTLEMIN is reachable on its own, so it needs its own undo line.
    Assert-True ($pb -match '(?i)893dee8e-2bef-41e0-89c6-b55d0929964c') ':PowerBackup no longer captures PROCTHROTTLEMIN - the minimum-processor-state prompt would imply an undo it does not have (regression).'
    # A partial run is the realistic failure here: the machine crashed part-way through the
    # restore and never reached -setactive, so the plan stayed switched. It goes back FIRST.
    $first = $pb.IndexOf('powercfg -setactive')
    $write = $pb.IndexOf('-setacvalueindex')   # the flag now comes from a table, not a literal
    Assert-True ($first -ge 0 -and $write -ge 0) ':PowerBackup undo file lost its setactive / value writes (regression).'
    Assert-True ($first -lt $write) ':PowerBackup undo file re-activates the scheme only AFTER the value writes - a run that stops part-way leaves the plan switched (regression).'
    $reactivations = ([regex]::Matches($pb, '(?i)powercfg -setactive')).Count
    Assert-True ($reactivations -ge 2) ':PowerBackup undo file no longer re-activates the scheme after the writes - powercfg needs that for changed values to take effect (regression).'

    # The generated file follows the same honesty rule: every restore goes through a counting
    # helper, and EVERY emitted powercfg does (one replaced call site would leave this green).
    # The value-write flag comes from a table, so match up to "powercfg ", not a literal "-set".
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
        # Strip rem/echo first: :DoPowerTimeouts' own comment quotes "powercfg -change".
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

# 92. One power undo file per action, not per routine.
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

# 93. The power undo file is reachable from the menu.
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
    $rbList = @(Get-BodyLines -Lines $cmd -Label 'RestorePowerBackup' -NoEcho | ForEach-Object { $_.Trim() })
    Assert-True ($rbList -contains 'for /f "delims=" %%F in (''dir /b /a-d /od "%%BACKUP_DIR%%\PowerPlan_*.bat" 2^>nul'') do (' -and $rbList -contains 'for %%G in ("!BACKUP_DIR!\%%F") do set "_pdt[!_pn!]=%%~tG"') ':RestorePowerBackup no longer lists the PowerPlan_*.bat undo files oldest first with their dates - the top entry would restore a state sincript itself made.'
    # A child cmd, never `call`: a syntax error in a called file ends all batch processing (a broken
    # undo file closed sincript, test 126). /q suppresses the file's own pause.
    $rbCode = (@(Get-BodyLines -Lines $cmd -Label 'RestorePowerBackup' -CodeOnly) + @(Get-BodyLines -Lines $cmd -Label 'RestorePowerBackup_ask' -CodeOnly)) -join "`n"
    Assert-True ($rbCode -match '(?i)cmd /d /v:off /s /c ""%%_pfile%%" /q"') ':RestorePowerBackup no longer runs the chosen undo file in a child cmd with /q - `call`ed, a syntax error in it ends sincript too, and without /q its own pause blocks the menu (regression).'
    Assert-True ($rbCode -notmatch '(?i)\bcall\s+"?[%!]_pfile') ':RestorePowerBackup `call`s the undo file again - a syntax error in it would end sincript too (regression).'
}

# 94. AutoEndTasks is disclosed as a data-loss trade-off; Status shows the hardware probes.
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


# 95. The main-menu header probes the disk type before printing it.
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

# 96. Every menu separator renders the same width.
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


# 97. :DetectSysDisk caches its answer per machine, not per session.
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


# 98. The file's bytes: pure ASCII, uniform CRLF, no BOM.
Invoke-Test 'Shipped text files stay ASCII-only, uniform CRLF, no BOM' {
    # Every shipped file read on Windows, not just the script (example.preset once got bare LFs).
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

# 99. Every number a menu prints is a number it handles, and vice versa.
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

        # Dispatch is not always in :X_ask, nor always on %sel% (:PathEditor branches on %_pesc%):
        # scan both bodies and accept any "%<var>%"=="<n>".
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
    Assert-True ($checked -eq 15) ("$checked static menu(s) were checked, not 15 (update the count when a menu is added) - the detection broke and this test was passing vacuously.")
}

# 100. Every registry write goes through :SafeRegAdd / :SafeRegDelete.
Invoke-Test 'No registry write bypasses :SafeRegAdd / :SafeRegDelete' {
    $cmd = Read-Lines $CmdPath
    $offenders = New-Object System.Collections.Generic.List[string]
    $total = 0
    $echoOnly = '(?i)^\s*((if\s+.*?\s+)?echo\b|call :Log(Var)?\b)'
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $l = $cmd[$i].Trim()
        if ($l -match '^(?i)rem\b') { continue }
        if ($l -match $echoOnly -and ($l -replace '\^.', '') -notmatch '[&|<>]') { continue }   # text, not a call
        $hit = $l -match '(?i)\breg(\.exe)?\s+(add|delete|import|copy|save|restore|load|unload)\b' -or $l -match '(?i)set\s+"?\w+=reg(\.exe)?\s'
        if (-not $hit) { continue }
        $total++
        $owner = '<none>'
        for ($j = $i; $j -ge 0; $j--) { if ($cmd[$j] -match '^:(\w+)') { $owner = $Matches[1]; break } }
        $ok = ($owner -eq '_sraApply' -and $l -match '^reg add "!_key!"') -or ($owner -eq '_srdApply' -and $l -match '^reg delete "!_key!"') -or
              ($owner -eq 'RestoreRegBackup_ask' -and $l -match '^reg import "!_qfile!"') -or
              ($owner -eq 'RestorePresetJson_ask' -and $l -match '^start "" /min /wait powershell ' -and $l -match 'reg delete \$it\.key')
        if (-not $ok) { $offenders.Add(("L{0} in :{1}: {2}" -f ($i+1), $owner, $l)) }
    }
    Assert-True ($total -eq 4) "Expected the 2 wrapper writes, the .reg import and the preset-JSON restore worker, found $total registry writer line(s) - see the offenders."
    Assert-True ($offenders.Count -eq 0) ("Registry write outside the backed-up wrappers - no undo file, no [FAIL], no _FAILS tally: " + (($offenders | Select-Object -First 3) -join ' | '))
}

# 101. A typed DNS resolver is validated before it reaches a command line.
Invoke-Test 'Custom DNS input is validated before it reaches a command line' {
    $cmd = Read-Lines $CmdPath
    $v = Get-RoutineBody -Lines $cmd -Label '_ip4_ok'
    $v = @($v)
    Assert-True ($v.Count -gt 0) ':_ip4_ok is missing.'
    $vc = @($v | Where-Object { $_.Trim() -notmatch '^(?i)(echo\(|rem)\b' }) -join "`n"
    # No PIPE: cmd builds each side's child command line from expanded text, so "echo(!v!| findstr"
    # ran an injected "&" remainder and then validated a clean value.
    Assert-True ($vc -notmatch '(?i)echo\(?!_IPCHK!\s*\|') ':_ip4_ok pipes the value into findstr again - the piped child re-parses it, so "1.1.1.1&command" executes the command and still validates (regression of F-J1).'
    # The eol= is part of the check: eol defaults to ";", so "1.1.1.1;<anything>" gave no token
    # and validated clean. It must be one of the allowed characters.
    Assert-True ($vc -match '(?i)for /f "eol=[0-9] delims=0123456789\." %%X in \("!_IPCHK!"\)') ':_ip4_ok lost its pipe-free charset check, or the eol= that closes the ";" hole (regression of F-J1).'
    Assert-True ($vc -match '(?i)if not "%%d"==""') ':_ip4_ok no longer requires a fourth octet - a missing token expands to empty, so "1.2.3." rebuilds to itself and passes (regression of F-J1).'
    # All four octets (dropping one leaves the rest matching), LEQ 255, after the shape check.
    $oct = ([regex]::Matches($vc, '(?i)LEQ 255')).Count
    Assert-True ($oct -eq 4) "::_ip4_ok range-checks $oct octet(s), not 4 - the unchecked position accepts anything up to 999 (regression)."

    $d = Get-RoutineBody -Lines $cmd -Label 'DnsCustom'
    $d = @($d)
    Assert-True ($d.Count -gt 0) ':DnsCustom is missing.'
    $dc = @($d | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    # both prompts validated, and every use late-expanded so a metacharacter stays literal
    $checks = ([regex]::Matches($dc, '(?i)call :_ip4_ok')).Count
    Assert-True ($checks -ge 2) "::DnsCustom validates fewer than both resolvers ($checks) - the unchecked one reaches PowerShell (regression)."
    $dcb = Get-RoutineBody -Lines $cmd -Label 'DnsCustom'
    Assert-True ((Test-BlockExit -Lines $dcb -Open '^call :_ip4_ok \|\| \($' -Exit '^goto DnsCustom$') -eq 2) ':DnsCustom validates a resolver but carries on with an invalid one - each failed check must return to the prompt.'
    Assert-True ($dc -notmatch '%_dns1%' -and $dc -notmatch '%_dns2%') ':DnsCustom expands a typed resolver with %% instead of !! - cmd would parse & | < > in it as operators at parse time (regression).'
    Assert-True ($dc -match "(?i)DNSSRV='!_dns1!'") ':DnsCustom no longer builds DNSSRV from the validated value (regression).'

    # the preset door has to use the same validator, or it becomes the way round the menu
    $pk = ((Get-RoutineBody -Lines $cmd -Label 'PChkDns') -join "`n")
    Assert-True ($pk -match '(?i)call :_ip4_ok && \( set "_P_DNS=!_v!"' -and $pk -match '(?i)set /a _perr\+=1') 'Preset key dns does not act on the validator: a literal address must be stored only when :_ip4_ok passes, and counted as an error otherwise (regression).'
    $pn = ((Get-RoutineBody -Lines $cmd -Label 'PresetDnsByName') -join "`n")
    Assert-True ($pn -match '(?i)set "DNSSRV="') ':PresetDnsByName does not clear DNSSRV first - a stale list from an earlier call would be applied instead (regression).'

    # flushing the cache is its own action, not something only a full stack reset can do
    $f = Get-RoutineBody -Lines $cmd -Label 'FlushDns'
    $f = @($f)
    Assert-True ($f.Count -gt 0) ':FlushDns is missing.'
    $fc = @($f | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' }) -join "`n"
    Assert-True ($fc -match '(?i)call :Run "ipconfig /flushdns"') ':FlushDns no longer flushes (regression).'
    Assert-True ($fc -match '(?i)call :Summary')                  ':FlushDns reports without :Summary, so a failure could print as success (regression).'

    # The current-resolver line stays a registry read, not localized netsh text. Strip rem first:
    # the comment explaining why "show dnsservers" is avoided would satisfy the negative check.
    $sAll = Get-RoutineBody -Lines $cmd -Label 'ShowCurrentDns'
    $sAll = @($sAll)
    Assert-True ($sAll.Count -gt 0) ':ShowCurrentDns is missing.'
    $s = @($sAll | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"
    Assert-True ($s -match '(?i)Tcpip\\Parameters\\Interfaces') ':ShowCurrentDns no longer reads the interface keys (regression).'
    Assert-True ($s -notmatch '(?i)show dnsservers') ':ShowCurrentDns parses localized netsh output - it would show nothing on a translated Windows and read as "no DNS set" (pitfall 26 regression).'
}

# 102. One custom preset's keys never carry into the next in the same session.
Invoke-Test 'Every preset directive the validators set is cleared before a preset runs' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    # Names the validators can define: `call :PVok NAME` and literal _P_NAME writes; the dynamic
    # `set "_P_%~1=1"` and the reset loop cannot match (% is outside the class).
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

# 103. A preset never inherits the plan picked on the Power menu (_PWPLAN).
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

    # :PresetCustom runs on through :PresetCustom_ask (a real label) before it applies anything,
    # so slice by file position, from :PresetCustom to the next real routine.
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

# 104. _RUNTRACK is cleared in :Summary only.
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

# 105. A called routine returns; it never jumps to a menu.
Invoke-Test 'A called routine returns - it never jumps to a menu (call-stack integrity)' {
    $cmd = Read-Lines $CmdPath

    # menu labels = the screens an action can legitimately goto, but a SUBROUTINE cannot
    $menu = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ln in $cmd) {
        if ($ln -match '^:((?:Main)?Menu\w*|ExitScript)\s*$') { [void]$menu.Add($Matches[1]) }
    }
    Assert-True ($menu.Count -ge 8) "Found only $($menu.Count) menu labels - this test would barely check anything."

    # Labels reached by `call`, limited to labels this file defines: :PowerBackup's "call :pt_do"
    # is text for the generated file (test 91).
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

# 106. The backup folder, the safety net for every tweak and the log, is handled safely.
Invoke-Test 'A missing backup folder is reported once, not shouted on every log line' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"

    Assert-True ($all -match '(?i)set "_BAKOK=0"') 'Startup no longer verifies that the backup folder was actually created - the md result was never checked (regression of F-C1).'
    $warnIdx = ($cmd | Select-String -SimpleMatch 'The backup folder could not be created')
    Assert-True (@($warnIdx).Count -ge 1) 'The unwritable-backup-folder warning is gone - actions would fail with no stated reason (regression of F-C1).'

    # the warning block prints a path that can legitimately contain ")", so it must be
    # late-expanded or the if-block closes early at parse time and the script dies
    Assert-True ($all -notmatch '(?m)^\s*echo\s+%BACKUP_DIR%\s*$') 'The warning echoes %BACKUP_DIR% percent-expanded - a Documents path containing ")" would close the if-block and crash the script at startup.'

    # A failed redirection is reported while cmd sets it up, so "2>nul" on the echo cannot hide it;
    # it must sit on a CALL. Keep :Log's write in its own routine.
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

# 107. Debloat says it is the one action with no undo.
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

# 108. A failed elevation says so.
Invoke-Test 'A failed self-elevation is reported, not a silently closing window' {
    $cmd = Read-Lines $CmdPath
    # window sized from the file, not a fixed 80 lines - the argument loop grew and pushed
    # the elevation block past a hardcoded bound, which read as "the relaunch is gone"
    $adminAt = ($cmd | Select-String -Pattern '^:AdminOK$' | Select-Object -First 1)
    Assert-True ($null -ne $adminAt) ':AdminOK is missing - the startup section was restructured.'
    $head = @($cmd[0..($adminAt.LineNumber - 1)] | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"

    Assert-True ($head -match '(?i)Start-Process') 'The self-elevation relaunch is gone.'
    Assert-True ($head -match '(?i)-Verb RunAs')   'The relaunch no longer requests elevation.'
    Assert-True (@($cmd[0..($adminAt.LineNumber - 1)] | Where-Object { $_ -match '(?i)Start-Process -FilePath \$env:PT_SELF' -and $_ -match '(?i)-ErrorAction Stop' }).Count -eq 1) 'Start-Process no longer uses -ErrorAction Stop, so a declined UAC prompt does not surface as a nonzero exit code (regression of F-C3).'
    Assert-True ($head -match '(?i)catch\{ exit 1 \}') 'The relaunch no longer converts a failure into an exit code (regression of F-C3).'
    Assert-True ($head -match '(?i)if not errorlevel 1 exit /b') 'The script exits unconditionally after attempting elevation, so the failure path is unreachable and stays silent (regression of F-C3).'
    Assert-True ($head -match '(?i)\[WARN\] The elevation prompt did not go through') 'A failed elevation no longer tells the user why the window is about to change behaviour (regression of F-C3).'
    Assert-True ($head -match '(?i)goto AdminWarn') 'A failed elevation no longer offers the limited-mode path that :AdminWarn already implements (regression of F-C3).'
}

# 109. Windows Update reset renames its folders, keeping a rollback.
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
    $pob = Get-RoutineBody -Lines $cmd -Label 'WUPruneOld'
    $poc = @($pob | ForEach-Object { $_.Trim() })
    Assert-True ((Test-BlockExit -Lines $pob -Open '^if /i not "!_wpc!"=="Y" \($' -Exit '^goto :eof$') -eq 1 -and [Array]::IndexOf($poc, 'if /i not "!_wpc!"=="Y" (') -lt [Array]::IndexOf($poc, 'set "PT_WP_MODE=delete"')) ':WUPruneOld deletes the leftovers whatever the answer - its decline branch no longer leaves before delete mode (regression of F-D1).'

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

# 110. Worker temp files carry %RANDOM%, and PT_* hand-off variables are cleared.
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

# 111. Two GPU vendors on one machine are both detected and handled.
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

# 112. Two input-robustness invariants.
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

    # set /a saturates an out-of-range variable at 2^31-1, so two large values would compare equal.
    $idem = ((Get-RoutineBody -Lines $cmd -Label 'SafeRegAdd') -join "`n")
    Assert-True ($idem -match '(?i)"!_curdec!"=="2147483647"') 'The DWORD idempotence check no longer detects set /a saturation, so two different values at or above 2^31 compare equal and the write is silently skipped (regression of F-E3).'
    Assert-True ($idem -match '(?i)if /i not "!_curtok!"=="!_data!" goto _sraDoWrite') 'The saturation fallback no longer compares the raw tokens as text (regression of F-E3).'
    # ...which only works if large values are written as hex, matching what reg query returns
    $all = $cmd -join "`n"
    Assert-True ($all -notmatch '(?i)REG_DWORD 4294967295') 'A large DWORD is written as decimal again; reg query returns hex, so the saturation fallback cannot match it and the value is re-written every run (regression of F-E3).'
}

# 113. Every menu prompt that re-asks itself has a way out.
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
        # The CYCLE must be bounded: from the target label to this jump the path passes :NoInput
        # (a guarded prompt) or :Logo (a redraw that resets the counter).
        $seg = $cmd[($lbl[0].LineNumber - 1)..$i] -join "`n"
        if ($seg -match '(?i)call :(Logo|NoInput)\b') { continue }
        $unguarded += ("line {0}: if not defined {1} goto {2}" -f ($i+1), $var, $tgt)
    }
    Assert-True ($unguarded.Count -eq 0) ("Self-repeating prompt(s) with no way out when stdin is empty - these spin at 100% CPU forever under redirected or closed stdin: {0} (regression of F-F1)." -f ($unguarded -join '; '))

    # and the courtesy pause must not announce its own failure on a non-interactive exit
    $bad = @($cmd | Select-String -Pattern '(?i)timeout /t \d+ >nul\s*$')
    Assert-True ($bad.Count -eq 0) ("timeout call(s) suppress stdout but not stderr, so a redirected stdin prints 'Input redirection is not supported' as the last line of an otherwise clean exit: line(s) $(($bad | ForEach-Object { $_.LineNumber }) -join ', ') (regression of F-F1).")
}

# 114. /preset: applies exactly what the menu applies and warns about Ultimate on laptops.
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
    Assert-True ($all -match '(?i)set "_CLIPLAN=%_a:~6%"') 'The argument loop no longer parses /plan: (regression of F-H2).'
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
    # A preset name becomes a path: whitelist it, without a pipe (a piped child ran an "&" remainder).
    Assert-True ($cliCode -match '(?i)for /f "eol=[A-Za-z0-9_.\-] delims=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_\.-" %%X in \("!_CLIPRESET!"\)') ':CliRun no longer holds the preset name to a whitelist without a pipe, or lost the eol= that closes the ";" hole - so /preset:..\..\x, a name containing "&", or anything after a ";" gets through (regression of F-H3).'
    Assert-True ($cliCode -notmatch '(?i)echo\(?!_CLIPRESET!\s*\|') ':CliRun pipes the preset name into findstr again - the piped child re-parses it and an "&" in the name executes (regression of F-J1).'
    # and the name must never reach :Summary, whose "echo [OK] %~1" re-parses its argument
    Assert-True ($cliCode -notmatch '(?i)call :Summary "Preset !_CLIPRESET!') ':CliRun passes the preset name to :Summary again - it ends in "echo [OK] %~1", and %~1 is substituted during parsing, so an "&" in the text splits the line (regression of F-J2).'
    Assert-True ($cliCode -match '(?i)_CLIPRESET:\.\.=') ':CliRun no longer rejects ".." in a preset name (regression of F-H3).'

    # ---- an option that parses to nothing must not fall through to the menu: an unattended
    #      caller would sit at a prompt with nothing reported ----
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
        Assert-True (($argBody -join "`n") -match ('(?i)if not defined ' + $v + ' set "_CLIBAD=%_a%"')) "An empty value for the option behind $v is accepted silently instead of being reported as bad usage (regression of F-H5)."
    }
    Assert-True ($cliCode -match '(?i)if not defined _CLIPRESET \(') ':CliRun does not refuse a command line with no /preset: - options like /norestore alone have nothing to apply (regression of F-H5).'

    # ---- a path from the user's Documents folder can contain & or ) ----
    Assert-True ($all -notmatch '(?i)Registry backup: %PRESET_LAST%') 'The "Registry backup:" line percent-expands PRESET_LAST - it is built from the Documents folder, so "C:\Users\Bob & Alice\..." would be re-parsed as a command separator (regression of F-H4).'
}

# 115. The backup-folder size total no longer rounds each file down to zero MB.
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

# 116. No value is validated by piping it into findstr.
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
    # Pipe-free and able to fire: findstr's class ranges follow collation, not codes, so pure
    # batch - a for /f over a printable-ASCII delimiter whitelist, with an allowed eol.
    Assert-True ($na -match '(?i)for /f "eol=[^"]*delims=[^"]*" %%c in \("!_rd!"\)') ':NonAsciiCheck no longer scans the value with a pipe-free for /f whitelist (regression of F-J1).'
    # Against CODE only (-CodeOnly): the routine's comment explains why findstr is not used.
    $naCode = (Get-BodyLines -Lines $cmd -Label 'NonAsciiCheck' -CodeOnly) -join "`n"
    Assert-True ($naCode.Length -gt 0) ':NonAsciiCheck has no code lines - only comments?'
    Assert-True ($naCode -notmatch '(?i)findstr') ':NonAsciiCheck went back to findstr - collation-order ranges mean it either never fires or flags plain ASCII (regression).'
    Assert-True ($na -notmatch '(?i)echo\(!_rd!\s*\|') ':NonAsciiCheck pipes the value into a child again - the child re-parses it (regression of F-J1).'
    $all = $cmd -join "`n"
    Assert-True ($all -match '(?i)for /f "eol=[0-9] delims=0123456789" %%X in \("!_in!"\)') 'The Unity job-worker prompt pipes typed input into findstr again, or lost its eol= (regression of F-J1).'
}

# 117. The startup manager re-enumerates entries before each toggle pass.
Invoke-Test 'Flipping a startup entry refuses if the list changed since it was shown' {
    $cmd = Read-Lines $CmdPath

    $w = @(Get-BodyLines -Lines $cmd -Label 'StartupWorker')
    Assert-True ($w.Count -gt 3) ':StartupWorker body did not unroll.'
    $code = @($w | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' }) -join "`n"

    Assert-True ($code -match '(?i)\$sg=\[BitConverter\]::ToString') ':StartupWorker no longer fingerprints the enumeration, so a list that changed between display and flip is undetectable (regression of F-K1).'
    Assert-True ($code -match '(?i)\$sg \| Out-File -FilePath \$env:PT_SU_SIG') 'The list pass no longer publishes the fingerprint (regression of F-K1).'
    Assert-True ($code -match '(?i)if\(-not \$env:PT_SU_SIGIN -or \$env:PT_SU_SIGIN -ne \$sg\)\{[^}]*exit 3 \}') 'The toggle pass no longer refuses (exit 3) a changed list or a missing fingerprint - a check written "SIGIN -and" is skipped when no fingerprint came back (regression of F-K1).'
    Assert-True ($code -match '(?i)\[Security\.Cryptography\.SHA256\]::Create\(\)' -and $code -notmatch '(?i)MD5') 'The startup fingerprint is no longer SHA-256 (MD5 can be refused by policy).'
    $ask = @(Get-BodyLines -Lines $cmd -Label 'StartupMgr_ask' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True (@($ask | Where-Object { $_ -ceq ') else if "%_surc%"=="3" (' }).Count -eq 1) 'A refused flip (exit 3) falls into the [ERROR] branch again, which tells the user to elevate.'
    # the refusal must happen BEFORE anything is written
    $iCheck = ($code -split "`n" | Select-String -SimpleMatch 'PT_SU_SIGIN -ne $sg' | Select-Object -First 1)
    $iWrite = ($code -split "`n" | Select-String -SimpleMatch 'Registry]::SetValue' | Select-Object -First 1)
    Assert-True ($null -ne $iCheck -and $null -ne $iWrite) ':StartupWorker lost either the staleness check or the write.'
    Assert-True ($iCheck.LineNumber -le $iWrite.LineNumber) ':StartupWorker checks the fingerprint after writing the new state (regression of F-K1).'
    # the fingerprint is derived from source+name, never the raw name through cmd; literal match,
    # escaped (a hand-written regex gets the backslash count wrong)
    $sigExpr = [regex]::Escape('$_[0]+''\''+$_[2]')
    Assert-True ($code -match $sigExpr) 'The fingerprint no longer covers both the source and the entry name, so an entry renamed between two sources would slip through (regression of F-K1).'
    Assert-True ($code.Contains('$_[0]+''\''+$_[2]+''=''+(S $_[1] $_[2])')) 'The startup fingerprint no longer covers each entry''s Enabled/Disabled state - an entry switched elsewhere after the list was shown would be flipped back the other way.'

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

# 118. No two batch variables differ only by case.
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

# 119. The HAGS screen shows the stored state; Status carries the full machine header.
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
    Assert-True ($hj -match 'if /i "!_hags!"=="0x2"\s+echo\s+Currently: HAGS is ON' -and $hj -match 'if /i "!_hags!"=="0x1"\s+echo\s+Currently: HAGS is OFF' -and $hj -match 'if not defined _hags\s+echo\s+Currently: HAGS is ON') ':HagsToggle maps HwSchMode to the wrong state - 2 is ON, 1 is OFF, absent is the default ON.'
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

# 120. The undervolt probe reports a tool, never a voltage.
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

# 121. The harness checks itself: no one-step @(Get-RoutineBody ...) wrapping.
Invoke-Test 'The harness itself never uses the misuse-prone body slicer' {
    Assert-True (Test-Path -LiteralPath $SelfPath) 'Could not locate the harness source to self-check.'
    $self = [System.IO.File]::ReadAllLines($SelfPath)

    # Skip `#` lines and `<# #>` blocks: Get-BodyLines' doc comment spells the banned form out.
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

# 122. A lone " typed at a prompt cannot abort the script.
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

    # A validator must not splice the typed value into its code: in ("%v%") a quote ends the
    # string (the prompt closed on `"`), and `50!0` passed. `!v!` is substituted after parsing.
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

    # Nothing up to the end of the rejection branch reads the value early: a typed `")` closed
    # the block, and `"&echo X` ran the command (measured).
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

# 123. The shipped hosts and boot.config bytes are checked too.
Invoke-Test 'Shipped data files are ASCII, BOM-free and end with a newline' {
    $dir = Split-Path -Parent $CmdPath
    $checked = 0
    foreach ($name in @('hosts', 'boot.config')) {
        $p = Join-Path $dir $name
        Assert-True (Test-Path -LiteralPath $p) "The bundled $name is missing next to the script."
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
    Assert-True ($checked -eq 2) 'Not both of hosts and boot.config were checked - the paths are wrong, so this test proved nothing.'
}

# 124. The telemetry undo file is captured before anything is disabled.
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

    # The slicer stops at :RestoreTelemetryBackup_ask, where the undo file actually runs, so
    # concatenate both halves.
    $rt = ((Get-BodyLines -Lines $cmd -Label 'RestoreTelemetryBackup' -CodeOnly) +
           (Get-BodyLines -Lines $cmd -Label 'RestoreTelemetryBackup_ask' -CodeOnly)) -join "`n"
    Assert-True ($rt.Length -gt 0) ':RestoreTelemetryBackup is missing.'
    $rtList = @(Get-BodyLines -Lines $cmd -Label 'RestoreTelemetryBackup' -NoEcho | ForEach-Object { $_.Trim() })
    Assert-True ($rtList -contains 'for /f "delims=" %%F in (''dir /b /a-d /od "%%BACKUP_DIR%%\Telemetry_*.bat" 2^>nul'') do (' -and $rtList -contains 'for %%G in ("!BACKUP_DIR!\%%F") do set "_tdt[!_tn!]=%%~tG"') ':RestoreTelemetryBackup no longer lists the Telemetry_*.bat undo files oldest first with their dates (regression).'
    Assert-True ($rt -match '(?i)cmd /d /v:off /s /c ""%%_tfile%%" /q"') ':RestoreTelemetryBackup no longer runs the chosen file in a child cmd with /q - `call`ed, a syntax error in it ends sincript too, and without /q its own pause blocks the menu (regression).'
    Assert-True ($rt -notmatch '(?i)\bcall\s+"?[%!]_tfile') ':RestoreTelemetryBackup `call`s the undo file again - a syntax error in it would end sincript too (regression; see test 126).'
    Assert-True ($rt -match '_RUNTRACK=') ':RestoreTelemetryBackup no longer clears _RUNTRACK, so the next cleanup counts benign failures as real ones (regression).'
}

# 125. Every set /p prompt fits the console width.
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

# 126. The undo files are run here, not only read.
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
        $outT = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw ('test 126: {0} did not finish within 60 s.' -f (Split-Path -Leaf $File)) }
        $out = $outT.Result
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
        $safe = '^(|rem|rem .*|@echo off|setlocal|set "PT_(OK|FAIL)=0"|call :pt_do [^&|<>^]+|if (not )?"?%PT_FAIL%"?=="?0"? echo [^&|<>^]*|if "?%~1"?==(""|) pause|exit /b|exit /b 0|exit /b %PT_FAIL%|:pt_do|:pt_bad|%\*|if errorlevel 1 goto :pt_bad|set /a PT_(OK|FAIL)\+=1|echo   \[FAIL\] %\*|call :pt_start [A-Za-z0-9_.-]+|:pt_start|:pt_started|:pt_nostart|sc start %1|set "PT_RC=%errorlevel%"|if "%PT_RC%"=="1056" goto :pt_started|if not "%PT_RC%"=="0" goto :pt_nostart|echo   \[FAIL\] sc start %1 - exit %PT_RC%)$'
        $unknown = @($lines | Where-Object { $_ -cnotmatch $safe })
        Assert-True ($unknown.Count -eq 0) ('{0} has line(s) this test does not know to be safe to dry-run - check them, then extend the list: {1}' -f $name, ($unknown -join ' | '))
        $n = @($lines | Where-Object { $_.StartsWith('call :pt_do ') -or $_.StartsWith('call :pt_start ') }).Count
        Assert-True ($n -ge 2) ('{0} restores {1} thing(s) - too few for the dry run to prove anything.' -f $name, $n)
        $dry = $File + '.dry.bat'
        [System.IO.File]::WriteAllLines($dry, [string[]]@($lines | ForEach-Object { ($_ -replace '^call :pt_do ', 'call :pt_do echo ') -replace '^sc start %1$', 'echo sc start %1' }), [System.Text.Encoding]::ASCII)
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

        # ---- power again: hibernation already off, only HibernateEnabledDefault recorded, and
        #      unreadable; then PT_HBOFF (sincript turned it off with no capture): a retried capture
        #      reading "off" says "unknown", never "already off". The 4th item must NOT appear.
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
        # sc start exits 1056 for a service that is already running: restored, not a failure
        Assert-True (@($tl | Where-Object { $_ -ceq 'call :pt_start EventLog' }).Count -eq 1) 'The telemetry undo file does not start EventLog (running on every Windows) through :pt_start, so a second run would count an already running service as a failure.'
        $nRestore = @($tl | Where-Object { $_.StartsWith('call :pt_do ') -or $_.StartsWith('call :pt_start ') }).Count
        foreach ($sc in @(@('1056', 0), @('5', 1))) {
            $scFile = $tlFile + '.sc' + $sc[0] + '.bat'
            [System.IO.File]::WriteAllLines($scFile, [string[]]@($tl | ForEach-Object { ($_ -replace '^call :pt_do ', 'call :pt_do cmd /d /c echo ') -replace '^sc start %1$', ('cmd /d /c exit ' + $sc[0]) }), [System.Text.Encoding]::ASCII)
            $r = & $runProc $cmdExe ('/d /v:off /s /c ""' + $scFile + '" /q"')
            Remove-Item -LiteralPath $scFile -Force
            if ($sc[1] -eq 0) {
                Assert-True ($r.Code -eq 0 -and $r.Out.Contains(('[OK] Restored {0} item' -f $nRestore))) ('sc start exiting 1056 (already running) must count as restored: exit {0}, {1}' -f $r.Code, $r.Out.Trim())
            }
            else {
                Assert-True ($r.Code -eq 1 -and $r.Out.Contains('[FAIL] sc start EventLog - exit 5')) ('sc start exiting 5 must be a [FAIL] naming its code: exit {0}, {1}' -f $r.Code, $r.Out.Trim())
            }
        }

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

# 127. The script's own path is read late after its capture.
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
    Assert-True ($pc.Contains('dir /b /a-d /on "!_pdir!\*.preset" >"!_plist!" 2>nul')) ':PresetCustom no longer lists the preset names into a file - routine changed shape?'
    Assert-True ($pc -notmatch '(?i)%%~fF' -and $pc -notmatch '(?i)%%~nxF') ':PresetCustom copies names or full paths through a FOR variable under delayed expansion again - a "!" in the script folder or a name is eaten (regression).'
}

# 128. SteamLight keeps Steam's browser sandbox unless the user turns it off.
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

# 129. Four maintenance actions report what happened.
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

# 130. Partial and failed results are reported as such.
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

# 131. Small correctness fixes stay fixed.
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

# 132. Profile paths are read late everywhere.
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

# 133. A ! % ^ or & in the user name reaches the user's own folders (run).
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
    $core0 = @(& $grab 'DoCleanupCore' @('_clCoreBody'))
    $core = @($core0 | ForEach-Object { $_ -replace '(?i)call :Run "ipconfig /flushdns"', 'rem (flushdns stubbed)' })
    Assert-True (@($core0 | Where-Object { $_ -match '(?i)ipconfig' }).Count -ge 1 -and @($core | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)ipconfig' }).Count -eq 0) 'test 133: the ipconfig stub did not replace every real flush - refusing to run it.'
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
            $outT = $p.StandardOutput.ReadToEndAsync()
            if (-not $p.WaitForExit(120000)) { $p.Kill(); throw ('test 133: the cleanup driver for "{0}" did not finish within 120 s.' -f $name) }
            $out = $outT.Result
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

# 134. No profile or script path rides a call argument.
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

# 135. The Documents capture keeps ! % ^ & in the user name (run).
Invoke-Test 'The Documents capture keeps "!", "%", "^" and "&" in the user name (run with a faked registry)' {
    $cmd = Read-Lines $CmdPath
    $i0 = [Array]::IndexOf($cmd, 'set "DOCS=%USERPROFILE%\Documents"')
    $i1 = [Array]::IndexOf($cmd, 'set "BACKUP_DIR=%DOCS%\PerfTweaks_Backups"')
    Assert-True ($i0 -gt 0 -and $i1 -gt $i0 -and ($i1 - $i0) -lt 20) 'The Documents capture changed shape - test 135 cannot find it.'
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
            $outT = $p.StandardOutput.ReadToEndAsync()
            if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'test 135: the capture driver did not finish within 60 s.' }
            $out = $outT.Result
            $got = @($out -split "`r?`n" | Where-Object { $_.StartsWith('[') })
            $want = '[' + $c[1] + '\PerfTweaks_Backups]'
            Assert-True ($got.Count -eq 1 -and $got[0] -eq $want) ('The Documents capture turned the registry answer "{0}" into {1}, not {2} (regression). {3}' -f $c[0], ($got -join ' '), $want, $err.Result.Trim())
        }
    }
    finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

# 136. The DNS screen states its real undo and lists typed-in resolvers (run).
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
            $err = $p.StandardError.ReadToEndAsync(); $outT = $p.StandardOutput.ReadToEndAsync()
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'test 136: the listing driver did not finish within 30 s.' }
            $out = $outT.Result
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
        & $w "name_$g2.txt" ("`r`n$kn$g2\Connection`r`n    Name    REG_SZ    Wi-Fi (home) & Co!`r`n")
        $cases = @(
            @('every typed-in value, named by adapter, with the unnamed ones counted',
              ("`r`n$k4$g1`r`n    NameServer    REG_SZ    `r`n`r`n$k4$g2`r`n    NameServer    REG_SZ    8.8.8.8,9.9.9.9,192.168.0.1`r`n`r`n$k4$g2\$g3`r`n    NameServer    REG_SZ    10.9.9.9`r`n`r`n$k4$g4`r`n    NameServer    REG_SZ    10.1.1.1`r`n`r`nEnd of search: 4 match(es) found.`r`n"),
              ("`r`n$k6$g2`r`n    NameServer    REG_SZ    fd00::53,fd00::54        `r`n`r`nEnd of search: 1 match(es) found.`r`n"),
              @(' DNS servers typed in by hand, per adapter - write down any you want to keep:',
                '   IPv4  8.8.8.8,9.9.9.9,192.168.0.1   (Wi-Fi (home) & Co!)',
                '   IPv6  fd00::53,fd00::54   (Wi-Fi (home) & Co!)',
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
                '   IPv4  192.168.0.1   (Wi-Fi (home) & Co!)')),
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

# 137. The power revert screen names what its undo file does not cover.
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

# 138. No screen promises an undo the code does not have.
Invoke-Test 'Screens promise no undo the code does not have' {
    $cmd = Read-Lines $CmdPath
    $never = '(?!)'   # a rule whose screen had nothing false, only something missing
    $rules = @(
        @(@('MenuAdvanced'),                               '(?i)\bReversible,',                                       '(?i)no in-app undo'),
        @(@('MenuTools'),                                  '(?i)reversible',                                          '(?i)cannot be undone'),
        @(@('CompactWinSxS'),                              '(?i)reversible',                                          '(?is)cleanup cannot.*CompactOS can: Cleanup option 8'),
        @(@('WinOldRemove'),                               '(?i)reversible|can be undone|back later',               '(?i)there is no undo'),
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

    # The hosts reset names the file that really holds what it replaced (hosts.bak is write-once,
    # so later it is the snapshot or nothing); _hbakdoc is cleared so a stale one is not named.
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

# 139. The driver toggle writes one documented policy, and "on" deletes it.
Invoke-Test 'Windows Update driver toggle: one documented policy, deleted to turn back on, end state counted, menu-only' {
    $cmd = Read-Lines $CmdPath
    $all = $cmd -join "`n"
    $key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $val = 'ExcludeWUDriversInQualityUpdate'

    # One spelling everywhere, comments included: Autopatch docs print ...From...Updates, which
    # Windows never reads.
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

    # Where the effect cannot be vouched for (Home, a build before 1607, MDM ignoring Group
    # Policy) only "written" is honest; each branch comes before the promising summary.
    $iPromise = -1; for ($i = 0; $i -lt $off.Count; $i++) { if ($off[$i] -match '^call :Summary "Windows Update will stop offering drivers') { $iPromise = $i; break } }
    Assert-True ($iPromise -gt 0) ':WuDrvOff lost its summary for the case where the block is documented to work.'
    foreach ($g in 'if defined _wdign goto _wdOffIgnored', 'if not "!_wdedc!"=="listed" goto _wdOffUnverified', 'if defined WIN_BUILD if !WIN_BUILD! LSS 14393 goto _wdOffUnverified') {
        $ig = [Array]::IndexOf($off, $g)
        Assert-True ($ig -ge 0 -and $ig -lt $iPromise) (":WuDrvOff promises the block works without first ruling out '{0}' - there only ""written"" is honest (regression)." -f $g)
    }
    $unv = @($off | Where-Object { $_ -match '^call :Summary "' -and $_ -notmatch 'will stop offering drivers' -and $_ -notmatch 'Group Policy Editor' })
    Assert-True ($unv.Count -eq 2 -and @($unv | Where-Object { $_ -match 'unverified' }).Count -eq 2) (':WuDrvOff should have exactly two "written ... unverified" summaries besides the promise and the Group Policy Editor one, found: ' + ($unv -join ' | '))
    Assert-True ([Array]::IndexOf($on, 'if defined _wdign goto _wdOnIgnored') -ge 0) ':WuDrvOn no longer says, where MDM tells Windows Update to ignore Group Policy, that removing the local value decides nothing (regression).'

    # A Group Policy Editor conflict decides the summary first (a restart writes its value back);
    # its flag is cleared before each write, and each conflict summary passes a _SUMCAUSE.
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
    # _SUMCAUSE ("not a failed write") belongs only under a :_wd*Gp* label, right above a :Summary
    # naming the Group Policy Editor; anywhere else it would explain away a real failure.
    $causes = @(for ($i = 0; $i -lt $cmd.Count; $i++) { if ($cmd[$i] -match '^\s*set "_SUMCAUSE=.+"') { $i } })
    Assert-True ($causes.Count -ge 1) 'No code sets _SUMCAUSE - the Group Policy Editor outcomes lost their explanation.'
    foreach ($i in $causes) {
        Assert-True ($i -gt 0 -and $cmd[$i - 1] -match '^:_wd(Off|On)Gp\w*$') ("line {0} sets _SUMCAUSE outside a Group Policy Editor outcome - it would explain away a real failure (regression)." -f ($i + 1))
        Assert-True ($cmd[$i + 1] -match '^\s*call :Summary ".*Group Policy Editor') ("line {0}: _SUMCAUSE is not followed directly by the Group Policy Editor summary it belongs to (regression)." -f ($i + 1))
    }
}

# 140. The driver screen states its costs before it asks.
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

    # One vocabulary: every word compared against _wdst / _wdedc / _wdgpc must be one the reader
    # can set, or the branch never runs.
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

    # Every fixed line fits the console and holds no unescaped redirect or separator. Variables
    # count at their stated maximum (edition 26, DWORD 10, type 30, build 5, gpedit 26); test 141
    # measures the real rendered lines.
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

# 141. The driver screen is run for twenty stored states with a faked registry.
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
        $outT = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'test 141: the screen driver did not finish within 120 s.' }
        $out = $outT.Result
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

# 142. The driver toggle's handlers are run with stubbed writes and a faked Registry.pol.
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
        ':MenuAdvanced', 'exit /b 0', ':RestartNote', 'exit /b 0')

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
    # b = WIN_BUILD, fail = the write fails, stuck = it "succeeds" but changes nothing, pol = the fake
    # Registry.pol ($null = none, 'lock' = held open), gpc = expected _wdgpc, log = expected log text.
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
            # the worker's own text, run the way PowerShell runs it, in a fresh runspace (here it could
            # read this test's variables and pass while failing in a real child)
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
        $outT = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(180000)) { $p.Kill(); throw 'test 142: the handler driver did not finish within 180 s.' }
        $out = $outT.Result
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

# Holds the worker's payload to an ALLOWLIST read by PowerShell's own parser: commands and call
# shapes, parameters, methods, static members, types, assigned variables, the one C# declaration.
# A denylist missed writers (Clear-ItemProperty, aliases, WMI .Put()). Tests 144 and 146 RUN the
# payload with writers blocked too. A guard against regressions, not against a disguised writer.
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

# Runs $Script in a child Windows PowerShell with the payload in PT_T_PAYLOAD, from a temp .ps1
# (-File: an encoded command can pass 32767 chars), in ASCII: 5.1 reads a BOM-less .ps1 as ANSI.
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

# 143. Status [Page file]: wired in, read-only, every verdict from the worker.
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
    # A leftover file is deleted before the worker runs and the result only after it is shown;
    # each step is searched for after the previous one, telling the two deletes apart.
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

    # --- [ADVISORY] only under a _pgfAdv* label, in all three bodies, on any non-rem line; every
    #     verdict the worker can emit has exactly one branch, and none is dead
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

    # --- READ-ONLY, half 2: no other code line names a page-file or crash-dump setting. Prose is
    #     rem, or an echo holding no & | < > once its ^x pairs are removed; anything else naming
    #     one fails ("echo reg add ... /f>>file" and "echo ^^& reg add" included).
    $targets = '(?i)PagingFiles|ExistingPageFiles|TempPageFile|AutomaticManagedPagefile|Win32_PageFileSetting|pagefileset|ClearPageFileAtShutdown|CrashControl|CrashDumpEnabled|DedicatedDumpFile|DumpFileSize|FilterPages'
    $echoLine = '(?i)^\s*(if\s+(/i\s+)?(not\s+)?(defined\s+\S+|exist\s+"[^"]*"|"[^"]*"==\s*"[^"]*")\s+)*echo([\s.:;,(]|$)'
    $code = @($cmd | Where-Object { $t = $_.Trim(); $t -ne '' -and $t -notmatch '^(?i)(rem\b|::)' -and -not ($_ -match $echoLine -and ($_ -replace '\^.', '') -notmatch '[&|<>]') })
    Assert-True ($code.Count -gt 2000 -and @($code | Where-Object { $_ -ceq $w }).Count -eq 1) 'The read-only scan found too little code, or not the worker - it would pass vacuously.'
    # The one writer: :PageWipeAsk reads ClearPageFileAtShutdown and may set it back to 0, nothing else.
    $pw = @(Get-BodyLines -Lines $cmd -Label 'PageWipeAsk' -CodeOnly | Where-Object { $_ -match $targets })
    $pwRead = 'for /f "tokens=1-3" %%a in (''reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ClearPageFileAtShutdown 2^>nul'') do if /i "%%a"=="ClearPageFileAtShutdown" if /i "%%b"=="REG_DWORD" set "_pwv=%%c"'
    $pwWrite = 'call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "ClearPageFileAtShutdown" REG_DWORD 0 "Page file no longer wiped at shutdown" || goto :eof'
    Assert-True ($pw.Count -eq 2 -and $pw[0].Trim() -ceq $pwRead -and $pw[1].Trim() -ceq $pwWrite) ('The page-file wipe option may only read ClearPageFileAtShutdown and write it back to 0: ' + ($pw -join ' | '))
    Assert-True (@($cmd | Where-Object { $_.Trim() -ceq $pwRead }).Count -eq 1 -and @($cmd | Where-Object { $_.Trim() -ceq $pwWrite }).Count -eq 1) 'The page-file wipe read or write is copied outside :PageWipeAsk.'
    $named = @($code | Where-Object { $_ -match $targets -and $_ -cne $w -and $_.Trim() -cne $pwRead -and $_.Trim() -cne $pwWrite })
    Assert-True ($named.Count -eq 0) ('A code line outside the read-only worker and the wipe option names a page-file or crash-dump setting - sincript shows them and must never change them: ' + (($named | ForEach-Object { $_.Trim().Substring(0, [Math]::Min(90, $_.Trim().Length)) }) -join ' | '))
    Assert-True (@($code | Where-Object { $_ -match '(?i)Win32_PageFileSetting|pagefileset|AutomaticManagedPagefile' }).Count -eq 0) 'Code touches Win32_PageFileSetting / AutomaticManagedPagefile - the WMI write surface for the page file. The status needs neither.'
}

# 144. The page-file classifier is run on synthetic machines.
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
  'ClearPageFileAtShutdown 1 - shutdown wipes the page file' = @{ MM = [pscustomobject]@{ PagingFiles = [string[]]@('?:\pagefile.sys'); ClearPageFileAtShutdown = 1 }; CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @('ADV|clear'); Gpi = 0 }
  'ClearPageFileAtShutdown 0 - nothing to say' = @{ MM = [pscustomobject]@{ PagingFiles = [string[]]@('?:\pagefile.sys'); ClearPageFileAtShutdown = 0 }; CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @(); Gpi = 0 }
  'ClearPageFileAtShutdown as a string - unrecognised, nothing said' = @{ MM = [pscustomobject]@{ PagingFiles = [string[]]@('?:\pagefile.sys'); ClearPageFileAtShutdown = '1' }; CC = (PTCc 7 $null $null); USE = @(PTUse 'C:\pagefile.sys' 1024 10 20 $false); OS = $os16; PM = $pm16; Peak = $null; Want = @(); Gpi = 0 }
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

# 145. The page-file display is run on synthetic records.
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
            $neither = @($one | Where-Object { $_ -match '^\s+\[i\] sincript does not change the page file size or the crash-dump type' }).Count
            if ($c -eq 'clear') { Assert-True ($neither -eq 0 -and (($one -join ' ') -match 'Performance tweaks\s+offers to turn it off')) ('ADV|clear must point to the Performance option and carry no page-file-size note of its own: ' + ($one -join ' | ')) }
            else { Assert-True ($neither -eq 1) ("ADV|$c printed without the line saying sincript does not change the setting.") }
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

# 146. The page-file worker's real compile and GetPerformanceInfo call are run once.
Invoke-Test 'Page file worker: the real GetPerformanceInfo compile and call answer' {
    $cmd = Read-Lines $CmdPath
    $hits = @(Get-PgfWorker -Lines $cmd)
    Assert-True ($hits.Count -eq 1) ('Expected one page-file worker line, found {0}.' -f $hits.Count)
    $m = [regex]::Match($hits[0], '-Command "(.*)"\s*$')
    Assert-True $m.Success 'The page-file worker lost the -Command "..." shape this test extracts.'
    $payload = $m.Groups[1].Value.Replace('%%', '%')
    $probs = @(Get-PgfPayloadProblems -Payload $payload)
    Assert-True ($probs.Count -eq 0) ('test 146 refuses to run a page-file worker that is off its read-only allowlist: ' + ($probs -join ' | '))
    # the harness's own reading: psapi's export (the worker uses K32), a declared
    # PERFORMANCE_INFORMATION struct, whole MB rounded down as the worker does
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

# 147. The crash report only reads, via EventLogReader, never Get-WinEvent.
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

# 148. Crash classification is run on synthetic events.
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
            $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close(); $null = $p.StandardError.ReadToEndAsync(); $null = $p.StandardOutput.ReadToEndAsync()
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

        # ---- D: evidence outside the week before the first crash (Kernel-Power 41, 2026-01-20)
        #      blames nothing: a corrected WHEA error, DrvOld 10 days before, DrvLate and the undo
        #      session after, SvcNear a service, and a session with no undo file
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

# 149. The crash collector is run against a faked event-log reader.
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
        # From a file: prelude and collector together outgrow the 32767-character command line.
        $ps1 = [IO.Path]::ChangeExtension($csv, '.ps1')
        [IO.File]::WriteAllText($ps1, ($prelude + "`n" + $Code), (New-Object Text.UTF8Encoding $true))
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ps1 + '"'
        $psi.EnvironmentVariables['PT_CR_OUT'] = $csv; $psi.EnvironmentVariables['PT_CR_BAK'] = $bak; $psi.EnvironmentVariables['PT_CR_DAYS'] = '30'
        $psi.EnvironmentVariables['PT149_MODE'] = $Mode
        $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close(); $err = $p.StandardError.ReadToEndAsync(); $null = $p.StandardOutput.ReadToEndAsync()
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

# 150. Two PowerShell name traps (aliases, case) in the crash workers.
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

# 151. The crash report's final line, hints and saved report (run).
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

# 152. The refresh-rate header never makes the menu wait.
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

# 153. The main-menu header fits the console at its widest.
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

# 154. The refresh-rate parser is run on synthetic answers.
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
            $outT = $p.StandardOutput.ReadToEndAsync()
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw ("test 154: the parser did not finish for case '{0}'." -f $c[0]) }
            $out = $outT.Result
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

# 155. The refresh-rate state machine is run over simulated draws.
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
        $outT = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'test 155: the state-machine driver did not finish.' }
        $out = $outT.Result
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

# 156. Names in other alphabets survive, and the code page is restored (run).
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

# 157. The timer screen gives its own undervolt advisory (run).
Invoke-Test 'The timer-resolution screen gives its own undervolt advisory, the power plan keeps its own (run)' {
    $cmd = Read-Lines $CmdPath
    $tr = @(Get-BodyLines -Lines $cmd -Label 'TimerResApply' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ($tr.Count -gt 10) ':TimerResApply is missing or did not unroll.'
    $ia = [Array]::IndexOf($tr, 'call :LaptopAdvisory timer')
    $ib = -1; for ($i = 0; $i -lt $tr.Count; $i++) { if ($tr[$i] -match '^call :RequireBundledFile SetTimerResolution\.exe') { $ib = $i; break } }
    Assert-True ($ia -ge 0 -and $ib -gt $ia) ':TimerResApply no longer shows the timer advisory before it asks anything - an undervolter would read the Ultimate Performance warning instead (regression).'
    $timerCalls = @($cmd | Where-Object { $_.Trim() -match '^(?i)call :LaptopAdvisory timer\b' })
    Assert-True ($timerCalls.Count -eq 1) ("Only the timer-resolution screen may pass 'timer' to :LaptopAdvisory; found {0} such call(s)." -f $timerCalls.Count)

    # The slice runs through :DesktopAdvisory, the next routine: a branch that loses its goto :eof
    # falls into it, and on a desktop the timer screen would print the LargeSystemCache warning.
    $s = [Array]::IndexOf($cmd, ':LaptopAdvisory'); $d = [Array]::IndexOf($cmd, ':DesktopAdvisory')
    $e = -1; for ($i = $d + 1; $i -lt $cmd.Count; $i++) { if ($cmd[$i] -match '^:[A-Za-z]') { $e = $i; break } }
    Assert-True ($s -gt 0 -and $d -gt $s -and $e -gt $d) ':LaptopAdvisory / :DesktopAdvisory could not be sliced for the run.'
    $adv = @($cmd[$s..($e - 1)])
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pt157_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $body = @('@echo off', 'setlocal EnableDelayedExpansion', 'set "MACHINE=desktop"',
                  'set "UVTOOL=ThrottleStop"', 'echo [CASE#timer]', 'call :LaptopAdvisory timer',
                  'echo [CASE#plan]', 'call :LaptopAdvisory',
                  'set "UVTOOL="', 'echo [CASE#none]', 'call :LaptopAdvisory timer',
                  'echo [END]', 'exit /b 0', ':DetectUndervolt', 'goto :eof') + $adv
        $live = @($body | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)\breg\s+(query|add|delete)\b|powershell|schtasks' })
        Assert-True ($live.Count -eq 0) ('test 157: the driver contains a real system command - refusing to run it: ' + ($live -join ' | '))
        $drv = Join-Path $dir 'drv.cmd'
        [System.IO.File]::WriteAllLines($drv, [string[]]$body, [System.Text.Encoding]::ASCII)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c ""' + $drv + '""'
        $psi.WorkingDirectory = $dir
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync()
        $outT = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'test 157: the driver did not finish within 30 s.' }
        $out = $outT.Result
        Assert-True ($p.ExitCode -eq 0 -and $err.Result.Trim() -eq '') ("test 157: the advisory driver failed (exit {0}): {1}" -f $p.ExitCode, $err.Result.Trim())
        $all = @($out -split "`r?`n")
        $at = @{}; foreach ($m in 'timer', 'plan', 'none') { $at[$m] = [Array]::IndexOf($all, "[CASE#$m]") }
        $end = [Array]::IndexOf($all, '[END]')
        Assert-True ($at.timer -ge 0 -and $at.plan -gt $at.timer -and $at.none -gt $at.plan -and $end -gt $at.none) 'test 157: the advisory driver did not run all three cases.'
        $timer = ($all[($at.timer + 1)..($at.plan - 1)]) -join "`n"
        $plan = ($all[($at.plan + 1)..($at.none - 1)]) -join "`n"
        # an empty section would make ($at.none + 1)..($end - 1) count backwards over the markers
        $none = @(if ($end -gt $at.none + 1) { $all[($at.none + 1)..($end - 1)] | Where-Object { $_.Trim() -ne '' } })
        Assert-True ($timer -match 'ThrottleStop is installed' -and $timer -match '(?i)timer\s+resolution' -and $timer -match '\(option 7\)' -and $timer -match 'WHEA') ("The timer screen's undervolt advisory lost the tool, the effect, the way back (option 7) or the WHEA pointer: {0}" -f $timer)
        Assert-True ($timer -notmatch '(?i)Ultimate|0x124') 'The timer screen shows the power-plan advice again (Ultimate / 0x124) - it says nothing about a timer (regression).'
        Assert-True ($plan -match 'Ultimate' -and $plan -match '0x124' -and $plan -notmatch '(?i)timer\s+resolution') 'The power-plan callers no longer get the power-plan undervolt advisory.'
        Assert-True (($timer + "`n" + $plan) -notmatch '(?i)looks like a desktop') 'An undervolt branch lost its goto :eof and falls into :DesktopAdvisory - a desktop would read the LargeSystemCache warning here (regression).'
        Assert-True ($none.Count -eq 0) ('With no undervolt tool found the advisory must stay silent - a missing tool is not evidence of a missing undervolt: ' + ($none -join ' | '))
        $wide = @($all[($at.timer + 1)..($at.plan - 1)] | Where-Object { $_.Length -gt 96 })
        Assert-True ($wide.Count -eq 0) ('The timer advisory runs past the console with one tool found: ' + ($wide -join ' | '))
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# 158. GlobalTimerResolutionRequests is claimed and written only where it exists (run).
Invoke-Test 'The timer screen claims and writes GlobalTimerResolutionRequests only where it exists (run)' {
    $cmd = Read-Lines $CmdPath
    $said = @($cmd | Where-Object { $_.Trim() -match '^(?i)(if .*?)?echo\b' }) -join "`n"
    Assert-True ($said -notmatch '(?i)Windows 10 2004\+\s*/\s*11') 'A screen claims GlobalTimerResolutionRequests works on Windows 10 2004+ again - the value exists from Windows 11 / Server 2022 only (regression).'
    $s = [Array]::IndexOf($cmd, ':TimerResApply'); $e = [Array]::IndexOf($cmd, ':TimerResRemove')
    Assert-True ($s -gt 0 -and $e -gt $s) ':TimerResApply could not be sliced.'
    $body = @($cmd[$s..($e - 1)])
    $hdr = @($body | Where-Object { $_ -match '^echo ' }) -join "`n"
    Assert-True ($hdr -match '(?i)undocumented' -and $hdr -match '(?i)Windows 11') 'The timer screen no longer says the switch is undocumented and Windows 11 only.'
    $g0 = [Array]::IndexOf($body, 'set "_trglobal="')
    $g1 = -1; for ($i = [Math]::Max($g0, 0); $i -lt $body.Count; $i++) { if ($body[$i] -eq ')') { $g1 = $i; break } }
    Assert-True ($g0 -gt 0 -and $g1 -gt $g0) 'The build gate of :TimerResApply is missing or changed shape.'
    $wr = @($body | Where-Object { $_ -match 'GlobalTimerResolutionRequests" REG_DWORD 1' })
    Assert-True ($wr.Count -eq 1 -and $wr[0] -match '^if defined _trglobal call :SafeRegAdd ') ('GlobalTimerResolutionRequests is written without the build gate: ' + ($wr -join ' | '))
    $si = -1; for ($i = 0; $i -lt $body.Count; $i++) { if ($body[$i] -match '^call :Summary "Timer-resolution autostart installed') { $si = $i; break } }
    Assert-True ($si -gt $g1) ':TimerResApply lost its :Summary line, or it moved above the build gate.'
    $tail = @($body[($si + 1)..($body.Count - 1)] | Where-Object { $_ -match '^if (not )?defined _trglobal .*\becho ' })
    Assert-True ($tail.Count -eq 3) "Expected 3 build-dependent closing lines after the summary, found $($tail.Count)."

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pt158_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $builds = @('18363', '19045', '20348', '22631', '')
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        foreach ($b in $builds) {
            $drv += $(if ($b) { 'set "WIN_BUILD=' + $b + '"' } else { 'set "WIN_BUILD="' })
            $drv += ('echo [CASE#' + $b + ']')
            $drv += $body[$g0..$g1]
            $drv += $wr
            $drv += $tail
        }
        $drv += @('echo [END]', 'exit /b 0', ':SafeRegAdd', 'echo [REGWRITE] %~2=%~4', 'goto :eof')
        $live = @($drv | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)\breg\s+(query|add|delete)\b|powershell|schtasks' })
        Assert-True ($live.Count -eq 0) ('test 158: the driver contains a real system command - refusing to run it: ' + ($live -join ' | '))
        $path = Join-Path $dir 'drv.cmd'
        [System.IO.File]::WriteAllLines($path, [string[]]$drv, [System.Text.Encoding]::ASCII)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c ""' + $path + '""'
        $psi.WorkingDirectory = $dir
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $err = $p.StandardError.ReadToEndAsync()
        $outT = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'test 158: the driver did not finish within 30 s.' }
        $out = $outT.Result
        Assert-True ($p.ExitCode -eq 0 -and $err.Result.Trim() -eq '') ("test 158: the gate driver failed (exit {0}): {1}" -f $p.ExitCode, $err.Result.Trim())
        $all = @($out -split "`r?`n")
        $marks = @($builds | ForEach-Object { [Array]::IndexOf($all, "[CASE#$_]") }) + @([Array]::IndexOf($all, '[END]'))
        for ($i = 1; $i -lt $marks.Count; $i++) { Assert-True ($marks[$i] -gt $marks[$i - 1] -and $marks[0] -ge 0) 'test 158: the gate driver did not run every build.' }
        $want = @{
            '18363' = @{ reg = $false; adv = $false; line = 'system-wide already' }
            '19045' = @{ reg = $false; adv = $true;  line = 'reaches the helper only' }
            '20348' = @{ reg = $true;  adv = $false; line = 'REBOOT for the system-wide effect' }
            '22631' = @{ reg = $true;  adv = $false; line = 'REBOOT for the system-wide effect' }
            ''      = @{ reg = $true;  adv = $false; line = 'REBOOT for the system-wide effect' }
        }
        for ($i = 0; $i -lt $builds.Count; $i++) {
            $b = $builds[$i]; $w = $want[$b]; $who = $(if ($b) { "build $b" } else { 'an unreadable build' })
            $sec = $(if ($marks[$i + 1] -gt $marks[$i] + 1) { ($all[($marks[$i] + 1)..($marks[$i + 1] - 1)]) -join "`n" } else { '' })
            Assert-True (($sec -match '\[REGWRITE\] GlobalTimerResolutionRequests=1') -eq $w.reg) ("{0}: GlobalTimerResolutionRequests {1} - it exists from build 20348 only, and an unreadable build gets it. Output: {2}" -f $who, $(if ($w.reg) { 'was not written' } else { 'was written' }), $sec)
            Assert-True (($sec -match '\[ADVISORY\]') -eq $w.adv) ("{0}: the Windows 10 2004+ advisory {1}. Output: {2}" -f $who, $(if ($w.adv) { 'is missing' } else { 'shows where it does not apply' }), $sec)
            Assert-True ($sec.Contains($w.line)) ("{0}: the closing line should say '{1}'. Output: {2}" -f $who, $w.line, $sec)
        }
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}


# 159. Every reboot screen says Restart, and the note follows Fast Startup's registry values (run).
Invoke-Test 'Every reboot screen says Restart, not Shut down, only when Fast Startup can be on (run)' {
    $cmd = Read-Lines $CmdPath
    $want = '(?i)\breboot (is )?(recommended|required|may be needed)|\bREBOOT (to fully apply|for the)'
    $n = 0; $miss = @()
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $t = $cmd[$i].Trim()
        # result lines only: a screen's own description is "echo  Text"
        if ($t -notmatch '^(?i)(if .*?)?(echo|call :Summary)\b' -or $t -notmatch $want -or $t -match '^(?i)echo  \S') { continue }
        $n++; $ok = $false
        for ($j = $i + 1; $j -lt $cmd.Count; $j++) {
            $u = $cmd[$j].Trim()
            if ($u -match '^(?i)(if .*?)?call :RestartNote$') { $ok = $true; break }
            if ($u -match '^(?i)(pause|goto\b|exit\b|:\w)') { break }
        }
        if (-not $ok) { $miss += ('{0}: {1}' -f ($i + 1), $t) }
    }
    Assert-True ($n -ge 20) "Only $n reboot result lines found - the scan no longer recognises them."
    Assert-True ($miss.Count -eq 0) ('A reboot screen ends without :RestartNote: ' + ($miss -join ' | '))
    $code = @($cmd | ForEach-Object { $_.Trim() })
    foreach ($g in 'if "!_dismrc!"=="3010" call :RestartNote', 'if "!_cwrc!"=="3010" call :RestartNote') {
        Assert-True (@($code | Where-Object { $_ -ceq $g }).Count -eq 1) "Exit code 3010 (restart needed) no longer brings the restart note: $g"
    }
    Assert-True (@($code | Where-Object { $_ -ceq 'if "%_FAILS%"=="0" call :RestartNote' }).Count -eq 2) 'The driver toggle shows the restart note after a failed write.'
    $mi = [Array]::IndexOf($code, 'if defined _mmok call :RestartNote')
    Assert-True ($mi -gt 0 -and $code[$mi - 1] -ceq 'set "_mmok=" & for %%r in (0 1 2) do if "%_mmrc%"=="%%r" set "_mmok=1"') 'Memory compression shows the restart note after it changed nothing.'

    $body = @(Get-BodyLines -Lines $cmd -Label 'RestartNote')
    $q = [ordered]@{
        fsv = 'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled'
        fsp = 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v HiberbootEnabled'
        fsh = 'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v HibernateEnabled'
    }
    foreach ($k in $q.Keys) { Assert-True (@($body | Where-Object { $_.Contains($q[$k]) }).Count -eq 1) ('test 159: :RestartNote no longer asks the registry the way this test fakes it: ' + $q[$k]) }
    $drvBody = @(foreach ($s in $body) { foreach ($k in $q.Keys) { $s = $s.Replace($q[$k], ('type "!PT159!\{0}.txt"' -f $k)) }; $s })
    # HiberbootEnabled, its policy, HibernateEnabled ('' = absent), note expected
    $cases = @(@('0x1', '', '0x1', $true), @('0x0', '', '0x1', $false), @('0x0', '0x1', '0x1', $true), @('0x0', '0x0', '0x1', $false),
               @('0x1', '0x0', '0x1', $true), @('0x1', '0x1', '0x0', $false), @('', '', '', $true), @('0x1', '', '', $true))
    $ks = @($q.Keys); $vn = @('HiberbootEnabled', 'HiberbootEnabled', 'HibernateEnabled')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt159_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path $cd)
            for ($k = 0; $k -lt 3; $k++) {
                if ($cases[$c][$k]) { [IO.File]::WriteAllText((Join-Path $cd ($ks[$k] + '.txt')), ("`r`nHKEY_LOCAL_MACHINE\X`r`n    {0}    REG_DWORD    {1}`r`n`r`n" -f $vn[$k], $cases[$c][$k])) }
            }
            $drv += @(('set "PT159=' + $cd + '"'), "echo [CASE#$c]", 'call :RestartNote')
        }
        $drv += @('echo [END]', 'exit /b 0', ':RestartNote') + $drvBody
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 159: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]
            Assert-True (($sec[$c] -match 'Use Restart, not Shut down') -eq $x[3]) ('HiberbootEnabled={0} policy={1} HibernateEnabled={2}: the restart note {3}. Output: {4}' -f $x[0], $x[1], $x[2], $(if ($x[3]) { 'is missing' } else { 'shows though Fast Startup cannot be on' }), $sec[$c])
        }
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# 160. Sticky / Filter / Toggle Keys: only the shortcut bit is cleared, odd values are left alone (run).
Invoke-Test 'The accessibility shortcut switch is asked for, clears only the shortcut bit and skips odd values (run)' {
    $cmd = Read-Lines $CmdPath
    $calls = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)call :AccessKeysOff\b' })
    Assert-True ($calls.Count -eq 1 -and $calls[0].Trim() -ceq 'if /i "!_q13!"=="Y" call :AccessKeysOff') ('The shortcut switch runs without its own Y/N question: ' + ($calls -join ' | '))
    $perf = @(Get-BodyLines -Lines $cmd -Label 'Performance' -CodeOnly | ForEach-Object { $_.Trim() })
    $ia = -1; $ic = -1
    for ($i = 0; $i -lt $perf.Count; $i++) { if ($perf[$i].Contains('set /p "_q13=')) { $ia = $i }; if ($perf[$i] -ceq $calls[0].Trim()) { $ic = $i } }
    Assert-True ($ia -ge 0 -and $ic -gt $ia -and $perf[$ia].StartsWith('set "_q13=" & ')) 'The shortcut question is missing from :Performance, not reset first, or asked after the switch runs.'
    $ako = @(Get-BodyLines -Lines $cmd -Label 'AccessKeysOff' -CodeOnly | Where-Object { $_ -match 'call :_akOne' } | ForEach-Object { $_.Trim() })
    $keys = @(@('StickyKeys', 'Sticky Keys'), @('Keyboard Response', 'Filter Keys'), @('ToggleKeys', 'Toggle Keys'))
    Assert-True (($ako -join '|') -ceq (@($keys | ForEach-Object { 'call :_akOne "{0}" "{1}"' -f $_[0], $_[1] }) -join '|')) ('The switch no longer covers exactly Sticky, Filter and Toggle Keys: ' + ($ako -join ' | '))

    $ak = @(Get-BodyLines -Lines $cmd -Label '_akOne')
    $rq = 'reg query "!_akk!" /v Flags'
    Assert-True (@($ak | Where-Object { $_.Contains($rq) }).Count -eq 1) 'test 160: :_akOne no longer reads Flags the way this test fakes it.'
    $ak = @($ak | ForEach-Object { $_.Replace($rq, 'type "!PT160!\flags.txt"') })
    # key index, type, data ('' = absent), value written ('' = none), why nothing was written
    $cases = @(@(0, 'REG_SZ', '510', '506', ''), @(1, 'REG_SZ', '126', '122', ''), @(2, 'REG_SZ', '62', '58', ''), @(0, 'REG_SZ', '4', '0', ''),
               @(0, 'REG_SZ', '506', '', 'already off'), @(0, 'REG_SZ', '0', '', 'already off'),
               @(0, 'REG_DWORD', '0x1fe', '', 'could not be read'), @(0, 'REG_SZ', '0510', '', 'could not be read'), @(0, 'REG_SZ', '1234567', '', 'could not be read'),
               @(0, 'REG_SZ', '5a0', '', 'could not be read'), @(1, 'REG_SZ', '126 x', '', 'could not be read'), @(2, '', '', '', 'could not be read'))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt160_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path $cd)
            if ($x[1]) { [IO.File]::WriteAllText((Join-Path $cd 'flags.txt'), ("`r`nHKEY_CURRENT_USER\Control Panel\Accessibility\{0}`r`n    Flags    {1}    {2}`r`n`r`n" -f $keys[$x[0]][0], $x[1], $x[2])) }
            $drv += @(('set "PT160=' + $cd + '"'), "echo [CASE#$c]", ('call :_akOne "{0}" "{1}"' -f $keys[$x[0]][0], $keys[$x[0]][1]))
        }
        $drv += @('echo [END]', 'exit /b 0', ':_akOne') + $ak + @(':SafeRegAdd', 'echo [REGWRITE] %~1 / %~2 / %~3 / %~4', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 160: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $who = '{0} Flags {1} {2}' -f $keys[$x[0]][1], $x[1], $x[2]
            $w = @([regex]::Matches($sec[$c], '\[REGWRITE\][^\n]*') | ForEach-Object { $_.Value.TrimEnd() })
            if ($x[3]) {
                $exp = '[REGWRITE] HKCU\Control Panel\Accessibility\{0} / Flags / REG_SZ / {1}' -f $keys[$x[0]][0], $x[3]
                Assert-True ($w.Count -eq 1 -and $w[0] -ceq $exp) ('{0}: expected one write of {1}, got: {2}' -f $who, $x[3], $sec[$c])
            }
            else { Assert-True ($w.Count -eq 0 -and $sec[$c].Contains($x[4])) ('{0}: expected no write and "{1}", got: {2}' -f $who, $x[4], $sec[$c]) }
        }
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# 161. Clipboard policies are opt-in; the Windows Update reset sets the BITS queue aside in order (part run).
Invoke-Test 'Clipboard policies are asked for, and the Windows Update reset clears the BITS queue in order (part run)' {
    $cmd = Read-Lines $CmdPath
    $code = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' })
    $priv = @(Get-BodyLines -Lines $cmd -Label 'Privacy' -CodeOnly | ForEach-Object { $_.Trim() })
    foreach ($v in @(@('AllowCrossDeviceClipboard', '_clip'), @('AllowClipboardHistory', '_cliph'))) {
        $w = @($code | Where-Object { $_.Contains('"' + $v[0] + '"') })
        $exp = 'if /i "!{0}!"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "{1}" REG_DWORD 0 ' -f $v[1], $v[0]
        Assert-True ($w.Count -eq 1 -and $w[0].Trim().StartsWith($exp)) ('{0} is written without its own Y/N question, or more than once: {1}' -f $v[0], ($w -join ' | '))
        $iz = [Array]::IndexOf($priv, ('set "{0}="' -f $v[1])); $ip = -1; $iw = [Array]::IndexOf($priv, $w[0].Trim())
        for ($i = 0; $i -lt $priv.Count; $i++) { if ($priv[$i].StartsWith(('set /p "{0}=' -f $v[1]))) { $ip = $i } }
        Assert-True ($iz -ge 0 -and $ip -gt $iz -and $iw -gt $ip) ('{0}: its answer is not reset, asked, then acted on inside :Privacy.' -f $v[0])
    }

    $wu = @(Get-BodyLines -Lines $cmd -Label 'WUReset' | ForEach-Object { $_.Trim() })
    $at = [ordered]@{ stop = '^for %%S in \(wuauserv bits .*net stop'; qmgr = '^for %%F in \("%ALLUSERSPROFILE%\\Microsoft\\Network\\Downloader\\qmgr\*\.dat"\) do \('
                      start = '^for %%S in \(wuauserv bits .*net start'; reset = '^"%SystemRoot%\\System32\\bitsadmin\.exe" /reset /allusers >nul 2>&1$'
                      log = '^call :Log "WUReset BITS: '; elev = '^if "%_ELEV%"=="0" \($' }
    $pos = @(foreach ($k in $at.Keys) { $h = @(for ($i = 0; $i -lt $wu.Count; $i++) { if ($wu[$i] -match $at[$k]) { $i } }); Assert-True ($h.Count -eq 1) "test 161: :WUReset step '$k' is missing or repeated."; $h[0] })
    for ($i = 1; $i -lt $pos.Count; $i++) { Assert-True ($pos[$i] -gt $pos[$i - 1]) ('The Windows Update reset no longer runs stop, set qmgr*.dat aside, start, bitsadmin /reset, log, then the elevation check: ' + (@($at.Keys) -join ' > ')) }
    Assert-True (@($wu | Where-Object { $_ -notmatch '^(?i)(rem|echo)\b' -and $_ -match '(?i)\b(del|erase|rd|rmdir)\b.*qmgr' }).Count -eq 0) 'The Windows Update reset deletes the BITS queue files - it must only rename them.'
    $said = @($wu | Where-Object { $_ -match '^if (not )?"!_bitsrc!"==' })
    Assert-True ($said.Count -eq 3 -and $said[0].StartsWith('if "!_bitsrc!"=="0" echo ') -and $said[1].StartsWith('if "!_bitsrc!"=="skip" echo ') -and $said[2].StartsWith('if not "!_bitsrc!"=="0" if not "!_bitsrc!"=="skip" echo      [WARN] ')) ('The BITS result is not reported as cleared / not present / [WARN]: ' + ($said -join ' | '))

    # run the rename loop on a fake Downloader folder; one file is held open, so its rename fails
    $s = [Array]::IndexOf($wu, 'set "_qmn=0"'); $e = -1
    for ($i = $s + 1; $i -lt $wu.Count; $i++) { if ($wu[$i] -eq ')') { $e = $i; break } }
    Assert-True ($s -gt 0 -and $e -gt $s) 'test 161: the qmgr*.dat loop could not be sliced.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt161_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $lock = $null
    try {
        foreach ($f in 'qmgr0.dat', 'qmgr1.dat', 'qmgr.db', 'other.dat') { [IO.File]::WriteAllText((Join-Path $dir $f), 'x') }
        $lock = [IO.File]::Open((Join-Path $dir 'qmgr1.dat'), 'Open', 'Read', 'None')
        $loop = @($wu[$s..$e] | ForEach-Object { $_ -replace '(?i)%ALLUSERSPROFILE%\\Microsoft\\Network\\Downloader', $dir.Replace('$', '$$') })
        Assert-True (@($loop | Where-Object { $_ -match '(?i)ALLUSERSPROFILE' }).Count -eq 0 -and @($loop | Where-Object { $_.Contains($dir) }).Count -eq 1) 'test 161: the Downloader path was not redirected into the test folder - refusing to rename real files.'
        $r = Invoke-CmdDriver -Lines (@('@echo off', 'setlocal EnableDelayedExpansion') + $loop + @('echo [QMN]!_qmn!', 'exit /b 0')) -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 161: the loop driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        Assert-True ($r.Out -contains '[QMN]1') ('The loop should count the one rename that worked, not the held file: ' + ($r.Out -join ' '))
        $names = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { $_.Name })
        Assert-True ((@($names | Where-Object { $_ -like 'qmgr0.dat.bak_*' }).Count -eq 1) -and ($names -notcontains 'qmgr0.dat') -and ($names -contains 'qmgr1.dat') -and ($names -contains 'qmgr.db') -and ($names -contains 'other.dat')) ('Only qmgr0.dat should be set aside: ' + ($names -join ', '))
    }
    finally {
        if ($lock) { $lock.Dispose() }
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}


# 162. Windows.old, Reserved Storage and CompactOS undo: supported tools only, verdicts from the result (run).
Invoke-Test 'Windows.old, Reserved Storage and CompactOS undo use the supported tools and report what happened (run)' {
    $cmd = Read-Lines $CmdPath
    $code = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' })
    Assert-True (@($code | Where-Object { $_ -match '(?i)\b(rd|rmdir|del|erase|takeown|icacls)\b.*Windows\.old' }).Count -eq 0) 'Windows.old is deleted by hand - only DISM and the Settings route are supported.'
    Assert-True (@($code | Where-Object { $_ -match '(?i)ReserveManager' }).Count -eq 0) 'Reserved Storage is changed in the registry - only DISM /Set-ReservedStorageState is supported.'
    foreach ($g in 'if "!sel!"=="6" goto WinOldRemove', 'if "!sel!"=="7" goto ReservedStorage', 'if "!sel!"=="8" goto CompactOSUndo') {
        Assert-True (@($code | Where-Object { $_.Trim() -ceq $g }).Count -eq 1) "The Cleanup menu no longer offers: $g (Compact WinSxS points to option 8)."
    }
    $routines = [ordered]@{
        WinOldRemove    = @(Get-BodyLines -Lines $cmd -Label 'WinOldRemove')
        ReservedStorage = @(Get-BodyLines -Lines $cmd -Label 'ReservedStorage') + @(':ReservedStorage_ask') + @(Get-BodyLines -Lines $cmd -Label 'ReservedStorage_ask')
        CompactOSUndo   = @(Get-BodyLines -Lines $cmd -Label 'CompactOSUndo')
    }
    Assert-True (@($code | Where-Object { $_ -match '(?i)call :RunLive "compact\.exe /compactos:query"' }).Count -eq 0) ':CompactOSUndo sends the state query through :RunLive again, which logs its exit code (the state, 101 when not compact) as FAIL.'
    $drvBody = @()
    $nq = 0
    foreach ($k in $routines.Keys) {
        Assert-True ($routines[$k].Count -gt 20) ":$k is missing or did not unroll."
        $drvBody += ':' + $k
        foreach ($s in $routines[$k]) {
            $t = $s.Trim()
            if ($t -ieq 'cls' -or $t -ieq 'pause' -or $t -ieq 'call :Logo') { $drvBody += 'rem ' + $t; continue }
            # the CompactOS query runs bare (its exit code is the state), so it is echoed like :RunLive
            if ($t -ceq 'compact.exe /compactos:query') { $drvBody += 'echo [RUN] compact.exe /compactos:query'; $nq++; continue }
            $drvBody += ($s -replace '^(\s*)set /p "(\w+)=.*$', '$1set "$2=!PT_ANS!"')
        }
    }
    Assert-True ($nq -eq 1) 'test 162: the bare CompactOS query was not found to stub.'
    $stubs = @(':RunLive', 'echo [RUN] %~1', 'set "_runrc=!PT_RC!"', 'if defined PT_DEL if exist "!PT_DEL!\" rd /s /q "!PT_DEL!"', 'goto :eof',
               ':FreeSpaceSnap', 'set "_FREE_BYTES=1"', 'goto :eof', ':FreeSpaceReport', 'echo [FREE]', 'goto :eof',
               ':Log', 'goto :eof', ':NoInput', 'exit /b 1', ':MenuCleanup', 'goto :eof', ':ExitScript', 'goto :eof')
    $q = 'dism /online /Get-ReservedStorageState'; $off = 'dism /online /Set-ReservedStorageState /State:Disabled'; $on = 'dism /online /Set-ReservedStorageState /State:Enabled'
    $wo = 'dism /online /Remove-OSUninstall'; $cq = 'compact.exe /compactos:query'; $cn = 'compact.exe /compactos:never'
    $settings = 'Settings > System > Storage > Temporary files >'
    # routine, Windows.old there, DISM removes it, elevated, build, answer, exit code, commands run, must say, must not say
    $cases = @(
        @('WinOldRemove', 1, 1, 1, '22631', 'Y', '0', @($wo), @('[OK] Windows.old is gone', '[FREE]'), @('[WARN]', $settings)),
        @('WinOldRemove', 1, 0, 1, '22631', 'Y', '0', @($wo), @('[WARN] DISM removed the way back, but', $settings), @('[OK]')),
        @('WinOldRemove', 1, 0, 1, '22631', 'Y', '1168', @($wo), @('[WARN] DISM could not remove it (exit code 1168)', $settings), @('[OK]')),
        @('WinOldRemove', 0, 0, 1, '22631', 'Y', '0', @(), @('[i] There is no Windows.old'), @('[OK]', '[WARN]')),
        @('WinOldRemove', 1, 0, 0, '22631', 'Y', '0', @(), @('[WARN] Not elevated'), @('[OK]')),
        @('WinOldRemove', 1, 0, 1, '22631', 'N', '0', @(), @(), @('[OK]', '[WARN]', '[FREE]')),
        @('ReservedStorage', 0, 0, 1, '22631', '1', '0', @($q, $off), @('[OK] Reserved Storage is now off.', '[FREE]'), @('[FAIL]')),
        @('ReservedStorage', 0, 0, 1, '22631', '2', '0', @($q, $on), @('[OK] Reserved Storage is now on.'), @('[FAIL]')),
        @('ReservedStorage', 0, 0, 1, '22631', '1', '5', @($q, $off), @('[FAIL] DISM could not turn Reserved Storage off (exit code 5)'), @('[OK]')),
        @('ReservedStorage', 0, 0, 1, '18363', '1', '0', @(), @('[i] Build 18363 is older than Windows 10 2004'), @('[OK]')),
        @('ReservedStorage', 0, 0, 1, '', '0', '0', @($q), @(), @('[OK]', '[FAIL]', '[FREE]')),
        @('ReservedStorage', 0, 0, 0, '22631', '1', '0', @(), @('[WARN] Not elevated'), @('[OK]')),
        @('CompactOSUndo', 0, 0, 1, '22631', 'Y', '0', @($cq, $cn), @('[OK] CompactOS is off', '[FREE]'), @('[FAIL]')),
        @('CompactOSUndo', 0, 0, 1, '22631', 'Y', '87', @($cq, $cn), @('[FAIL] compact did not finish (exit code 87)'), @('[OK]')),
        @('CompactOSUndo', 0, 0, 1, '22631', 'N', '0', @($cq), @(), @('[OK]', '[FAIL]', '[FREE]')),
        @('CompactOSUndo', 0, 0, 0, '22631', 'Y', '0', @(), @('[WARN] Not elevated'), @('[OK]')))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt162_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path $cd)
            if ($x[1]) { [void](New-Item -ItemType Directory -Path (Join-Path $cd 'Windows.old')) }
            $drv += @(('set "SystemDrive=' + $cd + '"'), ('set "PT_DEL=' + $(if ($x[2]) { Join-Path $cd 'Windows.old' }) + '"'), ('set "_ELEV=' + $x[3] + '"'),
                      ('set "WIN_BUILD=' + $x[4] + '"'), ('set "PT_ANS=' + $x[5] + '"'), ('set "PT_RC=' + $x[6] + '"'), "echo [CASE#$c]", ('call :' + $x[0]))
        }
        $drv += @('echo [END]', 'exit /b 0') + $drvBody + $stubs
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir -Allow '^(?i)(if .*?)?call :RunLive "[^"]*"$'
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 162: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $who = '{0} (Windows.old {1}, removed {2}, elevated {3}, build "{4}", answer {5}, exit {6})' -f $x[0], $x[1], $x[2], $x[3], $x[4], $x[5], $x[6]
            $ran = @([regex]::Matches($sec[$c], '\[RUN\] ([^\n]*)') | ForEach-Object { $_.Groups[1].Value.TrimEnd() })
            Assert-True (($ran -join ' | ') -ceq (@($x[7]) -join ' | ')) ('{0}: ran [{1}], expected [{2}]' -f $who, ($ran -join ' | '), (@($x[7]) -join ' | '))
            foreach ($m in $x[8]) { Assert-True ($sec[$c].Contains($m)) ('{0}: should say "{1}". Output: {2}' -f $who, $m, $sec[$c]) }
            foreach ($m in $x[9]) { Assert-True (-not $sec[$c].Contains($m)) ('{0}: should not say "{1}". Output: {2}' -f $who, $m, $sec[$c]) }
        }
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}


# 163. USB selective suspend: asked for, AC only, and captured by the power undo file first.
Invoke-Test 'USB selective suspend is asked for, changed on AC only, and the power undo file restores it' {
    $cmd = Read-Lines $CmdPath
    $code = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' } | ForEach-Object { $_.Trim() })
    $calls = @($code | Where-Object { $_ -match '(?i)call :UsbSuspendOffAc\b' })
    Assert-True ($calls.Count -eq 1 -and $calls[0] -ceq 'if /i "!_usb!"=="Y" call :UsbSuspendOffAc') ('USB suspend changes without its own Y/N question: ' + ($calls -join ' | '))
    $opt = @(Get-BodyLines -Lines $cmd -Label '_pwOptional' -NoEcho | ForEach-Object { $_.Trim() })
    $ia = -1; for ($i = 0; $i -lt $opt.Count; $i++) { if ($opt[$i].StartsWith('set /p "_usb=')) { $ia = $i } }
    $ic = [Array]::IndexOf($opt, $calls[0])
    Assert-True ($ia -gt 0 -and $opt[$ia - 1] -ceq 'set "_usb="' -and $ic -gt $ia) 'The USB question is not reset, asked, then acted on inside the power options.'
    $usb = @(Get-BodyLines -Lines $cmd -Label 'UsbSuspendOffAc' -CodeOnly | ForEach-Object { $_.Trim() })
    $pc = @($usb | Where-Object { $_ -match '(?i)powercfg' })
    $sub = '2a737441-1930-4402-8d77-b2bebba308a3'; $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    Assert-True ($pc.Count -eq 2 -and $pc[0] -ceq ('call :Run "powercfg /setacvalueindex scheme_current {0} {1} 0"' -f $sub, $set) -and $pc[1] -ceq 'call :Run "powercfg /setactive scheme_current"') ('USB suspend is not set to 0 on AC only, then applied: ' + ($pc -join ' | '))
    $bk = [Array]::IndexOf($usb, 'call :PowerBackup')
    Assert-True ($bk -ge 0 -and $bk -lt [Array]::IndexOf($usb, $pc[0])) 'USB suspend changes before the power undo file captures it.'
    $w = @($cmd | Where-Object { $_.Contains('PT_PWBAK -Value $L') })
    Assert-True ($w.Count -eq 1 -and $w[0].Contains(("@('{0}','{1}','USB selective suspend')" -f $sub, $set))) 'The power undo file does not capture USB selective suspend, so Revert power settings cannot put it back.'
}

# 164. NetBIOS + LLMNR: the policy and every Tcpip_ adapter, off and back to the defaults (run).
Invoke-Test 'NetBIOS and LLMNR go off on every adapter and back to the Windows defaults (run)' {
    $cmd = Read-Lines $CmdPath
    $body = @(Get-BodyLines -Lines $cmd -Label 'NetLegacyNames') + @(':NetLegacyNames_ask') + @(Get-BodyLines -Lines $cmd -Label 'NetLegacyNames_ask') + @(':_nlAdapter') + @(Get-BodyLines -Lines $cmd -Label '_nlAdapter')
    $rq = 'reg query "HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"'
    Assert-True (@($body | Where-Object { $_.Contains($rq) }).Count -eq 1) 'test 164: :NetLegacyNames no longer lists the adapters the way this test fakes it.'
    $drvBody = @(foreach ($s in $body) {
        $t = $s.Trim()
        if ($t -ieq 'cls' -or $t -ieq 'pause' -or $t -ieq 'call :Logo') { 'rem ' + $t; continue }
        ($s.Replace($rq, 'type "!PT164!\ifs.txt"') -replace '^(\s*)set /p "(\w+)=.*$', '$1set "$2=!PT_ANS!"')
    })
    $stubs = @(':SafeRegAdd', 'echo [ADD] %~1 / %~2 / %~3 / %~4', 'goto :eof', ':SafeRegDelete', 'echo [DEL] %~1 / %~2', 'goto :eof',
               ':Summary', 'echo [SUM] %~1', 'goto :eof', ':RestartNote', 'echo [RESTART]', 'goto :eof', ':NoInput', 'exit /b 1', ':MenuNetwork', 'goto :eof', ':ExitScript', 'goto :eof')
    $ifs = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    $two = "`r`n$ifs\Tcpip_{1111-A}`r`n$ifs\Tcpip_{2222-B}`r`n$ifs\Other`r`n"
    $pol = 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
    $nb = 'HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\'
    # answer, listing, expected writes in order
    $cases = @(
        @('1', $two, @("[ADD] $pol / EnableMulticast / REG_DWORD / 0", "[ADD] $($nb)Tcpip_{1111-A} / NetbiosOptions / REG_DWORD / 2", "[ADD] $($nb)Tcpip_{2222-B} / NetbiosOptions / REG_DWORD / 2", '[SUM] NetBIOS and LLMNR turned off. Reboot recommended.', '[RESTART]')),
        @('2', $two, @("[DEL] $pol / EnableMulticast", "[ADD] $($nb)Tcpip_{1111-A} / NetbiosOptions / REG_DWORD / 0", "[ADD] $($nb)Tcpip_{2222-B} / NetbiosOptions / REG_DWORD / 0", '[SUM] NetBIOS and LLMNR back to the Windows defaults. Reboot recommended.', '[RESTART]')),
        @('1', '', @("[ADD] $pol / EnableMulticast / REG_DWORD / 0", '[SUM] NetBIOS and LLMNR turned off. Reboot recommended.', '[RESTART]')),
        @('0', $two, @()))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt164_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path $cd)
            if ($cases[$c][1]) { [IO.File]::WriteAllText((Join-Path $cd 'ifs.txt'), $cases[$c][1]) }
            $drv += @(('set "PT164=' + $cd + '"'), ('set "PT_ANS=' + $cases[$c][0] + '"'), "echo [CASE#$c]", 'call :NetLegacyNames')
        }
        $drv += @('echo [END]', 'exit /b 0', ':NetLegacyNames') + $drvBody + $stubs
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 164: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $got = @($sec[$c] -split "`n" | Where-Object { $_ -match '^\[(ADD|DEL|SUM|RESTART)\]' } | ForEach-Object { $_.TrimEnd() })
            Assert-True (($got -join ' | ') -ceq (@($cases[$c][2]) -join ' | ')) ('answer {0}: wrote [{1}], expected [{2}]' -f $cases[$c][0], ($got -join ' | '), (@($cases[$c][2]) -join ' | '))
        }
        Assert-True ($sec[2].Contains('[i] No adapter is listed')) ('An empty adapter list is not reported: ' + $sec[2])
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# 165. Intel / AMD usage-report services: found by their program, listed, disabled only on yes (run).
Invoke-Test 'Intel and AMD usage-report services are found by their program and disabled only on yes (run)' {
    $cmd = Read-Lines $CmdPath
    $gt = @(@('GpuTelemetry', 'GpuNvidia', 'GpuAmd') | ForEach-Object { $b = @(Get-BodyLines -Lines $cmd -Label $_ -CodeOnly); $b } | ForEach-Object { $_.Trim() })
    $gv = @($gt | Where-Object { $_ -match 'GpuVendorSvc' })
    Assert-True ($gv.Count -eq 4) ('Every way out of the GPU vendor offers (no GPU, after NVIDIA, AMD declined, AMD done) should lead to the vendor services, found ' + $gv.Count + ': ' + ($gv -join ' | '))
    Assert-True (@(Get-BodyLines -Lines $cmd -Label 'DoGpuTelemetryOff' -CodeOnly | Where-Object { $_ -match 'GpuVendorSvc|_gvsOff' }).Count -eq 0) 'Presets disable vendor services without asking.'
    $body = @(Get-BodyLines -Lines $cmd -Label 'GpuVendorSvc') + @(':_gvsOff') + @(Get-BodyLines -Lines $cmd -Label '_gvsOff')
    $rq = 'reg query "HKLM\SYSTEM\CurrentControlSet\Services" /s /v ImagePath'
    $sc = 'sc stop "!_vsx!" >nul 2>&1'
    Assert-True (@($body | Where-Object { $_.Contains($rq) }).Count -eq 1 -and @($body | Where-Object { $_.Trim() -ceq $sc }).Count -eq 1) 'test 165: the vendor scan no longer reads services, or stops them, the way this test fakes it.'
    $drvBody = @(foreach ($s in $body) {
        $t = $s.Trim()
        if ($t -ieq 'pause') { 'rem pause'; continue }
        if ($t -ceq $sc) { 'echo [STOP] !_vsx!'; continue }
        ($s.Replace($rq, 'type "!PT165!\svc.txt"') -replace '^(\s*)set /p "(\w+)=.*$', '$1set "$2=!PT_ANS!"')
    })
    $stubs = @(':SafeRegAdd', 'echo [ADD] %~1 / %~2 / %~3 / %~4', 'goto :eof', ':Summary', 'echo [SUM] %~1', 'goto :eof', ':MenuAdvanced', 'goto :eof')
    $k = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\'
    $ent = { param($n, $v) "$k$n`r`n    ImagePath    REG_EXPAND_SZ    $v`r`n`r`n" }
    $svc = "`r`n" + (& $ent 'ESRV_SVC_QUEENCREEK' '"C:\Program Files\Intel\SUR\QUEENCREEK\x64\esrv_svc.exe"') + (& $ent 'Spooler' '%SystemRoot%\System32\spoolsv.exe') +
           (& $ent 'Intel(R) SUR QC SAM' '"C:\Program Files\Intel\SUR\QUEENCREEK\Updater\bin\IntelSoftwareAssetManagerService.exe"') +
           (& $ent 'Foo\Parameters' 'C:\Program Files\Intel\SUR\x.exe') + (& $ent 'AMD Crash Defender Service' 'C:\Windows\System32\amdfendrsr.exe') +
           (& $ent 'AUEPLauncher' '"C:\Program Files\AMD\Performance Profile Client\AUEPLauncher.exe"') + "End of search: 6 match(es) found.`r`n"
    $found = @('ESRV_SVC_QUEENCREEK', 'Intel(R) SUR QC SAM', 'AUEPLauncher')
    $cases = @(@('Y', $svc), @('N', $svc), @('Y', "`r`nEnd of search: 0 match(es) found.`r`n"))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt165_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path $cd)
            [IO.File]::WriteAllText((Join-Path $cd 'svc.txt'), $cases[$c][1])
            $drv += @(('set "PT165=' + $cd + '"'), ('set "PT_ANS=' + $cases[$c][0] + '"'), "echo [CASE#$c]", 'call :GpuVendorSvc')
        }
        $drv += @('echo [END]', 'exit /b 0', ':GpuVendorSvc') + $drvBody + $stubs
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 165: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        $listed = @($sec[0] -split "`n" | Where-Object { $_ -match '^    - ' } | ForEach-Object { $_.Substring(6).TrimEnd() })
        Assert-True (($listed -join ' | ') -ceq ($found -join ' | ')) ('Listed [{0}], expected the Intel SUR and AMD AUEP services only [{1}]' -f ($listed -join ' | '), ($found -join ' | '))
        $want = @(foreach ($n in $found) { "[ADD] HKLM\SYSTEM\CurrentControlSet\Services\$n / Start / REG_DWORD / 4"; "[STOP] $n" }) + @('[SUM] Intel / AMD usage-report services disabled.')
        $got = @($sec[0] -split "`n" | Where-Object { $_ -match '^\[(ADD|STOP|SUM)\]' } | ForEach-Object { $_.TrimEnd() })
        Assert-True (($got -join ' | ') -ceq ($want -join ' | ')) ('Yes: did [{0}], expected [{1}]' -f ($got -join ' | '), ($want -join ' | '))
        Assert-True ($sec[1] -notmatch '\[(ADD|STOP|SUM)\]' -and $sec[1].Contains('    - AUEPLauncher')) ('No: services were touched, or not listed first: ' + $sec[1])
        Assert-True ($sec[2] -notmatch '\[(ADD|STOP|SUM)\]' -and $sec[2].Contains('[i] No Intel or AMD usage-report service found')) ('None found: ' + $sec[2])
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}


# 166. Leftover settings check: reads only, judges each finding right, fixes only what was asked (run).
Invoke-Test 'The leftover-settings check reads only, judges each finding, and fixes only what was asked (run)' {
    $cmd = Read-Lines $CmdPath
    $w = @($cmd | Where-Object { $_.Contains('PT_LC_RES -Value $r') })
    Assert-True ($w.Count -eq 1) 'test 166: the boot-configuration worker could not be found.'
    Assert-True ($w[0] -notmatch '(?i)Set(Boolean|Integer|String|Object|Device)\w*Element|DeleteElement|bcdedit|CreateStore|ImportStore') 'The boot-configuration worker can change the store - it must only read.'
    Assert-True ($w[0].Contains("OpenObject -Arguments @{Id='{fa926493-6f1c-4193-a414-58f0b2456d1e}'}")) 'The worker no longer opens {current} by its well-known ID.'
    $codes = [ordered]@{ testsigning = '0x16000049'; nointegritychecks = '0x16000048'; nx = '0x25000020'; numproc = '0x25000061'; onecpu = '0x26000060'; truncatememory = '0x15000007'; removememory = '0x25000031' }
    foreach ($k in $codes.Keys) { Assert-True ($w[0].Contains(("@('{0}',{1})" -f $k, $codes[$k]))) ('The worker reads {0} under a different element code than Microsoft documents ({1}).' -f $k, $codes[$k]) }

    $labels = @('LeftoverCheck', '_lcBcd', '_lcBcdRec', '_lcCapDel', '_lcUac', '_lcSvcAll', '_lcSvc', '_lcSvcFix')
    $uq = 'reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA'
    $sq = 'reg query "HKLM\SYSTEM\CurrentControlSet\Services\!_lcs!" /v Start'
    $drvBody = @()
    foreach ($lb in $labels) {
        $b = @(Get-BodyLines -Lines $cmd -Label $lb)
        Assert-True ($b.Count -gt 2) ":$lb is missing or did not unroll."
        $drvBody += ':' + $lb
        foreach ($s in $b) {
            $t = $s.Trim()
            if ($t -ieq 'cls' -or $t -ieq 'pause' -or $t -ieq 'call :Logo') { $drvBody += 'rem ' + $t; continue }
            if ($s.Contains('PT_LC_RES -Value $r')) { $drvBody += 'if exist "!PT166!\bcd.txt" copy /y "!PT166!\bcd.txt" "!_lcres!" >nul'; continue }
            $drvBody += ($s.Replace($uq, 'type "!PT166!\uac.txt"').Replace($sq, 'type "!PT166!\svc_!_lcs!.txt"') -replace '^(\s*)set /p "(\w+)=.*$', '$1set "$2=!PT_ANS!"')
        }
    }
    Assert-True (@($drvBody | Where-Object { $_.Contains('!PT166!\uac.txt') }).Count -eq 1 -and @($drvBody | Where-Object { $_.Contains('!PT166!\svc_') }).Count -eq 1) 'test 166: the check no longer reads UAC or the services the way this test fakes it.'
    $stubs = @(':Run', 'echo [RUN] %~1', 'set "_runrc=0"', 'goto :eof', ':RunVar', 'echo [RUNVAR] !%~1!', 'set "_runrc=!PT_EXPRC!"', 'goto :eof',
               ':SafeRegAdd', 'echo [ADD] %~1 / %~2 / %~3 / %~4', 'goto :eof', ':Summary', 'echo [SUM] %~1', 'goto :eof', ':RestartNote', 'echo [RESTART]', 'goto :eof',
               ':MenuTools', 'goto :eof', ':NoInput', 'exit /b 1', ':ExitScript', 'goto :eof')
    $reg = { param($n, $v) "`r`nHKEY_LOCAL_MACHINE\X`r`n    $n    REG_DWORD    $v`r`n`r`n" }
    $dirtyBcd = "BCD|testsigning|1`r`nBCD|nointegritychecks|0`r`nBCD|nx|2`r`nBCD|numproc|4`r`nBCD|onecpu|0`r`nBCD|truncatememory|4294967296`r`nEND|ok`r`n"
    $dirtySvc = @{ Dnscache = '0x4'; Appinfo = '0x4'; Schedule = '0x2' }
    $sysk = 'HKLM\SYSTEM\CurrentControlSet\Services\'
    $act = '^\[(RUN|RUNVAR|ADD|SUM|RESTART)\]'
    # bcd file ('' = none), EnableLUA, service Start values, elevated, answer, export exit code, actions (prefix match), must say, must not say
    $cases = @(
        @("BCD|nx|0`r`nEND|ok`r`n", '0x1', @{}, 1, 'Y', '0', @(), @('[OK] No leftover boot flags', '[OK] UAC is on', '[OK] None of the core services', '[OK] Nothing left behind among the settings this checks.'), @('[ADVISORY]')),
        @($dirtyBcd, '0x0', $dirtySvc, 1, 'Y', '0',
          @('[RUNVAR] bcdedit /export "', '[RUN] bcdedit /deletevalue {current} numproc', '[RUN] bcdedit /deletevalue {current} truncatememory',
            '[ADD] HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System / EnableLUA / REG_DWORD / 1',
            "[ADD] $($sysk)Dnscache / Start / REG_DWORD / 2", "[ADD] $($sysk)Appinfo / Start / REG_DWORD / 3", '[SUM] Selected leftovers fixed. Reboot recommended.', '[RESTART]'),
          @('Test Mode is on', 'DEP is off for every program', 'numproc=4:', 'truncatememory=4294967296:', 'UAC is off', 'DNS Client (Dnscache) is Disabled; default: Automatic.', 'Application Information (Appinfo) is Disabled; default: Manual.', '[BACKUP] Boot configuration'),
          @('Driver signature checks are off', 'onecpu:', '(Schedule)', 'deletevalue {current} testsigning', 'deletevalue {current} nx')),
        @($dirtyBcd, '0x0', $dirtySvc, 1, 'N', '0', @(), @('Test Mode is on', 'numproc=4:', 'UAC is off', '(Dnscache) is Disabled'), @('[BACKUP]')),
        @('BCD|unreadable', '0x1', @{}, 1, 'Y', '0', @(), @('[i] The boot configuration could not be read', '[OK] Nothing left behind in what could be read - the boot flags were not checked.'), @('[OK] No leftover boot flags', 'among the settings this checks')),
        @($dirtyBcd, '0x0', @{ Dnscache = '0x4' }, 0, 'Y', '0', @(), @('[i] Skipped: reading it needs Administrator.', 'UAC is off', '(Dnscache) is Disabled', '[WARN] Not elevated - nothing can be fixed'), @('Test Mode is on', 'numproc=')),
        @("BCD|numproc|2`r`nEND|ok`r`n", '0x1', @{}, 1, 'Y', '1', @('[RUNVAR] bcdedit /export "'), @('[FAIL] The boot configuration could not be saved first'), @('[BACKUP]', 'deletevalue')))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt166_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path $cd)
            if ($x[0]) { [IO.File]::WriteAllText((Join-Path $cd 'bcd.txt'), $x[0]) }
            [IO.File]::WriteAllText((Join-Path $cd 'uac.txt'), (& $reg 'EnableLUA' $x[1]))
            foreach ($k in $x[2].Keys) { [IO.File]::WriteAllText((Join-Path $cd "svc_$k.txt"), (& $reg 'Start' $x[2][$k])) }
            $drv += @(('set "PT166=' + $cd + '"'), ('set "BACKUP_DIR=' + $cd + '"'), ('set "_ELEV=' + $x[3] + '"'), ('set "PT_ANS=' + $x[4] + '"'), ('set "PT_EXPRC=' + $x[5] + '"'), "echo [CASE#$c]", 'call :LeftoverCheck')
        }
        $drv += @('echo [END]', 'exit /b 0') + $drvBody + $stubs
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir -Allow '^(?i)((if .*?)?call :Run "[^"]*"|set "_lccmd=bcdedit /export "!_lcbak!"")$'
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 166: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $who = "case $c (elevated $($x[3]), answer $($x[4]), export exit $($x[5]))"
            $got = @($sec[$c] -split "`n" | Where-Object { $_ -match $act } | ForEach-Object { $_.TrimEnd() })
            $ok = $got.Count -eq @($x[6]).Count
            for ($i = 0; $ok -and $i -lt $got.Count; $i++) { $ok = $got[$i].StartsWith($x[6][$i]) }
            Assert-True $ok ('{0}: did [{1}], expected [{2}]' -f $who, ($got -join ' | '), (@($x[6]) -join ' | '))
            foreach ($m in $x[7]) { Assert-True ($sec[$c].Contains($m)) ('{0}: should say "{1}". Output: {2}' -f $who, $m, $sec[$c]) }
            foreach ($m in $x[8]) { Assert-True (-not $sec[$c].Contains($m)) ('{0}: should not say "{1}". Output: {2}' -f $who, $m, $sec[$c]) }
        }
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}


# 167. The page-file wipe option: asked only while the wipe is on, writes only the default, run.
Invoke-Test 'The page-file wipe option is asked only while the wipe is on and writes only the Windows default (run)' {
    $cmd = Read-Lines $CmdPath
    $calls = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)rem\b' -and $_ -match '(?i)call :PageWipeAsk\b' })
    Assert-True ($calls.Count -eq 1 -and $calls[0].Trim() -ceq 'call :PageWipeAsk') ('The wipe option is called from more than one place, or conditionally: ' + ($calls -join ' | '))
    $perf = @(Get-BodyLines -Lines $cmd -Label 'Performance' -CodeOnly | ForEach-Object { $_.Trim() })
    $ip = [Array]::IndexOf($perf, 'call :PageWipeAsk'); $is = [Array]::IndexOf($perf, 'call :Summary "Performance tweaks applied."')
    Assert-True ($ip -gt 0 -and $is -eq $ip + 1) 'The wipe option is not the last question of :Performance, right before its summary.'
    foreach ($lb in 'DoPerformanceCore', 'PresetApplyDirectives') {
        Assert-True (@(Get-BodyLines -Lines $cmd -Label $lb -CodeOnly | Where-Object { $_ -match '(?i)PageWipeAsk|ClearPageFileAtShutdown' }).Count -eq 0) ":$lb reaches the wipe option - presets must not change it."
    }
    $body = @(Get-BodyLines -Lines $cmd -Label 'PageWipeAsk')
    $rq = 'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ClearPageFileAtShutdown'
    Assert-True (@($body | Where-Object { $_.Contains($rq) }).Count -eq 1) 'test 167: :PageWipeAsk no longer reads the value the way this test fakes it.'
    $ask = @($body | Where-Object { $_.Trim().StartsWith('set "_q14=" & set /p "_q14=') })
    Assert-True ($ask.Count -eq 1 -and $ask[0].Contains('Stop wiping the page file at shutdown') -and $ask[0].TrimEnd().EndsWith('(Y/N): "')) ('The question lost its wording, or is not one reset-then-ask line: ' + ($ask -join ' | '))
    # the question becomes a visible marker, then the test's answer
    $drvBody = @($body | ForEach-Object { $_.Replace($rq, 'type "!PT167!\v.txt"') -replace '^(\s*)set "_q14=" & set /p "_q14=.*$', '$1set "_q14=" & echo [PROMPT] & set "_q14=!PT_ANS!"' })
    Assert-True (@($drvBody | Where-Object { $_ -match 'set /p' }).Count -eq 0) 'test 167: the question could not be replaced by the test answer.'
    # value type, data ('' = absent), answer, write fails, asked, written, note; an absent value right after a 1 catches a stale read
    $cases = @(@('REG_DWORD', '0x1', 'Y', 0, $true, $true, $true), @('', '', 'Y', 0, $false, $false, $false),
               @('REG_DWORD', '0x1', 'N', 0, $true, $false, $false), @('REG_DWORD', '0x1', '', 0, $true, $false, $false),
               @('REG_DWORD', '0x1', 'x', 0, $true, $false, $false), @('REG_DWORD', '0x1', 'y', 0, $true, $true, $true),
               @('REG_SZ', '0x1', 'Y', 0, $false, $false, $false), @('REG_QWORD', '0x1', 'Y', 0, $false, $false, $false),
               @('REG_DWORD', '0x0', 'Y', 0, $false, $false, $false), @('REG_DWORD', '0x1', 'Y', 1, $true, $true, $false))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt167_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path $cd)
            if ($x[0]) { [IO.File]::WriteAllText((Join-Path $cd 'v.txt'), ("`r`nHKEY_LOCAL_MACHINE\X`r`n    ClearPageFileAtShutdown    {0}    {1}`r`n`r`n" -f $x[0], $x[1])) }
            $drv += @(('set "PT167=' + $cd + '"'), ('set "PT_ANS=' + $x[2] + '"'), ('set "PT_FAILW=' + $(if ($x[3]) { '1' }) + '"'), "echo [CASE#$c]", 'call :PageWipeAsk')
        }
        $drv += @('echo [END]', 'exit /b 0', ':PageWipeAsk') + $drvBody +
                @(':SafeRegAdd', 'echo [ADD] %~1 / %~2 / %~3 / %~4', 'if defined PT_FAILW echo [WRITEFAIL]', 'if defined PT_FAILW exit /b 1', 'exit /b 0')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 167: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        $want = '[ADD] HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management / ClearPageFileAtShutdown / REG_DWORD / 0'
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $who = 'value {0} {1}, answer "{2}"{3}' -f $x[0], $x[1], $x[2], $(if ($x[3]) { ', write fails' })
            $asked = $sec[$c].Contains('[PROMPT]')
            $adds = @($sec[$c] -split "`n" | Where-Object { $_ -match '^\[ADD\]' } | ForEach-Object { $_.TrimEnd() })
            Assert-True ($asked -eq $x[4]) ('{0}: the question {1}. Output: {2}' -f $who, $(if ($x[4]) { 'is missing' } else { 'shows though the wipe is not a DWORD 1' }), $sec[$c])
            Assert-True ((($adds -join '|') -ceq $(if ($x[5]) { $want } else { '' }))) ('{0}: wrote [{1}]' -f $who, ($adds -join ' | '))
            Assert-True ($sec[$c].Contains('write the 1 back') -eq $x[6]) ('{0}: the security-policy note must follow a write that worked, and nothing else. Output: {1}' -f $who, $sec[$c])
            if ($x[4]) { Assert-True ($sec[$c].Contains('BitLocker') -and $sec[$c].Contains('without a restart') -and $sec[$c].Contains('Windows wipes the page file at every shutdown')) ('{0}: the explanation above the question lost what the wipe protects or that no restart is needed. Output: {1}' -f $who, $sec[$c]) }
        }
    }
    finally { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
}

# 168. Telemetry tasks go by name, and a worker that answered nothing is a [FAIL] (run).
Invoke-Test 'Telemetry tasks go by name, and four workers report no answer as a failure, not as nothing found (run)' {
    $cmd = Read-Lines $CmdPath
    $code = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' })
    Assert-True (@($code | Where-Object { $_ -match '(?i)schtasks\s+/Change\s+/TN\b.*?/Disable\b' }).Count -eq 0) 'A scheduled task is disabled by a fixed path again - 24H2 renamed or dropped those, and an elevated run hides the failure.'
    $tk = @($code | Where-Object { $_ -match '^\s*set "PT_TK_NAMES=' }); $tl = @($code | Where-Object { $_ -match '^\s*set "PT_TL_TASKS=' })
    Assert-True ($tk.Count -eq 1 -and $tl.Count -eq 1) 'test 168: the two task lists could not be found.'
    $tkv = [regex]::Match($tk[0], 'PT_TK_NAMES=([^"]*)"').Groups[1].Value; $tlv = [regex]::Match($tl[0], 'PT_TL_TASKS=([^"]*)"').Groups[1].Value
    Assert-True ($tkv.Length -gt 20 -and $tlv.Length -gt 20) 'test 168: the task lists could not be read.'
    Assert-True ($tkv -ceq $tlv) ('The tasks Privacy disables and the tasks its undo file captures differ: ' + $tkv + ' / ' + $tlv)
    foreach ($n in 'Microsoft Compatibility Appraiser', 'Microsoft Compatibility Appraiser Exp', 'QueueReporting', 'MareBackup') { Assert-True (@($tkv -split '\|') -ccontains $n) "The telemetry task list lost $n." }
    # name, result variable, call line, the answer the worker writes when nothing is there, its [SKIP] text
    $rs = @(@('DisableTelemetryTasks', '_tkres', 'call :DisableTelemetryTasks', '0 0 10 0', 'none of the 10 exist'),
            @('DisableNvidiaTelemetryTasks', '_nvres', 'call :DisableNvidiaTelemetryTasks', '0 0 0', 'none found on this system'),
            @('DiagTrackFirewall', '_fwres', 'call :DiagTrackFirewall', '0 0', 'no DiagTrack rule group'),
            @('DebloatRun', '_dbres', 'call :DebloatRun "a|b" "Test apps"', '0 0 2 0', 'none of these apps are installed'))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt168_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "BACKUP_DIR=' + $dir + '"'))
        $bodies = @(); $c = 0
        foreach ($x in $rs) {
            $b = @(Get-BodyLines -Lines $cmd -Label $x[0])
            $w = @($b | Where-Object { $_ -match '^\s*start "" /min /wait powershell' })
            Assert-True ($w.Count -eq 1) ("test 168: :{0} no longer has one worker line." -f $x[0])
            $bodies += ':' + $x[0]
            $bodies += @($b | ForEach-Object { if ($_ -match '^\s*start "" /min /wait powershell') { 'if defined PT_ANS copy /y "!PT_ANS!" "!' + $x[1] + '!" >nul' } else { $_ } })
            [IO.File]::WriteAllText((Join-Path $dir "ans$c.txt"), ($x[3] + "`r`n"))
            $drv += @('set "PT_ANS="', 'set "_FAILS=0"', "echo [CASE#$($c * 2)]", $x[2], 'echo [FAILS]!_FAILS!')
            $drv += @(('set "PT_ANS=' + (Join-Path $dir "ans$c.txt") + '"'), 'set "_FAILS=0"', "echo [CASE#$($c * 2 + 1)]", $x[2], 'echo [FAILS]!_FAILS!')
            $c++
        }
        $drv += @('echo [END]', 'exit /b 0') + $bodies + @(':Log', 'goto :eof', ':LogVar', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 168: the driver failed: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count ($rs.Count * 2)
        for ($c = 0; $c -lt $rs.Count; $c++) {
            $none = $sec[$c * 2]; $empty = $sec[$c * 2 + 1]
            Assert-True ($none.Contains('[FAIL]') -and $none.Contains('PowerShell returned no answer') -and $none.Contains('[FAILS]1') -and -not $none.Contains('[SKIP]')) (':{0} with no worker answer must fail and count it, not report nothing found: {1}' -f $rs[$c][0], $none)
            Assert-True ($empty.Contains('[SKIP]') -and $empty.Contains($rs[$c][4]) -and $empty.Contains('[FAILS]0')) (':{0} with an answer of nothing present must skip: {1}' -f $rs[$c][0], $empty)
        }
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 169. Registry backups: a backup that holds no value line refuses the write, an unwritable folder fails
#      quietly and once, and removing an absent value says so (run).
Invoke-Test 'A registry backup must hold the value before the write, and removing an absent value says so (run)' {
    $cmd = Read-Lines $CmdPath
    $q = 'reg query "!_key!" /v "!_val!"'
    $add = 'reg add "!_key!" /v "!_val!" /t !_type! /d "!_data!" /f >nul 2>&1'
    $del = 'reg delete "!_key!" /v "!_val!" /f >nul 2>&1'
    $parts = @()
    foreach ($lb in 'SafeRegAdd', 'SafeRegDelete', '_BakWrite', 'BackupValueLine', 'NonAsciiCheck') {
        $b = @(Get-BodyLines -Lines $cmd -Label $lb)
        Assert-True ($b.Count -gt 1) "test 169: :$lb is missing."
        if ($lb -eq 'BackupValueLine') { $b = @('if defined PT_NOVAL goto :eof') + $b }
        $parts += ':' + $lb
        $parts += @($b | ForEach-Object { if ($_.Contains('PT_BK_FILE') -and $_.Trim().StartsWith('start ""')) { 'if defined PT_MULTI echo [MULTI] >>"!_bkp!"' } else { $_.Replace($q, 'type "!PTQ!"').Replace($add, 'echo [REGADD] !_val!=!_data!').Replace($del, 'echo [REGDEL] !_val!') } })
    }
    Assert-True (@($parts | Where-Object { $_ -match '(?i)\breg\s+(add|delete|query)\b' -and $_.Trim() -notmatch '^(?i)(rem|echo)\b' }).Count -eq 0) 'test 169: a real reg command survived the stubbing - refusing to run.'
    $pp = @(Get-BodyLines -Lines $cmd -Label 'ProcPriority' -NoEcho | ForEach-Object { $_.Trim() })
    $ia = [Array]::IndexOf($pp, 'if defined _SRD_ABSENT ('); $is = -1
    for ($i = 0; $i -lt $pp.Count; $i++) { if ($pp[$i].StartsWith('call :Summary "Priority override for !_exe! removed')) { $is = $i } }
    Assert-True ($ia -ge 0 -and $is -gt $ia -and (Test-BlockExit -Lines (Get-BodyLines -Lines $cmd -Label 'ProcPriority') -Open '^if defined _SRD_ABSENT \($' -Exit '^goto MenuAdvanced$') -eq 1) 'Removing a priority override that does not exist still ends in "removed".'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt169_' + [guid]::NewGuid().ToString('N'))
    foreach ($d in 'b0', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'q') { [void](New-Item -ItemType Directory -Path (Join-Path $dir $d)) }
    try {
        $qf = Join-Path $dir 'q\present.txt'
        [IO.File]::WriteAllText($qf, "`r`nHKEY_CURRENT_USER\Software\X`r`n    Val    REG_DWORD    0x1`r`n`r`n")
        $gone = Join-Path $dir 'nope\deeper'
        $qm = Join-Path $dir 'q\multi.txt'; $qs = Join-Path $dir 'q\multi_same.txt'
        [IO.File]::WriteAllText($qm, "`r`nHKEY_CURRENT_USER\Software\X`r`n    Multi    REG_MULTI_SZ    x\0y`r`n`r`n")
        [IO.File]::WriteAllText($qs, "`r`nHKEY_CURRENT_USER\Software\X`r`n    Multi    REG_MULTI_SZ    a\0b`r`n`r`n")
        # routine call, backup folder, query answer, header-only, the multi-string worker wrote its line
        $cases = @(@('call :SafeRegAdd "HKCU\Software\X" "Val" REG_DWORD 0 "set Val"', (Join-Path $dir 'b0'), $qf, '', ''),
                   @('call :SafeRegAdd "HKCU\Software\X" "Val" REG_DWORD 0 "set Val"', $gone, $qf, '', ''),
                   @('call :SafeRegAdd "HKCU\Software\X" "Val" REG_DWORD 0 "set Val"', (Join-Path $dir 'b2'), $qf, '1', ''),
                   @('call :SafeRegDelete "HKCU\Software\X" "Val" "remove Val"', (Join-Path $dir 'b3'), (Join-Path $dir 'q\absent.txt'), '', ''),
                   @('call :SafeRegDelete "HKCU\Software\X" "Val" "remove Val"', (Join-Path $dir 'b4'), $qf, '', ''),
                   @('call :SafeRegAdd "HKCU\Software\X" "Multi" REG_MULTI_SZ "a\0b" "set Multi"', (Join-Path $dir 'b5'), $qm, '', '1'),
                   @('call :SafeRegAdd "HKCU\Software\X" "Multi" REG_MULTI_SZ "a\0b" "set Multi"', (Join-Path $dir 'b6'), $qm, '', ''),
                   @('call :SafeRegAdd "HKCU\Software\X" "Multi" REG_MULTI_SZ "a\0b" "set Multi"', (Join-Path $dir 'b7'), $qs, '', '1'))
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]
            $drv += @(('set "BACKUP_DIR=' + $x[1] + '"'), ('set "PTQ=' + $x[2] + '"'), ('set "PT_NOVAL=' + $x[3] + '"'), ('set "PT_MULTI=' + $x[4] + '"'), 'set "_FAILS=0"', "echo [CASE#$c]", $x[0], 'echo [FAILS]!_FAILS! [ABSENT]!_SRD_ABSENT!')
        }
        $drv += @('echo [END]', 'exit /b 0') + $parts + @(':Log', 'goto :eof', ':LogVar', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0) ('test 169: the driver failed: ' + $r.Err)
        Assert-True ($r.Err -eq '') ('An unwritable backup folder printed raw cmd errors instead of one [FAIL]: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        $baks = @(Get-ChildItem -LiteralPath (Join-Path $dir 'b0') -Filter '*.reg')
        Assert-True ($sec[0].Contains('[REGADD] Val=0') -and $sec[0].Contains('[FAILS]0') -and $baks.Count -eq 1 -and (Get-Content -LiteralPath $baks[0].FullName).Count -ge 4 -and (Get-Content -Raw -LiteralPath $baks[0].FullName).Contains('"Val"=dword:00000001')) ('A normal write must leave a 4-line backup holding the old value, then write: ' + $sec[0])
        Assert-True ($sec[1].Contains('[FAIL]') -and -not $sec[1].Contains('[REGADD]') -and $sec[1].Contains('[FAILS]1') -and @(([regex]::Matches($sec[1], '\[FAIL\]'))).Count -eq 1) ('An unwritable backup folder must fail once and not write: ' + $sec[1])
        Assert-True ($sec[2].Contains('[FAIL]') -and -not $sec[2].Contains('[REGADD]') -and $sec[2].Contains('[FAILS]1') -and @(Get-ChildItem -LiteralPath (Join-Path $dir 'b2') -Filter '*.reg').Count -eq 0) ('A backup holding only its header must refuse the write and be removed: ' + $sec[2])
        Assert-True ($sec[3].Contains('[SKIP]') -and $sec[3].Contains('nothing to remove') -and $sec[3].Contains('[ABSENT]1') -and -not $sec[3].Contains('[REGDEL]') -and @(Get-ChildItem -LiteralPath (Join-Path $dir 'b3') -Filter '*.reg').Count -eq 0) ('Removing an absent value must say so, set _SRD_ABSENT and leave no backup: ' + $sec[3])
        Assert-True ($sec[4].Contains('[REGDEL] Val') -and $sec[4] -match '\[ABSENT\]\s*$' -and $sec[4].Contains('[FAILS]0') -and @(Get-ChildItem -LiteralPath (Join-Path $dir 'b4') -Filter '*.reg').Count -eq 1) ('Removing a present value must back it up, delete it and leave _SRD_ABSENT clear: ' + $sec[4])
        $b5 = @(Get-ChildItem -LiteralPath (Join-Path $dir 'b5') -Filter '*.reg')
        Assert-True ($sec[5].Contains('[REGADD] Multi=a\0b') -and $sec[5].Contains('[FAILS]0') -and $b5.Count -eq 1 -and @(Get-Content -LiteralPath $b5[0].FullName).Count -ge 4 -and (Get-Content -Raw -LiteralPath $b5[0].FullName).Contains('[MULTI]')) ('A REG_MULTI_SZ must be backed up through its own worker line and then written: ' + $sec[5])
        Assert-True ($sec[6].Contains('[FAIL]') -and -not $sec[6].Contains('[REGADD]') -and $sec[6].Contains('[FAILS]1') -and @(Get-ChildItem -LiteralPath (Join-Path $dir 'b6') -Filter '*.reg').Count -eq 0) ('A REG_MULTI_SZ whose backup worker wrote nothing must refuse the write: ' + $sec[6])
        Assert-True ($sec[7].Contains('[SKIP]') -and -not $sec[7].Contains('[REGADD]') -and $sec[7].Contains('[FAILS]0') -and @(Get-ChildItem -LiteralPath (Join-Path $dir 'b7') -Filter '*.reg').Count -eq 0) ('A REG_MULTI_SZ already holding the strings must be skipped, not backed up and rewritten: ' + $sec[7])
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 170. hosts reset, the boot.config and preset-backup workers, and exit code 2 everywhere (part run).
Invoke-Test 'hosts reset, the boot.config and preset workers judge the real result, and exit code 2 reads the same everywhere (part run)' {
    $cmd = Read-Lines $CmdPath
    $exit2 = '(?i)2 bad usage,? or no writable backup folder|2 bad usage or no writable backup folder'
    Assert-True (@(Get-BodyLines -Lines $cmd -Label 'CliHelp' | Where-Object { $_ -match $exit2 }).Count -eq 1) 'The /? help no longer says exit code 2 also means no writable backup folder.'
    Assert-True ((Get-Content -Raw -LiteralPath $PresetPath) -match '(?s)2 bad usage or no writable backup folder') 'example.preset no longer says exit code 2 also means no writable backup folder.'
    $readme = Join-Path (Split-Path -Parent (Split-Path -Parent $CmdPath)) 'README_sincript.md'
    if (Test-Path -LiteralPath $readme) { Assert-True ((Get-Content -Raw -LiteralPath $readme) -match '(?i)no writable backup folder') 'The README no longer says exit code 2 also means no writable backup folder.' }

    $rh = Get-RoutineBody -Lines $cmd -Label 'ResetHostsDefault'; $rh = @($rh)
    $s = -1; for ($i = 0; $i -lt $rh.Count; $i++) { if ($rh[$i].Trim().StartsWith('set "_hdef=')) { $s = $i; break } }
    $e = -1; for ($i = $s + 1; $i -lt $rh.Count; $i++) { if ($rh[$i].Trim() -eq 'pause') { $e = $i; break } }
    Assert-True ($s -ge 0 -and $e -gt $s) 'test 170: the hosts reset write could not be sliced - it no longer writes a temp file first?'
    $slice = @($rh[$s..($e - 1)])
    Assert-True (@($slice | Where-Object { $_ -match '^\s*\) > "%_HOSTS%"' }).Count -eq 0 -and @($slice | Where-Object { $_.Trim() -ceq 'if not "!_hrc!"=="0" (' }).Count -eq 1) 'The hosts reset judges a redirect into hosts by errorlevel again - a blocked write would print [OK].'
    $wk = @(Get-BodyLines -Lines $cmd -Label 'PrepareBootConfig' | Where-Object { $_ -match '^\s*start "" /min /wait powershell' })
    $pe = @(Get-BodyLines -Lines $cmd -Label 'PresetEnd' | Where-Object { $_ -match '^\s*start "" /min /wait powershell' })
    Assert-True ($wk.Count -eq 1 -and $wk[0] -match "\`$ErrorActionPreference='Stop';try\{" -and $pe.Count -eq 1 -and $pe[0] -match "\`$ErrorActionPreference='Stop';try\{") 'The boot.config or preset-backup worker no longer stops on a read error, so an unreadable source becomes an empty result and exit 0.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt170_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $locks = @()
    try {
        # hosts: a writable file is replaced; a read-only one is left alone and reported
        $hw = Join-Path $dir 'hosts_w'; $hr = Join-Path $dir 'hosts_r'
        foreach ($f in $hw, $hr) { [IO.File]::WriteAllText($f, "old`r`n") }
        (Get-Item -LiteralPath $hr).IsReadOnly = $true
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "TEMP=' + $dir + '"'))
        $c = 0
        foreach ($f in $hw, $hr) { $drv += @(('set "_HOSTS=' + $f + '"'), "echo [CASE#$c]", 'call :HostsWrite'); $c++ }
        # boot.config: readable, held open, empty
        $src = Join-Path $dir 'boot.config'; [IO.File]::WriteAllText($src, "gfx-enable-gfx-jobs=1`r`njob-worker-count=2`r`n")
        $held = Join-Path $dir 'held.config'; [IO.File]::WriteAllText($held, "job-worker-count=2`r`n")
        $empty = Join-Path $dir 'empty.config'; [IO.File]::WriteAllText($empty, '')
        foreach ($f in $src, $held, $empty) {
            $drv += @(('set "PT_SRC=' + $f + '"'), ('set "PT_OUT=' + $f + '.out"'), 'set "PT_JW=7"', "echo [CASE#$c]", 'call :PrepareBootConfig', 'echo [RC]!errorlevel!'); $c++
        }
        # preset backup: a readable temp is converted and dropped; a held one is kept
        $j1 = Join-Path $dir 'p1.json'; [IO.File]::WriteAllText("$j1.tmp", "{""a"":1}`r`n{""b"":2}`r`n")
        $j2 = Join-Path $dir 'p2.json'; [IO.File]::WriteAllText("$j2.tmp", "{""a"":1}`r`n")
        foreach ($j in $j1, $j2) {
            $drv += @(('set "PRESET_JSON=' + $j + '"'), ('set "PRESET_JSON_TMP=' + $j + '.tmp"'), 'set "_FAILS=0"', "echo [CASE#$c]", 'call :PresetEnd', 'echo [LAST]!PRESET_LAST! [FAILS]!_FAILS!'); $c++
        }
        $drv += @('echo [END]', 'exit /b 0', ':HostsWrite') + $slice + @('goto :eof', ':PrepareBootConfig') + @(Get-BodyLines -Lines $cmd -Label 'PrepareBootConfig') +
                @(':PresetEnd') + @(Get-BodyLines -Lines $cmd -Label 'PresetEnd') + @(':Run', 'echo [RUN] %~1', 'goto :eof', ':Log', 'goto :eof', ':LogVar', 'goto :eof')
        $allow = '^(' + [regex]::Escape($wk[0].Trim()) + '|' + [regex]::Escape($pe[0].Trim()) + '|call :Run "ipconfig /flushdns")$'
        $locks += [IO.File]::Open($held, 'Open', 'Read', 'None')
        $locks += [IO.File]::Open("$j2.tmp", 'Open', 'Read', 'None')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir -Allow $allow -Seconds 90
        Assert-True ($r.Exit -eq 0) ('test 170: the driver failed: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $c
        Assert-True ($sec[0].Contains('[OK] hosts reset') -and (Get-Content -Raw -LiteralPath $hw).Contains('# Copyright')) ('A writable hosts must be reset and reported: ' + $sec[0])
        Assert-True ($sec[1].Contains('[WARN] Reset failed') -and -not $sec[1].Contains('[OK]') -and (Get-Content -Raw -LiteralPath $hr) -ceq "old`r`n") ('A blocked hosts write must be reported as failed, with hosts unchanged: ' + $sec[1])
        Assert-True (@(Get-ChildItem -LiteralPath $dir -Filter 'pt_hosts_*').Count -eq 0) 'The hosts reset left its temp file behind.'
        Assert-True ($sec[2].Contains('[RC]0') -and (Get-Content -Raw -LiteralPath "$src.out").Contains('job-worker-count=7')) ('A readable boot.config must be prepared: ' + $sec[2])
        Assert-True ($sec[3].Contains('[RC]1')) ('An unreadable boot.config source must fail, not install an empty file: ' + $sec[3])
        Assert-True ($sec[4].Contains('[RC]1')) ('An empty prepared boot.config must fail: ' + $sec[4])
        Assert-True ($sec[5] -match '\[LAST\].+p1\.json' -and -not (Test-Path -LiteralPath "$j1.tmp") -and (Get-Content -Raw -LiteralPath $j1) -match '^\[\{"a":1\},\{"b":2\}\]') ('A readable preset temp must become the JSON backup: ' + $sec[5])
        Assert-True ($sec[6].Contains('[WARN]') -and $sec[6] -match '\[LAST\]\s+\[FAILS\]1' -and (Test-Path -LiteralPath "$j2.tmp")) ('An unreadable preset temp must be kept and reported, not replaced by an empty backup: ' + $sec[6])
    }
    finally {
        foreach ($l in $locks) { $l.Dispose() }
        if (Test-Path -LiteralPath (Join-Path $dir 'hosts_r')) { (Get-Item -LiteralPath (Join-Path $dir 'hosts_r')).IsReadOnly = $false }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 171. A backup path holding a variable reference (a%OS%b) reaches the for /f and cmd /c children
#      unexpanded: listings, the per-value line count and the undo runs (part run).
Invoke-Test 'Backup paths reach for /f and cmd /c children unexpanded, so a folder named like a%OS%b still works (part run)' {
    $cmd = Read-Lines $CmdPath
    $code = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' })
    $byVal = @($code | Where-Object { $_ -match "(?i)\bin \('[^']*!(BACKUP_DIR|_bkp|_pfile|_tfile)!" })
    Assert-True ($byVal.Count -eq 0) ('A for /f child is handed a backup path by value, so it would expand a variable reference in it again: ' + ($byVal -join ' | '))
    $lists = @($code | Where-Object { $_ -match "(?i)\bin \('dir [^']*%%BACKUP_DIR%%" })
    Assert-True ($lists.Count -eq 6) ('Expected six backup-folder listings that let the child read BACKUP_DIR, found {0}.' -f $lists.Count)
    $piped = @($code | Where-Object { $_ -match "(?i)\bin \('dir [^']*\^\|" })
    Assert-True ($piped.Count -eq 0) ('A dir listing still pipes, so a child parses the path once more: ' + ($piped -join ' | '))
    $counts = @($code | Where-Object { $_.Contains('find /c /v "" ^< "%%_bkp%%"') })
    Assert-True ($counts.Count -eq 2) ('The per-value backup line count must let the child read _bkp, in :SafeRegAdd and :SafeRegDelete; found {0}.' -f $counts.Count)
    $runs = @($code | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(?i)cmd /d /v:off /s /c ' })
    Assert-True ($runs.Count -eq 2 -and $runs -ccontains 'cmd /d /v:off /s /c ""%%_pfile%%" /q"' -and $runs -ccontains 'cmd /d /v:off /s /c ""%%_tfile%%" /q"') ('The undo runs must let the child read the file path: ' + ($runs -join ' | '))

    $body = @(Get-BodyLines -Lines $cmd -Label 'RestoreRegBackup')
    Assert-True ($body.Count -gt 15) ':RestoreRegBackup is missing or did not unroll.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt171_' + [guid]::NewGuid().ToString('N'))
    $bd = Join-Path $dir 'pct_a%OS%b'
    [void](New-Item -ItemType Directory -Path $bd)
    try {
        foreach ($f in 'FullReg_1.reg', 'v1.reg', 'v2.reg') { [IO.File]::WriteAllText((Join-Path $bd $f), 'x') }
        $undo = Join-Path $bd 'PowerPlan_1.bat'
        [IO.File]::WriteAllLines($undo, [string[]]@('@echo off', 'echo [UNDO RAN %1]', 'exit /b 0'), [Text.Encoding]::ASCII)
        # The path reaches the driver through the environment: written into the driver's own text,
        # its %OS% would be expanded by the driver before the code under test saw it.
        $env:PT171_BD = $bd; $env:PT171_UNDO = $undo
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', 'set "BACKUP_DIR=!PT171_BD!"', 'set "_pfile=!PT171_UNDO!"',
                 'echo [CASE#0]', 'call :RestoreRegBackup', 'echo [CASE#1]', 'cmd /d /v:off /s /c ""%%_pfile%%" /q"', 'echo [RC]!errorlevel!',
                 'echo [END]', 'exit /b 0', ':RestoreRegBackup')
        foreach ($s in $body) {
            $t = $s.Trim()
            if ($t -ieq 'cls' -or $t -ieq 'pause' -or $t -ieq 'call :Logo') { $drv += 'rem ' + $t; continue }
            $drv += $s
        }
        $drv += @('goto :eof', ':MenuBackups', 'echo [MENU]', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 171: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count 2
        Assert-True ($sec[0].Contains('v1.reg') -and $sec[0].Contains('v2.reg') -and -not $sec[0].Contains('FullReg_1') -and -not $sec[0].Contains('No per-value')) ('The value-backup list in a folder named pct_a%OS%b must show v1.reg and v2.reg and leave out FullReg_1.reg: ' + $sec[0])
        Assert-True ($sec[1].Contains('[UNDO RAN /q]') -and $sec[1].Contains('[RC]0')) ('The undo run must find a file in a folder named pct_a%OS%b: ' + $sec[1])
    }
    finally {
        Remove-Item Env:PT171_BD, Env:PT171_UNDO -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 172. LockFinder closes a PID only while it still holds the file: Windows reuses PIDs (run).
Invoke-Test 'LockFinder lists the holders again and closes a PID only while it still holds the file (run)' {
    $cmd = Read-Lines $CmdPath
    $ask = @(Get-BodyLines -Lines $cmd -Label 'LockFinder_ask')
    Assert-True ($ask.Count -gt 20) ':LockFinder_ask is missing or did not unroll.'
    $code = @($ask | ForEach-Object { $_.Trim() } | Where-Object { $_ -notmatch '^(?i)(rem|echo)\b' })
    $iList = [Array]::IndexOf($code, 'call :LockWorker list')
    $iKill = -1; for ($i = 0; $i -lt $code.Count; $i++) { if ($code[$i] -like 'call :Run "taskkill /PID *') { $iKill = $i; break } }
    Assert-True ($iList -ge 0 -and $iKill -gt $iList) 'The holders are not listed again before the close.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt172_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $listA = Join-Path $dir 'still.txt'; $listB = Join-Path $dir 'gone.txt'
        [IO.File]::WriteAllLines($listA, [string[]]@('1|4242|normal|Editor|'), [Text.Encoding]::ASCII)
        [IO.File]::WriteAllLines($listB, [string[]]@('1|5151|normal|Other|'), [Text.Encoding]::ASCII)
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "_lflist=' + (Join-Path $dir 'list.txt') + '"'), 'set "_lfpath=C:\x.txt"',
                 'set "_lfn=1"', 'set "_lfpid[1]=4242"', 'set "_lfcrit[1]=normal"', 'set "_lfnm[1]=Editor"')
        $cases = @(@($listA, 'still holds'), @($listB, 'gone'))
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $drv += @(('set "PT_LIST=' + $cases[$c][0] + '"'), 'set "PT_K=1"', 'set "PT_Y=Y"', "echo [CASE#$c]", 'call :LockFinder_ask')
        }
        $drv += @('echo [END]', 'exit /b 0', ':LockFinder_ask')
        $nq = 0
        foreach ($s in $ask) {
            $t = $s.Trim()
            if ($t -ieq 'pause' -or $t -ieq 'cls') { $drv += 'rem ' + $t; continue }
            if ($t -ceq 'set /p "_lfk=Number to close (0 = back): "') { $drv += 'set "_lfk=!PT_K!" & set "PT_K=0"'; $nq++; continue }
            if ($t -ceq 'set /p "_lc=Proceed? (Y/N): "') { $drv += 'set "_lc=!PT_Y!"'; $nq++; continue }
            $drv += $s
        }
        Assert-True ($nq -eq 2) 'test 172: the two questions were not both found to answer.'
        $drv += @(':LockWorker', 'copy /y "!PT_LIST!" "!_lflist!" >nul', 'goto :eof',
                  ':Run', 'echo [RUN] %~1', 'goto :eof', ':Utf8On', 'goto :eof', ':Utf8Off', 'goto :eof',
                  ':NoInput', 'exit /b 1', ':ExitScript', 'goto :eof', ':MenuTools', 'echo [TOOLS]', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir -Allow '^(?i)call :Run "taskkill /PID [^"]*"$'
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 172: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count 2
        Assert-True ($sec[0].Contains('[RUN] taskkill /PID 4242 /F')) ('A PID that still holds the file must be closed: ' + $sec[0])
        Assert-True (-not $sec[1].Contains('[RUN]') -and $sec[1].Contains('no longer holds the file')) ('A PID that no longer holds the file must not be closed: ' + $sec[1])
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}


# 173. The Documents path is read with the console on UTF-8, and a damaged read keeps the default (run).
Invoke-Test 'The Documents path keeps letters outside the console code page, and a "?" in it falls back to the default (run)' {
    $cmd = Read-Lines $CmdPath
    $s = [Array]::IndexOf($cmd, 'setlocal DisableDelayedExpansion')
    $e = -1; for ($i = $s + 1; $i -lt $cmd.Count; $i++) { if ($cmd[$i].StartsWith('set "BACKUP_DIR=')) { $e = $i; break } }
    Assert-True ($s -ge 0 -and $e -gt $s) 'test 173: the Documents read at the top could not be sliced.'
    $rq = "('reg query ""HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"" /v Personal 2^>nul ^| findstr /I ""Personal""')"
    $slice = @($cmd[$s..$e])
    Assert-True (@($slice | Where-Object { $_.Contains($rq) }).Count -eq 1) 'test 173: the Documents read no longer has the shape this test replaces.'
    # The stand-in prints the value the way reg does: a child cmd writing to a pipe in the console code page.
    $slice = @($slice | ForEach-Object { $_.Replace($rq, "('cmd /d /c echo     Personal    REG_SZ    %%PT173_DOC%%')") })
    $cyr = [string]::new([char[]](0x0422, 0x0435, 0x0441, 0x0442))
    $cases = @(('C:\Users\' + $cyr + '\Documents'), 'C:\Users\a?b\Documents', 'C:\Users\Plain\Documents')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt173_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'chcp 437 >nul')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $drv += @(('set "PT173_DOC=%PT173_D' + $c + '%"'), "echo [CASE#$c]", 'call :Docs')
        }
        $drv += @('echo [END]', 'exit /b 0', ':Docs') + $slice + @('setlocal EnableDelayedExpansion', 'for /f "tokens=2 delims=:" %%p in (''chcp'') do echo [CP]%%p',
                  'if "!DOCS!"=="!PT173_DOC!" echo [SAME]', 'if "!DOCS!"=="!USERPROFILE!\Documents" echo [DEFAULT]', 'goto :eof')
        for ($c = 0; $c -lt $cases.Count; $c++) { Set-Item -Path ("Env:PT173_D$c") -Value $cases[$c] }
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 173: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        Assert-True ($sec[0].Contains('[SAME]') -and $sec[0].Contains('[CP] 437')) ('A Documents path in another alphabet must arrive intact, with the code page put back: ' + $sec[0])
        Assert-True ($sec[1].Contains('[DEFAULT]') -and -not $sec[1].Contains('[SAME]')) ('A Documents path holding "?" must fall back to USERPROFILE\Documents: ' + $sec[1])
        Assert-True ($sec[2].Contains('[SAME]') -and $sec[2].Contains('[CP] 437')) ('A plain Documents path must be taken as read: ' + $sec[2])
    }
    finally {
        for ($c = 0; $c -lt 3; $c++) { Remove-Item -Path ("Env:PT173_D$c") -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # SteamLight reads the same way: all three registry reads inside one UTF-8 window
    $sl = @(Get-BodyLines -Lines $cmd -Label 'SteamLight' -CodeOnly | ForEach-Object { $_.Trim() })
    $on = [Array]::IndexOf($sl, 'call :Utf8On'); $off = [Array]::IndexOf($sl, 'call :Utf8Off')
    $reads = @(for ($i = 0; $i -lt $sl.Count; $i++) { if ($sl[$i] -match 'reg query "HK[^"]*\\Valve\\Steam"') { $i } })
    Assert-True ($reads.Count -eq 3 -and $on -ge 0 -and $on -lt $reads[0] -and $off -gt $reads[2]) 'SteamLight reads the Steam folder outside UTF-8 again - a folder name in another alphabet becomes "?" and "no steam.exe there".'
}

# 174. A quote or a "!" inside a command-line argument is data (run).
Invoke-Test 'A quote inside a command-line argument is no exit 255, and a "!" is not lost before the checks (run)' {
    $cmd = Read-Lines $CmdPath
    $s = [Array]::IndexOf($cmd, ':_argLoop'); $e = [Array]::IndexOf($cmd, ':_argDone')
    Assert-True ($s -ge 0 -and $e -gt $s) 'test 174: the argument loop is missing.'
    # the loop runs before the script turns delayed expansion on: with it on, set "_a=%~1" eats a "!"
    Assert-True ($s -lt [Array]::IndexOf($cmd, 'setlocal EnableDelayedExpansion') -and $cmd[$e + 1] -ceq 'setlocal EnableDelayedExpansion') 'The argument loop runs with delayed expansion on again - /preset:Hi!There would reach the checks as HiThere.'
    Assert-True (@($cmd[$s..$e] | Where-Object { $_ -notmatch '^\s*rem\b' -and $_.Contains('!_a') }).Count -eq 0) 'The argument loop reads its copy with !_a! again - delayed expansion is off there, so that reads nothing.'
    $cases = @('/preset:"my preset"', '/preset:"light" /norestore', '/dns:"google"', '"/preset:a b"', '/preset:light /dns:quad9', '/preset:Hi!There', '/preset:li!FOO!ght', '/dns:go!x!ogle /norestore')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt174_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', 'set "FOO=X"')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $drv += @('setlocal DisableDelayedExpansion', 'set "_CLIPRESET=" & set "_CLIDNS=" & set "_CLINORP=" & set "_CLIBAD=" & set "_CLIANY="', "echo [CASE#$c]", ('call :Args ' + $cases[$c]),
                      'setlocal EnableDelayedExpansion', 'echo [P=!_CLIPRESET!] [D=!_CLIDNS!] [N=!_CLINORP!] [B=!_CLIBAD!]', 'endlocal & endlocal')
        }
        $drv += @('echo [END]', 'exit /b 0', ':Args') + @($cmd[$s..($e - 1)]) + @(':_argDone', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('A quoted value must not end the argument loop (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        $want = @('[P=my preset] [D=] [N=] [B=]', '[P=light] [D=] [N=1] [B=]', '[P=] [D=google] [N=] [B=]', '[P=a b] [D=] [N=] [B=]', '[P=light] [D=quad9] [N=] [B=]',
                  '[P=Hi!There] [D=] [N=] [B=]', '[P=li!FOO!ght] [D=] [N=] [B=]', '[P=] [D=go!x!ogle] [N=1] [B=]')
        for ($c = 0; $c -lt $cases.Count; $c++) { Assert-True ($sec[$c].Trim() -ceq $want[$c]) ('{0} must parse as {1}, got: {2}' -f $cases[$c], $want[$c], $sec[$c]) }
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 175. A typed .exe name or lock-finder path that cmd would alter, or that is not one file, is refused (run).
Invoke-Test 'Process priority refuses an .exe name cmd would alter, and the lock finder refuses a folder or a wildcard (run)' {
    $cmd = Read-Lines $CmdPath
    $pp = @(Get-BodyLines -Lines $cmd -Label 'ProcPriority')
    $t = @($pp | ForEach-Object { $_.Trim() })
    $s = [Array]::IndexOf($t, 'set "_exe="'); $e = [Array]::IndexOf($t, 'echo  Priority for !_exe!:')
    Assert-True ($s -ge 0 -and $e -gt $s) 'test 175: the .exe name handling could not be sliced.'
    $ask = 'set /p "_exe=.exe name (e.g. game.exe), blank = cancel: "'
    Assert-True (@($t[$s..$e] | Where-Object { $_ -ceq $ask }).Count -eq 1) 'test 175: the .exe question is not the one this test answers.'
    $names = @('Wow!.exe', 'a^b.exe', '*.cmd', 'zz?.exe', 'a%OS%b.exe', 'C:\Games\game.exe', 'a&b', 'Tom.exe')
    $want = @('', '', '', '', '', 'game.exe', 'a&b.exe', 'Tom.exe')
    $lf = @(Get-BodyLines -Lines $cmd -Label 'LockFinder')
    $lt = @($lf | ForEach-Object { $_.Trim() })
    $ls = [Array]::IndexOf($lt, 'set "_lfbad=" & set "_lfat="'); $le = -1
    for ($i = $ls + 1; $i -lt $lt.Count; $i++) { if ($lt[$i] -eq 'goto LockFinder') { $le = $i + 1; break } }
    Assert-True ($ls -ge 0 -and $le -gt $ls -and $lt[$le] -eq ')') 'test 175: the lock finder path check could not be sliced.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt175_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        [IO.File]::WriteAllText((Join-Path $dir 'held.txt'), 'x')
        $paths = @($dir, (Join-Path $dir 'h*.txt'), (Join-Path $dir 'hel?.txt'), (Join-Path $dir 'held.txt'))
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $names.Count; $c++) { Set-Item -Path ("Env:PT175_N$c") -Value $names[$c]; $drv += @(('set "PT_EXE=!PT175_N' + $c + '!"'), "echo [CASE#$c]", 'call :Pp') }
        for ($c = 0; $c -lt $paths.Count; $c++) { Set-Item -Path ("Env:PT175_P$c") -Value $paths[$c]; $drv += @(('set "_lfpath=!PT175_P' + $c + '!"'), ("echo [CASE#{0}]" -f ($names.Count + $c)), 'call :Lf') }
        $drv += @('echo [END]', 'exit /b 0', ':Pp')
        foreach ($l in $pp[$s..$e]) { if ($l.Trim() -ceq $ask) { $drv += 'set "_exe=!PT_EXE!"' } else { $drv += $l.Replace(' & pause & ', ' & ') } }
        $drv += @('echo [NAME=!_exe!]', 'goto :eof', ':MenuAdvanced', 'echo [REFUSED]', 'goto :eof', ':Lf')
        foreach ($l in $lf[$ls..$le]) { if ($l.Trim() -eq 'pause') { $drv += 'rem pause' } else { $drv += $l } }
        $drv += @('echo [ACCEPTED]', 'goto :eof', ':LockFinder', 'echo [REFUSED]', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 175: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count ($names.Count + $paths.Count)
        for ($c = 0; $c -lt $names.Count; $c++) {
            if ($want[$c]) { Assert-True ($sec[$c].Contains("[NAME=$($want[$c])]") -and -not $sec[$c].Contains('[REFUSED]')) ('"{0}" must be taken as {1}: {2}' -f $names[$c], $want[$c], $sec[$c]) }
            else { Assert-True ($sec[$c].Contains('[REFUSED]') -and -not $sec[$c].Contains('[NAME=')) ('"{0}" would reach the registry altered and must be refused: {1}' -f $names[$c], $sec[$c]) }
        }
        for ($c = 0; $c -lt $paths.Count; $c++) {
            $x = $sec[$names.Count + $c]
            if ($c -lt 3) { Assert-True ($x.Contains('[REFUSED]') -and $x.Contains('folder or a wildcard') -and -not $x.Contains('[ACCEPTED]')) ('The lock finder must refuse {0}: {1}' -f $paths[$c], $x) }
            else { Assert-True ($x.Contains('[ACCEPTED]') -and -not $x.Contains('[REFUSED]')) ('The lock finder must take one existing file: ' + $x) }
        }
    }
    finally {
        for ($c = 0; $c -lt 8; $c++) { Remove-Item -Path ("Env:PT175_N$c"), ("Env:PT175_P$c") -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 176. A custom preset asks before it applies, a preset that cannot start holds its error, declining every power
#      question is no "[OK] applied", and the sign-out note needs a changed key (part run).
Invoke-Test 'Custom presets ask first, a failed preset start stays readable, and "nothing chosen" is not reported as applied (part run)' {
    $cmd = Read-Lines $CmdPath
    $pc = @(Get-BodyLines -Lines $cmd -Label 'PresetCustom_ask')
    $t = @($pc | ForEach-Object { $_.Trim() })
    $s = [Array]::IndexOf($t, ':_pcHaveValid'); $e = [Array]::IndexOf($t, 'call :PresetBegin "custom_!_pbase!"')
    Assert-True ($s -ge 0 -and $e -gt $s) 'test 176: the custom preset confirmation could not be sliced.'
    $qs = @('set /p "_cc=Apply the valid directives and skip the problems? (Y/N): "', 'set /p "_cc=Apply these %_pgood% directive(s)? (Y/N): "', 'set /p "_rp=Create a System Restore Point first? (Y/N): "')
    foreach ($q in $qs) { Assert-True (@($t[$s..$e] | Where-Object { $_ -ceq $q }).Count -eq 1) "test 176: the question '$q' is gone from the custom preset path." }
    $pb = @(Get-BodyLines -Lines $cmd -Label 'PresetBegin'); $pt = @(Get-BodyLines -Lines $cmd -Label '_pbTouch')
    $hold = 'if not defined _CLIANY pause'
    Assert-True (@($pb | Where-Object { $_.Trim() -ceq $hold }).Count -eq 1 -and $pt.Count -ge 2) 'test 176: :PresetBegin no longer holds its error for the menu, or no longer writes its temp one call down.'
    $ak = @(Get-BodyLines -Lines $cmd -Label '_akOne'); $ao = @(Get-BodyLines -Lines $cmd -Label 'AccessKeysOff')
    $rq = 'reg query "!_akk!" /v Flags'
    Assert-True (@($ak | Where-Object { $_.Contains($rq) }).Count -eq 1) 'test 176: :_akOne no longer reads Flags the way this test fakes it.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt176_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        # the Y answers reach the real :PresetBegin, so its backup must land in this folder
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', 'set "_pbase=t"', 'set "_CLIANY="', ('set "BACKUP_DIR=' + $dir + '"'))
        # problems, answer
        $pcases = @(@(0, 'N'), @(0, 'Y'), @(0, ''), @(1, 'N'), @(1, 'Y'))
        $c = 0
        foreach ($x in $pcases) { $drv += @(('set "_perr=' + $x[0] + '"'), 'set "_pgood=2"', ('set "PT_CC=' + $x[1] + '"'), "echo [CASE#$c]", 'call :Pc'); $c++ }
        $drv += @('set "_CLIANY="', ('set "BACKUP_DIR=' + (Join-Path $dir 'nope\deeper') + '"'), "echo [CASE#$c]", 'call :PresetBegin light', 'echo [RC]!errorlevel!'); $c++
        $drv += @('set "_CLIANY=1"', "echo [CASE#$c]", 'call :PresetBegin light', 'echo [RC]!errorlevel!'); $c++
        $drv += @('set "_CLIANY="', ('set "BACKUP_DIR=' + $dir + '"'), "echo [CASE#$c]", 'call :PresetBegin light', 'echo [RC]!errorlevel! [MODE]!PRESET_MODE!'); $c++
        # sign-out note: all three already off, one switched, one whose write failed
        $flags = @(@('506', '122', '58', 0), @('510', '122', '58', 0), @('510', '122', '58', 1))
        foreach ($x in $flags) {
            $cd = Join-Path $dir "ak$c"; [void](New-Item -ItemType Directory -Path $cd)
            $nm = @('Sticky Keys', 'Filter Keys', 'Toggle Keys')
            for ($k = 0; $k -lt 3; $k++) { [IO.File]::WriteAllText((Join-Path $cd ($nm[$k] + '.txt')), ("`r`nHKEY_CURRENT_USER\Control Panel\Accessibility\x`r`n    Flags    REG_SZ    {0}`r`n`r`n" -f $x[$k])) }
            $drv += @(('set "PT176=' + $cd + '"'), ('set "PT_SRA=' + $x[3] + '"'), "echo [CASE#$c]", 'call :AccessKeysOff'); $c++
        }
        $drv += @('echo [END]', 'exit /b 0', ':Pc')
        foreach ($l in @($pc[$s..$e])) {
            $u = $l.Trim()
            if ($u -ceq $qs[0] -or $u -ceq $qs[1]) { $drv += 'set "_cc=!PT_CC!"' } elseif ($u -ceq $qs[2]) { $drv += 'set "_rp=N"' } else { $drv += $l }
        }
        $drv += @('echo [APPLY]', 'goto :eof', ':MenuPresets', 'echo [MENU]', 'goto :eof', ':CreateRestorePoint', 'echo [RP]', 'goto :eof', ':RpNote', 'goto :eof',
                  ':PresetBegin') + @($pb | ForEach-Object { if ($_.Trim() -ceq $hold) { $_.Replace('pause', 'echo [PAUSE]') } else { $_ } }) + @(':_pbTouch') + $pt
        $drv += @(':AccessKeysOff') + $ao + @(':_akOne') + @($ak | ForEach-Object { $_.Replace($rq, 'type "!PT176!\!_akn!.txt"') })
        $drv += @(':SafeRegAdd', 'echo [REGWRITE] %~2 %~4', 'exit /b !PT_SRA!', ':Log', 'goto :eof', ':LogVar', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0) ('test 176: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        Assert-True ($r.Err -eq '') ('A preset that cannot write its backup printed a raw cmd error: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $c
        for ($i = 0; $i -lt $pcases.Count; $i++) {
            $go = ($pcases[$i][1] -eq 'Y')
            Assert-True ($sec[$i].Contains('[MENU]') -ne $go -and $sec[$i].Contains('[APPLY]') -eq $go) ('Custom preset with {0} problem(s), answer "{1}": it must apply only on Y: {2}' -f $pcases[$i][0], $pcases[$i][1], $sec[$i])
        }
        $n = $pcases.Count
        Assert-True ($sec[$n].Contains('[ERROR] Could not create the preset JSON backup') -and $sec[$n].Contains('[PAUSE]') -and $sec[$n].Contains('[RC]1')) ('From the menu, a preset that cannot start must hold its error before the menu redraws: ' + $sec[$n])
        Assert-True ($sec[$n + 1].Contains('[ERROR]') -and -not $sec[$n + 1].Contains('[PAUSE]') -and $sec[$n + 1].Contains('[RC]1')) ('A command-line run must never wait on a failed preset start: ' + $sec[$n + 1])
        Assert-True ($sec[$n + 2].Contains('[RC]0 [MODE]1') -and -not $sec[$n + 2].Contains('[PAUSE]')) ('A writable backup folder must start the preset: ' + $sec[$n + 2])
        $note = 'The shortcut pop-ups stop after you sign out'
        Assert-True (-not $sec[$n + 3].Contains($note) -and -not $sec[$n + 3].Contains('[REGWRITE]')) ('With every shortcut already off, nothing changed, so no sign-out note: ' + $sec[$n + 3])
        Assert-True ($sec[$n + 4].Contains($note) -and $sec[$n + 4].Contains('[REGWRITE] Flags 506')) ('A switched shortcut must be followed by the sign-out note: ' + $sec[$n + 4])
        Assert-True (-not $sec[$n + 5].Contains($note) -and $sec[$n + 5].Contains('[REGWRITE]')) ('A write that failed changed nothing, so no sign-out note: ' + $sec[$n + 5])
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    # Power: declining every question goes to its own [SKIP], never to :Summary's "[OK] ... applied"
    $pw = @(Get-BodyLines -Lines $cmd -Label 'Power' -CodeOnly | ForEach-Object { $_.Trim() })
    $ig = -1; for ($i = 0; $i -lt $pw.Count; $i++) { if ($pw[$i].StartsWith('if not defined _PWPLAN if /i not "!_tmo!"=="Y"') -and $pw[$i].EndsWith('goto _pwNone')) { $ig = $i } }
    $is = [Array]::IndexOf($pw, 'call :Summary "Power settings applied."'); $in = [Array]::IndexOf($pw, ':_pwNone')
    Assert-True ($ig -ge 0 -and $is -gt $ig -and $in -gt $is) 'Power no longer checks that something was chosen before it reports "[OK] Power settings applied."'
    foreach ($v in '_tmo', '_hb', '_mp', '_pwt', '_usb') { Assert-True ($pw[$ig].Contains('if /i not "!' + $v + '!"=="Y"')) "The nothing-chosen check on Power misses the $v answer." }
    $none = @(); for ($i = $in + 1; $i -lt $pw.Count -and $pw[$i] -ne 'goto MainMenu'; $i++) { $none += $pw[$i] }
    Assert-True (@($none | Where-Object { $_ -match '\[SKIP\] Nothing was chosen' }).Count -eq 1 -and @($none | Where-Object { $_ -match '(?i)call :Summary' }).Count -eq 0) 'Power with nothing chosen must say so with [SKIP], not through :Summary.'
}

# 177. "Found N but changed none" always counts, the advice fits the window, a firewall that did not answer and an
#      OneDrive worker that said nothing are failures (run).
Invoke-Test 'Privacy "found but changed none" always counts with fitting advice; a silent firewall or OneDrive worker is a failure (run)' {
    $cmd = Read-Lines $CmdPath
    $routs = @(@('DisableTelemetryTasks', '_tkres'), @('DisableNvidiaTelemetryTasks', '_nvres'), @('DiagTrackFirewall', '_fwres'))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt177_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $bodies = @()
        foreach ($x in $routs) {
            $b = @(Get-BodyLines -Lines $cmd -Label $x[0])
            Assert-True (@($b | Where-Object { $_ -match '^\s*start "" /min /wait powershell' }).Count -eq 1) ("test 177: :{0} no longer has one worker line." -f $x[0])
            $bodies += ':' + $x[0]
            $bodies += @($b | ForEach-Object { if ($_ -match '^\s*start "" /min /wait powershell') { 'if defined PT_ANS copy /y "!PT_ANS!" "!' + $x[1] + '!" >nul' } else { $_ } })
        }
        $od = @(Get-BodyLines -Lines $cmd -Label 'DebloatOneDrive')
        $os = -1; for ($i = 0; $i -lt $od.Count; $i++) { if ($od[$i].Trim().StartsWith('set "_odres=')) { $os = $i; break } }
        Assert-True ($os -ge 0 -and @($od | Where-Object { $_ -match '^\s*start "" /min /wait powershell' }).Count -eq 1) 'test 177: the OneDrive worker could not be sliced.'
        $bodies += ':OneDrive'
        $bodies += @($od[$os..($od.Count - 1)] | ForEach-Object { if ($_ -match '^\s*start "" /min /wait powershell') { 'if defined PT_ANS copy /y "!PT_ANS!" "!_odres!" >nul' } else { $_ } })
        $bodies += @('goto :eof', ':DebloatDone', 'goto :eof')
        # routine, answer, elevated, what the screen must say
        $cases = @(@(0, '3 0 10 0', '1', 'Windows or a policy protects them'), @(0, '3 0 10 0', '0', 'run as Administrator'),
                   @(1, '2 0 1', '1', 'Windows or a policy protects them'), @(2, '0 2', '1', 'Windows or a policy protects them'),
                   @(2, 'E 0', '1', 'Windows Firewall did not answer'), @(3, '', '1', 'PowerShell returned no answer'),
                   @(3, '1 0', '1', '[OK] OneDrive uninstalled'))
        $calls = @('call :DisableTelemetryTasks', 'call :DisableNvidiaTelemetryTasks', 'call :DiagTrackFirewall', 'call :OneDrive')
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "BACKUP_DIR=' + $dir + '"'))
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $af = ''
            if ($x[1]) { $af = Join-Path $dir "ans$c.txt"; [IO.File]::WriteAllText($af, ($x[1] + "`r`n")) }
            $drv += @(('set "PT_ANS=' + $af + '"'), ('set "_ELEV=' + $x[2] + '"'), 'set "_FAILS=0" & set "_RUNTRACK="', "echo [CASE#$c]", $calls[$x[0]], 'echo [FAILS]!_FAILS!')
        }
        $drv += @('echo [END]', 'exit /b 0') + $bodies + @(':Log', 'goto :eof', ':LogVar', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 177: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        # the last case answers: OneDrive's no-answer check must not fire then
        $n = $cases.Count - 1
        Assert-True ($sec[$n].Contains($cases[$n][3]) -and $sec[$n].Contains('[FAILS]0') -and -not $sec[$n].Contains('[FAIL]')) ('OneDrive with an answer must report it, not "no answer": ' + $sec[$n])
        for ($c = 0; $c -lt $n; $c++) {
            $x = $cases[$c]
            Assert-True ($sec[$c].Contains('[FAIL]') -and $sec[$c].Contains($x[3]) -and $sec[$c].Contains('[FAILS]1') -and -not $sec[$c].Contains('[SKIP]') -and -not $sec[$c].Contains('[OK]')) ('{0} answering "{1}" (elevated={2}) must be a counted [FAIL] saying "{3}": {4}' -f $calls[$x[0]], $x[1], $x[2], $x[3], $sec[$c])
        }
        Assert-True (-not $sec[0].Contains('run as Administrator') -and -not $sec[5].Contains('was not found')) 'An elevated window is told to run as Administrator, or OneDrive with no answer still claims the uninstaller was not found.'
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    $fw = @(Get-BodyLines -Lines $cmd -Label 'DiagTrackFirewall' | Where-Object { $_ -match '^\s*start "" /min /wait powershell' })
    Assert-True ($fw[0].Contains("-ErrorAction Stop) }catch{ if(`$_.CategoryInfo.Category -ne 'ObjectNotFound')") -and $fw[0].Contains("'E 0'")) 'The firewall worker swallows a failed query again, so a stopped firewall reads as "no DiagTrack rule group".'
}

# 178. The PATH editor compares folders with and without a trailing backslash as one, and remove-by-number refuses
#      a PATH that changed since it was listed (run, registry faked).
Invoke-Test 'PATH editor: a trailing backslash is the same folder, a drive root stays a root, and a changed PATH is not edited by number (run)' {
    $cmd = Read-Lines $CmdPath
    $w = @(Get-BodyLines -Lines $cmd -Label 'PathWorker' | Where-Object { $_ -match '^\s*start "" /min /wait powershell' })
    Assert-True ($w.Count -eq 1) 'test 178: :PathWorker no longer has one worker line.'
    $ps = $w[0].Trim(); $i = $ps.IndexOf('-Command "'); $ps = $ps.Substring($i + 10); $ps = $ps.Substring(0, $ps.Length - 1)
    $read = '$k=$root.OpenSubKey($sub,$false); $raw=''''; if($k){ $raw=[string]$k.GetValue(''Path'',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $k.Close() };'
    Assert-True ($ps.Contains($read)) 'test 178: the PATH read is not the shape this test fakes.'
    Assert-True ($ps -match '\[Security\.Cryptography\.SHA256\]::Create\(\)' -and $ps -notmatch '(?i)MD5') 'The PATH fingerprint is no longer SHA-256 (MD5 can be refused by policy).'
    $ps = $ps.Replace($read, '$raw=$env:PT_FAKE_RAW;')
    $a = $ps.IndexOf('$new=($parts -join '';'');'); $b = $ps.IndexOf('($note+[Environment]::NewLine')
    Assert-True ($a -ge 0 -and $b -gt $a) 'test 178: the PATH write is not the shape this test fakes.'
    $ps = $ps.Substring(0, $a) + '$new=($parts -join '';''); [IO.File]::WriteAllText($env:PT_FAKE_OUT,$new); ' + $ps.Substring($b)
    Assert-True ($ps -notmatch 'OpenSubKey\(\$sub,\$true\)|SetValue\(|SendMessageTimeout') 'test 178: a real registry write survived the faking - refusing to run.'
    $sh = @(Get-BodyLines -Lines $cmd -Label 'PathEditor_show' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True (@($sh | Where-Object { $_ -ceq 'if exist "!_pesigf!" for /f "usebackq delims=" %%S in ("!_pesigf!") do set "_pesigv=%%S"' }).Count -eq 1) 'The PATH list no longer keeps the fingerprint of what it showed.'
    Assert-True (@(Get-BodyLines -Lines $cmd -Label 'PathWorker' -CodeOnly | Where-Object { $_.Trim() -ceq 'set "PT_PE_SIGIN=!_pesigv!"' }).Count -eq 1) 'The PATH edits no longer hand the shown fingerprint to the worker.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt178_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $names = 'PT_PE_SCOPE', 'PT_PE_MODE', 'PT_PE_ARG', 'PT_PE_LIST', 'PT_PE_RES', 'PT_PE_SIG', 'PT_PE_SIGIN', 'PT_FAKE_RAW', 'PT_FAKE_OUT'
    try {
        $f = Join-Path $dir 'pe.ps1'; [IO.File]::WriteAllText($f, $ps, [Text.Encoding]::ASCII)
        $run = {
            param($mode, $raw, $arg, $sigin)
            $o = Join-Path $dir 'out.txt'; $rs = Join-Path $dir 'res.txt'; $sg = Join-Path $dir 'sig.txt'; $ls = Join-Path $dir 'list.txt'
            foreach ($p in $o, $rs, $sg, $ls) { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
            $env:PT_PE_SCOPE = 'user'; $env:PT_PE_MODE = $mode; $env:PT_PE_ARG = $arg; $env:PT_PE_LIST = $ls; $env:PT_PE_RES = $rs
            $env:PT_PE_SIG = $sg; $env:PT_PE_SIGIN = $sigin; $env:PT_FAKE_RAW = $raw; $env:PT_FAKE_OUT = $o
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $f + '"')) -Wait -PassThru -WindowStyle Hidden
            [pscustomobject]@{ Rc = $p.ExitCode
                Out = $(if (Test-Path -LiteralPath $o) { [IO.File]::ReadAllText($o) } else { $null })
                Res = $(if (Test-Path -LiteralPath $rs) { [IO.File]::ReadAllText($rs) } else { '' })
                Sig = $(if (Test-Path -LiteralPath $sg) { ([IO.File]::ReadAllText($sg)).Trim() } else { '' }) }
        }
        $base = 'C:\Windows;C:\Program Files\dotnet\'
        $x = & $run 'list' $base '' ''
        Assert-True ($x.Rc -eq 0 -and $x.Sig -match '^[0-9A-F]{64}$') ('Listing PATH must write its SHA-256 fingerprint: rc={0} sig={1}' -f $x.Rc, $x.Sig)
        $sig = $x.Sig
        foreach ($typed in 'C:\Program Files\dotnet', 'C:\Program Files\dotnet\', 'c:\program files\DOTNET\\') {
            $x = & $run 'add' $base $typed ''
            Assert-True ($x.Rc -eq 0 -and $null -eq $x.Out -and $x.Res.Contains('already in PATH')) ('"{0}" is already in PATH as "C:\Program Files\dotnet\" and must not be added again: {1}' -f $typed, $x.Res)
        }
        $x = & $run 'add' 'C:\Windows' 'D:\' ''
        Assert-True ($x.Out -ceq 'C:\Windows;D:\') ('A typed drive root must stay a root, not become the drive-relative "D:": ' + $x.Out)
        $x = & $run 'dedupe' 'C:\a\;C:\a;c:\A\;C:\b' '' ''
        Assert-True ($x.Out -ceq 'C:\a\;C:\b' -and $x.Res.Contains('Removed 2 duplicate')) ('Entries that differ only by a trailing backslash or case are duplicates: ' + $x.Out + ' / ' + $x.Res)
        $x = & $run 'removeidx' $base '2' $sig
        Assert-True ($x.Rc -eq 0 -and $x.Out -ceq 'C:\Windows') ('Removing #2 of the PATH that was shown must remove it: ' + $x.Out)
        $x = & $run 'removeidx' 'C:\Windows;C:\New;C:\Program Files\dotnet\' '2' $sig
        Assert-True ($x.Rc -eq 3 -and $null -eq $x.Out -and $x.Res.Contains('changed since it was listed')) ('A PATH that changed after it was shown must not be edited by number: rc={0} {1}' -f $x.Rc, $x.Res)
        $x = & $run 'removeidx' $base '1' ''
        Assert-True ($x.Rc -eq 3 -and $null -eq $x.Out -and $x.Res.Contains('could not be checked')) ('With no fingerprint to compare, nothing may be removed: rc={0} {1}' -f $x.Rc, $x.Res)
    }
    finally {
        foreach ($n in $names) { Remove-Item -Path "Env:$n" -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 179. A preset JSON backup that cannot be read is an [ERROR], not "[OK] 0 restored", and a name in another
#      alphabet is listed intact (run; the inputs never reach a registry write).
Invoke-Test 'Preset JSON restore: an unreadable, empty or partly restorable backup is reported as such, and names keep their letters (run)' {
    $cmd = Read-Lines $CmdPath
    $rl = @(Get-BodyLines -Lines $cmd -Label 'RestorePresetJson'); $rt = @($rl | ForEach-Object { $_.Trim() })
    $s = [Array]::IndexOf($rt, 'set "_rn=0"'); $e = -1
    for ($i = $s; $i -lt $rt.Count; $i++) { if ($rt[$i].StartsWith('for /l %%I in (1,1,%_rn%) do echo')) { $e = $i; break } }
    Assert-True ($s -ge 0 -and $e -gt $s) 'test 179: the backup listing could not be sliced.'
    $ra = @(Get-BodyLines -Lines $cmd -Label 'RestorePresetJson_ask'); $at = @($ra | ForEach-Object { $_.Trim() })
    $s2 = [Array]::IndexOf($at, 'set "PT_FILE=!_rfile!"'); $e2 = -1
    for ($i = $s2; $i -lt $at.Count; $i++) { if ($at[$i].StartsWith('echo      Not restored here:')) { $e2 = $i; break } }
    Assert-True ($s2 -ge 0 -and $e2 -gt $s2) 'test 179: the restore and its report could not be sliced.'
    $wk = @($ra[$s2..$e2] | Where-Object { $_ -match '^\s*start "" /min /wait powershell' })
    Assert-True ($wk.Count -eq 1) 'test 179: the restore worker could not be found.'
    $u8 = @(':Utf8On') + @(Get-BodyLines -Lines $cmd -Label 'Utf8On') + @(':Utf8Off') + @(Get-BodyLines -Lines $cmd -Label 'Utf8Off')
    $stubs = @(':RestartNote', 'echo [RESTART]', 'goto :eof', ':Log', 'goto :eof', ':LogVar', 'goto :eof')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt179_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $lock = $null
    try {
        $cyr = [string]::new([char[]](0x0422, 0x0435, 0x0441, 0x0442))
        $env:PT179_NAME = 'Preset_custom_' + $cyr + '_1.json'
        $ld = Join-Path $dir 'list'; [void](New-Item -ItemType Directory -Path $ld)
        [IO.File]::WriteAllText((Join-Path $ld $env:PT179_NAME), '[]')
        $files = @((Join-Path $dir 'missing.json'), (Join-Path $dir 'held.json'), (Join-Path $dir 'empty.json'), (Join-Path $dir 'none.json'), (Join-Path $dir 'binary.json'), (Join-Path $dir 'bad.json'))
        [IO.File]::WriteAllText($files[1], '[]'); [IO.File]::WriteAllText($files[2], ''); [IO.File]::WriteAllText($files[3], "[]`r`n")
        [IO.File]::WriteAllText($files[4], '[{"key":"HKCU\\Software\\PT179","name":"v","present":true,"oldtype":"REG_BINARY","restorable":false}]' + "`r`n")
        [IO.File]::WriteAllText($files[5], "{ not json`r`n")
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', 'chcp 437 >nul', ('set "BACKUP_DIR=' + $ld + '"'), 'echo [CASE#0]', 'call :List', 'if "!_rnm[1]!"=="!PT179_NAME!" (echo [NAME-SAME]) else (echo [NAME-DIFF])')
        for ($c = 0; $c -lt $files.Count; $c++) { $drv += @(('set "_rfile=' + $files[$c] + '"'), ("echo [CASE#{0}]" -f ($c + 1)), 'call :Restore') }
        $drv += @('echo [END]', 'exit /b 0', ':List') + @($rl[$s..$e]) + @('goto :eof', ':Restore') + @($ra[$s2..$e2]) + @('goto :eof') + $u8 + $stubs
        $lock = [IO.File]::Open($files[1], 'Open', 'Read', 'None')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir -Seconds 120 -Allow ('^' + [regex]::Escape($wk[0].Trim()) + '$')
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 179: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count ($files.Count + 1)
        Assert-True ($sec[0].Contains('[NAME-SAME]')) ('A backup named in another alphabet must be listed with its own letters, not "?": ' + $sec[0])
        foreach ($c in 1, 2, 3, 6) { Assert-True ($sec[$c].Contains('[ERROR] That backup file could not be read') -and -not $sec[$c].Contains('[OK]')) ('{0} must be an unreadable backup, not a restore: {1}' -f (Split-Path -Leaf $files[$c - 1]), $sec[$c]) }
        Assert-True ($sec[4].Contains('[SKIP] That backup holds no values') -and -not $sec[4].Contains('[OK]')) ('An empty backup holds nothing to restore: ' + $sec[4])
        Assert-True ($sec[5].Contains('[WARN] Restore finished: 0 put back, but 1 value(s) this file cannot restore') -and -not $sec[5].Contains('[OK]')) ('A value the file cannot restore must be named, not passed over: ' + $sec[5])
        # the worker that answers nothing, a clean restore and a partial one, with the answer stubbed
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "_rfile=' + $files[3] + '"'))
        $ans = @(@('', '0'), @('3 0 0 0 3', '0'), @('1 1 0 0 2', '1'))
        for ($c = 0; $c -lt $ans.Count; $c++) {
            $af = ''; if ($ans[$c][0]) { $af = Join-Path $dir "ans$c.txt"; [IO.File]::WriteAllText($af, ($ans[$c][0] + "`r`n")) }
            $drv += @(('set "PT_ANS=' + $af + '"'), ('set "PT_RC=' + $ans[$c][1] + '"'), "echo [CASE#$c]", 'call :Restore')
        }
        $drv += @('echo [END]', 'exit /b 0', ':Restore')
        $drv += @($ra[$s2..$e2] | ForEach-Object { if ($_ -match '^\s*start "" /min /wait powershell') { 'if defined PT_ANS copy /y "!PT_ANS!" "!_prres!" >nul'; 'cmd /d /c exit !PT_RC!' } else { $_ } })
        $drv += @('goto :eof') + $stubs
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 179: the stubbed driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $ans.Count
        Assert-True ($sec[0].Contains('[ERROR] PowerShell returned no answer') -and -not $sec[0].Contains('[WARN]')) ('A worker that answered nothing must be reported as such: ' + $sec[0])
        Assert-True ($sec[1].Contains('[OK] Restore finished: 3 value(s) put back')) ('A clean restore must be [OK]: ' + $sec[1])
        Assert-True ($sec[2].Contains('[WARN] Restore incomplete: 1 restored, 1 FAILED') -and -not $sec[2].Contains('[OK]')) ('A partial restore must warn: ' + $sec[2])
    }
    finally {
        if ($lock) { $lock.Dispose() }
        Remove-Item Env:PT179_NAME -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 180. The bundled hosts leaves the Microsoft Store working; the timer helper is out of a standard user's reach; and
#      the restore point, list notices and minimum processor state say what is true.
Invoke-Test 'hosts keeps the Store reachable, the timer helper lives in Program Files, and four screens say what is true' {
    $cmd = Read-Lines $CmdPath
    $hosts = @([IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $CmdPath) 'hosts')) | Where-Object { $_ -match '^0\.0\.0\.0 ' })
    $names = @($hosts | ForEach-Object { $_.Split(' ') | Select-Object -Skip 1 })
    Assert-True ($names.Count -gt 1000) 'test 180: the bundled hosts could not be read.'
    foreach ($h in 'displaycatalog.mp.microsoft.com', 'licensing.mp.microsoft.com', 'storeedgefd.dsx.mp.microsoft.com', 'store-images.s-microsoft.com') {
        Assert-True (-not ($names -contains $h)) "The bundled hosts blocks $h again - Microsoft Store cannot load or install apps without it."
    }
    $ta = @(Get-BodyLines -Lines $cmd -Label 'TimerResApply' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True (@($ta | Where-Object { $_ -ceq 'set "_TRDIR=%ProgramW6432%\Sincript"' }).Count -eq 1 -and @($ta | Where-Object { $_ -ceq 'if not defined ProgramW6432 set "_TRDIR=%ProgramFiles%\Sincript"' }).Count -eq 1 -and @($ta | Where-Object { $_ -match '(?i)set "_TRDIR=%ProgramData%' }).Count -eq 0) 'The timer helper is no longer installed in the 64-bit Program Files (a 32-bit cmd names the (x86) one), or it is under ProgramData again, where a standard user can plant the exe the elevated logon task runs.'
    Assert-True (@($ta | Where-Object { $_.Contains('/TR "\"%_TRDIR%\SetTimerResolution.exe\" --resolution !_res! --no-console"') }).Count -eq 1) 'The logon task no longer quotes the helper path inside /TR - "C:\Program Files" would split at its space.'
    $tr = (@(Get-BodyLines -Lines $cmd -Label 'TimerResRemove' -CodeOnly) -join "`n")
    Assert-True ($tr.Contains('for %%D in ("%ProgramFiles%\Sincript" "%ProgramData%\Sincript" "!_trw!") do if not "%%~D"=="" if exist "%%~D\SetTimerResolution.exe" set "_trleft=1"')) 'Removing the timer helper no longer checks all of its homes.'
    $rp = @(Get-BodyLines -Lines $cmd -Label 'CreateRestorePoint')
    $iw = -1; $is = -1; $il = -1
    for ($i = 0; $i -lt $rp.Count; $i++) { if ($rp[$i] -match '^\s*start "" /min /wait powershell') { $iw = $i }; if ($rp[$i].Trim() -ceq 'call :RpState') { $is = $i }; if ($rp[$i].Contains('call :Log "Creating restore point - System Protection for %SystemDrive% was !_rpst! before"')) { $il = $i } }
    Assert-True ($iw -ge 0 -and $is -ge 0 -and $il -gt $is -and $is -lt $iw -and $rp[$iw].Contains('Enable-ComputerRestore') -and -not $rp[$iw].Contains('may be off')) 'A restore point no longer reads and logs the System Protection state before it may turn it on, or its failure text still guesses that it may be off.'
    Assert-True (@($cmd | Where-Object { $_.Trim() -match '^(?i)echo\b' -and $_ -match 'ASCII-only' }).Count -eq 0) 'A list still says names are shown ASCII-only - letters of other alphabets show as they are since the UTF-8 reads.'
    $mp = @($cmd | Where-Object { $_ -match '^\s*start "" /min /wait powershell' -and $_.Contains('893dee8e-2bef-41e0-89c6-b55d0929964c') -and $_.Contains('$ac=(Get-ItemProperty -Path $p).ACSettingIndex') })
    Assert-True ($mp.Count -eq 1) 'test 180: the minimum processor state worker could not be found.'
    $a = $mp[0].IndexOf('if($ac -eq $null -and $dc -eq $null)'); $b = $mp[0].IndexOf('; $s | Out-File')
    Assert-True ($a -ge 0 -and $b -gt $a) 'The minimum processor state line no longer reports each side on its own.'
    $expr = $mp[0].Substring($a, $b - $a).Replace('%%', '%')
    $show = { param($ac, $dc) & ([scriptblock]::Create('param($ac,$dc) ' + $expr + '; $s')) $ac $dc }
    Assert-True ((& $show 25 $null) -ceq '  AC=25%   DC=scheme default') ('Only AC stored must not print an empty DC: ' + (& $show 25 $null))
    Assert-True ((& $show $null 7) -ceq '  AC=scheme default   DC=7%') ('Only DC stored must not hide it behind "scheme default": ' + (& $show $null 7))
    Assert-True ((& $show 5 5) -ceq '  AC=5%   DC=5%' -and (& $show $null $null) -ceq '  (using scheme default)') 'Both sides stored, or neither, must read as before.'
}


# 181. The driver runner refuses a real command that an echo's closing paren lets through (run).
Invoke-Test 'The driver runner refuses a real command chained after an echo, a pipe or a closing paren (run)' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt181_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        # hostname stands in for a real command: harmless, and its output names this PC
        $me = $env:COMPUTERNAME
        Assert-True ($me.Length -gt 0) 'test 181: COMPUTERNAME is empty, so a run of hostname could not be recognised.'
        $ran = @()
        foreach ($l in 'if 1==0 (echo yes) else hostname', 'echo x & hostname', 'echo x | hostname', 'echo "x" & hostname', 'hostname') {
            try { [void](Invoke-CmdDriver -Lines @('@echo off', $l) -Dir $dir -Real '(?i)\bhostname\b'); $ran += $l }
            catch { if ($_.Exception.Message -notlike '*refusing to run*') { throw } }
        }
        Assert-True ($ran.Count -eq 0) ('The runner let a real command through: ' + ($ran -join ' | '))
        # a & | or ) inside quotes is text to cmd, as in a log line: call :Log "OK (dism exit 0)"
        foreach ($l in 'echo the hostname tool', 'if 1==1 echo hostname here', 'echo a ^& hostname', 'echo "done (hostname exit 0)"', 'echo "a & b | hostname"', 'rem hostname') {
            $r = Invoke-CmdDriver -Lines @('@echo off', $l) -Dir $dir -Real '(?i)\bhostname\b'
            Assert-True (($r.Out -join ' ') -notmatch [regex]::Escape($me)) ("A line that only names the command ran it: $l")
        }
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}


# ---- shared by 185-191: a worker's PowerShell, taken from its line and run with faked cmdlets ----------
function Get-WorkerPayload {
    param([string[]]$Lines, [string]$Key)
    $hits = @($Lines | Where-Object { $_.TrimStart() -notmatch '^(?i)rem\b' -and $_ -match '^\s*start "" /min /wait powershell' -and $_.Contains($Key) })
    Assert-True ($hits.Count -eq 1) ("Expected one worker holding '{0}', found {1} - it moved, so this test is not running it." -f $Key, $hits.Count)
    $m = [regex]::Match($hits[0], '-Command "(.*)"\s*$')
    Assert-True $m.Success "The worker holding '$Key' lost the -Command shape this test extracts."
    $raw = $m.Groups[1].Value
    Assert-True (-not $raw.Contains('!') -and -not $raw.Replace('%%', '').Contains('%')) "The worker holding '$Key' holds a ! or a single %, which cmd would change and this test cannot copy."
    return $raw.Replace('%%', '%')
}
# Runs PowerShell text in a child with stdin closed; anything that could change the machine exits it with 185.
function Invoke-PsPayload {
    param([string]$Text)
    $guard = @'
foreach ($n in @('Disable-ScheduledTask', 'Enable-ScheduledTask', 'Remove-AppxPackage', 'Add-AppxPackage', 'Set-DnsClientServerAddress', 'Enable-ComputerRestore', 'Checkpoint-Computer', 'Start-Process', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item', 'Set-Service', 'Stop-Service', 'Start-Service', 'Clear-RecycleBin')) {
    Set-Item -Path ('function:global:' + $n) -Value ([scriptblock]::Create("[Console]::Error.WriteLine('the worker tried to run $n'); [Environment]::Exit(185)"))
}
'@
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guard + "`n" + $Text))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'a worker did not finish within 60 s.' }
    [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result.Trim() }
}
# Fakes for a provider that does not answer, and for one that answers "no such item".
$script:FakeDead = @'
function global:Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName) Write-Error -Message 'the service did not answer (test)' -Category NotSpecified -ErrorAction Stop }
function global:Get-DnsClientServerAddress { [CmdletBinding()] param($AddressFamily) Write-Error -Message 'the DNS client did not answer (test)' -Category NotSpecified -ErrorAction Stop }
function global:Get-NetAdapter { [CmdletBinding()] param([switch]$Physical) Write-Error -Message 'WMI did not answer (test)' -Category NotSpecified -ErrorAction Stop }
function global:Get-AppxPackage { [CmdletBinding()] param([switch]$AllUsers, [Parameter(Position = 0)]$Name) Write-Error -Message 'the deployment service did not answer (test)' -Category NotSpecified -ErrorAction Stop }
function global:Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) Write-Error -Message 'WMI did not answer (test)' -Category NotSpecified -ErrorAction Stop }
'@
$script:FakeNone = @'
function global:Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName) Write-Error -Message 'No MSFT_ScheduledTask objects found (test)' -Category ObjectNotFound -ErrorAction Stop }
function global:Get-DnsClientServerAddress { [CmdletBinding()] param($AddressFamily) [pscustomobject]@{ InterfaceAlias = 'Ethernet'; ServerAddresses = @() } }
function global:Get-AppxPackage { [CmdletBinding()] param([switch]$AllUsers, [Parameter(Position = 0)]$Name) }
'@

# 182. The no-input reason is printed after the exit screen's cls, not before it (run).
Invoke-Test 'A run that ends on closed input says why after the exit screen clears (run)' {
    $cmd = Read-Lines $CmdPath
    $ni = @(Get-BodyLines -Lines $cmd -Label 'NoInput'); $ex = @(Get-BodyLines -Lines $cmd -Label 'ExitScript')
    Assert-True ($ni.Count -gt 3 -and $ex.Count -gt 5) 'test 182: :NoInput or :ExitScript is missing.'
    Assert-True (@($ni | Where-Object { $_.Trim() -match '^(?i)echo\b' }).Count -eq 0) ':NoInput prints its reason again - every caller jumps to :ExitScript, whose cls wipes it.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt182_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $exd = @($ex | ForEach-Object { $u = $_.Trim(); if ($u -ceq 'cls') { 'echo [CLS]' } elseif ($u -match '^(?i)timeout\b') { 'rem timeout' } else { $_ } })
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', 'set "_NOIN=99"', ('set "LOGFILE=' + (Join-Path $dir 'none.log') + '"'), ('set "BACKUP_DIR=' + $dir + '"'),
                 'call :NoInput || goto ExitScript', 'echo [NOT-REACHED]', 'exit /b 0', ':NoInput') + $ni + @(':ExitScript') + $exd + @(':Logo', 'goto :eof', ':Log', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        $o = @($r.Out)
        $iC = [Array]::IndexOf($o, '[CLS]'); $iE = -1
        for ($i = 0; $i -lt $o.Count; $i++) { if ($o[$i].StartsWith('[ERROR] No input after 100 empty reads')) { $iE = $i } }
        Assert-True ($iC -ge 0 -and $iE -gt $iC -and -not ($o -contains '[NOT-REACHED]')) ('The no-input reason must follow the exit screen''s cls: ' + ($o -join ' | '))
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 183. Unity boot.config: no wildcard, no drive root, and the folder is shown and confirmed first (run).
Invoke-Test 'Unity boot.config refuses a wildcard or a drive root and asks, with the folder shown, before it writes (run)' {
    $cmd = Read-Lines $CmdPath
    $ub = @(Get-BodyLines -Lines $cmd -Label 'UnityBoot')
    $t = @($ub | ForEach-Object { $_.Trim() })
    $qGd = 'set /p "_gd=Path: "'; $qC = 'set /p "_c=Put the tuned boot.config in this folder? (Y/N): "'
    Assert-True (@($t | Where-Object { $_ -ceq $qGd }).Count -eq 1 -and @($t | Where-Object { $_ -ceq $qC }).Count -eq 1) 'test 183: the Unity questions are not the ones this test answers.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt183_' + [guid]::NewGuid().ToString('N'))
    $games = Join-Path $dir 'Games'; $g0 = Join-Path $dir 'G0'
    foreach ($d in 'Zeta_Data', 'Yota_Data', 'Plain') { [void](New-Item -ItemType Directory -Path (Join-Path $games $d)) }
    foreach ($d in 'Alpha_Data', 'Beta_Data') { [void](New-Item -ItemType Directory -Path (Join-Path $g0 $d)) }
    try {
        $body = @($ub | ForEach-Object { $u = $_.Trim(); if ($u -ceq $qGd) { 'set "_gd=!PT_GD!"' } elseif ($u -ceq $qC) { 'set "_c=!PT_C!"' } elseif ($u -ceq 'pause' -or $u -ceq 'cls') { 'rem ' + $u } else { $_ } })
        $cases = @(@((Join-Path $g0 '*_Data'), 'Y'), @('C:\', 'Y'), @((Join-Path $games 'Yota_Data'), 'N'), @((Join-Path $games 'Zeta_Data'), 'Y'), @((Join-Path $games 'Plain'), 'N'))
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "TEMP=' + $dir + '"'), ('set "SCRIPT_DIR=' + $dir + '\"'))
        for ($c = 0; $c -lt $cases.Count; $c++) { $drv += @(('set "PT_GD=' + $cases[$c][0] + '"'), ('set "PT_C=' + $cases[$c][1] + '"'), "echo [CASE#$c]", 'call :UnityBoot') }
        $drv += @('echo [END]', 'exit /b 0', ':UnityBoot') + $body + @(':Logo', 'goto :eof', ':Log', 'goto :eof', ':MenuApps', 'echo [MENU]', 'goto :eof',
                  ':RequireBundledFile', 'exit /b 0', ':DetectUnityJobWorkers', 'set "_JWCOUNT=7" & set "_CORESRC=8 logical processors"', 'goto :eof',
                  ':PrepareBootConfig', '>"!PT_OUT!" echo job-worker-count=7', 'set "PT_SRC=" & set "PT_OUT=" & set "PT_JW="', 'exit /b 0')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0) ('test 183: the driver failed: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        $placed = { param($d) Test-Path -LiteralPath (Join-Path $games "$d\boot.config") }
        Assert-True ($sec[0].Contains('holds a * or ?') -and @(Get-ChildItem -LiteralPath $g0 -Recurse -Filter 'boot.config*').Count -eq 0) ('A typed wildcard must be refused before pushd picks a folder: ' + $sec[0])
        Assert-True ($sec[1].Contains('That is a drive') -and -not (Test-Path -LiteralPath (Join-Path $dir 'boot.config'))) ('A drive root must be refused, not read as the current folder: ' + $sec[1])
        Assert-True ($sec[2].Contains('Folder: ' + (Join-Path $games 'Yota_Data')) -and $sec[2].Contains('Nothing was changed') -and -not (& $placed 'Yota_Data')) ('The folder must be shown first, and N must change nothing: ' + $sec[2])
        Assert-True ($sec[3].Contains('[OK] boot.config placed') -and (& $placed 'Zeta_Data') -and -not $sec[3].Contains('[WARN]')) ('Y in a *_Data folder must place the file: ' + $sec[3])
        Assert-True ($sec[4].Contains('[WARN]') -and $sec[4].Contains('_Data') -and -not (& $placed 'Plain')) ('A folder not named *_Data must be flagged: ' + $sec[4])
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 184. SteamLight reads the Steam folder with delayed expansion off, so a "!" in it survives (run).
Invoke-Test 'SteamLight keeps a "!" in the Steam folder it reads from the registry (run)' {
    $cmd = Read-Lines $CmdPath
    $sl = @(Get-BodyLines -Lines $cmd -Label 'SteamLight')
    $t = @($sl | ForEach-Object { $_.Trim() })
    $s = [Array]::IndexOf($t, 'set "_STEAMDIR="'); $e = -1
    for ($i = [Math]::Max($s, 0); $i -lt $t.Count; $i++) { if ($t[$i] -ceq 'if defined _STEAMDIR set "_STEAMDIR=!_STEAMDIR:/=\!"') { $e = $i; break } }
    Assert-True ($s -ge 0 -and $e -gt $s) 'test 184: the Steam folder read could not be sliced.'
    $reads = @(for ($i = $s; $i -le $e; $i++) { if ($t[$i] -match 'reg query "HK[^"]*\\Valve\\Steam"') { $i } })
    $off = [Array]::IndexOf($t, 'setlocal DisableDelayedExpansion'); $end = [Array]::IndexOf($t, 'endlocal')
    Assert-True ($reads.Count -eq 3 -and $off -gt $s -and $off -lt $reads[0] -and $end -gt $reads[2] -and $end -lt $e) 'SteamLight reads the Steam folder with delayed expansion on again - a "!" in it is lost.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt184_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $steam = Join-Path $dir 'Valve!\Steam'
        [IO.File]::WriteAllText((Join-Path $dir 'none.txt'), '')
        [IO.File]::WriteAllText((Join-Path $dir 'hit.txt'), ("`r`nHKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam`r`n    InstallPath    REG_SZ    " + $steam + "`r`n`r`n"))
        $slice = @($sl[$s..$e] | ForEach-Object {
            if ($_.Contains('WOW6432Node\Valve\Steam')) { $_ -replace "\('reg query [^']*'\)", "('type ""%%PT184A%%"" 2^>nul ^| findstr /I ""InstallPath""')" }
            elseif ($_ -match "\('reg query ") { $_ -replace "\('reg query [^']*'\)", "('type ""%%PT184B%%"" 2^>nul ^| findstr /I ""InstallPath""')" }
            else { $_ } })
        Assert-True (@($slice | Where-Object { $_ -match '(?i)reg query' }).Count -eq 0) 'test 184: a real reg query survived the stubbing - refusing to run.'
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "TEMP=' + $dir + '"'), ('set "PT184A=' + (Join-Path $dir 'none.txt') + '"'), ('set "PT184B=' + (Join-Path $dir 'hit.txt') + '"')) +
               $slice + @('echo [DIR]!_STEAMDIR!', 'exit /b 0', ':Utf8On', 'goto :eof', ':Utf8Off', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0) ('test 184: the driver failed: ' + $r.Err)
        Assert-True (@($r.Out) -contains ('[DIR]' + $steam)) ('The Steam folder must arrive with its "!": ' + ($r.Out -join ' | '))
        Assert-True (@(Get-ChildItem -LiteralPath $dir -Filter 'PerfTweaks_steam_*').Count -eq 0) 'SteamLight left its hand-off file in TEMP.'
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 185. A Task Scheduler, DNS client, adapter list, app list or System Protection read that does not answer is not
#      "none" - in the workers, run with faked cmdlets, and in the batch that reads their answers (run).
Invoke-Test 'Workers tell "could not look" from "none", and the screens count it as a failure (run)' {
    $cmd = Read-Lines $CmdPath
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt185_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $f = { param($n) Join-Path $dir $n }
        $set = { param([hashtable]$Env) ($Env.GetEnumerator() | ForEach-Object { "`$env:{0} = '{1}'" -f $_.Key, $_.Value.Replace("'", "''") }) -join "`n" }
        $read = { param($n) if (Test-Path -LiteralPath (& $f $n)) { (Get-Content -Raw -LiteralPath (& $f $n)).Trim() } else { '<none>' } }
        # extra telemetry tasks
        $w = Get-WorkerPayload -Lines $cmd -Key '$env:PT_TK_RES'
        foreach ($k in @(@('dead', $script:FakeDead, '0 0 2 2'), @('none', $script:FakeNone, '0 0 2 0'))) {
            $r = Invoke-PsPayload ((& $set @{ PT_TK_RES = (& $f "tk_$($k[0]).txt"); PT_TK_NAMES = 'pt185a|pt185b' }) + "`n" + $k[1] + "`n" + $w)
            Assert-True ((& $read "tk_$($k[0]).txt") -ceq $k[2]) ('The telemetry task worker with a provider that is {0} must answer "{1}": {2} {3}' -f $k[0], $k[2], (& $read "tk_$($k[0]).txt"), $r.Err)
        }
        # the telemetry undo file
        $w = Get-WorkerPayload -Lines $cmd -Key 'Set-Content -LiteralPath $env:PT_TLBAK'
        foreach ($k in @(@('dead', $script:FakeDead, 2, 'could not be read - Task Scheduler did not answer'), @('none', $script:FakeNone, 0, 'is not present on this edition'))) {
            $r = Invoke-PsPayload ((& $set @{ PT_TLBAK = (& $f "tl_$($k[0]).bat"); PT_TL_SVC = 'PT185NoSuchService'; PT_TL_TASKS = 'pt185a|pt185b' }) + "`n" + $k[1] + "`n" + $w)
            $txt = & $read "tl_$($k[0]).bat"
            Assert-True ($r.Code -eq $k[2] -and ([regex]::Matches($txt, [regex]::Escape($k[3]))).Count -eq 2) ('The telemetry undo worker with a provider that is {0} must exit {1} and say "{2}" for both tasks: exit {3} | {4} {5}' -f $k[0], $k[2], $k[3], $r.Code, $txt, $r.Err)
        }
        # NVIDIA tasks
        $w = Get-WorkerPayload -Lines $cmd -Key '$env:PT_NV_RES'
        $r = Invoke-PsPayload ((& $set @{ PT_NV_RES = (& $f 'nv.txt'); PT_NV_UNDO = (& $f 'nv_undo.bat') }) + "`n" + $script:FakeDead + "`n" + $w)
        Assert-True ((& $read 'nv.txt') -ceq 'E 0 0' -and $r.Code -eq 2 -and -not (Test-Path -LiteralPath (& $f 'nv_undo.bat'))) ('The NVIDIA task worker must answer E when the task list cannot be read: ' + (& $read 'nv.txt') + ' ' + $r.Err)
        # Status DNS list
        $w = Get-WorkerPayload -Lines $cmd -Key 'Wu8 $env:PT_DNSF'
        foreach ($k in @(@('dead', $script:FakeDead, 'could not read the DNS settings'), @('none', $script:FakeNone, 'no adapter has a DNS server set'))) {
            $r = Invoke-PsPayload ((& $set @{ PT_DNSF = (& $f "dns_$($k[0]).txt") }) + "`n" + $k[1] + "`n" + $w)
            Assert-True ((& $read "dns_$($k[0]).txt").Contains($k[2])) ('Status DNS with a DNS client that is {0} must say "{1}": {2} {3}' -f $k[0], $k[2], (& $read "dns_$($k[0]).txt"), $r.Err)
        }
        # DNS reset: the adapter list
        $w = Get-WorkerPayload -Lines $cmd -Key 'ResetServerAddresses'
        $r = Invoke-PsPayload ((& $set @{ PT_DNSRES = (& $f 'dnsres.txt') }) + "`n" + $script:FakeDead + "`n" + $w)
        Assert-True ((& $read 'dnsres.txt') -ceq 'E 0' -and $r.Code -eq 2) ('The DNS reset worker must answer E when the adapters cannot be listed: ' + (& $read 'dnsres.txt') + ' ' + $r.Err)
        # Debloat lookups
        $w = Get-WorkerPayload -Lines $cmd -Key '$env:PT_DB_RES'
        foreach ($k in @(@('dead', $script:FakeDead, '0 0 0 2'), @('none', $script:FakeNone, '0 0 2 0'))) {
            $r = Invoke-PsPayload ((& $set @{ PT_DB_RES = (& $f "db_$($k[0]).txt"); PT_DB_PKGS = 'pt185a|pt185b' }) + "`n" + $k[1] + "`n" + $w)
            Assert-True ((& $read "db_$($k[0]).txt") -ceq $k[2]) ('The Debloat worker with an app list that is {0} must answer "{1}": {2} {3}' -f $k[0], $k[2], (& $read "db_$($k[0]).txt"), $r.Err)
        }
        # System Protection state
        $w = Get-WorkerPayload -Lines $cmd -Key '$env:PT_RPST'
        $r = Invoke-PsPayload ((& $set @{ PT_RPST = (& $f 'rpst.txt') }) + "`n" + $script:FakeDead + "`n" + $w)
        Assert-True ((& $read 'rpst.txt') -ceq 'unknown') ('A System Protection read that fails must answer unknown, never off: ' + (& $read 'rpst.txt') + ' ' + $r.Err)

        # the batch side: the answers are counted failures, not [SKIP]
        $rs = @(@('DisableTelemetryTasks', '_tkres'), @('DisableNvidiaTelemetryTasks', '_nvres'), @('DebloatRun', '_dbres'))
        $bodies = @()
        foreach ($x in $rs) {
            $b = @(Get-BodyLines -Lines $cmd -Label $x[0])
            Assert-True (@($b | Where-Object { $_ -match '^\s*start "" /min /wait powershell' }).Count -eq 1) ("test 185: :{0} no longer has one worker line." -f $x[0])
            $bodies += ':' + $x[0]
            $bodies += @($b | ForEach-Object { if ($_ -match '^\s*start "" /min /wait powershell') { 'if defined PT_ANS copy /y "!PT_ANS!" "!' + $x[1] + '!" >nul' } else { $_ } })
        }
        $bodies += @(':DnsResult') + @(Get-BodyLines -Lines $cmd -Label 'DnsResult')
        $cases = @(@('call :DisableTelemetryTasks', '0 0 10 10'), @('call :DisableTelemetryTasks', '2 2 10 1'), @('call :DisableNvidiaTelemetryTasks', 'E 0 0'),
                   @('call :DebloatRun "a|b" "Test apps"', '0 0 0 2'), @('call :DebloatRun "a|b" "Test apps"', '1 0 1 0'),
                   @('call :DnsResult "2" "DNS test"', 'E 0'), @('call :DnsResult "0" "DNS test"', '1 0'))
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "BACKUP_DIR=' + $dir + '"'), 'set "_ELEV=1"')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $af = & $f "ans$c.txt"; [IO.File]::WriteAllText($af, ($cases[$c][1] + "`r`n"))
            $drv += @(('set "PT_ANS=' + $af + '"'), ('set "_dnsres=' + (& $f "dnsans$c.txt") + '"'), ('copy /y "' + $af + '" "!_dnsres!" >nul'), 'set "_FAILS=0" & set "_dbdid="', "echo [CASE#$c]", $cases[$c][0], 'echo [FAILS]!_FAILS! [DID]!_dbdid!')
        }
        $drv += @('echo [END]', 'exit /b 0') + $bodies + @(':Log', 'goto :eof', ':LogVar', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 185: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        Assert-True ($sec[0].Contains('Task Scheduler did not answer for 10 of 10') -and $sec[0].Contains('[FAILS]1') -and -not $sec[0].Contains('[SKIP]')) ('Telemetry tasks nobody could look up must be a counted [FAIL], not "none exist": ' + $sec[0])
        Assert-True ($sec[1].Contains('did not answer for 1 of 10') -and $sec[1].Contains('[OK] Extra telemetry tasks: disabled 2 of 2 found') -and $sec[1].Contains('[FAILS]1')) ('A partial lookup must report both halves: ' + $sec[1])
        Assert-True ($sec[2].Contains('NVIDIA telemetry tasks: Task Scheduler did not answer') -and $sec[2].Contains('[FAILS]1') -and -not $sec[2].Contains('[SKIP]')) ('An unreadable NVIDIA task list must be a counted [FAIL]: ' + $sec[2])
        Assert-True ($sec[3].Contains('could not be looked up') -and -not $sec[3].Contains('[SKIP]') -and $sec[3] -match '\[DID\]\s*$') ('Apps nobody could look up must not read as "none installed": ' + $sec[3])
        Assert-True ($sec[4].Contains('[OK] Test apps: removed 1') -and $sec[4].Contains('[DID]1')) ('A removal must be recorded for the closing line: ' + $sec[4])
        Assert-True ($sec[5].Contains('could not be listed') -and $sec[5].Contains('[FAILS]1') -and -not $sec[5].Contains('elevated')) ('An adapter list that could not be read must not blame elevation: ' + $sec[5])
        Assert-True ($sec[6].Contains('[OK] DNS test on 1 adapter') -and $sec[6].Contains('[FAILS]0')) ('A DNS change that worked must read as before: ' + $sec[6])
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 186. Custom presets: names with ! and ^ are listed and picked as they are, and a "!" on a directive line is
#      refused from the menu and from the command line (run).
Invoke-Test 'Preset names with ! or ^ are listed and picked as they are, and a "!" on a directive line is refused (run)' {
    $cmd = Read-Lines $CmdPath
    $pc = @(Get-BodyLines -Lines $cmd -Label 'PresetCustom'); $pa = @(Get-BodyLines -Lines $cmd -Label 'PresetCustom_ask')
    $qSel = 'set /p "sel=Choose a preset file: "'
    $qCc = @('set /p "_cc=Apply the valid directives and skip the problems? (Y/N): "', 'set /p "_cc=Apply these %_pgood% directive(s)? (Y/N): "')
    Assert-True (@($pa | Where-Object { $_.Trim() -ceq $qSel }).Count -eq 1) 'test 186: the preset pick is not the question this test answers.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt186_' + [guid]::NewGuid().ToString('N'))
    $pd = Join-Path $dir 'sincript_presets'
    [void](New-Item -ItemType Directory -Path $pd)
    try {
        $files = [ordered]@{ 'bang.preset' = "# a comment with a ! is fine`r`ncleanup=1!`r`n"; 'ca^ret.preset' = "privacy=1`r`n"; 'Hi!There.preset' = "cleanup=1`r`n"; 'ok.preset' = "# fine!`r`ncleanup=1`r`n" }
        foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $pd $k), $files[$k]) }
        $map = { param($l) $u = $l.Trim(); if ($u -ceq $qSel) { 'set "sel=!PT_SEL!"' } elseif ($qCc -ccontains $u) { 'set "_cc=N"' } elseif ($u -ceq 'pause' -or $u -ceq 'cls') { 'rem ' + $u } else { $l } }
        $body = @(':PresetCustom') + @($pc | ForEach-Object { & $map $_ }) + @(':PresetCustom_ask') + @($pa | ForEach-Object { & $map $_ })
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "TEMP=' + $dir + '"'), ('set "SCRIPT_DIR=' + $dir + '\"'))
        $sel = @('1', '2', '3', '4')
        for ($c = 0; $c -lt $sel.Count; $c++) { $drv += @(('set "PT_SEL=' + $sel[$c] + '"'), "echo [CASE#$c]", 'call :PresetCustom') }
        # the command line: the same refusal, with exit 2
        $cli = @(Get-BodyLines -Lines $cmd -Label 'CliRun')
        $cs = -1; $ce = -1; for ($i = 0; $i -lt $cli.Count; $i++) { if ($cli[$i].Trim() -ceq 'set "_CLIKIND=builtin"') { $cs = $i }; if ($cli[$i].Trim() -ceq ':_cliResolved') { $ce = $i } }
        Assert-True ($cs -ge 0 -and $ce -gt $cs) 'test 186: the command-line preset check could not be sliced.'
        foreach ($n in 'bang', 'ok') { $drv += @(('set "_CLIPRESET=' + $n + '"'), "echo [CASE#$($sel.Count + [int]($n -eq 'ok'))]", 'call :CliPreset', 'echo [RC]!errorlevel!') }
        $drv += @('echo [END]', 'exit /b 0') + $body + @(':CliPreset') + @($cli[$cs..($ce - 1)]) + @('exit /b 0', ':_cliBadName', 'exit /b 9') +
                @(':PresetBangCheck') + @(Get-BodyLines -Lines $cmd -Label 'PresetBangCheck') +
                @(':PresetCheckLine', 'echo [LINE] !_k!=!_v!', 'set /a _pgood+=1', 'goto :eof', ':Logo', 'goto :eof', ':Log', 'goto :eof', ':LogVar', 'goto :eof',
                  ':MenuPresets', 'echo [MENU]', 'goto :eof', ':NoInput', 'exit /b 1', ':ExitScript', 'goto :eof', ':RpNote', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0) ('test 186: the driver failed: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count ($sel.Count + 2)
        foreach ($n in '1.  bang.preset', '2.  ca^ret.preset', '3.  Hi!There.preset', '4.  ok.preset') { Assert-True ($sec[0].Contains($n)) ("The preset list must show '$n' as it is: " + $sec[0]) }
        Assert-True ($sec[0].Contains('has an exclamation mark on a directive line') -and -not $sec[0].Contains('[LINE]')) ('A "!" on a directive line must be refused before the file is read: ' + $sec[0])
        Assert-True ($sec[1] -match 'Preset file:\s+ca\^ret\.preset' -and $sec[1].Contains('[LINE] privacy=1')) ('A "^" in the name must reach the file: ' + $sec[1])
        Assert-True ($sec[2] -match 'Preset file:\s+Hi!There\.preset' -and $sec[2].Contains('[LINE] cleanup=1')) ('A "!" in the name must reach the file: ' + $sec[2])
        Assert-True ($sec[3].Contains('[LINE] cleanup=1') -and -not $sec[3].Contains('exclamation')) ('A "!" in a comment line must not refuse the file: ' + $sec[3])
        Assert-True ($sec[4].Contains('has an exclamation mark on a directive line') -and $sec[4].Contains('[RC]2')) ('The command line must refuse the file with exit 2: ' + $sec[4])
        Assert-True ($sec[5].Contains('[LINE] cleanup=1') -and $sec[5].Contains('[RC]0')) ('The command line must read a clean file: ' + $sec[5])
        Assert-True (@(Get-ChildItem -LiteralPath $dir -File -Filter 'sincript_p*').Count -eq 0) 'The preset list or pick file was left in TEMP.'
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 187. Small fixes from the re-check stay fixed: the power timeouts are asked, the timer helper is removed from
#      every home (run), list names show ! and ^ as ?, a failed OpenAsar download counts, Debloat says when nothing
#      was removed, and the disk cache follows every internal disk.
Invoke-Test 'Power asks before the timeouts, the timer helper leaves no copy (run), and five more re-check fixes stay' {
    $cmd = Read-Lines $CmdPath
    $pw = @(Get-BodyLines -Lines $cmd -Label 'Power' -CodeOnly | ForEach-Object { $_.Trim() })
    $to = @($pw | Where-Object { $_ -match '(?i)call :DoPowerTimeouts' })
    $iq = -1; $isw = -1
    for ($i = 0; $i -lt $pw.Count; $i++) { if ($pw[$i].StartsWith('set /p "_tmo=')) { $iq = $i }; if ($pw[$i] -ceq 'if defined _PWPLAN call :DoPowerPlanSwitch') { $isw = $i } }
    Assert-True ($to.Count -eq 1 -and $to[0] -ceq 'if /i "!_tmo!"=="Y" call :DoPowerTimeouts' -and $iq -gt $isw -and $isw -ge 0) 'A plan pick sets the never-sleep timeouts without asking again - picking a plan is not a yes to them.'
    # the timer helper, removed from the 64-bit Program Files, the (x86) one and ProgramData
    $tr = @(Get-BodyLines -Lines $cmd -Label 'TimerResRemove' -CodeOnly)
    $loops = @($tr | Where-Object { $_ -match '^\s*for %%D in \(' }); $trw = @($tr | Where-Object { $_.Trim() -match '^(set "_trw="|if defined ProgramW6432 set "_trw=)' })
    Assert-True ($loops.Count -eq 3 -and $trw.Count -eq 2) 'test 187: the timer helper removal changed shape.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt187_' + [guid]::NewGuid().ToString('N'))
    foreach ($d in 'pf64\Sincript', 'pf86\Sincript', 'pd\Sincript') { [void](New-Item -ItemType Directory -Path (Join-Path $dir $d)) }
    try {
        foreach ($d in 'pf64', 'pf86') { [IO.File]::WriteAllText((Join-Path $dir "$d\Sincript\SetTimerResolution.exe"), 'x') }
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "ProgramW6432=' + (Join-Path $dir 'pf64') + '"'), ('set "ProgramFiles=' + (Join-Path $dir 'pf86') + '"'), ('set "ProgramData=' + (Join-Path $dir 'pd') + '"'),
                 'set "_trleft=0"') + $trw + $loops + @('echo [LEFT]!_trleft!')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True (@($r.Out) -contains '[LEFT]0' -and -not (Test-Path -LiteralPath (Join-Path $dir 'pf64\Sincript')) -and -not (Test-Path -LiteralPath (Join-Path $dir 'pf86\Sincript'))) ('A copy under either Program Files must be removed and the result must say none is left: ' + ($r.Out -join ' | '))
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($lb in 'PathWorker', 'LockWorker') {
        $w = @(Get-BodyLines -Lines $cmd -Label $lb | Where-Object { $_ -match '^\s*start "" /min /wait powershell' })
        Assert-True (@($w | Where-Object { $_.Contains("-replace '[\x00-\x1f\x7f]','?' -replace '[\x21\x5e]','?'") }).Count -ge 1) ":$lb no longer shows ! and ^ as ? - the batch list copies names with delayed expansion on, which drops them."
    }
    $oa = @(Get-BodyLines -Lines $cmd -Label '_oasDlFail' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True (@($oa | Where-Object { $_ -ceq 'set /a _FAILS+=1' }).Count -eq 1) 'A failed OpenAsar download prints [ERROR] but is not counted, so a preset run ends in [OK] and exit 0.'
    $dd = @(Get-BodyLines -Lines $cmd -Label 'DebloatDone')
    Assert-True ((Test-BlockExit -Lines $dd -Open '^if not defined _dbdid \($' -Exit '^goto MenuApps$') -eq 1 -and @($dd | Where-Object { $_.Contains('echo Nothing was removed.') }).Count -eq 1) 'Debloat ends with "Done. Most removed apps ..." when nothing was removed.'
    $sd = @(Get-BodyLines -Lines $cmd -Label 'DetectSysDisk' -CodeOnly) -join "`n"
    Assert-True ($sd.Contains('reg query "HKLM\SYSTEM\CurrentControlSet\Services\disk\Enum" 2^>nul') -and $sd.Contains('if /i not "!_sdv:~0,8!"=="USBSTOR\" set "_sdkey=!_sdkey!%%C;"') -and -not $sd.Contains('Enum" /v 0')) 'The disk-type cache is keyed on disk 0 alone again - Windows moved to another disk would reuse the old answer.'
}

# 188. A blank boot.config is refused, and a missing worker key is added (run).
Invoke-Test 'The boot.config worker refuses a blank source and adds a missing worker key (run)' {
    $cmd = Read-Lines $CmdPath
    $w = Get-WorkerPayload -Lines $cmd -Key '$env:PT_OUT -Value $out'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt188_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $cases = [ordered]@{ 'nl' = "`r`n"; 'spaces' = "  `r`n `r`n"; 'nokeys' = "gfx-enable-gfx-jobs=1`r`n"; 'one' = "job-worker-count=2`r`nvr-enabled=0`r`n" }
        $res = @{}
        foreach ($k in $cases.Keys) {
            $src = Join-Path $dir "$k.config"; [IO.File]::WriteAllText($src, $cases[$k])
            $pre = "`$env:PT_SRC = '{0}'`n`$env:PT_OUT = '{0}.out'`n`$env:PT_JW = '7'`n" -f $src.Replace("'", "''")
            $r = Invoke-PsPayload ($pre + $w)
            $out = if (Test-Path -LiteralPath "$src.out") { [IO.File]::ReadAllText("$src.out") } else { '' }
            $res[$k] = @($r.Code, $out)
        }
        foreach ($k in 'nl', 'spaces') { Assert-True ($res[$k][0] -eq 1 -and $res[$k][1] -eq '') ("A boot.config holding only blank lines ($k) must be refused, not installed: exit {0}" -f $res[$k][0]) }
        Assert-True ($res['nokeys'][0] -eq 0 -and $res['nokeys'][1].Contains('job-worker-count=7') -and $res['nokeys'][1].Contains('job-worker-maximum-count=7') -and $res['nokeys'][1].Contains('gfx-enable-gfx-jobs=1')) ('A source without the worker keys must get both: ' + $res['nokeys'][1])
        Assert-True ($res['one'][0] -eq 0 -and ([regex]::Matches($res['one'][1], 'job-worker-count=')).Count -eq 1 -and $res['one'][1].Contains('job-worker-count=7') -and $res['one'][1].Contains('job-worker-maximum-count=7')) ('A source with one key must have it replaced and the other added: ' + $res['one'][1])
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 189. A restore point is asked after the change it guards, says first when it would turn System Protection on,
#      and shows a failure reason in UTF-8.
Invoke-Test 'The restore-point question comes after the go-ahead, names a System Protection switch-on first, and shows UTF-8' {
    $cmd = Read-Lines $CmdPath
    $qs = @{ 'DisableMitigations' = 'set /p "_c=Disable mitigations now? (Y/N): "'; 'NvmeFlags' = 'set /p "_c=Apply NVMe flags? (Y/N): "'; 'ApplyRecommended' = 'set /p "_c=Proceed with the recommended set? (Y/N): "'
             'PresetModerate' = 'set /p "_c=Apply the MODERATE preset? (Y/N): "'; 'PresetHeavy' = 'set /p "_c=Apply the HEAVY preset? (Y/N): "' }
    foreach ($lb in $qs.Keys) {
        $b = @(Get-BodyLines -Lines $cmd -Label $lb -CodeOnly | ForEach-Object { $_.Trim() })
        $ia = [Array]::IndexOf($b, $qs[$lb]); $in = [Array]::IndexOf($b, 'call :RpNote'); $ir = -1
        for ($i = 0; $i -lt $b.Count; $i++) { if ($b[$i].StartsWith('set /p "_rp=')) { $ir = $i } }
        Assert-True ($ia -ge 0 -and $in -gt $ia -and $ir -gt $in) ":$lb asks for the restore point before its own go-ahead again, or without saying what it does to System Protection - declining the change would leave a restore point and System Protection on."
    }
    $all = @($cmd | ForEach-Object { $_.Trim() })
    $rpq = @(for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i].StartsWith('set /p "_rp=')) { $i } })
    Assert-True ($rpq.Count -ge 6 -and @($rpq | Where-Object { $all[$_ - 2] -cne 'call :RpNote' }).Count -eq 0) 'A restore-point question is asked without :RpNote first.'
    $dr = @(Get-BodyLines -Lines $cmd -Label 'DoRestorePoint' -CodeOnly | ForEach-Object { $_.Trim() })
    Assert-True ([Array]::IndexOf($dr, 'call :RpNote') -ge 0 -and [Array]::IndexOf($dr, 'call :RpNote') -lt [Array]::IndexOf($dr, 'call :CreateRestorePoint') -and $dr -contains 'if /i "!_rpst!"=="on" goto _drpGo' -and $dr -contains 'if /i not "!_c!"=="Y" goto MenuBackups') 'Create restore point turns System Protection on without asking.'
    $rn = @(Get-BodyLines -Lines $cmd -Label 'RpNote' -NoEcho | ForEach-Object { $_.Trim() }); $re = (@(Get-BodyLines -Lines $cmd -Label 'RpNote') -join "`n")
    Assert-True ($rn -contains 'call :RpState' -and $re.Contains('if /i "!_rpst!"=="off" echo') -and $re.Contains('if /i "!_rpst!"=="unknown" echo')) ':RpNote no longer says, for both "off" and "could not tell", that a restore point turns System Protection on.'
    $cr = @(Get-BodyLines -Lines $cmd -Label 'CreateRestorePoint' -CodeOnly | ForEach-Object { $_.Trim() })
    $iw = -1; for ($i = 0; $i -lt $cr.Count; $i++) { if ($cr[$i].StartsWith('start "" /min /wait powershell')) { $iw = $i } }
    Assert-True ($iw -ge 0 -and $cr[$iw].Contains('(New-Object Text.UTF8Encoding $false)') -and $cr[$iw + 2] -ceq 'call :Utf8On' -and $cr[$iw + 3].StartsWith('if exist "!_rpf!" type') -and $cr[$iw + 4] -ceq 'call :Utf8Off') 'The restore point result is written or shown outside UTF-8 again - a failure reason in another language turns into "?".'
}

# 190. The crash report counts every undo file a session writes into the backup folder.
Invoke-Test 'The crash report''s "undo files written" count knows every kind the script writes there' {
    $cmd = Read-Lines $CmdPath
    $w = @($cmd | Where-Object { $_ -match '^\s*start "" /min /wait powershell' -and $_.Contains('$bk=@($fs | Where-Object {') })
    Assert-True ($w.Count -eq 1) 'test 190: the crash worker''s undo-file filter could not be found.'
    $m = [regex]::Match($w[0], '\$bk=@\(\$fs \| Where-Object \{(.*?)\}\);')
    Assert-True $m.Success 'test 190: the filter changed shape.'
    $filter = [scriptblock]::Create($m.Groups[1].Value)
    # every file name a write site under BACKUP_DIR builds, with its variables filled in
    $sites = @($cmd | Where-Object { $_.Trim() -notmatch '^(?i)(rem|echo)\b' } | ForEach-Object { [regex]::Matches($_, '!BACKUP_DIR!\\([^"*]+\.(bak|reg|json|bat|txt|log))') } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True ($sites.Count -ge 10) ('test 190: only {0} write sites under the backup folder were found - the scan is not seeing them.' -f $sites.Count)
    $fill = { param($s) $s = $s.Replace('%_flav%', 'Discord'); $s = [regex]::Replace($s, '%RANDOM%', '1234'); [regex]::Replace($s, '(%[^%]+%|![^!]+!)', 'x') }
    $not = '^(PerfTweaks|CrashReport|FullReg)_'
    foreach ($s in $sites) {
        $name = & $fill $s
        $hit = @([pscustomobject]@{ Name = $name } | Where-Object $filter).Count -eq 1
        if ($name -match $not) { Assert-True (-not $hit) "The crash report counts $name as an undo file - it is a log or a full export." }
        else { Assert-True $hit "The crash report does not count $name (written as $s) as an undo file, so a session that wrote only that reads as '0 undo file(s) written'." }
    }
}

# 191. Cleanup judges the Recycle Bin by its item count before and after: Windows PowerShell 5.1's
#      Clear-RecycleBin can report an error after emptying the bin, which read as "could not be emptied" (run).
Invoke-Test 'Cleanup judges the Recycle Bin by its item count, so a stale Clear-RecycleBin error is no [WARN] (run)' {
    $cmd = Read-Lines $CmdPath
    $w = Get-WorkerPayload -Lines $cmd -Key 'Clear-RecycleBin -Force'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt191_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        # a Shell whose Recycle Bin (folder 10) holds PT191_N items, and a Clear-RecycleBin that leaves PT191_LEFT,
        # then reports the 5.1 stale error (stale) or throws before deleting anything (throw)
        $fake = @'
function global:New-Object { param([string]$ComObject) if ($ComObject -ne 'Shell.Application' -or $global:PT191_DEAD) { throw 'the shell did not answer (test)' }
    $bin = [pscustomobject]@{}; $bin | Add-Member -MemberType ScriptMethod -Name Items -Value { [pscustomobject]@{ Count = $global:PT191_N } }
    $sh = [pscustomobject]@{ Bin = $bin }; $sh | Add-Member -MemberType ScriptMethod -Name Namespace -Value { param($n) if ($n -eq 10) { $this.Bin } }; $sh }
function global:Clear-RecycleBin { [CmdletBinding()] param([switch]$Force)
    if (-not $Force) { return }
    if ($global:PT191_MODE -eq 'throw') { Write-Error -Message 'access denied (test)' -Category PermissionDenied -ErrorAction Stop }
    $global:PT191_N = $global:PT191_LEFT
    if ($global:PT191_MODE -eq 'stale') { Write-Error -Message 'The system cannot find the path specified (test)' -Category NotSpecified } }
'@
        $wk = [ordered]@{ 'stale' = @(3, 0, 'stale', 0, '3 0'); 'empty' = @(0, 0, 'stale', 0, '0 0'); 'left' = @(4, 1, '', 0, '4 1'); 'throw' = @(2, 0, 'throw', 0, '2 2'); 'dead' = @(5, 0, '', 1, '-1 -1') }
        foreach ($k in $wk.Keys) {
            $v = $wk[$k]; $af = Join-Path $dir "ans_$k.txt"
            $pre = "`$env:PT_RBRES = '{0}'`n`$global:PT191_N = {1}; `$global:PT191_LEFT = {2}; `$global:PT191_MODE = '{3}'; `$global:PT191_DEAD = {4}`n" -f $af.Replace("'", "''"), $v[0], $v[1], $v[2], $v[3]
            $r = Invoke-PsPayload ($pre + $fake + "`n" + $w)
            $got = if (Test-Path -LiteralPath $af) { (Get-Content -Raw -LiteralPath $af).Trim() } else { '<none>' }
            Assert-True ($got -ceq $v[4]) ('The Recycle Bin worker ({0}) must answer "{1}": {2} {3}' -f $k, $v[4], $got, $r.Err)
        }
        # the batch side, fed the answers above; "none" = PowerShell left no answer
        $cl = @(Get-BodyLines -Lines $cmd -Label 'Cleanup')
        $t = @($cl | ForEach-Object { $_.Trim() })
        $s = [Array]::IndexOf($t, 'echo   ^> Emptying Recycle Bin...'); $e = [Array]::IndexOf($t, ':_clRbDone')
        Assert-True ($s -ge 0 -and $e -gt $s) 'test 191: the Recycle Bin step could not be sliced.'
        $slice = @($cl[$s..($e - 1)] | ForEach-Object { if ($_ -match '^\s*start "" /min /wait powershell') { 'if defined PT_ANS copy /y "!PT_ANS!" "!_rbres!" >nul' } else { $_ } })
        $cases = @($wk.Keys) + @('none')
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "TEMP=' + $dir + '"'))
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $drv += @($(if ($cases[$c] -eq 'none') { 'set "PT_ANS="' } else { 'set "PT_ANS=' + (Join-Path $dir ('ans_' + $cases[$c] + '.txt')) + '"' }), "echo [CASE#$c]", 'call :RB')
        }
        $drv += @('echo [END]', 'exit /b 0', ':RB') + $slice + @(':_clRbDone', 'goto :eof', ':Log', 'echo [LOG] %~1', 'goto :eof')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 191: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        Assert-True ($sec[0].Contains('[OK] Recycle Bin emptied.') -and -not $sec[0].Contains('[WARN]') -and $sec[0].Contains('[LOG] Recycle Bin items before=3 after=0')) ('A bin that is empty afterwards is [OK], whatever Clear-RecycleBin reported: ' + $sec[0])
        Assert-True ($sec[1].Contains('[OK] Recycle Bin was already empty.') -and -not $sec[1].Contains('[WARN]')) ('A bin that was empty must say so, not warn: ' + $sec[1])
        Assert-True ($sec[2].Contains('[WARN] Recycle Bin: 1 item(s) could not be deleted') -and -not $sec[2].Contains('[OK]')) ('Items left in the bin must be a [WARN] with their count: ' + $sec[2])
        Assert-True ($sec[3].Contains('[WARN] Recycle Bin: 2 item(s) could not be deleted') -and -not $sec[3].Contains('[OK]')) ('A Clear-RecycleBin that deleted nothing must be a [WARN]: ' + $sec[3])
        foreach ($i in 4, 5) { Assert-True ($sec[$i].Contains('[WARN] Recycle Bin: its item count could not be read') -and -not $sec[$i].Contains('[OK]') -and -not $sec[$i].Contains('item(s)')) ('An unread count must not read as emptied or as items left: ' + $sec[$i]) }
        Assert-True (@(Get-ChildItem -LiteralPath $dir -Filter 'pt_rb_*').Count -eq 0) 'The Recycle Bin answer file was left in TEMP.'
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 192. Remove stale system actions: reads first, judges each finding, fixes only what was asked, and the
#      boot-menu fixes stop when the store could not be saved (run).
Invoke-Test 'Remove stale system actions reads first, judges each finding, and fixes only what was asked (run)' {
    $cmd = Read-Lines $CmdPath
    $w = @($cmd | Where-Object { $_.Contains('PT_SA_BCD') -and $_ -match '^\s*start "" /min /wait powershell' })
    Assert-True ($w.Count -eq 1) 'test 192: the boot-menu worker could not be found.'
    Assert-True ($w[0] -notmatch '(?i)Set(Boolean|Integer|String|Object|Device)\w*Element|DeleteElement|DeleteObject|bcdedit|CreateStore|ImportStore|CreateObject') 'The boot-menu worker can change the store - it must only read.'
    foreach ($c in '0x24000001', '0x24000002', '0x25000004', '0x26000020', '0x23000003', '0x11000001', '0x12000002', '0x12000004', '0x21000001', '0x22000002') { Assert-True ($w[0].Contains($c)) ("The boot-menu worker no longer reads element $c (Microsoft's documented code).") }
    Assert-True ($w[0].Contains("@{Id='{9dea862c-5cdd-4e70-acc1-f32b344d4795}'}") -and $w[0].Contains("@{Id='{fa926493-6f1c-4193-a414-58f0b2456d1e}'}")) 'The worker no longer opens {bootmgr} and {current} by their well-known IDs.'
    $labels = @('StaleActions', '_saBoot', '_saBootOne', '_saKeep', '_saDirtyVol', '_saBcd', '_saBmRec', '_saOsRec', '_saBcdBackup', '_saBcdDel', '_saPending')
    $beq = 'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v BootExecute 2^>nul ^| findstr /I /C:"REG_MULTI_SZ"'
    $pend = [ordered]@{ 'reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" >nul 2>&1 &&' = 'if exist "!PT192!\cbs.txt"'
                        'reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" >nul 2>&1 &&' = 'if exist "!PT192!\wu.txt"'
                        'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v PendingFileRenameOperations >nul 2>&1 &&' = 'if exist "!PT192!\pfro.txt"' }
    $drvBody = @(); $subs = 0
    foreach ($lb in $labels) {
        $b = @(Get-BodyLines -Lines $cmd -Label $lb)
        Assert-True ($b.Count -gt 1) ":$lb is missing or did not unroll."
        $drvBody += ':' + $lb
        foreach ($s in $b) {
            $t = $s.Trim()
            if ($t -ieq 'cls' -or $t -ieq 'pause' -or $t -ieq 'call :Logo') { $drvBody += 'rem ' + $t; continue }
            if ($s.Contains('PT_SA_DIRTY') -and $t.StartsWith('start ""')) { $drvBody += 'if exist "!PT192!\dirty.txt" copy /y "!PT192!\dirty.txt" "!_sadf!" >nul'; $subs++; continue }
            if ($s.Contains('PT_SA_BCD') -and $t.StartsWith('start ""')) { $drvBody += 'if exist "!PT192!\bcd.txt" copy /y "!PT192!\bcd.txt" "!_sabf!" >nul'; $subs++; continue }
            if ($s.Contains($beq)) { $drvBody += $s.Replace($beq, 'type "!PT192!\be.txt"'); $subs++; continue }
            $x = $s
            foreach ($k in $pend.Keys) { if ($x.Contains($k)) { $x = $x.Replace($k, $pend[$k]); $subs++ } }
            $x = $x.Replace('if exist "%SystemRoot%\System32\!_safile!"', 'if exist "!PT192!\sys32\!_safile!"')
            $drvBody += ($x -replace '^(\s*)set /p "(\w+)=.*$', '$1set "$2=!PT_ANS!" & echo [PROMPT]')
        }
    }
    Assert-True ($subs -eq 6) ("test 192: expected 6 stub substitutions, made $subs - the screen changed shape.")
    Assert-True (@($drvBody | Where-Object { $_.Contains('%SystemRoot%\System32\!_safile!') -or $_ -match '^\s*set /p ' }).Count -eq 0 -and @($drvBody | Where-Object { $_.Contains('"!PT192!\sys32\!_safile!"') }).Count -eq 1) 'test 192: a real System32 check or a set /p survived the stubbing.'
    $stubs = @(':Run', 'echo [RUN] %~1', 'set "_runrc=!PT_RUNRC!"', 'goto :eof', ':RunVar', 'echo [RUNVAR] !%~1!', 'set "_runrc=!PT_EXPRC!"', 'goto :eof',
               ':SafeRegAdd', 'echo [ADD] %~1 / %~2 / %~3 / %~4', 'goto :eof', ':Summary', 'echo [SUM] %~1', 'goto :eof', ':RestartNote', 'echo [RESTART]', 'goto :eof',
               ':Utf8On', 'goto :eof', ':Utf8Off', 'goto :eof', ':MenuAdvanced', 'goto :eof', ':Log', 'goto :eof', ':LogVar', 'goto :eof')
    $vol = { param($s) "VOL|$s`r`nEND|ok`r`n" }
    $bcdOk = "BM|timeout|0`r`nBM|menu|0`r`nBM|default|{A}`r`nOS|{A}|ok|Windows 11`r`nEND|ok`r`n"
    $bcdDirty = "BM|timeout|30`r`nBM|menu|1`r`nBM|default|{A}`r`nOS|{A}|ok|Windows 11`r`nOS|{B}|novol|Windows 10 (old)`r`nOS|{C}|noload|Windows Setup`r`nOS|{D}|unknown|Linux (VHD)`r`nEND|ok`r`n"
    $bcdDefStale = "BM|timeout|30`r`nBM|menu|0`r`nBM|default|{B}`r`nOS|{A}|ok|Windows 11`r`nOS|{B}|novol|Old`r`nEND|ok`r`n"
    $bcdTwoOk = "BM|timeout|0`r`nBM|menu|0`r`nBM|default|{A}`r`nOS|{A}|ok|Windows 11`r`nOS|{F}|ok|Second`r`nEND|ok`r`n"
    $bcdOneStaleMenu = "BM|timeout|30`r`nBM|menu|1`r`nBM|default|{A}`r`nOS|{A}|ok|Windows 11`r`nOS|{B}|novol|Old`r`nEND|ok`r`n"
    $bcdSeqSetup = "BM|timeout|30`r`nBM|menu|0`r`nBM|default|{A}`r`nBM|seq|{H}`r`nOS|{A}|ok|Windows 11`r`nOS|{H}|setup|Windows 11 (Volume 3)`r`nEND|ok`r`n"
    $beDirty = 'autocheck autochk /p \??\D:\0autocheck autochk /k:E *\0autocheck sdnclean64.exe\0autocheck autochk *\0pdboot *'
    $addKey = '[ADD] HKLM\SYSTEM\CurrentControlSet\Control\Session Manager / BootExecute / REG_MULTI_SZ / '
    $act = '^\[(RUN|RUNVAR|ADD|SUM|RESTART)\]'
    # BootExecute data ($null = unreadable), dirty answer, boot-menu answer, pending markers, System32 files, elevated, answer,
    # export exit code, bcdedit exit code, actions (prefix match, in order), must say, must not say, prompts, _FAILS
    $cases = @(
        @('autocheck autochk *', (& $vol 'C:|0'), $bcdOk, @(), @(), 1, 'Y', '0', '0', @(),
          @('[OK] No disk check is queued', '[OK] No volume is marked dirty', '[OK] One entry and the text-mode menu is off', '[OK] Windows reports no pending restart', '[OK] Nothing stale among the actions this checks.'),
          @('[PROMPT]', '[STALE]', '[WARN]'), 0, '0'),
        @($beDirty, "VOL|C:|0`r`nVOL|D:|1`r`nEND|ok`r`n", $bcdDirty, @('cbs.txt', 'pfro.txt'), @('pdboot.exe'), 1, 'Y', '0', '0',
          @(($addKey + 'autocheck autochk /k:E *\0autocheck autochk *\0pdboot *'), '[RUNVAR] bcdedit /export "', '[RUN] bcdedit /delete {B}', '[RUN] bcdedit /delete {C}', '[RUN] bcdedit /deletevalue {bootmgr} displaybootmenu', '[RUN] bcdedit /timeout 0', '[SUM] Stale actions removed', '[RESTART]'),
          @('[STALE] A disk check is queued for the next start: autochk /p \??\D:', 'Excluded from the start-up check (chkntfs /x): autochk /k:E *', '[STALE] Boot-time program sdnclean64.exe: its file is gone', 'Boot-time program pdboot is installed', 'Volume D: is marked dirty',
            '[STALE] "Windows 10 (old)" {B} - its disk or partition is no longer here', '[STALE] "Windows Setup" {C} - no Windows loader', '"Linux (VHD)" {D} - starts from a device this check cannot judge. Kept', '[OK] "Windows 11" (default) {A}',
            'text-mode boot menu is switched on', '4 entries are offered for 30 s', 'servicing reports a restart is pending', 'File replacements wait for the next restart', '[BACKUP] Boot configuration', '2 entries stay in the menu'),
          @('[OK] Nothing stale', 'bcdedit /default', '[STALE] "Windows 11"', 'Windows Update reports a restart', '[OK] Windows reports no pending restart'), 4, '0'),
        @($beDirty, (& $vol 'C:|0'), $bcdDirty, @(), @('pdboot.exe'), 1, 'N', '0', '0', @(), @('[STALE] A disk check is queued', '[STALE] "Windows 10 (old)"'), @('[ADD]', '[RUN]', '[RUNVAR]', '[SUM]', '[BACKUP]'), 4, '0'),
        @('autocheck autochk /r \??\C:', (& $vol 'C:|1'), $bcdDefStale, @(), @(), 1, 'Y', '0', '0',
          @(($addKey + 'autocheck autochk *'), '[RUNVAR] bcdedit /export "', '[RUN] bcdedit /default {current}', '[RUN] bcdedit /delete {B}', '[SUM] Stale actions removed', '[RESTART]'),
          @('[STALE] The default entry "autocheck autochk *" is missing', '[STALE] A disk check is queued for the next start: autochk /r \??\C:', '"Old" (default) {B} - its disk or partition is no longer here', 'Volume C: is marked dirty'),
          @('timeout 0', 'displaybootmenu', '[OK] No disk check'), 2, '0'),
        @($beDirty, (& $vol 'C:|0'), $bcdDirty, @(), @('pdboot.exe'), 0, 'Y', '0', '0', @(),
          @('[STALE] A disk check is queued', '[i] Skipped: reading the boot configuration needs Administrator.', '[WARN] Not elevated - nothing can be removed from here'),
          @('[PROMPT]', '[ADD]', '[STALE] "Windows 10', '[OK] Nothing stale'), 0, '0'),
        @($null, "VOL|unreadable`r`n", "BM|unreadable`r`n", @(), @(), 1, 'Y', '0', '0', @(),
          @('[i] The start-up program list could not be read', '[i] Whether a volume is marked dirty could not be read', '[i] The boot configuration could not be read', '[OK] Nothing stale in what could be read'),
          @('[PROMPT]', '[STALE]', '[OK] Nothing stale among'), 0, '0'),
        @('autocheck autochk *', (& $vol 'C:|0'), $bcdOneStaleMenu, @(), @(), 1, 'Y', '1', '0', @('[RUNVAR] bcdedit /export "'),
          @('[FAIL] The boot configuration could not be saved first', '[STALE] "Old" {B}', 'text-mode boot menu is switched on'), @('[RUN]', '[SUM]', '[BACKUP]'), 1, '1'),
        @('autocheck autochk *\0autocheck autochk /k:D *', (& $vol 'C:|0'), $bcdTwoOk, @('wu.txt'), @(), 1, 'Y', '0', '0', @(),
          @('[i] Excluded from the start-up check (chkntfs /x): autochk /k:D *', '[OK] No disk check is queued', '[OK] 2 entries, timeout 0', 'Windows Update reports a restart is pending', '[OK] Nothing stale among the actions this checks.'),
          @('[PROMPT]', '[STALE]', '[OK] Windows reports no pending restart'), 0, '0'),
        @('autocheck autochk *', (& $vol 'C:|0'), $bcdOneStaleMenu, @(), @(), 1, 'Y', '0', '1',
          @('[RUNVAR] bcdedit /export "', '[RUN] bcdedit /delete {B}', '[RUN] bcdedit /deletevalue {bootmgr} displaybootmenu', '[SUM] Stale actions removed', '[RESTART]'),
          @('[BACKUP] Boot configuration'), @('timeout 0'), 2, '2'),
        @('autocheck autochk /q /v *\0autocheck autochk * /p \??\C:\0autocheck autochk /m:D', (& $vol 'C:|0'), $bcdSeqSetup, @(), @(), 1, 'Y', '0', '0',
          @(($addKey + 'autocheck autochk /q /v *'), '[RUNVAR] bcdedit /export "', '[RUN] bcdedit /delete {H}', '[RUN] bcdedit /deletevalue {bootmgr} bootsequence', '[SUM] Stale actions removed', '[RESTART]'),
          @('[STALE] A disk check is queued for the next start: autochk * /p \??\C:', '[STALE] A disk check is queued for the next start: autochk /m:D', '[STALE] "Windows 11 (Volume 3)" {H} - a leftover of a Windows upgrade', '[STALE] A one-time boot order is still set (bootsequence): the next start begins with {H}.'),
          @('[STALE] The default entry', 'autochk /q /v * - kept', 'timeout 0', 'displaybootmenu'), 3, '0'))
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt192_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion')
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $cd = Join-Path $dir "c$c"; [void](New-Item -ItemType Directory -Path (Join-Path $cd 'sys32'))
            [IO.File]::WriteAllText((Join-Path $cd 'be.txt'), $(if ($null -ne $x[0]) { "    BootExecute    REG_MULTI_SZ    " + $x[0] + "`r`n" } else { '' }))
            [IO.File]::WriteAllText((Join-Path $cd 'dirty.txt'), $x[1]); [IO.File]::WriteAllText((Join-Path $cd 'bcd.txt'), $x[2])
            foreach ($m in $x[3]) { [IO.File]::WriteAllText((Join-Path $cd $m), 'x') }
            foreach ($m in $x[4]) { [IO.File]::WriteAllText((Join-Path $cd "sys32\$m"), 'x') }
            $drv += @(('set "PT192=' + $cd + '"'), ('set "BACKUP_DIR=' + $cd + '"'), ('set "TEMP=' + $cd + '"'), ('set "_ELEV=' + $x[5] + '"'), ('set "PT_ANS=' + $x[6] + '"'), ('set "PT_EXPRC=' + $x[7] + '"'), ('set "PT_RUNRC=' + $x[8] + '"'), 'set "_FAILS=0"', "echo [CASE#$c]", 'call :StaleActions', 'echo [FAILS]!_FAILS!')
        }
        $drv += @('echo [END]', 'exit /b 0') + $drvBody + $stubs
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir -Allow '^(?i)((if .*?)?call :Run "[^"]*"|set "_sacmd=bcdedit /export "!_sabak!"")$'
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 192: the driver failed (exit {0}): {1}' -f $r.Exit, $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count $cases.Count
        for ($c = 0; $c -lt $cases.Count; $c++) {
            $x = $cases[$c]; $who = "case $c (elevated $($x[5]), answer $($x[6]), export exit $($x[7]), bcdedit exit $($x[8]))"
            $got = @($sec[$c] -split "`n" | Where-Object { $_ -match $act } | ForEach-Object { $_.TrimEnd() })
            $ok = $got.Count -eq @($x[9]).Count
            for ($i = 0; $ok -and $i -lt $got.Count; $i++) { $ok = $got[$i].StartsWith($x[9][$i]) }
            Assert-True $ok ('{0}: did [{1}], expected [{2}]' -f $who, ($got -join ' | '), (@($x[9]) -join ' | '))
            foreach ($m in $x[10]) { Assert-True ($sec[$c].Contains($m)) ('{0}: should say "{1}". Output: {2}' -f $who, $m, $sec[$c]) }
            foreach ($m in $x[11]) { Assert-True (-not $sec[$c].Contains($m)) ('{0}: should not say "{1}". Output: {2}' -f $who, $m, $sec[$c]) }
            Assert-True (([regex]::Matches($sec[$c], '\[PROMPT\]')).Count -eq $x[12]) ('{0}: asked {1} question(s), expected {2}. Output: {3}' -f $who, ([regex]::Matches($sec[$c], '\[PROMPT\]')).Count, $x[12], $sec[$c])
            Assert-True ($sec[$c].Contains('[FAILS]' + $x[13])) ('{0}: _FAILS must end at {1}. Output: {2}' -f $who, $x[13], $sec[$c])
            Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $dir "c$c") -Filter 'pt_sa*').Count -eq 0) ("$who left a worker answer file in TEMP.")
        }
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 193. The stale-actions workers, run with the store, the volumes and the registry faked: the boot-menu worker
#      judges each entry by its device and loader and never the running one, the dirty-bit worker tells
#      unreadable from clean, and a REG_MULTI_SZ backup is a hex(7) line that decodes back to the value (run).
Invoke-Test 'The stale-actions workers judge entries by device and loader, read dirty bits honestly, and back up a REG_MULTI_SZ as hex(7) (run)' {
    $cmd = Read-Lines $CmdPath
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt193_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $f = { param($n) Join-Path $dir $n }
        $read = { param($n) if (Test-Path -LiteralPath (& $f $n)) { @([IO.File]::ReadAllLines((& $f $n))) -join ';' } else { '<none>' } }
        # the dirty-bit worker
        $w = Get-WorkerPayload -Lines $cmd -Key 'PT_SA_DIRTY'
        $fakeVol = @'
function global:Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) @([pscustomobject]@{ DriveLetter = 'C:'; DirtyBitSet = $true }, [pscustomobject]@{ DriveLetter = $null; DirtyBitSet = $true }, [pscustomobject]@{ DriveLetter = 'D:'; DirtyBitSet = $null }) }
'@
        $r = Invoke-PsPayload ("`$env:PT_SA_DIRTY = '" + (& $f 'dirty.txt') + "'`n" + $fakeVol + "`n" + $w)
        Assert-True ((& $read 'dirty.txt') -ceq 'VOL|C:|1;VOL|D:|-;END|ok') ('The dirty-bit worker must report C: dirty, skip a volume without a letter and show an unknown flag as -: ' + (& $read 'dirty.txt') + ' ' + $r.Err)
        $r = Invoke-PsPayload ("`$env:PT_SA_DIRTY = '" + (& $f 'dirty2.txt') + "'`n" + $script:FakeDead + "`n" + $w)
        Assert-True ((& $read 'dirty2.txt') -ceq 'VOL|unreadable') ('A WMI that does not answer must read as unreadable, never as clean: ' + (& $read 'dirty2.txt') + ' ' + $r.Err)
        # the boot-menu worker: a scripted store around this PC's own system volume
        $nt = $null
        foreach ($n in 1..24) { if ([IO.Directory]::Exists("\\?\GLOBALROOT\Device\HarddiskVolume$n\Windows\System32")) { $nt = "\Device\HarddiskVolume$n"; break } }
        Assert-True ($null -ne $nt) 'test 193: no \Device\HarddiskVolumeN holding \Windows\System32 was reachable through GLOBALROOT, so the loader check cannot be exercised here.'
        $ldr = '\Windows\System32\winload.exe'; if ([IO.File]::Exists("\\?\GLOBALROOT$nt\Windows\System32\winload.efi")) { $ldr = '\Windows\System32\winload.efi' }
        Assert-True ([IO.File]::Exists("\\?\GLOBALROOT$nt$ldr")) 'test 193: no Windows loader on the system volume.'
        $w = Get-WorkerPayload -Lines $cmd -Key 'PT_SA_BCD'
        $fakeBcd = @'
function global:Invoke-CimMethod { [CmdletBinding()] param($Namespace, $ClassName, $MethodName, $Arguments, $InputObject)
    $S = $global:PT193
    if ($MethodName -eq 'OpenStore') { if ($S.dead) { throw 'no store (test)' }; return [pscustomobject]@{ ReturnValue = $true; Store = [pscustomobject]@{ kind = 'store' } } }
    if ($MethodName -eq 'OpenObject') { $id = [string]$Arguments.Id; if ($id -eq '{fa926493-6f1c-4193-a414-58f0b2456d1e}') { $id = $S.current }
        $o = $S.objects[$id]; if ($null -eq $o) { return [pscustomobject]@{ ReturnValue = $false; Object = $null } }
        return [pscustomobject]@{ ReturnValue = $true; Object = [pscustomobject]@{ Id = $id; el = $o } } }
    if ($MethodName -eq 'GetElement') { $k = '{0:x8}' -f [uint32]$Arguments.Type; $e = $InputObject.el[$k]; if ($null -eq $e) { throw 'element not set (test)' }
        return [pscustomobject]@{ ReturnValue = $true; Element = [pscustomobject]$e } }
    throw ('unexpected method ' + $MethodName)
}
function global:Part([string]$p) { [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'BcdDevicePartitionData' }; Path = $p } }
function global:Loc() { [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'BcdDeviceLocateElementData' } } }
'@
        $store = @"
`$global:PT193 = @{ dead = `$false; current = '{A}'; objects = @{
  '{9dea862c-5cdd-4e70-acc1-f32b344d4795}' = @{ '25000004' = @{ Integer = 30 }; '26000020' = @{ Boolean = `$true }; '23000003' = @{ Id = '{B}' }; '24000002' = @{ Ids = @('{B}', '{H}') }; '24000001' = @{ Ids = @('{A}', '{B}', '{C}', '{D}', '{E}', '{F}', '{G}', '{H}', '{I}') } };
  '{A}' = @{ '12000004' = @{ String = 'Windows 11' }; '11000001' = @{ Device = (Part '\Device\HarddiskVolume999') }; '12000002' = @{ String = '$ldr' } };
  '{B}' = @{ '12000004' = @{ String = 'Old' }; '11000001' = @{ Device = (Part '\Device\HarddiskVolume999') }; '12000002' = @{ String = '$ldr' } };
  '{C}' = @{ '12000004' = @{ String = 'Setup' }; '11000001' = @{ Device = (Part '$nt') }; '12000002' = @{ String = '\pt193\none\winload.efi' } };
  '{D}' = @{ '12000004' = @{ String = 'Linux' }; '11000001' = @{ Device = (Loc) }; '12000002' = @{ String = '$ldr' } };
  '{E}' = @{ '12000004' = @{ String = 'Windows.old' }; '11000001' = @{ Device = (Part '$nt') }; '12000002' = @{ String = '$ldr' }; '21000001' = @{ Device = (Part '$nt') }; '22000002' = @{ String = '\pt193nowhere' } };
  '{F}' = @{ '12000004' = @{ String = 'Win & "x" | y' }; '11000001' = @{ Device = (Part '$nt') }; '12000002' = @{ String = '$ldr' }; '21000001' = @{ Device = (Part '$nt') }; '22000002' = @{ String = '\Windows' } };
  '{G}' = @{ '12000004' = @{ String = 'No device' } };
  '{H}' = @{ '12000004' = @{ String = 'Windows 11 (Volume 3)' }; '11000001' = @{ Device = (Part '$nt') }; '12000002' = @{ String = '\`$WINDOWS.~BT\NewOS\WINDOWS\system32\winload.efi' }; '22000002' = @{ String = '\`$WINDOWS.~BT\NewOS\WINDOWS' } };
  '{I}' = @{ '12000004' = @{ String = 'Gone disk' }; '11000001' = @{ Device = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'BcdDeviceUnknownData' } } }; '12000002' = @{ String = '$ldr' } } } }
"@
        $dead = '$global:PT193 = @{ dead = $true; current = ''{A}''; objects = @{} }'
        $bare = '$global:PT193 = @{ dead = $false; current = ''{A}''; objects = @{ ''{9dea862c-5cdd-4e70-acc1-f32b344d4795}'' = @{ ''24000001'' = @{ Ids = @() } } } }'
        foreach ($k in @(@('bcd1.txt', $store, 'BM|timeout|30;BM|menu|1;BM|default|{B};BM|seq|{B};{H};OS|{A}|ok|Windows 11;OS|{B}|novol|Old;OS|{C}|noload|Setup;OS|{D}|unknown|Linux;OS|{E}|nowin|Windows.old;OS|{F}|ok|Win ? ?x? ? y;OS|{G}|unknown|No device;OS|{H}|setup|Windows 11 (Volume 3);OS|{I}|novol|Gone disk;END|ok'),
                         @('bcd2.txt', $dead, 'BM|unreadable'), @('bcd3.txt', $bare, 'BM|timeout|-;BM|menu|-;BM|default|-;BM|seq|-;END|ok'))) {
            $r = Invoke-PsPayload ("`$env:PT_SA_BCD = '" + (& $f $k[0]) + "'`n" + $fakeBcd + "`n" + $k[1] + "`n" + $w)
            Assert-True ((& $read $k[0]) -ceq $k[2]) ('The boot-menu worker must answer "{0}": {1} {2}' -f $k[2], (& $read $k[0]), $r.Err)
        }
        # the REG_MULTI_SZ backup worker: the value read from the registry (faked), written as hex(7)
        $w = Get-WorkerPayload -Lines $cmd -Key 'PT_BK_FILE'
        $fakeReg = @'
function global:Get-ItemProperty { [CmdletBinding()] param($LiteralPath, $Name) $global:PT193Q = [string]$LiteralPath; $o = New-Object psobject; $o | Add-Member -MemberType NoteProperty -Name $Name -Value @('autocheck autochk /p \??\C:', '', ('caf' + [char]0xE9)); $o }
'@
        $bk = & $f 'bk.reg'; [IO.File]::WriteAllText($bk, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager]`r`n")
        $r = Invoke-PsPayload ("`$env:PT_BK_KEY = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager'; `$env:PT_BK_VAL = 'BootExecute'; `$env:PT_BK_FILE = '" + $bk + "'`n" + $fakeReg + "`n" + $w + "`n[Console]::Out.Write('KEY=' + `$global:PT193Q)")
        $txt = @([IO.File]::ReadAllLines($bk))
        Assert-True ($txt.Count -ge 5 -and $txt[3].StartsWith('"BootExecute"=hex(7):') -and $txt[3].EndsWith('\') -and $txt[4].StartsWith('  ')) ('The REG_MULTI_SZ backup must be a wrapped hex(7) value line: ' + ($txt -join ' / ') + ' ' + $r.Err)
        $hex = (($txt[3..($txt.Count - 1)] -join '') -replace '\\', '' -replace '\s', '') -replace '^"BootExecute"=hex\(7\):', ''
        $bytes = [byte[]]@($hex -split ',' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
        $dec = @(([Text.Encoding]::Unicode.GetString($bytes)) -split [char]0)
        Assert-True ($dec.Count -eq 5 -and $dec[0] -ceq 'autocheck autochk /p \??\C:' -and $dec[1] -ceq '' -and $dec[2] -ceq ('caf' + [char]0xE9) -and $dec[3] -ceq '' -and $dec[4] -ceq '') ('The hex(7) must decode to the three strings, an empty and a non-ASCII one included, with the double terminator: ' + ($dec -join '|'))
        Assert-True (($r.Out -join '').Contains('KEY=Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager')) ('The backup worker must read the value under the full hive name: ' + $r.Out)
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 194. The VM probe reads the firmware strings from the registry and the question is interactive only.
Invoke-Test 'A virtual machine is recognised from the firmware strings, asked about interactively and never on the command line (run)' {
    $cmd = Read-Lines $CmdPath
    $b = Get-RoutineBody -Lines $cmd -Label 'VmDetect'
    Assert-True ($b.Count -gt 0) ':VmDetect is missing.'
    $code = @($b | Where-Object { $_.Trim() -notmatch '^(?i)(echo|rem)\b' })
    $text = $code -join "`n"
    Assert-True ($text -match 'reg query "HKLM\\HARDWARE\\DESCRIPTION\\System\\BIOS"') ':VmDetect no longer reads the firmware strings from the registry.'
    Assert-True ($text -notmatch '(?i)powershell|wmic|Get-CimInstance|systeminfo') ':VmDetect went to WMI, PowerShell or systeminfo - the registry read is the point: no startup cost, no provider, no localisation.'
    foreach ($w in @('QEMU', 'VMware', 'VirtualBox', '"Virtual Machine"', '"HVM domU"', 'Parallels')) { Assert-True ($text.Contains($w)) (':VmDetect lost the platform word ' + $w) }
    Assert-True ($text -match '(?i)set "VM=unknown"' -and $text -match '(?i)set "VM=no"') ':VmDetect must start from unknown and reach no only after a real read.'
    Assert-True ($text -notmatch '(?i)for /f[^\n]*_vmf') ':VmDetect reads the dump through a for /f - a value with an odd character would then be parsed (regression).'
    # placement: the probe before the start log line that records it; the question after the command-line
    # branches (an unattended run is never asked) and before :MainMenu; the question ends the script on anything but Y
    $iCli = -1; $iMenu = -1; $iAsk = -1; $iLog = -1; $iCall = -1
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($iCli -lt 0 -and $cmd[$i] -match '^if defined _CLIANY goto CliRun') { $iCli = $i }
        if ($iMenu -lt 0 -and $cmd[$i] -match '^:MainMenu$') { $iMenu = $i }
        if ($iAsk -lt 0 -and $cmd[$i] -match '^if not "!VM!"=="no" if not "!VM!"=="unknown" \($') { $iAsk = $i }
        if ($iLog -lt 0 -and $cmd[$i] -match '^call :Log "PerfTweaks start') { $iLog = $i }
        if ($iCall -lt 0 -and $cmd[$i] -match '^call :VmDetect$') { $iCall = $i }
    }
    Assert-True ($iCli -ge 0 -and $iMenu -ge 0 -and $iAsk -ge 0 -and $iLog -ge 0 -and $iCall -ge 0) 'The VM question, its probe call, the command-line branch, the start log line or :MainMenu could not be found.'
    Assert-True ($iCall -lt $iLog) ':VmDetect must run before the start log line that records it.'
    Assert-True ($cmd[$iLog] -match 'vm=%VM%') 'The start log line no longer records vm=.'
    Assert-True ($iCli -lt $iAsk -and $iAsk -lt $iMenu) 'The VM question must sit after the command-line branches and before :MainMenu.'
    $blk = $cmd[$iAsk..$iMenu]
    Assert-True ((Test-BlockExit -Lines $blk -Open '^if not "!VM!"=="no" if not "!VM!"=="unknown" \($' -Exit '^if /i not "!_vmq!"=="Y" exit /b$') -eq 1) 'The VM question no longer ends the script on anything but Y.'
    Assert-True (($blk -join "`n") -match 'set /p "_vmq=Proceed anyway\? \(Y/N\): "') 'The VM question lost its prompt.'
    Assert-True (($blk -join "`n") -match '(?i)It appears that you.re currently using a virtual machine') 'The VM question no longer says what it found.'
    # run :VmDetect on firmware dumps, the registry read answered from a file; the last read fails outright
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt194_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $k = "HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\BIOS`r`n"
        $dumps = @(
            @('qemu',   ($k + "    SystemManufacturer    REG_SZ    QEMU`r`n    SystemProductName    REG_SZ    Standard PC (Q35 + ICH9, 2009)`r`n    BIOSVendor    REG_SZ    SeaBIOS`r`n"), 'QEMU'),
            @('vmware', ($k + "    SystemManufacturer    REG_SZ    VMware, Inc.`r`n    SystemProductName    REG_SZ    VMware Virtual Platform`r`n    BIOSVendor    REG_SZ    Phoenix Technologies LTD`r`n"), 'VMware'),
            @('hyperv', ($k + "    SystemManufacturer    REG_SZ    Microsoft Corporation`r`n    SystemProductName    REG_SZ    Virtual Machine`r`n    BIOSVendor    REG_SZ    Microsoft Corporation`r`n"), 'Hyper-V'),
            @('vbox',   ($k + "    SystemManufacturer    REG_SZ    innotek GmbH`r`n    SystemProductName    REG_SZ    VirtualBox`r`n    BIOSVendor    REG_SZ    innotek GmbH`r`n"), 'VirtualBox'),
            @('xen',    ($k + "    SystemManufacturer    REG_SZ    Xen`r`n    SystemProductName    REG_SZ    HVM domU`r`n    BIOSVendor    REG_SZ    Xen`r`n"), 'Xen'),
            @('lenovo', ($k + "    SystemManufacturer    REG_SZ    LENOVO`r`n    SystemProductName    REG_SZ    20XYZ Xenon Edition`r`n    SystemVersion    REG_SZ    ThinkPad P1 Gen 4i Xeon W-11955M`r`n    BIOSVendor    REG_SZ    LENOVO`r`n    BaseBoardProduct    REG_SZ    20XYZ`r`n"), 'no'),
            @('empty',  '', 'unknown')
        )
        $body = @($b | ForEach-Object { $_ -replace '^reg query "HKLM\\HARDWARE\\DESCRIPTION\\System\\BIOS" >"!_vmf!" 2>nul$', 'copy /y "!PT194!" "!_vmf!" >nul 2>&1' })
        Assert-True (@($body | Where-Object { $_ -match '^copy /y "!PT194!"' }).Count -eq 1) 'test 194: the registry read line of :VmDetect is not the one line the test replaces.'
        $drv = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "TEMP=' + $dir + '"'))
        for ($c = 0; $c -lt $dumps.Count; $c++) {
            $f = Join-Path $dir ($dumps[$c][0] + '.txt'); [IO.File]::WriteAllText($f, $dumps[$c][1], [Text.Encoding]::ASCII)
            $drv += @(('set "PT194=' + $f + '"'), "echo [CASE#$c]", 'call :VmDetect', 'echo VM=!VM!')
        }
        $drv += @(('set "PT194=' + (Join-Path $dir 'missing.txt') + '"'), ('echo [CASE#' + $dumps.Count + ']'), 'call :VmDetect', 'echo VM=!VM!')
        $drv += @('echo [END]', 'exit /b 0', ':VmDetect') + $body
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 194: the driver failed: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count ($dumps.Count + 1)
        for ($c = 0; $c -lt $dumps.Count; $c++) { Assert-True ($sec[$c] -match ('(?m)^VM=' + [regex]::Escape($dumps[$c][2]) + '$')) ('test 194: the ' + $dumps[$c][0] + ' dump must give VM=' + $dumps[$c][2] + ', got: ' + $sec[$c]) }
        Assert-True ($sec[$dumps.Count] -match '(?m)^VM=unknown$') ('test 194: a registry read that fails must give VM=unknown, never no: ' + $sec[$dumps.Count])
        Assert-True (@(Get-ChildItem -Path $dir -Filter 'pt_vm_*.txt').Count -eq 0) 'test 194: :VmDetect left its dump file behind.'
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 195. System32 first on the script's own PATH, before anything runs.
Invoke-Test 'System32 leads the script''s own PATH before any command runs, and the line prepends without truncating (run)' {
    $cmd = Read-Lines $CmdPath
    $line = 'set "PATH=%SystemRoot%\System32;%PATH%"'
    $iPath = -1; $iDe = -1; $iProbe = -1; $iFind = -1
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        $t = $cmd[$i].Trim()
        if ($iPath -lt 0 -and $t -ceq $line) { $iPath = $i }
        if ($iDe -lt 0 -and $t -match '^(?i)setlocal EnableDelayedExpansion$') { $iDe = $i }
        if ($iProbe -lt 0 -and $t -match '^net session >nul 2>&1 \|\| fltmc') { $iProbe = $i }
        if ($iFind -lt 0 -and $t -notmatch '^(?i)rem\b' -and $t -match '(?i)\bfind /c /v ""') { $iFind = $i }
    }
    Assert-True ($iPath -ge 0) 'The PATH line (set "PATH=%SystemRoot%\System32;%PATH%") is gone: a GNU find ahead of System32 walks the C: drive on "find /c /v"".'
    Assert-True ($iDe -ge 0 -and $iProbe -ge 0 -and $iFind -ge 0) 'test 195: the delayed-expansion switch, the elevation probe or the first find /c /v line could not be found.'
    Assert-True ($iPath -lt $iDe) 'The PATH line must run while delayed expansion is still off (a "!" in PATH would otherwise be eaten).'
    Assert-True ($iPath -lt $iProbe -and $iPath -lt $iFind) 'The PATH line must come before the elevation probe and before the first find /c /v.'
    Assert-True (@($cmd | Where-Object { $_ -match '(?i)^\s*setx\b' }).Count -eq 0) 'A setx appeared: PATH must change for this process only (setx truncates PATH and flattens REG_EXPAND_SZ).'
    # run the line itself: with SystemRoot and PATH set to known values, PATH comes out prepended and whole
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pt195_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $long = ((1..40) | ForEach-Object { 'C:\dir' + $_ }) -join ';'
        $drv = @('@echo off', 'setlocal DisableDelayedExpansion', 'set "SystemRoot=C:\Fake"', ('set "PATH=' + $long + '"'), 'echo [CASE#0]', $line, 'echo PATH=%PATH%', 'echo [END]', 'exit /b 0')
        $r = Invoke-CmdDriver -Lines $drv -Dir $dir
        Assert-True ($r.Exit -eq 0 -and $r.Err -eq '') ('test 195: the driver failed: ' + $r.Err)
        $sec = Get-CaseSections -Out $r.Out -Count 1
        Assert-True ($sec[0] -ceq ('PATH=C:\Fake\System32;' + $long)) ('test 195: the PATH line must prepend %SystemRoot%\System32 and keep the rest whole, got: ' + $sec[0])
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
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

