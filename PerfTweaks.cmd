@echo off
echo off
rem  Capture the script's location before any shift renumbers argument zero, with delayed
rem  expansion off so an exclamation mark survives. Later read both only with delayed expansion,
rem  and pass values built from them in a variable, never as a call argument.
setlocal DisableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
set "_SELFPATH=%~f0"
rem  Backup folder too, while delayed expansion is off. Resolves OneDrive-redirected Documents.
set "DOCS=%USERPROFILE%\Documents"
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Personal 2^>nul ^| findstr /I "Personal"') do set "DOCS=%%b"
rem  call set expands a registry value stored unexpanded. Only such a value goes through it:
rem  call re-parses its arguments and would mangle a percent sign or caret in a real path.
if "%DOCS:~0,1%"=="%%" call set "DOCS=%DOCS%"
if "%DOCS:~-1%"==" " set "DOCS=%DOCS:~0,-1%"
set "BACKUP_DIR=%DOCS%\PerfTweaks_Backups"
setlocal EnableDelayedExpansion
cd /d "!SCRIPT_DIR!" 2>nul
color 0D
title Sincript - Windows 10/11 Optimizer
rem =====================================================================================
rem  PerfTweaks - a curated, reversible Windows 10/11 optimizer with a category menu.
rem  Every registry change is backed up first as a .reg file. Backups and status makes a
rem  restore point and a full registry export - do that first.
rem =====================================================================================
rem ---------- Command line ----------
rem  Parsed before the elevation probe: a command-line run never self-elevates, so the caller
rem  gets the exit code of the work. Values are read late, so special characters stay data.
set "_CLIPRESET=" & set "_CLIDNS=" & set "_CLINORP=" & set "_CLIHELP=" & set "_CLIBAD=" & set "_CLIPLAN="
set "_RELAUNCHED=" & set "_CLIANY="

:_argLoop
if "%~1"=="" goto _argDone
set "_a=%~1"
shift
rem  /elevated is the relaunch marker, not a command-line request, so it does not set _CLIANY.
if /i "!_a!"=="/elevated"   set "_RELAUNCHED=1" & goto _argLoop
rem  Any other argument means command-line mode, even an empty option: :CliRun then reports it.
set "_CLIANY=1"
if /i "!_a!"=="/?"          set "_CLIHELP=1" & goto _argLoop
if /i "!_a!"=="/help"       set "_CLIHELP=1" & goto _argLoop
if /i "!_a!"=="/norestore"  set "_CLINORP=1" & goto _argLoop
if /i "!_a:~0,8!"=="/preset:" goto _argPreset
if /i "!_a:~0,5!"=="/dns:"    goto _argDns
if /i "!_a:~0,6!"=="/plan:"   goto _argPlan
set "_CLIBAD=!_a!"
goto _argLoop
rem  One label per value: chaining the empty check and goto on one line makes the goto conditional.
:_argPreset
set "_CLIPRESET=!_a:~8!"
if not defined _CLIPRESET set "_CLIBAD=!_a!"
goto _argLoop

:_argDns
set "_CLIDNS=!_a:~5!"
if not defined _CLIDNS set "_CLIBAD=!_a!"
goto _argLoop

:_argPlan
set "_CLIPLAN=!_a:~6!"
if not defined _CLIPLAN set "_CLIBAD=!_a!"
goto _argLoop

:_argDone
rem ---------- Self-elevate to Administrator (robust, cannot loop) ----------
rem  net session needs the Server service, so fall back to fltmc, then a service-free reg query.
set "_ELEV="
net session >nul 2>&1 || fltmc >nul 2>&1 || reg query "HKU\S-1-5-19" >nul 2>&1
if not errorlevel 1 ( set "_ELEV=1" & goto AdminOK )
rem  A command-line run never relaunches: :CliRun reports why and returns a usable exit code.
rem  Test _CLIANY, not _CLIPRESET: every option, even a typo, is a command-line request.
if defined _CLIANY ( set "_ELEV=0" & goto AdminOK )
if defined _CLIHELP ( set "_ELEV=0" & goto AdminOK )
if defined _RELAUNCHED goto AdminWarn
rem  The relaunch goes through cmd /C, which re-parses an ampersand, caret or at sign in the path
rem  and the new window closes silently. Carets cannot be tested for, so only two are checked.
set "_spbad="
if not "!_SELFPATH:&=!"=="!_SELFPATH!" set "_spbad=1"
if not "!_SELFPATH:@=!"=="!_SELFPATH!" set "_spbad=1"
if defined _spbad (
    echo.
    echo [WARN] This script's path contains a character Windows cannot pass through an
    echo        elevated relaunch ^(^& ^^ or @^):
    echo          !_SELFPATH!
    echo        The new window would close immediately with no message. Instead, right-click
    echo        PerfTweaks.cmd and choose "Run as administrator", or move the script to a
    echo        folder without those characters.
    call :Log "ABORT: self-elevation refused - script path contains & or @"
    goto AdminWarn
)
echo Requesting Administrator privileges...
rem  Use _SELFPATH: after the argument loop's shift, argument zero no longer names this script.
set "PT_SELF=!_SELFPATH!"
rem  -ErrorAction Stop plus try/catch: a declined UAC prompt or absent PowerShell exits nonzero.
powershell -NoProfile -Command "try{ Start-Process -FilePath $env:PT_SELF -ArgumentList '/elevated' -Verb RunAs -WorkingDirectory (Split-Path -Parent $env:PT_SELF) -ErrorAction Stop }catch{ exit 1 }" >nul 2>&1
if not errorlevel 1 exit /b
set "PT_SELF="
echo.
echo [WARN] The elevation prompt did not go through - either it was declined, or PowerShell
echo        is blocked / unavailable on this machine.
goto AdminWarn

:AdminWarn
rem  Reached when a relaunch left us unelevated or could not start. Sets _ELEV=0 so results are
rem  reported honestly, and asks before continuing in limited mode.
set "_ELEV=0"
echo.
echo [WARN] Not running as Administrator. HKLM / service / boot / hosts changes WILL fail;
echo        only per-user (HKCU) tweaks and the read-only status screens can work in this mode.
echo        For the full toolset, close this window and use "Run as administrator".
echo.
set "_lc="
set /p "_lc=Continue anyway in limited (per-user only) mode? (Y/N): "
if /i not "!_lc!"=="Y" exit /b

:AdminOK
if not defined _ELEV set "_ELEV=1"
rem  Use SCRIPT_DIR: argument zero no longer names this script after the argument loop's shift.
cd /d "!SCRIPT_DIR!" 2>nul
rem ---------- Globals ----------
rem  _FAILS counts failed registry writes since the last reset. :SafeRegAdd and :SafeRegDelete
rem  bump it across their endlocal; :Summary reads it to report the real outcome.
set "_FAILS=0"
rem  LOGFILE is built from BACKUP_DIR by a late read, which keeps special characters intact.
set "LOGFILE=!BACKUP_DIR!\PerfTweaks_%RANDOM%.log"
if not exist "!BACKUP_DIR!" md "!BACKUP_DIR!" >nul 2>&1
rem  Verify the folder: :SafeRegAdd refuses any tweak whose .reg backup did not land. Use delayed
rem  expansion in the block: a closing paren in the path would end the if-block early.
set "_BAKOK=1"
if not exist "!BACKUP_DIR!\" set "_BAKOK=0"
if "%_BAKOK%"=="0" (
    echo.
    echo [WARN] The backup folder could not be created:
    echo          !BACKUP_DIR!
    echo        Every registry tweak refuses to run without a per-value undo file, so nearly
    echo        all actions will report [FAIL] until this is fixed, and no log can be written.
    echo        Usual causes: Controlled Folder Access, a read-only or offline OneDrive
    echo        Documents folder, or a full disk.
    echo.
)
rem  Ask only interactively: unattended, set /p returns at once; :CliRun reports this instead.
if "%_BAKOK%"=="0" if not defined _CLIANY (
    set "_lb="
    rem  No caret escaping: the double quotes already protect the parens inside this block.
    set /p "_lb=Continue anyway (status screens and file cleanup still work)? (Y/N): "
    if /i not "!_lb!"=="Y" exit /b
)
rem ---------- OS build / Win11 / GPU detection ----------
set "WIN_BUILD="
for /f "tokens=3" %%B in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| findstr /I "CurrentBuildNumber"') do set "WIN_BUILD=%%B"
set "IS_WIN11=0"
if defined WIN_BUILD if !WIN_BUILD! GEQ 22000 set "IS_WIN11=1"
rem  NVIDIA and AMD are tracked separately, since one machine can have both. GPU is one word for
rem  the header and log; actions branch on GPU_NV and GPU_AMD. One recursive reg query, read twice.
set "GPU=unknown"
set "GPU_NV=" & set "GPU_AMD="
set "_gpuf=!TEMP!\pt_gpu_%RANDOM%%RANDOM%.txt"
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" /s /v DriverDesc >"!_gpuf!" 2>nul
if exist "!_gpuf!" findstr /I "nvidia" "!_gpuf!" >nul && set "GPU_NV=1"
if exist "!_gpuf!" findstr /I "radeon" "!_gpuf!" >nul && set "GPU_AMD=1"
del "!_gpuf!" >nul 2>&1
if defined GPU_NV set "GPU=nvidia"
if defined GPU_AMD set "GPU=amd"
if defined GPU_NV if defined GPU_AMD set "GPU=nvidia+amd"
rem ---------- CPU vendor ----------
rem  VendorIdentifier is filled in by Windows at boot: GenuineIntel or AuthenticAMD.
set "CPU=unknown"
set "_cpuv="
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0" /v VendorIdentifier 2^>nul ^| findstr /I "VendorIdentifier"') do set "_cpuv=%%B"
if defined _cpuv set "CPU=other"
if /i "!_cpuv!"=="GenuineIntel" set "CPU=intel"
if /i "!_cpuv!"=="AuthenticAMD" set "CPU=amd"
rem ---------- Machine class (laptop / desktop / unknown) ----------
rem  CmBatt Enum Count is nonzero exactly when an internal battery is present. Warning-only use.
set "MACHINE=unknown"
set "_bat="
for /f "tokens=3" %%M in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\CmBatt\Enum" /v Count 2^>nul ^| findstr /I "Count"') do set "_bat=%%M"
if not defined _bat ( reg query "HKLM\SYSTEM\CurrentControlSet\Services\CmBatt" >nul 2>&1 && set "_bat=0x0" )
if "%_bat%"=="0x0" set "MACHINE=desktop"
if defined _bat if not "%_bat%"=="0x0" set "MACHINE=laptop"
call :Log "PerfTweaks start - build %WIN_BUILD% win11=%IS_WIN11% cpu=%CPU% gpu=%GPU% machine=%MACHINE%"
rem  Command-line paths branch here, after the probes they need. Both exit; neither returns.
if defined _CLIHELP goto CliHelp
if defined _CLIANY goto CliRun
rem  Resize only here: mode con clears the scrollback, which a command-line run must not do.
mode con: cols=100 lines=36 >nul 2>&1
rem =====================================================================================
rem  MAIN MENU
rem =====================================================================================
:MainMenu
cls
call :Logo
echo ==========================================  MAIN MENU  ===========================================
rem  Cached after the first call, so this is one probe per session, not per menu draw.
call :DetectSysDisk
call :DetectUndervolt
rem  Non-blocking: starts a background worker once; later draws only check for its answer.
call :DetectRefresh
set "_uvhdr=none found"
if defined UVTOOL set "_uvhdr=!UVTOOL!"
echo   Build %WIN_BUILD%   Win11=%IS_WIN11%   CPU=%CPU%   GPU=%GPU%   Disk=%SYSDISK%   Refresh=!REFRESH!
echo   Machine=%MACHINE%   Undervolt tool: !_uvhdr!
echo --------------------------------------------------------------------------------------------------
echo     1.  Cleanup ^& repair        (temp/logs, DISM/SFC, Windows Update, Store, WinSxS)
echo     2.  Performance tweaks       (GameDVR off, priorities, snappier UI)
echo     3.  Privacy ^& telemetry      (telemetry, ads, Cortana, location off)
echo     4.  Power plan               (high-performance, no sleep)
echo     5.  Network ^& DNS            (TCP tweaks, DNS, reset stack)
echo     6.  Apps ^& files            (OpenAsar, boot.config, hosts, SteamLight, startup)
echo     7.  Advanced                 (at your own risk - mitigations, timers, IPv6, GPU, WU drivers)
echo     8.  Backups ^& status        (restore point, registry backup, current status)
echo --------------------------------------------------------------------------------------------------
echo     9.  Apply recommended safe set  (one click: 1-5 core tweaks, no prompts)
echo    10.  Presets (light / moderate / heavy / custom)  + restore preset backup
echo    11.  What was excluded (info)
echo    12.  System tools               (PATH editor, file locks, crash ^& hardware-error report)
echo     0.  Exit
echo ==================================================================================================

:MainMenu_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MainMenu_ask
if "!sel!"=="1" goto MenuCleanup
if "!sel!"=="2" goto Performance
if "!sel!"=="3" goto Privacy
if "!sel!"=="4" goto Power
if "!sel!"=="5" goto MenuNetwork
if "!sel!"=="6" goto MenuApps
if "!sel!"=="7" goto MenuAdvanced
if "!sel!"=="8" goto MenuBackups
if "!sel!"=="9" goto ApplyRecommended
if "!sel!"=="10" goto MenuPresets
if "!sel!"=="11" goto Excluded
if "!sel!"=="12" goto MenuTools
if "!sel!"=="0" goto ExitScript
goto MainMenu

:ExitScript
cls
call :Logo
rem  Only name files that exist.
if exist "!LOGFILE!" (echo   Log saved to: !LOGFILE!) else (echo   No log file could be written this session.)
if exist "!BACKUP_DIR!\" (echo   Backups in:   !BACKUP_DIR!) else (echo   No backup folder could be created.)
rem  Remove a refresh-rate answer and its marker files still left in TEMP.
if defined _hzres del "!_hzres!" "!_hzres!.run" "!_hzres!.tmp" >nul 2>&1
if defined _hzold del "!_hzold!" "!_hzold!.run" "!_hzold!.tmp" >nul 2>&1
echo.
echo   Bye.
rem  Silence stderr too: timeout refuses redirected input and prints an error there.
timeout /t 2 >nul 2>&1
exit /b
rem =====================================================================================
rem  SUBMENU: Cleanup & repair
rem =====================================================================================
:MenuCleanup
cls
call :Logo
echo =======================================  CLEANUP ^& REPAIR  =======================================
echo     1.  Clean temp / logs / caches (+ optional: shaders, Recycle Bin, Event Viewer, Disk Cleanup)
echo     2.  DISM + SFC system integrity
echo     3.  Reset Windows Update components
echo     4.  Re-register Microsoft Store / apps
echo     5.  Compact WinSxS (free disk space)
echo     0.  Back
echo ==================================================================================================

:MenuCleanup_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuCleanup_ask
if "!sel!"=="1" goto Cleanup
if "!sel!"=="2" goto SfcDism
if "!sel!"=="3" goto WUReset
if "!sel!"=="4" goto StoreRepair
if "!sel!"=="5" goto CompactWinSxS
if "!sel!"=="0" goto MainMenu
goto MenuCleanup
rem =====================================================================================
rem  SUBMENU: Network & DNS
rem =====================================================================================
:MenuNetwork
cls
call :Logo
echo ========================================  NETWORK ^& DNS  =========================================
echo     1.  Apply TCP tweaks        (autotuning/heuristics/RSS/RSC, optional low-latency)
echo     2.  Set DNS                 (Cloudflare / Google / Quad9 / automatic)
echo     3.  Reset network stack     (winsock / ip / dns)
echo     4.  Flush DNS cache          (just the resolver cache - no stack changes)
echo     0.  Back
echo ==================================================================================================

:MenuNetwork_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuNetwork_ask
if "!sel!"=="1" goto NetworkApply
if "!sel!"=="2" goto MenuDns
if "!sel!"=="3" goto NetReset
if "!sel!"=="4" goto FlushDns
if "!sel!"=="0" goto MainMenu
goto MenuNetwork

:MenuDns
cls
call :Logo
echo ===========================================  SET DNS  ============================================
echo  Changes every PHYSICAL adapter, connected or not - VPN and other virtual adapters are
echo  left alone - and flushes the DNS cache. Options 1-3 set IPv4 + IPv6; option 5 IPv4 only.
echo  Undo is option 4, and it goes back to automatic ^(DHCP^): a server you typed in yourself -
echo  your router, a Pi-hole - is NOT saved by sincript. Write it down from the list below first.
call :ShowCurrentDns
echo     1.  Cloudflare   1.1.1.1 / 1.0.0.1
echo     2.  Google       8.8.8.8 / 8.8.4.4
echo     3.  Quad9        9.9.9.9 / 149.112.112.112   (blocks known-malicious domains)
echo     4.  Revert to automatic (DHCP)
echo     5.  Custom server            (enter your own resolver)
echo     0.  Back
echo ==================================================================================================

:MenuDns_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuDns_ask
if "!sel!"=="1" goto DnsCloudflare
if "!sel!"=="2" goto DnsGoogle
if "!sel!"=="3" goto DnsQuad9
if "!sel!"=="4" goto DnsAuto
if "!sel!"=="5" goto DnsCustom
if "!sel!"=="0" goto MenuNetwork
goto MenuDns
rem =====================================================================================
rem  SUBMENU: Apps & files
rem =====================================================================================
:MenuApps
cls
call :Logo
echo =========================================  APPS ^& FILES  =========================================
echo     1.  Install OpenAsar into Discord
echo     2.  Place Unity boot.config into a game folder
echo     3.  Apply custom hosts file (ad/telemetry blocklist)
echo     4.  Restore / reset hosts
echo     5.  Install SteamLight (lightweight Steam launcher + desktop shortcut)
echo     6.  Apply timer resolution (SetTimerResolution autostart)
echo     7.  Remove timer resolution
echo     8.  Remove built-in apps (debloat)
echo     9.  Manage startup programs (enable / disable, reversible)
echo     0.  Back
echo ==================================================================================================

:MenuApps_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuApps_ask
if "!sel!"=="1" goto OpenAsar
if "!sel!"=="2" goto UnityBoot
if "!sel!"=="3" goto ApplyHosts
if "!sel!"=="4" goto RestoreHosts
if "!sel!"=="5" goto SteamLight
if "!sel!"=="6" goto TimerResApply
if "!sel!"=="7" goto TimerResRemove
if "!sel!"=="8" goto Debloat
if "!sel!"=="9" goto StartupMgr
if "!sel!"=="0" goto MainMenu
goto MenuApps
rem =====================================================================================
rem  SUBMENU: Advanced
rem =====================================================================================
:MenuAdvanced
cls
call :Logo
echo ================================  ADVANCED  -  AT YOUR OWN RISK  =================================
echo  Never part of "Apply recommended". Most need a reboot. Not every item has a full undo:
echo  BCD timers only go back to Windows defaults, and memory compression has no in-app undo.
echo     1.  Disable CPU mitigations        (faster, LESS secure)
echo     2.  Re-enable CPU mitigations      (secure default)
echo     3.  BCDEdit timer tweaks
echo     4.  Revert BCDEdit timer tweaks
echo     5.  Experimental NVMe driver flags
echo     6.  Disable IPv6 (all adapters)
echo     7.  Disable memory compression / page combining
echo     8.  %GPU% telemetry / background tasks off
echo     9.  GPU hardware scheduling (HAGS) on/off
echo    10.  Set permanent process priority  (per .exe, e.g. a game)
echo    11.  Windows Update driver installs on/off
echo     0.  Back
echo ==================================================================================================

:MenuAdvanced_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuAdvanced_ask
if "!sel!"=="1" goto DisableMitigations
if "!sel!"=="2" goto EnableMitigations
if "!sel!"=="3" goto BcdTimers
if "!sel!"=="4" goto BcdRevert
if "!sel!"=="5" goto NvmeFlags
if "!sel!"=="6" goto DisableIPv6
if "!sel!"=="7" goto MemCompress
if "!sel!"=="8" goto GpuTelemetry
if "!sel!"=="9" goto HagsToggle
if "!sel!"=="10" goto ProcPriority
if "!sel!"=="11" goto WuDrivers
if "!sel!"=="0" goto MainMenu
goto MenuAdvanced
rem =====================================================================================
rem  SUBMENU: Backups & status
rem =====================================================================================
:MenuBackups
cls
call :Logo
echo =======================================  BACKUPS ^& STATUS  =======================================
echo     1.  Create System Restore Point
echo     2.  Full registry backup (HKLM + HKCU export)
echo     3.  Show current status / what's applied
echo     4.  Restore from a preset backup (JSON)
echo     5.  Restore a single value backup (.reg)
echo     6.  Revert power settings (from a power backup)
echo     7.  Revert telemetry services / tasks (from a telemetry backup)
echo     8.  Manage / open backup folder
echo     0.  Back
echo ==================================================================================================

:MenuBackups_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuBackups_ask
if "!sel!"=="1" goto DoRestorePoint
if "!sel!"=="2" goto DoRegBackup
if "!sel!"=="3" goto Status
if "!sel!"=="4" goto RestorePresetJson
if "!sel!"=="5" goto RestoreRegBackup
if "!sel!"=="6" goto RestorePowerBackup
if "!sel!"=="7" goto RestoreTelemetryBackup
if "!sel!"=="8" goto ManageBackups
if "!sel!"=="0" goto MainMenu
goto MenuBackups
rem =====================================================================================
rem  ACTION: Cleanup
rem =====================================================================================
:Cleanup
cls
call :Logo
echo ===========================================  CLEANUP  ============================================
echo  Deletes temp files, Windows logs, thumbnail cache, crash dumps, Delivery Optimization
echo  cache, and telemetry caches, then flushes DNS. Optional: shader caches, Recycle Bin,
echo  Event Viewer, or launch Disk Cleanup / Storage Sense. Only files are removed; nothing
echo  is changed in the registry. Prefetch is intentionally left alone.
echo ==================================================================================================
set "_c="
set /p "_c=Proceed? (Y/N): "
if /i not "!_c!"=="Y" goto MenuCleanup
rem  Outer free-space bracket: measure before core + optionals, report once at the end.
set "_CLEAN_OUTER=1"
call :FreeSpaceSnap
set "_FREE_BEFORE=%_FREE_BYTES%"
call :DoCleanupCore
set "_sh="
echo   The next game launch may hitch once while the caches rebuild.
set /p "_sh=Also clear DirectX / NVIDIA download shader caches? (Y/N): "
if /i not "!_sh!"=="Y" goto _clShDone
rem  Handed to :RunVar by name: in a call argument a "%" in the user name was lost.
if defined _cleanLocalAppData if exist "!LocalAppData!\D3DSCache\" (set "_runcmd=del /f /s /q "!LocalAppData!\D3DSCache\*.*"" & call :RunVar _runcmd)
set "_cleanProgramData="
call :CleanRoot ProgramData
if defined _cleanProgramData if exist "%ProgramData%\NVIDIA Corporation\Downloader\" call :Run "del /f /s /q ""%ProgramData%\NVIDIA Corporation\Downloader\*.*"""

:_clShDone
set "_rb="
set /p "_rb=Also empty the Recycle Bin (irreversible)? (Y/N): "
if /i not "!_rb!"=="Y" goto _clRbDone
echo   ^> Emptying Recycle Bin...
call :Log "EXEC-PS: Clear-RecycleBin"
start "" /min /wait powershell -NoProfile -Command "try{ Clear-RecycleBin -Force -ErrorAction Stop; exit 0 }catch{ exit 1 }"
if errorlevel 1 ( echo   [WARN] Recycle Bin could not be emptied. ) else ( echo   [OK] Recycle Bin emptied. )

:_clRbDone
set "_ev="
echo   Clearing the event logs also erases the history the crash ^& hardware-error report reads.
set /p "_ev=Also clear ALL Event Viewer logs, including the Security/audit log (irreversible)? (Y/N): "
if /i not "!_ev!"=="Y" goto _clEvDone
rem  Count what was actually cleared - this is the one irreversible step on this screen.
set "_evok=0" & set "_evbad=0"
for /f "tokens=*" %%G in ('wevtutil el') do (
    call :Run "wevtutil cl ""%%G"""
    if "!_runrc!"=="0" (set /a _evok+=1) else (set /a _evbad+=1)
)
if "!_evok!"=="0" (
    echo   [FAIL] No event log could be cleared ^(!_evbad! refused^) - see the log.
) else if not "!_evbad!"=="0" (
    echo   [WARN] Cleared !_evok! event log^(s^); !_evbad! could not be cleared - the log file lists each one.
) else (
    echo   [OK] Cleared all !_evok! event logs.
)
call :Log "Event logs: cleared !_evok!, failed !_evbad!"

:_clEvDone
set "_cm="
echo   Cleanup opens in its own window; Sincript does not wait for it.
set /p "_cm=Also open Windows Disk Cleanup (cleanmgr) for the system drive? (Y/N): "
if /i not "!_cm!"=="Y" goto _clCmDone
set "_drv=%SystemDrive:~0,1%"
start "" cleanmgr.exe /d %_drv%
call :Log "LAUNCH: cleanmgr /d %_drv%"
echo   [OK] Disk Cleanup launched for %_drv%:.

:_clCmDone
set "_ss="
set /p "_ss=Also open Storage Sense settings (configure / run from Windows Settings)? (Y/N): "
if /i not "!_ss!"=="Y" goto _clSsDone
start "" ms-settings:storagesense
call :Log "LAUNCH: ms-settings:storagesense"
echo   [OK] Storage Sense settings opened.

:_clSsDone
call :FreeSpaceSnap
set "_FREE_AFTER=%_FREE_BYTES%"
call :FreeSpaceReport
set "_CLEAN_OUTER="
rem  Deletes are best-effort, so claim no more than the measured free-space figures show.
if "%_ELEV%"=="0" (
    echo [WARN] Cleanup ran without Administrator rights: the Windows folders - and the event
    echo        logs, if you chose them - could not be cleaned. Re-run as Administrator for those.
) else (
    echo [OK] Cleanup finished. Files that were in use stay in place; the free-space figures above
    echo      are what it recovered.
)
pause
goto MenuCleanup

:DoCleanupCore
rem  An unset root variable would turn a delete into one from the drive root, so :CleanRoot proves
rem  each root and every delete is gated on it. _CLEAN_OUTER=1: the caller reports free space.
if defined _CLEAN_OUTER goto _clCoreBody
call :FreeSpaceSnap
set "_FREE_BEFORE=%_FREE_BYTES%"

:_clCoreBody
set "_cleanTEMP=" & set "_cleanSystemRoot=" & set "_cleanLocalAppData="
call :CleanRoot TEMP
call :CleanRoot SystemRoot
call :CleanRoot LocalAppData
rem  Deletes under the user profile go to :RunVar by name: a call argument loses a percent sign.
rem  TEMP is usually LocalAppData\Temp, often under its 8.3 short name: clean that folder once.
set "_tmpsame="
if defined _cleanTEMP if defined _cleanLocalAppData for %%A in ("!TEMP!") do for %%B in ("!LocalAppData!\Temp") do if /i "%%~fsA"=="%%~fsB" set "_tmpsame=1"
if defined _cleanTEMP if not defined _tmpsame (set "_runcmd=del /f /s /q "!TEMP!\*.*"" & call :RunVar _runcmd)
if defined _cleanSystemRoot call :Run "del /f /s /q ""%SystemRoot%\Temp\*.*"""
if defined _cleanLocalAppData (set "_runcmd=del /f /s /q "!LocalAppData!\Temp\*.*"" & call :RunVar _runcmd)
rem  Prefetch is intentionally not cleared: Windows rebuilds it and launches get slower.
if defined _cleanLocalAppData (set "_runcmd=del /f /s /q /a "!LocalAppData!\Microsoft\Windows\Explorer\*.db"" & call :RunVar _runcmd)
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Logs\CBS\*"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Logs\DISM\*"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Temp\CBS\*"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\setupact.log"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\setuperr.log"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Panther\*"""
if defined _cleanLocalAppData (set "_runcmd=del /f /q "!LocalAppData!\Microsoft\Windows\WebCache\*.*"" & call :RunVar _runcmd)
rem  Regenerating junk safe for presets: crash dumps, minidumps, Delivery Optimization cache.
if defined _cleanLocalAppData if exist "!LocalAppData!\CrashDumps\" (set "_runcmd=del /f /s /q "!LocalAppData!\CrashDumps\*.*"" & call :RunVar _runcmd)
if defined _cleanSystemRoot if exist "%SystemRoot%\Minidump\" call :Run "del /f /q ""%SystemRoot%\Minidump\*"""
if defined _cleanSystemRoot if exist "%SystemRoot%\SoftwareDistribution\DeliveryOptimization\Cache\" call :Run "del /f /s /q ""%SystemRoot%\SoftwareDistribution\DeliveryOptimization\Cache\*.*"""
rem  No path, nothing to collapse - never gated.
call :Run "ipconfig /flushdns"
if defined _CLEAN_OUTER goto :eof
call :FreeSpaceSnap
set "_FREE_AFTER=%_FREE_BYTES%"
call :FreeSpaceReport
goto :eof
rem =====================================================================================
rem  ACTION: DISM + SFC
rem =====================================================================================
:SfcDism
cls
call :Logo
echo =====================================  DISM + SFC integrity  =====================================
echo  Repairs the component store (DISM RestoreHealth) then verifies system files (SFC).
echo  Takes several minutes; progress streams below - let it finish.
echo ==================================================================================================
set "_c="
set /p "_c=Run DISM + SFC now? (Y/N): "
if /i not "!_c!"=="Y" goto MenuCleanup
call :RunLive "dism /online /cleanup-image /restorehealth"
set "_dismrc=!_runrc!"
call :RunLive "sfc /scannow"
echo.
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - DISM/SFC could not run. Re-run as Administrator.
    goto _sdDone
)
rem  DISM exit code: 0 = healthy or repaired, 3010 = repaired but needs a restart, else failed.
if "!_dismrc!"=="0" (
    echo [OK] DISM: the component store is healthy, or was repaired.
) else if "!_dismrc!"=="3010" (
    echo [OK] DISM: the component store was repaired - restart Windows to finish.
) else (
    echo [FAIL] DISM RestoreHealth did not complete ^(exit code !_dismrc!^). SFC repairs from that
    echo        store, so its result may be incomplete as well. DISM's output above says why.
)
rem  SFC exit codes are undocumented, so defer to the verdict it prints last.
echo        SFC reports its own result: the last message it printed above.

:_sdDone
pause
goto MenuCleanup
rem =====================================================================================
rem  ACTION: Reset Windows Update
rem =====================================================================================
:WUReset
cls
call :Logo
echo ===============================  Reset Windows Update components  ================================
echo  Stops update services, renames SoftwareDistribution and catroot2, restarts them.
echo  Fixes most stuck-update problems. Safe.
echo  The renamed folders are kept as a rollback copy. They are NOT deleted automatically -
echo  but sincript now offers to clear out the ones left by PREVIOUS resets first, because
echo  SoftwareDistribution is routinely 1-5 GB and one copy accumulated per run.
echo ==================================================================================================
set "_c="
set /p "_c=Reset Windows Update now? (Y/N): "
if /i not "!_c!"=="Y" goto MenuCleanup
call :WUPruneOld
for %%S in (wuauserv bits cryptSvc msiserver appidsvc) do call :Run "net stop %%S"
call :Run "ren ""%SystemRoot%\SoftwareDistribution"" SoftwareDistribution.bak_%RANDOM%"
call :Run "ren ""%SystemRoot%\System32\catroot2"" catroot2.bak_%RANDOM%"
rem  Check the renames before restarting services: wuauserv and cryptSvc recreate the folders.
set "_wufail="
if exist "%SystemRoot%\SoftwareDistribution\" set "_wufail=SoftwareDistribution"
if exist "%SystemRoot%\System32\catroot2\" set "_wufail=!_wufail! catroot2"
for %%S in (wuauserv bits cryptSvc msiserver appidsvc) do call :Run "net start %%S"
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - Windows Update reset could not run. Re-run as Administrator.
    goto _wuDone
)
if defined _wufail (
    echo [FAIL] Windows Update was NOT fully reset - still in place: !_wufail!. A service came
    echo        back or a file was in use. Restart Windows, then run this again.
    call :Log "FAIL: WUReset - not renamed: !_wufail!"
    goto _wuDone
)
echo [OK] Windows Update reset: SoftwareDistribution and catroot2 were set aside, and Windows
echo      builds fresh ones.
echo      The previous SoftwareDistribution / catroot2 were renamed beside the originals as
echo      a rollback copy. Once Windows Update works again they are dead weight - re-run this
echo      action, or delete them by hand from %%SystemRoot%%.

:_wuDone
pause
goto MenuCleanup

:WUPruneOld
rem  Reports and offers to delete the .bak_ folders left by earlier resets; deletion is opt-in.
set "_wpres=!TEMP!\pt_wuprune_%RANDOM%%RANDOM%.txt"
set "PT_WP_RES=!_wpres!"
set "PT_WP_MODE=count"
call :WUPruneWorker
set "_wpn=0" & set "_wpmb=0"
if exist "!_wpres!" for /f "usebackq tokens=1,2" %%a in ("!_wpres!") do ( set "_wpn=%%a" & set "_wpmb=%%b" )
del "!_wpres!" >nul 2>&1
if "!_wpn!"=="0" goto :eof
echo.
echo   [i] !_wpn! folder^(s^) from previous Windows Update resets are still on disk,
echo       using about !_wpmb! MB in %SystemRoot%. Deleting them is safe once Windows
echo       Update is working; keeping them only helps if you need to roll a reset back.
set "_wpc="
set /p "_wpc=  Delete those older leftovers now? (Y/N): "
if /i not "!_wpc!"=="Y" (
    echo   [SKIP] Leftovers kept.
    call :Log "WUReset: kept !_wpn! old leftover folder(s), ~!_wpmb! MB"
    goto :eof
)
set "PT_WP_RES=!_wpres!"
set "PT_WP_MODE=delete"
call :WUPruneWorker
set "_wpd=0" & set "_wpfree=0"
if exist "!_wpres!" for /f "usebackq tokens=1,2" %%a in ("!_wpres!") do ( set "_wpd=%%a" & set "_wpfree=%%b" )
del "!_wpres!" >nul 2>&1
if "!_wpd!"=="0" (
    echo         [FAIL] None could be removed - they may be in use, or this window is not elevated.
    call :Log "FAIL: WUReset prune removed 0 of !_wpn!"
    goto :eof
)
echo   [OK] Removed !_wpd! of !_wpn! old leftover folder^(s^), about !_wpfree! MB.
call :Log "OK: WUReset prune removed !_wpd!/!_wpn! (~!_wpfree! MB)"
goto :eof

:WUPruneWorker
rem  PT_WP_MODE = count or delete, PT_WP_RES = result file. Matches only the .bak_ folders this
rem  script creates, under two hardcoded parents. Sizes are measured before removal.
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $del=($env:PT_WP_MODE -eq 'delete'); $t=@(); $t+=@(Get-ChildItem -LiteralPath $env:SystemRoot -Directory -Filter 'SoftwareDistribution.bak_*' -ErrorAction SilentlyContinue); $t+=@(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'System32') -Directory -Filter 'catroot2.bak_*' -ErrorAction SilentlyContinue); $n=0; $mb=0; foreach($d in $t){ $sz=0; try{ $sz=[int64]((Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) }catch{}; if($del){ try{ Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $n++; $mb+=[math]::Round($sz/1MB) }catch{} } else { $n++; $mb+=[math]::Round($sz/1MB) } }; (''+$n+' '+$mb) | Out-File -FilePath $env:PT_WP_RES -Encoding ASCII"
set "PT_WP_RES=" & set "PT_WP_MODE="
goto :eof
rem =====================================================================================
rem  ACTION: Re-register Store / apps
rem =====================================================================================
:StoreRepair
cls
call :Logo
echo ==============================  Re-register Microsoft Store / apps  ==============================
echo  Re-registers the Store package for the current user. Fixes a broken Store.
echo ==================================================================================================
set "_c="
set /p "_c=Re-register the Store now? (Y/N): "
if /i not "!_c!"=="Y" goto MenuCleanup
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - Store re-register needs Administrator for -AllUsers. Re-run as Administrator.
    pause
    goto MenuCleanup
)
echo   ^> Re-registering Microsoft Store (separate window)...
call :Log "EXEC-PS (isolated): Store re-register"
rem  Exit 2 when no Store package exists: a pipeline over an empty set would exit 0.
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $p=@(Get-AppxPackage -AllUsers Microsoft.WindowsStore); if ($p.Count -eq 0) { exit 2 }; try { $p | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register ($_.InstallLocation + '\AppXManifest.xml') } } catch { exit 1 }"
set "_strc=%errorlevel%"
if "%_strc%"=="2" (
    echo [WARN] No Microsoft Store package is present on this Windows edition, so there was
    echo        nothing to re-register.
    call :Log "SKIP: Store re-register - no Microsoft.WindowsStore package present"
) else if not "%_strc%"=="0" (
    echo [ERROR] Store re-registration failed. Reboot and re-run if the Store still misbehaves.
    call :Log "FAIL: Store re-register"
) else (
    echo [OK] Store re-registration finished. If the Store still misbehaves, reboot and re-run.
    call :Log "OK: Store re-register"
)
pause
goto MenuCleanup
rem =====================================================================================
rem  ACTION: Compact WinSxS
rem =====================================================================================
:CompactWinSxS
cls
call :Logo
echo ========================================  Compact WinSxS  ========================================
echo  Removes superseded component-store versions via the supported DISM method, then
echo  optionally compresses system binaries (CompactOS). Frees disk space. The cleanup cannot
echo  be undone - it deletes old component versions now instead of after Windows' 30-day wait.
echo  CompactOS can: compact.exe /compactos:never decompresses the binaries again.
echo ==================================================================================================
set "_c="
set /p "_c=Run component cleanup now? (Y/N): "
if /i not "!_c!"=="Y" goto MenuCleanup
call :Run "dism /online /cleanup-image /startcomponentcleanup"
set "_cwrc=!_runrc!"
set "_co="
set /p "_co=Also compress OS binaries with CompactOS (slower, more space saved)? (Y/N): "
set "_corc="
if /i "!_co!"=="Y" call :Run "compact.exe /compactos:always"
if /i "!_co!"=="Y" set "_corc=!_runrc!"
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - component cleanup could not run. Re-run as Administrator.
    goto _cwDone
)
rem  Report each step's own exit code; 3010 is DISM's done, restart to finish.
if "!_cwrc!"=="0" (
    echo [OK] Component cleanup finished.
) else if "!_cwrc!"=="3010" (
    echo [OK] Component cleanup finished - restart Windows to complete it.
) else (
    echo [FAIL] DISM component cleanup did not complete ^(exit code !_cwrc!^) - see the log.
)
if defined _corc if "!_corc!"=="0" echo [OK] CompactOS: the system binaries are compressed.
if defined _corc if not "!_corc!"=="0" echo [FAIL] CompactOS did not complete ^(exit code !_corc!^) - see the log.

:_cwDone
pause
goto MenuCleanup
rem =====================================================================================
rem  ACTION: Performance
rem =====================================================================================
:Performance
cls
call :Logo
echo ======================================  PERFORMANCE TWEAKS  ======================================
echo  GameDVR off, gaming MMCSS priorities, faster startup/menus/shutdown, best-performance
echo  visuals, long-path support, Explorer opens "This PC", unhide core-parking options.
echo  Legacy "memory optimization" values and CPU-mitigation changes are NOT here (Advanced).
echo  One trade-off worth knowing: "faster shutdown" here includes AutoEndTasks=1. That
echo  lets Windows force-close apps at shutdown instead of showing the prompt that names
echo  which app is blocking it. Faster because it stops waiting - and unsaved work in
echo  those apps goes with it. Undo it from the value backup like any other tweak.
echo ==================================================================================================
set "_c="
set /p "_c=Apply performance tweaks? (Y/N): "
if /i not "!_c!"=="Y" goto MainMenu
rem  _RUNTRACK lets :Run count a failed sc, schtasks or powercfg call when not elevated.
set "_FAILS=0" & set "_RUNTRACK=1"
call :DoPerformanceCore
set "_q1=" & set "_q2=" & set "_q3=" & set "_q4=" & set "_q5=" & set "_q6=" & set "_q7="
set "_q8=" & set "_q9=" & set "_q10=" & set "_q12="
echo.
echo Optional knobs (small / unproven gains, or plain preference - your call):
set /p "_q1=  SystemResponsiveness=0 (reserve less for background)? (Y/N): "
if /i "!_q1!"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "SystemResponsiveness" REG_DWORD 0 "SystemResponsiveness 0"
set /p "_q2=  Disable network throttling (may affect media playback)? (Y/N): "
if /i "!_q2!"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex" REG_DWORD 0xffffffff "Network throttling off"
rem  One exclusive choice, so a value and a reset in one pass cannot corrupt the value backup.
rem  42 = short fixed quantum, shown by Windows as background services; 38 = the Programs value.
echo   Win32PrioritySeparation ^(processor scheduling^):
echo       1 = 42 ^(0x2A: short FIXED quantum - the classic "42" tweak. The Windows
echo               dialog will read this back as "background services", because a fixed
echo               quantum treats all apps equally - that is what the value means.^)
echo       2 = 38 ^(0x26: short VARIABLE quantum, strong foreground boost - the value
echo               Windows own "Programs" radio writes; foreground gets the longer slice.^)
echo       3 = 2  ^(the Windows default - switches back from 42 or 38; the exact value you
echo               had before is in its .reg backup^)
echo       N = leave unchanged
set /p "_q3=  Choose [1/2/3/N]: "
if "!_q3!"=="1" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 42 "Win32PrioritySeparation = 42 (0x2A, short fixed quantum)"
if "!_q3!"=="2" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 38 "Win32PrioritySeparation = 38 (0x26, short variable quantum, foreground)"
if "!_q3!"=="3" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 2 "Win32PrioritySeparation default (2)"
call :DesktopAdvisory
set /p "_q4=  LargeSystemCache=1 (can help some laptops, can hurt desktops)? (Y/N): "
if /i "!_q4!"=="Y" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "LargeSystemCache" REG_DWORD 1 "LargeSystemCache on"
set /p "_q5=  Disable Windows Game Mode (contested; some titles run smoother without it)? (Y/N): "
if /i "!_q5!"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "AutoGameModeEnabled" REG_DWORD 0 "Game Mode off"
if /i "!_q5!"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "AllowAutoGameMode" REG_DWORD 0 "Auto Game Mode off"
echo     Recording is already off from the core pass - this is the overlay chrome.
echo     It does not uninstall Xbox.
set /p "_q12=  Disable Game Bar / Xbox Game Bar overlay leftovers? (Y/N): "
if /i "!_q12!"=="Y" call :DoGameBarOff
echo     Raw 1:1 mouse movement. Takes effect after you sign out and back in.
set /p "_q6=  Disable mouse acceleration / Enhance pointer precision? (Y/N): "
if /i "!_q6!"=="Y" call :SafeRegAdd "HKCU\Control Panel\Mouse" "MouseSpeed" REG_SZ 0 "Mouse acceleration off"
if /i "!_q6!"=="Y" call :SafeRegAdd "HKCU\Control Panel\Mouse" "MouseThreshold1" REG_SZ 0 "Mouse accel threshold1 off"
if /i "!_q6!"=="Y" call :SafeRegAdd "HKCU\Control Panel\Mouse" "MouseThreshold2" REG_SZ 0 "Mouse accel threshold2 off"
set /p "_q7=  Show file extensions in Explorer (safer, see real file types)? (Y/N): "
if /i "!_q7!"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" REG_DWORD 0 "Show file extensions"
echo     Stops Windows auto-deleting temp files and the recycle bin.
echo     Cleanup does the same thing on demand instead.
set /p "_q8=  Turn off Storage Sense? (Y/N): "
rem  Machine policy only: AllowStorageSenseGlobal is device scope, so an HKCU copy does nothing.
if /i "!_q8!"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSenseGlobal" REG_DWORD 0 "Storage Sense off (policy)"
echo     Only changes anything if you turned on Enhanced search, which indexes
echo     the whole drive. Classic is already the Windows default.
set /p "_q9=  Windows Search: index libraries only, not the entire drive? (Y/N): "
if /i "!_q9!"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Search\Preferences" "WholeFileSystem" REG_DWORD 0 "Windows Search: classic scope"
call :DetectSysDisk
call :DiskAdvisory
echo     Less background disk and CPU on an SSD.
echo     Keep it ON for a mechanical HDD.
set /p "_q10=  Disable SysMain / Superfetch? (Y/N): "
if /i "!_q10!"=="Y" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\SysMain" "Start" REG_DWORD 4 "SysMain (Superfetch) disabled"
if /i "!_q10!"=="Y" call :Run "sc stop SysMain"
echo     A diagnostic that names each startup step, so you can SEE what is slow.
echo     It is not a speed-up itself.
set "_q11=" & set /p "_q11=  Show verbose boot/logon messages? (Y/N): "
if /i "!_q11!"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "verbosestatus" REG_DWORD 1 "Verbose startup/logon status messages"
if /i "!_q11!"=="Y" call :VerboseStatusNote
call :Summary "Performance tweaks applied."
pause
goto MainMenu

:DoPerformanceCore
call :SafeRegAdd "HKCU\System\GameConfigStore" "GameDVR_Enabled" REG_DWORD 0 "GameDVR off"
call :SafeRegAdd "HKCU\System\GameConfigStore" "GameDVR_FSEBehaviorMode" REG_DWORD 2 "FSE behavior"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" REG_DWORD 0 "GameDVR off (policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" "GPU Priority" REG_DWORD 8 "Games GPU priority"
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" "Priority" REG_DWORD 6 "Games CPU priority"
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" "Scheduling Category" REG_SZ High "Games scheduling High"
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" "SFIO Priority" REG_SZ High "Games SFIO High"
call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" "StartupDelayInMSec" REG_DWORD 0 "No startup delay"
call :SafeRegAdd "HKCU\Control Panel\Desktop" "MenuShowDelay" REG_SZ 50 "Menu show delay 50ms"
call :SafeRegAdd "HKCU\Control Panel\Desktop" "AutoEndTasks" REG_SZ 1 "Auto-end hung tasks"
call :SafeRegAdd "HKCU\Control Panel\Desktop" "WaitToKillAppTimeout" REG_SZ 5000 "WaitToKill app 5s"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control" "WaitToKillServiceTimeout" REG_SZ 5000 "WaitToKill service 5s"
call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" REG_DWORD 2 "Visuals: best performance"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled" REG_DWORD 1 "Enable long paths"
call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "LaunchTo" REG_DWORD 1 "Explorer opens This PC"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583" "Attributes" REG_DWORD 0 "Unhide core-parking min cores"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb" "Attributes" REG_DWORD 0 "Unhide allow-throttle-states option"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\ea062031-0e34-4ff1-9b6d-eb1059334028" "Attributes" REG_DWORD 0 "Unhide core-parking max cores"
goto :eof
rem =====================================================================================
rem  ACTION: Privacy
rem =====================================================================================
:Privacy
rem  One telemetry undo file per visit, so a second pass does not bury the first capture.
set "_TLBAK_FILE="
cls
call :Logo
echo =====================================  PRIVACY ^& TELEMETRY  ======================================
echo  Disables diagnostic telemetry, advertising ID, suggested apps, Cortana/web search,
echo  feedback prompts, activity feed and location; stops DiagTrack and CEIP tasks.
echo  Also turns off Windows AI features by policy - Copilot, Recall snapshots and
echo  Click to Do - plus inking/typing personalization and online speech recognition.
echo  Quiets remaining Start/lock Content Delivery tips, search-box suggestions, and
echo  tailored experiences. Also turns off the Widgets / News and Interests feed and
echo  Start app-launch tracking ("Most used"), and disables dmwappushservice alongside
echo  DiagTrack.
echo --------------------------------------------------------------------------------------------------
echo  Honest notes: the telemetry policy is written as 0 (Security). Enterprise and
echo  Education honor 0; Home/Pro clamp it to Basic (1) - the lowest those editions
echo  allow. Stopping DiagTrack also stops Xbox achievement sync and the Feedback Hub.
echo  Recall policies only have visible effect on Copilot+ hardware; elsewhere they
echo  are inert but harmless. Start/lock "suggestions and tips" keys quiet the
echo  Content Delivery surface - they are not Defender or security changes.
echo  dmwappushservice is the WAP-push telemetry transport, but it also carries MDM
echo  enrolment - on a work or school managed PC, leave this action alone.
echo  OneDrive is NOT touched by this core: it is the opt-in prompt below.
echo ==================================================================================================
set "_c="
set /p "_c=Apply privacy / telemetry hardening? (Y/N): "
if /i not "!_c!"=="Y" goto MainMenu
set "_FAILS=0" & set "_RUNTRACK=1"
call :DoPrivacyCore
set "_svc="
set /p "_svc=Also disable per-user sync services (breaks Mail/Calendar/People sync)? (Y/N): "
if /i not "!_svc!"=="Y" goto _privSvcDone
for %%S in (CDPUserSvc OneSyncSvc PimIndexMaintenanceSvc UnistoreSvc UserDataSvc MessagingService) do call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\%%S" "Start" REG_DWORD 4 "Disable per-user svc %%S"

:_privSvcDone
set "_fw="
echo   Belt-and-braces: keeps it blocked if an update re-enables the service.
set /p "_fw=Also block the telemetry service in Windows Firewall? (Y/N): "
if /i "!_fw!"=="Y" call :DiagTrackFirewall
set "_edge="
echo   Edge only, and it does not uninstall Edge.
set /p "_edge=Also reduce Edge first-run / sidebar / shopping nudges? (Y/N): "
if /i "!_edge!"=="Y" call :DoEdgeNudgesOff
set "_od="
echo   This STOPS OneDrive syncing entirely - not just its telemetry.
set /p "_od=Also block OneDrive file sync by policy? (Y/N): "
if /i "!_od!"=="Y" call :DoOneDriveSyncOff
call :Summary "Privacy tweaks applied."
pause
goto MainMenu

:DoPrivacyCore
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" REG_DWORD 0 "Diagnostic telemetry (policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" REG_DWORD 0 "Diagnostic telemetry (HKLM)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "AITEnable" REG_DWORD 0 "App inventory off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableInventory" REG_DWORD 1 "Inventory collection off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" REG_DWORD 0 "Advertising ID off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" REG_DWORD 1 "Advertising ID off (policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" REG_DWORD 1 "Suggested apps off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" REG_DWORD 0 "Widgets / News and Interests off"
rem  Unverified: no ADMX defines this value; kept because it is harmless, and labelled so.
call :SafeRegAdd "HKCU\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsSpotlightOnLockScreen" REG_DWORD 1 "Windows Spotlight on lock screen off (unverified)"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled" REG_DWORD 0 "Start suggestions off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338389Enabled" REG_DWORD 0 "Tips/tricks off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338387Enabled" REG_DWORD 0 "Get tips/suggestions off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338393Enabled" REG_DWORD 0 "Content Delivery 338393 off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-353694Enabled" REG_DWORD 0 "Content Delivery 353694 off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-353696Enabled" REG_DWORD 0 "Content Delivery 353696 off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled" REG_DWORD 0 "Silent app install off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SoftLandingEnabled" REG_DWORD 0 "Soft Landing tips off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "PreInstalledAppsEnabled" REG_DWORD 0 "Preinstalled app suggestions off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "OemPreInstalledAppsEnabled" REG_DWORD 0 "OEM preinstalled app suggestions off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenEnabled" REG_DWORD 0 "Rotating lock screen off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "RotatingLockScreenOverlayEnabled" REG_DWORD 0 "Lock screen overlay fun facts off"
call :SafeRegAdd "HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" REG_DWORD 1 "Search box suggestions off (user policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" REG_DWORD 1 "Search box suggestions off (policy)"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" REG_DWORD 0 "Tailored experiences off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableTailoredExperiencesWithDiagnosticData" REG_DWORD 1 "Tailored experiences off (policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" REG_DWORD 0 "Cortana off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" REG_DWORD 1 "Web search in Start off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" REG_DWORD 0 "Connected web search off"
call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" REG_DWORD 0 "Bing in search off"
call :SafeRegAdd "HKCU\Software\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" REG_DWORD 0 "Feedback prompts off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DoNotShowFeedbackNotifications" REG_DWORD 1 "Feedback notifications off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" REG_DWORD 0 "Activity feed off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" REG_DWORD 0 "Activity history publish off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" REG_DWORD 0 "Activity history upload off"
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackProgs" REG_DWORD 0 "App-launch tracking off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" "DisableLocation" REG_DWORD 1 "Location off"
rem  --- Windows AI (Copilot / Recall / Click to Do) - policy off, reversible ---
call :SafeRegAdd "HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" REG_DWORD 1 "Copilot off (user policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" REG_DWORD 1 "Copilot off (policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" REG_DWORD 1 "Recall data analysis off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "AllowRecallEnablement" REG_DWORD 0 "Recall enablement blocked"
rem  Unverified: no ADMX defines this; DisableAIDataAnalysis above is the documented control.
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "TurnOffSavingSnapshots" REG_DWORD 1 "Recall snapshots off (unverified)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" REG_DWORD 1 "Click to Do off"
rem  --- inking / typing / speech personalization off ---
call :SafeRegAdd "HKCU\SOFTWARE\Policies\Microsoft\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0 "Inking-typing personalization off (user policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0 "Inking-typing personalization off (policy)"
call :SafeRegAdd "HKCU\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" REG_DWORD 1 "Implicit text collection off"
call :SafeRegAdd "HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore" "HarvestContacts" REG_DWORD 0 "Contact harvesting off"
call :SafeRegAdd "HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" "HasAccepted" REG_DWORD 0 "Online speech recognition off"
rem  Capture first: sc config and schtasks leave no .reg, so :TelemetryBackup writes the undo.
call :TelemetryBackup
call :Run "sc config DiagTrack start= disabled"
call :Run "sc stop DiagTrack"
call :Run "sc config dmwappushservice start= disabled"
call :Run "sc stop dmwappushservice"
call :Run "schtasks /Change /TN ""\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"" /Disable"
call :Run "schtasks /Change /TN ""\Microsoft\Windows\Application Experience\ProgramDataUpdater"" /Disable"
call :Run "schtasks /Change /TN ""\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"" /Disable"
call :Run "schtasks /Change /TN ""\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"" /Disable"
call :Run "schtasks /Change /TN ""\Microsoft\Windows\Windows Error Reporting\QueueReporting"" /Disable"
call :DisableTelemetryTasks
goto :eof
rem =====================================================================================
rem  ACTION: Power plan
rem =====================================================================================
:Power
cls
call :Logo
echo ==========================================  POWER PLAN  ==========================================
echo  Pick a power plan below, then optionally set monitor/standby/disk sleep timeouts to
echo  never. Ultimate Performance is the aggressive one and is best kept for a plugged-in
echo  desktop; High Performance is the safer fast plan; Balanced switches back from either.
echo  To return to exactly the plan you had: Backups ^& status ^> Revert power settings.
echo  Declining the plan switch does NOT end here: every other change on this screen
echo  applies to whichever plan you are already on, so you can keep Balanced and still
echo  turn off sleep, set the minimum CPU state, or disable power throttling.
echo --------------------------------------------------------------------------------------------------
echo  Your current plan:
for /f "tokens=*" %%i in ('powercfg /getactivescheme') do echo    %%i
echo ==================================================================================================
call :LaptopAdvisory
rem  Warning-only, changes no default: sustained max clocks can break a stable laptop undervolt.
if /i "%MACHINE%"=="laptop" echo   [ADVISORY] Option 1 especially: Windows hides Ultimate Performance on
if /i "%MACHINE%"=="laptop" echo              battery-powered machines by design. If you run an undervolt
if /i "%MACHINE%"=="laptop" echo              ^(ThrottleStop / XTU / vendor tuning^), jumping straight to
if /i "%MACHINE%"=="laptop" echo              sustained max clocks is where an otherwise-stable undervolt
if /i "%MACHINE%"=="laptop" echo              fails ^(BSOD^), and the CPU reports it as an uncorrectable machine check.
echo.
echo   Power plan:
echo       1 = Ultimate Performance  ^(workstation plan. Pins the minimum processor state at
echo           100%%, disables core parking and PCIe link power management: max clocks, no
echo           idle states. Windows hides this plan on battery-powered machines.^)
echo       2 = High Performance      ^(the long-standing fast plan; still parks cores and
echo           still lets PCIe links idle - the safer of the two^)
echo       3 = Balanced              ^(the Windows default - switches back from 1 or 2^)
echo       N = leave the plan alone  ^(you can still apply the individual items below^)
set "_c="
set /p "_c=Choose [1/2/3/N]: "
set "_PWPLAN="
if "!_c!"=="1" set "_PWPLAN=ultimate"
if "!_c!"=="2" set "_PWPLAN=high"
if "!_c!"=="3" set "_PWPLAN=balanced"
if defined _PWPLAN goto _pwApply
rem  Only the plan switch is plan-level; the rest acts on the active scheme, so still offer it.
set "_c2="
set /p "_c2=Apply individual power changes to your CURRENT plan instead? (Y/N): "
if /i not "!_c2!"=="Y" goto MainMenu

:_pwApply
rem  One undo file per visit, not per routine: :DoPowerCore calls both halves.
set "_PWBAK_FILE="
rem  _PWHBOFF: set below when hibernation is turned off with no capture landed on this visit.
set "_PWHBOFF="
set "_FAILS=0" & set "_RUNTRACK=1"
if defined _PWPLAN call :DoPowerPlanSwitch
rem  Balanced is the way back to defaults, so it skips the never-sleep timeouts and just asks.
if defined _PWPLAN if /i not "!_PWPLAN!"=="balanced" call :DoPowerTimeouts
if defined _PWPLAN if /i not "!_PWPLAN!"=="balanced" goto _pwOptional
rem  On the current-plan path the timeouts are asked for, never implied.
set "_tmo="
echo   Costs battery on a laptop.
set /p "_tmo=Set monitor / standby / disk timeouts to NEVER on the current plan? (Y/N): "
if /i "!_tmo!"=="Y" call :DoPowerTimeouts

:_pwOptional
set "_hb="
echo   It goes into the power undo file first ^(Backups ^& status ^> Revert power settings^).
set /p "_hb=Also disable hibernation (frees disk space, removes Fast Startup)? (Y/N): "
rem  Capture first: :PowerBackup records hibernation so its undo file can turn it back on.
if /i "!_hb!"=="Y" call :PowerBackup
if /i "!_hb!"=="Y" call :Run "powercfg /hibernate off"
rem  No capture landed: _PWHBOFF makes a retried capture call the earlier state unknown.
if /i "!_hb!"=="Y" if not defined _PWBAK_FILE set "_PWHBOFF=1"
set "_mp="
echo   The CPU idles to save power, with no FPS loss.
echo   Undo: Backups ^& status ^> Revert power settings, or Windows Power Options.
set /p "_mp=Set minimum processor state to 5%%? (Y/N): "
if /i "!_mp!"=="Y" call :SetMinProcState
set "_pwt="
echo   Background apps then run at full speed - more heat, more battery drain.
set /p "_pwt=Also disable CPU power throttling? (Y/N): "
if /i "!_pwt!"=="Y" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" "PowerThrottlingOff" REG_DWORD 1 "CPU power throttling off"
call :Summary "Power settings applied."
pause
goto MainMenu

:DoPowerCore
rem  Aggregate for presets and the recommended set: switch the plan and set the timeouts.
call :DoPowerPlanSwitch
rem  /plan:balanced means put it back, so it skips the never-sleep timeouts.
if /i not "%_PWPLAN%"=="balanced" call :DoPowerTimeouts
goto :eof

:DoPowerPlanSwitch
rem  The only part that changes which scheme is active; everything else tunes the active one.
call :PowerBackup
rem  _PWPLAN = ultimate, high or balanced; unset means ultimate, as presets and the recommended
rem  set expect. Resolve into _pwsel and never write back: _PWPLAN is an input.
set "_pwsel=%_PWPLAN%"
if not defined _pwsel set "_pwsel=ultimate"
if /i "%_pwsel%"=="balanced" goto _pwPlanBalanced
if /i "%_pwsel%"=="high" goto _pwPlanHigh
call :Log "Power plan -> Ultimate (fallback High)"
rem  Duplicate Ultimate onto its canonical GUID so re-runs do not pile up unused clones.
powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 e9a42b02-d5df-448d-aa00-03f14749eb61 >nul 2>&1
powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 >nul 2>&1
set "_pwswrc=%errorlevel%"
if "%_pwswrc%"=="0" goto :eof
rem  Ultimate could not be activated, so fall back to High Performance and say so.
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1
set "_pwswrc=%errorlevel%"
if not "%_pwswrc%"=="0" call :_pwSwitchFailed "Ultimate Performance (and the High Performance fallback)"
if not "%_pwswrc%"=="0" goto :eof
echo   [WARN] Ultimate Performance could not be activated here, so High Performance was
echo          activated instead.
call :Log "Power plan: Ultimate unavailable - High Performance activated instead"
goto :eof

:_pwPlanHigh
rem  No -duplicatescheme needed: High Performance ships with Windows and is never hidden.
call :Log "Power plan -> High Performance"
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1
set "_pwswrc=%errorlevel%"
if not "%_pwswrc%"=="0" call :_pwSwitchFailed "High Performance"
goto :eof

:_pwPlanBalanced
call :Log "Power plan -> Balanced (Windows default)"
powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e >nul 2>&1
set "_pwswrc=%errorlevel%"
if not "%_pwswrc%"=="0" call :_pwSwitchFailed "Balanced"
goto :eof

:_pwSwitchFailed
rem  Arg 1 = plan name, echoed late so it is never re-parsed.
set "_pwname=%~1"
echo [WARN] Could not switch to !_pwname! - this Windows does not have that plan. Your
echo        current plan was left as it is; everything else on this screen still applied.
call :Log "FAIL: power plan -> !_pwname! (setactive returned nonzero)"
set /a _FAILS+=1
goto :eof

:DoPowerTimeouts
rem  powercfg -change targets the active scheme, so this works on any plan.
call :PowerBackup
call :Log "Power timeouts -> never (active scheme)"
call :Run "powercfg -change -monitor-timeout-ac 0"
call :Run "powercfg -change -monitor-timeout-dc 0"
call :Run "powercfg -change -standby-timeout-ac 0"
call :Run "powercfg -change -standby-timeout-dc 0"
call :Run "powercfg -change -disk-timeout-ac 0"
call :Run "powercfg -change -disk-timeout-dc 0"
goto :eof

:PowerBackup
rem  Captures the active scheme, idle timeouts, minimum CPU state and hibernation into an undo .bat
rem  once per visit: _PWBAK_FILE is the guard, cleared again if the capture fails. Reads the
rem  registry, not localized powercfg text. With _PWHBOFF set, the earlier hibernation state is
rem  written as unknown. A failed capture only warns - all of it is reachable by hand.
if defined _PWBAK_FILE goto :eof
set "_PWBAK_FILE=!BACKUP_DIR!\PowerPlan_%RANDOM%%RANDOM%.bat"
set "PT_PWBAK=!_PWBAK_FILE!"
set "PT_HBOFF=!_PWHBOFF!"
del "!_PWBAK_FILE!" >nul 2>&1
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $g=[regex]::Match(((powercfg /getactivescheme) -join ' '),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value; if(-not $g){exit 1}; $q=[char]34; $defs=@(@('7516b95f-f776-4464-8c53-06167f40cc99','3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e','monitor idle timeout'),@('238c9fa8-0aad-41ed-83f4-97be242c8f20','29f6c1db-86da-48c5-9fdb-f2b67b1f44da','standby idle timeout'),@('0012ee47-9041-4b5d-9b77-535fba8b1442','6738e2c4-e8a5-4a42-b16a-e040e769756e','disk idle timeout'),@('54533251-82be-4824-96c1-47b60b740d00','893dee8e-2bef-41e0-89c6-b55d0929964c','minimum processor state')); $L=@('@echo off','setlocal',('set '+$q+'PT_OK=0'+$q),('set '+$q+'PT_FAIL=0'+$q),'rem  Sincript power-settings undo.','rem  Restores the power scheme that was active before sincript changed it, and the','rem  monitor / standby / disk idle timeouts and the minimum processor state it had,','rem  each in its own native unit (seconds for the timeouts, percent for the CPU floor).','rem  Values are read back from the registry, so this is locale-independent.','rem  A setting this plan never stored explicitly is restored from the plan default','rem  (PowerSettings\...\DefaultPowerSchemeValues), or failing that from the value','rem  that was in effect (powercfg /query, read as hex so it does not depend on the','rem  display language). Without that, sincript''s explicit 0 simply stayed put.','rem  Safe to run more than once. Double-click to restore.','',('rem  scheme: '+$g),'','rem  The plan itself goes back FIRST, on purpose. It is the single line that matters most','rem  in this file, so a partial run - a crash, a closed window, a failed write below -','rem  still leaves you on the plan you started from instead of stranded on the new one.',('call :pt_do powercfg -setactive '+$g),''); foreach($d in $defs){ $p='HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\'+$g+'\'+$d[0]+'\'+$d[1]; $v=Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue; $dp='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\'+$d[0]+'\'+$d[1]+'\DefaultPowerSchemeValues\'+$g; $dv=Get-ItemProperty -LiteralPath $dp -ErrorAction SilentlyContinue; $qc=$null; foreach($s in @(@('ACSettingIndex','-setacvalueindex','on AC',0),@('DCSettingIndex','-setdcvalueindex','on battery',1))){ $n=$s[0]; $val=$null; $note=''; if($null -ne $v -and $null -ne $v.$n){ $val=[int]$v.$n } elseif($null -ne $dv -and $null -ne $dv.$n){ $val=[int]$dv.$n; $note=' - never set explicitly on this plan; this is the plan default' } else { if($null -eq $qc){ $qc=@([regex]::Matches(((powercfg /query $g $d[0] $d[1]) | Out-String),'0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value }) }; if($qc.Count -ge 2){ $val=[Convert]::ToInt64($qc[$qc.Count-2+$s[3]].Substring(2),16); $note=' - not stored on this plan; this is the value that was in effect' } } if($null -ne $val){ $L+=('rem  '+$d[2]+', '+$s[2]+$note); $L+=('call :pt_do powercfg '+$s[1]+' '+$g+' '+$d[0]+' '+$d[1]+' '+$val) } else { $L+=('rem  '+$d[2]+' '+$s[2]+' could not be read at backup time - left alone') } } }; $hb=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue; $hv=$null; $hd=$false; if($null -ne $hb){ if($null -ne $hb.HibernateEnabled){ $hv=$hb.HibernateEnabled } elseif($null -ne $hb.HibernateEnabledDefault){ $hv=$hb.HibernateEnabledDefault; $hd=$true } }; $L+=''; if($null -ne $hv){ if($hd){ $L+='rem  HibernateEnabled was not set, so this is the Windows default (HibernateEnabledDefault).' }; if([int]$hv -eq 1){ $L+='rem  hibernation was on before sincript - turn it back on'; $L+='call :pt_do powercfg /hibernate on' } elseif($env:PT_HBOFF){ $L+='rem  sincript turned hibernation off before this file could be written, so whether it was'; $L+='rem  on before is unknown - left alone. If it was on, turn it back on from an elevated'; $L+='rem  prompt with:  powercfg /hibernate on' } else { $L+='rem  hibernation was already off before sincript - left alone' } } else { $L+='rem  hibernation state could not be read at backup time - left alone. If it was on before,'; $L+='rem  turn it back on from an elevated prompt with:  powercfg /hibernate on' }; $L+=@('','rem  Re-activate once more: powercfg only applies changed values to the active scheme','rem  when the scheme is (re)activated, so this is what makes the writes above take effect.',('call :pt_do powercfg -setactive '+$g),'','rem  Report what actually landed. This file used to print a flat restored line whatever','rem  happened, so a run that could not write anything - not elevated, or the scheme since','rem  deleted - still read as success. Generated output is real cmd, so it gets the same','rem  honesty rule as the script that wrote it.',('if '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [OK] Restored %%PT_OK%% power setting(s).'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [WARN] %%PT_OK%% restored, %%PT_FAIL%% FAILED - see the [FAIL] lines above.'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo        Re-run this file from an elevated prompt.'),('if '+$q+'%%~1'+$q+'=='+$q+$q+' pause'),'exit /b %%PT_FAIL%%','','rem  Flat on purpose: no ( ) block, so nothing here depends on delayed expansion.',':pt_do','%%*','if errorlevel 1 goto :pt_bad','set /a PT_OK+=1','exit /b',':pt_bad','set /a PT_FAIL+=1','echo   [FAIL] %%*','exit /b'); Set-Content -LiteralPath $env:PT_PWBAK -Value $L -Encoding ASCII"
set "PT_PWBAK="
set "PT_HBOFF="
if not exist "!_PWBAK_FILE!" (
    echo   [WARN] Could not save a power-settings undo file - continuing anyway. The plan and its
    echo          timeouts stay reachable in Control Panel ^> Power Options; hibernation comes back
    echo          only with  powercfg /hibernate on  in an elevated prompt.
    call :Log "WARN: power backup not written"
    set "_PWBAK_FILE="
    goto :eof
)
echo   [BACKUP] Power settings -^> !_PWBAK_FILE!
set "_LOGMSG=POWERBACKUP -> !_PWBAK_FILE!" & call :LogVar _LOGMSG
goto :eof

:SetMinProcState
rem  Capture first: this is reachable without the plan switch or the timeouts.
call :PowerBackup
call :Log "Min processor state -> 5 percent"
call :Run "powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMIN 5"
call :Run "powercfg /setdcvalueindex scheme_current sub_processor PROCTHROTTLEMIN 5"
call :Run "powercfg /setactive scheme_current"
goto :eof
rem =====================================================================================
rem  BACKUP: telemetry services + scheduled tasks
rem =====================================================================================
:TelemetryBackup
rem  Captures the telemetry services and tasks :DoPrivacyCore disables into an undo .bat, once per
rem  visit; a failure only warns. Reads the registry, not localized text. Already-disabled: skipped.
if defined _TLBAK_FILE goto :eof
if not exist "!BACKUP_DIR!\" goto _tlbNoFolder
set "_TLBAK_FILE=!BACKUP_DIR!\Telemetry_%RANDOM%%RANDOM%.bat"
del "!_TLBAK_FILE!" >nul 2>&1
set "PT_TLBAK=!_TLBAK_FILE!"
set "PT_TL_SVC=DiagTrack|dmwappushservice"
set "PT_TL_TASKS=Microsoft Compatibility Appraiser|ProgramDataUpdater|Consolidator|UsbCeip|QueueReporting|MareBackup|StartupAppTask|Microsoft-Windows-DiskDiagnosticDataCollector|MapsToastTask"
start "" /min /wait powershell -NoProfile -Command "$q=[char]34; $map=@{0='boot';1='system';2='auto';3='demand';4='disabled'}; $L=@('@echo off','setlocal',('set '+$q+'PT_OK=0'+$q),('set '+$q+'PT_FAIL=0'+$q),'rem  Sincript telemetry undo.','rem  Puts back the start type of the services and the enabled state of the scheduled','rem  tasks that sincript disabled - each one only if it was in that state beforehand.','rem  Read from the registry and from Get-ScheduledTask, so nothing here depends on the','rem  display language. Safe to run more than once. Double-click to restore.',''); foreach($s in @($env:PT_TL_SVC -split '\|')){ $p='HKLM:\SYSTEM\CurrentControlSet\Services\'+$s; $v=Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue; if($null -eq $v -or $null -eq $v.Start){ $L+=('rem  service '+$s+' is not on this machine - nothing to put back'); continue }; $kw=$map[[int]$v.Start]; if(-not $kw){ $L+=('rem  service '+$s+' had start type '+[int]$v.Start+', which has no sc keyword - left alone'); continue }; if($kw -eq 'disabled'){ $L+=('rem  service '+$s+' was already disabled before sincript - left alone'); continue }; $L+=('rem  '+$s+': start type before sincript'); $L+=('call :pt_do sc config '+$s+' start= '+$kw); if((Get-Service -Name $s -ErrorAction SilentlyContinue).Status -eq 'Running'){ $L+=('rem  '+$s+' was running at the time, so start it again'); $L+=('call :pt_do sc start '+$s) } }; foreach($t in @($env:PT_TL_TASKS -split '\|')){ $o=@(Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue); if($o.Count -eq 0){ $L+=('rem  task '+$t+' is not present on this edition'); continue }; foreach($x in $o){ $f=$x.TaskPath+$x.TaskName; if($x.State -eq 'Disabled'){ $L+=('rem  task '+$f+' was already disabled before sincript - left alone') } else { $L+=('call :pt_do schtasks /Change /TN '+$q+$f+$q+' /Enable') } } }; $L+=@('',('if '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [OK] Restored %%PT_OK%% item(s).'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [WARN] %%PT_OK%% restored, %%PT_FAIL%% FAILED - see the [FAIL] lines above.'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo        Re-run this file from an elevated prompt.'),('if '+$q+'%%~1'+$q+'=='+$q+$q+' pause'),'exit /b %%PT_FAIL%%','','rem  Flat on purpose: no ( ) block, so nothing here depends on delayed expansion.',':pt_do','%%*','if errorlevel 1 goto :pt_bad','set /a PT_OK+=1','exit /b',':pt_bad','set /a PT_FAIL+=1','echo   [FAIL] %%*','exit /b'); Set-Content -LiteralPath $env:PT_TLBAK -Value $L -Encoding ASCII"
set "PT_TLBAK=" & set "PT_TL_SVC=" & set "PT_TL_TASKS="
if not exist "!_TLBAK_FILE!" goto _tlbFailed
echo   [i] Telemetry undo file: !_TLBAK_FILE!
set "_LOGMSG=TELEMETRY backup -> !_TLBAK_FILE!" & call :LogVar _LOGMSG
goto :eof

:_tlbNoFolder
echo   [WARN] No backup folder, so no telemetry undo file was written. Services.msc and Task
echo          Scheduler can still put these back by hand.
call :Log "WARN: telemetry backup skipped - no backup folder"
set "_TLBAK_FILE="
goto :eof

:_tlbFailed
echo   [WARN] The telemetry undo file could not be written. Continuing: services.msc and Task
echo          Scheduler can still put these back by hand.
call :Log "WARN: telemetry backup not written"
set "_TLBAK_FILE="
goto :eof
rem =====================================================================================
rem  ACTION: Network TCP tweaks
rem =====================================================================================
:NetworkApply
cls
call :Logo
echo =======================================  APPLY TCP TWEAKS  =======================================
echo  Receive-side autotuning = normal, heuristics off, RSS on, RSC on (sane defaults). The
echo  previous netsh values are NOT saved: to note them first, run  netsh int tcp show global
echo  and  netsh int tcp show heuristics  ^(show global does not list the heuristics setting^).
echo  Optionally disable Nagle / delayed-ACK on current adapters (lower latency), and
echo  stop Delivery Optimization uploading Windows Update files to other PCs ^(both backed up^).
echo ==================================================================================================
set "_c="
set /p "_c=Apply TCP tweaks? (Y/N): "
if /i not "!_c!"=="Y" goto MenuNetwork
set "_FAILS=0" & set "_RUNTRACK=1"
call :DoNetworkCore
set "_nag="
set /p "_nag=Also disable Nagle/delayed-ACK on current adapters? (Y/N): "
if /i not "!_nag!"=="Y" goto _netNagDone
call :DoNagleOff

:_netNagDone
set "_dopt="
set /p "_dopt=Also stop sharing Windows Update downloads with other PCs (Delivery Optimization)? (Y/N): "
if /i "!_dopt!"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" REG_DWORD 0 "Delivery Optimization: no peer sharing"
call :Summary "TCP tweaks applied."
pause
goto MenuNetwork

:DoNetworkCore
call :Run "netsh int tcp set global autotuninglevel=normal"
call :Run "netsh int tcp set heuristics disabled"
call :Run "netsh int tcp set global rss=enabled"
call :Run "netsh int tcp set global rsc=enabled"
goto :eof
rem =====================================================================================
rem  ACTION: Reset network stack
rem =====================================================================================
:NetReset
cls
call :Logo
echo =====================================  Reset network stack  ======================================
echo  Resets TCP/IP and Winsock, flushes DNS, releases/renews IP. Brief connectivity loss.
echo  This cannot be undone: custom Winsock providers ^(some VPN / security software^) may need
echo  a repair, and static IP settings must be re-entered.
echo ==================================================================================================
set "_c="
set /p "_c=Proceed? (Y/N): "
if /i not "!_c!"=="Y" goto MenuNetwork
set "_FAILS=0" & set "_RUNTRACK=1"
call :Run "ipconfig /flushdns"
call :Run "netsh winsock reset"
call :Run "netsh int ip reset"
call :Run "ipconfig /release"
call :Run "ipconfig /renew"
call :Summary "Network stack reset. Reboot recommended."
pause
goto MenuNetwork
rem =====================================================================================
rem  ACTION: DNS options
rem =====================================================================================
:FlushDns
cls
call :Logo
echo ===================================  Flush DNS resolver cache  ===================================
echo  Clears cached name lookups only. No adapter, stack or DNS-server change - this is
echo  the "a site moved and Windows is still using the old address" fix, and it is what
echo  you want far more often than a full stack reset.
echo ==================================================================================================
set "_FAILS=0" & set "_RUNTRACK=1"
call :Run "ipconfig /flushdns"
call :Summary "DNS resolver cache flushed."
pause
goto MenuNetwork

:ShowCurrentDns
rem  Lists hand-typed DNS servers per adapter, since no undo file keeps them. Reads the Tcpip keys,
rem  not localized netsh text; values with no current adapter are counted. No IPv4 key path means
rem  the read failed, so warn rather than claim none. reg only: this runs on every menu draw.
set "_scdAny=" & set "_scdSeen=" & set "_scdSkip=0"
call :Utf8On
set "_scdFam=IPv4"
set "_scdRoot=HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
call :_scdScan
rem  _scdKey is defined only if the IPv4 scan printed at least one key path.
if defined _scdKey set "_scdSeen=1"
set "_scdFam=IPv6"
set "_scdRoot=HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces"
call :_scdScan
if not defined _scdSeen echo  [WARN] Could not read the IPv4 DNS settings from the registry, so they are not listed.
if not defined _scdSeen echo         Note your DNS servers in Windows' network settings before changing anything.
if defined _scdSeen if not defined _scdAny if "!_scdSkip!"=="0" echo  DNS servers typed in by hand: none - every adapter gets its DNS from DHCP.
if defined _scdSeen if not defined _scdAny if not "!_scdSkip!"=="0" echo  DNS servers typed in by hand: none on a current adapter. Not shown: !_scdSkip! stored for no
if defined _scdSeen if not defined _scdAny if not "!_scdSkip!"=="0" echo  adapter in Network Connections now ^(removed adapters, per-network records^).
if defined _scdAny if not "!_scdSkip!"=="0" echo    ^(not shown: !_scdSkip! stored for no adapter in Network Connections now^)
set "_scdRoot=" & set "_scdFam=" & set "_scdKey=" & set "_scdVal=" & set "_scdGuid=" & set "_scdName=" & set "_scdT1="
set "_scdAny=" & set "_scdSeen=" & set "_scdSkip="
call :Utf8Off
goto :eof

:_scdScan
rem  In: _scdRoot, _scdFam. The last key path printed owns the next NameServer line. The value
rem  is registry data: pass it in a variable, never as a call argument.
set "_scdKey="
for /f "tokens=1,2,*" %%A in ('reg query "!_scdRoot!" /s /v NameServer 2^>nul') do (
    set "_scdT1=%%A"
    if /i "!_scdT1:~0,5!"=="HKEY_" set "_scdKey=%%A"
    if /i "%%A"=="NameServer" if /i "%%B"=="REG_SZ" if not "%%C"=="" (
        set "_scdVal=%%C"
        call :_scdShow
    )
)
goto :eof

:_scdShow
rem  In: _scdKey, _scdVal, _scdFam. Prints family, servers and adapter name; a key with no
rem  Network Connections name is counted in _scdSkip instead.
if not defined _scdKey goto :eof
call :_scdTrim
if not defined _scdVal goto :eof
set "_scdGuid=!_scdKey:*\Interfaces\=!"
set "_scdName="
for /f "tokens=1,2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}\!_scdGuid!\Connection" /v Name 2^>nul') do if /i "%%A"=="Name" if /i "%%B"=="REG_SZ" set "_scdName=%%C"
if not defined _scdName set /a _scdSkip+=1
if not defined _scdName goto :eof
if not defined _scdAny echo  DNS servers typed in by hand, per adapter - write down any you want to keep:
set "_scdAny=1"
echo    !_scdFam!  !_scdVal!   ^(!_scdName!^)
goto :eof

:_scdTrim
rem  Drops trailing spaces so the adapter name follows the addresses.
if not defined _scdVal goto :eof
if not "!_scdVal:~-1!"==" " goto :eof
set "_scdVal=!_scdVal:~0,-1!"
goto _scdTrim

:Utf8On
rem  Console to UTF-8 while reg output or a worker's UTF-8 file is read, so non-ASCII names survive;
rem  echo shows them either way. Saves the code page for :Utf8Off; does nothing if chcp is unreadable.
if defined _cpSaved goto :eof
set "_cpRaw="
for /f "tokens=2 delims=:" %%p in ('chcp') do set "_cpRaw=%%p"
if defined _cpRaw set "_cpRaw=!_cpRaw: =!"
if defined _cpRaw set "_cpRaw=!_cpRaw:.=!"
if not defined _cpRaw goto :eof
set "_cpBad="
for /f "eol=0 delims=0123456789" %%c in ("!_cpRaw!") do set "_cpBad=1"
if defined _cpBad goto :eof
if "!_cpRaw!"=="65001" goto :eof
set "_cpSaved=!_cpRaw!"
chcp 65001 >nul
goto :eof

:Utf8Off
if not defined _cpSaved goto :eof
chcp !_cpSaved! >nul
set "_cpSaved="
goto :eof

:_ip4_ok
rem  Validates !_IPCHK! as a dotted-quad IPv4 address; errorlevel 1 if it is not one.
rem  Pure batch only: never pipe the value into findstr, since a pipe re-parses it.
rem  eol must be an allowed character: with the default semicolon a crafted value skips the loop.
set "_ipbad="
for /f "eol=0 delims=0123456789." %%X in ("!_IPCHK!") do set "_ipbad=1"
if defined _ipbad exit /b 1
rem  Reject zero-padded octets before the range test: IF reads them as octal or as text.
set "_ipz="
for /f "tokens=1-4 delims=." %%a in ("!_IPCHK!") do for %%o in (%%a %%b %%c %%d) do (
    set "_ipoct=%%o"
    if not "!_ipoct!"=="0" if "!_ipoct:~0,1!"=="0" set "_ipz=1"
)
if defined _ipz exit /b 1
set "_ipok="
rem  Test the fourth token for empty first, or 1.2.3. would rebuild to itself and pass.
for /f "tokens=1-4 delims=." %%a in ("!_IPCHK!") do if not "%%d"=="" if "%%a.%%b.%%c.%%d"=="!_IPCHK!" if %%a LEQ 255 if %%b LEQ 255 if %%c LEQ 255 if %%d LEQ 255 set "_ipok=1"
if not defined _ipok exit /b 1
exit /b 0

:DnsCustom
cls
call :Logo
echo ======================================  Custom DNS server  =======================================
echo  Enter an IPv4 resolver of your own - a router, a Pi-hole, NextDNS, a corporate
echo  server, or a provider not listed on the previous screen.
echo.
echo  IPv4 only: no IPv6 server is set here. With IPv6 active, Windows may also use an IPv6
echo  DNS server, so not every lookup has to go through the one you enter.
echo  Option 4 on the previous screen goes back to DHCP - it does not bring back a server you
echo  had typed in before, so note the list below first.
echo ==================================================================================================
call :ShowCurrentDns
echo.
set "_dns1="
set /p "_dns1=Primary resolver (blank = cancel): "
if not defined _dns1 goto MenuDns
set "_IPCHK=!_dns1!"
call :_ip4_ok || (
    echo.
    echo [FAIL] Not an IPv4 address. Four numbers 0-255 separated by dots, e.g. 192.168.1.1
    pause
    goto DnsCustom
)
set "_dns2="
set /p "_dns2=Secondary resolver (optional, blank = none): "
if not defined _dns2 goto _dnsCustGo
set "_IPCHK=!_dns2!"
call :_ip4_ok || (
    echo.
    echo [FAIL] Not an IPv4 address. Leave it blank if you only want one resolver.
    pause
    goto DnsCustom
)

:_dnsCustGo
rem  Built only from values that passed :_ip4_ok, so DNSSRV is safe in the PowerShell call.
if defined _dns2 set "DNSSRV='!_dns1!','!_dns2!'"
if not defined _dns2 set "DNSSRV='!_dns1!'"
echo.
call :ApplyDns "Custom (!_dns1!)"
pause
goto MenuDns

:DnsCloudflare
set "DNSSRV='1.1.1.1','1.0.0.1','2606:4700:4700::1111','2606:4700:4700::1001'"
cls
call :Logo
call :ApplyDns "Cloudflare"
pause
goto MenuDns

:DnsGoogle
set "DNSSRV='8.8.8.8','8.8.4.4','2001:4860:4860::8888','2001:4860:4860::8844'"
cls
call :Logo
call :ApplyDns "Google"
pause
goto MenuDns

:DnsQuad9
set "DNSSRV='9.9.9.9','149.112.112.112','2620:fe::fe','2620:fe::9'"
cls
call :Logo
call :ApplyDns "Quad9"
pause
goto MenuDns

:DnsAuto
cls
call :Logo
echo Reverting DNS to automatic (DHCP) on every physical adapter...
call :Log "DNS -> automatic (DHCP)"
set "_dnsres=!TEMP!\pt_dnsres_%RANDOM%.txt"
del "!_dnsres!" >nul 2>&1
set "PT_DNSRES=!_dnsres!"
start "" /min /wait powershell -NoProfile -Command "$ok=0;$fail=0;Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { try { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction Stop; $ok++ } catch { $fail++ } }; ('' + $ok + ' ' + $fail) | Out-File -FilePath $env:PT_DNSRES -Encoding ASCII; if($ok -gt 0){exit 0}else{exit 1}"
set "_dnsrc=%errorlevel%"
set "PT_DNSRES="
ipconfig /flushdns >nul 2>&1
call :DnsResult "%_dnsrc%" "DNS reset to automatic (DHCP)"
pause
goto MenuDns
rem =====================================================================================
rem  ACTION: OpenAsar
rem =====================================================================================
:OpenAsar
cls
call :Logo
echo =======================================  Install OpenAsar  =======================================
echo  Replaces Discord's app.asar in app-VERSION\resources\. Uses the bundled app.asar
echo  next to this script, or downloads the latest nightly. If a mod renamed the original
echo  to _app.asar / app.orig.asar / app.asar.orig, THAT is replaced (OpenAsar loads under
echo  the mod). Handles Discord / PTB / Canary. A Discord update can revert it - re-run.
echo ==================================================================================================
set "_SRC="
if exist "!SCRIPT_DIR!app.asar" set "_SRC=!SCRIPT_DIR!app.asar"
if defined _SRC goto OA_HaveSrc
echo Local app.asar not found next to this script.
set "_dl="
set /p "_dl=Download the latest OpenAsar (nightly) from GitHub instead? (Y/N): "
if /i not "!_dl!"=="Y" goto MenuApps
echo Downloading OpenAsar nightly...
rem  Per-run filename, so two windows downloading at once never share a partial file.
set "_OADL=!TEMP!\openasar_nightly_%RANDOM%%RANDOM%.asar"
set "PT_OADL=!_OADL!"
start "" /min /wait powershell -NoProfile -Command "try{Invoke-WebRequest -Uri 'https://github.com/GooseMod/OpenAsar/releases/download/nightly/app.asar' -OutFile $env:PT_OADL -UseBasicParsing}catch{exit 1}"
rem  Capture the exit code before anything else runs: del always resets errorlevel to 0.
set "_dlrc=%errorlevel%"
set "PT_OADL="
if not "%_dlrc%"=="0" del "!_OADL!" >nul 2>&1
if not "%_dlrc%"=="0" goto OA_DlFail
if not exist "!_OADL!" goto OA_DlFail
set "_SRC=!_OADL!"

:OA_HaveSrc
set "_c="
set /p "_c=Close Discord and continue? (Y/N): "
if /i not "!_c!"=="Y" goto MenuApps
taskkill /f /im Discord.exe       >nul 2>&1
taskkill /f /im DiscordPTB.exe    >nul 2>&1
taskkill /f /im DiscordCanary.exe >nul 2>&1
timeout /t 3 >nul 2>&1
set "_DONE=0"
set "_OAFAIL=0"
for %%F in (Discord DiscordPTB DiscordCanary) do if exist "!LocalAppData!\%%F\" call :InstallAsarInto "%%F"
rem  Delete only the downloaded nightly; a bundled app.asar is the user's file and must stay.
if defined _OADL if exist "!_OADL!" del /f /q "!_OADL!" >nul 2>&1
set "_OADL="
if "%_DONE%"=="0" (
    echo [ERROR] No Discord install was updated. Either none has a resources\app.asar ^(Store
    echo         version unsupported^), or Discord was still running - fully quit it and re-run.
    pause
    goto MenuApps
)
echo.
rem  _DONE means at least one flavor succeeded, so report any that failed.
if not "%_OAFAIL%"=="0" echo [WARN] %_OAFAIL% Discord install^(s^) could NOT be updated - see the lines above.
echo Reopening Discord...
if exist "!LocalAppData!\Discord\Update.exe" start "" "!LocalAppData!\Discord\Update.exe" --processStart Discord.exe
echo Check Settings at the bottom of the left sidebar for an "OpenAsar" entry.
echo To revert: restore the .bak file over the replaced .asar, or reinstall Discord.
pause
goto MenuApps

:OA_DlFail
echo [ERROR] Download failed (no internet, or GitHub is blocked here).
echo         Put OpenAsar's app.asar next to this script and re-run (openasar.dev).
pause
goto MenuApps
rem =====================================================================================
rem  ACTION: Unity boot.config
rem =====================================================================================
:UnityBoot
cls
call :Logo
echo ======================================  Unity boot.config  =======================================
echo  Copies the bundled boot.config into a Unity game's *_Data folder, tuned for your
echo  CPU (job-worker-count). Per-game; restore boot.config.bak from that folder if needed.
echo ==================================================================================================
call :RequireBundledFile boot.config "Unity engine boot configuration"
if errorlevel 1 goto MenuApps
call :DetectUnityJobWorkers
echo.
echo   Detected: !_CORESRC!
echo   Setting job-worker-count / job-worker-maximum-count to !_JWCOUNT! (logical CPUs minus one).
echo.
echo Paste the game's *_Data folder path (or drag the folder here), then Enter:
set "_gd="
set /p "_gd=Path: "
rem  Test if defined first: substituting on an unset _gd leaves junk text in it.
if defined _gd set "_gd=!_gd:"=!"
if not defined _gd (
    echo.
    echo [ERROR] No folder path entered.
    echo         Paste the full path to the game's *_Data folder and try again.
    call :Log "ABORT: Unity boot.config - empty path"
    pause
    goto MenuApps
)
if "!_gd:~-1!"=="\" set "_gd=!_gd:~0,-1!"
set "_boottmp=!TEMP!\PerfTweaks_boot_%RANDOM%.config"
set "PT_SRC=!SCRIPT_DIR!boot.config"
set "PT_OUT=!_boottmp!"
set "PT_JW=!_JWCOUNT!"
call :PrepareBootConfig
if errorlevel 1 (
    echo.
    echo [ERROR] Could not prepare boot.config with job-worker-count=!_JWCOUNT!.
    echo   Check that the bundled boot.config is readable and try again.
    call :Log "FAIL: PrepareBootConfig workers=!_JWCOUNT!"
    if exist "!_boottmp!" del /f /q "!_boottmp!" >nul 2>&1
    pause
    goto MenuApps
)
rem  pushd into the folder and copy to the bare name, so no command gets a path with spaces.
pushd "!_gd!" 2>nul
if errorlevel 1 (
    echo.
    echo [ERROR] Folder not found or not accessible:
    echo         "!_gd!"
    echo   Check the path and make sure you selected the game's *_Data folder.
    call :Log "ABORT: Unity boot.config - cannot enter path"
    if exist "!_boottmp!" del /f /q "!_boottmp!" >nul 2>&1
    pause
    goto MenuApps
)
set "_ubbak=0"
if exist "boot.config" (
    rem  Write-once backup; the check below aborts if none landed, so the original survives.
    if not exist "boot.config.bak" copy /y "boot.config" "boot.config.bak" >nul 2>&1
    if exist "boot.config.bak" set "_ubbak=1"
)
if exist "boot.config" if "!_ubbak!"=="0" (
    popd
    del /f /q "!_boottmp!" >nul 2>&1
    echo.
    echo [ERROR] Could not back up the existing boot.config in:
    echo         "!_gd!"
    echo   Aborting so the game's original is NOT overwritten without a backup. The folder
    echo   may be read-only, or the game is running.
    call :Log "ABORT: Unity boot.config - no backup landed, original left intact"
    pause
    goto MenuApps
)
copy /y "!_boottmp!" "boot.config" >nul
set "_copyerr=!errorlevel!"
popd
del /f /q "!_boottmp!" >nul 2>&1
if !_copyerr! geq 1 goto _ubCopyFail
echo [OK] boot.config placed with job-worker-count=!_JWCOUNT! ^(!_CORESRC!^).
if "!_ubbak!"=="1" echo      The original boot.config is saved beside it as boot.config.bak
call :Log "OK: Unity boot.config -> !_gd! workers=!_JWCOUNT!"
pause
goto MenuApps

:_ubCopyFail
echo.
echo [ERROR] Could not write boot.config into:
echo         "!_gd!"
echo   The folder may be read-only, or boot.config is locked by the running game.
echo   Close the game, run PerfTweaks as administrator, then try again.
call :Log "FAIL: Unity boot.config copy to !_gd!"
pause
goto MenuApps
rem =====================================================================================
:SteamLight
cls
call :Logo
echo ==========================================  SteamLight  ==========================================
echo  Finds your Steam folder, writes a "SteamLight.bat" launcher there, and adds a
echo  Desktop shortcut. SteamLight starts Steam with flags that cut RAM/CPU use
echo  (single core, no shaders, no Big Picture, etc.) for a lighter, faster Steam.
echo ==================================================================================================
rem  --- locate the Steam install folder (machine-wide first, then per-user) ---
set "_STEAMDIR="
for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\WOW6432Node\Valve\Steam" /v InstallPath 2^>nul ^| findstr /I "InstallPath"') do set "_STEAMDIR=%%b"
if not defined _STEAMDIR for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Valve\Steam" /v InstallPath 2^>nul ^| findstr /I "InstallPath"') do set "_STEAMDIR=%%b"
if not defined _STEAMDIR for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| findstr /I "SteamPath"') do set "_STEAMDIR=%%b"
if defined _STEAMDIR set "_STEAMDIR=!_STEAMDIR:/=\!"
if not defined _STEAMDIR (
    echo [ERROR] Could not find Steam in the registry. Is Steam installed?
    pause
    goto MenuApps
)
if not exist "!_STEAMDIR!\steam.exe" (
    echo [ERROR] Found a Steam path but no steam.exe there:
    echo         "!_STEAMDIR!"
    pause
    goto MenuApps
)
echo Steam folder: "!_STEAMDIR!"
echo.
set "_c="
set /p "_c=Install SteamLight here and add a Desktop shortcut? [Y/N]: "
if /i not "!_c!"=="Y" goto MenuApps
rem  Steam launch flags. -cef-single-process disables the sandbox too: keep it in the opt-in below.
set "_SLFLAGS=-dev -console -nofriendsui -no-dwrite -nointro -nobigpicture -nofasthtml -nocrashmonitor -noshaders -no-shared-textures -disablehighdpi -cef-in-process-gpu -single_core -cef-disable-d3d11 -disable-winh264 -vrdisable -cef-disable-breakpad"
echo.
echo  One more option saves the most memory: running Steam's web pages in a single process.
echo  It also turns off the sandbox that keeps a compromised store or community page away
echo  from the rest of your PC, so it stays off unless you choose it.
set "_slsp="
set /p "_slsp=Run Steam's web pages in one process, without the sandbox? (Y/N): "
if /i "!_slsp!"=="Y" set "_SLFLAGS=!_SLFLAGS! -cef-single-process -cef-disable-sandbox -no-cef-sandbox"
rem  The launcher lives in the Steam folder and starts the steam.exe beside it.
> "!_STEAMDIR!\SteamLight.bat" echo @echo off
>>"!_STEAMDIR!\SteamLight.bat" echo taskkill /f /im steam.exe ^>nul 2^>^&1
>>"!_STEAMDIR!\SteamLight.bat" echo start "" "%%~dp0steam.exe" !_SLFLAGS!
if exist "!_STEAMDIR!\SteamLight.bat" goto _slWritten
echo [ERROR] Could not write SteamLight.bat into the Steam folder - is it writable? Try running as administrator.
call :Log "FAIL: SteamLight.bat could not be written to !_STEAMDIR!"
pause
goto MenuApps

:_slWritten
call :Log "SteamLight written to !_STEAMDIR!\SteamLight.bat"
echo   ^> Creating Desktop shortcut...
rem  Path goes in via env var so an apostrophe cannot break the PS string; exit 1 if no .lnk.
set "PT_SLDIR=!_STEAMDIR!"
start "" /min /wait powershell -NoProfile -Command "$sd=$env:PT_SLDIR; $d=[Environment]::GetFolderPath('Desktop'); $lnk=Join-Path $d 'SteamLight.lnk'; $w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($lnk); $s.TargetPath=(Join-Path $sd 'SteamLight.bat'); $s.WorkingDirectory=$sd; $s.WindowStyle=7; $s.IconLocation=((Join-Path $sd 'steam.exe')+',0'); $s.Description='Launch Steam in lightweight mode'; $s.Save(); if(-not (Test-Path -LiteralPath $lnk)){ exit 1 }"
rem  Capture errorlevel before the next set: in a .cmd a successful set resets it to 0.
set "_slrc=%errorlevel%"
set "PT_SLDIR="
if not "%_slrc%"=="0" (
    echo [OK] SteamLight installed in the Steam folder.
    echo [WARN] Desktop shortcut was not created ^(COM / Desktop redirect / permissions^).
    call :Log "SteamLight: bat OK, Desktop shortcut failed"
) else (
    echo [OK] SteamLight installed in the Steam folder, and a shortcut was placed on your Desktop.
    call :Log "SteamLight desktop shortcut created"
)
echo      First launch restarts Steam, so it may take a moment.
pause
goto MenuApps
rem =====================================================================================
rem  ACTION: Apply hosts
rem =====================================================================================
:ApplyHosts
cls
call :Logo
echo ===================================  Apply custom hosts file  ====================================
echo  Replaces the system hosts file with the bundled blocklist (entries point to 0.0.0.0).
echo  The current hosts is copied into the backup folder first; the first run also keeps the
echo  original beside it as hosts.bak, which later runs never overwrite. DNS is flushed.
echo ==================================================================================================
set "_HOSTS=%SystemRoot%\System32\drivers\etc\hosts"
call :RequireBundledFile hosts "ad/telemetry blocklist for the system hosts file"
if errorlevel 1 goto MenuApps
set "_c="
set /p "_c=Proceed? (Y/N): "
if /i not "!_c!"=="Y" goto MenuApps
set "_hbak=0"
if exist "%_HOSTS%" (
    set "_hbakdoc=!BACKUP_DIR!\hosts_%RANDOM%%RANDOM%.bak"
    rem  hosts.bak is write-once, the pristine original; the backup-folder copy is per run.
    rem  Either one satisfies _hbak on purpose: an existing pristine hosts.bak is the better undo.
    if not exist "%_HOSTS%.bak" copy /y "%_HOSTS%" "%_HOSTS%.bak" >nul 2>&1
    copy /y "%_HOSTS%" "!_hbakdoc!" >nul 2>&1 && set "_hbak=1"
    if exist "%_HOSTS%.bak" set "_hbak=1"
    call :Log "hosts backup made (hbak=!_hbak!)"
)
if exist "%_HOSTS%" if "!_hbak!"=="0" (
    echo.
    echo [ERROR] Could not back up the current hosts file ^(AV / Controlled Folder Access / read-only^).
    echo         Aborting so your existing hosts is NOT overwritten without a backup. Allow writes to
    echo         hosts or the backup folder, then re-run this action.
    call :Log "ABORT: hosts apply - no backup written, existing hosts left intact"
    pause
    goto MenuApps
)
copy /y "!SCRIPT_DIR!hosts" "%_HOSTS%" >nul
if errorlevel 1 (
    echo.
    echo [ERROR] Could not replace the system hosts file:
    echo         "%_HOSTS%"
    echo   Common causes: Defender tamper protection, a third-party AV web-shield, or the
    echo   file is read-only. Temporarily allow edits to hosts, then re-run this action.
    call :Log "FAIL: apply hosts -> %_HOSTS%"
) else (
    echo [OK] hosts replaced. The original is backed up ^(hosts.bak beside it, and/or the backup folder^).
    set "_LOGMSG=OK: hosts applied from !SCRIPT_DIR!hosts" & call :LogVar _LOGMSG
    call :Run "ipconfig /flushdns"
)
pause
goto MenuApps
rem =====================================================================================
rem  ACTION: Restore / reset hosts
rem =====================================================================================
:RestoreHosts
cls
call :Logo
echo ====================================  Restore / reset hosts  =====================================
echo     1.  Restore from backup (hosts.bak, or Documents hosts_*.bak)
echo     2.  Reset to a clean Windows default (un-blocks everything)
echo     0.  Back
echo ==================================================================================================
set "_HOSTS=%SystemRoot%\System32\drivers\etc\hosts"

:RestoreHosts_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto RestoreHosts_ask
if "!sel!"=="1" goto RestoreHostsBak
if "!sel!"=="2" goto ResetHostsDefault
if "!sel!"=="0" goto MenuApps
goto RestoreHosts

:RestoreHostsBak
set "_hsrc="
if exist "%_HOSTS%.bak" set "_hsrc=%_HOSTS%.bak"
if not defined _hsrc (
    rem  Oldest snapshot by creation time is closest to the original; copy keeps last-write time.
    for /f "delims=" %%F in ('dir /b /od /tc "!BACKUP_DIR!\hosts_*.bak" 2^>nul') do (
        if not defined _hsrc set "_hsrc=!BACKUP_DIR!\%%F"
    )
)
if not defined _hsrc (
    echo [ERROR] No hosts backup found at "%_HOSTS%.bak" or in "!BACKUP_DIR!\hosts_*.bak".
    echo         Use option 2 to reset to a clean Windows default.
    pause
    goto RestoreHosts
)
echo   Restoring from: !_hsrc!
copy /y "!_hsrc!" "%_HOSTS%" >nul
if errorlevel 1 ( echo [WARN] Restore failed ^(AV tamper protection?^). ) else ( echo [OK] hosts restored from backup. & call :Run "ipconfig /flushdns" )
pause
goto MenuApps

:ResetHostsDefault
rem  Never overwrite without a landed backup; clear stale _hbakdoc/_hbnew for the final message.
set "_hbakdoc="
set "_hbnew="
set "_hbak=0"
if exist "%_HOSTS%" (
    rem  hosts.bak stays write-once; the backup-folder snapshot keeps a reset recoverable.
    set "_hbakdoc=!BACKUP_DIR!\hosts_%RANDOM%%RANDOM%.bak"
    if not exist "%_HOSTS%.bak" copy /y "%_HOSTS%" "%_HOSTS%.bak" >nul 2>&1 && set "_hbnew=1"
    copy /y "%_HOSTS%" "!_hbakdoc!" >nul 2>&1 && set "_hbak=1"
    if exist "%_HOSTS%.bak" set "_hbak=1"
    if "!_hbak!"=="0" (
        echo.
        echo [ERROR] Could not back up the current hosts file ^(AV / Controlled Folder Access / read-only^).
        echo         Aborting so your existing hosts is NOT overwritten without a backup.
        call :Log "ABORT: hosts reset - no backup written, existing hosts left intact"
        pause
        goto RestoreHosts
    )
)
(
echo # Copyright ^(c^) 1993-2009 Microsoft Corp.
echo #
echo # This is a sample HOSTS file used by Microsoft TCP/IP for Windows.
echo #
echo # This file contains the mappings of IP addresses to host names. Each
echo # entry should be kept on an individual line. The IP address should
echo # be placed in the first column followed by the corresponding host name.
echo #
echo # localhost name resolution is handled within DNS itself.
echo #	127.0.0.1       localhost
echo #	::1             localhost
) > "%_HOSTS%"
if errorlevel 1 (
    echo [WARN] Reset failed ^(AV tamper protection?^).
) else (
    echo [OK] hosts reset to Windows default.
    if defined _hbakdoc if exist "!_hbakdoc!" echo      The file it replaced is saved as !_hbakdoc!
    if defined _hbakdoc if not exist "!_hbakdoc!" if defined _hbnew echo      The file it replaced is saved as hosts.bak, beside it.
    if defined _hbakdoc if not exist "!_hbakdoc!" if not defined _hbnew echo      The file it replaced could NOT be saved - only the oldest original, hosts.bak, remains.
    if exist "%_HOSTS%.bak" echo      The oldest original is kept as hosts.bak ^(Restore / reset hosts ^> 1 brings it back^).
    call :Run "ipconfig /flushdns"
)
pause
goto MenuApps
rem =====================================================================================
rem  ACTION: Disable / enable CPU mitigations
rem =====================================================================================
:DisableMitigations
cls
call :Logo
echo ===============================  Disable CPU mitigations (RISKY)  ================================
echo  Disables Spectre/Meltdown/MDS/SSBD/L1TF ^(bits 0-1^) AND Downfall/GDS ^(bit 25^).
echo  Can improve CPU performance but REDUCES security. Undo: option 2 ^(the secure default^).
echo  For the exact values you had: Backups ^& status ^> Restore a single value backup, the two
echo  ...Memory_Management_*.reg files written at this step - other changes share that name, so
echo  open one in Notepad to see which value it holds.
echo  Per Microsoft KB5029778 Downfall/GDS DOES have its own bit ^(0x2000000^); the older
echo  "3" alone left it mitigated. Combined value is 0x2000003 ^(decimal 33554435^), and
echo  the mask must cover the same bits or the extra bit is written but ignored.
echo  Verify after reboot: PowerShell ^> Get-SpeculationControlSettings
echo ==================================================================================================
set "_rp=Y"
set /p "_rp=Create a restore point first? (Y/N): "
if /i "!_rp!"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Disable mitigations now? (Y/N): "
if /i not "!_c!"=="Y" goto MenuAdvanced
set "_FAILS=0"
:: 0x2000003 = bits 0-1 Spectre/Meltdown/MDS/SSBD/L1TF + bit 25 Downfall/GDS. The mask needs
:: the same bits or Windows ignores bit 25. Decimal, since :SafeRegAdd compares with set /a.
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "FeatureSettingsOverride" REG_DWORD 33554435 "Disable CPU mitigations (Spectre/Meltdown + Downfall)"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "FeatureSettingsOverrideMask" REG_DWORD 33554435 "Mitigations override mask (covers Downfall bit)"
call :Summary "Mitigations disabled (incl. Downfall/GDS). REBOOT required."
pause
goto MenuAdvanced

:EnableMitigations
cls
call :Logo
echo ==============================  Re-enable CPU mitigations (secure)  ==============================
set "_FAILS=0"
:: Override=0 turns all mitigations back on; the mask still covers the Downfall bit 25.
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "FeatureSettingsOverride" REG_DWORD 0 "Re-enable CPU mitigations (incl. Downfall)"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "FeatureSettingsOverrideMask" REG_DWORD 33554435 "Mitigations override mask (covers Downfall bit)"
call :Summary "Mitigations restored to secure default (incl. Downfall/GDS). REBOOT required."
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: BCDEdit timer tweaks
rem =====================================================================================
:BcdTimers
cls
call :Logo
echo =====================================  BCDEdit timer tweaks  =====================================
echo  Removes the forced platform clock, forces the platform tick, disables dynamic tick
echo  and sets TSC sync = enhanced (the BCD timer combo from the optimization guide).
echo  Can help timer-sensitive workloads. REBOOT required. Option 4 puts all four back to the
echo  Windows defaults - a value you had set yourself before is not saved by sincript.
echo ==================================================================================================
call :LaptopAdvisory
set "_c="
set /p "_c=Apply timer tweaks? (Y/N): "
if /i not "!_c!"=="Y" goto MenuAdvanced
set "_FAILS=0" & set "_RUNTRACK=1"
call :Run "bcdedit /deletevalue useplatformclock"
call :Run "bcdedit /set useplatformtick yes"
call :Run "bcdedit /set disabledynamictick yes"
call :Run "bcdedit /set tscsyncpolicy enhanced"
call :Summary "Timer tweaks applied. REBOOT required."
pause
goto MenuAdvanced

:BcdRevert
cls
call :Logo
echo ====================================  Revert BCDEdit timers  =====================================
set "_FAILS=0" & set "_RUNTRACK=1"
call :Run "bcdedit /deletevalue useplatformclock"
call :Run "bcdedit /deletevalue useplatformtick"
call :Run "bcdedit /deletevalue disabledynamictick"
call :Run "bcdedit /deletevalue tscsyncpolicy"
call :Summary "Timer settings reverted to defaults. REBOOT required."
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: NVMe flags
rem =====================================================================================
:NvmeFlags
cls
call :Logo
echo ================================  Experimental NVMe driver flags  ================================
echo  Toggles feature flags for Microsoft's in-box NVMe driver (StorNVMe). NOTE: Microsoft
echo  blocked these on fully-patched systems in 2026, so on an updated PC this likely does
echo  nothing now. Only relevant if your SSD uses the in-box driver. Where it did take effect,
echo  some drives and disk tools misbehaved. Undo: Backups ^& status ^> Restore a single value
echo  backup, the four ...FeatureManagement_Overrides_*.reg files ^(one per flag^), then reboot.
echo ==================================================================================================
set "_rp=Y"
set /p "_rp=Create a restore point first? (Y/N): "
if /i "!_rp!"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Apply NVMe flags? (Y/N): "
if /i not "!_c!"=="Y" goto MenuAdvanced
set "_FAILS=0"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "1176759950" REG_DWORD 1 "NVMe flag 1"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "1853569164" REG_DWORD 1 "NVMe flag 2"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "156965516" REG_DWORD 1 "NVMe flag 3"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "735209102" REG_DWORD 1 "NVMe flag 4"
call :Summary "NVMe flags written. REBOOT required."
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: Disable IPv6
rem =====================================================================================
:DisableIPv6
cls
call :Logo
echo =========================================  Disable IPv6  =========================================
echo  Sets DisabledComponents=0xFF (disables IPv6 on all interfaces). Do this only if you
echo  know you don't need IPv6. REBOOT needed. To revert: Backups ^& status ^> Restore a
echo  single value backup ^(it holds the DisabledComponents value you had^), or set it to 0.
echo ==================================================================================================
set "_c="
set /p "_c=Disable IPv6? (Y/N): "
if /i not "!_c!"=="Y" goto MenuAdvanced
set "_FAILS=0"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" "DisabledComponents" REG_DWORD 255 "Disable IPv6 (0xFF)"
call :Summary "IPv6 disabled. REBOOT required."
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: Memory compression
rem =====================================================================================
:MemCompress
cls
call :Logo
echo ============================  Disable memory compression / combining  ============================
echo  Turns off RAM compression and page combining. Frees a little CPU at the cost of more
echo  RAM pressure on low-memory PCs. This turns BOTH off, so the undo needs both switches:
echo  Re-enable: PowerShell ^> Enable-MMAgent -MemoryCompression -PageCombining
echo ==================================================================================================
set "_c="
set /p "_c=Disable memory compression and page combining? (Y/N): "
if /i not "!_c!"=="Y" goto MenuAdvanced
rem  PowerShell runs in a separate minimized window: inside this one it changes the console font.
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - memory compression was NOT changed. Re-run as Administrator.
    pause
    goto MenuAdvanced
)
echo   ^> Disabling memory compression and page combining...
call :Log "EXEC-PS (isolated): Disable-MMAgent -MemoryCompression / -PageCombining"
rem  One try per switch; exit code 1 = memory compression failed, 2 = page combining, 3 = both.
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $e=0; try{ Disable-MMAgent -MemoryCompression }catch{ $e+=1 }; try{ Disable-MMAgent -PageCombining }catch{ $e+=2 }; exit $e"
set "_mmrc=%errorlevel%"
if "%_mmrc%"=="0" (
    echo [OK] Memory compression and page combining disabled. REBOOT to fully apply.
    call :Log "OK: Disable-MMAgent"
) else if "%_mmrc%"=="1" (
    echo [WARN] Page combining was disabled, but memory compression could NOT be. REBOOT to apply
    echo        the change that worked.
    call :Log "FAIL: Disable-MMAgent -MemoryCompression (page combining OK)"
) else if "%_mmrc%"=="2" (
    echo [WARN] Memory compression was disabled, but page combining could NOT be. REBOOT to apply
    echo        the change that worked.
    call :Log "FAIL: Disable-MMAgent -PageCombining (memory compression OK)"
) else (
    echo [ERROR] Memory compression / page combining could not be disabled. Reboot and re-run as Administrator.
    call :Log "FAIL: Disable-MMAgent"
)
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: GPU telemetry off
rem =====================================================================================
:GpuTelemetry
cls
call :Logo
echo ==================================  GPU telemetry / tasks off  ===================================
rem  Test the vendor flags, not GPU, so a machine with both vendors is offered both.
if defined GPU_NV goto GpuNvidia
if defined GPU_AMD goto GpuAmd
echo  No NVIDIA/AMD GPU detected (or detection failed). Nothing to do here.
pause
goto MenuAdvanced

:GpuNvidia
echo  Detected NVIDIA. Disables NVIDIA telemetry tasks and background reporting only. The
echo  large undocumented GPU registry tweaks are NOT applied (they can cause crashes).
set "_c="
set /p "_c=Apply NVIDIA telemetry-off? (Y/N): "
rem  Declining NVIDIA must not skip AMD on a machine that has both.
if /i not "!_c!"=="Y" goto _gpuNvDone
set "_FAILS=0"
call :DisableNvidiaTelemetryTasks
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" "SendTelemetryData" REG_DWORD 0 "NVIDIA telemetry off"
call :SafeRegAdd "HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client" "OptInOrOutPreference" REG_DWORD 0 "NVIDIA opt-out"
call :Summary "NVIDIA telemetry / tasks disabled."

:_gpuNvDone
if defined GPU_AMD (
    echo.
    echo  This machine also has an AMD adapter - its opt-out is offered next.
    echo.
    goto GpuAmd
)
pause
goto MenuAdvanced

:GpuAmd
echo  Detected AMD. This opts you out of the AMD User Experience Program - AMD's usage-data /
echo  telemetry collection - by writing the opt-out to the registry, with a backup (reversible).
echo  No bulk undocumented AMD register tweaks are applied; those can cause instability.
set "_c="
set /p "_c=Apply AMD telemetry opt-out? (Y/N): "
if /i not "!_c!"=="Y" goto MenuAdvanced
set "_FAILS=0"
call :SafeRegAdd "HKLM\SOFTWARE\AMD\CN" "UserExperienceProgram" REG_DWORD 0 "AMD User Experience Program opt-out"
echo.
call :Summary "AMD User Experience Program opt-out written."
echo      AMD has no single guaranteed switch across driver versions, so to be sure also open
echo      AMD Software ^> Settings ^> Preferences and turn OFF: AMD User Experience Program,
echo      AMD Image Inspector, and Game Adjustment Tracking and Notifications.
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: GPU hardware scheduling (HAGS)
rem =====================================================================================
:HagsToggle
cls
call :Logo
echo ================================  GPU hardware scheduling (HAGS)  ================================
echo  HwSchMode in GraphicsDrivers: 2 = on (Windows default), 1 = off. Takes effect after a
echo  REBOOT. Needs Windows 10 2004+ and a GPU/driver that supports it - on older GPUs the
echo  setting is simply ignored. The on/off difference is usually small and system-specific;
echo  turning it OFF can help some capture/overlay stutter, but DISABLES features that need
echo  it ON - notably NVIDIA Frame Generation (DLSS 3). Backed up, so it stays reversible.
echo.
rem  Plain reg query, no PowerShell, so this draws instantly. Absent is the Windows default: on.
set "_hags="
for /f "tokens=3" %%H in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode 2^>nul ^| findstr /I "HwSchMode"') do set "_hags=%%H"
if not defined _hags        echo   Currently: HAGS is ON  ^(HwSchMode not set - the Windows default on 2004+^)
if /i "!_hags!"=="0x2"      echo   Currently: HAGS is ON   ^(HwSchMode = 2, the Windows default^)
if /i "!_hags!"=="0x1"      echo   Currently: HAGS is OFF  ^(HwSchMode = 1^)
if defined _hags if /i not "!_hags!"=="0x1" if /i not "!_hags!"=="0x2" echo   Currently: HwSchMode = !_hags! ^(not a value Windows documents^)
echo   A change here only takes effect after a REBOOT, so this line shows what is stored,
echo   not necessarily what the GPU is doing right now.
echo.
echo     1.  Turn HAGS OFF  (HwSchMode = 1)
echo     2.  Turn HAGS ON   (HwSchMode = 2, default)
echo     0.  Back
echo ==================================================================================================

:HagsToggle_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto HagsToggle_ask
if "!sel!"=="1" goto HagsOff
if "!sel!"=="2" goto HagsOn
if "!sel!"=="0" goto MenuAdvanced
goto HagsToggle_ask

:HagsOff
set "_FAILS=0"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" REG_DWORD 1 "HAGS off"
call :Summary "HAGS set OFF. Reboot for the change to take effect."
pause
goto MenuAdvanced

:HagsOn
set "_FAILS=0"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" REG_DWORD 2 "HAGS on (default)"
call :Summary "HAGS set ON (default). Reboot for the change to take effect."
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: Windows Update driver installs (one documented policy, on/off)
rem =====================================================================================
:WuDrivers
cls
call :Logo
echo ================================  Windows Update driver installs  ================================
echo  Policy "Do not include drivers with Windows Updates" ^(ExcludeWUDriversInQualityUpdate^).
echo  Blocking stops Windows Update OFFERING drivers in its update scans - GPU, Wi-Fi, chipset - and
echo  the PC maker's BIOS/UEFI firmware, which Windows Update delivers as driver packages and which
echo  can carry security fixes. Microsoft recommends leaving driver updates on. Blocking does not
echo  remove what is installed; drivers inside Windows' own updates or a feature update still come.
echo  Drivers you install yourself ^(NVIDIA / AMD / Intel / PC maker tools^) are not affected.
echo  Set in the Group Policy Editor ^(gpedit.msc^)? Change it there: it writes its own value back.
echo.
rem  Plain reg queries only; :WuDrvGpCheck starts PowerShell, so it runs only after a change.
call :WuDrvRead
call :WuDrvStateLine
echo   That is the stored value. Windows Update rereads policy when it restarts: reboot after a change.
call :WuDrvEditionNote
rem  The Policy CSP lists this policy from Windows 10 1607 (build 14393) on. Warning-only.
if defined WIN_BUILD if !WIN_BUILD! LSS 14393 echo   [ADVISORY] Microsoft lists this policy from Windows 10 1607 ^(build 14393^); this is build !WIN_BUILD!.
call :WuDrvFirmwareAdvisory
echo.
echo     1.  Block driver updates   (ExcludeWUDriversInQualityUpdate = 1)
echo     2.  Allow driver updates   (delete the value: "Not configured", the Windows default)
echo     0.  Back
echo ==================================================================================================

:WuDrivers_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto WuDrivers_ask
if "!sel!"=="1" goto WuDrvOff
if "!sel!"=="2" goto WuDrvOn
if "!sel!"=="0" goto MenuAdvanced
goto WuDrivers_ask

:WuDrvOff
set "_FAILS=0"
rem  _wdgpc is set only by :WuDrvGpCheck, which skips a failed write: clear any stale value.
set "_wdgpc="
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ExcludeWUDriversInQualityUpdate" REG_DWORD 1 "Windows Update driver installs blocked (policy)"
rem  Read the value back: only a DWORD 1 blocks, so anything else, unread included, is a failure.
call :WuDrvRead
if "%_FAILS%"=="0" if not "!_wdst!"=="blocked" (
    echo         [FAIL] The value did not read back as a DWORD 1, so the block is not confirmed.
    set /a _FAILS+=1
)
rem  Once written, check whether the Group Policy Editor sets it too: it would silently undo this.
if "%_FAILS%"=="0" call :WuDrvGpCheck blocked
rem  gpedit override first; unlisted edition, old build or MDM ignoring GP: unverified summary.
if defined _wdgpc goto _wdOffGp
if defined _wdign goto _wdOffIgnored
if not "!_wdedc!"=="listed" goto _wdOffUnverified
if defined WIN_BUILD if !WIN_BUILD! LSS 14393 goto _wdOffUnverified
call :Summary "Windows Update will stop offering drivers once it rereads its policy - restart Windows."
goto _wdOffDone

:_wdOffUnverified
call :Summary "Policy written, but its effect on this edition or build is unverified - restart Windows."
goto _wdOffDone

:_wdOffIgnored
call :Summary "Policy written, but Windows Update is set to ignore Group Policy here - effect unverified."
goto _wdOffDone

:_wdOffGp
set "_SUMCAUSE=Not a failed write: the change was made and read back. The [WARN] above is the reason."
call :Summary "Block written, but the Group Policy Editor will override it - change it in gpedit.msc."

:_wdOffDone
pause
goto MenuAdvanced

:WuDrvOn
rem  Allow deletes the value, back to Not configured, rather than writing 0, the Disabled state.
set "_FAILS=0"
set "_wdgpc="
call :SafeRegDelete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ExcludeWUDriversInQualityUpdate" "Windows Update driver installs allowed again (policy removed)"
call :WuDrvRead
if "%_FAILS%"=="0" if not "!_wdst!"=="unset" (
    echo         [FAIL] The value did not read back as deleted, so the default is not confirmed.
    set /a _FAILS+=1
)
if "%_FAILS%"=="0" call :WuDrvGpCheck unset
rem  gpedit value 1 brings the block back; another DWORD keeps drivers allowed but configured.
if "!_wdgpc!"=="keep" goto _wdOnGpKeep
if "!_wdgpc!"=="block" goto _wdOnGpBlock
if defined _wdgpc goto _wdOnGp
if defined _wdign goto _wdOnIgnored
call :Summary "Driver updates back to the Windows default - restart Windows so Windows Update rereads it."
goto _wdOnDone

:_wdOnIgnored
call :Summary "Policy value removed; Windows Update is set to ignore Group Policy here, so MDM decides."
goto _wdOnDone

:_wdOnGpKeep
set "_SUMCAUSE=Not a failed write: the change was made and read back. The [WARN] above is the reason."
call :Summary "Drivers stay allowed, but the Group Policy Editor will put its own value back."
goto _wdOnDone

:_wdOnGpBlock
set "_SUMCAUSE=Not a failed write: the change was made and read back. The [WARN] above is the reason."
call :Summary "Value deleted, but the Group Policy Editor will put its 1 (block) back - change it there."
goto _wdOnDone

:_wdOnGp
set "_SUMCAUSE=Not a failed write: the change was made and read back. The [WARN] above is the reason."
call :Summary "Value deleted, but the Group Policy Editor will put its own value back - change it there."

:_wdOnDone
rem  MDM applies only when no Group Policy value is left and gpedit will not write one back.
if defined _wdmdm if "!_wdst!"=="unset" if not defined _wdgpc echo   [i] Your organization's MDM policy sets this to !_wdmdm! - that value now applies.
pause
goto MenuAdvanced

:WuDrvRead
rem  Reads the driver policy state with plain reg queries, no PowerShell. Sets:
rem    _wdst  = unset | blocked | allow0 | other | badtype | unread   (the Group Policy value)
rem    _wdtype, _wdraw = its registry type and data as reg query printed them
rem    _wdmdm = data of the MDM (work/school) value when one is configured, else undefined
rem    _wdign = 1 when MDM tells Windows Update to ignore Group Policy, else undefined
rem    _wded  = EditionID ;  _wdedc = listed | home | other | unread
rem  Only DWORD 1 blocks; type is checked first. No EditionID means reg failed: unread, not unset.
rem  For MDM read only the current device key: the default key holds metadata on every PC.
set "_wdst=unset" & set "_wdtype=" & set "_wdraw=" & set "_wdln=" & set "_wdmdm="
set "_wded=" & set "_wdedc=unread" & set "_wdign=" & set "_wdigv="
for /f "delims=" %%L in ('reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate 2^>nul ^| findstr /I /C:"REG_"') do set "_wdln=%%L"
if not defined _wdln goto _wdrMdm
set "_wdtd=REG_!_wdln:*REG_=!"
for /f "tokens=1,*" %%a in ("!_wdtd!") do ( set "_wdtype=%%a" & set "_wdraw=%%b" )
set "_wdst=badtype"
if /i not "!_wdtype!"=="REG_DWORD" goto _wdrMdm
set "_wdst=other"
if not defined _wdraw goto _wdrMdm
set "_wdnum="
set /a _wdnum=_wdraw 2>nul
if "!_wdnum!"=="1" set "_wdst=blocked"
if "!_wdnum!"=="0" set "_wdst=allow0"

:_wdrMdm
for /f "tokens=3" %%M in ('reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /v ExcludeWUDriversInQualityUpdate 2^>nul ^| findstr /I /C:"REG_"') do set "_wdmdm=%%M"
for /f "tokens=3" %%G in ('reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /v IgnoreWindowsUpdateGroupPolicies 2^>nul ^| findstr /I /C:"REG_"') do set "_wdigv=%%G"
if /i "!_wdigv!"=="0x1" set "_wdign=1"
for /f "tokens=3" %%E in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID 2^>nul ^| findstr /I /C:"REG_SZ"') do set "_wded=%%E"
if not defined _wded if "!_wdst!"=="unset" set "_wdst=unread"
if not defined _wded goto :eof
set "_wdedc=other"
if /i "!_wded:~0,4!"=="Core" set "_wdedc=home"
if /i "!_wded:~0,12!"=="Professional" set "_wdedc=listed"
if /i "!_wded:~0,10!"=="Enterprise" set "_wdedc=listed"
if /i "!_wded:~0,9!"=="Education" set "_wdedc=listed"
if /i "!_wded:~0,13!"=="IoTEnterprise" set "_wdedc=listed"
goto :eof

:WuDrvStateLine
rem  One wording for the stored state, shared by this screen and Status. Branch with goto,
rem  never parenthesized blocks: it prints registry text. Group Policy beats MDM by default.
if "!_wdst!"=="blocked" goto _wdslBlocked
if "!_wdst!"=="unset" goto _wdslUnset
if "!_wdst!"=="allow0" goto _wdslAllow0
if "!_wdst!"=="badtype" goto _wdslBad
if "!_wdst!"=="unread" goto _wdslUnread
echo   Currently: ALLOWED  ^(value !_wdraw! - Windows documents only 1 as "exclude drivers"^)
goto _wdslMdm

:_wdslBlocked
echo   Currently: BLOCKED  ^(ExcludeWUDriversInQualityUpdate = 1^)
goto _wdslMdm

:_wdslUnset
if defined _wdmdm goto _wdslMdmOnly
echo   Currently: ALLOWED  ^(not set - the Windows default^)
goto _wdslIgn

:_wdslMdmOnly
if /i "!_wdmdm!"=="0x1" echo   Currently: BLOCKED by your organization  ^(no local value; its MDM policy sets 1^)
if /i not "!_wdmdm!"=="0x1" echo   Currently: ALLOWED  ^(no local value; your organization's MDM policy sets !_wdmdm!^)
goto _wdslIgn

:_wdslAllow0
rem  0 is what the Group Policy Editor writes for "Disabled" - the hint names it.
echo   Currently: ALLOWED  ^(0 = "Disabled", as the Group Policy Editor writes it; same as not set^)
goto _wdslMdm

:_wdslBad
echo   Currently: UNKNOWN  ^(not a DWORD: !_wdtype! - only DWORD 1 is documented^)
goto _wdslMdm

:_wdslUnread
echo   Currently: UNKNOWN - the registry could not be read.
goto :eof

:_wdslMdm
if not defined _wdmdm goto _wdslIgn
echo   [i] Your organization also sets this policy to !_wdmdm!, via work/school management ^(MDM^).
if defined _wdign goto _wdslIgn
echo       By default Group Policy wins over MDM for Windows Update - on a managed PC, ask IT first.

:_wdslIgn
if not defined _wdign goto :eof
echo   [i] Your organization set Windows Update to ignore Group Policy: a local value does nothing.
goto :eof

:WuDrvEditionNote
rem  Warning-only. Long EditionIDs get a line of their own so text stays within console width.
if "!_wdedc!"=="listed" goto _wdenListed
if "!_wdedc!"=="home" goto _wdenHome
if "!_wdedc!"=="unread" goto _wdenUnread
echo   [i] Windows edition: !_wded!
echo       Microsoft does not list it for this policy ^(Pro, Enterprise, Education, IoT^). The
echo       value can be written; whether it takes effect cannot be verified here.
goto :eof

:_wdenListed
echo   [i] Windows edition: !_wded! - Microsoft documents this policy for it.
goto :eof

:_wdenHome
echo   [ADVISORY] Windows edition: !_wded! - a Home edition.
echo              Microsoft documents this policy for Pro, Enterprise, Education and IoT only;
echo              on Home the value can be written, but its effect cannot be verified.
goto :eof

:_wdenUnread
echo   [i] The Windows edition could not be read. Microsoft documents this policy for Pro,
echo       Enterprise, Education and IoT editions.
goto :eof

:WuDrvFirmwareAdvisory
rem  Warning-only. The driver block also holds back laptop firmware sent as driver packages.
if /i not "%MACHINE%"=="laptop" goto :eof
echo   [ADVISORY] This machine looks like a laptop. Laptop makers can ship BIOS/UEFI, battery and
echo              embedded-controller firmware through Windows Update - this blocks that too.
echo              While it is on, check the maker's support site or update tool yourself.
goto :eof

:WuDrvGpCheck
rem  Arg 1 = the state the caller just wrote: blocked or unset. Write path only: starts PowerShell.
rem  Checks whether gpedit's Registry.pol also sets this value; Group Policy would reapply it.
rem  The worker reports the LAST matching entry, set, **del. or **DelVals, since order decides.
rem  A matching end state gets an [i]; anything else a [WARN] counted into _FAILS. Sets _wdgpc:
rem    keep  = after Allow, a DWORD other than 1 - drivers stay allowed, but the value returns ;
rem    block = after Allow, a DWORD 1 - the block returns ;  replace = anything else.
rem  From a 32-bit window System32 redirects to SysWOW64, so Sysnative is used there.
set "_wdgp=" & set "_wdgpd=" & set "_wdgpok=" & set "_wdgpc="
set "_wdpolf=!TEMP!\pt_wdpol_%RANDOM%%RANDOM%.txt"
set "_wdpolsrc=!SystemRoot!\System32\GroupPolicy\Machine\Registry.pol"
if defined PROCESSOR_ARCHITEW6432 set "_wdpolsrc=!SystemRoot!\Sysnative\GroupPolicy\Machine\Registry.pol"
set "PT_WDPOL=!_wdpolf!"
set "PT_WDPOLSRC=!_wdpolsrc!"
start "" /min /wait powershell -NoProfile -Command "$r='unread'; try { $b=$null; try { $b=[IO.File]::ReadAllBytes($env:PT_WDPOLSRC) } catch [IO.FileNotFoundException] { } catch [IO.DirectoryNotFoundException] { }; $r='none'; if ($null -ne $b -and $b.Length -gt 8) { $L=[Text.Encoding]::GetEncoding(28591); $u=[Text.Encoding]::Unicode; $s=$L.GetString($b); $k='[Software\Policies\Microsoft\Windows\WindowsUpdate'+[char]0+';'; $n='ExcludeWUDriversInQualityUpdate'+[char]0+';'; $ps=$L.GetString($u.GetBytes($k+$n)); $pd=$L.GetString($u.GetBytes($k+'**del.'+$n)); $pv=$L.GetString($u.GetBytes($k+'**delvals')); $c=[StringComparison]::OrdinalIgnoreCase; $i=$s.LastIndexOf($ps,$c); $j=[Math]::Max($s.LastIndexOf($pd,$c),$s.LastIndexOf($pv,$c)); if ($j -gt $i) { $r='del' } elseif ($i -ge 0) { $o=$i+$ps.Length; $r='set ?'; if ($b.Length -ge ($o+16) -and [BitConverter]::ToUInt32($b,$o) -eq 4 -and [BitConverter]::ToUInt32($b,$o+6) -eq 4) { $r='set '+[BitConverter]::ToUInt32($b,$o+12) } } } } catch { $r='unread' }; $r | Out-File -FilePath $env:PT_WDPOL -Encoding ASCII"
set "PT_WDPOL=" & set "PT_WDPOLSRC="
if exist "!_wdpolf!" for /f "usebackq tokens=1,2" %%a in ("!_wdpolf!") do ( set "_wdgp=%%a" & set "_wdgpd=%%b" )
del "!_wdpolf!" >nul 2>&1
if "!_wdgp!"=="none" goto :eof
if not "!_wdgp!"=="set" if not "!_wdgp!"=="del" goto _wdgcUnread
if "%~1"=="blocked" if "!_wdgp!"=="set" if "!_wdgpd!"=="1" set "_wdgpok=1"
if "%~1"=="unset" if "!_wdgp!"=="del" set "_wdgpok=1"
if defined _wdgpok goto _wdgcSame
set "_wdgpc=replace"
if "%~1"=="unset" if "!_wdgp!"=="set" if "!_wdgpd!"=="1" set "_wdgpc=block"
if "%~1"=="unset" if "!_wdgp!"=="set" if not "!_wdgpd!"=="1" if not "!_wdgpd!"=="?" set "_wdgpc=keep"
set "_wdlog=WARN: Registry.pol (gpedit.msc) holds ExcludeWUDriversInQualityUpdate as: !_wdgp! !_wdgpd! - Group Policy will re-apply that over this change (%~1)"
call :LogVar _wdlog
if "!_wdgpd!"=="?" set "_wdgpd=a non-DWORD value"
if "!_wdgp!"=="del" echo   [WARN] The Group Policy Editor ^(gpedit.msc^) is set to delete this policy value.
if "!_wdgp!"=="set" echo   [WARN] The Group Policy Editor ^(gpedit.msc^) also sets this policy, to !_wdgpd!.
echo          Group Policy re-applies it at its next refresh or restart - change it in gpedit.msc.
set /a _FAILS+=1
goto :eof

:_wdgcSame
echo   [i] The Group Policy Editor ^(gpedit.msc^) configures this value the same way, so it stays.
goto :eof

:_wdgcUnread
set "_wdlog=INFO: could not read Registry.pol to check whether gpedit.msc also sets ExcludeWUDriversInQualityUpdate"
call :LogVar _wdlog
echo   [i] Could not check whether the Group Policy Editor also sets this policy ^(Registry.pol^).
goto :eof
rem =====================================================================================
rem  ACTION: Permanent process priority (per .exe)
rem =====================================================================================
:ProcPriority
cls
call :Logo
echo ============================  PERMANENT PROCESS PRIORITY (per .exe)  =============================
echo  Pins a CPU priority that Windows re-applies every time that program starts, via
echo  Image File Execution Options (CpuPriorityClass). Backed up, so it stays reversible.
echo  Use the .exe that ACTUALLY runs (Task Manager -^> Details tab), not a launcher -
echo  High / Above-normal do NOT pass down to child processes. Realtime is not offered
echo  (it can starve Windows and freeze the machine).
echo ==================================================================================================
set "_exe="
set /p "_exe=.exe name (e.g. game.exe), blank = cancel: "
if not defined _exe goto MenuAdvanced
set "_exe=!_exe:"=!"
if not defined _exe goto MenuAdvanced
for %%I in ("!_exe!") do set "_exe=%%~nxI"
if not defined _exe goto MenuAdvanced
if /i not "!_exe:~-4!"==".exe" set "_exe=!_exe!.exe"
if /i "!_exe!"==".exe" (echo   Please enter a real .exe name. & pause & goto MenuAdvanced)
echo.
echo  Priority for !_exe!:
echo     1.  High            (demanding games; use sparingly)
echo     2.  Above normal    (a gentler boost than High)
echo     3.  Normal          (Windows default)
echo     4.  Below normal
echo     5.  Low / Idle      (background apps you want out of the way)
echo     6.  Remove override (delete the setting -^> back to default)
echo     0.  Cancel
set "_plv="
set "_pln="
set "_pl="
set /p "_pl=Choose: "
if "!_pl!"=="0" goto MenuAdvanced
if "!_pl!"=="6" goto _ppRemove
if "!_pl!"=="1" (set "_plv=3" & set "_pln=High")
if "!_pl!"=="2" (set "_plv=6" & set "_pln=Above normal")
if "!_pl!"=="3" (set "_plv=2" & set "_pln=Normal")
if "!_pl!"=="4" (set "_plv=5" & set "_pln=Below normal")
if "!_pl!"=="5" (set "_plv=1" & set "_pln=Low/Idle")
if not defined _plv goto MenuAdvanced
set "_FAILS=0"
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\!_exe!\PerfOptions" "CpuPriorityClass" REG_DWORD !_plv! "Priority !_pln! for !_exe!"
echo.
call :Summary "!_exe! priority set to !_pln!. Close and reopen the program for it to take effect."
pause
goto MenuAdvanced

:_ppRemove
set "_FAILS=0"
call :SafeRegDelete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\!_exe!\PerfOptions" "CpuPriorityClass" "Remove priority override for !_exe!"
echo.
call :Summary "Priority override for !_exe! removed (back to Windows default)."
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: Backups & status
rem =====================================================================================
:DoRestorePoint
cls
call :Logo
echo =====================================  Create restore point  =====================================
call :CreateRestorePoint
pause
goto MenuBackups

:DoRegBackup
cls
call :Logo
echo =====================================  Full registry backup  =====================================
call :CreateRegBackup
pause
goto MenuBackups

:Status
cls
call :Logo
echo ========================================  CURRENT STATUS  ========================================
rem  Same header as the main menu, so the two screens never disagree about the machine.
call :DetectSysDisk
call :DetectUndervolt
rem  Collects the session's one refresh-rate measurement; it does not start a new one.
call :DetectRefresh
set "_uvhdr=none found"
if defined UVTOOL set "_uvhdr=!UVTOOL!"
echo   Build %WIN_BUILD%   Win11=%IS_WIN11%   CPU=%CPU%   GPU=%GPU%   Disk=%SYSDISK%   Refresh=!REFRESH!
echo   Machine=%MACHINE%   Undervolt tool: !_uvhdr!
echo --------------------------------------------------------------------------------------------------
echo [Hardware probes]  (these drive the [ADVISORY] lines, and nothing else)
echo   Machine class = %MACHINE%   ^(ACPI battery present = laptop^)
echo   Windows disk  = %SYSDISK%   ^(seek-penalty probe; feeds the SysMain advisory^)
if defined UVTOOL echo   Undervolt    = !UVTOOL! found - a tool that CAN undervolt is installed.
if defined UVTOOL echo                  This cannot read the actual offset, only that the tool is here.
if not defined UVTOOL echo   Undervolt    = no known tool found ^(ThrottleStop / Intel XTU / Ryzen Master^)
if not defined UVTOOL echo                  That is NOT proof you are not undervolted - a BIOS/EFI offset
if not defined UVTOOL echo                  leaves no trace this can see. Treat it as "unknown", not "no".
call :_hzShow
echo [Disk]  system drive free space
call :FreeSpaceSnap
if defined _FREE_HUMAN ( echo   !_FREE_HUMAN! ) else ( echo   could not measure )
echo [Power plan]
for /f "tokens=*" %%i in ('powercfg /getactivescheme') do echo   %%i
echo [Hibernation]  (0x0 = off, 0x1 = on)
call :ShowReg "HKLM\SYSTEM\CurrentControlSet\Control\Power" "HibernateEnabled"
echo [Min processor state]  (this script can set 5%%)
rem  Per-call temp file names, so two open sincript windows cannot read or delete each other's.
set "_mps=!TEMP!\pt_mps_%RANDOM%%RANDOM%.txt"
set "PT_MPS=!_mps!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $g=[regex]::Match(((powercfg /getactivescheme) -join ' '),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value; $p='HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\'+$g+'\54533251-82be-4824-96c1-47b60b740d00\893dee8e-2bef-41e0-89c6-b55d0929964c'; $ac=(Get-ItemProperty -Path $p).ACSettingIndex; $dc=(Get-ItemProperty -Path $p).DCSettingIndex; if($ac -ne $null){ $s='  AC=' + $ac + '%%   DC=' + $dc + '%%' } else { $s='  (using scheme default)' }; $s | Out-File -FilePath $env:PT_MPS -Encoding ASCII"
set "PT_MPS="
if exist "!_mps!" ( type "!_mps!" & del "!_mps!" >nul 2>&1 )
echo [DNS - adapters with DNS configured]
set "_dnsf=!TEMP!\pt_dns_%RANDOM%%RANDOM%.txt"
set "PT_DNSF=!_dnsf!"
start "" /min /wait powershell -NoProfile -Command "function Wu8($p){ [IO.File]::WriteAllLines($p,[string[]]@($input),(New-Object Text.UTF8Encoding $false)) }; Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.ServerAddresses} | ForEach-Object { '  ' + $_.InterfaceAlias + ': ' + ($_.ServerAddresses -join ', ') } | Wu8 $env:PT_DNSF"
set "PT_DNSF="
call :Utf8On
if exist "!_dnsf!" type "!_dnsf!"
call :Utf8Off
del "!_dnsf!" >nul 2>&1
echo [Key tweaks]
call :ShowReg "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex"
call :ShowReg "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "SystemResponsiveness"
call :ShowReg "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation"
call :ShowReg "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "LargeSystemCache"
call :ShowReg "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "FeatureSettingsOverride"
call :ShowReg "HKCU\System\GameConfigStore" "GameDVR_Enabled"
call :ShowReg "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled"
call :ShowReg "HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions"
call :ShowReg "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" "DisabledComponents"
echo [GPU scheduling / HAGS]  (0x2 = on/default, 0x1 = off; toggle under Advanced)
call :ShowReg "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode"
echo [Windows Update drivers]  (ExcludeWUDriversInQualityUpdate policy; toggle under Advanced ^> 11)
call :WuDrvRead
call :WuDrvStateLine
if "!_wdst!"=="blocked" if not "!_wdedc!"=="listed" call :WuDrvEditionNote
echo [TCP global]
netsh int tcp show global | findstr ":"
echo [CPU mitigations] FeatureSettingsOverride above: 0x2000003 ^(33554435^)=all off incl.
echo                   Downfall; 0x3=Spectre/Meltdown off only; 0/^(not set^)=all on.
echo                   Detail: PowerShell ^> Get-SpeculationControlSettings
echo [Memory compression]  (True = on/default, False = disabled via Advanced)
set "_mma=!TEMP!\pt_mma_%RANDOM%%RANDOM%.txt"
set "PT_MMA=!_mma!"
start "" /min /wait powershell -NoProfile -Command "try{ $m=Get-MMAgent; $s='  MemoryCompression=' + $m.MemoryCompression + '   PageCombining=' + $m.PageCombining }catch{ $s='  (MMAgent not available on this system)' }; $s | Out-File -FilePath $env:PT_MMA -Encoding ASCII"
set "PT_MMA="
if exist "!_mma!" ( type "!_mma!" & del "!_mma!" >nul 2>&1 )
call :PageFileStatus
echo [hosts file]
rem  Kept flat: the escaped redirect in the find line would need different escaping in a block.
set "_hostsf=%SystemRoot%\System32\drivers\etc\hosts"
set "_hlines="
if exist "%_hostsf%" for /f %%c in ('find /c /v "" ^< "%_hostsf%"') do set "_hlines=%%c"
if defined _hlines echo   !_hlines! lines total
if not defined _hlines echo   ^(hosts file not found or unreadable^)
echo [OpenAsar]  (app.asar well under 1 MB = OpenAsar; ~9 MB = stock Discord)
set "_asarf=!TEMP!\pt_asar_%RANDOM%%RANDOM%.txt"
set "PT_ASARF=!_asarf!"
start "" /min /wait powershell -NoProfile -Command "Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Discord\app-*\resources\app.asar') -ErrorAction SilentlyContinue | ForEach-Object { '  ' + [math]::Round($_.Length/1MB,2) + ' MB  ' + $_.FullName } | Out-File -FilePath $env:PT_ASARF -Encoding ASCII"
set "PT_ASARF="
if exist "!_asarf!" ( type "!_asarf!" & del "!_asarf!" >nul 2>&1 )
echo ==================================================================================================
pause
goto MenuBackups
rem =====================================================================================
rem  ACTION: Apply recommended safe set
rem =====================================================================================
:ApplyRecommended
cls
call :Logo
echo ==================================  Apply recommended safe set  ==================================
echo  Runs Cleanup + Privacy + Performance + Power + Network core tweaks with no prompts.
echo  The power core switches to Ultimate Performance ^(High if Ultimate is missing^) and sets
echo  sleep to never. On a laptop, or if you undervolt, use menu 4 and pick High or Balanced.
echo  Optional/risky items are NOT included. A restore point first is strongly advised.
echo ==================================================================================================
call :LaptopAdvisory
set "_rp=Y"
set /p "_rp=Create a System Restore Point now? (Y/N): "
if /i "!_rp!"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Proceed with the recommended set? (Y/N): "
if /i not "!_c!"=="Y" goto MainMenu
rem  _RUNTRACK on: this path runs all five cores, the most sc/schtasks/powercfg calls of any.
set "_PWBAK_FILE="
set "_TLBAK_FILE="
rem  Clear _PWPLAN so a plan picked on menu 4 earlier in the session is not inherited.
set "_PWPLAN="
set "_FAILS=0" & set "_RUNTRACK=1"
call :DoCleanupCore
call :DoPrivacyCore
call :DoPerformanceCore
call :DoPowerCore
call :DoNetworkCore
echo.
call :Summary "Recommended set applied. Reboot recommended."
pause
goto MainMenu
rem =====================================================================================
rem  INFO: What was excluded
rem =====================================================================================
:Excluded
cls
call :Logo
echo =================================  What was left out (and why)  ==================================
echo  This script intentionally does NOT include, by category:
echo.
echo  Security-weakening (excluded):
echo    - Disabling Windows Defender, Firewall, UAC or SmartScreen
echo    - Removing the "downloaded from the Internet" warning on executables
echo    - Fully disabling Windows Update or faking its server (Advanced ^> 11 stops only DRIVER installs)
echo    - Disabling VBS / HVCI via buggy boot edits
echo    - Boot flags that turn off DEP, anti-malware early launch, or the hypervisor
echo      (those also break WSL2 / Hyper-V / Sandbox)
echo    - Regrouping svchost services (SvcHostSplitThresholdInKB) - Microsoft splits them
echo      on purpose for inter-service isolation and reliability, and documents the saving
echo      from regrouping as modest. Isolation is worth more than the RAM.
echo.
echo  Placebo / obsolete / harmful (excluded):
echo    - XP-era "memory optimization" registry values (fixed pool/cache sizes etc.)
echo    - Forcing the large system file cache on by default (it is opt-in under Performance)
echo    - Clearing the pagefile at shutdown (only makes shutdown slower)
echo    - Clearing the Prefetch folder (Windows rebuilds it; first launches just get slower)
echo    - Disabling the prefetcher itself (EnablePrefetcher=0) - same cost as above, made
echo      permanent, and near zero gain on an SSD (SysMain on/off is offered separately)
echo    - Lowering ServicesPipeTimeout to 30000 - 30 s already IS the Windows default, so
echo      it changes nothing, and it would silently undo a 60000 fix if you ever needed one
echo    - Firewall rules that block Google/YouTube IP ranges to "stop throttling" (a myth)
echo    - Deprecated TCP options (Chimney/NetDMA) removed by Microsoft years ago
echo    - Hardcoded MTU and other link-specific values copied from another PC
echo    - Uninstalling old Windows 7/8.1 "telemetry" updates (irrelevant on 10/11)
echo    - Bulk undocumented GPU registry dumps (only vendor telemetry-off is kept, in Advanced)
echo    - Raising TdrDelay or setting TdrLevel=0 to "fix" display driver resets (driver-testing keys)
echo.
echo  From the gaming optimization guide (left out on purpose):
echo    - Windows activation scripts (MAS) - licensing/trust, not a performance tweak
echo    - Replacing Defender with a third-party AV (e.g. Panda) - no FPS gain, changes security
echo    - Aggressive RAM / standby "cleaners" (ISLC empty-standby-list) - placebo to harmful
echo    - Forcing MSI mode, and NIC edits (jumbo frames, offloads) - the guide advises against these
echo.
echo  Note: disabling CPU mitigations, the large system cache, and SteamLight's single-process
echo  mode (it turns off Steam's browser sandbox) ARE available, but only as explicit opt-in
echo  choices (Advanced / Performance / Apps ^& files) - never in the recommended set.
echo ==================================================================================================
pause
goto MainMenu
rem =====================================================================================
rem  HELPERS
rem =====================================================================================
:Logo
rem  Every screen draw clears the :NoInput empty-read counter, so only repeats of one prompt count.
set "_NOIN=0"
echo.
echo                                         SSSS   III   N   N
echo                                         S       I    NN  N
echo                                         SSSS    I    N N N
echo                                             S   I    N  NN
echo                                         SSSS   III   N   N
echo.
goto :eof
rem =====================================================================================
rem  COMMAND LINE:  PerfTweaks.cmd /preset:NAME [/dns:VALUE] [/plan:VALUE] [/norestore]
rem =====================================================================================
:CliHelp
echo.
echo  sincript - Windows 10/11 optimizer
echo.
echo  Run with no arguments for the interactive menu, or drive one preset unattended:
echo.
echo     PerfTweaks.cmd /preset:NAME [/dns:VALUE] [/plan:VALUE] [/norestore]
echo.
echo     /preset:light      cleanup + privacy + network cores
echo     /preset:moderate   the recommended safe set (cleanup, privacy, performance,
echo                        power, network)
echo     /preset:heavy      the safe set plus the aggressive extras
echo     /preset:NAME       any NAME.preset file in sincript_presets\
echo.
echo     /dns:VALUE         cloudflare ^| google ^| quad9 ^| an IPv4 address.
echo                        Omit it and DNS is left exactly as it is - the interactive
echo                        presets ASK, and an unattended run must not guess.
echo     /plan:VALUE        ultimate ^| high ^| balanced - which power scheme a preset
echo                        containing power=1 activates. Unset means ultimate.
echo                        ON A LAPTOP RUNNING AN UNDERVOLT, PASS high OR balanced:
echo                        ultimate pins sustained maximum clocks, which is where a
echo                        stable undervolt stops being stable and the CPU raises an
echo                        uncorrectable machine check (bugcheck 0x124). Unattended
echo                        there is no prompt to reconsider at, so choose it here.
echo     /norestore         skip the System Restore Point (it is created by default).
echo     /?                 this help.
echo.
echo  Requires an elevated window: unlike the menu, a /preset: run will NOT relaunch
echo  itself, because a relaunch returns an exit code for the relaunch and not for the
echo  work. Start it from an elevated prompt or a task set to run with highest privileges.
echo.
echo  Exit codes:  0 applied cleanly   1 applied with failures   2 bad usage
echo               3 not elevated
echo.
exit /b 0

:CliRun
rem  One preset, no prompts, a real exit code; same routines as the menu so they cannot drift.
if defined _CLIBAD (
    echo [ERROR] Unrecognized option, or an option with no value: !_CLIBAD!
    echo         Run  PerfTweaks.cmd /?  for the accepted options.
    exit /b 2
)
if not defined _CLIPRESET (
    echo [ERROR] No preset given. The command line needs /preset:NAME - on its own,
    echo         an option like /norestore has nothing to apply.
    echo         Run  PerfTweaks.cmd /?  for the accepted options.
    exit /b 2
)
rem  Validate /dns: with the menu's checker before anything is applied.
if defined _CLIDNS (
    set "_dnsok="
    if /i "!_CLIDNS!"=="cloudflare" set "_dnsok=1"
    if /i "!_CLIDNS!"=="google"     set "_dnsok=1"
    if /i "!_CLIDNS!"=="quad9"      set "_dnsok=1"
    if not defined _dnsok set "_IPCHK=!_CLIDNS!" & call :_ip4_ok && set "_dnsok=1"
    if not defined _dnsok (
        echo [ERROR] /dns:!_CLIDNS! is not valid - use cloudflare, google, quad9 or an IPv4 address.
        exit /b 2
    )
)
if defined _CLIPLAN (
    set "_planok="
    if /i "!_CLIPLAN!"=="ultimate" set "_planok=1"
    if /i "!_CLIPLAN!"=="high"     set "_planok=1"
    if /i "!_CLIPLAN!"=="balanced" set "_planok=1"
    if not defined _planok (
        echo [ERROR] /plan:!_CLIPLAN! is not valid - use ultimate, high or balanced.
        exit /b 2
    )
)
rem  ---- resolve and fully validate the preset BEFORE anything is changed ----
rem  Read-only until the validated marker below: a typo must abort before anything changes.
set "_CLIKIND=builtin"
if /i "!_CLIPRESET!"=="light"    goto _cliResolved
if /i "!_CLIPRESET!"=="moderate" goto _cliResolved
if /i "!_CLIPRESET!"=="heavy"    goto _cliResolved
set "_CLIKIND=custom"
rem  NAME becomes a path, so it is whitelisted: letters, digits, _ . -; double dots checked apart.
rem  No pipe: a piped child re-parses it. eol=A closes the semicolon hole; A itself is allowed.
set "_pnbad="
for /f "eol=A delims=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-" %%X in ("!_CLIPRESET!") do set "_pnbad=1"
if defined _pnbad goto _cliBadName
if not "!_CLIPRESET!"=="!_CLIPRESET:..=!" goto _cliBadName
set "_pfile=!SCRIPT_DIR!sincript_presets\!_CLIPRESET!.preset"
if not exist "!_pfile!" (
    echo [ERROR] No such preset: !_CLIPRESET!
    echo         Expected a built-in ^(light / moderate / heavy^) or this file:
    echo           !_pfile!
    set "_LOGMSG=CLI abort: preset file not found - !_pfile!" & call :LogVar _LOGMSG
    exit /b 2
)
rem  Parse and validate the file now - this only fills in _P_* variables, it changes nothing.
set "_perr=0" & set "_pgood=0"
set "_perrfile=!TEMP!\sincript_cli_err_%RANDOM%%RANDOM%.txt"
break>"!_perrfile!"
for %%K in (CLEANUP PRIVACY PERFORMANCE POWER PWTIMEOUTS PWPLAN NETWORK OPENASAR GAMEMODE GAMEBAR EDGE ONEDRIVE SYSRESP NETTHROTTLE LARGECACHE MINPROC BCDTIMERS IPV6 MEMCOMPRESS NVME GPUTEL NAGLE WIN32 DNS) do set "_P_%%K="
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("!_pfile!") do (
    set "_k=%%A"
    set "_v=%%B"
    call :PresetCheckLine
)
echo  Recognized directives: !_pgood!    Problems: !_perr!
if %_perr% gtr 0 type "!_perrfile!"
del "!_perrfile!" >nul 2>&1
if %_pgood% lss 1 (
    echo [ERROR] No valid directives in !_CLIPRESET!.preset - nothing to apply.
    set "_LOGMSG=CLI abort: no valid directives in !_pfile!" & call :LogVar _LOGMSG
    exit /b 2
)

:_cliResolved
rem  ---- the command line is valid; now check the environment can honour it ----
rem  Argument errors are reported before environment errors, so one mistake is one round trip.
if "%_ELEV%"=="0" (
    echo [ERROR] /preset: needs an elevated window - almost every tweak writes to HKLM.
    echo         This run would have failed nearly everything, so nothing was attempted.
    echo         Re-run from an elevated prompt, or set the scheduled task to run with
    echo         highest privileges. A /preset: run never self-elevates on purpose: the
    echo         relaunch would return its own exit code instead of the work's.
    call :Log "CLI abort: /preset:!_CLIPRESET! without elevation"
    exit /b 3
)
if "%_BAKOK%"=="0" (
    echo [ERROR] The backup folder is not writable, and every registry tweak refuses to run
    echo         without a per-value undo file. Nothing was attempted.
    echo           !BACKUP_DIR!
    call :Log "CLI abort: /preset:!_CLIPRESET! with no writable backup folder"
    exit /b 2
)
rem  ---- validated; from here on the machine is actually changed ----
echo.
echo  sincript - applying preset "!_CLIPRESET!" unattended.
echo.
call :Log "CLI start: preset=!_CLIPRESET! kind=!_CLIKIND! dns=!_CLIDNS! plan=!_CLIPLAN! norestore=!_CLINORP!"
rem  Laptop advisory here too, warning-only: unattended, it is the only record of the risk.
call :LaptopAdvisory
if /i "%MACHINE%"=="laptop" if not defined _CLIPLAN (
    echo   [ADVISORY] No /plan: given, so a preset containing power=1 will activate ULTIMATE
    echo              PERFORMANCE - the plan Windows hides on battery-powered machines. If this
    echo              laptop runs an undervolt, pass /plan:high or /plan:balanced instead: the
    echo              jump to sustained max clocks is where a stable undervolt stops being
    echo              stable, and the CPU reports it as an uncorrectable machine check.
)
call :Log "CLI advisory: machine=%MACHINE% plan=!_CLIPLAN!"
if not defined _CLINORP call :CreateRestorePoint
set "_FAILS=0"
if /i "!_CLIKIND!"=="custom" goto _cliCustom
call :PresetBegin !_CLIPRESET!
if errorlevel 1 exit /b 2
rem  Only after :PresetBegin, which clears _PWPLAN; set before it, the plan would be wiped.
if defined _CLIPLAN set "_PWPLAN=!_CLIPLAN!"
if /i "!_CLIPRESET!"=="light"    call :PresetBodyLight
if /i "!_CLIPRESET!"=="moderate" call :PresetBodyModerate
if /i "!_CLIPRESET!"=="heavy"    call :PresetBodyHeavy
if defined _CLIDNS call :PresetDnsByName "!_CLIDNS!"
call :PresetEnd
goto _cliDone

:_cliBadName
echo [ERROR] /preset:!_CLIPRESET! - a custom preset is a plain file name from
echo         sincript_presets\, with no path separators, wildcards or "..".
call :Log "CLI abort: rejected preset name !_CLIPRESET!"
exit /b 2

:_cliCustom
set "_pbase=!_CLIPRESET: =_!"
call :PresetBegin custom_!_pbase!
if errorlevel 1 exit /b 2
rem  Write _P_PWPLAN, not _PWPLAN: :PresetApplyDirectives would put the file's plan back over it.
if defined _CLIPLAN set "_P_PWPLAN=!_CLIPLAN!"
call :PresetApplyDirectives
rem  An explicit /dns: overrides the file's key, which :PresetApplyDirectives already applied.
if defined _CLIDNS call :PresetDnsByName "!_CLIDNS!"
call :PresetEnd

:_cliDone
echo.
rem  Never pass the preset name to :Summary: it parses its argument, so an ampersand would run.
call :Summary "Preset applied."
echo      Preset:          !_CLIPRESET!
if defined PRESET_LAST (echo      Registry backup: !PRESET_LAST!) else (echo      Registry backup: none - it could not be written, see the [WARN] above.)
echo      A reboot is recommended.
call :Log "CLI end: preset=!_CLIPRESET! fails=%_FAILS%"
if not "%_FAILS%"=="0" exit /b 1
exit /b 0

:NonAsciiCheck
rem  Sets _naData=1 when _rd holds a non-printable-ASCII char; runs in :SafeRegAdd's setlocal.
rem  for /f yields a token only for a char outside the delims whitelist; a quote counts as one.
rem  Space must be the last delimiter; eol must be an allowed char, A, or a semicolon hides data.
rem  Not findstr: its ranges follow collation order, not character codes.
if not defined _rd goto :eof
for /f "eol=A delims=^!#$%%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~ " %%c in ("!_rd!") do set "_naData=1"
goto :eof

:NoInput
rem  Called when a prompt read back empty. Returns 0 = ask again, 1 = give up.
rem  Caps consecutive empty reads so a closed stdin cannot loop forever.
rem  Returns, never jumps: the caller does the goto, which keeps the call stack balanced.
if not defined _NOIN set "_NOIN=0"
set /a _NOIN+=1
if !_NOIN! lss 100 exit /b 0
echo.
echo [ERROR] No input after !_NOIN! empty reads - stdin looks empty or closed.
echo         sincript is an interactive menu: run it from a console window, or
echo         double-click it. It cannot be driven from a pipe or a redirected file.
call :Log "ABORT: input exhausted after !_NOIN! empty reads"
exit /b 1

:Log
rem  Read with delayed expansion off, echoed with it on, so special characters stay data.
rem  Written one call deeper so stderr goes to nul on the call, hiding a failed redirection.
rem  Not a parenthesized block: a closing paren in LOGFILE or the message would end it early.
setlocal DisableDelayedExpansion
set "_LOGLN=%~1"
setlocal EnableDelayedExpansion
call :_LogWrite 2>nul
goto :eof

:_LogWrite
>>"!LOGFILE!" echo [%date% %time%] !_LOGLN!
goto :eof

:LogVar
rem  Arg 1 = the NAME of a variable holding the message. Use it for paths under the profile or
rem  script folder: call re-parses its arguments and loses percent signs; by name it is read once.
setlocal EnableDelayedExpansion
set "_LOGLN=!%~1!"
call :_LogWrite 2>nul
goto :eof

:TimerResApply
cls
call :Logo
echo ====================================  Apply timer resolution  ====================================
echo  Installs SetTimerResolution to run hidden at every logon (Task Scheduler) and hold
echo  a higher Windows timer resolution. On Windows 10 2004+ / 11 it also sets
echo  GlobalTimerResolutionRequests=1 so the change is system-wide (this needs a REBOOT).
echo  Reversible via option 7 (Remove timer resolution).
echo ==================================================================================================
call :LaptopAdvisory
call :RequireBundledFile SetTimerResolution.exe "raises the Windows timer resolution (autostart helper)"
if errorlevel 1 goto MenuApps
echo.
echo  Resolution is in 100ns units:  5000 = 0.5 ms (typical best),  10000 = 1 ms.
echo  The TimerResolution tool's MeasureSleep can find the best value for your PC.
set "_res="
set /p "_res=Resolution in 100ns units [Enter = 5000]: "
if not defined _res set "_res=5000"
set "_bad="
rem  eol=0 closes the semicolon hole. Read _res late so a quote or exclamation mark stays data.
for /f "eol=0 delims=0123456789" %%x in ("!_res!") do set "_bad=1"
if defined _bad (
    echo [ERROR] "!_res!" must be a whole number ^(100ns units^). Aborting.
    pause
    goto MenuApps
)
set "_c="
set /p "_c=Install the timer-resolution autostart with resolution !_res!? (Y/N): "
if /i not "!_c!"=="Y" goto MenuApps
set "_TRDIR=%ProgramData%\Sincript"
if not exist "%_TRDIR%" md "%_TRDIR%" >nul 2>&1
rem  Stop the helper before copying: Windows will not overwrite a running exe.
taskkill /f /im SetTimerResolution.exe >nul 2>&1
copy /y "!SCRIPT_DIR!SetTimerResolution.exe" "%_TRDIR%\SetTimerResolution.exe" >nul
if errorlevel 1 (
    echo [ERROR] Could not copy SetTimerResolution.exe to "%_TRDIR%".
    call :Log "TIMERRES copy failed"
    pause
    goto MenuApps
)
call :Log "TIMERRES helper copied to %_TRDIR%"
set "_FAILS=0"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" "GlobalTimerResolutionRequests" REG_DWORD 1 "Global timer resolution requests on"
schtasks /Create /F /TN "Sincript Timer Resolution" /SC ONLOGON /RL HIGHEST /TR "%_TRDIR%\SetTimerResolution.exe --resolution !_res! --no-console" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Could not create the scheduled task ^(schtasks failed^).
    call :Log "TIMERRES schtasks create failed"
    pause
    goto MenuApps
)
call :Log "TIMERRES task created res=!_res!"
schtasks /Run /TN "Sincript Timer Resolution" >nul 2>&1
echo.
call :Summary "Timer-resolution autostart installed (resolution !_res!). Runs hidden at logon."
echo      REBOOT for the system-wide effect (GlobalTimerResolutionRequests) to take hold.
pause
goto MenuApps

:TimerResRemove
cls
call :Logo
echo ===================================  Remove timer resolution  ====================================
echo  Removes the SetTimerResolution autostart: deletes the scheduled task, stops the
echo  hidden helper and deletes the copied file. You can also revert the system-wide
echo  registry switch (that revert needs a REBOOT).
echo ==================================================================================================
set "_c="
set /p "_c=Remove the timer-resolution autostart? (Y/N): "
if /i not "!_c!"=="Y" goto MenuApps
schtasks /Delete /F /TN "Sincript Timer Resolution" >nul 2>&1
taskkill /f /im SetTimerResolution.exe >nul 2>&1
if exist "%ProgramData%\Sincript\SetTimerResolution.exe" del /f /q "%ProgramData%\Sincript\SetTimerResolution.exe" >nul 2>&1
rd "%ProgramData%\Sincript" >nul 2>&1
rem  Report what is actually gone: every command above hides its output and exit code.
set "_trleft=0"
schtasks /Query /TN "Sincript Timer Resolution" >nul 2>&1 && set "_trleft=1"
if exist "%ProgramData%\Sincript\SetTimerResolution.exe" set "_trleft=1"
if "%_trleft%"=="0" (
    call :Log "TIMERRES removed (task + helper)"
    echo [OK] Autostart removed and the helper stopped.
) else (
    call :Log "TIMERRES remove incomplete - task and/or helper still present"
    echo [WARN] Not fully removed - the scheduled task and/or the helper file are still there.
    echo        Removing either needs Administrator, so re-run this elevated.
)
echo.
set "_c2="
set /p "_c2=Also revert GlobalTimerResolutionRequests to default (off)? (Y/N): "
if /i not "!_c2!"=="Y" goto MenuApps
set "_FAILS=0"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" "GlobalTimerResolutionRequests" REG_DWORD 0 "Global timer resolution requests off"
echo.
call :Summary "GlobalTimerResolutionRequests reverted to off."
echo      REBOOT to fully apply.
pause
goto MenuApps

:Debloat
cls
call :Logo
echo =====================================  Remove built-in apps  =====================================
echo  Removes built-in Microsoft Store apps (telemetry / ads / rarely-used). Each group
echo  is opt-in below. This is NOT covered by the .reg backups: most removed apps can be
echo  reinstalled from the Microsoft Store ^(LTSC editions have no Store^). Apps you actually
echo  use, just answer N.
echo ==================================================================================================
rem  Check elevation here: without it -AllUsers finds nothing and every group reports none.
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - listing packages for all users needs Administrator, so nothing
    echo        could be removed. Close this window and use "Run as administrator".
    pause
    goto MenuApps
)
echo.
echo  The standard set removes these 15 apps:
echo     Copilot                Bing Weather            Bing News
echo     Bing Search            Microsoft Teams         Office hub
echo     Outlook for Windows    Clipchamp               Solitaire Collection
echo     Quick Assist           Feedback Hub            Microsoft Family
echo     Sticky Notes           To Do                   Clock and Alarms
echo.
echo  Sticky Notes takes its notes with it if they were never synced to an account.
set "_c="
set /p "_c=Remove the 15 standard apps listed above? (Y/N): "
if /i not "!_c!"=="Y" goto DebloatOpt
call :Log "DEBLOAT standard set"
call :DebloatRun "MicrosoftCorporationII.QuickAssist|Microsoft.WindowsFeedbackHub|Microsoft.Copilot|Microsoft.BingWeather|MicrosoftCorporationII.MicrosoftFamily|Microsoft.MicrosoftOfficeHub|Microsoft.BingSearch|Clipchamp.Clipchamp|MSTeams|Microsoft.Todos|Microsoft.MicrosoftStickyNotes|Microsoft.BingNews|Microsoft.OutlookForWindows|Microsoft.WindowsAlarms|Microsoft.MicrosoftSolitaireCollection" "Standard bloat"

:DebloatOpt
echo.
set "_c2="
echo  Optional set: Camera, Sound Recorder, Snipping Tool, Power Automate, the Xbox app, and
echo  Xbox TCUI - the Xbox screens games open for profiles, friends and achievements. Game Bar
echo  itself is not removed.
set /p "_c2=Also remove those 6 optional apps? (Y/N): "
if /i not "!_c2!"=="Y" goto DebloatOneDrive
call :Log "DEBLOAT optional apps"
call :DebloatRun "Microsoft.WindowsCamera|Microsoft.WindowsSoundRecorder|Microsoft.ScreenSketch|Microsoft.PowerAutomateDesktop|Microsoft.Xbox.TCUI|Microsoft.GamingApp" "Optional apps"

:DebloatOneDrive
echo.
set "_c4="
set /p "_c4=Also remove OneDrive (uninstall it and remove the sync app)? (Y/N): "
if /i not "!_c4!"=="Y" goto DebloatDone
call :Log "DEBLOAT OneDrive"
echo Removing OneDrive (a minimized window may flash)...
rem  Look for OneDriveSetup.exe in SysWOW64 too: on 64-bit Windows it often lives only there.
set "_odres=!TEMP!\pt_od_%RANDOM%.txt"
del "!_odres!" >nul 2>&1
set "PT_OD_RES=!_odres!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $ok=0; foreach($q in @(Get-AppxPackage -AllUsers Microsoft.OneDriveSync -ErrorAction SilentlyContinue)){ try{ $q | Remove-AppxPackage -ErrorAction Stop; $ok++ }catch{} }; $s=(Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'); if(-not (Test-Path -LiteralPath $s)){ $s=(Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe') }; $rc=-1; if(Test-Path -LiteralPath $s){ $pr=Start-Process -FilePath $s -ArgumentList '/uninstall' -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue; if($pr){ $rc=$pr.ExitCode } }; (''+$ok+' '+$rc) | Out-File -FilePath $env:PT_OD_RES -Encoding ASCII"
set "PT_OD_RES="
set "_odok=0" & set "_odrc=-1"
if exist "!_odres!" for /f "usebackq tokens=1,2" %%a in ("!_odres!") do ( set "_odok=%%a" & set "_odrc=%%b" )
del "!_odres!" >nul 2>&1
rem  Only exit 0 counts as uninstalled; the uninstaller's other codes are undocumented.
if "!_odrc!"=="-1" (
    echo   [WARN] OneDrive: the sync app removal ran ^(!_odok! package^(s^)^), but OneDriveSetup.exe
    echo          was not found in System32 or SysWOW64 - OneDrive itself was NOT uninstalled.
    call :Log "DEBLOAT OneDrive: setup not found, appx=!_odok!"
) else if not "!_odrc!"=="0" (
    echo   [WARN] OneDrive's uninstaller exited with code !_odrc!, so it may not have finished -
    echo          check Settings ^> Apps. ^(!_odok! sync package^(s^) removed.^)
    call :Log "DEBLOAT OneDrive: appx=!_odok! setup rc=!_odrc! - not 0"
) else (
    echo   [OK] OneDrive uninstalled ^(!_odok! sync package^(s^) removed^).
    call :Log "DEBLOAT OneDrive: appx=!_odok! setup rc=0"
)

:DebloatDone
echo.
echo Done. Most removed apps can be reinstalled from the Microsoft Store ^(LTSC editions, IoT
echo LTSC included, have no Store^). OneDrive comes back from Microsoft's OneDrive download page.
pause
goto MenuApps

:DebloatRun
rem  %1 = pipe-separated package list   %2 = group label
rem  Removes each package; counts removed / failed / not-installed separately, since debloat has
rem  no undo. The package list goes by environment variable, so cmd never re-parses a name.
set "_dbres=!TEMP!\pt_debloat_%RANDOM%.txt"
del "!_dbres!" >nul 2>&1
set "PT_DB_RES=!_dbres!"
set "PT_DB_PKGS=%~1"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $rm=0;$fail=0;$absent=0; foreach($x in @($env:PT_DB_PKGS -split '\|')){ if(-not $x){ continue }; $pk=@(Get-AppxPackage -AllUsers $x -ErrorAction SilentlyContinue); if($pk.Count -eq 0){ $absent++; continue }; foreach($q in $pk){ try{ $q | Remove-AppxPackage -ErrorAction Stop; $rm++ }catch{ $fail++ } } }; (''+$rm+' '+$fail+' '+$absent) | Out-File -FilePath $env:PT_DB_RES -Encoding ASCII"
set "PT_DB_RES=" & set "PT_DB_PKGS="
set "_dbrm=0" & set "_dbf=0" & set "_dba=0"
if exist "!_dbres!" for /f "usebackq tokens=1,2,3" %%a in ("!_dbres!") do ( set "_dbrm=%%a" & set "_dbf=%%b" & set "_dba=%%c" )
del "!_dbres!" >nul 2>&1
if not "!_dbf!"=="0" goto _dbFail
if "!_dbrm!"=="0" goto _dbNone
echo   [OK] %~2: removed !_dbrm! package^(s^); !_dba! were not installed.
call :Log "OK: DEBLOAT %~2 removed=!_dbrm! absent=!_dba!"
goto :eof

:_dbNone
echo   [SKIP] %~2: none of these apps are installed - nothing to remove.
call :Log "SKIP: DEBLOAT %~2 - none present"
goto :eof

:_dbFail
echo         [FAIL] %~2: removed !_dbrm!, but !_dbf! could NOT be removed ^(!_dba! not installed^).
echo                Some in-box apps are provisioned by Windows and refuse removal; a few come
echo                back after a feature update. Re-running is safe.
call :Log "FAIL: DEBLOAT %~2 removed=!_dbrm! failed=!_dbf! absent=!_dba!"
goto :eof
rem =====================================================================================
rem  ACTION: Manage startup programs (the reversible Task Manager switch, with backups)
rem =====================================================================================
:StartupMgr
cls
call :Logo
echo ===================================  MANAGE STARTUP PROGRAMS  ====================================
echo  Lists what starts with Windows - the Run registry keys (HKCU / HKLM / WOW64) and
echo  both Startup folders - and lets you flip any entry between Enabled and Disabled.
echo  This is the same reversible StartupApproved switch Task Manager uses: nothing is
echo  deleted, and the entry's previous state is saved as a .reg backup before each
echo  flip (restorable from Backups ^& status, or by double-clicking the file).
echo ==================================================================================================
set "_sulist=!TEMP!\pt_startup_%RANDOM%%RANDOM%.txt"
set "_sures=!TEMP!\pt_sures_%RANDOM%%RANDOM%.txt"
set "_susigf=!TEMP!\pt_susig_%RANDOM%%RANDOM%.txt"
del "!_sulist!" >nul 2>&1
set "_susigv="
call :StartupWorker list 0
if not exist "!_sulist!" (
    echo [ERROR] Could not enumerate startup entries ^(PowerShell blocked or unavailable^).
    pause
    goto MenuApps
)
rem  Fingerprint of the list shown; the toggle pass refuses if the set changed since.
rem  _susigf and _susigv must differ by more than case: cmd variable names ignore case.
if exist "!_susigf!" for /f "usebackq delims=" %%S in ("!_susigf!") do set "_susigv=%%S"
del "!_susigf!" >nul 2>&1
set "_sn=0"
call :Utf8On
for /f "usebackq tokens=1,2,3,* delims=|" %%a in ("!_sulist!") do (
    set /a _sn+=1
    set "_sst[!_sn!]=%%b"
    set "_ssc[!_sn!]=%%c"
    set "_snm[!_sn!]=%%d"
)
call :Utf8Off
del "!_sulist!" >nul 2>&1
if "%_sn%"=="0" (
    echo  No startup entries found ^(the Run keys and Startup folders are empty^).
    pause
    goto MenuApps
)
echo   #    State      Source           Name
echo --------------------------------------------------------------------------------------------------
for /l %%I in (1,1,%_sn%) do call :_suShow %%I
echo --------------------------------------------------------------------------------------------------
echo  Names are shown ASCII-only ^(other characters appear as "?"^); a flip still
echo  targets the exact entry. Disabled entries stay listed and can be re-enabled.

:StartupMgr_ask
set "sel="
set /p "sel=Number to flip Enabled/Disabled (0 = back): "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto StartupMgr_ask
if "!sel!"=="0" goto MenuApps
set "_sok="
for /l %%I in (1,1,%_sn%) do if "!sel!"=="%%I" set "_sok=1"
if not defined _sok goto StartupMgr_ask
echo.
echo  About to flip:  [!_sst[%sel%]!]  !_ssc[%sel%]!  -  !_snm[%sel%]!
set "_cc="
set /p "_cc=Proceed? (Y/N): "
if /i not "!_cc!"=="Y" goto StartupMgr_ask
del "!_sures!" >nul 2>&1
call :StartupWorker toggle %sel%
set "_surc=%errorlevel%"
echo.
call :Utf8On
if exist "!_sures!" type "!_sures!"
call :Utf8Off
del "!_sures!" >nul 2>&1
if "%_surc%"=="0" (
    echo [OK] Flipped. Takes effect at the next sign-in; flip it again any time to undo.
    call :Log "STARTUP flip #%sel% ok"
) else (
    echo [ERROR] The flip failed - nothing was changed. If it is an HKLM / Common entry,
    echo         make sure this window is elevated, then try again.
    call :Log "STARTUP flip #%sel% FAILED"
)
pause
goto StartupMgr

:_suShow
rem %1 = 1-based index into the _sst/_ssc/_snm listing arrays; prints one aligned row.
set "_p1=%1.    "
set "_p1=!_p1:~0,5!"
set "_p2=!_sst[%1]!            "
set "_p2=!_p2:~0,11!"
set "_p3=!_ssc[%1]!                 "
set "_p3=!_p3:~0,17!"
set "_p4=!_snm[%1]!"
echo   !_p1!!_p2!!_p3!!_p4:~0,58!
goto :eof

:StartupWorker
rem %1 = list | toggle   %2 = 1-based entry index (toggle mode; ignored for list)
rem PowerShell worker, minimized. Enumerates Run keys and Startup folders in a fixed sorted order,
rem so the listed number addresses the same entry on toggle; names never round-trip through cmd.
rem A flip writes a .reg backup of the prior state first, then the StartupApproved value.
rem Keep literal-path / .NET registry calls: a name with [ ] * ? must not match another value.
rem PT_SU_SIG / PT_SU_SIGIN: the toggle pass re-checks the list fingerprint and refuses on change.
set "PT_SU_MODE=%~1"
set "PT_SU_IDX=%~2"
set "PT_SU_LIST=!_sulist!"
set "PT_SU_RES=!_sures!"
set "PT_SU_BAK=!BACKUP_DIR!"
set "PT_SU_SIG=!_susigf!"
set "PT_SU_SIGIN=%_susigv%"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; function Wu8($p){ [IO.File]::WriteAllLines($p,[string[]]@($input),(New-Object Text.UTF8Encoding $false)) }; $srcs=@(@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKCU-Run'),@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKLM-Run'),@('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32','HKLM-Run32')); $E=@(); foreach($s in $srcs){ $k=Get-Item -LiteralPath $s[0] -ErrorAction SilentlyContinue; if($k){ foreach($n in ($k.GetValueNames() | Sort-Object)){ if($n -ne ''){ $E+=,@($s[2],$s[1],$n) } } } }; $dirs=@(@([Environment]::GetFolderPath('Startup'),'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder','User-Startup'),@([Environment]::GetFolderPath('CommonStartup'),'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder','Common-Startup')); foreach($s in $dirs){ if($s[0] -and (Test-Path -LiteralPath $s[0])){ foreach($f in (Get-ChildItem -LiteralPath $s[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | Sort-Object Name)){ $E+=,@($s[2],$s[1],$f.Name) } } }; function S($a,$n){ $k=Get-Item -LiteralPath $a -ErrorAction SilentlyContinue; if($k){ $v=$k.GetValue($n); if($v -and $v.Length -ge 1 -and (($v[0] -band 1) -eq 1)){ return 'Disabled' } }; return 'Enabled' }; $sg=[BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::Unicode.GetBytes((($E | ForEach-Object { $_[0]+'\'+$_[2] }) -join ';')))).Replace('-',''); if($env:PT_SU_MODE -eq 'list'){ $i=0; $o=@(); foreach($x in $E){ $i++; $dn=$x[2] -replace '[\x00-\x1f\x7f]','?' -replace '[\x21\x22\x25\x26\x3c\x3e\x5e\x7c]','?'; $o+=(''+$i+'|'+(S $x[1] $x[2])+'|'+$x[0]+'|'+$dn) }; $o | Wu8 $env:PT_SU_LIST; if($env:PT_SU_SIG){ $sg | Out-File -FilePath $env:PT_SU_SIG -Encoding ASCII }; exit 0 }; if($env:PT_SU_SIGIN -and $env:PT_SU_SIGIN -ne $sg){ 'The startup list changed since it was displayed - something added or removed an entry. Nothing was modified. The refreshed list is shown below; pick again.' | Wu8 $env:PT_SU_RES; exit 1 }; $n=0; try{ $n=[int]$env:PT_SU_IDX }catch{ $n=0 }; if($n -lt 1 -or $n -gt $E.Count){ 'Entry not found - the startup list changed. Nothing was modified.' | Wu8 $env:PT_SU_RES; exit 1 }; $x=$E[$n-1]; $appr=$x[1]; $name=$x[2]; $cur=S $appr $name; $had=$false; $raw=$null; $k=Get-Item -LiteralPath $appr -ErrorAction SilentlyContinue; if($k){ $raw=$k.GetValue($name); if($null -ne $raw){ $had=$true } }; $rk=$appr.Replace('HKCU:','HKEY_CURRENT_USER').Replace('HKLM:','HKEY_LOCAL_MACHINE'); $q=[char]34; $en=$name.Replace('\','\\').Replace([string]$q,'\'+$q); $bak=Join-Path $env:PT_SU_BAK ('StartupApproved_'+(Get-Random)+'.reg'); $body=@('Windows Registry Editor Version 5.00','','['+$rk+']'); if($had -and ($raw -is [byte[]])){ $hex=(($raw | ForEach-Object { $_.ToString('x2') }) -join ','); $body+=($q+$en+$q+'=hex:'+$hex) } elseif($had){ $body+=('; original value was not REG_BINARY - not auto-restorable from this file') } else { $body+=($q+$en+$q+'=-') }; $body | Out-File -FilePath $bak -Encoding Unicode; if(-not (Test-Path -LiteralPath $bak)){ 'Could not write the undo backup - antivirus or Controlled Folder Access may be blocking the backup folder. The startup entry was NOT changed.' | Wu8 $env:PT_SU_RES; exit 1 }; if($cur -eq 'Enabled'){ $new=[byte[]](3,0,0,0)+[BitConverter]::GetBytes([DateTime]::Now.ToFileTime()); $ns='Disabled' } else { $new=[byte[]](2,0,0,0,0,0,0,0,0,0,0,0); $ns='Enabled' }; try{ [Microsoft.Win32.Registry]::SetValue($rk,$name,[byte[]]$new,[Microsoft.Win32.RegistryValueKind]::Binary) }catch{ Remove-Item -LiteralPath $bak -ErrorAction SilentlyContinue; ('Could not write the new state: '+$_.Exception.Message) | Wu8 $env:PT_SU_RES; exit 1 }; $dn=$name -replace '[\x00-\x1f\x7f]','?'; ((''+$dn+' : '+$cur+' -> '+$ns),('Backup of the previous state: '+$bak)) | Wu8 $env:PT_SU_RES; exit 0"
set "_swrc=%errorlevel%"
set "PT_SU_MODE=" & set "PT_SU_IDX=" & set "PT_SU_LIST=" & set "PT_SU_RES=" & set "PT_SU_BAK="
set "PT_SU_SIG=" & set "PT_SU_SIGIN="
exit /b %_swrc%

:RequireBundledFile
rem %1 = filename beside PerfTweaks.cmd   %2 = short description for messages/log
rem Returns 0 = present and non-empty, 1 = missing or empty. The caller must check it and abort.
rem Never goto a menu from here: only goto :eof or exit /b pops the call frame.
set "_bundled=!SCRIPT_DIR!%~1"
set "_bundled_sz="
if exist "!_bundled!" for %%F in ("!_bundled!") do set "_bundled_sz=%%~zF"
if exist "!_bundled!" if defined _bundled_sz if not "!_bundled_sz!"=="0" exit /b 0
echo.
if not exist "!_bundled!" (
    echo [ERROR] Bundled file not found: %~1
) else (
    echo [ERROR] Bundled file is empty: %~1
)
echo.
echo   Expected location:
echo     !_bundled!
echo.
echo   Used for: %~2
echo.
echo   Fix: copy %~1 into the same folder as PerfTweaks.cmd, then run this option again.
echo        It is listed under "Optional bundled files" in the Sincript README.
call :Log "ABORT: missing/empty bundled %~1 (%~2)"
pause
exit /b 1

:DetectUnityJobWorkers
rem Sets _JWCOUNT and _CORESRC. Logical processors (threads) - 1 when detectable; else prompt.
setlocal EnableDelayedExpansion
set "_JWCOUNT="
set "_CORESRC="
set "_LOGI=0"
rem  A separate minimized PowerShell window keeps this console's font intact.
set "_coresf=!TEMP!\pt_cores_%RANDOM%%RANDOM%.txt"
set "PT_CORESF=!_coresf!"
start "" /min /wait powershell -NoProfile -Command "try{$s=(Get-CimInstance Win32_Processor|Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum;if(-not $s){$s=0}}catch{$s=0}; $s | Out-File -FilePath $env:PT_CORESF -Encoding ASCII"
set "PT_CORESF="
if exist "!_coresf!" for /f "usebackq tokens=1 delims= " %%N in ("!_coresf!") do set "_LOGI=%%N"
del "!_coresf!" >nul 2>&1
if !_LOGI! gtr 0 (
    set /a "_JWCOUNT=!_LOGI!-1"
    set "_CORESRC=!_LOGI! logical processors"
    goto DetectUnityJobWorkers_clamp
)
for /f "tokens=2 delims==" %%C in ('wmic cpu get NumberOfLogicalProcessors /value 2^>nul ^| findstr /I "NumberOfLogicalProcessors"') do set /a "_LOGI+=%%C" 2>nul
if !_LOGI! gtr 0 (
    set /a "_JWCOUNT=!_LOGI!-1"
    set "_CORESRC=!_LOGI! logical processors (WMIC)"
    goto DetectUnityJobWorkers_clamp
)
if defined NUMBER_OF_PROCESSORS (
    set /a "_JWCOUNT=%NUMBER_OF_PROCESSORS%-1"
    set "_CORESRC=%NUMBER_OF_PROCESSORS% logical processors"
    goto DetectUnityJobWorkers_clamp
)
echo.
echo [WARN] Could not detect CPU core count automatically.

:DetectUnityJobWorkers_ask
set "_in="
set /p "_in=Enter job-worker count for Unity (usually logical CPUs minus 1, e.g. 7 for 8 threads): "
if not defined _in call :NoInput || goto DetectUnityJobWorkers_giveup
if not defined _in goto DetectUnityJobWorkers_ask
rem  No pipe: a pipe re-parses the typed text, so an ampersand in it would run a command.
rem  for /f yields a token only for a non-digit; eol=0 so a leading semicolon is not skipped.
set "_inbad="
for /f "eol=0 delims=0123456789" %%X in ("!_in!") do set "_inbad=1"
if defined _inbad (
    echo [ERROR] Enter a whole number between 1 and 32.
    goto DetectUnityJobWorkers_ask
)
set "_JWCOUNT=!_in!"
set "_CORESRC=user specified"
goto DetectUnityJobWorkers_clamp

:DetectUnityJobWorkers_giveup
rem  Reached only when stdin is exhausted. A called routine must not goto a menu, as that leaves
rem  a call frame pending; return a safe default and let the caller unwind.
set "_JWCOUNT=1"
set "_CORESRC=no input available - defaulted to 1"

:DetectUnityJobWorkers_clamp
if !_JWCOUNT! lss 1 set "_JWCOUNT=1"
if !_JWCOUNT! gtr 32 set "_JWCOUNT=32"
set "_DJW=!_JWCOUNT!"
set "_DCS=!_CORESRC!"
endlocal & set "_JWCOUNT=%_DJW%" & set "_CORESRC=%_DCS%"
goto :eof

:PrepareBootConfig
rem  In: PT_SRC = source boot.config, PT_OUT = output path, PT_JW = count for both worker keys.
rem  Set by the caller, not passed as call arguments, so special characters in the path survive.
start "" /min /wait powershell -NoProfile -Command "try{$n=$env:PT_JW;$out=@();foreach($line in Get-Content -LiteralPath $env:PT_SRC){if($line -match '^job-worker-count='){$out+='job-worker-count='+$n}elseif($line -match '^job-worker-maximum-count='){$out+='job-worker-maximum-count='+$n}else{$out+=$line}};Set-Content -LiteralPath $env:PT_OUT -Value $out -Encoding ASCII;exit 0}catch{exit 1}"
set "_pbc=%errorlevel%"
set "_pbout=!PT_OUT!"
set "PT_SRC=" & set "PT_OUT=" & set "PT_JW="
if "%_pbc%"=="1" exit /b 1
if not exist "!_pbout!" exit /b 1
exit /b 0
rem =====================================================================================
rem  SUBMENU: System tools
rem =====================================================================================
:MenuTools
cls
call :Logo
rem  PT_PE_SCOPE picks the hive the PATH worker reads and writes. Cleared on entry so the editor
rem  only acts on a scope chosen this visit.
set "PT_PE_SCOPE="
echo =========================================  SYSTEM TOOLS  =========================================
echo  General-purpose tools, not tweaks. Each one reads first; the crash report only reads.
echo  A PATH edit is backed up first; closing a process cannot be undone ^(its unsaved work is lost^).
echo     1.  Edit PATH (System / User environment variable)
echo     2.  Find what is locking a file (and optionally close it)
echo     3.  Crash ^& hardware-error report (read-only, from the event logs)
echo     0.  Back
echo ==================================================================================================

:MenuTools_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuTools_ask
if "!sel!"=="1" goto PathEditor
if "!sel!"=="2" goto LockFinder
if "!sel!"=="3" goto CrashReport
if "!sel!"=="0" goto MainMenu
goto MenuTools
rem =====================================================================================
rem  ACTION: PATH editor  (System Manager\Environment or HKCU\Environment)
rem =====================================================================================
:PathEditor
cls
call :Logo
echo ======================================  EDIT PATH VARIABLE  ======================================
echo  Reads the RAW value straight from the registry, so %%VAR%% references stay intact,
echo  and writes it back as REG_EXPAND_SZ - the type PATH must keep. It never uses
echo  setx (which silently crops at 1024 chars and freezes %%VAR%% into literal paths).
echo  Every edit first backs up the whole Environment key ^(PATH and the other variables in it^),
echo  then broadcasts the change so new programs see it without a sign-out.
echo --------------------------------------------------------------------------------------------------
echo  Which PATH?
echo     1.  System  (HKLM - affects all users, needs Administrator)
echo     2.  User    (HKCU - just you)
echo     0.  Back
set "_pesc="
set /p "_pesc=Choose: "
if not defined _pesc goto MenuTools
if "!_pesc!"=="1" ( set "PT_PE_SCOPE=machine" & goto PathEditor_show )
if "!_pesc!"=="2" ( set "PT_PE_SCOPE=user" & goto PathEditor_show )
if "!_pesc!"=="0" goto MenuTools
goto PathEditor

:PathEditor_show
if /i "%PT_PE_SCOPE%"=="machine" if "%_ELEV%"=="0" (
    echo.
    echo  [WARN] Editing the System PATH needs Administrator, and this window is not
    echo         elevated - a save would fail. Close this window and re-launch it
    echo         with Run as administrator, or pick User PATH instead.
    echo.
    pause
    goto PathEditor
)
set "_pelist=!TEMP!\pt_path_%RANDOM%.txt"
set "_peres=!TEMP!\pt_pathres_%RANDOM%.txt"
del "!_pelist!" >nul 2>&1
call :PathWorker list ""
if not exist "!_pelist!" (
    echo [ERROR] Could not read the PATH value ^(PowerShell blocked or unavailable^).
    pause
    goto MenuTools
)
set "_pen=0"
call :Utf8On
for /f "usebackq tokens=1,2,* delims=|" %%a in ("!_pelist!") do (
    set /a _pen+=1
    set "_pest[!_pen!]=%%b"
    set "_penm[!_pen!]=%%c"
)
call :Utf8Off
del "!_pelist!" >nul 2>&1
echo.
if /i "%PT_PE_SCOPE%"=="machine" ( echo  System PATH - %_pen% entry^(ies^): ) else ( echo  User PATH - %_pen% entry^(ies^): )
echo   #   State    Folder
echo --------------------------------------------------------------------------------------------------
for /l %%I in (1,1,%_pen%) do call :_peShow %%I
echo --------------------------------------------------------------------------------------------------
echo  [missing] = the folder does not exist on disk ^(a dead PATH entry^).
echo  Folders are shown ASCII-only ^("?"^ for other characters^); an edit still targets
echo  the exact entry.

:PathEditor_ask
echo.
echo     A.  Add a folder            R.  Remove an entry by number
echo     D.  Remove all dead ^(missing^) entries      C.  Clean duplicate entries
echo     0.  Back
set "_pea="
set /p "_pea=Choose: "
if not defined _pea call :NoInput || goto ExitScript
if not defined _pea goto PathEditor_ask
if /i "!_pea!"=="0" goto MenuTools
if /i "!_pea!"=="A" goto PathEditor_add
if /i "!_pea!"=="R" goto PathEditor_remove
if /i "!_pea!"=="D" ( set "PT_PE_ARG=" & call :PathEditor_run dropdead "" & goto PathEditor_show )
if /i "!_pea!"=="C" ( set "PT_PE_ARG=" & call :PathEditor_run dedupe "" & goto PathEditor_show )
goto PathEditor_ask

:PathEditor_add
echo.
echo  Type or paste the folder to add ^(it is added at the END of PATH^).
set "_pfolder="
set /p "_pfolder=Folder (blank = cancel): "
if not defined _pfolder goto PathEditor_ask
rem  Strip quotes, as Explorer's Copy as path adds them.
set "_pfolder=!_pfolder:"=!"
if not defined _pfolder goto PathEditor_ask
rem  Pass the folder in PT_PE_ARG, not as a call argument: each call re-expands percent signs.
set "PT_PE_ARG=!_pfolder!"
call :PathEditor_run add ""
goto PathEditor_show

:PathEditor_remove
echo.
set "_prm="
set /p "_prm=Number to remove (0 = cancel): "
if not defined _prm goto PathEditor_ask
if "!_prm!"=="0" goto PathEditor_ask
set "_pok="
for /l %%I in (1,1,%_pen%) do if "!_prm!"=="%%I" set "_pok=1"
rem  Guarded like every prompt: each backward jump's cycle passes through a NoInput guard.
if not defined _pok call :NoInput || goto ExitScript
if not defined _pok goto PathEditor_remove
echo.
echo  About to remove:  !_penm[%_prm%]!
set "_pc="
set /p "_pc=Proceed? (Y/N): "
if /i not "!_pc!"=="Y" goto PathEditor_ask
call :PathEditor_run removeidx "%_prm%"
goto PathEditor_show

:PathEditor_run
rem  %1 = verb (add|removeidx|dropdead|dedupe)   %2 = argument (folder or index)
rem  Backs up the Environment key first, runs the PS worker, then reports from its result file.
set "_pverb=%~1"
set "_parg=%~2"
if /i "%PT_PE_SCOPE%"=="machine" (
    set "_pekey=HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
) else (
    set "_pekey=HKCU\Environment"
)
rem  No backup, no edit: if the Environment key export fails, PATH is not touched.
set "_BSV_OK="
call :BackupSingleValue "!_pekey!" "Path" "PATH (before %_pverb%)"
if not defined _BSV_OK (
    echo.
    echo  [ABORT] PATH was NOT changed - no backup could be written, and a PATH edit
    echo          you cannot undo is not worth the risk. Check that the backup folder
    echo          is writable, then try again.
    echo.
    pause
    goto :eof
)
del "!_peres!" >nul 2>&1
call :PathWorker "%_pverb%" "%_parg%"
set "_perc=%errorlevel%"
echo.
call :Utf8On
if exist "!_peres!" type "!_peres!"
call :Utf8Off
del "!_peres!" >nul 2>&1
if "%_perc%"=="0" (
    call :Log "PATH %PT_PE_SCOPE% %_pverb% ok"
) else (
    echo [ERROR] The PATH edit failed - nothing was changed. If this is the System PATH,
    echo         make sure the window is elevated, then try again.
    call :Log "PATH %PT_PE_SCOPE% %_pverb% FAILED rc=%_perc%"
)
pause
goto :eof

:_peShow
rem %1 = 1-based index; prints one aligned row (# / state / folder).
set "_q1=%1.    "
set "_q1=!_q1:~0,4!"
set "_q2=!_pest[%1]!         "
set "_q2=!_q2:~0,9!"
set "_q3=!_penm[%1]!"
echo   !_q1!!_q2!!_q3:~0,64!
goto :eof

:PathWorker
rem  %1 = list | add | removeidx | dropdead | dedupe     %2 = folder (add) or index (removeidx)
rem  PS worker, minimized. Reads the raw REG_EXPAND_SZ PATH so VAR references stay intact, edits
rem  it in .NET, writes it back as REG_EXPAND_SZ and broadcasts WM_SETTINGCHANGE. Entry text never
rem  round-trips through cmd: the listed number maps to the same split index.
set "PT_PE_MODE=%~1"
rem  Overwrite PT_PE_ARG only when an argument is passed: add sets it directly, the rest clear it.
if not "%~2"=="" set "PT_PE_ARG=%~2"
set "PT_PE_LIST=!_pelist!"
set "PT_PE_RES=!_peres!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; function Wu8($p){ [IO.File]::WriteAllLines($p,[string[]]@($input),(New-Object Text.UTF8Encoding $false)) }; $scope=$env:PT_PE_SCOPE; if($scope -eq 'machine'){ $root=[Microsoft.Win32.Registry]::LocalMachine; $sub='SYSTEM\CurrentControlSet\Control\Session Manager\Environment' } else { $root=[Microsoft.Win32.Registry]::CurrentUser; $sub='Environment' }; $k=$root.OpenSubKey($sub,$false); $raw=''; if($k){ $raw=[string]$k.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $k.Close() }; $parts=@(); if($raw){ foreach($p in ($raw -split ';')){ if($p -ne ''){ $parts+=$p } } }; $mode=$env:PT_PE_MODE; if($mode -eq 'list'){ $i=0; $o=@(); foreach($p in $parts){ $i++; $exp=[Environment]::ExpandEnvironmentVariables($p); $state=if(Test-Path -LiteralPath $exp -PathType Container){'ok'}else{'[missing]'}; $dn=$p -replace '[\x00-\x1f\x7f]','?'; $o+=(''+$i+'|'+$state+'|'+$dn) }; $o | Wu8 $env:PT_PE_LIST; exit 0 }; $orig=$parts.Count; $changed=$false; $note=''; if($mode -eq 'add'){ $f=$env:PT_PE_ARG; if($f){ if($f.EndsWith('\')){ $f=$f.TrimEnd('\') }; $exists=$false; foreach($p in $parts){ if($p -ieq $f){ $exists=$true } }; if($exists){ $note='That folder is already in PATH - nothing added.' } else { $parts+=$f; $changed=$true; $note='Added: '+($f -replace '[\x00-\x1f\x7f]','?') } } } elseif($mode -eq 'removeidx'){ $n=0; try{ $n=[int]$env:PT_PE_ARG }catch{ $n=0 }; if($n -ge 1 -and $n -le $parts.Count){ $rm=$parts[$n-1]; $keep=@(); for($j=0;$j -lt $parts.Count;$j++){ if($j -ne ($n-1)){ $keep+=$parts[$j] } }; $parts=$keep; $changed=$true; $note='Removed: '+($rm -replace '[\x00-\x1f\x7f]','?') } else { $note='That number is not in the list - nothing removed.' } } elseif($mode -eq 'dropdead'){ $keep=@(); $drop=0; foreach($p in $parts){ $exp=[Environment]::ExpandEnvironmentVariables($p); if(Test-Path -LiteralPath $exp -PathType Container){ $keep+=$p } else { $drop++ } }; if($drop -gt 0){ $parts=$keep; $changed=$true }; $note='Removed '+$drop+' dead entry(ies).' } elseif($mode -eq 'dedupe'){ $seen=@{}; $keep=@(); $drop=0; foreach($p in $parts){ $key=$p.ToLowerInvariant(); if($seen.ContainsKey($key)){ $drop++ } else { $seen[$key]=$true; $keep+=$p } }; if($drop -gt 0){ $parts=$keep; $changed=$true }; $note='Removed '+$drop+' duplicate entry(ies).' }; if(-not $changed){ $note | Wu8 $env:PT_PE_RES; exit 0 }; $new=($parts -join ';'); if($scope -eq 'machine'){ $kw=$root.OpenSubKey($sub,$true) } else { $kw=$root.OpenSubKey($sub,$true) }; if(-not $kw){ ('Could not open PATH for writing.') | Wu8 $env:PT_PE_RES; exit 1 }; try{ $kw.SetValue('Path',$new,[Microsoft.Win32.RegistryValueKind]::ExpandString); $kw.Close() }catch{ ('Write failed: '+$_.Exception.Message) | Wu8 $env:PT_PE_RES; exit 1 }; try{ $sig='using System;using System.Runtime.InteropServices;namespace PTB{public static class N{[DllImport(\"user32.dll\",CharSet=CharSet.Auto)]public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,string l,uint f,uint t,out UIntPtr r);}}'; Add-Type -TypeDefinition $sig -Language CSharp; $r=[UIntPtr]::Zero; [void][PTB.N]::SendMessageTimeout([IntPtr]0xffff,0x1A,[IntPtr]::Zero,'Environment',2,5000,[ref]$r) }catch{}; ($note+[Environment]::NewLine+'PATH updated. New programs and shells see it now; already-open ones keep the old value until restarted.') | Wu8 $env:PT_PE_RES; exit 0"
set "_pwrc=%errorlevel%"
set "PT_PE_MODE=" & set "PT_PE_ARG=" & set "PT_PE_LIST=" & set "PT_PE_RES="
exit /b %_pwrc%
rem =====================================================================================
rem  ACTION: Find what is locking a file  (Restart Manager)
rem =====================================================================================
:LockFinder
cls
call :Logo
echo =================================  FIND WHAT IS LOCKING A FILE  ==================================
echo  Uses the Windows Restart Manager - the same API installers use to find what
echo  has a file open. It lists every process holding the file, and marks the ones
echo  Windows flags as critical system processes ^(which must never be force-closed^).
echo  Listing is always safe; closing a process is opt-in, one at a time, and confirmed.
echo --------------------------------------------------------------------------------------------------
echo  Type or paste the full path to the file ^(e.g. a DLL or document you cannot delete^).
set "_lfpath="
set /p "_lfpath=File path (blank = back): "
if not defined _lfpath goto MenuTools
rem  Strip quotes, as Explorer's Copy as path adds them.
if defined _lfpath set "_lfpath=!_lfpath:"=!"
if not defined _lfpath goto MenuTools
rem  Print the path late, with delayed expansion: at parse time a paren in it ends the block.
if not exist "!_lfpath!" (
    echo.
    echo  [ERROR] No such file: !_lfpath!
    echo          Give the full path to an existing file.
    echo.
    pause
    goto LockFinder
)
set "_lflist=!TEMP!\pt_lock_%RANDOM%.txt"
set "_lfres=!TEMP!\pt_lockres_%RANDOM%.txt"
del "!_lflist!" >nul 2>&1
set "PT_LF_FILE=!_lfpath!"
call :LockWorker list
if not exist "!_lflist!" (
    echo [ERROR] Could not query the file ^(PowerShell blocked, or the Restart Manager
    echo         service is unavailable^).
    pause
    goto MenuTools
)
set "_lfn=0"
call :Utf8On
for /f "usebackq tokens=1,2,3,4,* delims=|" %%a in ("!_lflist!") do (
    set /a _lfn+=1
    set "_lfpid[!_lfn!]=%%b"
    set "_lfcrit[!_lfn!]=%%c"
    set "_lfnm[!_lfn!]=%%d"
)
call :Utf8Off
del "!_lflist!" >nul 2>&1
echo.
if "%_lfn%"=="0" (
    echo  Nothing is holding that file open - it is free. If Explorer still refuses to
    echo  delete it, try refreshing the folder ^(F5^) or closing an Explorer preview pane.
    echo.
    pause
    goto MenuTools
)
echo  %_lfn% process^(es^) holding this file:
echo   #    PID     Type        Process
echo --------------------------------------------------------------------------------------------------
for /l %%I in (1,1,%_lfn%) do call :_lfShow %%I
echo --------------------------------------------------------------------------------------------------
echo  [critical] = a core Windows process. Sincript will NOT close these - a reboot is
echo  the only safe way to release a file they hold.

:LockFinder_ask
echo.
set "_lfk="
set /p "_lfk=Number to close (0 = back): "
if not defined _lfk call :NoInput || goto ExitScript
if not defined _lfk goto LockFinder_ask
if "!_lfk!"=="0" goto MenuTools
set "_lok="
for /l %%I in (1,1,%_lfn%) do if "!_lfk!"=="%%I" set "_lok=1"
if not defined _lok goto LockFinder_ask
rem  The loop above proved _lfk is an integer in 1..N; index with that copy, _lfi, from here on,
rem  so no raw input is ever percent-expanded inside a block.
set "_lfi=%_lfk%"
if /i "!_lfcrit[%_lfi%]!"=="critical" (
    echo.
    echo  [BLOCKED] !_lfnm[%_lfi%]! is a critical Windows process. Closing it would crash
    echo            or freeze Windows. Reboot to release the file instead.
    goto LockFinder_ask
)
echo.
echo  About to force-close:  PID !_lfpid[%_lfi%]!  -  !_lfnm[%_lfi%]!
echo  Any unsaved work in that program will be LOST. This does not delete the file.
set "_lc="
set /p "_lc=Proceed? (Y/N): "
if /i not "!_lc!"=="Y" goto LockFinder_ask
call :Run "taskkill /PID !_lfpid[%_lfi%]! /F"
echo.
echo  If it closed, the file should now be free. Re-checking...
echo.
del "!_lflist!" >nul 2>&1
set "PT_LF_FILE=!_lfpath!"
call :LockWorker list
set "_lfn2=0"
if not exist "!_lflist!" goto _lfRecheckFail
for /f "usebackq tokens=1 delims=|" %%a in ("!_lflist!") do set /a _lfn2+=1
del "!_lflist!" >nul 2>&1
if "%_lfn2%"=="0" (
    echo  [OK] Nothing is holding the file now.
) else (
    echo  [NOTE] %_lfn2% process^(es^) still hold it - it may have relaunched, or another
    echo         program opened it. Re-run to see the current list.
)
pause
goto MenuTools

:_lfRecheckFail
rem  No list means the worker's query failed - not that the file is free.
echo  [WARN] The file could not be checked again ^(the Restart Manager query failed^). Run the
echo         lock finder again to see whether it is free now.
pause
goto MenuTools

:_lfShow
rem %1 = 1-based index; prints one aligned row (# / pid / type / name).
set "_r1=%1.    "
set "_r1=!_r1:~0,5!"
set "_r2=!_lfpid[%1]!        "
set "_r2=!_r2:~0,8!"
set "_r3=!_lfcrit[%1]!            "
set "_r3=!_r3:~0,12!"
set "_r4=!_lfnm[%1]!"
echo   !_r1!!_r2!!_r3!!_r4:~0,52!
goto :eof

:LockWorker
rem  Arg 1 = list. The path comes in PT_LF_FILE, set by the caller, so special characters survive.
rem  Restart Manager lists the holders; critical ones are never closed. The PID drives any close.
rem  A failed query exits 4 and writes NO list, so it never reads as nothing holds the file.
set "PT_LF_LIST=!_lflist!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; function Wu8($p){ [IO.File]::WriteAllLines($p,[string[]]@($input),(New-Object Text.UTF8Encoding $false)) }; $sig='using System;using System.Runtime.InteropServices;namespace PTR{[StructLayout(LayoutKind.Sequential)]public struct RUP{public int pid;public System.Runtime.InteropServices.ComTypes.FILETIME ft;}public enum AT{Unknown=0,MainWindow=1,OtherWindow=2,Service=3,Explorer=4,Console=5,Critical=1000}[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct PI{public RUP Process;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string app;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)]public string svc;public AT AppType;public uint Status;public uint Sess;[MarshalAs(UnmanagedType.Bool)]public bool restart;}public static class Rm{[DllImport(\"rstrtmgr.dll\",CharSet=CharSet.Unicode)]public static extern int RmStartSession(out uint h,int f,string k);[DllImport(\"rstrtmgr.dll\")]public static extern int RmEndSession(uint h);[DllImport(\"rstrtmgr.dll\",CharSet=CharSet.Unicode)]public static extern int RmRegisterResources(uint h,uint nf,string[] fs,uint na,RUP[] a,uint ns,string[] s);[DllImport(\"rstrtmgr.dll\")]public static extern int RmGetList(uint h,out uint need,ref uint have,[In,Out]PI[] arr,ref uint reason);}}'; try{ Add-Type -TypeDefinition $sig -Language CSharp }catch{ exit 3 }; $file=$env:PT_LF_FILE; $key=[Guid]::NewGuid().ToString(); $h=0; if([PTR.Rm]::RmStartSession([ref]$h,0,$key) -ne 0){ exit 4 }; $out=@(); $bad=$false; try{ if([PTR.Rm]::RmRegisterResources($h,1,@($file),0,$null,0,$null) -ne 0){ throw }; [uint32]$need=0;[uint32]$have=0;[uint32]$reason=0; $rc=[PTR.Rm]::RmGetList($h,[ref]$need,[ref]$have,$null,[ref]$reason); if($rc -ne 0 -and $rc -ne 234){ throw }; if($need -gt 0){ $arr=[PTR.PI[]]::new($need); $have=$need; $rc=[PTR.Rm]::RmGetList($h,[ref]$need,[ref]$have,$arr,[ref]$reason); if($rc -ne 0){ throw }; if($rc -eq 0){ $i=0; for($j=0;$j -lt [int]$have;$j++){ $p=$arr[$j]; $i++; $nm=$p.app; if(-not $nm){ $nm='(pid '+$p.Process.pid+')' }; $dn=$nm -replace '[\x00-\x1f\x7f]','?'; $crit=if($p.AppType -eq [PTR.AT]::Critical){'critical'}else{'normal'}; $out+=(''+$i+'|'+$p.Process.pid+'|'+$crit+'|'+$dn+'|') } } } }catch{ $bad=$true }; [PTR.Rm]::RmEndSession($h) | Out-Null; if($bad){ exit 4 }; $out | Wu8 $env:PT_LF_LIST; exit 0"
set "_lwrc=%errorlevel%"
set "PT_LF_LIST=" & set "PT_LF_FILE="
exit /b %_lwrc%
rem =====================================================================================
rem  ACTION: Crash & hardware-error report  (read-only: reads two event logs, changes nothing)
rem =====================================================================================
:CrashReport
rem  Recent crashes and hardware, disk, driver and memory errors from the System and Application
rem  logs. Reads provider, event ID, level and named fields only - never the localized message text.
rem  Uses EventLogReader, not Get-WinEvent: that one reports an unreadable log as no events. A log
rem  is proven readable by reading its oldest record first; an unreadable one never counts as none
rem  found, and each none found is bounded by the days the log still holds. Three workers, as cmd
rem  caps a line at 8191 characters; the normalized events file between them is also the test input.
cls
call :Logo
echo ================================  CRASH ^& HARDWARE-ERROR REPORT  =================================
echo  Reads the System and Application event logs: which Windows component logged which event,
echo  at what level, and when. Never the message text. Read-only - nothing is changed.
echo --------------------------------------------------------------------------------------------------
echo  Reading the event logs ^(three short PowerShell steps; about 10 seconds, no input accepted^)...
call :DetectUndervolt
rem  The day window is set only here; the workers read it from PT_CR_DAYS.
set "_crdays=30"
set "_crcsv=!TEMP!\pt_crev_%RANDOM%%RANDOM%.txt"
set "_crsum=!TEMP!\pt_crsum_%RANDOM%%RANDOM%.txt"
set "_crstat=!TEMP!\pt_crstat_%RANDOM%%RANDOM%.txt"
set "_crlt=!TEMP!\pt_crlt_%RANDOM%%RANDOM%.txt"
set "_crtl=!TEMP!\pt_crtl_%RANDOM%%RANDOM%.txt"
set "_crhnt=!TEMP!\pt_crhnt_%RANDOM%%RANDOM%.txt"
call :_crCleanup
call :CrashCollect
if not exist "!_crcsv!" goto _crNoRead
call :CrashSummary
call :CrashTimeline
del "!_crcsv!" >nul 2>&1
if not exist "!_crsum!" goto _crNoRead
if not exist "!_crlt!" goto _crNoRead
call :_crReadStat
if not defined _cr_sys goto _crNoRead
rem  Hints are written one call level down, so the stderr redirect here covers a failed open.
rem  A missing hints file is reported, never shown as no hints.
set "_crnh=0"
set "_crhbad="
call :_crHintsFile 2>nul
if not exist "!_crhnt!" set "_crhbad=1"
set "_LOGMSG=CRASHREPORT system=!_cr_sys! !_cr_sysdays!d application=!_cr_app! !_cr_appdays!d hints=!_crnh!" & call :LogVar _LOGMSG

:CrashReport_show
cls
echo ================================  CRASH ^& HARDWARE-ERROR REPORT  =================================
type "!_crsum!"
echo.
type "!_crlt!"
echo --------------------------------------------------------------------------------------------------
call :_crVerdict
if defined _crhbad echo  [WARN] The hints could not be prepared - their temp file could not be written.
if not defined _crhbad if not "!_crnh!"=="0" echo  [i] !_crnh! hint^(s^) about what was found - press H to read them.
echo     H.  Hints     S.  Save this report to the backup folder     0.  Back

:CrashReport_ask
set "_crk="
set /p "_crk=Choose: "
if not defined _crk call :NoInput || goto _crQuit
if not defined _crk goto CrashReport_ask
if /i "!_crk!"=="H" goto _crHints
if /i "!_crk!"=="S" goto _crSave
if "!_crk!"=="0" goto _crLeave
goto CrashReport_ask

:_crHints
cls
echo ================================  CRASH ^& HARDWARE-ERROR REPORT  =================================
if defined _crhbad echo  [WARN] The hints could not be prepared - their temp file could not be written.
if not defined _crhbad if "!_crnh!"=="0" echo  No hints: nothing in this report matches a case with documented advice.
if exist "!_crhnt!" type "!_crhnt!"
echo --------------------------------------------------------------------------------------------------
pause
goto CrashReport_show

:_crSave
rem  Saves plain ASCII: summary, timeline, final line and hints. Never message text, file paths or
rem  user names - a service command line can hold a secret. The stamp is checked to be digits and _.
if not exist "!BACKUP_DIR!\" goto _crSaveFail
set "_crbad="
if not defined _cr_stamp set "_crbad=1"
if defined _cr_stamp for /f "eol=_ delims=0123456789_" %%X in ("!_cr_stamp!") do set "_crbad=1"
if defined _crbad set "_cr_stamp=report"
set "_crout=!BACKUP_DIR!\CrashReport_!_cr_stamp!_%RANDOM%.txt"
call :_crWrite 2>nul
if not exist "!_crout!" goto _crSaveFail
echo.
echo  [OK] Saved: !_crout!
set "_LOGMSG=CRASHREPORT saved -> !_crout!" & call :LogVar _LOGMSG
pause
goto CrashReport_show

:_crSaveFail
echo.
echo  [FAIL] The report could not be written to the backup folder:
echo           !BACKUP_DIR!
call :Log "FAIL: CRASHREPORT could not be saved"
pause
goto CrashReport_show

:_crNoRead
call :_crCleanup
echo.
echo  [FAIL] The event logs could not be read: PowerShell is blocked or unavailable, or its output
echo         could not be written to the temp folder. Nothing was checked - this is NOT a clean
echo         bill of health.
call :Log "FAIL: CRASHREPORT workers produced no output"
pause
goto MenuTools

:_crLeave
call :_crCleanup
goto MenuTools

:_crQuit
call :_crCleanup
goto ExitScript

:_crWrite
rem  One call level down so the caller's stderr redirect covers a file that cannot be opened.
rem  Carries the same final line as the screen, so a saved failed or partial read says so itself.
> "!_crout!" echo sincript - crash and hardware-error report
>>"!_crout!" echo Generated !_cr_gen!. Window: the last !_cr_days! days. Read by provider, event ID,
>>"!_crout!" echo level and named data fields only - no message text, no file paths, no user names.
>>"!_crout!" echo.
type "!_crsum!" >>"!_crout!"
>>"!_crout!" echo.
if exist "!_crtl!" type "!_crtl!" >>"!_crout!"
>>"!_crout!" echo.
>>"!_crout!" (call :_crVerdict)
>>"!_crout!" echo.
if defined _crhbad >>"!_crout!" echo  [WARN] The hints could not be prepared - their temp file could not be written.
if exist "!_crhnt!" type "!_crhnt!" >>"!_crout!"
goto :eof

:_crHintsFile
rem  One call level down so the caller's stderr redirect covers a file that cannot be opened.
>"!_crhnt!" (call :CrashHints)
goto :eof

:_crVerdict
rem  Reports the READ, not the machine: FAIL for an unreadable log, WARN for a capped or short
rem  read, OK only when both were read in full. Flat gotos: the text has parens. Echo only.
if /i "!_cr_sys!"=="fail" goto _crvFail
if /i "!_cr_app!"=="fail" goto _crvAppFail
if not "!_cr_capped!"=="0" goto _crvCap
if /i not "!_cr_sys!"=="ok" goto _crvShort
if /i not "!_cr_app!"=="ok" goto _crvShort
echo  [OK] Both logs were read and cover the full !_cr_days! days.
goto :eof

:_crvShort
echo  [WARN] Read, but not all !_cr_days! days of both logs - each "none found" above only covers
echo         the days its log still holds ^(see the first lines^).
goto :eof

:_crvCap
echo  [WARN] Reading stopped at !_cr_capped! matching events ^(newest first^): the counts above are a
echo         minimum, and each "none found" only covers the days that were read.
goto :eof

:_crvAppFail
echo  [FAIL] The Application log could not be read, so app crashes were NOT checked. Open Event
echo         Viewer, or run sincript from an elevated window and try again.
goto :eof

:_crvFail
echo  [FAIL] The System log could not be read, so nothing above rules out a crash. Open Event
echo         Viewer, or run sincript from an elevated window and try again.
goto :eof

:_crReadStat
rem  Takes only whitelisted KEY=VALUE lines, into _cr_* variables. Counts default to 0, so a missing
rem  key can only drop a hint, never invent one.
set "_crkeys=sys app sysdays appdays days gen stamp capped hw mce nocode vm46 disk ntfs rex tdr drvdate sin drv"
for %%K in (!_crkeys!) do set "_cr_%%K="
if not exist "!_crstat!" goto :eof
for /f "usebackq tokens=1,* delims==" %%a in ("!_crstat!") do for %%K in (!_crkeys!) do if /i "%%a"=="%%K" set "_cr_%%K=%%b"
for %%K in (capped hw mce nocode vm46 disk ntfs rex tdr) do if not defined _cr_%%K set "_cr_%%K=0"
if not defined _cr_days set "_cr_days=!_crdays!"
goto :eof

:_crCleanup
del "!_crcsv!" "!_crsum!" "!_crstat!" "!_crlt!" "!_crtl!" "!_crhnt!" >nul 2>&1
goto :eof

:CrashHints
rem  Warning-only advice, each hint gated on its own evidence; a tool not found adds nothing.
rem  Undervolt hint needs a machine check: WHEA Processor Core ids 18 19 28 29, or bugcheck 0x124.
rem  _crnh counts the hints shown; the caller zeroes it. Never write TdrDelay / TdrLevel here.
if "!_cr_hw!"=="0" goto _crh1
set /a _crnh+=1
echo   [i] Uncorrected hardware error or bugcheck 0x124: Microsoft names heat, failing hardware,
echo       memory or a failing CPU, and says to turn off over-clocking. Check the cooling and
echo       test the memory ^(Windows Memory Diagnostic^).

:_crh1
if not defined UVTOOL goto _crh2
if "!_cr_mce!"=="0" goto _crh2
set /a _crnh+=1
echo   [i] Undervolt tool found: !UVTOOL!
echo       Microsoft's 0x124 advice is to turn over-clocking off; an undervolt also runs the CPU
echo       off its stock settings, so retest at stock settings before suspecting the hardware.

:_crh2
if "!_cr_nocode!"=="0" goto _crh3
set /a _crnh+=1
echo   [i] Restart with no bugcheck code and no power-button press: Microsoft lists power loss,
echo       an underpowered or faulty power supply, overheating and over-clocking as the causes
echo       to check.

:_crh3
if "!_cr_vm46!"=="0" goto _crh4
set /a _crnh+=1
echo   [i] volmgr 46: crash-dump setup failed at that boot, so a crash then leaves no dump and no
echo       bugcheck code. Microsoft points at the page file configuration.

:_crh4
if "!_cr_disk!"=="0" goto _crh5
set /a _crnh+=1
echo   [i] Disk retries, resets or bad blocks: Microsoft points at the disk subsystem, storage
echo       drivers and firmware. chkdsk /scan is the read-only first check.

:_crh5
if "!_cr_ntfs!"=="0" goto _crh6
set /a _crnh+=1
echo   [i] NTFS reported corruption: run chkdsk /scan first ^(it only reads^). Microsoft ties these
echo       events to bad sectors or to disk requests that did not complete.

:_crh6
if "!_cr_rex!"=="0" goto _crh7
set /a _crnh+=1
echo   [i] Low virtual memory: RAM plus page file nearly ran out. Microsoft's memory-leak guidance
echo       starts from repeated 2004 events and the Commit size column in Task Manager.

:_crh7
if "!_cr_tdr!"=="0" goto _crh8
set /a _crnh+=1
echo   [i] Display driver resets ^(TDR^): Microsoft points at the display driver first, then at
echo       over-clocked parts, cooling and power. TdrLevel=0 turns detection off, and Microsoft
echo       says end users should not change the TdrDelay / TdrLevel keys.

:_crh8
if not defined _cr_drv goto _crh9
set /a _crnh+=1
echo   [i] A driver was installed less than a week before the first crash or unexpected restart:
echo       !_cr_drv!, on !_cr_drvdate!.
echo       Microsoft suggests checking drivers installed just before crashes began.

:_crh9
if not defined _cr_sin goto :eof
set /a _crnh+=1
echo   [i] sincript made changes on !_cr_sin!, before the first crash or unexpected restart here.
echo       The undo files that session wrote can be restored under Backups ^& status.
goto :eof

:CrashCollect
rem  Worker 1 of 3 - reads the logs into CSV PT_CR_OUT, columns K,T,Log,Prov,Id,Lvl,A,B,C: an L
rem  row per log, E per event, S per sincript session, one W row. EventLogReader: no message
rem  rendering, and failures are exceptions. Fields by name, never localized text like ServiceType.
rem  WHEA is classed by event ID, not level; an unknown ID counts as uncorrected, so the query
rem  reads levels 1-3 only. Newest first to a shared 30,000-event cap; covered days shrink to fit.
rem  SCM 7045 ImagePath is only tested for .sys, never written: it can hold a secret.
rem  Helper names carry an x prefix: PowerShell aliases beat functions, e.g. R and Rd.
set "PT_CR_OUT=!_crcsv!"
set "PT_CR_BAK=!BACKUP_DIR!"
set "PT_CR_DAYS=!_crdays!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; if(-not $env:PT_CR_OUT){ exit 2 }; $days=30; try{ $days=[int]$env:PT_CR_DAYS }catch{ $days=30 }; if($days -lt 1 -or $days -gt 365){ $days=30 }; $now=Get-Date; $from=$now.AddDays(-$days); $ic=[Globalization.CultureInfo]::InvariantCulture; $ap=[char]39; $rows=New-Object System.Collections.Generic.List[object]; function xR($k,$t,$l,$p,$i,$v,$x,$y,$z){ $rows.Add([pscustomobject]@{K=$k;T=$t;Log=$l;Prov=$p;Id=$i;Lvl=$v;A=$x;B=$y;C=$z}) }; function xS($s){ if($null -eq $s){ return '' }; $s=([string]$s) -replace '[^\x20-\x7e]','?' -replace '[\x21\x22\x25\x26\x2c\x3c\x3e\x5e\x7c]','?'; if($s.Length -gt 40){ $s=$s.Substring(0,40) }; return $s.Trim() }; function xRd($l,$x,$v){ $q=New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($l,[System.Diagnostics.Eventing.Reader.PathType]::LogName,$x); if($v){ $q.ReverseDirection=$true }; return (New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)) }; function xWhy($e){ $x=$e.Exception; while($x.InnerException){ $x=$x.InnerException }; if($x -is [UnauthorizedAccessException]){ return 'denied' }; if($x -is [System.Diagnostics.Eventing.Reader.EventLogNotFoundException]){ return 'missing' }; return 'error' }; function xD($x,$n){ foreach($d in @($x.Event.EventData.Data)){ if($d -isnot [string] -and $d.Name -eq $n){ return [string]$d.InnerText } }; return '' }; function xP($x,$i){ $v=@($x.Event.EventData.Data); if($v.Count -gt $i){ if($v[$i] -is [string]){ return $v[$i] }; return [string]$v[$i].InnerText }; return '' }; function xAll($x){ return ((@($x.Event.EventData.Data) | ForEach-Object { if($_ -is [string]){ $_ } else { $_.InnerText } }) -join ' ') }; function xPv($p,$ids){ return ('(Provider[@Name='+$ap+$p+$ap+'] and ('+((@($ids) | ForEach-Object { 'EventID='+$_ }) -join ' or ')+'))') }; $st=@{}; $old=@{}; foreach($l in @('System','Application')){ $st[$l]='ok'; try{ $r=xRd $l '*'; $e=$r.ReadEvent(); if($null -ne $e){ $old[$l]=$e.TimeCreated; $e.Dispose() } else { $st[$l]='empty' } }catch{ $st[$l]=xWhy $_ } }; $clr=@{}; if($st['System'] -eq 'ok'){ try{ $r=xRd 'System' ('*[System['+(xPv 'Microsoft-Windows-Eventlog' @(104))+']]'); while($null -ne ($e=$r.ReadEvent())){ $ch=[string]([xml]$e.ToXml()).Event.UserData.LogFileCleared.Channel; if($ch -eq 'System' -or $ch -eq 'Application'){ $clr[$ch]=$e.TimeCreated.ToString('yyyy-MM-dd HH:mm',$ic) }; $e.Dispose() } }catch{} }; $w='TimeCreated[timediff(@SystemTime) <= '+([int64]$days*86400000)+']'; $sel=@((xPv 'Microsoft-Windows-Kernel-Power' @(41)),(xPv 'EventLog' @(6008)),(xPv 'Microsoft-Windows-WER-SystemErrorReporting' @(1001)),('(Provider[@Name='+$ap+'Microsoft-Windows-WHEA-Logger'+$ap+'] and (Level=1 or Level=2 or Level=3))'),(xPv 'Display' @(4101)),(xPv 'disk' @(7,153)),(xPv 'storahci' @(129)),(xPv 'stornvme' @(129)),(xPv 'Ntfs' @(55)),(xPv 'Microsoft-Windows-Ntfs' @(55,98)),(xPv 'Microsoft-Windows-Resource-Exhaustion-Detector' @(2004)),(xPv 'volmgr' @(46)),(xPv 'Service Control Manager' @(7045))); $bn=@{'A'='IRQL_NOT_LESS_OR_EQUAL';'1A'='MEMORY_MANAGEMENT';'3B'='SYSTEM_SERVICE_EXCEPTION';'50'='PAGE_FAULT_IN_NONPAGED_AREA';'7E'='SYSTEM_THREAD_EXCEPTION_NOT_HANDLED';'9F'='DRIVER_POWER_STATE_FAILURE';'D1'='DRIVER_IRQL_NOT_LESS_OR_EQUAL';'EF'='CRITICAL_PROCESS_DIED';'101'='CLOCK_WATCHDOG_TIMEOUT';'116'='VIDEO_TDR_FAILURE';'124'='WHEA_UNCORRECTABLE_ERROR';'133'='DPC_WATCHDOG_VIOLATION';'139'='KERNEL_SECURITY_CHECK_FAILURE'}; function xBn($s){ $k=$s.Substring(2).TrimStart('0'); if($bn.ContainsKey($k)){ return $bn[$k] }; return '' }; $wco=@(2,17,19,21,23,25,27,28,41,43,45,47,49); $wcpu=@(18,19,28,29); $cap=30000; $n=0; $cp=@{}; $lt=$now; if($st['System'] -eq 'ok'){ try{ $r=xRd 'System' ('*[System[('+($sel -join ' or ')+') and '+$w+']]') 1; while($null -ne ($e=$r.ReadEvent())){ if($n -ge $cap){ $cp['System']=$lt; $e.Dispose(); break }; $n++; $lt=$e.TimeCreated; $p=$e.ProviderName; $id=[int]$e.Id; $A=''; $B=''; $C=''; if($p -eq 'Microsoft-Windows-WHEA-Logger'){ $A='uncorrected'; if($wco -contains $id){ $A='corrected' }; if($wcpu -contains $id){ $B='cpu' } } elseif($p -ne 'EventLog' -and $p -ne 'volmgr'){ $x=[xml]$e.ToXml(); if($id -eq 41){ $v=xD $x 'BugcheckCode'; if($v -match '^[0-9]{1,10}$' -and $v -ne '0'){ $A='0x{0:X8}' -f [uint32]$v; $C=xBn $A }; $B=xD $x 'PowerButtonTimestamp' } elseif($id -eq 1001){ $m=[regex]::Match((xD $x 'param1'),'^0x([0-9A-Fa-f]{1,8})'); if($m.Success){ $A='0x{0:X8}' -f [Convert]::ToUInt32($m.Groups[1].Value,16); $C=xBn $A } } elseif($id -eq 4101){ $A=xP $x 0 } elseif($id -eq 7 -or $id -eq 153 -or $id -eq 129){ $A=[regex]::Match((xAll $x),'(Harddisk|RaidPort)[0-9]+').Value } elseif($id -eq 55){ $A=xD $x 'DriveName' } elseif($id -eq 98){ $A=xD $x 'CorruptionActionState'; $B=xD $x 'DriveName' } elseif($id -eq 2004){ $A=xD $x 'SystemCommitCharge'; $B=xD $x 'SystemCommitLimit' } elseif($id -eq 7045){ $A=xD $x 'ServiceName'; $ip=(xD $x 'ImagePath').Trim(); $B='service'; if($ip -match '\.sys\W*$'){ $B='driver' } } }; xR 'E' $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss',$ic) 'System' $p $id ([int]$e.Level) (xS $A) (xS $B) (xS $C); $e.Dispose() } }catch{ $st['System']=xWhy $_ } }; $lt=$now; if($st['Application'] -eq 'ok'){ try{ $r=xRd 'Application' ('*[System['+(xPv 'Application Error' @(1000))+' and '+$w+']]') 1; while($null -ne ($e=$r.ReadEvent())){ if($n -ge $cap){ $cp['Application']=$lt; $e.Dispose(); break }; $n++; $lt=$e.TimeCreated; $x=[xml]$e.ToXml(); $A=xD $x 'AppName'; if(-not $A){ $A=xP $x 0 }; $B=xD $x 'ModuleName'; if(-not $B){ $B=xP $x 3 }; $C=xD $x 'ExceptionCode'; if(-not $C){ $C=xP $x 6 }; xR 'E' $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss',$ic) 'Application' $e.ProviderName ([int]$e.Id) ([int]$e.Level) (xS $A) (xS $B) (xS $C); $e.Dispose() } }catch{ $st['Application']=xWhy $_ } }; foreach($l in @('System','Application')){ $cov=0; $o=''; $s=$st[$l]; if($old.ContainsKey($l)){ $o=$old[$l].ToString('yyyy-MM-dd HH:mm',$ic); if($old[$l] -le $from){ $cov=$days } else { $cov=[int][Math]::Floor(($now-$old[$l]).TotalDays) } }; if($s -eq 'ok' -and $cp.ContainsKey($l)){ $s='capped'; $c2=[int][Math]::Floor(($now-$cp[$l]).TotalDays); if($c2 -lt $cov){ $cov=$c2 } }; xR 'L' $o $l '' '' '' $s $cov ([string]$clr[$l]) }; if($env:PT_CR_BAK -and (Test-Path -LiteralPath $env:PT_CR_BAK)){ $fs=@(Get-ChildItem -LiteralPath $env:PT_CR_BAK -File); $bk=@($fs | Where-Object { ($_.Name -match '_[0-9]+\.reg$' -and $_.Name -notlike 'FullReg_*') -or $_.Name -like 'Preset_*.json' -or $_.Name -like 'PowerPlan_*.bat' -or $_.Name -like 'Telemetry_*.bat' }); foreach($f in @($fs | Where-Object { $_.Name -like 'PerfTweaks_*.log' -and $_.CreationTime -ge $from })){ $s0=$f.CreationTime; $s1=$f.LastWriteTime.AddMinutes(1); $nb=@($bk | Where-Object { $_.CreationTime -ge $s0 -and $_.CreationTime -le $s1 }).Count; xR 'S' $s0.ToString('yyyy-MM-dd HH:mm:ss',$ic) '' 'sincript' '' '' ([string]$nb) '' '' } }; $wc='0'; if($cp.Count -gt 0){ $wc=[string]$cap }; xR 'W' $now.ToString('yyyy-MM-dd HH:mm',$ic) '' '' '' '' ([string]$days) $now.ToString('yyyyMMdd_HHmm',$ic) $wc; $rows | Export-Csv -LiteralPath $env:PT_CR_OUT -NoTypeInformation -Encoding ASCII; exit 0"
set "PT_CR_OUT=" & set "PT_CR_BAK=" & set "PT_CR_DAYS="
goto :eof

:CrashSummary
rem  Worker 2 of 3 - classifies. Reads PT_CR_IN, writes the summary PT_CR_SUM and KEY=VALUE counts
rem  to PT_CR_STAT. A Kernel-Power 41 paired with its WER 1001 or EventLog 6008 counts once.
rem  Events are grouped in one pass; a Where-Object per category is far too slow.
rem  Wrap every collection in an array subexpression: a single object has no .Count in PS 5.1.
rem  A capped Application log with no event read says NOT READ, never none found.
set "PT_CR_IN=!_crcsv!"
set "PT_CR_SUM=!_crsum!"
set "PT_CR_STAT=!_crstat!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; if(-not $env:PT_CR_IN -or -not $env:PT_CR_SUM -or -not $env:PT_CR_STAT){ exit 2 }; $ic=[Globalization.CultureInfo]::InvariantCulture; $rows=@(Import-Csv -LiteralPath $env:PT_CR_IN); $W=$null; $L=@{}; $g=@{}; foreach($r in $rows){ if($r.K -eq 'W'){ $W=$r } elseif($r.K -eq 'L'){ $L[$r.Log]=$r } elseif($r.K -eq 'E'){ $k=$r.Log+' '+$r.Prov+' '+$r.Id; if(-not $g.ContainsKey($k)){ $g[$k]=New-Object System.Collections.ArrayList }; [void]$g[$k].Add($r) } }; if(-not $W){ exit 3 }; $days=[int]$W.A; if($days -lt 1){ exit 3 }; $cq='0'; if($W.C -match '^[1-9][0-9]{0,5}$'){ $cq=$W.C }; function xTm($s){ try{ return ([datetime]::ParseExact($s,'yyyy-MM-dd HH:mm:ss',$ic).Ticks/10000000) }catch{ return 0 } }; function xSt($n){ $r=$L[$n]; if(-not $r){ return 'fail' }; if($r.A -ne 'ok' -and $r.A -ne 'empty' -and $r.A -ne 'capped'){ return 'fail' }; if([int]$r.B -ge $days -and $r.A -ne 'capped'){ return 'ok' }; return 'short' }; $ss=xSt 'System'; $as=xSt 'Application'; $sd=[int]$L['System'].B; $ad=[int]$L['Application'].B; $M='Microsoft-Windows-'; function xG($p,$ids){ return @(foreach($i in $ids){ $v=$g['System '+$p+' '+$i]; if($v){ $v } }) }; $kp=@(xG ($M+'Kernel-Power') @(41)); $el=@(xG 'EventLog' @(6008)); $wer=@(xG ($M+'WER-SystemErrorReporting') @(1001)); $wh=@(foreach($k in @($g.Keys)){ if($k -like ('System '+$M+'WHEA-Logger *')){ $g[$k] } }); $whf=@($wh.Where({ $_.A -ne 'corrected' })); $whc=@($wh.Where({ $_.A -eq 'corrected' })); $tdr=@(xG 'Display' @(4101)); $sto=@(@(xG 'disk' @(153))+@(xG 'storahci' @(129))+@(xG 'stornvme' @(129))); $bad=@(xG 'disk' @(7)); $ntf=@(@(@(xG 'Ntfs' @(55))+@(xG ($M+'Ntfs') @(55,98))).Where({ [int]$_.Id -ne 98 -or ($_.A -match '^[0-9]+$' -and $_.A -ne '0') })); $rex=@(xG ($M+'Resource-Exhaustion-Detector') @(2004)); $vm=@(xG 'volmgr' @(46)); $ae=@(foreach($v in @($g['Application Application Error 1000'])){ if($v){ $v } }); $anr=($L['Application'].A -eq 'capped' -and $ae.Count -eq 0); function xBc($s){ if($s -match '^0x[0-9A-F]{8}$' -and $s -ne '0x00000000'){ return $s }; return '' }; function xAd($h,$c,$t){ $k=$c+' '+[Math]::Floor($t/1800); if(-not $h.ContainsKey($k)){ $h[$k]=New-Object System.Collections.ArrayList }; [void]$h[$k].Add($t) }; function xNr($h,$c,$t){ $b=[Math]::Floor($t/1800); foreach($j in @(($b-1),$b,($b+1))){ foreach($u in @($h[$c+' '+$j])){ if($null -ne $u -and [Math]::Abs($u-$t) -le 1800){ return $true } } }; return $false }; $bc=New-Object System.Collections.Generic.List[object]; $hb=@{}; $hk=@{}; foreach($r in $wer){ $v=xBc $r.A; $t=xTm $r.T; $bc.Add(@($v,$t,$r.C)); xAd $hb $v $t; if($v){ xAd $hb 'c' $t } }; foreach($r in $kp){ $t=xTm $r.T; xAd $hk '' $t; $v=xBc $r.A; if($v -and -not (xNr $hb $v $t) -and -not (xNr $hb '' $t)){ $bc.Add(@($v,$t,$r.C)); xAd $hb $v $t } }; $un=@($el.Where({ -not (xNr $hk '' (xTm $_.T)) })).Count; $k1=0; $k2=0; foreach($r in $kp){ if((xBc $r.A) -or (xNr $hb 'c' (xTm $r.T))){ $k1++ } elseif($r.B -match '^[1-9][0-9]*$'){ $k2++ } }; $k3=$kp.Count-$k1-$k2; $o=New-Object System.Collections.Generic.List[string]; function xO($s){ if($s.Length -gt 96){ $s=$s.Substring(0,96) }; $o.Add($s) }; function xLn($a,$n,$d){ return ('  {0,-30}{1,4}  {2}' -f $a,$n,$d) }; function xCn($li){ return ((@($li) | Group-Object | Sort-Object Count -Descending | ForEach-Object { if($_.Count -gt 1){ $_.Name+' x'+$_.Count } else { $_.Name } }) -join ', ') }; function xCv($n){ $r=$L[$n]; $s=xSt $n; if($s -eq 'fail'){ $y='the read failed'; if($r.A -eq 'denied'){ $y='access refused' } elseif($r.A -eq 'missing'){ $y='no such log' }; xO ('  '+$n+' log: COULD NOT BE READ ('+$y+') - finding nothing there proves nothing.'); return }; if($r.A -eq 'empty'){ xO ('  '+$n+' log: EMPTY - nothing has been logged since it was last cleared.') } elseif($n -eq 'Application' -and $anr){ xO ('  '+$n+' log: NOT READ - the System log used up the shared '+$cq+'-event cap.') } elseif($r.A -eq 'capped'){ xO ('  '+$n+' log: stopped at the shared '+$cq+'-event cap (newest first) - covers '+$r.B+' day(s).') } elseif($s -eq 'ok'){ xO ('  '+$n+' log: read, covers the full '+$days+' days.') } else { xO ('  '+$n+' log: read, but covers only '+$r.B+' day(s) - its oldest event is from '+$r.T+'.') }; if($r.C){ xO ('    It was cleared '+$r.C+': anything logged before that is gone.') } }; xCv 'System'; xCv 'Application'; xO ''; $none=@(); if($ss -eq 'fail'){ xO '  Restart, bugcheck, hardware, display, disk and memory checks: NOT DONE (log unreadable).' } else { $n=$kp.Count+$un; if($n -gt 0){ $pt=@(); if($k1){ $pt+=(''+$k1+' bugcheck') }; if($k2){ $pt+=(''+$k2+' power button held') }; if($k3){ $pt+=(''+$k3+' no code') }; if($un){ $pt+=(''+$un+' lone 6008') }; xO (xLn 'Unexpected restarts' $n ($pt -join ', ')) } else { $none+='unexpected restarts' }; if($bc.Count -gt 0){ xO (xLn 'Bugchecks (blue screens)' $bc.Count (xCn @(foreach($v in $bc){ if($v[0]){ ($v[0]+' '+$v[2]).Trim() } else { 'code not recorded' } }))) } else { $none+='bugchecks' }; if($whf.Count -gt 0){ xO (xLn 'Hardware errors, UNCORRECTED' $whf.Count ('WHEA-Logger '+(xCn @($whf.ForEach({ 'id '+$_.Id }))))) } else { $none+='uncorrected hardware errors' }; if($whc.Count -gt 0){ xO (xLn 'Hardware errors, corrected' $whc.Count ('WHEA-Logger '+(xCn @($whc.ForEach({ 'id '+$_.Id }))))) } else { $none+='corrected hardware errors' }; if($tdr.Count -gt 0){ xO (xLn 'Display driver resets (TDR)' $tdr.Count ('Display 4101: '+(xCn @($tdr.ForEach({ if($_.A){ $_.A } else { 'driver not named' } }))))) } else { $none+='display driver resets' }; if($sto.Count -gt 0){ xO (xLn 'Disk retries / resets' $sto.Count (xCn @($sto.ForEach({ ($_.Prov+' '+$_.Id+' '+$_.A).Trim() })))) } else { $none+='disk retries or resets (Windows storage drivers only)' }; if($bad.Count -gt 0){ xO (xLn 'Disk bad blocks' $bad.Count ('disk 7: '+(xCn @($bad.ForEach({ $_.A }))))) } else { $none+='bad blocks' }; if($ntf.Count -gt 0){ xO (xLn 'NTFS corruption reported' $ntf.Count (xCn @($ntf.ForEach({ 'Ntfs '+$_.Id })))) } else { $none+='NTFS corruption' }; if($rex.Count -gt 0){ xO (xLn 'Low virtual memory' $rex.Count 'Resource-Exhaustion-Detector 2004') } else { $none+='low virtual memory' }; if($vm.Count -gt 0){ xO (xLn 'Crash-dump setup failed' $vm.Count 'volmgr 46') } else { $none+='crash-dump setup failures' }; if($none.Count -gt 0){ $t='  None found in the '+$sd+' day(s) the System log covers: '+($none -join ', ')+'.'; while($t.Length -gt 94){ $c=$t.LastIndexOf(' ',94); xO $t.Substring(0,$c); $t='    '+$t.Substring($c+1) }; xO $t } }; if($as -eq 'fail'){ xO (xLn 'App crashes (Application log)' '-' 'NOT READ - that log could not be read') } elseif($anr){ xO (xLn 'App crashes (Application log)' '-' 'NOT READ - the event cap was reached first') } elseif($ae.Count -gt 0){ xO (xLn 'App crashes (Application log)' $ae.Count (xCn @($ae.ForEach({ $_.A+' / '+$_.B })))) } else { xO (xLn 'App crashes (Application log)' 0 ('none in the '+$ad+' day(s) that log covers')) }; $has=@($bc.Where({ $_[0] -eq '0x00000124' })).Count; $f=[ordered]@{sys=$ss;app=$as;sysdays=$sd;appdays=$ad;days=$days;gen=$W.T;stamp=$W.B;capped=$cq;hw=($whf.Count+$has);mce=(@($wh.Where({ $_.B -eq 'cpu' })).Count+$has);nocode=$k3;vm46=$vm.Count;disk=($sto.Count+$bad.Count);ntfs=$ntf.Count;rex=$rex.Count;tdr=$tdr.Count}; $o | Out-File -FilePath $env:PT_CR_SUM -Encoding ASCII; @($f.Keys | ForEach-Object { $_+'='+$f[$_] }) | Out-File -FilePath $env:PT_CR_STAT -Encoding ASCII; exit 0"
set "PT_CR_IN=" & set "PT_CR_SUM=" & set "PT_CR_STAT="
goto :eof

:CrashTimeline
rem  Worker 3 of 3 - the timeline. Writes the latest five events to PT_CR_LT and all to PT_CR_TL,
rem  newest first, same-day repeats collapsed; appends drv / drvdate / sin to PT_CR_STAT.
rem  Group by hashtable, not Group-Object: it is quadratic in PowerShell 5.1.
set "PT_CR_IN=!_crcsv!"
set "PT_CR_LT=!_crlt!"
set "PT_CR_TL=!_crtl!"
set "PT_CR_STAT=!_crstat!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; if(-not $env:PT_CR_IN -or -not $env:PT_CR_LT -or -not $env:PT_CR_TL){ exit 2 }; $ic=[Globalization.CultureInfo]::InvariantCulture; $rows=@(Import-Csv -LiteralPath $env:PT_CR_IN); $M='Microsoft-Windows-'; function xTm($s){ try{ return [datetime]::ParseExact($s,'yyyy-MM-dd HH:mm:ss',$ic) }catch{ return [datetime]::MinValue } }; function xLb($r){ $p=$r.Prov -replace ('^'+$M),''; if($p -eq 'Service Control Manager'){ $p='SCM' } elseif($p -eq 'WER-SystemErrorReporting'){ $p='WER' } elseif($p -eq 'Resource-Exhaustion-Detector'){ $p='Resource-Exh' } elseif($p -eq 'Application Error'){ $p='App Error' }; return ($p+' '+$r.Id) }; function xDt($r){ $i=[int]$r.Id; $p=$r.Prov; $b=($r.A -match '^0x[0-9A-F]{8}$' -and $r.A -ne '0x00000000'); if($p -eq ($M+'Kernel-Power')){ if($b){ return ('bugcheck '+$r.A) }; if($r.B -match '^[1-9][0-9]*$'){ return 'power button held' }; return 'no bugcheck code recorded' }; if($i -eq 6008){ return 'unexpected shutdown, logged at the next boot' }; if($i -eq 1001){ if($b){ return ('bugcheck '+$r.A) }; return 'bugcheck, code not recorded' }; if($p -eq ($M+'WHEA-Logger')){ if($r.A -eq 'corrected'){ return 'corrected hardware error' }; return 'UNCORRECTED hardware error' }; if($i -eq 4101){ return ('display driver reset '+$r.A) }; if($i -eq 98){ return ('volume '+$r.B+' state '+$r.A) }; if($i -eq 55){ return ('corruption on '+$r.A) }; if($i -eq 2004){ if($r.A -match '^[0-9]+$' -and $r.B -match '^[1-9][0-9]*$'){ return ('commit '+([double]$r.A/1GB).ToString('0.0',$ic)+' of '+([double]$r.B/1GB).ToString('0.0',$ic)+' GB') }; return 'low virtual memory' }; if($i -eq 46){ return 'crash-dump setup failed' }; if($i -eq 1000){ return ($r.A+' / '+$r.B+' '+$r.C) }; if($i -eq 7045){ return ($r.A+' ('+$r.B+')') }; return $r.A }; $h=@{}; $lx=@{}; $m0=''; $ins=New-Object System.Collections.ArrayList; foreach($r in $rows.Where({ ($_.K -eq 'E' -or $_.K -eq 'S') -and ([int]$_.Id -ne 98 -or ($_.A -match '^[0-9]+$' -and $_.A -ne '0')) })){ $k=$r.K+'|'+$r.Log+'|'+$r.Prov+'|'+$r.Id+'|'+$r.A+'|'+$r.B+'|'+$r.C; if(-not $lx.ContainsKey($k)){ if($r.K -eq 'S'){ $lx[$k]=@('sincript session',('started; '+$r.A+' undo file(s) written')) } else { $lx[$k]=@((xLb $r),(xDt $r)) } }; $y=$lx[$k]; $d=$r.T.Substring(0,10)+'|'+$y[0]+'|'+$y[1]; $q=$h[$d]; if($q){ $q[0]++; if($r.T -lt $q[1]){ $q[1]=$r.T }; if($r.T -gt $q[2]){ $q[2]=$r.T } } else { $h[$d]=@(1,$r.T,$r.T,$y[0],$y[1]) }; if($r.K -eq 'E' -and $r.Log -eq 'System'){ if($r.Prov -eq 'Service Control Manager' -and $r.Id -eq '7045'){ [void]$ins.Add($r) }; if((($r.Prov -eq ($M+'Kernel-Power') -and $r.Id -eq '41') -or ($r.Prov -eq 'EventLog' -and $r.Id -eq '6008') -or ($r.Prov -eq ($M+'WER-SystemErrorReporting') -and $r.Id -eq '1001') -or ($r.Prov -eq ($M+'WHEA-Logger') -and $r.A -ne 'corrected')) -and ($m0 -eq '' -or $r.T -lt $m0)){ $m0=$r.T } } }; $gr=@(@(foreach($q in $h.Values){ $c=''; if($q[0] -gt 1){ $c=' x'+$q[0]+' (first '+$q[1].Substring(11,5)+')' }; $s='  '+$q[2].Substring(0,16)+'  '+$q[3].PadRight(22)+' '+$q[4]+$c; if($s.Length -gt 96){ $s=$s.Substring(0,96) }; [pscustomobject]@{ T=$q[2]; S=$s } }) | Sort-Object T -Descending); $dn=''; $dd=''; $sn=''; $hd=@(); function xCn($li){ return ((@($li) | Group-Object | Sort-Object Count -Descending | ForEach-Object { if($_.Count -gt 1){ $_.Name+' x'+$_.Count } else { $_.Name } }) -join ', ') }; if($ins.Count -gt 0){ $d1=xCn @($ins | Where-Object { $_.B -eq 'driver' } | ForEach-Object { $_.A+' (driver)' }); $d2=xCn @($ins | Where-Object { $_.B -ne 'driver' } | ForEach-Object { $_.A }); $s=('  {0,-30}{1,4}  {2}' -f 'Drivers/services installed',$ins.Count,((@($d1,$d2) | Where-Object { $_ }) -join '; ')); if($s.Length -gt 96){ $s=$s.Substring(0,96) }; $hd=@($s,'') }; $lt=$hd+@('  Latest events, newest first (a saved report lists them all):'); $all=$hd+@('  Timeline, newest first:'); if($gr.Count -eq 0){ $lt+='  (nothing to list)'; $all+='  (nothing to list)' } else { $lt+=@($gr | Select-Object -First 5 | ForEach-Object { $_.S }); $all+=@($gr | ForEach-Object { $_.S }) }; if($m0){ $f0=xTm $m0; $dr=@($ins | Where-Object { $_.B -eq 'driver' -and (xTm $_.T) -le $f0 -and (xTm $_.T) -ge $f0.AddDays(-7) } | Sort-Object T); if($dr.Count -gt 0){ $dn=$dr[$dr.Count-1].A; $dd=$dr[$dr.Count-1].T.Substring(0,10) }; $se=@($rows.Where({ $_.K -eq 'S' -and $_.A -match '^[1-9][0-9]*$' -and (xTm $_.T) -le $f0 }) | Sort-Object T); if($se.Count -gt 0){ $sn=$se[$se.Count-1].T.Substring(0,10) } }; if($env:PT_CR_STAT){ @(('drvdate='+$dd),('sin='+$sn),('drv='+$dn)) | Out-File -FilePath $env:PT_CR_STAT -Encoding ASCII -Append }; $lt | Out-File -FilePath $env:PT_CR_LT -Encoding ASCII; $all | Out-File -FilePath $env:PT_CR_TL -Encoding ASCII; exit 0"
set "PT_CR_IN=" & set "PT_CR_LT=" & set "PT_CR_TL=" & set "PT_CR_STAT="
goto :eof

:BackupSingleValue
rem  %1 = key  %2 = value  %3 = description
rem  Whole-key .reg backup via reg export for the PATH editor; sets _BSV_OK=1 only if it landed.
rem  Not :BackupValueLine: that writer handles only REG_DWORD and REG_SZ, and PATH is REG_EXPAND_SZ.
setlocal EnableDelayedExpansion
set "_key=%~1"
set "_val=%~2"
set "_desc=%~3"
set "_safe=!_key:\=_!"
set "_safe=!_safe::=!"
set "_safe=!_safe: =_!"
set "_bkp=!BACKUP_DIR!\!_safe!_%RANDOM%%RANDOM%.reg"
set "_rk=!_key!"
rem  Map all five hive abbreviations, not only the ones used today.
set "_rk=!_rk:HKLM\=HKEY_LOCAL_MACHINE\!"
set "_rk=!_rk:HKCU\=HKEY_CURRENT_USER\!"
set "_rk=!_rk:HKCR\=HKEY_CLASSES_ROOT\!"
set "_rk=!_rk:HKU\=HKEY_USERS\!"
set "_rk=!_rk:HKCC\=HKEY_CURRENT_CONFIG\!"
del "!_bkp!" >nul 2>&1
reg export "!_rk!" "!_bkp!" /y >nul 2>&1
if errorlevel 1 goto _bsvFail
if not exist "!_bkp!" goto _bsvFail
echo   [BACKUP] !_desc! -^> !_bkp!
set "_LOGMSG=PATHBACKUP !_key! !_val! -> !_bkp!" & call :LogVar _LOGMSG
endlocal & set "_BSV_OK=1" & goto :eof

:_bsvFail
echo   [ERROR] Could not write a backup of !_key!.
call :Log "FAIL: PATHBACKUP !_key! !_val!"
endlocal & set "_BSV_OK=" & goto :eof
rem =====================================================================================
rem  HARDWARE PROBE: system disk media type (for the SysMain advisory)
rem =====================================================================================
:DetectSysDisk
rem  Sets SYSDISK=ssd, hdd or unknown; the if defined SYSDISK guard keeps it to one probe a session.
rem  Asks the volume via IOCTL_STORAGE_QUERY_PROPERTY, StorageDeviceSeekPenaltyProperty, opened with
rem  0 access. Do not switch to Get-PhysicalDisk / Get-Partition: one broken vendor storage provider
rem  makes them all throw. Failure leaves unknown, and the advisory it feeds only warns.
if defined SYSDISK goto :eof
set "SYSDISK=unknown"
rem  ---- tier 1: the answer this machine already gave, if the hardware has not changed ----
rem  Add-Type compiles C# for the probe, which is slow, so the answer is cached per machine, keyed
rem  on disk 0's device instance path, which changes with the hardware. Delete the file to re-probe.
set "_sdkey="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\disk\Enum" /v 0 2^>nul ^| findstr /I /C:"REG_SZ"') do set "_sdkey=%%B"
set "_sddir=!LOCALAPPDATA!\Sincript"
set "_sdcache=!_sddir!\sysdisk.cache"
if not defined LOCALAPPDATA goto _sdProbe
if not defined _sdkey goto _sdProbe
if not exist "!_sdcache!" goto _sdProbe
set "_sdck=" & set "_sdcv="
for /f "usebackq tokens=1,* delims=|" %%A in ("!_sdcache!") do ( set "_sdck=%%A" & set "_sdcv=%%B" )
if not defined _sdcv goto _sdProbe
if not "!_sdck!"=="!_sdkey!" goto _sdProbe
rem  Only ssd or hdd are valid answers; anything else means the file was altered, so re-probe.
if /i not "!_sdcv!"=="ssd" if /i not "!_sdcv!"=="hdd" goto _sdProbe
set "SYSDISK=!_sdcv!"
call :Log "System disk media type: !SYSDISK! (cached)"
goto :eof

:_sdProbe
set "_sdres=!TEMP!\pt_sdisk_%RANDOM%.txt"
del "!_sdres!" >nul 2>&1
set "PT_SD_RES=!_sdres!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $t='unknown'; $dl=if($env:SystemDrive){ $env:SystemDrive.Substring(0,1) }else{ 'C' }; try{ $sig='using System;using System.Runtime.InteropServices;namespace PTDisk{[StructLayout(LayoutKind.Sequential)]public struct SPQ{public uint PropertyId;public uint QueryType;[MarshalAs(UnmanagedType.ByValArray,SizeConst=1)]public byte[] AdditionalParameters;}[StructLayout(LayoutKind.Sequential)]public struct DSPD{public uint Version;public uint Size;[MarshalAs(UnmanagedType.U1)]public bool IncursSeekPenalty;}public static class N{[DllImport(\"kernel32.dll\",SetLastError=true,CharSet=CharSet.Auto)]public static extern IntPtr CreateFile(string n,uint a,uint s,IntPtr sec,uint d,uint f,IntPtr t);[DllImport(\"kernel32.dll\",SetLastError=true)]public static extern bool DeviceIoControl(IntPtr h,uint c,ref SPQ i,uint isz,ref DSPD o,uint osz,ref uint r,IntPtr ov);[DllImport(\"kernel32.dll\",SetLastError=true)]public static extern bool CloseHandle(IntPtr h);}}'; Add-Type -TypeDefinition $sig -Language CSharp; $h=[PTDisk.N]::CreateFile('\\.\'+$dl+':',0,3,[IntPtr]::Zero,3,0,[IntPtr]::Zero); if($h -ne [IntPtr]::new(-1)){ $q=New-Object PTDisk.SPQ; $q.PropertyId=7; $q.QueryType=0; $q.AdditionalParameters=New-Object byte[] 1; $d=New-Object PTDisk.DSPD; $ret=0; if([PTDisk.N]::DeviceIoControl($h,0x2D1400,[ref]$q,[uint32][Runtime.InteropServices.Marshal]::SizeOf($q),[ref]$d,[uint32][Runtime.InteropServices.Marshal]::SizeOf($d),[ref]$ret,[IntPtr]::Zero)){ if($d.IncursSeekPenalty){ $t='hdd' }else{ $t='ssd' } }; [void][PTDisk.N]::CloseHandle($h) } }catch{}; if($t -eq 'unknown'){ try{ $n=(Get-Partition -DriveLetter $dl -ErrorAction Stop).DiskNumber; $pd=@(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$n }); if($pd.Count -ge 1){ $m=[string]$pd[0].MediaType; if($m -eq 'SSD'){ $t='ssd' } elseif($m -eq 'HDD'){ $t='hdd' } } }catch{} }; $t | Out-File -FilePath $env:PT_SD_RES -Encoding ASCII"
set "PT_SD_RES="
rem  The MediaType fallback runs only if the IOCTL fails, so it can only turn unknown into a result.
if exist "!_sdres!" for /f "usebackq tokens=1" %%T in ("!_sdres!") do set "SYSDISK=%%T"
del "!_sdres!" >nul 2>&1
call :Log "System disk media type: %SYSDISK%"
rem  Cache a real answer only: a cached unknown would make one failed probe permanent. Written with
rem  delayed expansion, as the device path holds special characters; the escaped bar separates.
if /i "%SYSDISK%"=="unknown" goto :eof
if not defined LOCALAPPDATA goto :eof
if not defined _sdkey goto :eof
if not exist "!_sddir!\" md "!_sddir!" >nul 2>&1
if not exist "!_sddir!\" goto :eof
> "!_sdcache!" echo !_sdkey!^|!SYSDISK!
set "_LOGMSG=System disk media type cached -> !_sdcache!" & call :LogVar _LOGMSG
goto :eof

:DetectUndervolt
rem  Sets UVTOOL to the CPU voltage or tuning tools found, or leaves it empty; UVPROBED caches it.
rem  Reports a TOOL, never a voltage; none found proves nothing, so it only strengthens a warning.
rem  Plain reg queries of known keys, no PowerShell: it runs at startup. Every tool found is listed.
if defined UVPROBED goto :eof
set "UVPROBED=1"
set "UVTOOL="
rem  Intel XTU installs a driver service under one of these names.
set "_uvhit="
reg query "HKLM\SYSTEM\CurrentControlSet\Services\XTU3SERVICE" >nul 2>&1 && set "_uvhit=1"
if not defined _uvhit reg query "HKLM\SYSTEM\CurrentControlSet\Services\XtuAcpiDriver" >nul 2>&1 && set "_uvhit=1"
if defined _uvhit call :_uvAdd "Intel XTU"
rem  AMD Ryzen Master ships a versioned driver service; probe the two long-lived names.
set "_uvhit="
reg query "HKLM\SYSTEM\CurrentControlSet\Services\AMDRyzenMasterDriverV20" >nul 2>&1 && set "_uvhit=1"
if not defined _uvhit reg query "HKLM\SYSTEM\CurrentControlSet\Services\AMDRyzenMasterDriverV19" >nul 2>&1 && set "_uvhit=1"
if defined _uvhit call :_uvAdd "AMD Ryzen Master"
rem  ThrottleStop is portable, so look for its autostart: a Run entry or a Startup-folder shortcut.
set "_uvhit="
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" 2>nul | findstr /I "ThrottleStop" >nul && set "_uvhit=1"
if not defined _uvhit reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" 2>nul | findstr /I "ThrottleStop" >nul && set "_uvhit=1"
if not defined _uvhit if exist "!APPDATA!\Microsoft\Windows\Start Menu\Programs\Startup\ThrottleStop.lnk" set "_uvhit=1"
if not defined _uvhit if exist "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup\ThrottleStop.lnk" set "_uvhit=1"
if defined _uvhit call :_uvAdd "ThrottleStop"
set "_uvhit="
if defined UVTOOL call :Log "Undervolt tool(s) detected: !UVTOOL!"
if not defined UVTOOL call :Log "Undervolt tool: none of the known ones found"
goto :eof

:_uvAdd
if not defined UVTOOL ( set "UVTOOL=%~1" ) else ( set "UVTOOL=!UVTOOL! + %~1" )
goto :eof
rem =====================================================================================
rem  HARDWARE PROBE: display refresh rate (main-menu header and Status; nothing acts on it)
rem =====================================================================================
:ProbeRefresh
rem  Starts one background measurement of every display's refresh rate, never waiting; REFRESH, the
rem  header value of at most 14 columns, and REFRESH_ALL read pending until :DetectRefresh collects.
rem  Never cached across sessions: a refresh rate is a setting the user changes.
rem  Reads WinRT DisplayManager: an exact rate per display path, rounded to whole hertz.
rem  Not Win32_VideoController - per adapter, truncated - nor a user32 shim: a C# compile per run.
rem  Files in TEMP: .run marks a started worker; .tmp is renamed to the answer once complete.
rem  Records: S n = a display, R = remote session, E = failed, N = no display; n is 0-9999 or ?.
rem  If restarted while pending, the old path is kept in _hzold and its files deleted later.
if "!HZSTATE!"=="pending" set "_hzold=!_hzres!"
set "_hzres=!TEMP!\pt_hz_%RANDOM%%RANDOM%.txt"
del "!_hzres!" "!_hzres!.run" "!_hzres!.tmp" >nul 2>&1
set "HZSTATE=pending"
set "_hzdraws=0"
set "REFRESH=pending"
set "REFRESH_ALL=pending"
set "PT_HZ_RES=!_hzres!"
start "" /min powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $f=$env:PT_HZ_RES; if(-not $f){ exit 1 }; Set-Content -LiteralPath ($f+'.run') -Value 'run' -Encoding ASCII; $o=@(); try{ $g=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name GlassSessionId -ErrorAction SilentlyContinue).GlassSessionId; if(($null -ne $g) -and ([int]$g -ne [Diagnostics.Process]::GetCurrentProcess().SessionId)){ $o+='R' }; $null=[Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]; $m=[Windows.Devices.Display.Core.DisplayManager]::Create([Windows.Devices.Display.Core.DisplayManagerOptions]::None); try{ $r=$m.TryReadCurrentStateForAllTargets(); if([string]$r.ErrorCode -ne 'Success'){ throw 'read failed' }; foreach($v in $r.State.Views){ foreach($p in $v.Paths){ $q=$p.PresentationRate; $hz='?'; if($q -and ($q.VerticalSyncRate.Denominator -gt 0)){ $x=[Math]::Floor($q.VerticalSyncRate.Numerator / $q.VerticalSyncRate.Denominator + 0.5); if(($x -ge 0) -and ($x -le 9999)){ $hz=[string]$x } }; $o+=('S '+$hz) } } } finally { $m.Dispose() } } catch { $o+='E' }; if($o.Count -eq 0){ $o=@('N') }; $t=$f+'.tmp'; $o | Out-File -FilePath $t -Encoding ASCII; Move-Item -LiteralPath $t -Destination $f -Force"
set "PT_HZ_RES="
goto :eof

:DetectRefresh
rem  Runs on every menu draw, so it must stay cheap: after the first call, no process and no wait.
if not defined HZSTATE call :ProbeRefresh
if not "!HZSTATE!"=="pending" goto :eof
if exist "!_hzres!" goto _hzCollect
set /a _hzdraws+=1
rem  No answer yet. Give up after 10 draws if the worker never created its .run marker, else after
rem  30. A later answer still replaces unknown; the give-up is logged once.
set "_hzlim=10"
if exist "!_hzres!.run" set "_hzlim=30"
if !_hzdraws! LSS !_hzlim! goto :eof
if "!REFRESH!"=="unknown" goto :eof
set "REFRESH=unknown"
set "REFRESH_ALL=unknown"
set "_hzwhy=it never started"
if exist "!_hzres!.run" set "_hzwhy=it started but has not finished"
set "_hzlog=Display refresh rate: no answer from the worker after !_hzdraws! menu draws - !_hzwhy!"
call :LogVar _hzlog
goto :eof

:_hzCollect
call :_hzParse
del "!_hzres!" "!_hzres!.run" >nul 2>&1
set "HZSTATE=done"
if defined _hzold del "!_hzold!" "!_hzold!.run" "!_hzold!.tmp" >nul 2>&1
set "_hzold="
set "_hzlog=Display refresh rate: !REFRESH_ALL! (header: !REFRESH!) - !_hzwhy!"
call :LogVar _hzlog
goto :eof

:_hzParse
rem  Turns the worker's answer file into REFRESH / REFRESH_ALL and sets _hzwhy for the log:
rem  R = remote, E or N or no usable rate = unknown, else the rates joined by / plus Hz.
rem  0 and 1 mean hardware default and show as ?. The header shows two rates plus +N, at most 14
rem  columns; Status shows eight. The file is in user-writable TEMP, so any record the worker
rem  never writes makes it all unknown. Reject any exclamation mark: delayed expansion drops it.
set "_hzbad=" & set "_hzr=" & set "_hze=" & set "_hzn=" & set "_hzsn=0" & set "_hzrecs=0"
set "_hzhdr=" & set "_hzall=" & set "_hzsep=" & set "_hzallq=1" & set "_hzwhy=malformed answer"
if not exist "!_hzres!" set "_hzwhy=no answer file" & goto _hzUnknown
findstr /l /c:"^!" "!_hzres!" >nul 2>&1
if errorlevel 2 set "_hzwhy=the answer could not be checked" & goto _hzUnknown
if not errorlevel 1 goto _hzUnknown
for /f "usebackq tokens=1-3" %%A in ("!_hzres!") do (
    set "_hzt1=%%A" & set "_hzt2=%%B" & set "_hzt3=%%C"
    if not defined _hzbad call :_hzRec
)
if defined _hzbad goto _hzUnknown
if defined _hzn if !_hzrecs! GTR 1 goto _hzUnknown
rem  Remote wins over a failed read: the worker notes the session before it reads the displays.
if defined _hzr set "REFRESH=remote" & set "REFRESH_ALL=remote" & set "_hzwhy=remote session" & goto :eof
if defined _hze set "_hzwhy=the worker failed" & goto _hzUnknown
if defined _hzn set "_hzwhy=no display on the desktop" & goto _hzUnknown
if !_hzsn! EQU 0 set "_hzwhy=empty answer" & goto _hzUnknown
for /l %%I in (1,1,%_hzsn%) do call :_hzJoin %%I
if defined _hzallq set "_hzwhy=Windows gave no usable rate" & goto _hzUnknown
set "REFRESH=!_hzhdr!Hz"
set "REFRESH_ALL=!_hzall!Hz"
set /a _hzmore=_hzsn-2
if !_hzmore! GTR 0 set "REFRESH=!REFRESH!+!_hzmore!"
set /a _hzmore=_hzsn-8
if !_hzmore! GTR 0 set "REFRESH_ALL=!REFRESH_ALL!+!_hzmore!"
set "_hzwhy=measured"
goto :eof

:_hzUnknown
set "REFRESH=unknown"
set "REFRESH_ALL=unknown"
goto :eof

:_hzRec
rem  One record in _hzt1.._hzt3, not call arguments: call would re-parse user-writable text.
set /a _hzrecs+=1
if defined _hzt3 set "_hzbad=1" & goto :eof
if "!_hzt1!"=="R" if not defined _hzt2 if not defined _hzr set "_hzr=1" & goto :eof
if "!_hzt1!"=="E" if not defined _hzt2 if not defined _hze set "_hze=1" & goto :eof
if "!_hzt1!"=="N" if not defined _hzt2 set "_hzn=1" & goto :eof
if not "!_hzt1!"=="S" set "_hzbad=1" & goto :eof
set "_hzv=!_hzt2!"
if not defined _hzv set "_hzbad=1" & goto :eof
if "!_hzv!"=="?" goto _hzRecKeep
rem  1-4 digits, no leading zero. eol=0 so a leading semicolon is not skipped; read late.
set "_hzx="
for /f "eol=0 delims=0123456789" %%x in ("!_hzv!") do set "_hzx=1"
if defined _hzx set "_hzbad=1" & goto :eof
if not "!_hzv:~4!"=="" set "_hzbad=1" & goto :eof
if not "!_hzv!"=="0" if "!_hzv:~0,1!"=="0" set "_hzbad=1" & goto :eof
if "!_hzv!"=="0" set "_hzv=?"
if "!_hzv!"=="1" set "_hzv=?"

:_hzRecKeep
if !_hzsn! GEQ 64 set "_hzbad=1" & goto :eof
set /a _hzsn+=1
set "_hzs[!_hzsn!]=!_hzv!"
goto :eof

:_hzJoin
rem  %1 = a position in the list (a counter, never file data).
set "_hzq=!_hzs[%~1]!"
if not "!_hzq!"=="?" set "_hzallq="
if %~1 LEQ 2 set "_hzhdr=!_hzhdr!!_hzsep!!_hzq!"
if %~1 LEQ 8 set "_hzall=!_hzall!!_hzsep!!_hzq!"
set "_hzsep=/"
goto :eof

:_hzShow
rem  Display section of Status: the session's value, never a new measurement. Drives nothing.
echo [Display]  (shown for information - no tweak or advisory uses it)
echo   Refresh rate  = !REFRESH_ALL!
if "!REFRESH!"=="pending" echo                   Still being measured in the background - the main menu shows it once it lands.
if "!REFRESH!"=="remote" echo                   A remote session: its displays are virtual, so no rate is shown.
if "!REFRESH!"=="unknown" echo                   Windows gave no rate, or the measurement could not run - the log says which.
if "!REFRESH!"=="pending" goto :eof
if "!REFRESH!"=="remote" goto :eof
if "!REFRESH!"=="unknown" goto :eof
echo                   The current mode's rate in whole hertz, as Windows reports it, one per display
echo                   in the order Windows lists them ^(a 59.94 Hz mode shows as 60^).
echo                   Measured once per launch: a rate changed since then shows after a restart.
echo                   VRR, G-SYNC, FreeSync or Dynamic Refresh Rate can run a panel below it.
if not "!REFRESH_ALL:?=!"=="!REFRESH_ALL!" echo                   A ? is a display Windows gave no usable rate for.
goto :eof

:DiskAdvisory
rem  SysMain advisory: warns only, never blocks or changes a default. Warns unless an SSD is
rem  confirmed; a confirmed SSD gets a positive line, so it differs from a probe that never ran.
if /i "%SYSDISK%"=="ssd" (
    echo   [i] Windows disk: SSD - SysMain has little to offer here, so turning it off
    echo       is a reasonable call. No caveat applies.
    goto :eof
)
if /i "%SYSDISK%"=="hdd" (
    echo   [ADVISORY] The Windows disk looks like a mechanical HDD - SysMain really does
    echo              help there. Leaving it enabled is the better call.
    goto :eof
)
echo   [ADVISORY] Could not identify the Windows disk type - if it is a mechanical HDD,
echo              leave SysMain enabled; it mainly helps spinning disks.
goto :eof

:VerboseStatusNote
rem  Windows ignores verbosestatus while DisableStatusMessages is nonzero in the same key; say so.
setlocal EnableDelayedExpansion
set "_dsm="
for /f "delims=" %%L in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "DisableStatusMessages" 2^>nul ^| findstr /I /C:"REG_DWORD"') do set "_dsm=%%L"
rem  Parse the last token with set /a, not findstr: a substring match reads 0x10 as 0x1.
set "_dsmon="
set "_dsmtok="
if defined _dsm for %%a in (!_dsm!) do set "_dsmtok=%%a"
set "_dsmval=0"
if defined _dsmtok set /a _dsmval=_dsmtok 2>nul
if not "!_dsmval!"=="0" set "_dsmon=1"
if defined _dsmon (
    echo   [i] Note: DisableStatusMessages=1 is set, which OVERRIDES verbose status -
    echo       Windows shows no boot messages until that is cleared. verbosestatus is
    echo       written and backed up, but stays dormant until then.
) else (
    echo   [i] Verbose messages will appear at the next startup/logon. To turn them off,
    echo       restore this value from the Backups menu or set verbosestatus back to 0.
)
endlocal & goto :eof
rem =====================================================================================
rem  PRIVACY HELPERS: extra telemetry tasks, and the DiagTrack firewall block
rem =====================================================================================
:DisableTelemetryTasks
rem  Disables a vetted set of telemetry tasks BY NAME via Get-ScheduledTask - a wrong schtasks path
rem  fails quietly. Reports found / disabled / checked, so absent and failed stay distinct.
rem  Only the DiskDiagnostic DataCollector, never the Resolver: that one warns of a dying disk.
set "_tkres=!TEMP!\pt_tasks_%RANDOM%.txt"
del "!_tkres!" >nul 2>&1
set "PT_TK_RES=!_tkres!"
set "PT_TK_NAMES=MareBackup|StartupAppTask|Microsoft-Windows-DiskDiagnosticDataCollector|MapsToastTask"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $names=@($env:PT_TK_NAMES -split '\|'); $found=0; $ok=0; foreach($n in $names){ if($n){ $ts=@(Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue); foreach($t in $ts){ $found++; try{ Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null; $ok++ }catch{} } } }; (''+$found+' '+$ok+' '+$names.Count) | Out-File -FilePath $env:PT_TK_RES -Encoding ASCII"
set "PT_TK_RES=" & set "PT_TK_NAMES="
set "_tkf=0" & set "_tko=0" & set "_tkn=0"
if exist "!_tkres!" for /f "usebackq tokens=1,2,3" %%a in ("!_tkres!") do ( set "_tkf=%%a" & set "_tko=%%b" & set "_tkn=%%c" )
del "!_tkres!" >nul 2>&1
if "!_tkf!"=="0" (
    echo   [SKIP] Extra telemetry tasks: none of the !_tkn! exist on this edition.
    call :Log "TASKS extra: none of !_tkn! present"
    goto :eof
)
if "!_tko!"=="0" (
    echo         [FAIL] Extra telemetry tasks: found !_tkf! but disabled none - run as Administrator.
    call :Log "FAIL: TASKS extra found=!_tkf! disabled=0"
    if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS+=1
    goto :eof
)
echo   [OK] Extra telemetry tasks: disabled !_tko! of !_tkf! found.
call :Log "OK: TASKS extra found=!_tkf! disabled=!_tko!"
goto :eof

:DisableNvidiaTelemetryTasks
rem  Disables NvTmRep_ / NvTmMon_ tasks BY NAME PREFIX: driver updates change their folder path.
rem  NvDriverUpdateCheckDaily_ is not telemetry and is left alone. First writes an undo
rem  Telemetry_nvidia_*.bat - the Backups revert menu lists Telemetry_*.bat - that re-enables only
rem  the tasks that were enabled; a failed write warns but does not block.
set "_nvres=!TEMP!\pt_nvtasks_%RANDOM%.txt"
del "!_nvres!" >nul 2>&1
set "_nvundo="
if exist "!BACKUP_DIR!\" set "_nvundo=!BACKUP_DIR!\Telemetry_nvidia_%RANDOM%%RANDOM%.bat"
set "PT_NV_RES=!_nvres!"
set "PT_NV_UNDO=!_nvundo!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $q=[char]34; $ts=@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^(NvTmRep_|NvTmMon_)' }); $found=$ts.Count; $ok=0; $wrote=0; if($found -gt 0 -and $env:PT_NV_UNDO){ $L=@('@echo off','setlocal',('set '+$q+'PT_OK=0'+$q),('set '+$q+'PT_FAIL=0'+$q),'rem  Sincript NVIDIA telemetry tasks undo.','rem  Re-enables the NVIDIA telemetry scheduled tasks that were enabled before sincript','rem  disabled them - only those. Read from Get-ScheduledTask, so nothing here depends on','rem  the display language. Safe to run more than once. Double-click to restore.',''); foreach($t in $ts){ $f=$t.TaskPath+$t.TaskName; if($t.State -eq 'Disabled'){ $L+=('rem  task '+$f+' was already disabled before sincript - left alone') } else { $L+=('call :pt_do schtasks /Change /TN '+$q+$f+$q+' /Enable') } }; $L+=@('',('if '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [OK] Restored %%PT_OK%% item(s).'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [WARN] %%PT_OK%% restored, %%PT_FAIL%% FAILED - see the [FAIL] lines above.'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo        Re-run this file from an elevated prompt.'),('if '+$q+'%%~1'+$q+'=='+$q+$q+' pause'),'exit /b %%PT_FAIL%%','','rem  Flat on purpose: no ( ) block, so nothing here depends on delayed expansion.',':pt_do','%%*','if errorlevel 1 goto :pt_bad','set /a PT_OK+=1','exit /b',':pt_bad','set /a PT_FAIL+=1','echo   [FAIL] %%*','exit /b'); Set-Content -LiteralPath $env:PT_NV_UNDO -Value $L -Encoding ASCII; if(Test-Path -LiteralPath $env:PT_NV_UNDO){ $wrote=1 } }; foreach($t in $ts){ try{ Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null; $ok++ }catch{} }; (''+$found+' '+$ok+' '+$wrote) | Out-File -FilePath $env:PT_NV_RES -Encoding ASCII"
set "PT_NV_RES=" & set "PT_NV_UNDO="
set "_nvf=0" & set "_nvo=0" & set "_nvw=0"
if exist "!_nvres!" for /f "usebackq tokens=1,2,3" %%a in ("!_nvres!") do ( set "_nvf=%%a" & set "_nvo=%%b" & set "_nvw=%%c" )
del "!_nvres!" >nul 2>&1
if "!_nvf!"=="0" (
    echo   [SKIP] NVIDIA telemetry tasks: none found on this system.
    call :Log "TASKS nvidia: none present"
    goto :eof
)
if "!_nvw!"=="1" echo   [i] NVIDIA tasks undo file: !_nvundo!
if "!_nvw!"=="1" (set "_LOGMSG=NVIDIA tasks backup -> !_nvundo!" & call :LogVar _LOGMSG)
if not "!_nvw!"=="1" echo   [WARN] No undo file could be written for the NVIDIA tasks. Task Scheduler can
if not "!_nvw!"=="1" echo          re-enable them by hand.
if "!_nvo!"=="0" (
    echo         [FAIL] NVIDIA telemetry tasks: found !_nvf! but disabled none - run as Administrator.
    call :Log "FAIL: TASKS nvidia found=!_nvf! disabled=0"
    set /a _FAILS+=1
    goto :eof
)
echo   [OK] NVIDIA telemetry tasks: disabled !_nvo! of !_nvf! found.
call :Log "OK: TASKS nvidia found=!_nvf! disabled=!_nvo!"
goto :eof

:DiagTrackFirewall
rem  Flips Windows' own DiagTrack firewall rule group from Allow to Block: nothing to name or clean.
rem  Covers an update re-enabling the service. Undo in elevated PowerShell with:
rem  Set-NetFirewallRule -Group DiagTrack -Action Allow
set "_fwres=!TEMP!\pt_fw_%RANDOM%.txt"
del "!_fwres!" >nul 2>&1
set "PT_FW_RES=!_fwres!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $r=@(Get-NetFirewallRule -Group DiagTrack -ErrorAction SilentlyContinue); $n=0; foreach($x in $r){ try{ Set-NetFirewallRule -InputObject $x -Enabled True -Action Block -ErrorAction Stop; $n++ }catch{} }; (''+$n+' '+$r.Count) | Out-File -FilePath $env:PT_FW_RES -Encoding ASCII"
set "PT_FW_RES="
set "_fwn=0" & set "_fwc=0"
if exist "!_fwres!" for /f "usebackq tokens=1,2" %%a in ("!_fwres!") do ( set "_fwn=%%a" & set "_fwc=%%b" )
del "!_fwres!" >nul 2>&1
if "!_fwc!"=="0" (
    echo   [SKIP] Telemetry firewall: this Windows has no DiagTrack rule group - nothing to block.
    call :Log "FW DiagTrack: no rules present"
    goto :eof
)
if "!_fwn!"=="0" (
    echo         [FAIL] Telemetry firewall: found !_fwc! rule^(s^) but changed none - run as Administrator.
    call :Log "FAIL: FW DiagTrack found=!_fwc! blocked=0"
    if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS+=1
    goto :eof
)
echo   [OK] Telemetry firewall: blocked !_fwn! of !_fwc! DiagTrack rule^(s^).
call :Log "OK: FW DiagTrack found=!_fwc! blocked=!_fwn!"
goto :eof
rem =====================================================================================
rem  HELPER: snapshot system-drive free space into _FREE_BYTES / _FREE_HUMAN
rem =====================================================================================
:FreeSpaceSnap
set "_FREE_BYTES="
set "_FREE_HUMAN="
rem  Per-call file name: runs twice per cleanup, and another sincript window may run at once.
set "_freef=!TEMP!\pt_free_%RANDOM%%RANDOM%.txt"
set "PT_FREEF=!_freef!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $letter=if($env:SystemDrive){$env:SystemDrive.Substring(0,1)}else{'C'}; $d=Get-CimInstance Win32_LogicalDisk -Filter ('DeviceID='''+$letter+':'''); if(-not $d -or $null -eq $d.FreeSpace){exit 1}; $b=[int64]$d.FreeSpace; $t=[int64]$d.Size; $line=('{0}|{1:N1} GB free of {2:N1} GB on {3}:' -f $b,($b/1GB),($t/1GB),$letter); $line | Out-File -FilePath $env:PT_FREEF -Encoding ASCII"
set "PT_FREEF="
if not exist "!_freef!" goto :eof
for /f "usebackq tokens=1,* delims=|" %%A in ("!_freef!") do (
    set "_FREE_BYTES=%%A"
    set "_FREE_HUMAN=%%B"
)
del "!_freef!" >nul 2>&1
goto :eof
rem  HELPER: print free-space delta from _FREE_BEFORE / _FREE_AFTER byte strings
rem =====================================================================================
:FreeSpaceReport
if not defined _FREE_BEFORE goto _fsFail
if not defined _FREE_AFTER goto _fsFail
set "PT_FB=%_FREE_BEFORE%"
set "PT_FA=%_FREE_AFTER%"
set "_freedf=!TEMP!\pt_freed_%RANDOM%%RANDOM%.txt"
set "PT_FREEDF=!_freedf!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try{ $b=[int64]$env:PT_FB; $a=[int64]$env:PT_FA; $d=$a-$b; if($d -ge 1048576){ $s='  [Disk] Freed about '+[math]::Round($d/1MB,1)+' MB  now '+[math]::Round($a/1GB,1)+' GB free.' } elseif($d -le -1048576){ $s='  [Disk] Free space dropped about '+[math]::Round((-$d)/1MB,1)+' MB  other activity; now '+[math]::Round($a/1GB,1)+' GB free.' } else { $s='  [Disk] No measurable change  now '+[math]::Round($a/1GB,1)+' GB free.' }; $s | Out-File -FilePath $env:PT_FREEDF -Encoding ASCII }catch{ exit 1 }"
set "PT_FB=" & set "PT_FA=" & set "PT_FREEDF="
if exist "!_freedf!" (
    type "!_freedf!"
    del "!_freedf!" >nul 2>&1
) else (
    echo   [Disk] Could not measure free-space change.
)
goto :eof

:_fsFail
echo   [Disk] Could not measure free space.
goto :eof
rem =====================================================================================
rem  HELPER: [Page file] section of :Status - READ-ONLY
rem =====================================================================================
:PageFileStatus
rem  Shows page-file setting, use, RAM, commit and crash-dump type; ADVISORY only for a documented
rem  problem. Strictly read-only: a test fails if other code names a page-file or dump value.
rem  Sources are locale-free: registry values and WMI numbers.
rem  GetPerformanceInfo needs a slow C# compile, so it runs only when no page file can grow.
rem  A system-managed page file is never judged small; unreadable or unparsable states not at all.
rem  The worker classifies, this script only prints. Records: a tag, then bar-separated fields,
rem  each non-empty - a dash when unknown - as for /f collapses empty fields. Fields keep only
rem  letters, digits and a few inert characters, so nothing printed reaches cmd as syntax.
echo [Page file]  ^(shown only - sincript never changes the page file or the crash-dump type^)
set "_pgfres=!TEMP!\pt_pgf_%RANDOM%%RANDOM%.txt"
del "!_pgfres!" >nul 2>&1
set "PT_PGF_RES=!_pgfres!"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue';$o=New-Object Collections.Generic.List[string];$av=New-Object Collections.Generic.List[string];function Cl($v,$n){$s=(([string]$v) -replace '[^A-Za-z0-9 :.?_\\-]','').Trim();if($s.Length -gt $n){$s=$s.Substring(0,$n).Trim()};if($s -eq ''){$s='-'};$s};function Nm($v){if($null -eq $v){return '-'};try{$d=[double]$v}catch{return '-'};if($d -lt 0 -or $d -gt 99999999){return '-'};[string][int64][math]::Floor($d)};$sd='C';if($env:SystemDrive -match '^([A-Za-z]):'){$sd=$Matches[1].ToUpper()};$rk='HKLM:\SYSTEM\CurrentControlSet\Control\';$cfg='unreadable';$es=@();$mm=$null;try{$mm=Get-ItemProperty -LiteralPath ($rk+'Session Manager\Memory Management') -ErrorAction Stop}catch{$mm=$null};if($mm){$pv=$mm.PSObject.Properties['PagingFiles'];if(-not $pv){$cfg='absent'}else{foreach($e in @($pv.Value)){$t=([string]$e).Trim();if($t -eq ''){continue};$x=[pscustomobject]@{D='-';K='unrec';I=[int64]0;X=[int64]0;R=(Cl $t 40)};$m=[regex]::Match($t,'^([A-Za-z?]):\\[^\\\s]+(?:\s+(\d{1,8})\s+(\d{1,8}))?$');if($m.Success){$x.D=$m.Groups[1].Value.ToUpper();$z=$m.Groups[2].Success;if($z){$i=[int64]$m.Groups[2].Value;$j=[int64]$m.Groups[3].Value};if($x.D -eq '?'){if(-not $z -or ($i -eq 0 -and $j -eq 0)){$x.K='auto'}}elseif($z){if($i -eq 0 -and $j -eq 0){$x.K='sys'}elseif($i -ge 1 -and $j -ge $i){$x.K='custom';$x.I=$i;$x.X=$j}}}elseif($t -match '^([A-Za-z]):'){$x.D=$Matches[1].ToUpper()};$es+=$x};if($es.Count -eq 0){$cfg='none'}elseif($es.Count -eq 1 -and $es[0].K -eq 'auto'){$cfg='auto'}else{$cfg='list'}}};$us=@();$src='unknown';$ud=0;try{$w=@(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop);$src='wmi';foreach($u in $w){$n=[string]$u.Name;$d='-';if($n -match '^([A-Za-z]):'){$d=$Matches[1].ToUpper()};$us+=[pscustomobject]@{N=(Cl $n 30);D=$d;A=(Nm $u.AllocatedBaseSize);C=(Nm $u.CurrentUsage);P=(Nm $u.PeakUsage);T=($u.TempPageFile -eq $true)}}}catch{$us=@();if($mm){$ev=$mm.PSObject.Properties['ExistingPageFiles'];if($ev){$src='reg';foreach($e in @($ev.Value)){$t=([string]$e).Trim() -replace '^\\\?\?\\','';if($t -eq ''){continue};$d='-';if($t -match '^([A-Za-z]):'){$d=$Matches[1].ToUpper()};$us+=[pscustomobject]@{N=(Cl $t 30);D=$d;A='-';C='-';P='-';T=$false}}}}};if($src -eq 'wmi' -and $us.Count -eq 0 -and $mm){$ev=$mm.PSObject.Properties['ExistingPageFiles'];if($ev){foreach($e in @($ev.Value)){if(([string]$e).Trim() -ne ''){$ud=1}}};if($ud){$src='unknown'}};$rv='-';$ri='-';$cn='-';$cl='-';$cp='-';try{$os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop;if($os.TotalVisibleMemorySize -gt 0){$rv=Nm ($os.TotalVisibleMemorySize/1024)};if($os.TotalVirtualMemorySize -gt 0){$cl=Nm ($os.TotalVirtualMemorySize/1024);if($null -ne $os.FreeVirtualMemory){$cn=Nm (($os.TotalVirtualMemorySize-$os.FreeVirtualMemory)/1024)}}}catch{};try{$s=[double]0;foreach($p in @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)){$s+=[double]$p.Capacity};if($s -gt 0){$ri=Nm ($s/1MB)}}catch{};$dt='R';$dr='-';$dd=0;try{$cc=Get-ItemProperty -LiteralPath ($rk+'CrashControl') -ErrorAction Stop;$dt='U';$cv=$cc.PSObject.Properties['CrashDumpEnabled'];if($cv){$dt='X';if($cv.Value -is [int]){$v=[int64]$cv.Value;$dr=Nm $v;if(@(0,1,2,3,7) -contains $v){$dt=[string]$v};$fp=$cc.PSObject.Properties['FilterPages'];if($v -eq 1 -and $fp -and $fp.Value -is [int] -and $fp.Value -eq 1){$dt='A'}}};$dv=$cc.PSObject.Properties['DedicatedDumpFile'];if($dv -and ([string]$dv.Value).Trim() -ne ''){$dd=1}}catch{$dt='R'};$pn=0;if($cfg -eq 'none' -and $us.Count -gt 0){$pn=1};if($cfg -eq 'list' -and $src -ne 'unknown'){$ok=$true;foreach($x in $es){if($x.K -eq 'unrec' -or $x.K -eq 'auto'){$ok=$false}};foreach($u in $us){if($u.D -eq '-'){$ok=$false}};if($ok){if(((@($es|ForEach-Object{$_.D})|Sort-Object -Unique) -join '') -ne ((@($us|ForEach-Object{$_.D})|Sort-Object -Unique) -join '')){$pn=1};foreach($x in $es){if($x.K -eq 'custom'){foreach($u in $us){if($u.D -eq $x.D -and $u.A -ne '-'){if([int64]$u.A -lt $x.I -or [int64]$u.A -gt $x.X){$pn=1}}}}}}};$wn='now';if($pn -eq 1 -or $src -eq 'unknown'){$wn='next'};$don=@('1','2','3','7','A') -contains $dt;if($cfg -eq 'none'){$av.Add('ADV|none|'+$wn)};$bk=@('none','list') -contains $cfg;$bh=$false;if($cfg -eq 'list'){foreach($x in $es){if($x.D -eq '-' -or $x.D -eq '?'){$bk=$false};if($x.D -eq $sd){$bh=$true}}};if($don -and $dd -eq 0 -and $bk -and -not $bh){$av.Add('ADV|nodump|'+$sd+'|'+$wn)};if($dt -eq '1' -and $dd -eq 0 -and $rv -ne '-' -and $cfg -eq 'list'){$f1=[int64]$rv+1;$f2=[int64]$rv+257;if($f2 -le 99999999){foreach($x in $es){if($x.D -eq $sd -and $x.K -eq 'custom'){if($x.X -lt $f1){$av.Add('ADV|dumpsize|'+$sd+'|'+$f1+'|'+$x.X)}elseif($x.X -lt $f2){$av.Add('ADV|dumpshort|'+$sd+'|'+$f2+'|'+$x.X)}}}}};$fx=$cfg -eq 'none' -and $src -ne 'unknown';if($cfg -eq 'list' -and $src -eq 'wmi'){$fx=$true;foreach($x in $es){$h=$false;if($x.K -eq 'custom'){foreach($u in $us){if($u.D -eq $x.D -and $u.A -ne '-'){if([int64]$u.A -ge $x.X){$h=$true}}}};if(-not $h){$fx=$false}}};if($fx -and $pn -eq 0){try{if(-not ('PTPf.N' -as [type])){$q=[char]34;Add-Type -TypeDefinition ('using System.Runtime.InteropServices;namespace PTPf{public static class N{[DllImport('+$q+'kernel32.dll'+$q+',EntryPoint='+$q+'K32GetPerformanceInfo'+$q+')]public static extern bool GPI([Out] byte[] b,int cb);}}')};$z=[IntPtr]::Size;$b=New-Object byte[] (@(56,104)[[int]($z -eq 8)]);if([PTPf.N]::GPI($b,$b.Length)){$r={param($i)if($z -eq 8){[double][BitConverter]::ToUInt64($b,8+8*$i)}else{[double][BitConverter]::ToUInt32($b,4+4*$i)}};$g=(& $r 9)/1MB;$cn=Nm ((& $r 0)*$g);$cl=Nm ((& $r 1)*$g);$cp=Nm ((& $r 2)*$g)}}catch{};if($cp -ne '-' -and $cl -ne '-'){if([int64]$cl -gt 0 -and [int64]$cp*10 -ge [int64]$cl*9){$av.Add('ADV|commit|'+$cp+'|'+$cl)}}};if(@($us|Where-Object{$_.T}).Count -gt 0){$av.Add('ADV|temp')};if($cfg -eq 'list'){foreach($x in $es){if($x.K -eq 'custom'){$o.Add('SET|custom|'+$x.D+'|'+$x.I+'|'+$x.X)}elseif($x.K -eq 'sys'){$o.Add('SET|sys|'+$x.D)}elseif($x.K -eq 'auto'){$o.Add('SET|auto')}else{$o.Add('SET|unrec|'+$x.R)}}}else{$o.Add('SET|'+$cfg)};if($src -eq 'unknown'){if($ud){$o.Add('USE|disagree')}else{$o.Add('USE|unknown')}}elseif($us.Count -eq 0){$o.Add('USE|none')}else{foreach($u in $us){$o.Add('USE|'+$u.N+'|'+$u.A+'|'+$u.C+'|'+$u.P)}};$o.Add('MEM|'+$rv+'|'+$ri+'|'+$cn+'|'+$cl+'|'+$cp);$o.Add('DMP|'+$dt+'|'+$dd+'|'+$dr);if($pn -eq 1){$o.Add('PND|1')};foreach($a in $av){$o.Add($a)};$o.Add('END|ok');$o|Out-File -FilePath $env:PT_PGF_RES -Encoding ASCII"
set "PT_PGF_RES="
call :_pgfShow
del "!_pgfres!" >nul 2>&1
goto :eof

:_pgfShow
rem  Prints nothing unless the worker's END record is present: a partial file gives a wrong verdict.
set "_pgfok="
if exist "!_pgfres!" findstr /b /l /c:"END|ok" "!_pgfres!" >nul 2>&1 && set "_pgfok=1"
if not defined _pgfok goto _pgfNone
set "_pgfadv="
for /f "usebackq tokens=1-6 delims=|" %%a in ("!_pgfres!") do (
    set "_pgft=%%a" & set "_pgf1=%%b" & set "_pgf2=%%c" & set "_pgf3=%%d" & set "_pgf4=%%e" & set "_pgf5=%%f"
    call :_pgfRec
)
if not defined _pgfadv goto :eof
echo   [i] sincript changes neither setting. Both are in SystemPropertiesAdvanced: Performance
echo       Settings ^> Advanced ^> Virtual memory, and Startup and Recovery for the crash-dump type.
goto :eof

:_pgfNone
echo   Could not read the page-file state - PowerShell or WMI did not answer. Nothing was judged.
goto :eof

:_pgfRec
rem  One record: each branch prints fixed text around its fields; an unknown tag prints nothing.
rem  Keep lines within 98 columns for a 30-character name and 8-digit numbers.
if "!_pgft!"=="SET" goto _pgfSet
if "!_pgft!"=="USE" goto _pgfUse
if "!_pgft!"=="MEM" goto _pgfMem
if "!_pgft!"=="DMP" goto _pgfDmp
if "!_pgft!"=="PND" goto _pgfPnd
if "!_pgft!"=="ADV" goto _pgfAdv
goto :eof

:_pgfSet
if "!_pgf1!"=="auto" echo   Setting   : system-managed - Windows picks the drive and the size ^(the default^)
if "!_pgf1!"=="none" echo   Setting   : NO page file
if "!_pgf1!"=="sys" echo   Setting   : !_pgf2!: system-managed size
if "!_pgf1!"=="custom" if "!_pgf3!"=="!_pgf4!" echo   Setting   : !_pgf2!: custom, fixed at !_pgf3! MB
if "!_pgf1!"=="custom" if not "!_pgf3!"=="!_pgf4!" echo   Setting   : !_pgf2!: custom, !_pgf3! MB, can grow to !_pgf4! MB
if "!_pgf1!"=="unrec" echo   Setting   : unrecognised entry "!_pgf2!" - not judged
if "!_pgf1!"=="absent" echo   Setting   : unrecognised - the registry holds no PagingFiles value; not judged
if "!_pgf1!"=="unreadable" echo   Setting   : could not be read from the registry - not judged
goto :eof

:_pgfUse
if "!_pgf1!"=="none" echo   In use    : none right now
if "!_pgf1!"=="unknown" echo   In use    : could not be read - WMI and the registry both failed
if "!_pgf1!"=="disagree" echo   In use    : unknown - WMI lists none, but the registry lists a page file in use
if "!_pgf1!"=="none" goto :eof
if "!_pgf1!"=="unknown" goto :eof
if "!_pgf1!"=="disagree" goto :eof
if "!_pgf2!"=="-" echo   In use    : !_pgf1!  ^(size not available - WMI did not answer^)
if not "!_pgf2!"=="-" echo   In use    : !_pgf1!  !_pgf2! MB, !_pgf3! MB used, peak !_pgf4! MB
goto :eof

:_pgfMem
if "!_pgf1!"=="-" if "!_pgf2!"=="-" echo   RAM       : not available
if "!_pgf1!"=="-" if not "!_pgf2!"=="-" echo   RAM       : !_pgf2! MB installed ^(how much of it Windows can use is not available^)
if not "!_pgf1!"=="-" if "!_pgf2!"=="-" echo   RAM       : !_pgf1! MB usable by Windows
if not "!_pgf1!"=="-" if not "!_pgf2!"=="-" echo   RAM       : !_pgf1! MB usable by Windows, !_pgf2! MB installed
if "!_pgf4!"=="-" echo   Committed : not available
if "!_pgf4!"=="-" goto :eof
if "!_pgf3!"=="-" echo   Committed : the limit is !_pgf4! MB ^(RAM plus page files^); the amount in use is not available
if "!_pgf3!"=="-" goto :eof
if "!_pgf5!"=="-" echo   Committed : !_pgf3! MB of a !_pgf4! MB limit ^(RAM plus page files^)
if not "!_pgf5!"=="-" echo   Committed : !_pgf3! MB of a !_pgf4! MB limit ^(RAM plus page files^), peak !_pgf5! MB
goto :eof

:_pgfDmp
if "!_pgf1!"=="0" echo   Crash dump: off - Windows writes no memory dump after a blue screen
if "!_pgf1!"=="1" echo   Crash dump: complete memory dump ^(CrashDumpEnabled=1^)
if "!_pgf1!"=="2" echo   Crash dump: kernel memory dump ^(CrashDumpEnabled=2^)
if "!_pgf1!"=="3" echo   Crash dump: small memory dump ^(CrashDumpEnabled=3^)
if "!_pgf1!"=="7" echo   Crash dump: automatic memory dump, the Windows default ^(CrashDumpEnabled=7^)
if "!_pgf1!"=="A" echo   Crash dump: active memory dump ^(CrashDumpEnabled=1 with FilterPages=1^)
if "!_pgf1!"=="X" if "!_pgf3!"=="-" echo   Crash dump: CrashDumpEnabled holds an unrecognised value - not judged
if "!_pgf1!"=="X" if not "!_pgf3!"=="-" echo   Crash dump: unrecognised value CrashDumpEnabled=!_pgf3! - not judged
if "!_pgf1!"=="U" echo   Crash dump: CrashDumpEnabled is not set - not judged
if "!_pgf1!"=="R" echo   Crash dump: the CrashControl key could not be read - not judged
if "!_pgf2!"=="1" echo               plus a dedicated dump file ^(DedicatedDumpFile is set^)
goto :eof

:_pgfPnd
echo   [i] The setting differs from the page file^(s^) in use: a change is waiting for a restart,
echo       or Windows could not create a configured file. The figures above are for the files in use.
goto :eof

:_pgfAdv
if "!_pgf1!"=="none" goto _pgfAdvNone
if "!_pgf1!"=="nodump" goto _pgfAdvNoDump
if "!_pgf1!"=="dumpsize" goto _pgfAdvDumpSize
if "!_pgf1!"=="dumpshort" goto _pgfAdvDumpShort
if "!_pgf1!"=="commit" goto _pgfAdvCommit
if "!_pgf1!"=="temp" goto _pgfAdvTemp
goto :eof

:_pgfAdvNone
set "_pgfadv=1"
if "!_pgf2!"=="next" goto _pgfAdvNoneNext
echo   [ADVISORY] No page file: Windows caps committed memory just below your RAM. Programs that
echo              reach the cap can fail, freeze or crash - even while RAM does not look full,
echo              because memory counts as committed before it is used. Windows' default is a
echo              system-managed page file.
goto :eof

:_pgfAdvNoneNext
echo   [ADVISORY] After the next restart there will be NO page file. Windows then caps committed
echo              memory just below your RAM, and programs that reach the cap can fail, freeze
echo              or crash - even while RAM does not look full, because memory counts as
echo              committed before it is used. Windows' default is a system-managed page file.
goto :eof

:_pgfAdvNoDump
set "_pgfadv=1"
if "!_pgf3!"=="next" goto _pgfAdvNoDumpNext
echo   [ADVISORY] Crash dumps are on, but the Windows drive !_pgf2!: has no page file and there is
echo              no dedicated dump file, so after a blue screen no memory dump can be written.
goto :eof

:_pgfAdvNoDumpNext
echo   [ADVISORY] Crash dumps are on, but after the next restart the Windows drive !_pgf2!: will
echo              have no page file, and there is no dedicated dump file - from then on, no memory
echo              dump can be written after a blue screen.
goto :eof

:_pgfAdvDumpSize
set "_pgfadv=1"
echo   [ADVISORY] The page file on !_pgf2!: is set to at most !_pgf4! MB, but a complete memory dump
echo              needs at least !_pgf3! MB there ^(RAM plus 1 MB^), so with this setting it cannot
echo              be written after a blue screen.
goto :eof

:_pgfAdvDumpShort
set "_pgfadv=1"
echo   [ADVISORY] The page file on !_pgf2!: is set to at most !_pgf4! MB. Microsoft sizes it at
echo              !_pgf3! MB for a complete memory dump ^(RAM plus 257 MB: a 1 MB header and up to
echo              256 MB of driver data^), so with this setting the dump may be cut short.
goto :eof

:_pgfAdvCommit
set "_pgfadv=1"
echo   [ADVISORY] Since the last restart, committed memory peaked at !_pgf2! MB - 90%% or more of
echo              its !_pgf3! MB limit - and that limit cannot grow: no page file, or fixed ones
echo              already at their maximum. Committed memory is what programs have reserved, not
echo              the RAM in use, so it can reach the limit while RAM still looks half free. At
echo              the limit, programs fail to get memory and Windows warns of low virtual memory;
echo              it grows a system-managed page file at exactly this 90%% mark instead.
goto :eof

:_pgfAdvTemp
set "_pgfadv=1"
echo   [ADVISORY] Windows is running on a TEMPORARY page file, which it creates usually because
echo              there is no permanent one. Check the setting above.
goto :eof
rem  HELPER: prove a cleanup root before anything is deleted under it
rem =====================================================================================
:CleanRoot
rem  Arg 1 = env variable NAME, read late. Sets _cleanNAME=1 only if its value is defined, an
rem  existing folder and not a drive root; otherwise prints why, and gated deletes are skipped.
set "_crv=!%~1!"
if not defined _crv (
    echo   [SKIP] %~1 is not set in this environment - nothing under it was touched.
    call :Log "SKIP cleanup root %~1: undefined or empty"
    goto :eof
)
if not exist "!_crv!\" (
    echo   [SKIP] %~1 does not point at a folder that exists ^(!_crv!^) - nothing under it
    echo          was touched.
    set "_LOGMSG=SKIP cleanup root %~1: not a directory: !_crv!" & call :LogVar _LOGMSG
    goto :eof
)
if "!_crv:~3!"=="" (
    echo   [SKIP] %~1 is a drive root ^(!_crv!^) - refusing to delete from the root of a
    echo          drive. Nothing under it was touched.
    set "_LOGMSG=SKIP cleanup root %~1: drive root: !_crv!" & call :LogVar _LOGMSG
    goto :eof
)
set "_clean%~1=1"
goto :eof

:RunVar
rem  Arg 1 = NAME of a variable holding one command, no pipes or redirects. Like :Run, for paths
rem  under the user profile: call would re-parse them. Two setlocals: the shared exit ends both.
setlocal EnableDelayedExpansion
setlocal EnableDelayedExpansion
set "_cmd=!%~1!"
set "_runlate=1"
goto _runBody

:Run
rem %1 = full command line (echoed, logged, run via cmd /s /c)
rem Read with delayed expansion off, then only late, to keep special chars. Profile paths: :RunVar.
rem Returns only _runrc, the exit code, and _FAILS across the endlocal.
setlocal DisableDelayedExpansion
set "_cmd=%~1"
setlocal EnableDelayedExpansion
rem  Collapse the doubled quotes callers use, or cmd /s /c splits the path at its first space.
set "_cmd=!_cmd:""="!"
set "_runlate="

:_runBody
rem  Log a quote-stripped copy, by name via :LogVar: a call argument would lose a percent sign.
set "_cmdlog=!_cmd:"=!"
echo   ^> !_cmd!
set "_runlog=EXEC: !_cmdlog!"
call :LogVar _runlog
if defined _runlate goto _runLate
cmd /s /c "!_cmd!" >nul 2>&1
goto _runRc

:_runLate
cmd /d /v:on /s /c "^!_cmd^!" >nul 2>&1

:_runRc
rem  Compare the saved code with 0: if errorlevel 1 misses negative HRESULT exit codes.
set "_runrc=%errorlevel%"
if not "%_runrc%"=="0" (
    set "_runlog=FAIL: !_cmdlog!"
    call :LogVar _runlog
    rem  Tally only tracked actions run unelevated; elevated nonzero exits are usually benign.
    if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS+=1
) else ( set "_runlog=OK: !_cmdlog!" & call :LogVar _runlog )
endlocal & endlocal & set "_runrc=%_runrc%" & set "_FAILS=%_FAILS%"
goto :eof

:RunLive
rem  Arg 1 = full command line. Like :Run, but output streams to the console, for DISM or SFC.
setlocal DisableDelayedExpansion
set "_cmd=%~1"
setlocal EnableDelayedExpansion
rem  Collapse the doubled quotes callers use, or cmd /s /c splits the path at its first space.
set "_cmd=!_cmd:""="!"
set "_cmdlog=!_cmd:"=!"
echo   ^> !_cmd!
set "_runlog=EXEC: !_cmdlog!"
call :LogVar _runlog
cmd /s /c "!_cmd!"
rem  Compare the saved code with 0: if errorlevel 1 misses negative HRESULT exit codes.
set "_runrc=%errorlevel%"
if not "%_runrc%"=="0" (
    set "_runlog=FAIL: !_cmdlog!"
    call :LogVar _runlog
    if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS+=1
) else ( set "_runlog=OK: !_cmdlog!" & call :LogVar _runlog )
endlocal & endlocal & set "_runrc=%_runrc%" & set "_FAILS=%_FAILS%"
goto :eof

:Summary
rem Arg 1 = success phrase: [OK] if _FAILS is 0, else [WARN] with the count or _SUMCAUSE.
rem Keep it goto-only, no if/else block: a closing paren in the phrase would end it early.
if not defined _FAILS set "_FAILS=0"
if not defined _ELEV set "_ELEV=1"
rem  Echo the phrase late from a variable, so an ampersand in it stays text.
set "_sumtext=%~1"
if not "%_FAILS%"=="0" goto _sum_warn
echo [OK] !_sumtext!
goto _sum_done

:_sum_warn
if defined _SUMCAUSE goto _sum_cause
echo [WARN] !_sumtext! -- %_FAILS% change(s) could NOT be applied. See the [FAIL] line(s) above.
if "%_ELEV%"=="0" goto _sum_notelev
echo        This window is elevated, so those keys are protected or held by Windows. See the log.
goto _sum_done

:_sum_cause
echo [WARN] !_sumtext!
echo        !_SUMCAUSE!
goto _sum_done

:_sum_notelev
echo        This window is NOT elevated - close it and use Run as administrator, then retry.

:_sum_done
rem  Tracking and cause are per action: clear them so a later action cannot inherit them.
set "_RUNTRACK="
set "_SUMCAUSE="
goto :eof

:LaptopAdvisory
rem  Warning-only laptop and undervolt advisory: never blocks or changes a default or preset.
call :DetectUndervolt
if /i not "%MACHINE%"=="laptop" goto _lapUv
echo   [ADVISORY] This machine looks like a laptop - this action typically costs battery
echo              life / heat there for little gain. It stays your call.

:_lapUv
if not defined UVTOOL goto :eof
echo   [ADVISORY] !UVTOOL! is installed, so this machine may be UNDERVOLTED. Pushing the CPU
echo              to sustained maximum clocks is where an otherwise-stable undervolt fails,
echo              and the CPU reports it as an uncorrectable machine check ^(bugcheck 0x124^),
echo              not as something that looks like a software crash. If you are undervolted,
echo              prefer High Performance or Balanced over Ultimate.
goto :eof

:DesktopAdvisory
rem  Desktop counterpart, for the LargeSystemCache prompt only.
if /i not "%MACHINE%"=="desktop" goto :eof
echo   [ADVISORY] This machine looks like a desktop - this option mainly helps some laptops
echo              and can hurt desktop performance.
goto :eof

:ApplyDns
rem %1 = friendly name ; uses %DNSSRV% as the PowerShell address list.
echo Setting %~1 DNS on every physical adapter...
call :Log "DNS -> %~1 : %DNSSRV%"
set "_dnsres=!TEMP!\pt_dnsres_%RANDOM%.txt"
del "!_dnsres!" >nul 2>&1
set "PT_DNSRES=!_dnsres!"
start "" /min /wait powershell -NoProfile -Command "$ok=0;$fail=0;Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { try { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses @(%DNSSRV%) -ErrorAction Stop; $ok++ } catch { $fail++ } }; ('' + $ok + ' ' + $fail) | Out-File -FilePath $env:PT_DNSRES -Encoding ASCII; if($ok -gt 0){exit 0}else{exit 1}"
set "_dnsrc=%errorlevel%"
set "PT_DNSRES="
ipconfig /flushdns >nul 2>&1
call :DnsResult "%_dnsrc%" "%~1 DNS applied"
if "%_dnsrc%"=="0" echo      Verify under Backups ^& status ^> Show current status.
goto :eof

:DnsResult
rem %1 = PS child exit code (0 = at least one adapter changed) ; %2 = success phrase.
rem  Reads the "ok fail" counts the child left in %_dnsres% and prints an honest line.
set "_phrase=%~2"
set "_okN=0" & set "_failN=0"
if exist "!_dnsres!" for /f "usebackq tokens=1,2" %%a in ("!_dnsres!") do ( set "_okN=%%a" & set "_failN=%%b" )
del "!_dnsres!" >nul 2>&1
if "%~1"=="0" (
    echo [OK] !_phrase! on !_okN! adapter^(s^), !_failN! failed.
    call :Log "OK: DNS - !_phrase! ok=!_okN! fail=!_failN!"
) else (
    echo [ERROR] !_phrase!: it failed on every physical adapter. Make sure this window is
    echo         elevated and that this PC has a physical network adapter, then try again.
    call :Log "FAIL: DNS - !_phrase! changed no adapters (fail=!_failN!)"
    rem  Count it, so :Summary and the exit code do not report success.
    set /a _FAILS+=1
)
goto :eof

:ShowReg
rem %1 = key ; %2 = value name ; prints "value = data" or "(not set)"
set "_found="
set "_srd="
for /f "tokens=2,*" %%a in ('reg query "%~1" /v "%~2" 2^>nul ^| findstr /I /C:"%~2"') do (set "_srd=%%b" & set "_found=1")
if not defined _found echo   %~2 = (not set)
if defined _found echo   %~2 = !_srd!
goto :eof

:SafeRegAdd
rem %1=Key %2=Value %3=Type %4=Data %5=Description.
rem Backs up only the single value being changed, not the whole key, to keep backups small.
setlocal EnableDelayedExpansion
set "_key=%~1"
set "_val=%~2"
set "_type=%~3"
set "_data=%~4"
set "_desc=%~5"
echo   [REG] !_desc!
set "_ln="
for /f "delims=" %%L in ('reg query "!_key!" /v "!_val!" 2^>nul ^| findstr /I /C:"REG_"') do set "_ln=%%L"
rem  Skip backup and write if the value already equals the target, so the original undo survives.
if not defined _ln goto _sraDoWrite
if /i "!_type!"=="REG_DWORD" goto _sraIdemDword
if /i "!_type!"=="REG_SZ" goto _sraIdemSz
goto _sraDoWrite

:_sraIdemDword
rem  Require type REG_DWORD before comparing numbers. set /a saturates values above 2147483647,
rem  so when both sides saturate compare the raw text; write large values as 0x hex at call sites.
set "_td=REG_!_ln:*REG_=!"
for /f "tokens=1,*" %%a in ("!_td!") do ( set "_rt=%%a" & set "_rd=%%b" )
if /i not "!_rt!"=="REG_DWORD" goto _sraDoWrite
for %%a in (!_ln!) do set "_curtok=%%a"
set /a _curdec=_curtok 2>nul
set /a _tgtdec=_data 2>nul
if "!_curdec!"=="2147483647" if "!_tgtdec!"=="2147483647" (
    if /i not "!_curtok!"=="!_data!" goto _sraDoWrite
    echo   [SKIP] !_desc! - already set.
    endlocal & goto :eof
)
if not "!_curdec!"=="!_tgtdec!" goto _sraDoWrite
echo   [SKIP] !_desc! - already set.
endlocal & goto :eof

:_sraIdemSz
set "_td=REG_!_ln:*REG_=!"
set "_rd="
for /f "tokens=1,*" %%a in ("!_td!") do ( set "_rt=%%a" & set "_rd=%%b" )
if /i not "!_rt!"=="REG_SZ" goto _sraDoWrite
if not defined _rd set "_rd="
if not "!_rd!"=="!_data!" goto _sraDoWrite
echo   [SKIP] !_desc! - already set.
endlocal & goto :eof

:_sraDoWrite
if defined PRESET_MODE goto _sraJson
rem  ----- manual mode: back up ONLY this single value to its own .reg file -----
set "_safe=!_key:\=_!"
set "_safe=!_safe::=!"
set "_safe=!_safe: =_!"
rem  Two random numbers, not one, so backups of values under the same key do not collide.
set "_bkp=!BACKUP_DIR!\!_safe!_%RANDOM%%RANDOM%.reg"
rem  expand the hive short name to the full name a .reg file requires
set "_rk=!_key!"
set "_rk=!_rk:HKLM\=HKEY_LOCAL_MACHINE\!"
set "_rk=!_rk:HKCU\=HKEY_CURRENT_USER\!"
set "_rk=!_rk:HKCR\=HKEY_CLASSES_ROOT\!"
set "_rk=!_rk:HKU\=HKEY_USERS\!"
set "_rk=!_rk:HKCC\=HKEY_CURRENT_CONFIG\!"
> "!_bkp!" echo Windows Registry Editor Version 5.00
>>"!_bkp!" echo.
>>"!_bkp!" echo [!_rk!]
call :BackupValueLine
rem  No backup file on disk: refuse the live write.
if not exist "!_bkp!" (
    echo         [FAIL] "!_desc!" was NOT applied - could not write a per-value backup ^(AV / Controlled Folder Access / disk full^).
    call :Log "  FAIL backup !_key! !_val! - write aborted"
    endlocal & set /a _FAILS+=1 & exit /b 1
)
goto _sraApply

:_sraJson
rem  ----- preset mode: append this value's prior state to the JSON backup -----
if not exist "!PRESET_JSON_TMP!" (
    echo         [FAIL] "!_desc!" was NOT applied - preset JSON backup is missing or unwritable.
    call :Log "  FAIL preset backup !_key! !_val! - write aborted"
    endlocal & set /a _FAILS+=1 & exit /b 1
)
call :BackupValueJson

:_sraApply
call :Log "REGADD !_key! !_val!=!_data! (!_desc!)"
set "_rc=0"
reg add "!_key!" /v "!_val!" /t !_type! /d "!_data!" /f >nul 2>&1
if errorlevel 1 set "_rc=1"
if "!_rc!"=="1" echo         [FAIL] "!_desc!" was NOT applied - run as Administrator, or the key is protected.
if "!_rc!"=="1" ( call :Log "  FAIL regadd !_key! !_val!" ) else ( call :Log "  OK regadd !_key! !_val!" )
endlocal & set /a _FAILS+=%_rc% & exit /b %_rc%

:SafeRegDelete
rem %1=Key %2=Value %3=Description. Backs up the single value (same as SafeRegAdd), then deletes it.
setlocal EnableDelayedExpansion
set "_key=%~1"
set "_val=%~2"
set "_desc=%~3"
echo   [REG] !_desc!
set "_ln="
for /f "delims=" %%L in ('reg query "!_key!" /v "!_val!" 2^>nul ^| findstr /I /C:"REG_"') do set "_ln=%%L"
if not defined _ln ( call :Log "REGDEL !_key! !_val! (already absent)" & endlocal & goto :eof )
if defined PRESET_MODE goto _srdJson
set "_safe=!_key:\=_!"
set "_safe=!_safe::=!"
set "_safe=!_safe: =_!"
set "_bkp=!BACKUP_DIR!\!_safe!_%RANDOM%%RANDOM%.reg"
set "_rk=!_key!"
set "_rk=!_rk:HKLM\=HKEY_LOCAL_MACHINE\!"
set "_rk=!_rk:HKCU\=HKEY_CURRENT_USER\!"
set "_rk=!_rk:HKCR\=HKEY_CLASSES_ROOT\!"
set "_rk=!_rk:HKU\=HKEY_USERS\!"
set "_rk=!_rk:HKCC\=HKEY_CURRENT_CONFIG\!"
> "!_bkp!" echo Windows Registry Editor Version 5.00
>>"!_bkp!" echo.
>>"!_bkp!" echo [!_rk!]
call :BackupValueLine
if not exist "!_bkp!" (
    echo         [FAIL] "!_desc!" was NOT applied - could not write a per-value backup ^(AV / Controlled Folder Access / disk full^).
    call :Log "  FAIL backup !_key! !_val! - write aborted"
    endlocal & set /a _FAILS+=1 & exit /b 1
)
goto _srdApply

:_srdJson
if not exist "!PRESET_JSON_TMP!" (
    echo         [FAIL] "!_desc!" was NOT applied - preset JSON backup is missing or unwritable.
    call :Log "  FAIL preset backup !_key! !_val! - write aborted"
    endlocal & set /a _FAILS+=1 & exit /b 1
)
call :BackupValueJson

:_srdApply
call :Log "REGDEL !_key! !_val! (!_desc!)"
set "_rc=0"
reg delete "!_key!" /v "!_val!" /f >nul 2>&1
if errorlevel 1 set "_rc=1"
if "!_rc!"=="1" echo         [FAIL] "!_desc!" was NOT applied - run as Administrator, or the key is protected.
if "!_rc!"=="1" ( call :Log "  FAIL regdel !_key! !_val!" ) else ( call :Log "  OK regdel !_key! !_val!" )
endlocal & set /a _FAILS+=%_rc% & exit /b %_rc%

:BackupValueLine
rem  appends the prior state of ONE value to !_bkp! (runs inside SafeRegAdd's setlocal scope)
if not defined _ln (
    >>"!_bkp!" echo "!_val!"=-
    goto :eof
)
set "_td=REG_!_ln:*REG_=!"
set "_rd="
for /f "tokens=1,*" %%a in ("!_td!") do ( set "_rt=%%a" & set "_rd=%%b" )
rem  Non-ASCII data would restore as mojibake from an ANSI .reg; flag it and decline below.
set "_naData="
if defined _rd call :NonAsciiCheck
if /i "!_rt!"=="REG_DWORD" (
    set "_hx=0000000!_rd:~2!"
    >>"!_bkp!" echo "!_val!"=dword:!_hx:~-8!
    goto :eof
)
if /i "!_rt!"=="REG_SZ" (
    if defined _naData (
        >>"!_bkp!" echo ; original value was REG_SZ with non-ASCII data - not auto-restorable from this file - use the full registry backup or a restore point
        goto :eof
    )
    rem  Guard on defined _rd: substitution on an undefined var returns the pattern itself.
    set "_sd="
    if defined _rd set "_sd=!_rd:\=\\!"
    if defined _rd set "_sd=!_sd:"=\"!"
    >>"!_bkp!" echo "!_val!"="!_sd!"
    goto :eof
)
>>"!_bkp!" echo ; original value was !_rt! = !_rd!
>>"!_bkp!" echo ; not auto-restorable from this file - use the full registry backup or a restore point
goto :eof

:CreateRestorePoint
echo Creating a System Restore Point (may take a moment)...
call :Log "Creating restore point"
set "_rpf=!TEMP!\pt_rp_%RANDOM%%RANDOM%.txt"
set "PT_RPF=!_rpf!"
rem  Compare the newest restore point before and after: a skipped one is only a warning.
start "" /min /wait powershell -NoProfile -Command "& { $bn=0; $b=@(Get-ComputerRestorePoint -ErrorAction SilentlyContinue); if ($b.Count -gt 0) { $bn=($b | Select-Object -Last 1).SequenceNumber }; $err=$null; try { Enable-ComputerRestore -Drive '%SystemDrive%\' -ErrorAction SilentlyContinue; Checkpoint-Computer -Description 'PerfTweaks' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue } catch { $err=$_.Exception.Message }; if ($err) { 'Restore point FAILED: ' + $err } else { $an=0; $a=@(Get-ComputerRestorePoint -ErrorAction SilentlyContinue); if ($a.Count -gt 0) { $an=($a | Select-Object -Last 1).SequenceNumber }; if ($an -gt $bn) { 'Restore point created.' } else { 'NO restore point was created - Windows skips one within 24 hours of the last, and System Protection may be off for ' + $env:SystemDrive + '. Continuing without it.' } } } | Out-File -FilePath $env:PT_RPF -Encoding ASCII"
set "PT_RPF="
if exist "!_rpf!" ( type "!_rpf!" & del "!_rpf!" >nul 2>&1 )
goto :eof

:CreateRegBackup
echo Exporting HKLM and HKCU (this can take a minute)...
call :Log "Full registry export"
rem  Verify both exports; they share one 30-bit stamp so /y never overwrites an older pair.
set "_rbStamp=%RANDOM%%RANDOM%"
set "_rbHKLM=!BACKUP_DIR!\FullReg_HKLM_%_rbStamp%.reg"
set "_rbHKCU=!BACKUP_DIR!\FullReg_HKCU_%_rbStamp%.reg"
set "_rbOK=1"
reg export HKLM "!_rbHKLM!" /y >nul 2>&1
if errorlevel 1 set "_rbOK=0"
if not exist "!_rbHKLM!" set "_rbOK=0"
reg export HKCU "!_rbHKCU!" /y >nul 2>&1
if errorlevel 1 set "_rbOK=0"
if not exist "!_rbHKCU!" set "_rbOK=0"
if "%_rbOK%"=="1" (
    echo [OK] Saved to !BACKUP_DIR!
    set "_LOGMSG=OK: full registry export -> !_rbHKLM! , !_rbHKCU!" & call :LogVar _LOGMSG
) else (
    echo [ERROR] Full registry backup FAILED or is incomplete - do NOT rely on it.
    echo         Make sure this window is elevated and that the folder is writable:
    echo         !BACKUP_DIR!
    call :Log "FAIL: full registry export (HKLM and/or HKCU missing or errored)"
)
goto :eof

:InstallAsarInto
rem Arg 1 = Discord, DiscordPTB or DiscordCanary. Source is the caller's _SRC, read late, not
rem passed as an arg, so paths with an exclamation mark survive.
setlocal EnableDelayedExpansion
set "_base=!LOCALAPPDATA!\%~1"
set "_flav=%~1"
set "_asrc=!_SRC!"
set "_resdir="
rem  Pick the highest-version app-* folder with resources; a plain dir sort misorders versions.
set "PT_OABASE=!_base!"
set "_oares=!TEMP!\pt_oares_%RANDOM%.txt"
del "!_oares!" >nul 2>&1
set "PT_OARES=!_oares!"
start "" /min /wait powershell -NoProfile -Command "$b=$env:PT_OABASE;$d=Get-ChildItem -LiteralPath $b -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'resources') } | Sort-Object { try{[version]($_.Name -replace '^app-','')}catch{[version]'0.0'} } -Descending | Select-Object -First 1; if($d){ $d.Name | Out-File -FilePath $env:PT_OARES -Encoding ASCII }"
set "PT_OABASE=" & set "PT_OARES="
rem  Only the ASCII folder name comes back; a non-ASCII profile path would not survive the file.
if exist "!_oares!" for /f "usebackq delims=" %%A in ("!_oares!") do set "_resdir=!_base!\%%A\resources"
del "!_oares!" >nul 2>&1
if not defined _resdir ( echo [SKIP] %_flav%: no app-*\resources folder. & endlocal & goto :eof )
set "_target=app.asar"
if exist "!_resdir!\_app.asar"     set "_target=_app.asar"
if exist "!_resdir!\app.orig.asar" set "_target=app.orig.asar"
if exist "!_resdir!\app.asar.orig" set "_target=app.asar.orig"
echo [%_flav%] Target: "!_resdir!\!_target!"
rem  Back up the original beside the .asar and in the backup folder; report which one landed.
set "_localbak=!_resdir!\!_target!.bak"
set "_docbak=!BACKUP_DIR!\%_flav%_!_target!.bak"
set "_hadorig=0"
set "_bakloc="
if exist "!_resdir!\!_target!" (
    set "_hadorig=1"
    rem  Write-once: re-runs are expected after Discord updates, and only the first copy is stock.
    if not exist "!_localbak!" copy /y "!_resdir!\!_target!" "!_localbak!" >nul 2>&1
    if not exist "!_docbak!"   copy /y "!_resdir!\!_target!" "!_docbak!"  >nul 2>&1
    if exist "!_localbak!" set "_bakloc=local"
    if not exist "!_localbak!" if exist "!_docbak!" set "_bakloc=doc"
)
rem  An original with no landed backup: refuse the write rather than overwrite it.
if "!_hadorig!"=="1" if not defined _bakloc (
    echo [FAIL] %_flav%: NOT installed - no backup of the original could be saved. Discord's
    echo        folder and the backup folder were both blocked ^(antivirus / Controlled Folder
    echo        Access^). The existing .asar is untouched; allow writes to either and re-run.
    call :Log "ABORT: OpenAsar %_flav% - no backup landed, asar left intact"
    endlocal & set /a _OAFAIL+=1 & goto :eof
)
copy /y "!_asrc!" "!_resdir!\!_target!" >nul
if errorlevel 1 (
    echo [WARN] %_flav%: copy failed ^(file in use? quit Discord fully and re-run^).
    endlocal & set /a _OAFAIL+=1
    goto :eof
)
if "!_bakloc!"=="local" echo [OK] %_flav%: OpenAsar installed. Original backed up beside the .asar as "!_target!.bak".
if "!_bakloc!"=="doc" (
    echo [OK] %_flav%: OpenAsar installed, but the backup could NOT be written into Discord's
    echo      folder ^(often blocked by antivirus / Controlled Folder Access^). The original is
    echo      safe in the backup folder - to revert, copy it back over the .asar:
    echo        from: "!_docbak!"
    echo        to:   "!_resdir!\!_target!"
)
if not defined _bakloc if "!_hadorig!"=="1" (
    echo [WARN] %_flav%: OpenAsar installed, but NO backup of the original could be saved
    echo        ^(both Discord's folder and the backup folder were blocked^). To revert,
    echo        reinstall Discord - then allow writes and re-run if you want a backup.
)
if not defined _bakloc if "!_hadorig!"=="0" echo [OK] %_flav%: OpenAsar installed. ^(No previous .asar to back up.^)
endlocal & set "_DONE=1" & goto :eof
rem =====================================================================================
rem  PRESETS  -  auto-apply groups of tweaks; registry changes saved to ONE JSON backup
rem =====================================================================================
:MenuPresets
cls
call :Logo
echo ======================================  AUTO-APPLY PRESETS  ======================================
echo  A preset applies a defined group of tweaks at once and saves ONE JSON backup of the
echo  registry values it changes (manual menu actions still save individual .reg files).
echo  Not in the JSON, each with its own way back: power plan and telemetry services -
echo  Backups ^& status; DNS - Network ^> DNS ^> 4 ^(DHCP, not your old servers^); BCD timers -
echo  Advanced ^> 4 ^(Windows defaults^); OpenAsar - its .bak. TCP tuning and memory compression
echo  have no in-app undo, and the cleanup deletes files for good.
echo --------------------------------------------------------------------------------------------------
echo     1.  Light     (temp cleanup, privacy, TCP tweaks, DNS)
echo     2.  Moderate  (recommended safe set + power plan + OpenAsar)
echo     3.  Heavy     (most tweaks; NO repair / NO stack reset / NO debloat / NO mitigations)
echo     4.  Custom    (load a user preset from the sincript_presets folder)
echo     5.  Restore from a preset backup (JSON)
echo     0.  Back
echo ==================================================================================================

:MenuPresets_ask
set "sel="
set /p "sel=Choose: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto MenuPresets_ask
if "!sel!"=="1" goto PresetLight
if "!sel!"=="2" goto PresetModerate
if "!sel!"=="3" goto PresetHeavy
if "!sel!"=="4" goto PresetCustom
if "!sel!"=="5" goto RestorePresetJson
if "!sel!"=="0" goto MainMenu
goto MenuPresets
rem ---------- preset capture helpers ----------
:PresetBegin
rem %1 = preset label used in the backup filename
set "_pname=%~1"
set "_PWBAK_FILE="
set "_TLBAK_FILE="
rem  Reset the global _PWPLAN so each preset uses its own plan; :PresetCustom may set it again.
set "_PWPLAN="
rem  Reset the tally per preset; _RUNTRACK stays unset, as cleanup delete failures are benign.
set "_FAILS=0"
set "PRESET_JSON=!BACKUP_DIR!\Preset_%_pname%_%RANDOM%%RANDOM%.json"
set "PRESET_JSON_TMP=!PRESET_JSON!.tmp"
break>"!PRESET_JSON_TMP!"
if not exist "!PRESET_JSON_TMP!" (
    echo [ERROR] Could not create the preset JSON backup in "!BACKUP_DIR!".
    echo         Aborting so registry changes are NOT applied without an undo file.
    call :Log "ABORT: preset begin - JSON temp not writable"
    set "PRESET_JSON="
    set "PRESET_JSON_TMP="
    exit /b 1
)
set "PRESET_MODE=1"
call :Log "PRESET begin: %_pname%"
echo.
echo Applying preset "%_pname%" - registry changes are being captured to one JSON backup.
echo.
goto :eof

:PresetEnd
rem  Turn the captured JSONL temp into a proper JSON array, then drop the temp.
set "PRESET_MODE="
set "_LOGMSG=PRESET end -> !PRESET_JSON!" & call :LogVar _LOGMSG
set "PT_TMP=!PRESET_JSON_TMP!"
set "PT_FINAL=!PRESET_JSON!"
start "" /min /wait powershell -NoProfile -Command "$t=$env:PT_TMP;$f=$env:PT_FINAL;if(Test-Path -LiteralPath $t){$o=@(Get-Content -LiteralPath $t | Where-Object {$_ -match '\S'});Set-Content -LiteralPath $f -Value ('['+($o -join ',')+']') -Encoding ASCII}else{Set-Content -LiteralPath $f -Value '[]' -Encoding ASCII}"
set "_pendrc=%errorlevel%"
rem  The temp file is the only copy of the captured values: keep it unless conversion succeeded.
if not "%_pendrc%"=="0" goto _presetEndKeep
if not exist "!PRESET_JSON!" goto _presetEndKeep
del "!PRESET_JSON_TMP!" >nul 2>&1
set "PRESET_LAST=!PRESET_JSON!"
goto _presetEndClear

:_presetEndKeep
echo [WARN] The preset undo file could not be written. The captured values are still in:
echo          !PRESET_JSON_TMP!
echo        Keep that file if you want to undo this preset by hand.
call :Log "FAIL: preset end - JSON conversion failed, temp kept"
set /a _FAILS+=1
rem  Otherwise the "Registry backup:" line after this names the PREVIOUS preset's file.
set "PRESET_LAST="

:_presetEndClear
set "PT_TMP="
set "PT_FINAL="
set "PRESET_JSON="
set "PRESET_JSON_TMP="
goto :eof

:PresetDnsChoice
rem  Interactive DNS picker for built-in presets; shows current servers first, as none are saved.
echo.
call :ShowCurrentDns
echo  1-3 replace them on every physical adapter; only DHCP ^(Network ^> DNS ^> 4^) goes back.
echo  DNS for this preset:   1=Cloudflare   2=Google   3=Quad9   4=Skip (leave as-is, keeps them)
set "_dc="
set /p "_dc=Choose DNS [1-4]: "
if "!_dc!"=="1" goto _pdnscf
if "!_dc!"=="2" goto _pdnsgg
if "!_dc!"=="3" goto _pdnsq9
echo  Leaving DNS unchanged.
goto :eof

:_pdnscf
set "DNSSRV='1.1.1.1','1.0.0.1','2606:4700:4700::1111','2606:4700:4700::1001'"
call :ApplyDns "Cloudflare"
goto :eof

:_pdnsgg
set "DNSSRV='8.8.8.8','8.8.4.4','2001:4860:4860::8888','2001:4860:4860::8844'"
call :ApplyDns "Google"
goto :eof

:_pdnsq9
set "DNSSRV='9.9.9.9','149.112.112.112','2620:fe::fe','2620:fe::9'"
call :ApplyDns "Quad9"
goto :eof

:PresetDnsByName
rem %1 = cloudflare | google | quad9 | a literal IPv4   (used by custom presets, no prompt)
rem  Clear first: DNSSRV is global, and a leftover list would be applied instead.
set "DNSSRV="
if /i "%~1"=="cloudflare" set "DNSSRV='1.1.1.1','1.0.0.1','2606:4700:4700::1111','2606:4700:4700::1001'"
if /i "%~1"=="google"     set "DNSSRV='8.8.8.8','8.8.4.4','2001:4860:4860::8888','2001:4860:4860::8844'"
if /i "%~1"=="quad9"      set "DNSSRV='9.9.9.9','149.112.112.112','2620:fe::fe','2620:fe::9'"
rem  Anything else reaching here is a literal IPv4 that :PChkDns already validated.
if not defined DNSSRV set "DNSSRV='%~1'"
call :ApplyDns "%~1"
goto :eof
rem ---------- returnable tweak wrappers (reused by heavy + custom presets) ----------
:DoSysResp0
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "SystemResponsiveness" REG_DWORD 0 "SystemResponsiveness 0"
goto :eof

:DoNetThrottleOff
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex" REG_DWORD 0xffffffff "Network throttling off"
goto :eof

:DoWin32_42
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 42 "Win32PrioritySeparation = 42 (0x2A, short fixed quantum)"
goto :eof

:DoWin32_38
rem  0x26 = short variable quantum with a strong foreground boost, as the Programs setting writes.
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 38 "Win32PrioritySeparation = 38 (0x26, short variable quantum, foreground)"
goto :eof

:DoWin32_26
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 26 "Win32PrioritySeparation = 26 (0x1A)"
goto :eof

:DoWin32_2
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 2 "Win32PrioritySeparation default (2)"
goto :eof

:DoLargeCacheOn
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "LargeSystemCache" REG_DWORD 1 "LargeSystemCache on"
goto :eof

:DoGameModeOff
call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "AutoGameModeEnabled" REG_DWORD 0 "Game Mode off"
call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "AllowAutoGameMode" REG_DWORD 0 "Auto Game Mode off"
goto :eof

:DoGameBarOff
rem  Overlay / Game Bar chrome only - GameDVR recording is already off in :DoPerformanceCore.
call :SafeRegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" REG_DWORD 0 "Game Bar app capture off"
call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "UseNexusForGameBarEnabled" REG_DWORD 0 "Game Bar Nexus off"
call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "ShowStartupPanel" REG_DWORD 0 "Game Bar startup panel off"
goto :eof

:DoEdgeNudgesOff
rem  Documented Edge ADMX policies (HKLM\SOFTWARE\Policies\Microsoft\Edge). Edge only.
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "HubsSidebarEnabled" REG_DWORD 0 "Edge hubs sidebar off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "EdgeShoppingAssistantEnabled" REG_DWORD 0 "Edge shopping assistant off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "HideFirstRunExperience" REG_DWORD 1 "Edge first-run experience hidden"
goto :eof

:DoOneDriveSyncOff
rem  Opt-in only: this policy stops all OneDrive sync, maybe of the folder holding the undo files.
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" REG_DWORD 1 "OneDrive file sync blocked (policy)"
goto :eof

:DoIpv6Off
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" "DisabledComponents" REG_DWORD 255 "Disable IPv6 (0xFF)"
goto :eof

:DoNvmeFlags
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "1176759950" REG_DWORD 1 "NVMe flag 1"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "1853569164" REG_DWORD 1 "NVMe flag 2"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "156965516" REG_DWORD 1 "NVMe flag 3"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "735209102" REG_DWORD 1 "NVMe flag 4"
goto :eof

:DoBcdTimers
call :Run "bcdedit /deletevalue useplatformclock"
call :Run "bcdedit /set useplatformtick yes"
call :Run "bcdedit /set disabledynamictick yes"
call :Run "bcdedit /set tscsyncpolicy enhanced"
goto :eof

:DoMemCompressOff
echo   ^> Disabling memory compression and page combining (separate window)...
call :Log "EXEC-PS (isolated): Disable-MMAgent (preset)"
rem  One try per switch, as in :MemCompress - the exit code says which one failed.
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $e=0; try{ Disable-MMAgent -MemoryCompression }catch{ $e+=1 }; try{ Disable-MMAgent -PageCombining }catch{ $e+=2 }; exit $e"
set "_mmrc=%errorlevel%"
if "%_mmrc%"=="0" (
    call :Log "OK: Disable-MMAgent (preset)"
) else if "%_mmrc%"=="1" (
    echo         [FAIL] Memory compression was NOT disabled ^(page combining was^).
    call :Log "FAIL: Disable-MMAgent -MemoryCompression (preset)"
    set /a _FAILS+=1
) else if "%_mmrc%"=="2" (
    echo         [FAIL] Page combining was NOT disabled ^(memory compression was^).
    call :Log "FAIL: Disable-MMAgent -PageCombining (preset)"
    set /a _FAILS+=1
) else (
    echo         [FAIL] Memory compression / page combining was NOT disabled.
    call :Log "FAIL: Disable-MMAgent (preset)"
    set /a _FAILS+=2
)
goto :eof

:DoGpuTelemetryOff
rem  Branch on the per-vendor flags, not GPU, so a machine with both gets both.
if defined GPU_AMD call :SafeRegAdd "HKLM\SOFTWARE\AMD\CN" "UserExperienceProgram" REG_DWORD 0 "AMD User Experience Program opt-out"
if not defined GPU_NV goto :eof
call :DisableNvidiaTelemetryTasks
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" "SendTelemetryData" REG_DWORD 0 "NVIDIA telemetry off"
call :SafeRegAdd "HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client" "OptInOrOutPreference" REG_DWORD 0 "NVIDIA opt-out"
goto :eof

:DoNagleOff
for /f "tokens=*" %%K in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" 2^>nul ^| findstr /R /C:"HKEY_LOCAL_MACHINE"') do (
    call :SafeRegAdd "%%K" "TcpAckFrequency" REG_DWORD 1 "Nagle: TcpAckFrequency"
    call :SafeRegAdd "%%K" "TCPNoDelay" REG_DWORD 1 "Nagle: TCPNoDelay"
    call :SafeRegAdd "%%K" "TcpDelAckTicks" REG_DWORD 0 "Nagle: TcpDelAckTicks"
)
goto :eof

:DoOpenAsarSilent
rem  Non-interactive OpenAsar install for presets: bundled app.asar, else the latest nightly.
set "_SRC="
if exist "!SCRIPT_DIR!app.asar" set "_SRC=!SCRIPT_DIR!app.asar"
if defined _SRC goto _oasInstall
echo   ^> OpenAsar: no bundled app.asar found - downloading the latest nightly...
call :Log "PRESET OpenAsar: downloading nightly"
set "_OADL=!TEMP!\openasar_nightly_%RANDOM%%RANDOM%.asar"
set "PT_OA=!_OADL!"
start "" /min /wait powershell -NoProfile -Command "try{Invoke-WebRequest -Uri 'https://github.com/GooseMod/OpenAsar/releases/download/nightly/app.asar' -OutFile $env:PT_OA -UseBasicParsing}catch{exit 1}"
rem  Capture the exit code before del, which resets errorlevel.
set "_dlrc=%errorlevel%"
set "PT_OA="
if not "%_dlrc%"=="0" del "!_OADL!" >nul 2>&1
if not "%_dlrc%"=="0" goto _oasDlFail
if not exist "!_OADL!" goto _oasDlFail
set "_SRC=!_OADL!"
goto _oasInstall

:_oasDlFail
echo [ERROR] OpenAsar download failed - skipping. Put app.asar next to the script and retry.
call :Log "PRESET OpenAsar: download failed"
set "_OADL="
goto :eof

:_oasInstall
echo   ^> Installing OpenAsar into Discord (closing Discord first)...
set "_LOGMSG=PRESET OpenAsar install from !_SRC!" & call :LogVar _LOGMSG
taskkill /f /im Discord.exe       >nul 2>&1
taskkill /f /im DiscordPTB.exe    >nul 2>&1
taskkill /f /im DiscordCanary.exe >nul 2>&1
rem  ping, not timeout: timeout exits at once when stdin is redirected.
ping -n 3 127.0.0.1 >nul 2>&1
set "_DONE=0"
set "_OAFAIL=0"
for %%F in (Discord DiscordPTB DiscordCanary) do if exist "!LocalAppData!\%%F\" call :InstallAsarInto "%%F"
if defined _OADL if exist "!_OADL!" del /f /q "!_OADL!" >nul 2>&1
set "_OADL="
if "%_DONE%"=="0" if "%_OAFAIL%"=="0" echo [SKIP] OpenAsar: no Discord install with a resources\app.asar found.
if "%_DONE%"=="0" if not "%_OAFAIL%"=="0" echo [WARN] OpenAsar: %_OAFAIL% Discord install^(s^) were found and NONE could be updated - see the lines above.
if not "%_OAFAIL%"=="0" echo   [WARN] %_OAFAIL% Discord install^(s^) could NOT be updated - see above.
rem  Count them: unattended runs only show :Summary and the exit code.
if not "%_OAFAIL%"=="0" set /a _FAILS+=%_OAFAIL%
if exist "!LocalAppData!\Discord\Update.exe" start "" "!LocalAppData!\Discord\Update.exe" --processStart Discord.exe
goto :eof
rem =====================================================================================
rem  PRESET BODIES - what each built-in preset applies, shared by the menu and /preset: so they
rem  cannot drift. Callers own :PresetBegin, :PresetEnd, :Summary and any DNS choice.
rem =====================================================================================
:PresetBodyLight
call :DoCleanupCore
call :DoPrivacyCore
call :DoNetworkCore
goto :eof

:PresetBodyModerate
call :DoCleanupCore
call :DoPrivacyCore
call :DoPerformanceCore
call :DoPowerCore
call :DoNetworkCore
goto :eof

:PresetBodyHeavy
call :DoCleanupCore
call :DoPrivacyCore
call :DoPerformanceCore
call :DoPowerCore
call :DoNetworkCore
call :DoSysResp0
call :DoNetThrottleOff
call :DoWin32_42
call :DoGameModeOff
call :DoNagleOff
call :DoIpv6Off
call :DoNvmeFlags
call :DoGpuTelemetryOff
call :DoBcdTimers
call :DoMemCompressOff
goto :eof
rem =====================================================================================
rem  PRESET: LIGHT
rem =====================================================================================
:PresetLight
cls
call :Logo
echo ========================================  PRESET: LIGHT  =========================================
echo  Applies: temp/log cleanup, privacy ^& telemetry hardening, TCP tuning, and a DNS
echo  choice. Registry changes go into ONE JSON backup, the telemetry services into their own
echo  undo file. The TCP tuning is not saved, DNS can only go back to DHCP, and the cleanup
echo  deletes files for good.
echo ==================================================================================================
set "_c="
set /p "_c=Apply the LIGHT preset? (Y/N): "
if /i not "!_c!"=="Y" goto MenuPresets
call :PresetBegin light
if errorlevel 1 goto MenuPresets
call :PresetBodyLight
call :PresetDnsChoice
call :PresetEnd
echo.
call :Summary "LIGHT preset applied."
if defined PRESET_LAST (echo      Registry backup: !PRESET_LAST!) else (echo      Registry backup: none - it could not be written, see the [WARN] above.)
echo      Reboot recommended.
pause
goto MenuPresets
rem =====================================================================================
rem  PRESET: MODERATE  (the recommended safe set + power + OpenAsar)
rem =====================================================================================
:PresetModerate
cls
call :Logo
echo =======================================  PRESET: MODERATE  =======================================
echo  Applies the recommended safe set - cleanup, privacy, performance, power and network
echo  core tweaks - then offers to install OpenAsar. Registry changes go into ONE JSON
echo  backup. This is the same set as "Apply recommended safe set", plus OpenAsar.
echo ==================================================================================================
call :LaptopAdvisory
set "_rp=Y"
set /p "_rp=Create a System Restore Point first? (Y/N): "
if /i "!_rp!"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Apply the MODERATE preset? (Y/N): "
if /i not "!_c!"=="Y" goto MenuPresets
call :PresetBegin moderate
if errorlevel 1 goto MenuPresets
call :PresetBodyModerate
call :PresetEnd
echo.
call :Summary "MODERATE preset applied."
if defined PRESET_LAST (echo      Registry backup: !PRESET_LAST!) else (echo      Registry backup: none - it could not be written, see the [WARN] above.)
echo.
set "_oa="
set /p "_oa=Also install OpenAsar into Discord now? (Y/N): "
if /i "!_oa!"=="Y" call :DoOpenAsarSilent
echo.
echo Reboot recommended.
pause
goto MenuPresets
rem =====================================================================================
rem  PRESET: HEAVY  (aggressive; no mitigations / repair / reset / debloat)
rem =====================================================================================
:PresetHeavy
cls
call :Logo
echo ========================================  PRESET: HEAVY  =========================================
echo  Aggressive. Applies the safe set PLUS: SystemResponsiveness=0,
echo  network throttling off, Win32PrioritySeparation=42, Game Mode off, Nagle/ACK off,
echo  IPv6 off, NVMe flags, GPU telemetry off (if applicable), BCD timer tweaks and
echo  memory compression off. It does NOT touch CPU mitigations, system repair, the
echo  network-stack reset, or debloat. Registry changes go into ONE JSON backup. Outside it: BCD
echo  timers go back to defaults ^(Advanced ^> 4^), DNS only to DHCP, TCP tuning and memory
echo  compression have no in-app undo ^(Enable-MMAgent -MemoryCompression -PageCombining^),
echo  and the cleanup deletes files for good.
echo  A REBOOT is required afterwards.
echo ==================================================================================================
call :LaptopAdvisory
set "_rp=Y"
set /p "_rp=Create a System Restore Point first? (strongly recommended) (Y/N): "
if /i "!_rp!"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Apply the HEAVY preset? (Y/N): "
if /i not "!_c!"=="Y" goto MenuPresets
call :PresetBegin heavy
if errorlevel 1 goto MenuPresets
call :PresetBodyHeavy
call :PresetDnsChoice
call :PresetEnd
echo.
call :Summary "HEAVY preset applied."
if defined PRESET_LAST (echo      Registry backup: !PRESET_LAST!) else (echo      Registry backup: none - it could not be written, see the [WARN] above.)
echo      REBOOT required for the timer / IPv6 / memory-compression changes to take hold.
echo.
echo  Tip: to also enable a higher timer resolution, use  Apps ^& files ^> Apply timer
echo       resolution  (it needs the bundled SetTimerResolution.exe).
pause
goto MenuPresets
rem =====================================================================================
rem  PRESET: CUSTOM  (load a key=value file from sincript_presets\)
rem =====================================================================================
:PresetCustom
cls
call :Logo
echo ========================================  CUSTOM PRESET  =========================================
set "_pdir=!SCRIPT_DIR!sincript_presets"
if not exist "!_pdir!\" (
    echo  No "sincript_presets" folder was found next to the script.
    echo  Create it and add a text file named e.g.  mypreset.preset  with lines like:
    echo      cleanup=1
    echo      privacy=1
    echo      dns=cloudflare
    echo  See the Sincript README, section Custom presets, for the full list of keys.
    echo.
    pause
    goto MenuPresets
)
set "_pn=0"
rem  Store names only; the full path is rebuilt late from _pdir when one is picked.
for %%F in ("!_pdir!\*.preset") do (
    set /a _pn+=1
    set "_pnm[!_pn!]=%%~nxF"
)
if "%_pn%"=="0" (
    echo  The "sincript_presets" folder has no *.preset files yet.
    echo  Add a text file named e.g.  mypreset.preset  - see the README for the key list.
    echo.
    pause
    goto MenuPresets
)
echo  Available preset files in sincript_presets\:
for /l %%I in (1,1,%_pn%) do echo     %%I.  !_pnm[%%I]!
echo     0.  Back
echo ==================================================================================================

:PresetCustom_ask
set "sel="
set /p "sel=Choose a preset file: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto PresetCustom_ask
if "!sel!"=="0" goto MenuPresets
set "_pfile="
for /l %%I in (1,1,%_pn%) do if "!sel!"=="%%I" set "_pfile=!_pdir!\!_pnm[%%I]!"
if not defined _pfile goto PresetCustom_ask
set "_pshow="
for /l %%I in (1,1,%_pn%) do if "!sel!"=="%%I" set "_pshow=!_pnm[%%I]!"
set "_pbase="
for %%F in ("!_pfile!") do set "_pbase=%%~nF"
set "_pbase=%_pbase: =_%"
rem ---- validate: read each key=value once, record valid directives, collect problems ----
set "_perr=0"
set "_pgood=0"
set "_perrfile=!TEMP!\sincript_preset_err_%RANDOM%.txt"
break>"!_perrfile!"
rem  Clear every directive global, or it leaks into the next preset. Sync with :PresetCheckLine.
for %%K in (CLEANUP PRIVACY PERFORMANCE POWER PWTIMEOUTS PWPLAN NETWORK OPENASAR GAMEMODE GAMEBAR EDGE ONEDRIVE SYSRESP NETTHROTTLE LARGECACHE MINPROC BCDTIMERS IPV6 MEMCOMPRESS NVME GPUTEL NAGLE WIN32 DNS) do set "_P_%%K="
rem  Assign from FOR variables, not call arguments, so quotes or parens in the file stay data.
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("!_pfile!") do (
    set "_k=%%A"
    set "_v=%%B"
    call :PresetCheckLine
)
cls
call :Logo
echo ========================================  CUSTOM PRESET  =========================================
rem  Late-expanded: an ampersand is legal in a file name.
echo  Preset file:            !_pshow!
echo  Recognized directives:  %_pgood%
echo  Problems:               %_perr%
if %_perr% gtr 0 (
    echo --------------------------------------------------------------------------------------------------
    type "!_perrfile!"
)
del "!_perrfile!" >nul 2>&1
echo ==================================================================================================
if %_pgood% geq 1 goto _pcHaveValid
echo [ABORT] No valid directives found - nothing to apply.
echo         Check the file against the key list in the README.
pause
goto MenuPresets

:_pcHaveValid
if %_perr% lss 1 goto _pcReady
set "_cc="
set /p "_cc=Apply the valid directives and skip the problems? (Y/N): "
if /i not "!_cc!"=="Y" goto MenuPresets

:_pcReady
set "_rp=Y"
set /p "_rp=Create a System Restore Point first? (Y/N): "
if /i "!_rp!"=="Y" call :CreateRestorePoint
rem  Quoted and late-expanded: the file name may hold an ampersand.
call :PresetBegin "custom_!_pbase!"
if errorlevel 1 goto MenuPresets
call :PresetApplyDirectives
call :PresetEnd
echo.
call :Summary "Custom preset applied."
if defined PRESET_LAST (echo      Registry backup: !PRESET_LAST!) else (echo      Registry backup: none - it could not be written, see the [WARN] above.)
echo      Reboot recommended.
pause
goto MenuPresets

:PresetApplyDirectives
rem  Applies the recorded _P_* directives, shared with /preset:. Caller owns begin, end, summary.
if defined _P_CLEANUP     call :DoCleanupCore
if defined _P_PRIVACY     call :DoPrivacyCore
if defined _P_PERFORMANCE call :DoPerformanceCore
rem  power_plan only picks which plan; set it before the cores so :DoPowerPlanSwitch sees it.
if defined _P_PWPLAN      set "_PWPLAN=%_P_PWPLAN%"
if defined _P_POWER       call :DoPowerCore
rem  power=1 already includes the timeouts, so the standalone key is skipped then.
if not defined _P_POWER if defined _P_PWTIMEOUTS call :DoPowerTimeouts
if defined _P_NETWORK     call :DoNetworkCore
if defined _P_SYSRESP     call :DoSysResp0
if defined _P_NETTHROTTLE call :DoNetThrottleOff
if defined _P_LARGECACHE  call :DoLargeCacheOn
if defined _P_GAMEMODE    call :DoGameModeOff
if defined _P_GAMEBAR     call :DoGameBarOff
if defined _P_EDGE        call :DoEdgeNudgesOff
if defined _P_ONEDRIVE    call :DoOneDriveSyncOff
if "%_P_WIN32%"=="42"     call :DoWin32_42
if "%_P_WIN32%"=="38"     call :DoWin32_38
if "%_P_WIN32%"=="26"     call :DoWin32_26
if "%_P_WIN32%"=="2"      call :DoWin32_2
if defined _P_MINPROC     call :SetMinProcState
if defined _P_NAGLE       call :DoNagleOff
if defined _P_IPV6        call :DoIpv6Off
if defined _P_NVME        call :DoNvmeFlags
if defined _P_GPUTEL      call :DoGpuTelemetryOff
if defined _P_BCDTIMERS   call :DoBcdTimers
if defined _P_MEMCOMPRESS call :DoMemCompressOff
if defined _P_OPENASAR    call :DoOpenAsarSilent
if defined _P_DNS         call :PresetDnsByName "%_P_DNS%"
goto :eof

:PresetCheckLine
rem  Takes no arguments: reads _k and _v late, so the user's text never meets parse-time expansion.
if not defined _k goto :eof
if "!_k:~0,1!"==";" goto :eof
if defined _v if "!_v:~-1!"==" " set "_v=!_v:~0,-1!"
set "_match="
if /i "!_k!"=="cleanup"               ( set "_match=1" & call :PVok CLEANUP 1 )
if /i "!_k!"=="privacy"               ( set "_match=1" & call :PVok PRIVACY 1 )
if /i "!_k!"=="performance"           ( set "_match=1" & call :PVok PERFORMANCE 1 )
if /i "!_k!"=="power"                 ( set "_match=1" & call :PVok POWER 1 )
if /i "!_k!"=="power_timeouts"        ( set "_match=1" & call :PVok PWTIMEOUTS 1 )
if /i "!_k!"=="network"               ( set "_match=1" & call :PVok NETWORK 1 )
if /i "!_k!"=="openasar"              ( set "_match=1" & call :PVok OPENASAR 1 )
if /i "!_k!"=="gamemode_off"          ( set "_match=1" & call :PVok GAMEMODE 1 )
if /i "!_k!"=="gamebar_off"           ( set "_match=1" & call :PVok GAMEBAR 1 )
if /i "!_k!"=="edge_nudges_off"       ( set "_match=1" & call :PVok EDGE 1 )
if /i "!_k!"=="onedrive_off"          ( set "_match=1" & call :PVok ONEDRIVE 1 )
if /i "!_k!"=="systemresponsiveness"  ( set "_match=1" & call :PVok SYSRESP 0 )
if /i "!_k!"=="networkthrottling_off" ( set "_match=1" & call :PVok NETTHROTTLE 1 )
if /i "!_k!"=="largesystemcache"      ( set "_match=1" & call :PVok LARGECACHE 1 )
if /i "!_k!"=="minprocstate5"         ( set "_match=1" & call :PVok MINPROC 1 )
if /i "!_k!"=="bcdtimers"             ( set "_match=1" & call :PVok BCDTIMERS 1 )
if /i "!_k!"=="ipv6_off"              ( set "_match=1" & call :PVok IPV6 1 )
if /i "!_k!"=="memcompress_off"       ( set "_match=1" & call :PVok MEMCOMPRESS 1 )
if /i "!_k!"=="nvme_flags"            ( set "_match=1" & call :PVok NVME 1 )
if /i "!_k!"=="gpu_telemetry_off"     ( set "_match=1" & call :PVok GPUTEL 1 )
if /i "!_k!"=="nagle_off"             ( set "_match=1" & call :PVok NAGLE 1 )
if /i "!_k!"=="win32priority"         ( set "_match=1" & call :PChkWin32 )
if /i "!_k!"=="dns"                   ( set "_match=1" & call :PChkDns )
if /i "!_k!"=="power_plan"            ( set "_match=1" & call :PChkPlan )
if defined _match goto :eof
>>"!_perrfile!" echo   ignored - unknown key: !_k!
set /a _perr+=1
goto :eof

:PVok
rem %1 = directive var name   %2 = expected value (1 or 0). Reads !_k! / !_v! from the caller.
rem Flat, not if/else: the user's value must never sit inside a parenthesised block.
if "!_v!"=="%~2" goto _pvOk
>>"!_perrfile!" echo   bad value "!_v!" for key !_k! ^(expected %~2^)
set /a _perr+=1
goto :eof

:_pvOk
set "_P_%~1=1"
set /a _pgood+=1
goto :eof

:PChkWin32
if "!_v!"=="42" ( set "_P_WIN32=42" & set /a _pgood+=1 & goto :eof )
if "!_v!"=="38" ( set "_P_WIN32=38" & set /a _pgood+=1 & goto :eof )
if "!_v!"=="26" ( set "_P_WIN32=26" & set /a _pgood+=1 & goto :eof )
if "!_v!"=="2"  ( set "_P_WIN32=2"  & set /a _pgood+=1 & goto :eof )
>>"!_perrfile!" echo   bad value "!_v!" for key win32priority (use 42, 38, 26 or 2)
set /a _perr+=1
goto :eof

:PChkPlan
rem  Explicit plan for custom presets; without it power=1 means Ultimate, a poor fit on laptops.
if /i "!_v!"=="ultimate" ( set "_P_PWPLAN=ultimate" & set /a _pgood+=1 & goto :eof )
if /i "!_v!"=="high"     ( set "_P_PWPLAN=high"     & set /a _pgood+=1 & goto :eof )
if /i "!_v!"=="balanced" ( set "_P_PWPLAN=balanced" & set /a _pgood+=1 & goto :eof )
>>"!_perrfile!" echo   bad value "!_v!" for key power_plan (use ultimate, high or balanced)
set /a _perr+=1
goto :eof

:PChkDns
if /i "!_v!"=="cloudflare" ( set "_P_DNS=cloudflare" & set /a _pgood+=1 & goto :eof )
if /i "!_v!"=="google"     ( set "_P_DNS=google"     & set /a _pgood+=1 & goto :eof )
if /i "!_v!"=="quad9"      ( set "_P_DNS=quad9"      & set /a _pgood+=1 & goto :eof )
rem  Also accept a literal IPv4, checked by the same validator as the interactive DNS screen.
set "_IPCHK=!_v!"
call :_ip4_ok && ( set "_P_DNS=!_v!" & set /a _pgood+=1 & goto :eof )
>>"!_perrfile!" echo   bad value "!_v!" for key dns (use cloudflare, google, quad9 or an IPv4 address)
set /a _perr+=1
goto :eof
rem =====================================================================================
rem  RESTORE from a preset JSON backup (registry values only)
rem =====================================================================================
:RestorePresetJson
cls
call :Logo
echo =============================  Restore from a preset backup (JSON)  ==============================
echo  Restores the registry values a preset changed, from one of its JSON backups.
echo  Not in the JSON, each with its own way back: power plan and telemetry services -
echo  Backups ^& status; DNS - Network ^> DNS ^> 4 ^(DHCP, not your old servers^); BCD timers -
echo  Advanced ^> 4 ^(Windows defaults^); OpenAsar - its .bak. TCP tuning and memory compression
echo  have no in-app undo, and the cleanup deletes files for good.
echo ==================================================================================================
set "_rn=0"
for /f "delims=" %%F in ('dir /b /o-d "!BACKUP_DIR!\Preset_*.json" 2^>nul') do (
    set /a _rn+=1
    set "_rf[!_rn!]=!BACKUP_DIR!\%%F"
    set "_rnm[!_rn!]=%%F"
)
if "%_rn%"=="0" (
    echo  No preset JSON backups were found in:
    echo     !BACKUP_DIR!
    echo.
    pause
    goto MenuBackups
)
echo  Preset backups (newest first):
for /l %%I in (1,1,%_rn%) do echo     %%I.  !_rnm[%%I]!
echo     0.  Back
echo ==================================================================================================

:RestorePresetJson_ask
set "sel="
set /p "sel=Choose a backup to restore: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto RestorePresetJson_ask
if "!sel!"=="0" goto MenuBackups
set "_rfile="
for /l %%I in (1,1,%_rn%) do if "!sel!"=="%%I" set "_rfile=!_rf[%%I]!"
if not defined _rfile goto RestorePresetJson_ask
echo.
echo  About to restore registry values from:
echo     !_rfile!
set "_cc="
set /p "_cc=Proceed with the restore? (Y/N): "
if /i not "!_cc!"=="Y" goto MenuBackups
set "_LOGMSG=PRESET restore from !_rfile!" & call :LogVar _LOGMSG
set "PT_FILE=!_rfile!"
set "_prres=!TEMP!\pt_prres_%RANDOM%.txt"
del "!_prres!" >nul 2>&1
set "PT_PRRES=!_prres!"
rem  The child writes ok, fail and badjson counts; an already-absent value counts as restored.
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue';$p=$env:PT_FILE;$ok=0;$fail=0;try{$items=Get-Content -Raw -LiteralPath $p | ConvertFrom-Json}catch{'0 0 1'|Out-File -FilePath $env:PT_PRRES -Encoding ASCII;exit 2};foreach($it in $items){ if(-not $it.present){ reg delete $it.key /v $it.name /f 2>$null | Out-Null; if($LASTEXITCODE -eq 0){$ok++}else{ reg query $it.key /v $it.name 2>$null | Out-Null; if($LASTEXITCODE -ne 0){$ok++}else{$fail++} } } elseif($it.oldtype -eq 'REG_DWORD'){ reg add $it.key /v $it.name /t REG_DWORD /d $it.olddata /f 2>$null | Out-Null; if($LASTEXITCODE -eq 0){$ok++}else{$fail++} } elseif($it.oldtype -eq 'REG_SZ' -and $it.restorable -ne $false){ $rk=$it.key -replace '^HKLM\\','HKLM:\' -replace '^HKCU\\','HKCU:\' -replace '^HKCR\\','Registry::HKEY_CLASSES_ROOT\' -replace '^HKU\\','Registry::HKEY_USERS\' -replace '^HKCC\\','Registry::HKEY_CURRENT_CONFIG\'; try{ if(-not (Test-Path -LiteralPath $rk)){New-Item -Path $rk -Force -ErrorAction Stop|Out-Null}; Set-ItemProperty -LiteralPath $rk -Name $it.name -Value ([string]$it.olddata) -Type String -ErrorAction Stop; $ok++ }catch{$fail++} } }; (''+$ok+' '+$fail+' 0')|Out-File -FilePath $env:PT_PRRES -Encoding ASCII; if($fail -gt 0){exit 1}else{exit 0}"
set "_prrc=%errorlevel%"
set "PT_FILE=" & set "PT_PRRES="
set "_okN=0" & set "_failN=0" & set "_badjson=0"
if exist "!_prres!" for /f "usebackq tokens=1,2,3" %%a in ("!_prres!") do ( set "_okN=%%a" & set "_failN=%%b" & set "_badjson=%%c" )
del "!_prres!" >nul 2>&1
echo.
if "!_badjson!"=="1" (
    echo [ERROR] That backup file could not be read as valid JSON. Nothing was changed.
    set "_LOGMSG=FAIL: preset restore - bad JSON !_rfile!" & call :LogVar _LOGMSG
) else if "!_prrc!"=="0" (
    echo [OK] Restore finished: !_okN! value^(s^) put back, 0 failed. A reboot is recommended.
    call :Log "OK: preset restore ok=!_okN! fail=!_failN!"
) else (
    echo [WARN] Restore incomplete: !_okN! restored, !_failN! FAILED ^(not elevated, or a protected key^).
    echo        Re-run elevated if HKLM values did not restore. Details are in the log.
    call :Log "FAIL: preset restore ok=!_okN! fail=!_failN!"
)
echo      Not restored here: power plan, telemetry services, DNS, BCD timers, TCP, memory compression.
pause
goto MenuBackups
rem =====================================================================================
rem  RESTORE a single per-value .reg backup (re-import one of the tiny tweak backups)
rem =====================================================================================
:RestoreRegBackup
cls
call :Logo
echo =============================  Restore a single value backup (.reg)  =============================
echo  Re-imports one of the small per-value .reg backups this script writes before each
echo  registry tweak - the same files you can also double-click in the backup folder.
echo  Full-registry exports (FullReg_*.reg) are not listed here; import those manually.
echo ==================================================================================================
set "_qn=0"
for /f "delims=" %%F in ('dir /b /a-d /o-d "!BACKUP_DIR!\*.reg" 2^>nul ^| findstr /I /V /B "FullReg_"') do (
    set /a _qn+=1
    set "_qf[!_qn!]=!BACKUP_DIR!\%%F"
    set "_qnm[!_qn!]=%%F"
)
if "%_qn%"=="0" (
    echo  No per-value .reg backups were found in:
    echo     !BACKUP_DIR!
    echo.
    pause
    goto MenuBackups
)
echo  Value backups (newest first):
for /l %%I in (1,1,%_qn%) do echo     %%I.  !_qnm[%%I]!
echo     0.  Back
echo ==================================================================================================

:RestoreRegBackup_ask
set "sel="
set /p "sel=Choose a backup to restore: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto RestoreRegBackup_ask
if "!sel!"=="0" goto MenuBackups
set "_qfile="
set "_qshow="
for /l %%I in (1,1,%_qn%) do if "!sel!"=="%%I" set "_qfile=!_qf[%%I]!"
for /l %%I in (1,1,%_qn%) do if "!sel!"=="%%I" set "_qshow=!_qnm[%%I]!"
if not defined _qfile goto RestoreRegBackup_ask
echo.
echo  This backup will put the following value(s) back to their saved state:
echo --------------------------------------------------------------------------------------------------
type "!_qfile!"
echo --------------------------------------------------------------------------------------------------
echo  A line like  "Name"=-  means the value did not exist before and will be removed.
set "_cc="
set /p "_cc=Import this .reg backup now? (Y/N): "
if /i not "!_cc!"=="Y" goto MenuBackups
echo   ^> Importing "%_qshow%"...
call :Log "REG restore (import) from %_qshow%"
reg import "!_qfile!" >nul 2>&1
if errorlevel 1 (
    echo [WARN] Import reported an error - check the log for details.
    call :Log "  FAIL reg import %_qshow%"
) else (
    echo [OK] Backup imported. A sign out/in or reboot may be needed for some values.
    call :Log "  OK reg import %_qshow%"
)
pause
goto MenuBackups
rem =====================================================================================
rem  MANAGE / open the backup folder (summary, open in Explorer, prune old full exports)
rem =====================================================================================
:RestorePowerBackup
cls
call :Logo
echo ==============================  Revert power settings (undo file)  ===============================
echo  Runs one of the PowerPlan_*.bat undo files sincript writes before it changes your
echo  power scheme or its sleep / disk timeouts. Each one re-activates the scheme that
echo  was current at the time and puts that scheme's timeouts back, in seconds.
echo  The minimum processor state is in that file too, and so is hibernation if it was turned
echo  off on the Power screen - unless the file says it could not read it or that its earlier
echo  state is unknown, or was written before this version: then turn it back on with
echo  powercfg /hibernate on  ^(elevated^).
echo  CPU power throttling is NOT in it: Backups ^& status ^> Restore a single value backup
echo  ^(the ...Control_Power_PowerThrottling_*.reg file^).
echo ==================================================================================================
set "_pn=0"
for /f "delims=" %%F in ('dir /b /a-d /o-d "!BACKUP_DIR!\PowerPlan_*.bat" 2^>nul') do (
    set /a _pn+=1
    set "_pf[!_pn!]=!BACKUP_DIR!\%%F"
    set "_pnm[!_pn!]=%%F"
)
if "%_pn%"=="0" (
    echo  No power-settings backups were found in:
    echo     !BACKUP_DIR!
    echo.
    echo  One is written automatically the next time you use the Power plan menu.
    pause
    goto MenuBackups
)
echo  Power backups (newest first):
for /l %%I in (1,1,%_pn%) do echo     %%I.  !_pnm[%%I]!
echo     0.  Back
echo ==================================================================================================

:RestorePowerBackup_ask
set "sel="
set /p "sel=Choose a backup to run: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto RestorePowerBackup_ask
if "!sel!"=="0" goto MenuBackups
set "_pfile="
for /l %%I in (1,1,%_pn%) do if "!sel!"=="%%I" set "_pfile=!_pf[%%I]!"
if not defined _pfile goto RestorePowerBackup_ask
echo.
echo  About to run:
echo     !_pfile!
set "_cc="
set /p "_cc=Proceed? (Y/N): "
if /i not "!_cc!"=="Y" goto MenuBackups
rem  Leave _RUNTRACK clear: nothing here goes through :Run, and only :Summary would clear it.
set "_FAILS=0" & set "_RUNTRACK="
set "_LOGMSG=POWER revert from !_pfile!" & call :LogVar _LOGMSG
rem  Child cmd, not call, so a syntax error in the file cannot end sincript; /q skips its pause.
rem  /v:off: the file is written for plain expansion, not delayed.
cmd /d /v:off /s /c ""!_pfile!" /q"
if errorlevel 1 (
    echo [WARN] The undo file reported a failure. Run it elevated, or open Control Panel ^>
    echo        Power Options and set the plan back by hand.
    set "_LOGMSG=FAIL: power revert !_pfile!" & call :LogVar _LOGMSG
) else (
    echo [OK] Power settings restored from the backup.
    set "_LOGMSG=OK: power revert !_pfile!" & call :LogVar _LOGMSG
)
echo.
echo  Current plan now:
for /f "tokens=*" %%i in ('powercfg /getactivescheme') do echo    %%i
pause
goto MenuBackups
rem =====================================================================================
rem  ACTION: revert telemetry services + scheduled tasks (undo file)
rem =====================================================================================
:RestoreTelemetryBackup
cls
call :Logo
echo ========================  Revert telemetry services ^& tasks (undo file)  =========================
echo  Runs one of the Telemetry_*.bat undo files sincript writes before Privacy disables the
echo  telemetry services and scheduled tasks, or GPU telemetry disables NVIDIA's (those files are
echo  named Telemetry_nvidia_*). Each one restores the service start types that were in place,
echo  starts a service again if it was running, and re-enables the tasks that were enabled -
echo  leaving alone anything you had already disabled yourself.
echo  Registry policy values are NOT in this file: those have their own .reg backups, under
echo  "Restore a single value backup" above.
echo ==================================================================================================
set "_tn=0"
for /f "delims=" %%F in ('dir /b /a-d /o-d "!BACKUP_DIR!\Telemetry_*.bat" 2^>nul') do (
    set /a _tn+=1
    set "_tf[!_tn!]=!BACKUP_DIR!\%%F"
    set "_tnm[!_tn!]=%%F"
)
if "%_tn%"=="0" (
    echo  No telemetry backups were found in:
    echo     !BACKUP_DIR!
    echo.
    echo  One is written automatically the next time you run Privacy ^& telemetry.
    pause
    goto MenuBackups
)
echo  Telemetry backups ^(newest first^):
for /l %%I in (1,1,%_tn%) do echo     %%I.  !_tnm[%%I]!
echo     0.  Back
echo ==================================================================================================

:RestoreTelemetryBackup_ask
set "sel="
set /p "sel=Choose a backup to run: "
if not defined sel call :NoInput || goto ExitScript
if not defined sel goto RestoreTelemetryBackup_ask
if "!sel!"=="0" goto MenuBackups
set "_tfile="
for /l %%I in (1,1,%_tn%) do if "!sel!"=="%%I" set "_tfile=!_tf[%%I]!"
if not defined _tfile goto RestoreTelemetryBackup_ask
echo.
echo  About to run:
echo     !_tfile!
set "_cc="
set /p "_cc=Proceed? (Y/N): "
if /i not "!_cc!"=="Y" goto MenuBackups
rem  Leave _RUNTRACK clear: nothing here goes through :Run, and only :Summary would clear it.
set "_FAILS=0" & set "_RUNTRACK="
set "_LOGMSG=TELEMETRY revert from !_tfile!" & call :LogVar _LOGMSG
rem  Child cmd, not call, so a syntax error in the file cannot end sincript; /q skips its pause.
rem  /v:off: the file is written for plain expansion, not delayed.
cmd /d /v:off /s /c ""!_tfile!" /q"
if errorlevel 1 (
    echo [WARN] The undo file reported a failure. Re-run it from an elevated prompt, or put the
    echo        services back in services.msc and the tasks back in Task Scheduler.
    set "_LOGMSG=FAIL: telemetry revert !_tfile!" & call :LogVar _LOGMSG
) else (
    echo [OK] Telemetry services and tasks restored from the backup.
    set "_LOGMSG=OK: telemetry revert !_tfile!" & call :LogVar _LOGMSG
)
echo.
pause
goto MenuBackups

:ManageBackups
cls
call :Logo
echo =====================================  Manage backup folder  =====================================
echo  Everything this script backs up lives in one folder. The small per-value .reg files
echo  and preset .json files are the precise undo data and are left untouched here; only
echo  the large full-registry exports - which pile up each time you run a full registry
echo  backup - can be pruned, and even then the newest pair is always kept.
echo ==================================================================================================
set "_cntAllReg=0"
for %%Z in ("!BACKUP_DIR!\*.reg") do set /a _cntAllReg+=1
set "_cntFull=0" & set "_kbFull=0"
for %%Z in ("!BACKUP_DIR!\FullReg_*.reg") do call :_mbAddFull "%%~zZ"
rem  Convert once, keeping a tenth of a MB, so small totals do not read as 0 MB.
set /a _mbW=_kbFull/1024
set /a _mbF=(_kbFull*10/1024)%%10
set "_mbFull=!_mbW!.!_mbF!"
set /a _cntVal=_cntAllReg-_cntFull
if !_cntVal! lss 0 set "_cntVal=0"
set "_cntJson=0"
for %%Z in ("!BACKUP_DIR!\Preset_*.json") do set /a _cntJson+=1
set "_cntHosts=0"
for %%Z in ("!BACKUP_DIR!\hosts_*.bak") do set /a _cntHosts+=1
set "_cntLog=0"
for %%Z in ("!BACKUP_DIR!\PerfTweaks_*.log") do set /a _cntLog+=1
set "_cntCrash=0"
for %%Z in ("!BACKUP_DIR!\CrashReport_*.txt") do set /a _cntCrash+=1
echo  Folder:  !BACKUP_DIR!
if exist "!LOGFILE!" (echo  Log now: !LOGFILE!) else (echo  Log now: none - no log file could be written this session)
echo --------------------------------------------------------------------------------------------------
echo   Per-value .reg backups ^(single-value undo^) : !_cntVal!
echo   Full registry exports  ^(HKLM/HKCU^)         : !_cntFull!   ^(~!_mbFull! MB^)
echo   Preset backups ^(.json^)                     : !_cntJson!
echo   hosts backups  ^(.bak^)                      : !_cntHosts!
echo   Logs ^(.log^)                                : !_cntLog!
echo   Crash reports ^(.txt^)                       : !_cntCrash!
echo ==================================================================================================
set "_c="
set /p "_c=Open this folder in Explorer now? (Y/N): "
if /i "!_c!"=="Y" start "" "!BACKUP_DIR!"
if !_cntFull! leq 2 goto _mbDone
echo.
echo  You have !_cntFull! full registry exports ^(~!_mbFull! MB^). Pruning keeps only the newest
echo  of each hive. An older one may be the only copy of values from before later changes -
echo  keep it if you may want those back.
set "_c2="
set /p "_c2=Delete the older full exports, keeping the newest of each hive? (Y/N): "
if /i not "!_c2!"=="Y" goto _mbDone
set "_keepL=0" & set "_keepU=0" & set "_keepO=0" & set "_delN=0" & set "_delFail=0"
for /f "delims=" %%F in ('dir /b /a-d /o-d "!BACKUP_DIR!\FullReg_*.reg" 2^>nul') do call :_mbPrune "%%F"
call :Log "MANAGE pruned !_delN! old full registry exports, !_delFail! could not be deleted"
if "!_delFail!"=="0" echo  [OK] Deleted !_delN! older full export^(s^); kept the newest HKLM and HKCU export.
if not "!_delFail!"=="0" echo  [WARN] Deleted !_delN! older full export^(s^), but !_delFail! could not be deleted - in use or read-only.

:_mbDone
echo.
pause
goto MenuBackups

:_mbAddFull
rem  %1 = file size in bytes of one full export; updates the running count + KB total.
rem  Sums KB: bytes overflow set /a and per-file MB drops small files.
rem  Size goes via a variable: set /a caps an oversized variable but errors on a literal.
set /a _cntFull+=1
set "_fsz=%~1"
if not defined _fsz set "_fsz=0"
set /a _kbFull+=_fsz/1024
goto :eof

:_mbPrune
rem  %1 = bare filename, caller feeds them newest-first.
rem  Keep the newest per hive. Flat gotos: a closing paren in the name would end a block early.
set "_prN=%~1"
if /i not "!_prN:FullReg_HKLM_=!"=="!_prN!" goto _mbPruneHKLM
if /i not "!_prN:FullReg_HKCU_=!"=="!_prN!" goto _mbPruneHKCU
if !_keepO! geq 2 goto _mbPruneDel
set /a _keepO+=1
goto :eof

:_mbPruneHKLM
if !_keepL! geq 1 goto _mbPruneDel
set /a _keepL+=1
goto :eof

:_mbPruneHKCU
if !_keepU! geq 1 goto _mbPruneDel
set /a _keepU+=1
goto :eof

:_mbPruneDel
del /f /q "!BACKUP_DIR!\!_prN!" >nul 2>&1
rem  Count a file as deleted only if it is gone; del sets no useful exit code here.
if not exist "!BACKUP_DIR!\!_prN!" set /a _delN+=1
if exist "!BACKUP_DIR!\!_prN!" set /a _delFail+=1
goto :eof
rem =====================================================================================
rem  JSON value backup (called by SafeRegAdd when a preset is being applied)
rem =====================================================================================
:BackupValueJson
rem  Appends ONE JSON object (the value's prior state) to !PRESET_JSON_TMP!.
rem  Runs inside SafeRegAdd's setlocal, so !_key! !_val! !_ln! are in scope.
set "_jk=!_key:\=\\!"
set "_jv=!_val:\=\\!"
if not defined _ln goto _bvjAbsent
set "_td=REG_!_ln:*REG_=!"
set "_rd="
for /f "tokens=1,*" %%a in ("!_td!") do ( set "_rt=%%a" & set "_rd=%%b" )
set "_naData="
if defined _rd call :NonAsciiCheck
if /i "!_rt!"=="REG_DWORD" goto _bvjDword
if /i "!_rt!"=="REG_SZ" goto _bvjSz
>>"!PRESET_JSON_TMP!" echo {"key":"!_jk!","name":"!_jv!","present":true,"oldtype":"!_rt!","restorable":false}
goto :eof

:_bvjAbsent
>>"!PRESET_JSON_TMP!" echo {"key":"!_jk!","name":"!_jv!","present":false}
goto :eof

:_bvjDword
>>"!PRESET_JSON_TMP!" echo {"key":"!_jk!","name":"!_jv!","present":true,"oldtype":"REG_DWORD","olddata":"!_rd!"}
goto :eof

:_bvjSz
rem  Escape for JSON: backslash first, then quote. Guard on defined _rd: an empty REG_SZ leaves
rem  _rd undefined, and substitution would write the pattern itself, breaking the JSON.
if defined _naData (
    >>"!PRESET_JSON_TMP!" echo {"key":"!_jk!","name":"!_jv!","present":true,"oldtype":"REG_SZ","restorable":false}
    goto :eof
)
set "_sz="
if defined _rd set "_sz=!_rd:\=\\!"
if defined _rd set "_sz=!_sz:"=\"!"
>>"!PRESET_JSON_TMP!" echo {"key":"!_jk!","name":"!_jv!","present":true,"oldtype":"REG_SZ","olddata":"!_sz!"}
goto :eof

