@echo off
echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0" 2>nul
mode con: cols=100 lines=36 >nul 2>&1
color 0D
title Sincript - Windows 10/11 Optimizer
rem =====================================================================================
rem  PerfTweaks - a curated, reversible Windows 10/11 optimizer with a category menu.
rem  Every registry change is backed up first (.reg in %BACKUP_DIR%). "Backups & status"
rem  makes a System Restore Point and a full registry export - do that first.
rem  Read "What was excluded" in the main menu for the safety rationale.
rem =====================================================================================
rem ---------- Self-elevate to Administrator (robust, cannot loop) ----------
rem  net session needs the 'Server' service (often disabled by debloat scripts), so fall
rem  back to fltmc, then to reg-querying the LocalService hive (needs no service at all).
rem  The one-shot /elevated marker guarantees we relaunch at most once - no infinite loop.
set "_ELEV="
net session >nul 2>&1 || fltmc >nul 2>&1 || reg query "HKU\S-1-5-19" >nul 2>&1
if not errorlevel 1 ( set "_ELEV=1" & goto AdminOK )
if /i "%~1"=="/elevated" goto AdminWarn
echo Requesting Administrator privileges...
set "PT_SELF=%~f0"
powershell -NoProfile -Command "Start-Process -FilePath $env:PT_SELF -ArgumentList '/elevated' -Verb RunAs -WorkingDirectory (Split-Path -Parent $env:PT_SELF)" >nul 2>&1
exit /b

:AdminWarn
rem  Reached only when a relaunch already happened but we are STILL not elevated (UAC declined,
rem  or all three admin probes are unavailable). Don't pretend HKLM writes will work: make the
rem  limited state explicit, set _ELEV=0 so :Summary / actions report honestly, and let the user
rem  opt in instead of silently continuing.
set "_ELEV=0"
echo.
echo [WARN] Not running as Administrator. HKLM / service / boot / hosts changes WILL fail;
echo        only per-user (HKCU) tweaks and the read-only status screens can work in this mode.
echo        For the full toolset, close this window and use "Run as administrator".
echo.
set "_lc="
set /p "_lc=Continue anyway in limited (per-user only) mode? (Y/N): "
if /i not "%_lc%"=="Y" exit /b

:AdminOK
if not defined _ELEV set "_ELEV=1"
cd /d "%~dp0" 2>nul
rem ---------- Globals ----------
set "SCRIPT_DIR=%~dp0"
rem  Running tally of registry writes that FAILED since the last reset. :SafeRegAdd /
rem  :SafeRegDelete bump it across their endlocal; :Summary reads it so an action's final
rem  line reports the REAL outcome instead of an unconditional [OK].
set "_FAILS=0"
rem  Put backups under the user's Documents folder (resolves OneDrive-redirected Documents);
rem  falls back to the profile default if the registry lookup fails.
set "DOCS=%USERPROFILE%\Documents"
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Personal 2^>nul ^| findstr /I "Personal"') do set "DOCS=%%b"
call set "DOCS=%DOCS%"
if "!DOCS:~-1!"==" " set "DOCS=!DOCS:~0,-1!"
set "BACKUP_DIR=%DOCS%\PerfTweaks_Backups"
set "LOGFILE=%BACKUP_DIR%\PerfTweaks_%RANDOM%.log"
if not exist "%BACKUP_DIR%" md "%BACKUP_DIR%" >nul 2>&1
rem ---------- OS build / Win11 / GPU detection ----------
set "WIN_BUILD="
for /f "tokens=3" %%B in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| findstr /I "CurrentBuildNumber"') do set "WIN_BUILD=%%B"
set "IS_WIN11=0"
if defined WIN_BUILD if !WIN_BUILD! GEQ 22000 set "IS_WIN11=1"
set "GPU=unknown"
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" /s /v DriverDesc 2>nul | findstr /I "nvidia" >nul && set "GPU=nvidia"
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" /s /v DriverDesc 2>nul | findstr /I "radeon" >nul && set "GPU=amd"
rem ---------- Machine class (laptop / desktop / unknown) ----------
rem  CmBatt is the ACPI control-method battery driver: its Enum\Count is nonzero exactly
rem  when an internal battery is present, separating laptops from desktops with one instant
rem  reg query (no WMI/PowerShell; USB UPS batteries enumerate under hidbatt, not CmBatt).
rem  Failure modes stay safe: an unreadable key leaves MACHINE=unknown and a battery-removed
rem  laptop reads as desktop - the advisories this feeds are warning-only, so a misread means
rem  a missing hint, never a changed default or a blocked action.
set "MACHINE=unknown"
set "_bat="
for /f "tokens=3" %%M in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\CmBatt\Enum" /v Count 2^>nul ^| findstr /I "Count"') do set "_bat=%%M"
if not defined _bat ( reg query "HKLM\SYSTEM\CurrentControlSet\Services\CmBatt" >nul 2>&1 && set "_bat=0x0" )
if "%_bat%"=="0x0" set "MACHINE=desktop"
if defined _bat if not "%_bat%"=="0x0" set "MACHINE=laptop"
call :Log "PerfTweaks start - build %WIN_BUILD% win11=%IS_WIN11% gpu=%GPU% machine=%MACHINE%"
rem =====================================================================================
rem  MAIN MENU
rem =====================================================================================
:MainMenu
cls
call :Logo
echo ================================  MAIN MENU  ======================================
rem  Cached after the first call, so this is one probe per session, not per menu draw.
call :DetectSysDisk
echo   Build %WIN_BUILD%   Win11=%IS_WIN11%   GPU=%GPU%   Machine=%MACHINE%   Disk=%SYSDISK%
echo -----------------------------------------------------------------------------------
echo     1.  Cleanup ^& repair        (temp/logs, DISM/SFC, Windows Update, Store, WinSxS)
echo     2.  Performance tweaks       (GameDVR off, priorities, snappier UI)
echo     3.  Privacy ^& telemetry      (telemetry, ads, Cortana, location off)
echo     4.  Power plan               (high-performance, no sleep)
echo     5.  Network ^& DNS            (TCP tweaks, DNS, reset stack)
echo     6.  Apps ^& files            (OpenAsar, boot.config, hosts, SteamLight, startup)
echo     7.  Advanced                 (at your own risk - mitigations, timers, IPv6, GPU)
echo     8.  Backups ^& status        (restore point, registry backup, current status)
echo -----------------------------------------------------------------------------------
echo     9.  Apply recommended safe set  (one click: 1-5 core tweaks, no prompts)
echo    10.  Presets (light / moderate / heavy / custom)  + restore preset backup
echo    11.  What was excluded (info)
echo    12.  System tools               (PATH editor, find what locks a file)
echo     0.  Exit
echo ===================================================================================

:MainMenu_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MainMenu_ask
if "%sel%"=="1" goto MenuCleanup
if "%sel%"=="2" goto Performance
if "%sel%"=="3" goto Privacy
if "%sel%"=="4" goto Power
if "%sel%"=="5" goto MenuNetwork
if "%sel%"=="6" goto MenuApps
if "%sel%"=="7" goto MenuAdvanced
if "%sel%"=="8" goto MenuBackups
if "%sel%"=="9" goto ApplyRecommended
if "%sel%"=="10" goto MenuPresets
if "%sel%"=="11" goto Excluded
if "%sel%"=="12" goto MenuTools
if "%sel%"=="0" goto ExitScript
goto MainMenu

:ExitScript
cls
call :Logo
echo   Log saved to: %LOGFILE%
echo   Backups in:   %BACKUP_DIR%
echo.
echo   Bye.
timeout /t 2 >nul
exit /b
rem =====================================================================================
rem  SUBMENU: Cleanup & repair
rem =====================================================================================
:MenuCleanup
cls
call :Logo
echo ============================  CLEANUP ^& REPAIR  ===================================
echo     1.  Clean temp / logs / caches (+ optional: shaders, Recycle Bin, Event Viewer, Disk Cleanup)
echo     2.  DISM + SFC system integrity
echo     3.  Reset Windows Update components
echo     4.  Re-register Microsoft Store / apps
echo     5.  Compact WinSxS (free disk space)
echo     0.  Back
echo ===================================================================================

:MenuCleanup_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuCleanup_ask
if "%sel%"=="1" goto Cleanup
if "%sel%"=="2" goto SfcDism
if "%sel%"=="3" goto WUReset
if "%sel%"=="4" goto StoreRepair
if "%sel%"=="5" goto CompactWinSxS
if "%sel%"=="0" goto MainMenu
goto MenuCleanup
rem =====================================================================================
rem  SUBMENU: Network & DNS
rem =====================================================================================
:MenuNetwork
cls
call :Logo
echo =============================  NETWORK ^& DNS  =====================================
echo     1.  Apply TCP tweaks        (autotuning/heuristics/RSS/RSC, optional low-latency)
echo     2.  Set DNS                 (Cloudflare / Google / Quad9 / automatic)
echo     3.  Reset network stack     (winsock / ip / dns)
echo     4.  Flush DNS cache          (just the resolver cache - no stack changes)
echo     0.  Back
echo ===================================================================================

:MenuNetwork_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuNetwork_ask
if "%sel%"=="1" goto NetworkApply
if "%sel%"=="2" goto MenuDns
if "%sel%"=="3" goto NetReset
if "%sel%"=="4" goto FlushDns
if "%sel%"=="0" goto MainMenu
goto MenuNetwork

:MenuDns
cls
call :Logo
echo ===============================  SET DNS  =========================================
echo  IPv4 + IPv6, applied to all active adapters, DNS cache flushed. Fully reversible.
call :ShowCurrentDns
echo     1.  Cloudflare   1.1.1.1 / 1.0.0.1
echo     2.  Google       8.8.8.8 / 8.8.4.4
echo     3.  Quad9        9.9.9.9 / 149.112.112.112   (blocks known-malicious domains)
echo     4.  Revert to automatic (DHCP)
echo     5.  Custom server            (enter your own resolver)
echo     0.  Back
echo ===================================================================================

:MenuDns_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuDns_ask
if "%sel%"=="1" goto DnsCloudflare
if "%sel%"=="2" goto DnsGoogle
if "%sel%"=="3" goto DnsQuad9
if "%sel%"=="4" goto DnsAuto
if "%sel%"=="5" goto DnsCustom
if "%sel%"=="0" goto MenuNetwork
goto MenuDns
rem =====================================================================================
rem  SUBMENU: Apps & files
rem =====================================================================================
:MenuApps
cls
call :Logo
echo =============================  APPS ^& FILES  ======================================
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
echo ===================================================================================

:MenuApps_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuApps_ask
if "%sel%"=="1" goto OpenAsar
if "%sel%"=="2" goto UnityBoot
if "%sel%"=="3" goto ApplyHosts
if "%sel%"=="4" goto RestoreHosts
if "%sel%"=="5" goto SteamLight
if "%sel%"=="6" goto TimerResApply
if "%sel%"=="7" goto TimerResRemove
if "%sel%"=="8" goto Debloat
if "%sel%"=="9" goto StartupMgr
if "%sel%"=="0" goto MainMenu
goto MenuApps
rem =====================================================================================
rem  SUBMENU: Advanced
rem =====================================================================================
:MenuAdvanced
cls
call :Logo
echo ====================  ADVANCED  -  AT YOUR OWN RISK  ==============================
echo  Reversible, never part of "Apply recommended". Most need a reboot.
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
echo     0.  Back
echo ===================================================================================

:MenuAdvanced_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuAdvanced_ask
if "%sel%"=="1" goto DisableMitigations
if "%sel%"=="2" goto EnableMitigations
if "%sel%"=="3" goto BcdTimers
if "%sel%"=="4" goto BcdRevert
if "%sel%"=="5" goto NvmeFlags
if "%sel%"=="6" goto DisableIPv6
if "%sel%"=="7" goto MemCompress
if "%sel%"=="8" goto GpuTelemetry
if "%sel%"=="9" goto HagsToggle
if "%sel%"=="10" goto ProcPriority
if "%sel%"=="0" goto MainMenu
goto MenuAdvanced
rem =====================================================================================
rem  SUBMENU: Backups & status
rem =====================================================================================
:MenuBackups
cls
call :Logo
echo ===========================  BACKUPS ^& STATUS  ====================================
echo     1.  Create System Restore Point
echo     2.  Full registry backup (HKLM + HKCU export)
echo     3.  Show current status / what's applied
echo     4.  Restore from a preset backup (JSON)
echo     5.  Restore a single value backup (.reg)
echo     6.  Revert power settings (from a power backup)
echo     7.  Manage / open backup folder
echo     0.  Back
echo ===================================================================================

:MenuBackups_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuBackups_ask
if "%sel%"=="1" goto DoRestorePoint
if "%sel%"=="2" goto DoRegBackup
if "%sel%"=="3" goto Status
if "%sel%"=="4" goto RestorePresetJson
if "%sel%"=="5" goto RestoreRegBackup
if "%sel%"=="6" goto RestorePowerBackup
if "%sel%"=="7" goto ManageBackups
if "%sel%"=="0" goto MainMenu
goto MenuBackups
rem =====================================================================================
rem  ACTION: Cleanup
rem =====================================================================================
:Cleanup
cls
call :Logo
echo ================================  CLEANUP  ========================================
echo  Deletes temp files, Windows logs, thumbnail cache, crash dumps, Delivery Optimization
echo  cache, and telemetry caches, then flushes DNS. Optional: shader caches, Recycle Bin,
echo  Event Viewer, or launch Disk Cleanup / Storage Sense. Only files are removed; nothing
echo  is changed in the registry. Prefetch is intentionally left alone.
echo ===================================================================================
set "_c="
set /p "_c=Proceed? (Y/N): "
if /i not "%_c%"=="Y" goto MenuCleanup
rem  Outer free-space bracket: measure before core + optionals, report once at the end.
set "_CLEAN_OUTER=1"
call :FreeSpaceSnap
set "_FREE_BEFORE=%_FREE_BYTES%"
call :DoCleanupCore
set "_sh="
set /p "_sh=Also clear DirectX / NVIDIA download shader caches (next game may hitch while they rebuild)? (Y/N): "
if /i not "%_sh%"=="Y" goto _clShDone
if defined _cleanLocalAppData if exist "%LocalAppData%\D3DSCache\" call :Run "del /f /s /q ""%LocalAppData%\D3DSCache\*.*"""
set "_cleanProgramData="
call :CleanRoot ProgramData "%ProgramData%"
if defined _cleanProgramData if exist "%ProgramData%\NVIDIA Corporation\Downloader\" call :Run "del /f /s /q ""%ProgramData%\NVIDIA Corporation\Downloader\*.*"""

:_clShDone
set "_rb="
set /p "_rb=Also empty the Recycle Bin (irreversible)? (Y/N): "
if /i not "%_rb%"=="Y" goto _clRbDone
echo   ^> Emptying Recycle Bin...
call :Log "EXEC-PS: Clear-RecycleBin"
start "" /min /wait powershell -NoProfile -Command "try{ Clear-RecycleBin -Force -ErrorAction Stop; exit 0 }catch{ exit 1 }"
if errorlevel 1 ( echo   [WARN] Recycle Bin could not be emptied. ) else ( echo   [OK] Recycle Bin emptied. )

:_clRbDone
set "_ev="
set /p "_ev=Also clear ALL Event Viewer logs, including the Security/audit log (irreversible)? (Y/N): "
if /i not "%_ev%"=="Y" goto _clEvDone
for /f "tokens=*" %%G in ('wevtutil el') do call :Run "wevtutil cl ""%%G"""

:_clEvDone
set "_cm="
set /p "_cm=Also open Windows Disk Cleanup (cleanmgr) for the system drive? Sincript does not wait for it. (Y/N): "
if /i not "%_cm%"=="Y" goto _clCmDone
set "_drv=%SystemDrive:~0,1%"
start "" cleanmgr.exe /d %_drv%
call :Log "LAUNCH: cleanmgr /d %_drv%"
echo   [OK] Disk Cleanup launched for %_drv%:.

:_clCmDone
set "_ss="
set /p "_ss=Also open Storage Sense settings (configure / run from Windows Settings)? (Y/N): "
if /i not "%_ss%"=="Y" goto _clSsDone
start "" ms-settings:storagesense
call :Log "LAUNCH: ms-settings:storagesense"
echo   [OK] Storage Sense settings opened.

:_clSsDone
call :FreeSpaceSnap
set "_FREE_AFTER=%_FREE_BYTES%"
call :FreeSpaceReport
set "_CLEAN_OUTER="
echo [OK] Cleanup done.
pause
goto MenuCleanup

:DoCleanupCore
rem  Every delete below is anchored on an environment variable, and that is a loaded gun
rem  if one of them is missing. Batch does not error on an unset variable - it expands to
rem  nothing - so on a machine with a corrupted profile, a stripped environment, or a
rem  stray "set TEMP=" somewhere up the chain,
rem      del /f /s /q "%TEMP%\*.*"
rem  quietly becomes
rem      del /f /s /q "\*.*"
rem  which is a RECURSIVE delete from the ROOT of the current drive. Same line, same
rem  flags, whole machine. Quoting the paths does not help: the quotes are intact, it is
rem  the content that collapsed.
rem
rem  So each root is proven ONCE, here, before any delete runs, and every delete below is
rem  gated on its root having passed. Anything unproven is skipped out loud rather than
rem  guessed at - a skipped cleanup costs disk space, a wrong one costs the machine.
rem  When called from interactive :Cleanup, _CLEAN_OUTER=1 so free-space is reported once
rem  after optional buckets. Preset / recommended callers get snap+report here.
if defined _CLEAN_OUTER goto _clCoreBody
call :FreeSpaceSnap
set "_FREE_BEFORE=%_FREE_BYTES%"

:_clCoreBody
set "_cleanTEMP=" & set "_cleanSystemRoot=" & set "_cleanLocalAppData="
call :CleanRoot TEMP "%TEMP%"
call :CleanRoot SystemRoot "%SystemRoot%"
call :CleanRoot LocalAppData "%LocalAppData%"
if defined _cleanTEMP call :Run "del /f /s /q ""%TEMP%\*.*"""
if defined _cleanSystemRoot call :Run "del /f /s /q ""%SystemRoot%\Temp\*.*"""
if defined _cleanLocalAppData call :Run "del /f /s /q ""%LocalAppData%\Temp\*.*"""
rem  Intentionally NOT clearing %SystemRoot%\Prefetch - Windows just rebuilds it and the
rem  next launches get slower; it is a placebo (listed under "What was excluded").
if defined _cleanLocalAppData call :Run "del /f /s /q /a ""%LocalAppData%\Microsoft\Windows\Explorer\*.db"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Logs\CBS\*"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Logs\DISM\*"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Temp\CBS\*"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\setupact.log"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\setuperr.log"""
if defined _cleanSystemRoot call :Run "del /f /q ""%SystemRoot%\Panther\*"""
if defined _cleanLocalAppData call :Run "del /f /q ""%LocalAppData%\Microsoft\Windows\WebCache\*.*"""
rem  Regenerating junk safe for presets: crash dumps, minidumps, Delivery Optimization cache.
if defined _cleanLocalAppData if exist "%LocalAppData%\CrashDumps\" call :Run "del /f /s /q ""%LocalAppData%\CrashDumps\*.*"""
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
echo =============================  DISM + SFC integrity  ==============================
echo  Repairs the component store (DISM RestoreHealth) then verifies system files (SFC).
echo  Takes several minutes; progress streams below - let it finish.
echo ===================================================================================
set "_c="
set /p "_c=Run DISM + SFC now? (Y/N): "
if /i not "%_c%"=="Y" goto MenuCleanup
call :RunLive "dism /online /cleanup-image /restorehealth"
call :RunLive "sfc /scannow"
if "%_ELEV%"=="0" ( echo [WARN] Not elevated - DISM/SFC could not run. Re-run as Administrator. ) else ( echo [OK] DISM + SFC finished. Check the output above and the log for any files SFC could not repair. )
pause
goto MenuCleanup
rem =====================================================================================
rem  ACTION: Reset Windows Update
rem =====================================================================================
:WUReset
cls
call :Logo
echo =======================  Reset Windows Update components  =========================
echo  Stops update services, renames SoftwareDistribution and catroot2, restarts them.
echo  Fixes most stuck-update problems. Safe.
echo ===================================================================================
set "_c="
set /p "_c=Reset Windows Update now? (Y/N): "
if /i not "%_c%"=="Y" goto MenuCleanup
for %%S in (wuauserv bits cryptSvc msiserver appidsvc) do call :Run "net stop %%S"
call :Run "ren ""%SystemRoot%\SoftwareDistribution"" SoftwareDistribution.bak_%RANDOM%"
call :Run "ren ""%SystemRoot%\System32\catroot2"" catroot2.bak_%RANDOM%"
for %%S in (wuauserv bits cryptSvc msiserver appidsvc) do call :Run "net start %%S"
if "%_ELEV%"=="0" ( echo [WARN] Not elevated - Windows Update reset could not run. Re-run as Administrator. ) else ( echo [OK] Windows Update reset finished. See the output above and the log for any errors. )
pause
goto MenuCleanup
rem =====================================================================================
rem  ACTION: Re-register Store / apps
rem =====================================================================================
:StoreRepair
cls
call :Logo
echo =====================  Re-register Microsoft Store / apps  ========================
echo  Re-registers the Store package for the current user. Fixes a broken Store.
echo ===================================================================================
set "_c="
set /p "_c=Re-register the Store now? (Y/N): "
if /i not "%_c%"=="Y" goto MenuCleanup
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - Store re-register needs Administrator for -AllUsers. Re-run as Administrator.
    pause
    goto MenuCleanup
)
echo   ^> Re-registering Microsoft Store (separate window)...
call :Log "EXEC-PS (isolated): Store re-register"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try { Get-AppxPackage -AllUsers Microsoft.WindowsStore | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register ($_.InstallLocation + '\AppXManifest.xml') } } catch { exit 1 }"
if errorlevel 1 (
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
echo ===============================  Compact WinSxS  ==================================
echo  Removes superseded component-store versions via the supported DISM method, then
echo  optionally compresses system binaries (CompactOS). Frees disk space; reversible.
echo ===================================================================================
set "_c="
set /p "_c=Run component cleanup now? (Y/N): "
if /i not "%_c%"=="Y" goto MenuCleanup
call :Run "dism /online /cleanup-image /startcomponentcleanup"
set "_co="
set /p "_co=Also compress OS binaries with CompactOS (slower, more space saved)? (Y/N): "
if /i "%_co%"=="Y" call :Run "compact.exe /compactos:always"
if "%_ELEV%"=="0" ( echo [WARN] Not elevated - component cleanup could not run. Re-run as Administrator. ) else ( echo [OK] Component cleanup finished. See the output above and the log for details. )
pause
goto MenuCleanup
rem =====================================================================================
rem  ACTION: Performance
rem =====================================================================================
:Performance
cls
call :Logo
echo ==============================  PERFORMANCE TWEAKS  ===============================
echo  GameDVR off, gaming MMCSS priorities, faster startup/menus/shutdown, best-performance
echo  visuals, long-path support, Explorer opens "This PC", unhide core-parking options.
echo  Legacy "memory optimization" values and CPU-mitigation changes are NOT here (Advanced).
echo  One trade-off worth knowing: "faster shutdown" here includes AutoEndTasks=1. That
echo  lets Windows force-close apps at shutdown instead of showing the prompt that names
echo  which app is blocking it. Faster because it stops waiting - and unsaved work in
echo  those apps goes with it. Undo it from the value backup like any other tweak.
echo ===================================================================================
set "_c="
set /p "_c=Apply performance tweaks? (Y/N): "
if /i not "%_c%"=="Y" goto MainMenu
rem  _RUNTRACK matches :Privacy / :Power: it lets :Run count a failed sc/schtasks/powercfg
rem  call when NOT elevated. Registry writes bump _FAILS on their own, so the gap only ever
rem  hid service-level failures - but an action that reports [OK] while "sc stop SysMain"
rem  silently failed is exactly the dishonesty :Summary exists to prevent.
set "_FAILS=0" & set "_RUNTRACK=1"
call :DoPerformanceCore
set "_q1=" & set "_q2=" & set "_q3=" & set "_q4=" & set "_q5=" & set "_q6=" & set "_q7="
set "_q8=" & set "_q9=" & set "_q10=" & set "_q12="
echo.
echo Optional knobs (small / unproven gains, or plain preference - your call):
set /p "_q1=  SystemResponsiveness=0 (reserve less for background)? (Y/N): "
if /i "%_q1%"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "SystemResponsiveness" REG_DWORD 0 "SystemResponsiveness 0"
set /p "_q2=  Disable network throttling (may affect media playback)? (Y/N): "
if /i "%_q2%"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex" REG_DWORD 4294967295 "Network throttling off"
rem  One mutually-exclusive choice (not two yes/no prompts): picking a value and then "reset"
rem  in the same pass was a net no-op, and the reset's per-value .reg backup would snapshot 42
rem  (the value just set) instead of the true prior default, breaking that single-value undo.
rem  A word on what these values actually do, because the Windows "Processor scheduling"
rem  dialog reads them back and it is easy to be surprised. The value is a bitfield;
rem  bits 3-2 are the quantum TYPE: 1 = variable, 2 = fixed. Per Microsoft, variable is
rem  the client default and gives the FOREGROUND app a longer quantum; fixed is the
rem  Windows Server default and gives every app the same quantum. So:
rem    42 (0x2A) = short, FIXED quantum. Because the quantum is fixed, the dialog shows
rem               "background services" - not a bug, that is what fixed means. It is the
rem               classic "42" tweak; it favours throughput/consistency over fg latency.
rem    38 (0x26) = short, VARIABLE quantum, strong fg boost. This is the exact value the
rem               dialog writes for "Programs"; the foreground app gets the longer slice.
rem  Both are legitimate; they are opposite trade-offs, so both are offered rather than
rem  one being declared "correct".
echo   Win32PrioritySeparation ^(processor scheduling^):
echo       1 = 42 ^(0x2A: short FIXED quantum - the classic "42" tweak. The Windows
echo               dialog will read this back as "background services", because a fixed
echo               quantum treats all apps equally - that is what the value means.^)
echo       2 = 38 ^(0x26: short VARIABLE quantum, strong foreground boost - the value
echo               Windows own "Programs" radio writes; foreground gets the longer slice.^)
echo       3 = 2  ^(Windows default - pick this to undo a previous 42 or 38^)
echo       N = leave unchanged
set /p "_q3=  Choose [1/2/3/N]: "
if "%_q3%"=="1" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 42 "Win32PrioritySeparation = 42 (0x2A, short fixed quantum)"
if "%_q3%"=="2" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 38 "Win32PrioritySeparation = 38 (0x26, short variable quantum, foreground)"
if "%_q3%"=="3" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 2 "Win32PrioritySeparation default (2)"
call :DesktopAdvisory
set /p "_q4=  LargeSystemCache=1 (can help some laptops, can hurt desktops)? (Y/N): "
if /i "%_q4%"=="Y" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "LargeSystemCache" REG_DWORD 1 "LargeSystemCache on"
set /p "_q5=  Disable Windows Game Mode (contested; some titles run smoother without it)? (Y/N): "
if /i "%_q5%"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "AutoGameModeEnabled" REG_DWORD 0 "Game Mode off"
if /i "%_q5%"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\GameBar" "AllowAutoGameMode" REG_DWORD 0 "Auto Game Mode off"
set /p "_q12=  Disable Game Bar / Xbox Game Bar overlay leftovers (recording already off in core; this is overlay chrome - does not uninstall Xbox)? (Y/N): "
if /i "%_q12%"=="Y" call :DoGameBarOff
set /p "_q6=  Disable mouse acceleration / Enhance pointer precision - raw 1:1 mouse, after sign out/in? (Y/N): "
if /i "%_q6%"=="Y" call :SafeRegAdd "HKCU\Control Panel\Mouse" "MouseSpeed" REG_SZ 0 "Mouse acceleration off"
if /i "%_q6%"=="Y" call :SafeRegAdd "HKCU\Control Panel\Mouse" "MouseThreshold1" REG_SZ 0 "Mouse accel threshold1 off"
if /i "%_q6%"=="Y" call :SafeRegAdd "HKCU\Control Panel\Mouse" "MouseThreshold2" REG_SZ 0 "Mouse accel threshold2 off"
set /p "_q7=  Show file extensions in Explorer (safer, see real file types)? (Y/N): "
if /i "%_q7%"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" REG_DWORD 0 "Show file extensions"
set /p "_q8=  Turn off Storage Sense - stop Windows auto-deleting temp files / recycle bin (Cleanup does this on demand instead)? (Y/N): "
if /i "%_q8%"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSenseGlobal" REG_DWORD 0 "Storage Sense off (policy)"
if /i "%_q8%"=="Y" call :SafeRegAdd "HKCU\SOFTWARE\Policies\Microsoft\Windows\StorageSense" "AllowStorageSenseGlobal" REG_DWORD 0 "Storage Sense off (user policy)"
rem  Classic is already the Windows default, so for most systems this writes what is
rem  already there and :SafeRegAdd honestly prints [SKIP]. It only does something if you
rem  turned on "Enhanced" search, which indexes the whole drive - that one is worth undoing.
set /p "_q9=  Windows Search: index libraries only, not the entire drive (only changes anything if you enabled Enhanced)? (Y/N): "
if /i "%_q9%"=="Y" call :SafeRegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Search\Preferences" "WholeFileSystem" REG_DWORD 0 "Windows Search: classic scope"
call :DetectSysDisk
call :DiskAdvisory
set /p "_q10=  Disable SysMain / Superfetch - less background disk and CPU on an SSD (keep it ON for a mechanical HDD)? (Y/N): "
if /i "%_q10%"=="Y" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\SysMain" "Start" REG_DWORD 4 "SysMain (Superfetch) disabled"
if /i "%_q10%"=="Y" call :Run "sc stop SysMain"
set "_q11=" & set /p "_q11=  Show verbose boot/logon messages - a diagnostic that names each startup step, so you can SEE what is slow (not a speed-up itself)? (Y/N): "
if /i "%_q11%"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "verbosestatus" REG_DWORD 1 "Verbose startup/logon status messages"
if /i "%_q11%"=="Y" call :VerboseStatusNote
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
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583" "Attributes" REG_DWORD 0 "Unhide core-parking option"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb" "Attributes" REG_DWORD 0 "Unhide core-parking max cores"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\ea062031-0e34-4ff1-9b6d-eb1059334028" "Attributes" REG_DWORD 0 "Unhide processor perf option"
goto :eof
rem =====================================================================================
rem  ACTION: Privacy
rem =====================================================================================
:Privacy
cls
call :Logo
echo =============================  PRIVACY ^& TELEMETRY  ===============================
echo  Disables diagnostic telemetry, advertising ID, suggested apps, Cortana/web search,
echo  feedback prompts, activity feed and location; stops DiagTrack and CEIP tasks.
echo  Also turns off Windows AI features by policy - Copilot, Recall snapshots and
echo  Click to Do - plus inking/typing personalization and online speech recognition.
echo  Quiets remaining Start/lock Content Delivery tips, search-box suggestions, and
echo  tailored experiences. Also turns off the Widgets / News and Interests feed and
echo  Start app-launch tracking ("Most used"), and disables dmwappushservice alongside
echo  DiagTrack.
echo -----------------------------------------------------------------------------------
echo  Honest notes: the telemetry policy is written as 0 (Security). Enterprise and
echo  Education honor 0; Home/Pro clamp it to Basic (1) - the lowest those editions
echo  allow. Stopping DiagTrack also stops Xbox achievement sync and the Feedback Hub.
echo  Recall policies only have visible effect on Copilot+ hardware; elsewhere they
echo  are inert but harmless. Start/lock "suggestions and tips" keys quiet the
echo  Content Delivery surface - they are not Defender or security changes.
echo  dmwappushservice is the WAP-push telemetry transport, but it also carries MDM
echo  enrolment - on a work or school managed PC, leave this action alone.
echo  OneDrive is NOT touched by this core: it is the opt-in prompt below.
echo ===================================================================================
set "_c="
set /p "_c=Apply privacy / telemetry hardening? (Y/N): "
if /i not "%_c%"=="Y" goto MainMenu
set "_FAILS=0" & set "_RUNTRACK=1"
call :DoPrivacyCore
set "_svc="
set /p "_svc=Also disable per-user sync services (breaks Mail/Calendar/People sync)? (Y/N): "
if /i not "%_svc%"=="Y" goto _privSvcDone
for %%S in (CDPUserSvc OneSyncSvc PimIndexMaintenanceSvc UnistoreSvc UserDataSvc MessagingService) do call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\%%S" "Start" REG_DWORD 4 "Disable per-user svc %%S"

:_privSvcDone
set "_fw="
set /p "_fw=Also block the telemetry service in Windows Firewall (belt-and-braces if an update re-enables it)? (Y/N): "
if /i "%_fw%"=="Y" call :DiagTrackFirewall
set "_edge="
set /p "_edge=Also reduce Edge first-run / sidebar / shopping nudges (Edge only; does not uninstall Edge)? (Y/N): "
if /i "%_edge%"=="Y" call :DoEdgeNudgesOff
set "_od="
set /p "_od=Also block OneDrive file sync by policy (STOPS OneDrive syncing entirely - not just telemetry)? (Y/N): "
if /i "%_od%"=="Y" call :DoOneDriveSyncOff
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
call :SafeRegAdd "HKCU\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsSpotlightOnLockScreen" REG_DWORD 1 "Windows Spotlight on lock screen off"
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
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "TurnOffSavingSnapshots" REG_DWORD 1 "Recall snapshots off"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableClickToDo" REG_DWORD 1 "Click to Do off"
rem  --- inking / typing / speech personalization off ---
call :SafeRegAdd "HKCU\SOFTWARE\Policies\Microsoft\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0 "Inking-typing personalization off (user policy)"
call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization" "AllowInputPersonalization" REG_DWORD 0 "Inking-typing personalization off (policy)"
call :SafeRegAdd "HKCU\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" REG_DWORD 1 "Implicit text collection off"
call :SafeRegAdd "HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore" "HarvestContacts" REG_DWORD 0 "Contact harvesting off"
call :SafeRegAdd "HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" "HasAccepted" REG_DWORD 0 "Online speech recognition off"
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
echo ================================  POWER PLAN  =====================================
echo  Pick a power plan below, then optionally set monitor/standby/disk sleep timeouts to
echo  never. Ultimate Performance is the aggressive one and is best kept for a plugged-in
echo  desktop; High Performance is the safer fast plan; Balanced undoes either.
echo  Declining the plan switch does NOT end here: every other change on this screen
echo  applies to whichever plan you are already on, so you can keep Balanced and still
echo  turn off sleep, set the minimum CPU state, or disable power throttling.
echo -----------------------------------------------------------------------------------
echo  Your current plan:
for /f "tokens=*" %%i in ('powercfg /getactivescheme') do echo    %%i
echo ===================================================================================
call :LaptopAdvisory
rem  Machine-aware, still warning-only: it names the risk and changes no default. Windows
rem  hides Ultimate Performance on battery-powered machines on purpose, and on a laptop
rem  running an undervolt this is the single most dangerous item in the whole script - a
rem  step change to sustained max clocks is exactly where a stable undervolt stops being
rem  stable, and the CPU reports it as an internal parity error (WHEA), not as a crash you
rem  could mistake for software. Real hardware, real bugcheck 0x124.
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
echo       3 = Balanced              ^(the Windows default - pick this to undo 1 or 2^)
echo       N = leave the plan alone  ^(you can still apply the individual items below^)
set "_c="
set /p "_c=Choose [1/2/3/N]: "
set "_PWPLAN="
if "%_c%"=="1" set "_PWPLAN=ultimate"
if "%_c%"=="2" set "_PWPLAN=high"
if "%_c%"=="3" set "_PWPLAN=balanced"
if defined _PWPLAN goto _pwApply
rem  The plan switch is the ONE change here that is plan-level; everything below acts on
rem  the active scheme whatever it is. Sending a "no" straight back to the main menu threw
rem  away four working options because of one declined question.
set "_c2="
set /p "_c2=Apply individual power changes to your CURRENT plan instead? (Y/N): "
if /i not "%_c2%"=="Y" goto MainMenu

:_pwApply
rem  One undo file per visit, not per routine: :DoPowerCore calls both halves.
set "_PWBAK_FILE="
set "_FAILS=0" & set "_RUNTRACK=1"
if defined _PWPLAN call :DoPowerPlanSwitch
if defined _PWPLAN call :DoPowerTimeouts
if defined _PWPLAN goto _pwOptional
rem  On the current-plan path the timeouts are a question, not a given: someone who came
rem  only for the minimum CPU state should not have their screen stop sleeping as a side
rem  effect of saying yes to something else.
set "_tmo="
set /p "_tmo=Set monitor / standby / disk timeouts to NEVER on the current plan (costs battery on a laptop)? (Y/N): "
if /i "%_tmo%"=="Y" call :DoPowerTimeouts

:_pwOptional
set "_hb="
set /p "_hb=Also disable hibernation (frees disk space, removes Fast Startup)? (Y/N): "
if /i "%_hb%"=="Y" call :Run "powercfg /hibernate off"
set "_mp="
set /p "_mp=Set minimum processor state to 5%% (CPU idles to save power, no FPS loss; reset it under Windows Power Options)? (Y/N): "
if /i "%_mp%"=="Y" call :SetMinProcState
set "_pwt="
set /p "_pwt=Also disable CPU power throttling (background apps run at full speed - more heat, more battery drain)? (Y/N): "
if /i "%_pwt%"=="Y" call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" "PowerThrottlingOff" REG_DWORD 1 "CPU power throttling off"
call :Summary "Power settings applied."
pause
goto MainMenu

:DoPowerCore
rem  Backwards-compatible aggregate: switch the plan AND set the timeouts. This is what
rem  "power=1" in a preset and "Apply recommended safe set" have always meant, so it keeps
rem  meaning exactly that - the split below adds granularity without moving anyone's cheese.
call :DoPowerPlanSwitch
call :DoPowerTimeouts
goto :eof

:DoPowerPlanSwitch
rem  The plan-level half, split out from :DoPowerCore. This is the only part of the power
rem  action that changes WHICH scheme is active; everything else tunes the active one.
call :PowerBackup
rem  %_PWPLAN% = ultimate | high | balanced. UNSET means ultimate, because that is what
rem  preset "power=1" and "Apply recommended safe set" have always applied - those keep
rem  their exact previous meaning. Only the interactive menu asks, and it now asks properly
rem  instead of hiding a workstation plan behind a yes/no.
if not defined _PWPLAN set "_PWPLAN=ultimate"
if /i "%_PWPLAN%"=="balanced" goto _pwPlanBalanced
if /i "%_PWPLAN%"=="high" goto _pwPlanHigh
call :Log "Power plan -> Ultimate (fallback High)"
rem  Duplicate Ultimate ONTO its canonical GUID. Without a destination GUID every run
rem  created another randomly-numbered "Ultimate Performance" clone that /setactive (which
rem  targets the canonical GUID) never used - so unused plans piled up and the fallback
rem  High plan was what actually activated. With the destination set this is idempotent:
rem  the first run creates the plan, re-runs fail harmlessly ("already exists", which is
rem  suppressed), and /setactive then finds the real Ultimate plan.
powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 e9a42b02-d5df-448d-aa00-03f14749eb61 >nul 2>&1
powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 >nul 2>&1 || powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1
goto :eof

:_pwPlanHigh
rem  No -duplicatescheme needed: High Performance ships with Windows and is never hidden.
call :Log "Power plan -> High Performance"
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1
goto :eof

:_pwPlanBalanced
call :Log "Power plan -> Balanced (Windows default)"
powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e >nul 2>&1
goto :eof

:DoPowerTimeouts
rem  Plan-agnostic by construction: "powercfg -change" always targets the ACTIVE scheme, so
rem  these six lines were never tied to the Ultimate switch - they were only welded to it by
rem  sharing a routine. Splitting them is what lets someone stay on Balanced and still stop
rem  the machine sleeping. :SetMinProcState already worked this way (it uses scheme_current).
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
rem  Captures the CURRENT power scheme and its monitor / standby / disk idle timeouts into a
rem  runnable undo .bat in the backup folder, before anything touches them.
rem
rem  This closes the last "changes state with no backup" gap in the script. Every registry
rem  tweak writes a per-value .reg, hosts and app.asar keep write-once file copies - but the
rem  power action switched your scheme and set six timeouts to never with nothing captured,
rem  which is why :SetMinProcState's own prompt used to admit "no in-app undo".
rem
rem  Values are read from HKLM\...\Power\User\PowerSchemes (the same registry route :Status
rem  already uses for the minimum processor state) rather than parsed out of "powercfg /query"
rem  text. That output is LOCALIZED - "Current AC Power Setting Index" is translated - so text
rem  parsing would silently capture nothing on a non-English Windows and hand back an undo file
rem  that restores less than it claims. The registry names are the same in every language.
rem
rem  A setting that was never explicitly set on the scheme has no registry value; it is written
rem  into the .bat as a comment rather than guessed at, so the scheme default keeps applying -
rem  the same honest-decline shape :BackupValueLine uses for data it cannot round-trip.
rem
rem  Unlike hosts / app.asar / registry writes, a failed capture WARNS instead of blocking the
rem  action. The distinction is deliberate: an overwritten file is gone, whereas power settings
rem  stay reachable through Control Panel > Power Options even with no backup at all. Refusing
rem  here would cost the user the action for a risk they can already undo by hand.
if defined _PWBAK_FILE goto :eof
set "_PWBAK_FILE=%BACKUP_DIR%\PowerPlan_%RANDOM%%RANDOM%.bat"
set "PT_PWBAK=%_PWBAK_FILE%"
del "%_PWBAK_FILE%" >nul 2>&1
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $g=[regex]::Match(((powercfg /getactivescheme) -join ' '),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value; if(-not $g){exit 1}; $q=[char]34; $defs=@(@('7516b95f-f776-4464-8c53-06167f40cc99','3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e','monitor idle timeout'),@('238c9fa8-0aad-41ed-83f4-97be242c8f20','29f6c1db-86da-48c5-9fdb-f2b67b1f44da','standby idle timeout'),@('0012ee47-9041-4b5d-9b77-535fba8b1442','6738e2c4-e8a5-4a42-b16a-e040e769756e','disk idle timeout'),@('54533251-82be-4824-96c1-47b60b740d00','893dee8e-2bef-41e0-89c6-b55d0929964c','minimum processor state')); $L=@('@echo off','setlocal',('set '+$q+'PT_OK=0'+$q),('set '+$q+'PT_FAIL=0'+$q),'rem  Sincript power-settings undo.','rem  Restores the power scheme that was active before sincript changed it, and the','rem  monitor / standby / disk idle timeouts and the minimum processor state it had,','rem  each in its own native unit (seconds for the timeouts, percent for the CPU floor).','rem  Values are read back from the registry, so this is locale-independent.','rem  Safe to run more than once. Double-click to restore.','',('rem  scheme: '+$g),'','rem  The plan itself goes back FIRST, on purpose. It is the single line that matters most','rem  in this file, so a partial run - a crash, a closed window, a failed write below -','rem  still leaves you on the plan you started from instead of stranded on the new one.',('call :pt_do powercfg -setactive '+$g),''); foreach($d in $defs){ $p='HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\'+$g+'\'+$d[0]+'\'+$d[1]; $v=Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue; if($null -ne $v -and $null -ne $v.ACSettingIndex){ $L+=('rem  '+$d[2]+', on AC'); $L+=('call :pt_do powercfg -setacvalueindex '+$g+' '+$d[0]+' '+$d[1]+' '+[int]$v.ACSettingIndex) } else { $L+=('rem  '+$d[2]+' AC was never explicitly set on this scheme - left at the scheme default') }; if($null -ne $v -and $null -ne $v.DCSettingIndex){ $L+=('rem  '+$d[2]+', on battery'); $L+=('call :pt_do powercfg -setdcvalueindex '+$g+' '+$d[0]+' '+$d[1]+' '+[int]$v.DCSettingIndex) } else { $L+=('rem  '+$d[2]+' DC was never explicitly set on this scheme - left at the scheme default') } }; $L+=@('','rem  Re-activate once more: powercfg only applies changed values to the active scheme','rem  when the scheme is (re)activated, so this is what makes the writes above take effect.',('call :pt_do powercfg -setactive '+$g),'','rem  Report what actually landed. This file used to print a flat restored line whatever','rem  happened, so a run that could not write anything - not elevated, or the scheme since','rem  deleted - still read as success. Generated output is real cmd, so it gets the same','rem  honesty rule as the script that wrote it.',('if '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [OK] Restored %%PT_OK%% power setting(s).'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo [WARN] %%PT_OK%% restored, %%PT_FAIL%% FAILED - see the [FAIL] lines above.'),('if not '+$q+'%%PT_FAIL%%'+$q+'=='+$q+'0'+$q+' echo        Re-run this file from an elevated prompt.'),('if '+$q+'%%~1'+$q+'=='+$q+$q+' pause'),'exit /b %%PT_FAIL%%','','rem  Flat on purpose: no ( ) block, so nothing here depends on delayed expansion.',':pt_do','%%*','if errorlevel 1 goto :pt_bad','set /a PT_OK+=1','exit /b',':pt_bad','set /a PT_FAIL+=1','echo   [FAIL] %%*','exit /b'); Set-Content -LiteralPath $env:PT_PWBAK -Value $L -Encoding ASCII"
set "PT_PWBAK="
if not exist "%_PWBAK_FILE%" (
    echo   [WARN] Could not save a power-settings undo file - continuing anyway. Power options
    echo          remain reversible through Control Panel ^> Power Options.
    call :Log "WARN: power backup not written"
    set "_PWBAK_FILE="
    goto :eof
)
echo   [BACKUP] Power settings -^> %_PWBAK_FILE%
call :Log "POWERBACKUP -> %_PWBAK_FILE%"
goto :eof

:SetMinProcState
rem  Capture first. This is reachable without the plan switch or the timeouts (decline both,
rem  answer Y here), and PROCTHROTTLEMIN is now one of the settings :PowerBackup records - so
rem  the prompt no longer has to admit "no in-app undo", and that promise is actually backed.
call :PowerBackup
call :Log "Min processor state -> 5%%"
call :Run "powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMIN 5"
call :Run "powercfg /setdcvalueindex scheme_current sub_processor PROCTHROTTLEMIN 5"
call :Run "powercfg /setactive scheme_current"
goto :eof
rem =====================================================================================
rem  ACTION: Network TCP tweaks
rem =====================================================================================
:NetworkApply
cls
call :Logo
echo ==============================  APPLY TCP TWEAKS  =================================
echo  Receive-side autotuning = normal, heuristics off, RSS on, RSC on (sane defaults).
echo  Optionally disable Nagle / delayed-ACK on current adapters (lower latency), and
echo  stop Delivery Optimization uploading Windows Update files to other PCs.
echo ===================================================================================
set "_c="
set /p "_c=Apply TCP tweaks? (Y/N): "
if /i not "%_c%"=="Y" goto MenuNetwork
set "_FAILS=0" & set "_RUNTRACK=1"
call :DoNetworkCore
set "_nag="
set /p "_nag=Also disable Nagle/delayed-ACK on current adapters? (Y/N): "
if /i not "%_nag%"=="Y" goto _netNagDone
call :DoNagleOff

:_netNagDone
set "_dopt="
set /p "_dopt=Also stop sharing Windows Update downloads with other PCs (Delivery Optimization)? (Y/N): "
if /i "%_dopt%"=="Y" call :SafeRegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" REG_DWORD 0 "Delivery Optimization: no peer sharing"
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
echo ============================  Reset network stack  ================================
echo  Resets TCP/IP and Winsock, flushes DNS, releases/renews IP. Brief connectivity loss.
echo ===================================================================================
set "_c="
set /p "_c=Proceed? (Y/N): "
if /i not "%_c%"=="Y" goto MenuNetwork
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
echo ==========================  Flush DNS resolver cache  =============================
echo  Clears cached name lookups only. No adapter, stack or DNS-server change - this is
echo  the "a site moved and Windows is still using the old address" fix, and it is what
echo  you want far more often than a full stack reset.
echo ===================================================================================
set "_FAILS=0" & set "_RUNTRACK=1"
call :Run "ipconfig /flushdns"
call :Summary "DNS resolver cache flushed."
pause
goto MenuNetwork

:ShowCurrentDns
rem  Reads the statically configured resolver straight out of the Tcpip interface keys.
rem  Deliberately NOT "netsh interface ip show dnsservers": that output is localized, so a
rem  parser built on its English wording would show nothing on a translated Windows and the
rem  failure would look like "no DNS set" rather than an error (pitfall 26). REG_SZ value
rem  names are identical in every language, and this is a plain reg query - no PowerShell.
rem
rem  NameServer is populated only when a resolver was set explicitly, which is exactly what
rem  this menu does; an empty one means DHCP is supplying it. That makes the line honest in
rem  both directions instead of guessing.
set "_curdns="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" /s /v NameServer 2^>nul ^| findstr /I /C:"REG_SZ"') do if not "%%B"=="" set "_curdns=%%B"
if defined _curdns echo  Currently set: !_curdns!
if not defined _curdns echo  Currently set: ^(none - your adapters are taking DNS from DHCP^)
goto :eof

:_ip4_ok
rem  Validates !_IPCHK! as a dotted-quad IPv4 address; errorlevel 1 if it is not one.
rem
rem  This is user-typed free text on its way into a command line, which is the shape that
rem  bit the sibling project: a value expanded with %% before it was checked, so anything
rem  containing ^& ^| ^< ^> was parsed as an operator instead of passed as data. Two defences,
rem  both needed. The findstr pass allows nothing but digits and dots, so no metacharacter
rem  can survive it; every use afterwards is delayed (!var!) so even that is literal.
rem  The octet range check is the correctness half - 999.1.1.1 is not an injection risk but
rem  it is not an address either, and failing here beats a confusing error from Windows.
echo(!_IPCHK!| findstr /r /x /c:"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" >nul || exit /b 1
for /f "tokens=1-4 delims=." %%a in ("!_IPCHK!") do (
    if %%a GTR 255 exit /b 1
    if %%b GTR 255 exit /b 1
    if %%c GTR 255 exit /b 1
    if %%d GTR 255 exit /b 1
)
exit /b 0

:DnsCustom
cls
call :Logo
echo ==============================  Custom DNS server  ================================
echo  Enter an IPv4 resolver of your own - a router, a Pi-hole, NextDNS, a corporate
echo  server, or a provider not listed on the previous screen.
echo.
echo  IPv4 only. Your IPv6 DNS is left exactly as it is, so if IPv6 is active the system
echo  may still resolve through it - that is Windows' choice, not something this hides.
echo  Option 4 on the previous screen puts everything back to DHCP.
echo ===================================================================================
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
rem  Built from values that have passed :_ip4_ok, so DNSSRV can only ever contain digits,
rem  dots, quotes and commas by the time :ApplyDns expands it into the PowerShell call.
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
echo Reverting DNS to automatic (DHCP) on all active adapters...
call :Log "DNS -> automatic (DHCP)"
set "_dnsres=%TEMP%\pt_dnsres_%RANDOM%.txt"
del "%_dnsres%" >nul 2>&1
set "PT_DNSRES=%_dnsres%"
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
echo ==============================  Install OpenAsar  =================================
echo  Replaces Discord's app.asar in app-VERSION\resources\. Uses the bundled app.asar
echo  next to this script, or downloads the latest nightly. If a mod renamed the original
echo  to _app.asar / app.orig.asar / app.asar.orig, THAT is replaced (OpenAsar loads under
echo  the mod). Handles Discord / PTB / Canary. A Discord update can revert it - re-run.
echo ===================================================================================
set "_SRC="
if exist "%SCRIPT_DIR%app.asar" set "_SRC=%SCRIPT_DIR%app.asar"
if defined _SRC goto OA_HaveSrc
echo Local app.asar not found next to this script.
set "_dl="
set /p "_dl=Download the latest OpenAsar (nightly) from GitHub instead? (Y/N): "
if /i not "%_dl%"=="Y" goto MenuApps
echo Downloading OpenAsar nightly...
start "" /min /wait powershell -NoProfile -Command "try{Invoke-WebRequest -Uri 'https://github.com/GooseMod/OpenAsar/releases/download/nightly/app.asar' -OutFile (Join-Path $env:TEMP 'openasar_nightly.asar') -UseBasicParsing}catch{exit 1}"
rem  A failed download can leave a PARTIAL file behind; trust the child exit code first
rem  and remove the leftover, so a broken .asar is never installed into Discord.
if errorlevel 1 del "%TEMP%\openasar_nightly.asar" >nul 2>&1
if errorlevel 1 goto OA_DlFail
if not exist "%TEMP%\openasar_nightly.asar" goto OA_DlFail
set "_SRC=%TEMP%\openasar_nightly.asar"

:OA_HaveSrc
set "_c="
set /p "_c=Close Discord and continue? (Y/N): "
if /i not "%_c%"=="Y" goto MenuApps
taskkill /f /im Discord.exe       >nul 2>&1
taskkill /f /im DiscordPTB.exe    >nul 2>&1
taskkill /f /im DiscordCanary.exe >nul 2>&1
timeout /t 3 >nul
set "_DONE=0"
set "_OAFAIL=0"
for %%F in (Discord DiscordPTB DiscordCanary) do if exist "%LocalAppData%\%%F\" call :InstallAsarInto "%LocalAppData%\%%F" "%%F" "%_SRC%"
rem  The downloaded nightly is a temp file and every flavor has now consumed it. Only the
rem  download is removed - a bundled %SCRIPT_DIR%app.asar is the user's file and must stay.
if exist "%TEMP%\openasar_nightly.asar" del /f /q "%TEMP%\openasar_nightly.asar" >nul 2>&1
if "%_DONE%"=="0" (
    echo [ERROR] No Discord install was updated. Either none has a resources\app.asar ^(Store
    echo         version unsupported^), or Discord was still running - fully quit it and re-run.
    pause
    goto MenuApps
)
echo.
rem  _DONE only means at least ONE flavor succeeded. Without this line, Discord updating
rem  cleanly while PTB failed still read as unqualified success.
if not "%_OAFAIL%"=="0" echo [WARN] %_OAFAIL% Discord install^(s^) could NOT be updated - see the lines above.
echo Reopening Discord...
if exist "%LocalAppData%\Discord\Update.exe" start "" "%LocalAppData%\Discord\Update.exe" --processStart Discord.exe
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
echo ============================  Unity boot.config  ==================================
echo  Copies the bundled boot.config into a Unity game's *_Data folder, tuned for your
echo  CPU (job-worker-count). Per-game; restore boot.config.bak from that folder if needed.
echo ===================================================================================
call :RequireBundledFile boot.config "Unity engine boot configuration"
call :DetectUnityJobWorkers
echo.
echo   Detected: !_CORESRC!
echo   Setting job-worker-count / job-worker-maximum-count to !_JWCOUNT! (logical CPUs minus one).
echo.
echo Paste the game's *_Data folder path (or drag the folder here), then Enter:
set "_gd="
set /p "_gd=Path: "
set "_gd=%_gd:"=%"
if not defined _gd (
    echo.
    echo [ERROR] No folder path entered.
    echo         Paste the full path to the game's *_Data folder and try again.
    call :Log "ABORT: Unity boot.config - empty path"
    pause
    goto MenuApps
)
if "!_gd:~-1!"=="\" set "_gd=!_gd:~0,-1!"
set "_boottmp=%TEMP%\PerfTweaks_boot_%RANDOM%.config"
call :PrepareBootConfig "%SCRIPT_DIR%boot.config" "!_boottmp!" "!_JWCOUNT!"
if errorlevel 1 (
    echo.
    echo [ERROR] Could not prepare boot.config with job-worker-count=!_JWCOUNT!.
    echo   Check that the bundled boot.config is readable and try again.
    call :Log "FAIL: PrepareBootConfig workers=!_JWCOUNT!"
    if exist "!_boottmp!" del /f /q "!_boottmp!" >nul 2>&1
    pause
    goto MenuApps
)
rem  Step INTO the game folder first, then copy to the bare name "boot.config". This way no
rem  command ever receives a full path containing spaces (e.g. C:\Program Files\..), so the
rem  space cannot be split into a stray "C:\Program" file at the drive root.
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
    rem  Write-once + gated, same bargain as hosts / asar. Two defects lived on the old
    rem  single line: it copied unconditionally, so re-running tuned-over-original destroyed
    rem  the game's file; and it swallowed its own failure (2>&1, no &&) while the success
    rem  message below claimed "saved as boot.config.bak" regardless.
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
echo ==============================  SteamLight  =======================================
echo  Finds your Steam folder, writes a "SteamLight.bat" launcher there, and adds a
echo  Desktop shortcut. SteamLight starts Steam with flags that cut RAM/CPU use
echo  (single process/core, no shaders, no Big Picture, etc.) for a lighter, faster Steam.
echo ===================================================================================
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
if /i not "%_c%"=="Y" goto MenuApps
rem  Steam launch flags (edit this one line to change them). These cut RAM/CPU usage.
set "_SLFLAGS=-dev -console -nofriendsui -no-dwrite -nointro -nobigpicture -nofasthtml -nocrashmonitor -noshaders -no-shared-textures -disablehighdpi -cef-single-process -cef-in-process-gpu -single_core -cef-disable-d3d11 -cef-disable-sandbox -disable-winh264 -no-cef-sandbox -vrdisable -cef-disable-breakpad"
rem  Write the launcher INTO the Steam folder. It uses %~dp0steam.exe, i.e. the steam.exe
rem  sitting next to it, so it keeps working no matter where Steam is installed.
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
rem  Pass the Steam path via an env var (not interpolated into the PS string) so a path with an
rem  apostrophe (e.g. C:\Users\O'Brien\Steam) can't break the single-quoted PS literals.
rem  Exit 1 if the .lnk did not land - COM / Desktop-redirect failures must not claim success.
set "PT_SLDIR=!_STEAMDIR!"
start "" /min /wait powershell -NoProfile -Command "$sd=$env:PT_SLDIR; $d=[Environment]::GetFolderPath('Desktop'); $lnk=Join-Path $d 'SteamLight.lnk'; $w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($lnk); $s.TargetPath=(Join-Path $sd 'SteamLight.bat'); $s.WorkingDirectory=$sd; $s.WindowStyle=7; $s.IconLocation=((Join-Path $sd 'steam.exe')+',0'); $s.Description='Launch Steam in lightweight mode'; $s.Save(); if(-not (Test-Path -LiteralPath $lnk)){ exit 1 }"
set "PT_SLDIR="
if errorlevel 1 (
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
echo ============================  Apply custom hosts file  ============================
echo  Replaces the system hosts file with the bundled blocklist (entries point to 0.0.0.0).
echo  The current hosts is backed up next to it AND into the backup folder. DNS is flushed.
echo ===================================================================================
set "_HOSTS=%SystemRoot%\System32\drivers\etc\hosts"
call :RequireBundledFile hosts "ad/telemetry blocklist for the system hosts file"
set "_c="
set /p "_c=Proceed? (Y/N): "
if /i not "%_c%"=="Y" goto MenuApps
set "_hbak=0"
if exist "%_HOSTS%" (
    set "_hbakdoc=%BACKUP_DIR%\hosts_%RANDOM%%RANDOM%.bak"
    rem  Two backups with DIFFERENT jobs, and that distinction is the whole fix here:
    rem
    rem    hosts.bak (beside the file) is WRITE-ONCE - it holds the PRISTINE original.
    rem    It used to be copied unconditionally every run, so a second "apply hosts" (and
    rem    re-running IS normal - the bundled blocklist gets updated) copied the ALREADY
    rem    APPLIED blocklist over it. The true original was then gone, and "Restore hosts"
    rem    - which prefers this file - restored the blocklist over itself: a silent no-op
    rem    presented as a successful undo. Same class as the redundant-re-apply bug that
    rem    :SafeRegAdd guards with its idempotence skip; the file path never got that guard.
    rem
    rem    hosts_<random>.bak (Documents) is the per-run snapshot, so re-runs accumulate
    rem    instead of overwriting, and a hand-edited hosts is still captured every time.
    rem
    rem  _hbak is satisfied by EITHER, on purpose: a pristine original already on disk is a
    rem  BETTER undo than a fresh copy of the current file, not a worse one. What must never
    rem  happen is overwriting hosts with no recoverable prior state anywhere.
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
copy /y "%SCRIPT_DIR%hosts" "%_HOSTS%" >nul
if errorlevel 1 (
    echo.
    echo [ERROR] Could not replace the system hosts file:
    echo         "%_HOSTS%"
    echo   Common causes: Defender tamper protection, a third-party AV web-shield, or the
    echo   file is read-only. Temporarily allow edits to hosts, then re-run this action.
    call :Log "FAIL: apply hosts -> %_HOSTS%"
) else (
    echo [OK] hosts replaced. The original is backed up ^(hosts.bak beside it, and/or the backup folder^).
    call :Log "OK: hosts applied from %SCRIPT_DIR%hosts"
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
echo ===========================  Restore / reset hosts  ===============================
echo     1.  Restore from backup (hosts.bak, or Documents hosts_*.bak)
echo     2.  Reset to a clean Windows default (un-blocks everything)
echo     0.  Back
echo ===================================================================================
set "_HOSTS=%SystemRoot%\System32\drivers\etc\hosts"

:RestoreHosts_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto RestoreHosts_ask
if "%sel%"=="1" goto RestoreHostsBak
if "%sel%"=="2" goto ResetHostsDefault
if "%sel%"=="0" goto MenuApps
goto RestoreHosts

:RestoreHostsBak
set "_hsrc="
if exist "%_HOSTS%.bak" set "_hsrc=%_HOSTS%.bak"
if not defined _hsrc (
    rem  :ApplyHosts may have saved only into Documents when the local .bak was blocked.
    rem  OLDEST first (/od, not /o-d): these snapshots accumulate one per run, so the NEWEST
    rem  is the most recently modified hosts - usually a blocklist this script itself applied.
    rem  The OLDEST sits closest to the user's pristine file, which is what a restore is
    rem  actually asking for. (The local hosts.bak preferred above is write-once, so pristine.)
    for /f "delims=" %%F in ('dir /b /od "%BACKUP_DIR%\hosts_*.bak" 2^>nul') do (
        if not defined _hsrc set "_hsrc=%BACKUP_DIR%\%%F"
    )
)
if not defined _hsrc (
    echo [ERROR] No hosts backup found at "%_HOSTS%.bak" or in "%BACKUP_DIR%\hosts_*.bak".
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
rem  Same bargain as :ApplyHosts: never overwrite without a landed backup when a hosts
rem  file already exists. A best-effort copy that fails must abort, not claim hosts.bak.
set "_hbak=0"
if exist "%_HOSTS%" (
    rem  Same write-once rule as :ApplyHosts - resetting to the Windows default must not copy
    rem  the current (usually already-applied) hosts over the pristine original. This path
    rem  also gained the Documents snapshot it never had, so a reset stays recoverable even
    rem  when hosts.bak already exists and is therefore correctly left untouched.
    set "_hbakdoc=%BACKUP_DIR%\hosts_%RANDOM%%RANDOM%.bak"
    if not exist "%_HOSTS%.bak" copy /y "%_HOSTS%" "%_HOSTS%.bak" >nul 2>&1
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
    if exist "%_HOSTS%.bak" (
        echo [OK] hosts reset to Windows default ^(old one saved as hosts.bak^).
    ) else (
        echo [OK] hosts reset to Windows default.
    )
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
echo =====================  Disable CPU mitigations (RISKY)  ===========================
echo  Disables Spectre/Meltdown/MDS/SSBD/L1TF ^(bits 0-1^) AND Downfall/GDS ^(bit 25^).
echo  Can improve CPU performance but REDUCES security. Reversible (option 2).
echo  Per Microsoft KB5029778 Downfall/GDS DOES have its own bit ^(0x2000000^); the older
echo  "3" alone left it mitigated. Combined value is 0x2000003 ^(decimal 33554435^), and
echo  the mask must cover the same bits or the extra bit is written but ignored.
echo  Verify after reboot: PowerShell ^> Get-SpeculationControlSettings
echo ===================================================================================
set "_rp=Y"
set /p "_rp=Create a restore point first? (Y/N): "
if /i "%_rp%"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Disable mitigations now? (Y/N): "
if /i not "%_c%"=="Y" goto MenuAdvanced
set "_FAILS=0"
:: 33554435 = 0x2000003 = bit0|bit1 (Spectre/Meltdown/MDS/SSBD/L1TF) | bit25 (Downfall/GDS).
:: The mask MUST carry the same bits: Windows only honours override bits that are set in
:: the mask, so a mask of 3 would silently drop the Downfall bit - the exact reason the
:: old code missed it. Pass DECIMAL: :SafeRegAdd's idempotence does set /a on the value,
:: and reg query returns 0x02000003 which set /a reads back to the same 33554435.
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "FeatureSettingsOverride" REG_DWORD 33554435 "Disable CPU mitigations (Spectre/Meltdown + Downfall)"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "FeatureSettingsOverrideMask" REG_DWORD 33554435 "Mitigations override mask (covers Downfall bit)"
call :Summary "Mitigations disabled (incl. Downfall/GDS). REBOOT required."
pause
goto MenuAdvanced

:EnableMitigations
cls
call :Logo
echo =====================  Re-enable CPU mitigations (secure)  ========================
set "_FAILS=0"
:: Override=0 clears every override bit (all mitigations back ON). The mask must cover the
:: Downfall bit too (0x2000003), otherwise re-enabling would leave bit25 outside the mask
:: and a machine previously set by the OLD disable path could keep a stale Downfall state.
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
echo ============================  BCDEdit timer tweaks  ===============================
echo  Removes the forced platform clock, forces the platform tick, disables dynamic tick
echo  and sets TSC sync = enhanced (the BCD timer combo from the optimization guide).
echo  Can help timer-sensitive workloads. Reversible (option 4). REBOOT required.
echo ===================================================================================
call :LaptopAdvisory
set "_c="
set /p "_c=Apply timer tweaks? (Y/N): "
if /i not "%_c%"=="Y" goto MenuAdvanced
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
echo ============================  Revert BCDEdit timers  ==============================
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
echo ======================  Experimental NVMe driver flags  ===========================
echo  Toggles feature flags for Microsoft's in-box NVMe driver (StorNVMe). NOTE: Microsoft
echo  blocked these on fully-patched systems in 2026, so on an updated PC this likely does
echo  nothing now. Only relevant if your SSD uses the in-box driver. Harmless + reversible.
echo ===================================================================================
set "_rp=Y"
set /p "_rp=Create a restore point first? (Y/N): "
if /i "%_rp%"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Apply NVMe flags? (Y/N): "
if /i not "%_c%"=="Y" goto MenuAdvanced
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
echo ===============================  Disable IPv6  ====================================
echo  Sets DisabledComponents=0xFF (disables IPv6 on all interfaces). Do this only if you
echo  know you don't need IPv6. To revert, delete that value or set it to 0. REBOOT needed.
echo ===================================================================================
set "_c="
set /p "_c=Disable IPv6? (Y/N): "
if /i not "%_c%"=="Y" goto MenuAdvanced
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
echo =====================  Disable memory compression / combining  ====================
echo  Turns off RAM compression and page combining. Frees a little CPU at the cost of more
echo  RAM pressure on low-memory PCs. Re-enable: PowerShell ^> Enable-MMAgent -MemoryCompression
echo ===================================================================================
set "_c="
set /p "_c=Disable memory compression and page combining? (Y/N): "
if /i not "%_c%"=="Y" goto MenuAdvanced
rem  Launch PowerShell in a SEPARATE minimized window. Running powershell inside THIS
rem  window makes it apply its own console font/size (shows up as bold + small) until the
rem  window is closed; a separate window keeps this window's Consolas font intact.
if "%_ELEV%"=="0" (
    echo [WARN] Not elevated - memory compression was NOT changed. Re-run as Administrator.
    pause
    goto MenuAdvanced
)
echo   ^> Disabling memory compression and page combining...
call :Log "EXEC-PS (isolated): Disable-MMAgent -MemoryCompression / -PageCombining"
rem  Stop swallowing failures: exit nonzero if either Disable-MMAgent throws.
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try{ Disable-MMAgent -MemoryCompression; Disable-MMAgent -PageCombining; exit 0 }catch{ exit 1 }"
if errorlevel 1 (
    echo [ERROR] Memory compression / page combining could not be disabled. Reboot and re-run as Administrator.
    call :Log "FAIL: Disable-MMAgent"
) else (
    echo [OK] Memory compression / page combining disabled. REBOOT to fully apply.
    call :Log "OK: Disable-MMAgent"
)
pause
goto MenuAdvanced
rem =====================================================================================
rem  ACTION: GPU telemetry off
rem =====================================================================================
:GpuTelemetry
cls
call :Logo
echo =========================  GPU telemetry / tasks off  =============================
if "%GPU%"=="nvidia" goto GpuNvidia
if "%GPU%"=="amd" goto GpuAmd
echo  No NVIDIA/AMD GPU detected (or detection failed). Nothing to do here.
pause
goto MenuAdvanced

:GpuNvidia
echo  Detected NVIDIA. Disables NVIDIA telemetry tasks and background reporting only. The
echo  large undocumented GPU registry tweaks are NOT applied (they can cause crashes).
set "_c="
set /p "_c=Apply NVIDIA telemetry-off? (Y/N): "
if /i not "%_c%"=="Y" goto MenuAdvanced
set "_FAILS=0"
call :DisableNvidiaTelemetryTasks
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" "SendTelemetryData" REG_DWORD 0 "NVIDIA telemetry off"
call :SafeRegAdd "HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client" "OptInOrOutPreference" REG_DWORD 0 "NVIDIA opt-out"
call :Summary "NVIDIA telemetry / tasks disabled."
pause
goto MenuAdvanced

:GpuAmd
echo  Detected AMD. This opts you out of the AMD User Experience Program - AMD's usage-data /
echo  telemetry collection - by writing the opt-out to the registry, with a backup (reversible).
echo  No bulk undocumented AMD register tweaks are applied; those can cause instability.
set "_c="
set /p "_c=Apply AMD telemetry opt-out? (Y/N): "
if /i not "%_c%"=="Y" goto MenuAdvanced
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
echo =====================  GPU hardware scheduling (HAGS)  ============================
echo  HwSchMode in GraphicsDrivers: 2 = on (Windows default), 1 = off. Takes effect after a
echo  REBOOT. Needs Windows 10 2004+ and a GPU/driver that supports it - on older GPUs the
echo  setting is simply ignored. The on/off difference is usually small and system-specific;
echo  turning it OFF can help some capture/overlay stutter, but DISABLES features that need
echo  it ON - notably NVIDIA Frame Generation (DLSS 3). Backed up, so it stays reversible.
echo.
echo     1.  Turn HAGS OFF  (HwSchMode = 1)
echo     2.  Turn HAGS ON   (HwSchMode = 2, default)
echo     0.  Back
echo ===================================================================================

:HagsToggle_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto HagsToggle_ask
if "%sel%"=="1" goto HagsOff
if "%sel%"=="2" goto HagsOn
if "%sel%"=="0" goto MenuAdvanced
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

:ProcPriority
cls
call :Logo
echo =====================  PERMANENT PROCESS PRIORITY (per .exe)  =====================
echo  Pins a CPU priority that Windows re-applies every time that program starts, via
echo  Image File Execution Options (CpuPriorityClass). Backed up, so it stays reversible.
echo  Use the .exe that ACTUALLY runs (Task Manager -^> Details tab), not a launcher -
echo  High / Above-normal do NOT pass down to child processes. Realtime is not offered
echo  (it can starve Windows and freeze the machine).
echo ===================================================================================
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
echo ===========================  Create restore point  ================================
call :CreateRestorePoint
pause
goto MenuBackups

:DoRegBackup
cls
call :Logo
echo ===========================  Full registry backup  ================================
call :CreateRegBackup
pause
goto MenuBackups

:Status
cls
call :Logo
echo ===============================  CURRENT STATUS  ==================================
echo   OS build %WIN_BUILD%   Win11=%IS_WIN11%   GPU=%GPU%
echo -----------------------------------------------------------------------------------
echo [Hardware probes]  (these drive the [ADVISORY] lines, and nothing else)
call :DetectSysDisk
echo   Machine class = %MACHINE%   ^(ACPI battery present = laptop^)
echo   Windows disk  = %SYSDISK%   ^(seek-penalty probe; feeds the SysMain advisory^)
echo [Disk]  system drive free space
call :FreeSpaceSnap
if defined _FREE_HUMAN ( echo   !_FREE_HUMAN! ) else ( echo   could not measure )
echo [Power plan]
for /f "tokens=*" %%i in ('powercfg /getactivescheme') do echo   %%i
echo [Hibernation]  (0x0 = off, 0x1 = on)
call :ShowReg "HKLM\SYSTEM\CurrentControlSet\Control\Power" "HibernateEnabled"
echo [Min processor state]  (this script can set 5%%)
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $g=[regex]::Match(((powercfg /getactivescheme) -join ' '),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value; $p='HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\'+$g+'\54533251-82be-4824-96c1-47b60b740d00\893dee8e-2bef-41e0-89c6-b55d0929964c'; $ac=(Get-ItemProperty -Path $p).ACSettingIndex; $dc=(Get-ItemProperty -Path $p).DCSettingIndex; if($ac -ne $null){ $s='  AC=' + $ac + '%%   DC=' + $dc + '%%' } else { $s='  (using scheme default)' }; $s | Out-File -FilePath (Join-Path $env:TEMP 'pt_mps.txt') -Encoding ASCII"
if exist "%TEMP%\pt_mps.txt" ( type "%TEMP%\pt_mps.txt" & del "%TEMP%\pt_mps.txt" >nul 2>&1 )
echo [DNS - adapters with DNS configured]
start "" /min /wait powershell -NoProfile -Command "Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.ServerAddresses} | ForEach-Object { '  ' + $_.InterfaceAlias + ': ' + ($_.ServerAddresses -join ', ') } | Out-File -FilePath (Join-Path $env:TEMP 'pt_dns.txt') -Encoding ASCII"
if exist "%TEMP%\pt_dns.txt" ( type "%TEMP%\pt_dns.txt" & del "%TEMP%\pt_dns.txt" >nul 2>&1 )
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
echo [TCP global]
netsh int tcp show global | findstr ":"
echo [CPU mitigations] FeatureSettingsOverride above: 0x2000003 ^(33554435^)=all off incl.
echo                   Downfall; 0x3=Spectre/Meltdown off only; 0/^(not set^)=all on.
echo                   Detail: PowerShell ^> Get-SpeculationControlSettings
echo [Memory compression]  (True = on/default, False = disabled via Advanced)
start "" /min /wait powershell -NoProfile -Command "try{ $m=Get-MMAgent; $s='  MemoryCompression=' + $m.MemoryCompression + '   PageCombining=' + $m.PageCombining }catch{ $s='  (MMAgent not available on this system)' }; $s | Out-File -FilePath (Join-Path $env:TEMP 'pt_mma.txt') -Encoding ASCII"
if exist "%TEMP%\pt_mma.txt" ( type "%TEMP%\pt_mma.txt" & del "%TEMP%\pt_mma.txt" >nul 2>&1 )
echo [hosts file]
rem  Flat, not nested: "find /c /v ^< file" needs its ^ escape, and the escaping rules shift
rem  inside a ( ) block. A missing/unreadable hosts used to print the header and nothing at all.
set "_hostsf=%SystemRoot%\System32\drivers\etc\hosts"
set "_hlines="
if exist "%_hostsf%" for /f %%c in ('find /c /v "" ^< "%_hostsf%"') do set "_hlines=%%c"
if defined _hlines echo   !_hlines! lines total
if not defined _hlines echo   ^(hosts file not found or unreadable^)
echo [OpenAsar]  (app.asar well under 1 MB = OpenAsar; ~9 MB = stock Discord)
start "" /min /wait powershell -NoProfile -Command "Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Discord\app-*\resources\app.asar') -ErrorAction SilentlyContinue | ForEach-Object { '  ' + [math]::Round($_.Length/1MB,2) + ' MB  ' + $_.FullName } | Out-File -FilePath (Join-Path $env:TEMP 'pt_asar.txt') -Encoding ASCII"
if exist "%TEMP%\pt_asar.txt" ( type "%TEMP%\pt_asar.txt" & del "%TEMP%\pt_asar.txt" >nul 2>&1 )
echo ===================================================================================
pause
goto MenuBackups
rem =====================================================================================
rem  ACTION: Apply recommended safe set
rem =====================================================================================
:ApplyRecommended
cls
call :Logo
echo =========================  Apply recommended safe set  ============================
echo  Runs Cleanup + Privacy + Performance + Power + Network core tweaks with no prompts.
echo  Optional/risky items are NOT included. A restore point first is strongly advised.
echo ===================================================================================
call :LaptopAdvisory
set "_rp=Y"
set /p "_rp=Create a System Restore Point now? (Y/N): "
if /i "%_rp%"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Proceed with the recommended set? (Y/N): "
if /i not "%_c%"=="Y" goto MainMenu
rem  Same _RUNTRACK reasoning as :Privacy / :Power / :Performance - this path runs all five
rem  cores, so it has the most sc/schtasks/powercfg calls of any single action.
set "_PWBAK_FILE="
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
echo =========================  What was left out (and why)  ===========================
echo  This script intentionally does NOT include, by category:
echo.
echo  Security-weakening (excluded):
echo    - Disabling Windows Defender, Firewall, UAC or SmartScreen
echo    - Removing the "downloaded from the Internet" warning on executables
echo    - Fully disabling Windows Update or pointing it at a fake update server
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
echo.
echo  From the gaming optimization guide (left out on purpose):
echo    - Windows activation scripts (MAS) - licensing/trust, not a performance tweak
echo    - Replacing Defender with a third-party AV (e.g. Panda) - no FPS gain, changes security
echo    - Aggressive RAM / standby "cleaners" (ISLC empty-standby-list) - placebo to harmful
echo    - Forcing MSI mode, and NIC edits (jumbo frames, offloads) - the guide advises against these
echo.
echo  Note: disabling CPU mitigations and the large system cache ARE available, but only as
echo  explicit opt-in choices (Advanced / Performance) - never in the recommended set.
echo ===================================================================================
pause
goto MainMenu
rem =====================================================================================
rem  HELPERS
rem =====================================================================================
:Logo
echo.
echo                           SSSS   III   N   N
echo                           S       I    NN  N
echo                           SSSS    I    N N N
echo                               S   I    N  NN
echo                           SSSS   III   N   N
echo.
goto :eof

:Log
rem  Capture the message first, then echo it via DELAYED expansion. A literal ">" inside the
rem  message (e.g. the "-> path" we log) must not be seen by the parser as a redirection - if
rem  it were, a path like "C:\Program Files\.." would be split and create a stray "C:\Program".
set "_LOGLN=%~1"
>>"%LOGFILE%" echo [%date% %time%] !_LOGLN!
goto :eof

:TimerResApply
cls
call :Logo
echo =========================  Apply timer resolution  ================================
echo  Installs SetTimerResolution to run hidden at every logon (Task Scheduler) and hold
echo  a higher Windows timer resolution. On Windows 10 2004+ / 11 it also sets
echo  GlobalTimerResolutionRequests=1 so the change is system-wide (this needs a REBOOT).
echo  Reversible via option 7 (Remove timer resolution).
echo ===================================================================================
call :LaptopAdvisory
call :RequireBundledFile SetTimerResolution.exe "raises the Windows timer resolution (autostart helper)"
echo.
echo  Resolution is in 100ns units:  5000 = 0.5 ms (typical best),  10000 = 1 ms.
echo  The TimerResolution tool's MeasureSleep can find the best value for your PC.
set "_res="
set /p "_res=Resolution in 100ns units [Enter = 5000]: "
if not defined _res set "_res=5000"
set "_bad="
for /f "delims=0123456789" %%x in ("%_res%") do set "_bad=1"
if defined _bad (
    echo [ERROR] "%_res%" must be a whole number ^(100ns units^). Aborting.
    pause
    goto MenuApps
)
set "_c="
set /p "_c=Install the timer-resolution autostart with resolution %_res%? (Y/N): "
if /i not "%_c%"=="Y" goto MenuApps
set "_TRDIR=%ProgramData%\Sincript"
if not exist "%_TRDIR%" md "%_TRDIR%" >nul 2>&1
copy /y "%SCRIPT_DIR%SetTimerResolution.exe" "%_TRDIR%\SetTimerResolution.exe" >nul
if errorlevel 1 (
    echo [ERROR] Could not copy SetTimerResolution.exe to "%_TRDIR%".
    call :Log "TIMERRES copy failed"
    pause
    goto MenuApps
)
call :Log "TIMERRES helper copied to %_TRDIR%"
set "_FAILS=0"
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" "GlobalTimerResolutionRequests" REG_DWORD 1 "Global timer resolution requests on"
schtasks /Create /F /TN "Sincript Timer Resolution" /SC ONLOGON /RL HIGHEST /TR "%_TRDIR%\SetTimerResolution.exe --resolution %_res% --no-console" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Could not create the scheduled task ^(schtasks failed^).
    call :Log "TIMERRES schtasks create failed"
    pause
    goto MenuApps
)
call :Log "TIMERRES task created res=%_res%"
taskkill /f /im SetTimerResolution.exe >nul 2>&1
schtasks /Run /TN "Sincript Timer Resolution" >nul 2>&1
echo.
call :Summary "Timer-resolution autostart installed (resolution %_res%). Runs hidden at logon."
echo      REBOOT for the system-wide effect (GlobalTimerResolutionRequests) to take hold.
pause
goto MenuApps

:TimerResRemove
cls
call :Logo
echo ========================  Remove timer resolution  ================================
echo  Removes the SetTimerResolution autostart: deletes the scheduled task, stops the
echo  hidden helper and deletes the copied file. You can also revert the system-wide
echo  registry switch (that revert needs a REBOOT).
echo ===================================================================================
set "_c="
set /p "_c=Remove the timer-resolution autostart? (Y/N): "
if /i not "%_c%"=="Y" goto MenuApps
schtasks /Delete /F /TN "Sincript Timer Resolution" >nul 2>&1
taskkill /f /im SetTimerResolution.exe >nul 2>&1
if exist "%ProgramData%\Sincript\SetTimerResolution.exe" del /f /q "%ProgramData%\Sincript\SetTimerResolution.exe" >nul 2>&1
rd "%ProgramData%\Sincript" >nul 2>&1
call :Log "TIMERRES removed (task + helper)"
echo [OK] Autostart removed and the helper stopped.
echo.
set "_c2="
set /p "_c2=Also revert GlobalTimerResolutionRequests to default (off)? (Y/N): "
if /i not "%_c2%"=="Y" goto MenuApps
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
echo ===============================  Remove built-in apps  ============================
echo  Removes built-in Microsoft Store apps (telemetry / ads / rarely-used). Each group
echo  is opt-in below. This is NOT covered by the .reg backups: to get an app back you
echo  reinstall it from the Microsoft Store. Apps you actually use, just answer N.
echo ===================================================================================
set "_c="
set /p "_c=Remove the standard bloat set (Copilot, Bing apps, Teams, Office hub, Solitaire, etc.)? (Y/N): "
if /i not "%_c%"=="Y" goto DebloatOpt
call :Log "DEBLOAT standard set"
echo Removing standard bloat (a minimized window may flash)...
start "" /min /wait powershell -NoProfile -Command "$p=@('MicrosoftCorporationII.QuickAssist','Microsoft.WindowsFeedbackHub','Microsoft.Copilot','Microsoft.BingWeather','MicrosoftCorporationII.MicrosoftFamily','Microsoft.MicrosoftOfficeHub','Microsoft.BingSearch','Clipchamp.Clipchamp','MSTeams','Microsoft.Todos','Microsoft.MicrosoftStickyNotes','Microsoft.BingNews','Microsoft.OutlookForWindows','Microsoft.WindowsAlarms','Microsoft.MicrosoftSolitaireCollection'); foreach($x in $p){Get-AppxPackage -AllUsers $x | Remove-AppxPackage -ErrorAction SilentlyContinue}"
echo [OK] Standard bloat removed where present.

:DebloatOpt
echo.
set "_c2="
set /p "_c2=Also remove optional apps (Camera, Sound Recorder, Snipping Tool, Power Automate, Xbox)? (Y/N): "
if /i not "%_c2%"=="Y" goto DebloatOneDrive
call :Log "DEBLOAT optional apps"
echo Removing optional apps (a minimized window may flash)...
start "" /min /wait powershell -NoProfile -Command "$p=@('Microsoft.WindowsCamera','Microsoft.WindowsSoundRecorder','Microsoft.ScreenSketch','Microsoft.PowerAutomateDesktop','Microsoft.Xbox.TCUI','Microsoft.GamingApp'); foreach($x in $p){Get-AppxPackage -AllUsers $x | Remove-AppxPackage -ErrorAction SilentlyContinue}"
echo [OK] Optional apps removed where present.

:DebloatOneDrive
echo.
set "_c4="
set /p "_c4=Also remove OneDrive (uninstall it and remove the sync app)? (Y/N): "
if /i not "%_c4%"=="Y" goto DebloatDone
call :Log "DEBLOAT OneDrive"
echo Removing OneDrive (a minimized window may flash)...
start "" /min /wait powershell -NoProfile -Command "Get-AppxPackage -AllUsers Microsoft.OneDriveSync | Remove-AppxPackage -ErrorAction SilentlyContinue; Start-Process -FilePath ($env:SystemRoot + '\System32\OneDriveSetup.exe') -ArgumentList '/uninstall' -NoNewWindow -Wait -ErrorAction SilentlyContinue"
echo [OK] OneDrive removed.

:DebloatDone
echo.
echo Done. Any removed app can be reinstalled later from the Microsoft Store.
pause
goto MenuApps
rem =====================================================================================
rem  ACTION: Manage startup programs (the reversible Task Manager switch, with backups)
rem =====================================================================================
:StartupMgr
cls
call :Logo
echo =========================  MANAGE STARTUP PROGRAMS  ===============================
echo  Lists what starts with Windows - the Run registry keys (HKCU / HKLM / WOW64) and
echo  both Startup folders - and lets you flip any entry between Enabled and Disabled.
echo  This is the same reversible StartupApproved switch Task Manager uses: nothing is
echo  deleted, and the entry's previous state is saved as a .reg backup before each
echo  flip (restorable from Backups ^& status, or by double-clicking the file).
echo ===================================================================================
set "_sulist=%TEMP%\pt_startup_%RANDOM%.txt"
set "_sures=%TEMP%\pt_sures_%RANDOM%.txt"
del "%_sulist%" >nul 2>&1
call :StartupWorker list 0
if not exist "%_sulist%" (
    echo [ERROR] Could not enumerate startup entries ^(PowerShell blocked or unavailable^).
    pause
    goto MenuApps
)
set "_sn=0"
for /f "usebackq tokens=1,2,3,* delims=|" %%a in ("%_sulist%") do (
    set /a _sn+=1
    set "_sst[!_sn!]=%%b"
    set "_ssc[!_sn!]=%%c"
    set "_snm[!_sn!]=%%d"
)
del "%_sulist%" >nul 2>&1
if "%_sn%"=="0" (
    echo  No startup entries found ^(the Run keys and Startup folders are empty^).
    pause
    goto MenuApps
)
echo   #    State      Source           Name
echo -----------------------------------------------------------------------------------
for /l %%I in (1,1,%_sn%) do call :_suShow %%I
echo -----------------------------------------------------------------------------------
echo  Names are shown ASCII-only ^(other characters appear as "?"^); a flip still
echo  targets the exact entry. Disabled entries stay listed and can be re-enabled.

:StartupMgr_ask
set "sel="
set /p "sel=Number to flip Enabled/Disabled (0 = back): "
if not defined sel goto StartupMgr_ask
if "%sel%"=="0" goto MenuApps
set "_sok="
for /l %%I in (1,1,%_sn%) do if "%sel%"=="%%I" set "_sok=1"
if not defined _sok goto StartupMgr_ask
echo.
echo  About to flip:  [!_sst[%sel%]!]  !_ssc[%sel%]!  -  !_snm[%sel%]!
set "_cc="
set /p "_cc=Proceed? (Y/N): "
if /i not "%_cc%"=="Y" goto StartupMgr_ask
del "%_sures%" >nul 2>&1
call :StartupWorker toggle %sel%
set "_surc=%errorlevel%"
echo.
if exist "%_sures%" ( type "%_sures%" & del "%_sures%" >nul 2>&1 )
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
rem  One shared PowerShell worker in a minimized window (font-safe + locale-safe, the
rem  same pattern as DNS/status). It enumerates the Run keys and Startup folders in a
rem  FIXED, sorted order, so the number picked from the listing addresses the same entry
rem  in the toggle call - the entry NAME never round-trips through cmd, so non-ASCII
rem  names stay intact. A flip first writes the value's prior state to a .reg backup
rem  (UTF-16, the native regedit format) in the backup folder, THEN writes the Task
rem  Manager-style StartupApproved value: 02.. = enabled, 03 + timestamp = disabled.
rem  Registry access uses literal-path/.NET calls so names with wildcard characters
rem  ([ ] * ?) cannot misfire onto a different value.
set "PT_SU_MODE=%~1"
set "PT_SU_IDX=%~2"
set "PT_SU_LIST=%_sulist%"
set "PT_SU_RES=%_sures%"
set "PT_SU_BAK=%BACKUP_DIR%"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $srcs=@(@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKCU-Run'),@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKLM-Run'),@('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32','HKLM-Run32')); $E=@(); foreach($s in $srcs){ $k=Get-Item -LiteralPath $s[0] -ErrorAction SilentlyContinue; if($k){ foreach($n in ($k.GetValueNames() | Sort-Object)){ if($n -ne ''){ $E+=,@($s[2],$s[1],$n) } } } }; $dirs=@(@([Environment]::GetFolderPath('Startup'),'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder','User-Startup'),@([Environment]::GetFolderPath('CommonStartup'),'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder','Common-Startup')); foreach($s in $dirs){ if($s[0] -and (Test-Path -LiteralPath $s[0])){ foreach($f in (Get-ChildItem -LiteralPath $s[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | Sort-Object Name)){ $E+=,@($s[2],$s[1],$f.Name) } } }; function S($a,$n){ $k=Get-Item -LiteralPath $a -ErrorAction SilentlyContinue; if($k){ $v=$k.GetValue($n); if($v -and $v.Length -ge 1 -and (($v[0] -band 1) -eq 1)){ return 'Disabled' } }; return 'Enabled' }; if($env:PT_SU_MODE -eq 'list'){ $i=0; $o=@(); foreach($x in $E){ $i++; $dn=$x[2] -replace '[^\x20-\x7e]','?' -replace '[\x21\x22\x25\x26\x3c\x3e\x5e\x7c]','?'; $o+=(''+$i+'|'+(S $x[1] $x[2])+'|'+$x[0]+'|'+$dn) }; $o | Out-File -FilePath $env:PT_SU_LIST -Encoding ASCII; exit 0 }; $n=0; try{ $n=[int]$env:PT_SU_IDX }catch{ $n=0 }; if($n -lt 1 -or $n -gt $E.Count){ 'Entry not found - the startup list changed. Nothing was modified.' | Out-File -FilePath $env:PT_SU_RES -Encoding ASCII; exit 1 }; $x=$E[$n-1]; $appr=$x[1]; $name=$x[2]; $cur=S $appr $name; $had=$false; $raw=$null; $k=Get-Item -LiteralPath $appr -ErrorAction SilentlyContinue; if($k){ $raw=$k.GetValue($name); if($null -ne $raw){ $had=$true } }; $rk=$appr.Replace('HKCU:','HKEY_CURRENT_USER').Replace('HKLM:','HKEY_LOCAL_MACHINE'); $q=[char]34; $en=$name.Replace('\','\\').Replace([string]$q,'\'+$q); $bak=Join-Path $env:PT_SU_BAK ('StartupApproved_'+(Get-Random)+'.reg'); $body=@('Windows Registry Editor Version 5.00','','['+$rk+']'); if($had -and ($raw -is [byte[]])){ $hex=(($raw | ForEach-Object { $_.ToString('x2') }) -join ','); $body+=($q+$en+$q+'=hex:'+$hex) } elseif($had){ $body+=('; original value was not REG_BINARY - not auto-restorable from this file') } else { $body+=($q+$en+$q+'=-') }; $body | Out-File -FilePath $bak -Encoding Unicode; if(-not (Test-Path -LiteralPath $bak)){ 'Could not write the undo backup - antivirus or Controlled Folder Access may be blocking the backup folder. The startup entry was NOT changed.' | Out-File -FilePath $env:PT_SU_RES -Encoding ASCII; exit 1 }; if($cur -eq 'Enabled'){ $new=[byte[]](3,0,0,0)+[BitConverter]::GetBytes([DateTime]::Now.ToFileTime()); $ns='Disabled' } else { $new=[byte[]](2,0,0,0,0,0,0,0,0,0,0,0); $ns='Enabled' }; try{ [Microsoft.Win32.Registry]::SetValue($rk,$name,[byte[]]$new,[Microsoft.Win32.RegistryValueKind]::Binary) }catch{ Remove-Item -LiteralPath $bak -ErrorAction SilentlyContinue; ('Could not write the new state: '+$_.Exception.Message) | Out-File -FilePath $env:PT_SU_RES -Encoding ASCII; exit 1 }; $dn=$name -replace '[^\x20-\x7e]','?'; ((''+$dn+' : '+$cur+' -> '+$ns),('Backup of the previous state: '+$bak)) | Out-File -FilePath $env:PT_SU_RES -Encoding ASCII; exit 0"
set "_swrc=%errorlevel%"
set "PT_SU_MODE=" & set "PT_SU_IDX=" & set "PT_SU_LIST=" & set "PT_SU_RES=" & set "PT_SU_BAK="
exit /b %_swrc%

:RequireBundledFile
rem %1 = filename beside PerfTweaks.cmd   %2 = short description for messages/log
set "_bundled=%SCRIPT_DIR%%~1"
set "_bundled_sz="
if exist "%_bundled%" for %%F in ("%_bundled%") do set "_bundled_sz=%%~zF"
if exist "%_bundled%" if defined _bundled_sz if not "!_bundled_sz!"=="0" goto :eof
echo.
if not exist "%_bundled%" (
    echo [ERROR] Bundled file not found: %~1
) else (
    echo [ERROR] Bundled file is empty: %~1
)
echo.
echo   Expected location:
echo     %_bundled%
echo.
echo   Used for: %~2
echo.
echo   Fix: copy %~1 into the same folder as PerfTweaks.cmd, then run this option again.
echo        It is listed under "Optional bundled files" in the Sincript README.
call :Log "ABORT: missing/empty bundled %~1 (%~2)"
pause
goto MenuApps

:DetectUnityJobWorkers
rem Sets _JWCOUNT and _CORESRC. Logical processors (threads) - 1 when detectable; else prompt.
setlocal EnableDelayedExpansion
set "_JWCOUNT="
set "_CORESRC="
set "_LOGI=0"
rem  Run PowerShell in a SEPARATE minimized window (keeps this console's font intact),
rem  write the logical-processor (thread) count to a temp file, then read it back.
start "" /min /wait powershell -NoProfile -Command "try{$s=(Get-CimInstance Win32_Processor|Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum;if(-not $s){$s=0}}catch{$s=0}; $s | Out-File -FilePath (Join-Path $env:TEMP 'pt_cores.txt') -Encoding ASCII"
if exist "%TEMP%\pt_cores.txt" for /f "usebackq tokens=1 delims= " %%N in ("%TEMP%\pt_cores.txt") do set "_LOGI=%%N"
del "%TEMP%\pt_cores.txt" >nul 2>&1
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
if not defined _in goto DetectUnityJobWorkers_ask
echo !_in!| findstr /R "^[0-9][0-9]*$" >nul || (
    echo [ERROR] Enter a whole number between 1 and 32.
    goto DetectUnityJobWorkers_ask
)
set "_JWCOUNT=!_in!"
set "_CORESRC=user specified"
goto DetectUnityJobWorkers_clamp

:DetectUnityJobWorkers_clamp
if !_JWCOUNT! lss 1 set "_JWCOUNT=1"
if !_JWCOUNT! gtr 32 set "_JWCOUNT=32"
set "_DJW=!_JWCOUNT!"
set "_DCS=!_CORESRC!"
endlocal & set "_JWCOUNT=%_DJW%" & set "_CORESRC=%_DCS%"
goto :eof

:PrepareBootConfig
rem %1=source boot.config  %2=temp output path  %3=job-worker count (both worker keys set to this)
rem  Run PowerShell in a SEPARATE minimized window (keeps this console's font intact);
rem  paths are passed via environment variables so spaces/quotes can't break the command,
rem  and start /wait hands the child's exit code back to errorlevel.
set "PT_SRC=%~1"
set "PT_OUT=%~2"
set "PT_JW=%~3"
start "" /min /wait powershell -NoProfile -Command "try{$n=$env:PT_JW;$out=@();foreach($line in Get-Content -LiteralPath $env:PT_SRC){if($line -match '^job-worker-count='){$out+='job-worker-count='+$n}elseif($line -match '^job-worker-maximum-count='){$out+='job-worker-maximum-count='+$n}else{$out+=$line}};Set-Content -LiteralPath $env:PT_OUT -Value $out -Encoding ASCII;exit 0}catch{exit 1}"
set "_pbc=%errorlevel%"
set "PT_SRC=" & set "PT_OUT=" & set "PT_JW="
if "%_pbc%"=="1" exit /b 1
if not exist "%~2" exit /b 1
exit /b 0
rem =====================================================================================
rem  SUBMENU: System tools
rem =====================================================================================
:MenuTools
cls
call :Logo
echo =============================  SYSTEM TOOLS  ======================================
echo  General-purpose tools, not tweaks. Both are read-first and reversible.
echo     1.  Edit PATH (System / User environment variable)
echo     2.  Find what is locking a file (and optionally close it)
echo     0.  Back
echo ===================================================================================

:MenuTools_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuTools_ask
if "%sel%"=="1" goto PathEditor
if "%sel%"=="2" goto LockFinder
if "%sel%"=="0" goto MainMenu
goto MenuTools
rem =====================================================================================
rem  ACTION: PATH editor  (System Manager\Environment or HKCU\Environment)
rem =====================================================================================
:PathEditor
cls
call :Logo
echo ============================  EDIT PATH VARIABLE  =================================
echo  Reads the RAW value straight from the registry, so %%VAR%% references stay intact,
echo  and writes it back as REG_EXPAND_SZ - the type PATH must keep. It never uses
echo  setx (which silently crops at 1024 chars and freezes %%VAR%% into literal paths).
echo  Adding or removing an entry backs up the whole PATH value first, then broadcasts
echo  the change so new programs see it without a sign-out.
echo -----------------------------------------------------------------------------------
echo  Which PATH?
echo     1.  System  (HKLM - affects all users, needs Administrator)
echo     2.  User    (HKCU - just you)
echo     0.  Back
set "_pesc="
set /p "_pesc=Choose: "
if not defined _pesc goto MenuTools
if "%_pesc%"=="1" ( set "PT_PE_SCOPE=machine" & goto PathEditor_show )
if "%_pesc%"=="2" ( set "PT_PE_SCOPE=user" & goto PathEditor_show )
if "%_pesc%"=="0" goto MenuTools
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
set "_pelist=%TEMP%\pt_path_%RANDOM%.txt"
set "_peres=%TEMP%\pt_pathres_%RANDOM%.txt"
del "%_pelist%" >nul 2>&1
call :PathWorker list ""
if not exist "%_pelist%" (
    echo [ERROR] Could not read the PATH value ^(PowerShell blocked or unavailable^).
    pause
    goto MenuTools
)
set "_pen=0"
for /f "usebackq tokens=1,2,* delims=|" %%a in ("%_pelist%") do (
    set /a _pen+=1
    set "_pest[!_pen!]=%%b"
    set "_penm[!_pen!]=%%c"
)
del "%_pelist%" >nul 2>&1
echo.
if /i "%PT_PE_SCOPE%"=="machine" ( echo  System PATH - %_pen% entry^(ies^): ) else ( echo  User PATH - %_pen% entry^(ies^): )
echo   #   State    Folder
echo -----------------------------------------------------------------------------------
for /l %%I in (1,1,%_pen%) do call :_peShow %%I
echo -----------------------------------------------------------------------------------
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
if not defined _pea goto PathEditor_ask
if /i "%_pea%"=="0" goto MenuTools
if /i "%_pea%"=="A" goto PathEditor_add
if /i "%_pea%"=="R" goto PathEditor_remove
if /i "%_pea%"=="D" ( set "PT_PE_ARG=" & call :PathEditor_run dropdead "" & goto PathEditor_show )
if /i "%_pea%"=="C" ( set "PT_PE_ARG=" & call :PathEditor_run dedupe "" & goto PathEditor_show )
goto PathEditor_ask

:PathEditor_add
echo.
echo  Type or paste the folder to add ^(it is added at the END of PATH^).
set "_pfolder="
set /p "_pfolder=Folder (blank = cancel): "
if not defined _pfolder goto PathEditor_ask
call :PathEditor_run add "%_pfolder%"
goto PathEditor_show

:PathEditor_remove
echo.
set "_prm="
set /p "_prm=Number to remove (0 = cancel): "
if not defined _prm goto PathEditor_ask
if "%_prm%"=="0" goto PathEditor_ask
set "_pok="
for /l %%I in (1,1,%_pen%) do if "%_prm%"=="%%I" set "_pok=1"
if not defined _pok goto PathEditor_remove
echo.
echo  About to remove:  !_penm[%_prm%]!
set "_pc="
set /p "_pc=Proceed? (Y/N): "
if /i not "%_pc%"=="Y" goto PathEditor_ask
call :PathEditor_run removeidx "%_prm%"
goto PathEditor_show

:PathEditor_run
rem  %1 = verb (add|removeidx|dropdead|dedupe)   %2 = argument (folder or index)
rem  Backs up the whole PATH value to a .reg first (via the standard per-value backup),
rem  then hands the edit to the PS worker, then reports honestly from its result file.
set "_pverb=%~1"
set "_parg=%~2"
if /i "%PT_PE_SCOPE%"=="machine" (
    set "_pekey=HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
) else (
    set "_pekey=HKCU\Environment"
)
rem  Snapshot the whole Environment key to a .reg before editing. If that backup does not
rem  land, do NOT touch PATH: an edit you cannot undo is precisely what this feature must
rem  never do, and it is the same rule :ApplyHosts already follows before it overwrites
rem  the system hosts file.
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
del "%_peres%" >nul 2>&1
call :PathWorker "%_pverb%" "%_parg%"
set "_perc=%errorlevel%"
echo.
if exist "%_peres%" ( type "%_peres%" & del "%_peres%" >nul 2>&1 )
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
rem  One shared PS worker in a minimized window - same font/locale-safe pattern as the
rem  DNS and Startup workers. Reads the RAW PATH from the registry (REG_EXPAND_SZ, so
rem  %VAR% stays a reference), performs the edit in .NET, and writes it back with
rem  reg add /t REG_EXPAND_SZ. On any change it broadcasts WM_SETTINGCHANGE so new
rem  processes pick up the value without a sign-out. Entry text never round-trips
rem  through cmd - the number picked in the listing maps to the same split index here.
set "PT_PE_MODE=%~1"
set "PT_PE_ARG=%~2"
set "PT_PE_LIST=%_pelist%"
set "PT_PE_RES=%_peres%"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $scope=$env:PT_PE_SCOPE; if($scope -eq 'machine'){ $root=[Microsoft.Win32.Registry]::LocalMachine; $sub='SYSTEM\CurrentControlSet\Control\Session Manager\Environment' } else { $root=[Microsoft.Win32.Registry]::CurrentUser; $sub='Environment' }; $k=$root.OpenSubKey($sub,$false); $raw=''; if($k){ $raw=[string]$k.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $k.Close() }; $parts=@(); if($raw){ foreach($p in ($raw -split ';')){ if($p -ne ''){ $parts+=$p } } }; $mode=$env:PT_PE_MODE; if($mode -eq 'list'){ $i=0; $o=@(); foreach($p in $parts){ $i++; $exp=[Environment]::ExpandEnvironmentVariables($p); $state=if(Test-Path -LiteralPath $exp -PathType Container){'ok'}else{'[missing]'}; $dn=$p -replace '[^\x20-\x7e]','?'; $o+=(''+$i+'|'+$state+'|'+$dn) }; $o | Out-File -FilePath $env:PT_PE_LIST -Encoding ASCII; exit 0 }; $orig=$parts.Count; $changed=$false; $note=''; if($mode -eq 'add'){ $f=$env:PT_PE_ARG; if($f){ if($f.EndsWith('\')){ $f=$f.TrimEnd('\') }; $exists=$false; foreach($p in $parts){ if($p -ieq $f){ $exists=$true } }; if($exists){ $note='That folder is already in PATH - nothing added.' } else { $parts+=$f; $changed=$true; $note='Added: '+($f -replace '[^\x20-\x7e]','?') } } } elseif($mode -eq 'removeidx'){ $n=0; try{ $n=[int]$env:PT_PE_ARG }catch{ $n=0 }; if($n -ge 1 -and $n -le $parts.Count){ $rm=$parts[$n-1]; $keep=@(); for($j=0;$j -lt $parts.Count;$j++){ if($j -ne ($n-1)){ $keep+=$parts[$j] } }; $parts=$keep; $changed=$true; $note='Removed: '+($rm -replace '[^\x20-\x7e]','?') } else { $note='That number is not in the list - nothing removed.' } } elseif($mode -eq 'dropdead'){ $keep=@(); $drop=0; foreach($p in $parts){ $exp=[Environment]::ExpandEnvironmentVariables($p); if(Test-Path -LiteralPath $exp -PathType Container){ $keep+=$p } else { $drop++ } }; if($drop -gt 0){ $parts=$keep; $changed=$true }; $note='Removed '+$drop+' dead entry(ies).' } elseif($mode -eq 'dedupe'){ $seen=@{}; $keep=@(); $drop=0; foreach($p in $parts){ $key=$p.ToLowerInvariant(); if($seen.ContainsKey($key)){ $drop++ } else { $seen[$key]=$true; $keep+=$p } }; if($drop -gt 0){ $parts=$keep; $changed=$true }; $note='Removed '+$drop+' duplicate entry(ies).' }; if(-not $changed){ $note | Out-File -FilePath $env:PT_PE_RES -Encoding ASCII; exit 0 }; $new=($parts -join ';'); if($scope -eq 'machine'){ $kw=$root.OpenSubKey($sub,$true) } else { $kw=$root.OpenSubKey($sub,$true) }; if(-not $kw){ ('Could not open PATH for writing.') | Out-File -FilePath $env:PT_PE_RES -Encoding ASCII; exit 1 }; try{ $kw.SetValue('Path',$new,[Microsoft.Win32.RegistryValueKind]::ExpandString); $kw.Close() }catch{ ('Write failed: '+$_.Exception.Message) | Out-File -FilePath $env:PT_PE_RES -Encoding ASCII; exit 1 }; try{ $sig='using System;using System.Runtime.InteropServices;namespace PTB{public static class N{[DllImport(\"user32.dll\",CharSet=CharSet.Auto)]public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,string l,uint f,uint t,out UIntPtr r);}}'; Add-Type -TypeDefinition $sig -Language CSharp; $r=[UIntPtr]::Zero; [void][PTB.N]::SendMessageTimeout([IntPtr]0xffff,0x1A,[IntPtr]::Zero,'Environment',2,5000,[ref]$r) }catch{}; ($note+[Environment]::NewLine+'PATH updated. New programs and shells see it now; already-open ones keep the old value until restarted.') | Out-File -FilePath $env:PT_PE_RES -Encoding ASCII; exit 0"
set "_pwrc=%errorlevel%"
set "PT_PE_MODE=" & set "PT_PE_ARG=" & set "PT_PE_LIST=" & set "PT_PE_RES="
exit /b %_pwrc%
rem =====================================================================================
rem  ACTION: Find what is locking a file  (Restart Manager)
rem =====================================================================================
:LockFinder
cls
call :Logo
echo =======================  FIND WHAT IS LOCKING A FILE  =============================
echo  Uses the Windows Restart Manager - the same API installers use to find what
echo  has a file open. It lists every process holding the file, and marks the ones
echo  Windows flags as critical system processes ^(which must never be force-closed^).
echo  Listing is always safe; closing a process is opt-in, one at a time, and confirmed.
echo -----------------------------------------------------------------------------------
echo  Type or paste the full path to the file ^(e.g. a DLL or document you cannot delete^).
set "_lfpath="
set /p "_lfpath=File path (blank = back): "
if not defined _lfpath goto MenuTools
rem  FIX (crash): this printed %_lfpath% - percent-expanded at PARSE time, before cmd
rem  even evaluates the condition, and before the block structure is worked out. A path
rem  like C:\Program Files (x86)\Steam\steam.exe therefore injected a bare ")" into the
rem  block and killed the whole script with "was unexpected at this time" - whether or
rem  not the file existed. !_lfpath! expands at RUN time, after the block is parsed, so
rem  the parens are just data. This is the same class as the hosts-restore crash; the
rem  analyzer cannot see it because the ")" arrives through a variable.
if not exist "%_lfpath%" (
    echo.
    echo  [ERROR] No such file: !_lfpath!
    echo          Give the full path to an existing file.
    echo.
    pause
    goto LockFinder
)
set "_lflist=%TEMP%\pt_lock_%RANDOM%.txt"
set "_lfres=%TEMP%\pt_lockres_%RANDOM%.txt"
del "%_lflist%" >nul 2>&1
call :LockWorker list "%_lfpath%"
if not exist "%_lflist%" (
    echo [ERROR] Could not query the file ^(PowerShell blocked, or the Restart Manager
    echo         service is unavailable^).
    pause
    goto MenuTools
)
set "_lfn=0"
for /f "usebackq tokens=1,2,3,4,* delims=|" %%a in ("%_lflist%") do (
    set /a _lfn+=1
    set "_lfpid[!_lfn!]=%%b"
    set "_lfcrit[!_lfn!]=%%c"
    set "_lfnm[!_lfn!]=%%d"
)
del "%_lflist%" >nul 2>&1
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
echo -----------------------------------------------------------------------------------
for /l %%I in (1,1,%_lfn%) do call :_lfShow %%I
echo -----------------------------------------------------------------------------------
echo  [critical] = a core Windows process. Sincript will NOT close these - a reboot is
echo  the only safe way to release a file they hold.

:LockFinder_ask
echo.
set "_lfk="
set /p "_lfk=Number to close (0 = back): "
if not defined _lfk goto LockFinder_ask
if "%_lfk%"=="0" goto MenuTools
set "_lok="
for /l %%I in (1,1,%_lfn%) do if "%_lfk%"=="%%I" set "_lok=1"
if not defined _lok goto LockFinder_ask
rem  _lfk came off set /p, so until this point it could hold anything. The loop above
rem  proves it is one of 1..N - a plain integer. Copy the PROVEN value into _lfi and
rem  index with that from here on, so no line below percent-expands raw user input into
rem  a block, where a ")" in the value would end the block early and abort the script.
rem  Same reason :LockFinder prints !_lfpath! and not %_lfpath%.
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
if /i not "%_lc%"=="Y" goto LockFinder_ask
call :Run "taskkill /PID !_lfpid[%_lfi%]! /F"
echo.
echo  If it closed, the file should now be free. Re-checking...
echo.
del "%_lflist%" >nul 2>&1
call :LockWorker list "%_lfpath%"
set "_lfn2=0"
if exist "%_lflist%" ( for /f "usebackq tokens=1 delims=|" %%a in ("%_lflist%") do set /a _lfn2+=1 )
del "%_lflist%" >nul 2>&1
if "%_lfn2%"=="0" (
    echo  [OK] Nothing is holding the file now.
) else (
    echo  [NOTE] %_lfn2% process^(es^) still hold it - it may have relaunched, or another
    echo         program opened it. Re-run to see the current list.
)
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
rem  %1 = list   %2 = file path.  One minimized PS worker (font/locale-safe, same
rem  pattern as the other workers). Calls the Restart Manager: RmStartSession ->
rem  RmRegisterResources(file) -> RmGetList, which returns the processes holding the
rem  file. ApplicationType == RmCritical (1000) marks a core Windows process; those are
rem  reported as "critical" and the batch refuses to close them. Process names are
rem  ASCII-forced for display; the PID drives any close, so the name never has to
rem  round-trip through cmd.
set "PT_LF_LIST=%_lflist%"
set "PT_LF_FILE=%~2"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $sig='using System;using System.Runtime.InteropServices;namespace PTR{[StructLayout(LayoutKind.Sequential)]public struct RUP{public int pid;public System.Runtime.InteropServices.ComTypes.FILETIME ft;}public enum AT{Unknown=0,MainWindow=1,OtherWindow=2,Service=3,Explorer=4,Console=5,Critical=1000}[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct PI{public RUP Process;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string app;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)]public string svc;public AT AppType;public uint Status;public uint Sess;[MarshalAs(UnmanagedType.Bool)]public bool restart;}public static class Rm{[DllImport(\"rstrtmgr.dll\",CharSet=CharSet.Unicode)]public static extern int RmStartSession(out uint h,int f,string k);[DllImport(\"rstrtmgr.dll\")]public static extern int RmEndSession(uint h);[DllImport(\"rstrtmgr.dll\",CharSet=CharSet.Unicode)]public static extern int RmRegisterResources(uint h,uint nf,string[] fs,uint na,RUP[] a,uint ns,string[] s);[DllImport(\"rstrtmgr.dll\")]public static extern int RmGetList(uint h,out uint need,ref uint have,[In,Out]PI[] arr,ref uint reason);}}'; try{ Add-Type -TypeDefinition $sig -Language CSharp }catch{ exit 3 }; $file=$env:PT_LF_FILE; $key=[Guid]::NewGuid().ToString(); $h=0; if([PTR.Rm]::RmStartSession([ref]$h,0,$key) -ne 0){ @() | Out-File -FilePath $env:PT_LF_LIST -Encoding ASCII; exit 0 }; $out=@(); try{ if([PTR.Rm]::RmRegisterResources($h,1,@($file),0,$null,0,$null) -ne 0){ throw }; [uint32]$need=0;[uint32]$have=0;[uint32]$reason=0; $rc=[PTR.Rm]::RmGetList($h,[ref]$need,[ref]$have,$null,[ref]$reason); if($need -gt 0){ $arr=[PTR.PI[]]::new($need); $have=$need; $rc=[PTR.Rm]::RmGetList($h,[ref]$need,[ref]$have,$arr,[ref]$reason); if($rc -eq 0){ $i=0; for($j=0;$j -lt [int]$have;$j++){ $p=$arr[$j]; $i++; $nm=$p.app; if(-not $nm){ $nm='(pid '+$p.Process.pid+')' }; $dn=$nm -replace '[^\x20-\x7e]','?'; $crit=if($p.AppType -eq [PTR.AT]::Critical){'critical'}else{'normal'}; $out+=(''+$i+'|'+$p.Process.pid+'|'+$crit+'|'+$dn+'|') } } } }catch{}; [PTR.Rm]::RmEndSession($h) | Out-Null; $out | Out-File -FilePath $env:PT_LF_LIST -Encoding ASCII; exit 0"
set "_lwrc=%errorlevel%"
set "PT_LF_LIST=" & set "PT_LF_FILE="
exit /b %_lwrc%

:BackupSingleValue
rem  %1 = key  %2 = value  %3 = description
rem  Whole-KEY .reg backup for the PATH editor, via reg export. Sets _BSV_OK=1 only when
rem  a real backup file actually landed, so the caller can refuse to edit without one.
rem
rem  Deliberately NOT :BackupValueLine, the echo-based writer every tweak uses. That one
rem  only knows REG_DWORD and REG_SZ and honestly declines everything else - which is
rem  correct for the tweaks, since they are all DWORDs. But PATH is REG_EXPAND_SZ - that
rem  is the entire point of the PATH editor - so it fell straight into the decline branch:
rem  the .reg got a "not auto-restorable" comment while the screen still printed [BACKUP].
rem  A comment is not an undo, and PATH is the one value here you most need to put back.
rem
rem  reg export is exact for every type (expand_sz, multi_sz, unicode data) and needs no
rem  escaping, so the value never passes through batch string handling at all. That also
rem  closes the one place a PATH entry holding "!" could be eaten by delayed expansion -
rem  a folder named C:\Foo!Bar is perfectly legal.
rem
rem  It exports the whole key rather than the single value. For Environment that is a
rem  handful of variables, and putting the key back as it was seconds ago IS the undo.
setlocal EnableDelayedExpansion
set "_key=%~1"
set "_val=%~2"
set "_desc=%~3"
set "_safe=!_key:\=_!"
set "_safe=!_safe::=!"
set "_safe=!_safe: =_!"
set "_bkp=%BACKUP_DIR%\!_safe!_%RANDOM%%RANDOM%.reg"
set "_rk=!_key!"
rem  All five hives, matching :SafeRegAdd. Only HKLM/HKCU reach here today (the PATH editor
rem  is the sole caller), but a half-map is the kind of thing that silently exports the wrong
rem  key the moment this helper picks up a second caller.
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
call :Log "PATHBACKUP !_key! !_val! -> !_bkp!"
endlocal & set "_BSV_OK=1" & goto :eof

:_bsvFail
echo   [ERROR] Could not write a backup of !_key!.
call :Log "FAIL: PATHBACKUP !_key! !_val!"
endlocal & set "_BSV_OK=" & goto :eof
rem =====================================================================================
rem  HARDWARE PROBE: system disk media type (for the SysMain advisory)
rem =====================================================================================
:DetectSysDisk
rem  Sets SYSDISK=ssd|hdd|unknown, and caches it - the "if defined SYSDISK" guard below is
rem  what keeps this to ONE probe per session no matter how many callers there are.
rem
rem  It used to be probed lazily right before the SysMain prompt, on the reasoning that no
rem  run should pay a PowerShell launch for a question most runs never ask. That reasoning
rem  expired when the disk type moved onto the main-menu header: every session now displays
rem  it, so every session needs it, and deferring only moved the same cost later. MACHINE
rem  stays a pure reg query and is still resolved at startup; this one costs one minimized
rem  PowerShell window on the first menu draw.
rem
rem  Asks the disk directly, via IOCTL_STORAGE_QUERY_PROPERTY with
rem  StorageDeviceSeekPenaltyProperty - "does this device incur a seek penalty?" is
rem  literally the SSD-vs-spinning question, and it is what Windows itself uses. The
rem  volume is opened with 0 access (query only, no read rights, no elevation needed).
rem
rem  It does NOT go through Get-PhysicalDisk / Get-Partition, and that is the whole
rem  point. Those live in the root\Microsoft\Windows\Storage CIM namespace, and per
rem  Microsoft they enumerate "across any available Storage Management Providers" - so
rem  ONE broken vendor storage provider makes every cmdlet in that namespace throw. That
rem  is not hypothetical: on a test machine (HP Omen, NVMe SSD) Get-Partition,
rem  Get-PhysicalDisk and even raw Get-CimInstance MSFT_PhysicalDisk all failed with
rem  CimException "Invalid property", while this IOCTL answered correctly and instantly.
rem  OEM laptops ship those providers as standard, so this is a common case, not an edge.
rem
rem  Failure stays safe: if the device cannot answer, SYSDISK stays "unknown" and the
rem  advisory this feeds is warning-only - a miss costs a hint, never a changed default
rem  or a blocked action.
if defined SYSDISK goto :eof
set "SYSDISK=unknown"
rem  ---- tier 1: the answer this machine already gave, if the hardware has not changed ----
rem  The probe below is correct but not cheap, and the expensive part is NOT the IOCTL - that
rem  is microseconds. It is "Add-Type -Language CSharp", which spawns the C# compiler at
rem  runtime to build the P/Invoke shim, and that costs a second or two on a cold run. Moving
rem  the disk type onto the main-menu header made every session pay it before the menu drew.
rem
rem  Switching to a faster detector is not the fix: the fast ones are Get-PhysicalDisk /
rem  Get-Partition, and those are exactly what this routine exists to avoid, because one
rem  broken vendor storage provider takes the whole Storage namespace down with it. So keep
rem  the trusted probe and run it once per MACHINE instead of once per session.
rem
rem  The cache is keyed on disk 0's device instance path (a plain reg query, instant, and the
rem  same string in every locale). It is not necessarily the system disk - it does not need to
rem  be. It only has to CHANGE when the storage hardware changes, which is exactly what makes
rem  a stale cached answer impossible to keep. Delete the file to force a fresh probe.
set "_sdkey="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\disk\Enum" /v 0 2^>nul ^| findstr /I /C:"REG_SZ"') do set "_sdkey=%%B"
set "_sddir=%LOCALAPPDATA%\Sincript"
set "_sdcache=%_sddir%\sysdisk.cache"
if not defined LOCALAPPDATA goto _sdProbe
if not defined _sdkey goto _sdProbe
if not exist "!_sdcache!" goto _sdProbe
set "_sdck=" & set "_sdcv="
for /f "usebackq tokens=1,* delims=|" %%A in ("!_sdcache!") do ( set "_sdck=%%A" & set "_sdcv=%%B" )
if not defined _sdcv goto _sdProbe
if not "!_sdck!"=="!_sdkey!" goto _sdProbe
rem  Only ssd/hdd are answers this routine can produce, so anything else means the file was
rem  edited or truncated. Re-probe rather than trust it - a cache is an optimisation, and an
rem  optimisation that can hand back a value the prober would never emit is a liability.
if /i not "!_sdcv!"=="ssd" if /i not "!_sdcv!"=="hdd" goto _sdProbe
set "SYSDISK=!_sdcv!"
call :Log "System disk media type: !SYSDISK! (cached)"
goto :eof

:_sdProbe
set "_sdres=%TEMP%\pt_sdisk_%RANDOM%.txt"
del "%_sdres%" >nul 2>&1
set "PT_SD_RES=%_sdres%"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $t='unknown'; $dl=if($env:SystemDrive){ $env:SystemDrive.Substring(0,1) }else{ 'C' }; try{ $sig='using System;using System.Runtime.InteropServices;namespace PTDisk{[StructLayout(LayoutKind.Sequential)]public struct SPQ{public uint PropertyId;public uint QueryType;[MarshalAs(UnmanagedType.ByValArray,SizeConst=1)]public byte[] AdditionalParameters;}[StructLayout(LayoutKind.Sequential)]public struct DSPD{public uint Version;public uint Size;[MarshalAs(UnmanagedType.U1)]public bool IncursSeekPenalty;}public static class N{[DllImport(\"kernel32.dll\",SetLastError=true,CharSet=CharSet.Auto)]public static extern IntPtr CreateFile(string n,uint a,uint s,IntPtr sec,uint d,uint f,IntPtr t);[DllImport(\"kernel32.dll\",SetLastError=true)]public static extern bool DeviceIoControl(IntPtr h,uint c,ref SPQ i,uint isz,ref DSPD o,uint osz,ref uint r,IntPtr ov);[DllImport(\"kernel32.dll\",SetLastError=true)]public static extern bool CloseHandle(IntPtr h);}}'; Add-Type -TypeDefinition $sig -Language CSharp; $h=[PTDisk.N]::CreateFile('\\.\'+$dl+':',0,3,[IntPtr]::Zero,3,0,[IntPtr]::Zero); if($h -ne [IntPtr]::new(-1)){ $q=New-Object PTDisk.SPQ; $q.PropertyId=7; $q.QueryType=0; $q.AdditionalParameters=New-Object byte[] 1; $d=New-Object PTDisk.DSPD; $ret=0; if([PTDisk.N]::DeviceIoControl($h,0x2D1400,[ref]$q,[uint32][Runtime.InteropServices.Marshal]::SizeOf($q),[ref]$d,[uint32][Runtime.InteropServices.Marshal]::SizeOf($d),[ref]$ret,[IntPtr]::Zero)){ if($d.IncursSeekPenalty){ $t='hdd' }else{ $t='ssd' } }; [void][PTDisk.N]::CloseHandle($h) } }catch{}; if($t -eq 'unknown'){ try{ $n=(Get-Partition -DriveLetter $dl -ErrorAction Stop).DiskNumber; $pd=@(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$n }); if($pd.Count -ge 1){ $m=[string]$pd[0].MediaType; if($m -eq 'SSD'){ $t='ssd' } elseif($m -eq 'HDD'){ $t='hdd' } } }catch{} }; $t | Out-File -FilePath $env:PT_SD_RES -Encoding ASCII"
set "PT_SD_RES="
rem  The MediaType fallback inside the worker only runs when the IOCTL could not answer,
rem  and every failure path is caught - so it can only ever turn an "unknown" into a real
rem  answer, never the reverse. The IOCTL is the verified path; the fallback is untested
rem  belt-and-braces for a device that does not implement the query.
if exist "%_sdres%" for /f "usebackq tokens=1" %%T in ("%_sdres%") do set "SYSDISK=%%T"
del "%_sdres%" >nul 2>&1
call :Log "System disk media type: %SYSDISK%"
rem  Cache a real answer only. An "unknown" is a probe that FAILED - caching it would make one
rem  bad run permanent and silently downgrade the advisory forever after. Delayed expansion on
rem  the write because a device instance path contains & and \, which would otherwise be
rem  re-parsed as operators; the ^| is the literal separator the reader splits on.
if /i "%SYSDISK%"=="unknown" goto :eof
if not defined LOCALAPPDATA goto :eof
if not defined _sdkey goto :eof
if not exist "!_sddir!\" md "!_sddir!" >nul 2>&1
if not exist "!_sddir!\" goto :eof
> "!_sdcache!" echo !_sdkey!^|!SYSDISK!
call :Log "System disk media type cached -> !_sdcache!"
goto :eof

:DiskAdvisory
rem  Hardware advisory for the SysMain knob - same contract as :LaptopAdvisory: it warns
rem  and nothing else. Never blocks, never changes a prompt default, never alters what a
rem  preset applies. SysMain genuinely helps a mechanical disk, so the hint appears
rem  whenever the probe did NOT positively identify an SSD.
rem  A confirmed SSD gets a positive line rather than silence. The advisory contract is
rem  unchanged - this warns about nothing and blocks nothing - but silence was
rem  indistinguishable from "the probe never ran", which is exactly the doubt the whole
rem  probe exists to remove.
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
rem  Honest footnote for verbosestatus: Windows IGNORES it if DisableStatusMessages=1
rem  exists in the same key (documented). Read that back and tell the user the truth.
setlocal EnableDelayedExpansion
set "_dsm="
for /f "delims=" %%L in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "DisableStatusMessages" 2^>nul ^| findstr /I /C:"REG_DWORD"') do set "_dsm=%%L"
rem  findstr /C:"0x1" was a SUBSTRING match, so 0x10 / 0x1a / 0x1f would all have read as
rem  "enabled". Take the last token and let set /a parse the 0x form, the same way
rem  :_sraIdemDword compares DWORDs. Any nonzero value means the override is in force.
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
rem  Disables a small vetted set of telemetry scheduled tasks BY NAME, not by folder path.
rem  That is deliberate: schtasks /Change needs a task's full path, an unverified path
rem  fails quietly, and the run would still look clean while the task stayed enabled.
rem  Get-ScheduledTask finds each task wherever Windows keeps it, and the worker returns
rem  "found disabled checked" so the report below can tell "not present on this edition"
rem  apart from "could not disable" instead of calling either one a success.
rem  Only the DiskDiagnostic *DataCollector* is listed - the one that uploads drive SMART
rem  data. Never the DiskDiagnostic *Resolver*: that is what warns you about a dying disk.
set "_tkres=%TEMP%\pt_tasks_%RANDOM%.txt"
del "%_tkres%" >nul 2>&1
set "PT_TK_RES=%_tkres%"
set "PT_TK_NAMES=MareBackup|StartupAppTask|Microsoft-Windows-DiskDiagnosticDataCollector|MapsToastTask"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $names=@($env:PT_TK_NAMES -split '\|'); $found=0; $ok=0; foreach($n in $names){ if($n){ $ts=@(Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue); foreach($t in $ts){ $found++; try{ Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null; $ok++ }catch{} } } }; (''+$found+' '+$ok+' '+$names.Count) | Out-File -FilePath $env:PT_TK_RES -Encoding ASCII"
set "PT_TK_RES=" & set "PT_TK_NAMES="
set "_tkf=0" & set "_tko=0" & set "_tkn=0"
if exist "%_tkres%" for /f "usebackq tokens=1,2,3" %%a in ("%_tkres%") do ( set "_tkf=%%a" & set "_tko=%%b" & set "_tkn=%%c" )
del "%_tkres%" >nul 2>&1
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
rem  Disables NVIDIA telemetry scheduled tasks BY NAME PREFIX, not by hardcoded \TN path.
rem  Driver updates have changed the folder/GUID suffix; schtasks /Change /TN with a stale
rem  full path fails quietly while Summary still looked clean. Get-ScheduledTask finds each
rem  NvTmRep_ / NvTmMon_ / NvDriverUpdateCheckDaily_ task wherever it lives.
set "_nvres=%TEMP%\pt_nvtasks_%RANDOM%.txt"
del "%_nvres%" >nul 2>&1
set "PT_NV_RES=%_nvres%"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $ts=@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^(NvTmRep_|NvTmMon_|NvDriverUpdateCheckDaily_)' }); $found=$ts.Count; $ok=0; foreach($t in $ts){ try{ Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null; $ok++ }catch{} }; (''+$found+' '+$ok) | Out-File -FilePath $env:PT_NV_RES -Encoding ASCII"
set "PT_NV_RES="
set "_nvf=0" & set "_nvo=0"
if exist "%_nvres%" for /f "usebackq tokens=1,2" %%a in ("%_nvres%") do ( set "_nvf=%%a" & set "_nvo=%%b" )
del "%_nvres%" >nul 2>&1
if "!_nvf!"=="0" (
    echo   [SKIP] NVIDIA telemetry tasks: none found on this system.
    call :Log "TASKS nvidia: none present"
    goto :eof
)
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
rem  Blocks the telemetry service's outbound traffic by flipping Windows' OWN built-in
rem  DiagTrack firewall rule group from Allow to Block - the same thing Sophia does, and
rem  the reason this is not a hand-written netsh rule: the rules already ship with
rem  Windows, so there is nothing to invent, nothing to name, and nothing to clean up.
rem  The service is already stopped and disabled by :DoPrivacyCore; this is the
rem  belt-and-braces half for the case where a Windows update re-enables it.
rem  To undo, one line in an elevated PowerShell, no pipe needed:
rem      Set-NetFirewallRule -Group DiagTrack -Action Allow
set "_fwres=%TEMP%\pt_fw_%RANDOM%.txt"
del "%_fwres%" >nul 2>&1
set "PT_FW_RES=%_fwres%"
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $r=@(Get-NetFirewallRule -Group DiagTrack -ErrorAction SilentlyContinue); $n=0; foreach($x in $r){ try{ Set-NetFirewallRule -InputObject $x -Enabled True -Action Block -ErrorAction Stop; $n++ }catch{} }; (''+$n+' '+$r.Count) | Out-File -FilePath $env:PT_FW_RES -Encoding ASCII"
set "PT_FW_RES="
set "_fwn=0" & set "_fwc=0"
if exist "%_fwres%" for /f "usebackq tokens=1,2" %%a in ("%_fwres%") do ( set "_fwn=%%a" & set "_fwc=%%b" )
del "%_fwres%" >nul 2>&1
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
del "%TEMP%\pt_free.txt" >nul 2>&1
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $letter=if($env:SystemDrive){$env:SystemDrive.Substring(0,1)}else{'C'}; $d=Get-CimInstance Win32_LogicalDisk -Filter ('DeviceID='''+$letter+':'''); if(-not $d -or $null -eq $d.FreeSpace){exit 1}; $b=[int64]$d.FreeSpace; $t=[int64]$d.Size; $line=('{0}|{1:N1} GB free of {2:N1} GB on {3}:' -f $b,($b/1GB),($t/1GB),$letter); $line | Out-File (Join-Path $env:TEMP 'pt_free.txt') -Encoding ASCII"
if not exist "%TEMP%\pt_free.txt" goto :eof
for /f "usebackq tokens=1,* delims=|" %%A in ("%TEMP%\pt_free.txt") do (
    set "_FREE_BYTES=%%A"
    set "_FREE_HUMAN=%%B"
)
del "%TEMP%\pt_free.txt" >nul 2>&1
goto :eof
rem  HELPER: print free-space delta from _FREE_BEFORE / _FREE_AFTER byte strings
rem =====================================================================================
:FreeSpaceReport
if not defined _FREE_BEFORE goto _fsFail
if not defined _FREE_AFTER goto _fsFail
set "PT_FB=%_FREE_BEFORE%"
set "PT_FA=%_FREE_AFTER%"
del "%TEMP%\pt_freed.txt" >nul 2>&1
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try{ $b=[int64]$env:PT_FB; $a=[int64]$env:PT_FA; $d=$a-$b; if($d -ge 1048576){ $s='  [Disk] Freed about '+[math]::Round($d/1MB,1)+' MB  now '+[math]::Round($a/1GB,1)+' GB free.' } elseif($d -le -1048576){ $s='  [Disk] Free space dropped about '+[math]::Round((-$d)/1MB,1)+' MB  other activity; now '+[math]::Round($a/1GB,1)+' GB free.' } else { $s='  [Disk] No measurable change  now '+[math]::Round($a/1GB,1)+' GB free.' }; $s | Out-File (Join-Path $env:TEMP 'pt_freed.txt') -Encoding ASCII }catch{ exit 1 }"
set "PT_FB=" & set "PT_FA="
if exist "%TEMP%\pt_freed.txt" (
    type "%TEMP%\pt_freed.txt"
    del "%TEMP%\pt_freed.txt" >nul 2>&1
) else (
    echo   [Disk] Could not measure free-space change.
)
goto :eof

:_fsFail
echo   [Disk] Could not measure free space.
goto :eof
rem  HELPER: prove a cleanup root before anything is deleted under it
rem =====================================================================================
:CleanRoot
rem  %1 = environment variable NAME (used in the message)   %2 = its expanded value
rem  Sets _clean<NAME>=1 only when it is safe to delete underneath. Otherwise the flag is
rem  left undefined - so every gated delete in :DoCleanupCore simply does not run - and
rem  the reason is printed, so a skipped cleanup is visible instead of silent.
rem
rem  Three things have to hold, and each one maps to a real way this goes wrong:
rem    defined     - an unset variable expands to nothing, turning "%%VAR%%\*.*" into
rem                  "\*.*": the current drive root.
rem    a directory - a variable pointing at a deleted or never-created folder.
rem    not a root  - %%TEMP%%=C:\ is not hypothetical enough to ignore: it turns the very
rem                  first delete into "del /f /s /q ""C:\*.*""" with /s still attached.
rem  The value is compared with delayed expansion, so a folder containing ) or ^& - say
rem  "C:\Program Files (x86)\..." - cannot break out of the if-block either.
set "_crv=%~2"
if not defined _crv (
    echo   [SKIP] %~1 is not set in this environment - nothing under it was touched.
    call :Log "SKIP cleanup root %~1: undefined or empty"
    goto :eof
)
if not exist "!_crv!\" (
    echo   [SKIP] %~1 does not point at a folder that exists ^(!_crv!^) - nothing under it
    echo          was touched.
    call :Log "SKIP cleanup root %~1: not a directory: !_crv!"
    goto :eof
)
if "!_crv:~3!"=="" (
    echo   [SKIP] %~1 is a drive root ^(!_crv!^) - refusing to delete from the root of a
    echo          drive. Nothing under it was touched.
    call :Log "SKIP cleanup root %~1: drive root: !_crv!"
    goto :eof
)
set "_clean%~1=1"
goto :eof

:Run
rem %1 = full command line (echoed, logged, run via cmd /s /c)
set "_cmd=%~1"
rem  Log a quote-stripped copy of the command: with the embedded quotes gone, the whole line
rem  is captured intact, and there is nothing the log step could misread as a redirection.
set "_cmdlog=%_cmd:"=%"
echo   ^> %_cmd%
call :Log "EXEC: %_cmdlog%"
cmd /s /c "%_cmd%" >nul 2>&1
if errorlevel 1 (
    call :Log "FAIL: %_cmdlog%"
    rem  Count as a REAL failure only when this is a tracked action AND we are not elevated - the
    rem  command then definitely could not do its privileged work. When elevated, a nonzero exit is
    rem  usually benign: service already stopped, bcd value unset, or task absent - so counting it
    rem  would cry wolf. Best-effort callers like cleanup deletes never set _RUNTRACK.
    if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS+=1
) else ( call :Log "OK: %_cmdlog%" )
goto :eof

:RunLive
rem  %1 = full command line. Identical contract and bookkeeping to :Run, except the child
rem  output STREAMS to this console instead of being swallowed - for long-runners whose
rem  native progress display (DISM percent bar, SFC verification counter) is the only sign
rem  of life over several minutes. The log stays outcome-only (EXEC/OK/FAIL) either way.
set "_cmd=%~1"
set "_cmdlog=%_cmd:"=%"
echo   ^> %_cmd%
call :Log "EXEC: %_cmdlog%"
cmd /s /c "%_cmd%"
if errorlevel 1 (
    call :Log "FAIL: %_cmdlog%"
    rem  Same conservative failure-tally rule as :Run - see the comment there.
    if defined _RUNTRACK if "%_ELEV%"=="0" set /a _FAILS+=1
) else ( call :Log "OK: %_cmdlog%" )
goto :eof

:Summary
rem %1 = success phrase. Prints [OK] if no registry write failed since _FAILS was last reset,
rem otherwise an honest [WARN] with the count. :SafeRegAdd / :SafeRegDelete keep _FAILS current
rem across their endlocal, so this reflects the REAL outcome (e.g. not-elevated HKLM writes).
rem
rem  NOTE: this routine branches with goto, NOT an if(...)else(...) block, ON PURPOSE.
rem  cmd parses a parenthesised block as a whole at parse time, so the FIRST unescaped
rem  ")" inside %~1 would close the block early and crash the script ("was unexpected at
rem  this time"). Callers legitimately pass text like "(incl. Downfall/GDS)", so %~1 must
rem  never sit inside ( ). Keep it block-free - do not "tidy" this back into if/else.
if not defined _FAILS set "_FAILS=0"
if not defined _ELEV set "_ELEV=1"
if not "%_FAILS%"=="0" goto _sum_warn
echo [OK] %~1
goto _sum_done

:_sum_warn
echo [WARN] %~1 -- %_FAILS% change(s) could NOT be applied. See the [FAIL] line(s) above.
if "%_ELEV%"=="0" goto _sum_notelev
echo        This window is elevated, so those keys are protected or held by Windows. See the log.
goto _sum_done

:_sum_notelev
echo        This window is NOT elevated - close it and use Run as administrator, then retry.

:_sum_done
rem  Tracking is per-action: clear it here so a later untracked action (e.g. cleanup) can't inherit it.
set "_RUNTRACK="
goto :eof

:LaptopAdvisory
rem  Hardware advisory: shown before the confirm prompt of actions that typically hurt
rem  battery life / thermals on portables (power core, hibernate off, BCD dynamic-tick
rem  off, held timer resolution). Warning-only BY DESIGN: it never blocks, never changes
rem  a prompt default, never alters what a preset applies. The C# port shares this rule.
if /i not "%MACHINE%"=="laptop" goto :eof
echo   [ADVISORY] This machine looks like a laptop - this action typically costs battery
echo              life / heat there for little gain. It stays your call, and stays reversible.
goto :eof

:DesktopAdvisory
rem  Inverse case, currently for LargeSystemCache only - its prompt already says "can help
rem  some laptops, can hurt desktops"; this makes that line machine-aware.
if /i not "%MACHINE%"=="desktop" goto :eof
echo   [ADVISORY] This machine looks like a desktop - this option mainly helps some laptops
echo              and can hurt desktop performance.
goto :eof

:ApplyDns
rem %1 = friendly name ; uses %DNSSRV% as the PowerShell address list.
rem  The per-adapter catch{} used to swallow failures while the batch always printed [OK];
rem  now the child counts ok/fail adapters and returns an exit code, and :DnsResult reports
rem  the real outcome - so "no adapter" / not-elevated no longer masquerades as success.
echo Setting %~1 DNS (IPv4 + IPv6) on all active adapters...
call :Log "DNS -> %~1 : %DNSSRV%"
set "_dnsres=%TEMP%\pt_dnsres_%RANDOM%.txt"
del "%_dnsres%" >nul 2>&1
set "PT_DNSRES=%_dnsres%"
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
if exist "%_dnsres%" for /f "usebackq tokens=1,2" %%a in ("%_dnsres%") do ( set "_okN=%%a" & set "_failN=%%b" )
del "%_dnsres%" >nul 2>&1
if "%~1"=="0" (
    echo [OK] !_phrase! on !_okN! adapter^(s^), !_failN! failed.
    call :Log "OK: DNS - !_phrase! ok=!_okN! fail=!_failN!"
) else (
    echo [ERROR] !_phrase!: it failed on every active adapter. Make sure this window is
    echo         elevated and that you have an active network adapter, then try again.
    call :Log "FAIL: DNS - !_phrase! changed no adapters (fail=!_failN!)"
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
rem Backs up ONLY the single value being changed (not the whole key + subkeys), so a tweak
rem under a big key (Memory Management, Power, etc.) no longer makes a 100+ MB .reg export.
setlocal EnableDelayedExpansion
set "_key=%~1"
set "_val=%~2"
set "_type=%~3"
set "_data=%~4"
set "_desc=%~5"
echo   [REG] !_desc!
set "_ln="
for /f "delims=" %%L in ('reg query "!_key!" /v "!_val!" 2^>nul ^| findstr /I /C:"REG_"') do set "_ln=%%L"
rem  Idempotence (DWORD + REG_SZ): if the value already equals the target, skip the
rem  backup + write. A redundant re-apply would otherwise snapshot the already-tweaked
rem  value as its "prior" state and bury this value's true-original per-value undo.
if not defined _ln goto _sraDoWrite
if /i "!_type!"=="REG_DWORD" goto _sraIdemDword
if /i "!_type!"=="REG_SZ" goto _sraIdemSz
goto _sraDoWrite

:_sraIdemDword
for %%a in (!_ln!) do set "_curtok=%%a"
set /a _curdec=_curtok 2>nul
set /a _tgtdec=_data 2>nul
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
rem  %RANDOM%%RANDOM% (30-bit) instead of one %RANDOM%: two values under the same key share
rem  !_safe!, so a single 15-bit %RANDOM% could birthday-collide within one apply pass and one
rem  value's .reg backup would overwrite another's - losing that value's per-value undo.
set "_bkp=%BACKUP_DIR%\!_safe!_%RANDOM%%RANDOM%.reg"
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
rem  Same bargain as PATH/hosts: no landed undo file => refuse the live write.
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
set "_bkp=%BACKUP_DIR%\!_safe!_%RANDOM%%RANDOM%.reg"
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
rem  Non-ASCII value data can't survive the console-code-page echo into an ANSI .reg
rem  (it would restore as mojibake). Detect it and decline honestly below - the full
rem  reg export handles non-ASCII correctly. DWORD data is numeric, so this never trips it.
set "_naData="
if defined _rd echo(!_rd!| findstr /r "[^ -~]" >nul && set "_naData=1"
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
    rem  guard on "defined _rd": an EMPTY REG_SZ leaves _rd undefined, and !_rd:...! on an
    rem  undefined var returns the literal pattern (\=\\) - which would corrupt the .reg.
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
start "" /min /wait powershell -NoProfile -Command "& { try { Enable-ComputerRestore -Drive '%SystemDrive%\' -ErrorAction SilentlyContinue; Checkpoint-Computer -Description 'PerfTweaks' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop; 'Restore point created.' } catch { 'Restore point failed (System Protection off, or one was made in the last 24h): ' + $_.Exception.Message } } | Out-File -FilePath (Join-Path $env:TEMP 'pt_rp.txt') -Encoding ASCII"
if exist "%TEMP%\pt_rp.txt" ( type "%TEMP%\pt_rp.txt" & del "%TEMP%\pt_rp.txt" >nul 2>&1 )
goto :eof

:CreateRegBackup
echo Exporting HKLM and HKCU (this can take a minute)...
call :Log "Full registry export"
rem  Verify BOTH exports actually succeeded and produced a file before claiming success -
rem  errors are suppressed (>nul 2>&1), so a blind "[OK] Saved" could mask a failed/partial
rem  backup, and this export is the safety net the whole tool leans on for reversibility.
set "_rbHKLM=%BACKUP_DIR%\FullReg_HKLM_%RANDOM%.reg"
set "_rbHKCU=%BACKUP_DIR%\FullReg_HKCU_%RANDOM%.reg"
set "_rbOK=1"
reg export HKLM "%_rbHKLM%" /y >nul 2>&1
if errorlevel 1 set "_rbOK=0"
if not exist "%_rbHKLM%" set "_rbOK=0"
reg export HKCU "%_rbHKCU%" /y >nul 2>&1
if errorlevel 1 set "_rbOK=0"
if not exist "%_rbHKCU%" set "_rbOK=0"
if "%_rbOK%"=="1" (
    echo [OK] Saved to !BACKUP_DIR!
    call :Log "OK: full registry export -> %_rbHKLM% , %_rbHKCU%"
) else (
    echo [ERROR] Full registry backup FAILED or is incomplete - do NOT rely on it.
    echo         Make sure this window is elevated and that the folder is writable:
    echo         !BACKUP_DIR!
    call :Log "FAIL: full registry export (HKLM and/or HKCU missing or errored)"
)
goto :eof

:InstallAsarInto
rem %1 = base dir (e.g. %LocalAppData%\Discord) ; %2 = flavor label ; %3 = source .asar
setlocal EnableDelayedExpansion
set "_base=%~1"
set "_flav=%~2"
set "_src=%~3"
set "_res="
rem  Pick the HIGHEST-version app-* folder that has a resources\ dir. A plain ASCII "dir /o-n"
rem  sort is wrong at a version digit-rollover (app-1.0.9500 sorts ABOVE app-1.0.10015), which
rem  targeted the OLD build the launcher no longer runs. Version-aware sort via PowerShell.
set "PT_OABASE=%_base%"
set "_oares=%TEMP%\pt_oares_%RANDOM%.txt"
del "%_oares%" >nul 2>&1
set "PT_OARES=%_oares%"
start "" /min /wait powershell -NoProfile -Command "$b=$env:PT_OABASE;$d=Get-ChildItem -LiteralPath $b -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'resources') } | Sort-Object { try{[version]($_.Name -replace '^app-','')}catch{[version]'0.0'} } -Descending | Select-Object -First 1; if($d){ (Join-Path $d.FullName 'resources') | Out-File -FilePath $env:PT_OARES -Encoding ASCII }"
set "PT_OABASE=" & set "PT_OARES="
if exist "%_oares%" for /f "usebackq delims=" %%A in ("%_oares%") do set "_res=%%A"
del "%_oares%" >nul 2>&1
if not defined _res ( echo [SKIP] %_flav%: no app-*\resources folder. & endlocal & goto :eof )
set "_target=app.asar"
if exist "%_res%\_app.asar"     set "_target=_app.asar"
if exist "%_res%\app.orig.asar" set "_target=app.orig.asar"
if exist "%_res%\app.asar.orig" set "_target=app.asar.orig"
echo [%_flav%] Target: "%_res%\!_target!"
rem  Two backups of the original: one BESIDE the .asar (easy in-place restore) and one in the
rem  backup folder. Security software / Controlled Folder Access frequently blocks writes INTO
rem  Discord's program folder while still allowing Documents, so the in-folder .bak can fail
rem  silently. Verify which backup actually landed and report THAT, instead of always claiming
rem  the in-folder copy exists.
set "_localbak=%_res%\!_target!.bak"
set "_docbak=%BACKUP_DIR%\%_flav%_!_target!.bak"
set "_hadorig=0"
set "_bakloc="
if exist "%_res%\!_target!" (
    set "_hadorig=1"
    rem  WRITE-ONCE, both copies. This action is explicitly built to be re-run - line 1 of the
    rem  screen says so, because a Discord update reverts the patch - and the old unconditional
    rem  copy meant run 2 backed up OPENASAR over the stock app.asar. In BOTH places, since
    rem  _docbak is a fixed name too, so unlike hosts there was no surviving randomized copy.
    rem  "Restore the .bak" then restored OpenAsar onto OpenAsar and the original was gone
    rem  short of reinstalling Discord. The first capture is the only one certainly stock, so
    rem  it is the one to keep. (Same class as the redundant-re-apply bug :SafeRegAdd already
    rem  guards with its idempotence skip.)
    if not exist "!_localbak!" copy /y "%_res%\!_target!" "!_localbak!" >nul 2>&1
    if not exist "!_docbak!"   copy /y "%_res%\!_target!" "!_docbak!"  >nul 2>&1
    if exist "!_localbak!" set "_bakloc=local"
    if not exist "!_localbak!" if exist "!_docbak!" set "_bakloc=doc"
)
rem  Same bargain as :SafeRegAdd / :ApplyHosts / the PATH editor - which the backup comment
rem  above already claimed to follow, while the copy below ran unconditionally. With an
rem  original present and NO backup landed, refuse the write instead of overwriting it and
rem  then advising a Discord reinstall.
if "!_hadorig!"=="1" if not defined _bakloc (
    echo [FAIL] %_flav%: NOT installed - no backup of the original could be saved. Discord's
    echo        folder and the backup folder were both blocked ^(antivirus / Controlled Folder
    echo        Access^). The existing .asar is untouched; allow writes to either and re-run.
    call :Log "ABORT: OpenAsar %_flav% - no backup landed, asar left intact"
    endlocal & set /a _OAFAIL+=1 & goto :eof
)
copy /y "%_src%" "%_res%\!_target!" >nul
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
    echo        to:   "%_res%\!_target!"
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
echo ==============================  AUTO-APPLY PRESETS  ===============================
echo  A preset applies a defined group of tweaks at once and saves ONE JSON backup of the
echo  registry values it changes (manual menu actions still save individual .reg files).
echo  Power-plan / DNS / BCD / service changes revert from their own menu items.
echo -----------------------------------------------------------------------------------
echo     1.  Light     (temp cleanup, privacy, TCP tweaks, DNS)
echo     2.  Moderate  (recommended safe set + power plan + OpenAsar)
echo     3.  Heavy     (most tweaks; NO repair / NO stack reset / NO debloat / NO mitigations)
echo     4.  Custom    (load a user preset from the sincript_presets folder)
echo     5.  Restore from a preset backup (JSON)
echo     0.  Back
echo ===================================================================================

:MenuPresets_ask
set "sel="
set /p "sel=Choose: "
if not defined sel goto MenuPresets_ask
if "%sel%"=="1" goto PresetLight
if "%sel%"=="2" goto PresetModerate
if "%sel%"=="3" goto PresetHeavy
if "%sel%"=="4" goto PresetCustom
if "%sel%"=="5" goto RestorePresetJson
if "%sel%"=="0" goto MainMenu
goto MenuPresets
rem ---------- preset capture helpers ----------
:PresetBegin
rem %1 = preset label used in the backup filename
set "_pname=%~1"
set "_PWBAK_FILE="
rem  Reset the failure tally so each preset's :Summary reflects only THIS preset's registry writes.
rem  (Not tracking _RUNTRACK here: presets also run cleanup deletes, whose failures are benign.)
set "_FAILS=0"
set "PRESET_JSON=%BACKUP_DIR%\Preset_%_pname%_%RANDOM%%RANDOM%.json"
set "PRESET_JSON_TMP=%PRESET_JSON%.tmp"
break>"%PRESET_JSON_TMP%"
if not exist "%PRESET_JSON_TMP%" (
    echo [ERROR] Could not create the preset JSON backup in "%BACKUP_DIR%".
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
call :Log "PRESET end -> %PRESET_JSON%"
set "PT_TMP=%PRESET_JSON_TMP%"
set "PT_FINAL=%PRESET_JSON%"
start "" /min /wait powershell -NoProfile -Command "$t=$env:PT_TMP;$f=$env:PT_FINAL;if(Test-Path -LiteralPath $t){$o=@(Get-Content -LiteralPath $t | Where-Object {$_ -match '\S'});Set-Content -LiteralPath $f -Value ('['+($o -join ',')+']') -Encoding ASCII}else{Set-Content -LiteralPath $f -Value '[]' -Encoding ASCII}"
del "%PRESET_JSON_TMP%" >nul 2>&1
set "PRESET_LAST=%PRESET_JSON%"
set "PT_TMP="
set "PT_FINAL="
set "PRESET_JSON="
set "PRESET_JSON_TMP="
goto :eof

:PresetDnsChoice
rem  interactive DNS picker for the built-in presets (the user asked to be prompted)
echo.
echo  DNS for this preset:   1=Cloudflare   2=Google   3=Quad9   4=Skip (leave as-is)
set "_dc="
set /p "_dc=Choose DNS [1-4]: "
if "%_dc%"=="1" goto _pdnscf
if "%_dc%"=="2" goto _pdnsgg
if "%_dc%"=="3" goto _pdnsq9
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
rem  Clear first: DNSSRV is global, so an address list left over from an earlier call would
rem  survive the three name tests below and get applied instead of the value asked for.
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
call :SafeRegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex" REG_DWORD 4294967295 "Network throttling off"
goto :eof

:DoWin32_42
call :SafeRegAdd "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" REG_DWORD 42 "Win32PrioritySeparation = 42 (0x2A, short fixed quantum)"
goto :eof

:DoWin32_38
rem  0x26 = short, VARIABLE quantum, strong foreground boost - the value Windows writes
rem  for the "Programs" radio. Foreground app gets the longer quantum.
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
rem  Was inside :DoPrivacyCore, which made it ride "Apply recommended safe set" (documented
rem  "no prompts") and every preset including LIGHT (documented "Nothing risky") without
rem  appearing on any screen or in the README. DisableFileSyncNGSC is not a telemetry knob:
rem  it is the ADMX policy "Prevent the usage of OneDrive for file storage", so it stops the
rem  client syncing altogether. That is a legitimate thing to want and a bad thing to get by
rem  surprise - especially since BACKUP_DIR deliberately resolves OneDrive-redirected
rem  Documents, so the core could disable sync for the very folder holding its own undo
rem  files. Opt-in only now, same shape as :DoGameBarOff / :DoEdgeNudgesOff.
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
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try{ Disable-MMAgent -MemoryCompression; Disable-MMAgent -PageCombining; exit 0 }catch{ exit 1 }"
if errorlevel 1 (
    echo         [FAIL] Memory compression / page combining was NOT disabled.
    call :Log "FAIL: Disable-MMAgent (preset)"
    set /a _FAILS+=1
) else (
    call :Log "OK: Disable-MMAgent (preset)"
)
goto :eof

:DoGpuTelemetryOff
if /i "%GPU%"=="amd" call :SafeRegAdd "HKLM\SOFTWARE\AMD\CN" "UserExperienceProgram" REG_DWORD 0 "AMD User Experience Program opt-out"
if /i not "%GPU%"=="nvidia" goto :eof
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
rem  Non-interactive OpenAsar install for presets: use a bundled app.asar if present,
rem  otherwise download the latest nightly. No prompts (Apps & files has the interactive one).
set "_SRC="
if exist "%SCRIPT_DIR%app.asar" set "_SRC=%SCRIPT_DIR%app.asar"
if defined _SRC goto _oasInstall
echo   ^> OpenAsar: no bundled app.asar found - downloading the latest nightly...
call :Log "PRESET OpenAsar: downloading nightly"
set "PT_OA=%TEMP%\openasar_nightly.asar"
del "%PT_OA%" >nul 2>&1
start "" /min /wait powershell -NoProfile -Command "try{Invoke-WebRequest -Uri 'https://github.com/GooseMod/OpenAsar/releases/download/nightly/app.asar' -OutFile $env:PT_OA -UseBasicParsing}catch{exit 1}"
rem  Same partial-download guard as the interactive path: exit code first, then existence.
if errorlevel 1 del "%PT_OA%" >nul 2>&1
if not exist "%PT_OA%" (
    echo [ERROR] OpenAsar download failed - skipping. Put app.asar next to the script and retry.
    call :Log "PRESET OpenAsar: download failed"
    set "PT_OA="
    goto :eof
)
set "_SRC=%PT_OA%"
set "PT_OA="

:_oasInstall
echo   ^> Installing OpenAsar into Discord (closing Discord first)...
call :Log "PRESET OpenAsar install from !_SRC!"
taskkill /f /im Discord.exe       >nul 2>&1
taskkill /f /im DiscordPTB.exe    >nul 2>&1
taskkill /f /im DiscordCanary.exe >nul 2>&1
timeout /t 2 >nul
set "_DONE=0"
set "_OAFAIL=0"
for %%F in (Discord DiscordPTB DiscordCanary) do if exist "%LocalAppData%\%%F\" call :InstallAsarInto "%LocalAppData%\%%F" "%%F" "!_SRC!"
if exist "%TEMP%\openasar_nightly.asar" del /f /q "%TEMP%\openasar_nightly.asar" >nul 2>&1
if "%_DONE%"=="0" echo [SKIP] OpenAsar: no Discord install with a resources\app.asar found.
if not "%_OAFAIL%"=="0" echo   [WARN] %_OAFAIL% Discord install^(s^) could NOT be updated - see above.
if exist "%LocalAppData%\Discord\Update.exe" start "" "%LocalAppData%\Discord\Update.exe" --processStart Discord.exe
goto :eof
rem =====================================================================================
rem  PRESET: LIGHT
rem =====================================================================================
:PresetLight
cls
call :Logo
echo ==============================  PRESET: LIGHT  ====================================
echo  Applies: temp/log cleanup, privacy ^& telemetry hardening, TCP tuning, and a DNS
echo  choice. All registry changes go into ONE JSON backup. Reversible.
echo ===================================================================================
set "_c="
set /p "_c=Apply the LIGHT preset? (Y/N): "
if /i not "%_c%"=="Y" goto MenuPresets
call :PresetBegin light
if errorlevel 1 goto MenuPresets
call :DoCleanupCore
call :DoPrivacyCore
call :DoNetworkCore
call :PresetDnsChoice
call :PresetEnd
echo.
call :Summary "LIGHT preset applied."
echo      Registry backup: %PRESET_LAST%
echo      Reboot recommended.
pause
goto MenuPresets
rem =====================================================================================
rem  PRESET: MODERATE  (the recommended safe set + power + OpenAsar)
rem =====================================================================================
:PresetModerate
cls
call :Logo
echo =============================  PRESET: MODERATE  ==================================
echo  Applies the recommended safe set - cleanup, privacy, performance, power and network
echo  core tweaks - then offers to install OpenAsar. Registry changes go into ONE JSON
echo  backup. This is the same set as "Apply recommended safe set", plus OpenAsar.
echo ===================================================================================
call :LaptopAdvisory
set "_rp=Y"
set /p "_rp=Create a System Restore Point first? (Y/N): "
if /i "%_rp%"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Apply the MODERATE preset? (Y/N): "
if /i not "%_c%"=="Y" goto MenuPresets
call :PresetBegin moderate
if errorlevel 1 goto MenuPresets
call :DoCleanupCore
call :DoPrivacyCore
call :DoPerformanceCore
call :DoPowerCore
call :DoNetworkCore
call :PresetEnd
echo.
call :Summary "MODERATE preset applied."
echo      Registry backup: %PRESET_LAST%
echo.
set "_oa="
set /p "_oa=Also install OpenAsar into Discord now? (Y/N): "
if /i "%_oa%"=="Y" call :DoOpenAsarSilent
echo.
echo Reboot recommended.
pause
goto MenuPresets
rem =====================================================================================
rem  PRESET: HEAVY  (aggressive but reversible; no mitigations / repair / reset / debloat)
rem =====================================================================================
:PresetHeavy
cls
call :Logo
echo ==============================  PRESET: HEAVY  ====================================
echo  Aggressive but reversible. Applies the safe set PLUS: SystemResponsiveness=0,
echo  network throttling off, Win32PrioritySeparation=42, Game Mode off, Nagle/ACK off,
echo  IPv6 off, NVMe flags, GPU telemetry off (if applicable), BCD timer tweaks and
echo  memory compression off. It does NOT touch CPU mitigations, system repair, the
echo  network-stack reset, or debloat. Registry changes go into ONE JSON backup; the
echo  non-registry parts (DNS / BCD / memory compression) revert from their own menus.
echo  A REBOOT is required afterwards.
echo ===================================================================================
call :LaptopAdvisory
set "_rp=Y"
set /p "_rp=Create a System Restore Point first? (strongly recommended) (Y/N): "
if /i "%_rp%"=="Y" call :CreateRestorePoint
set "_c="
set /p "_c=Apply the HEAVY preset? (Y/N): "
if /i not "%_c%"=="Y" goto MenuPresets
call :PresetBegin heavy
if errorlevel 1 goto MenuPresets
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
call :PresetDnsChoice
call :PresetEnd
echo.
call :Summary "HEAVY preset applied."
echo      Registry backup: %PRESET_LAST%
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
echo ===============================  CUSTOM PRESET  ===================================
set "_pdir=%SCRIPT_DIR%sincript_presets"
if not exist "%_pdir%\" (
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
for %%F in ("%_pdir%\*.preset") do (
    set /a _pn+=1
    set "_pf[!_pn!]=%%~fF"
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
echo ===================================================================================

:PresetCustom_ask
set "sel="
set /p "sel=Choose a preset file: "
if not defined sel goto PresetCustom_ask
if "%sel%"=="0" goto MenuPresets
set "_pfile="
for /l %%I in (1,1,%_pn%) do if "%sel%"=="%%I" set "_pfile=!_pf[%%I]!"
if not defined _pfile goto PresetCustom_ask
set "_pshow="
for /l %%I in (1,1,%_pn%) do if "%sel%"=="%%I" set "_pshow=!_pnm[%%I]!"
set "_pbase="
for %%F in ("%_pfile%") do set "_pbase=%%~nF"
set "_pbase=%_pbase: =_%"
rem ---- validate: read each key=value once, record valid directives, collect problems ----
set "_perr=0"
set "_pgood=0"
set "_perrfile=%TEMP%\sincript_preset_err_%RANDOM%.txt"
break>"%_perrfile%"
for %%K in (CLEANUP PRIVACY PERFORMANCE POWER NETWORK OPENASAR GAMEMODE GAMEBAR EDGE SYSRESP NETTHROTTLE LARGECACHE MINPROC BCDTIMERS IPV6 MEMCOMPRESS NVME GPUTEL NAGLE WIN32 DNS) do set "_P_%%K="
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%_pfile%") do call :PresetCheckLine "%%A" "%%B"
cls
call :Logo
echo ===============================  CUSTOM PRESET  ===================================
echo  Preset file:            %_pshow%
echo  Recognized directives:  %_pgood%
echo  Problems:               %_perr%
if %_perr% gtr 0 (
    echo -----------------------------------------------------------------------------------
    type "%_perrfile%"
)
del "%_perrfile%" >nul 2>&1
echo ===================================================================================
if %_pgood% geq 1 goto _pcHaveValid
echo [ABORT] No valid directives found - nothing to apply.
echo         Check the file against the key list in the README.
pause
goto MenuPresets

:_pcHaveValid
if %_perr% lss 1 goto _pcReady
set "_cc="
set /p "_cc=Apply the valid directives and skip the problems? (Y/N): "
if /i not "%_cc%"=="Y" goto MenuPresets

:_pcReady
set "_rp=Y"
set /p "_rp=Create a System Restore Point first? (Y/N): "
if /i "%_rp%"=="Y" call :CreateRestorePoint
call :PresetBegin custom_%_pbase%
if errorlevel 1 goto MenuPresets
if defined _P_CLEANUP     call :DoCleanupCore
if defined _P_PRIVACY     call :DoPrivacyCore
if defined _P_PERFORMANCE call :DoPerformanceCore
rem  power_plan only steers WHICH plan; it does not by itself switch one. Applied before
rem  the cores so :DoPowerPlanSwitch sees it.
if defined _P_PWPLAN      set "_PWPLAN=%_P_PWPLAN%"
if defined _P_POWER       call :DoPowerCore
rem  power=1 already includes the timeouts, so skip the standalone key rather than run the
rem  same six powercfg calls twice and print a second set of lines for no change.
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
call :PresetEnd
echo.
call :Summary "Custom preset applied."
echo      Registry backup: %PRESET_LAST%
echo      Reboot recommended.
pause
goto MenuPresets

:PresetCheckLine
rem %1 = key   %2 = value   (validates + records a directive; logs problems)
set "_k=%~1"
set "_v=%~2"
if not defined _k goto :eof
if "%_k:~0,1%"==";" goto :eof
if defined _v if "!_v:~-1!"==" " set "_v=!_v:~0,-1!"
set "_match="
if /i "%_k%"=="cleanup"               ( set "_match=1" & call :PVok CLEANUP "%_v%" 1 )
if /i "%_k%"=="privacy"               ( set "_match=1" & call :PVok PRIVACY "%_v%" 1 )
if /i "%_k%"=="performance"           ( set "_match=1" & call :PVok PERFORMANCE "%_v%" 1 )
if /i "%_k%"=="power"                 ( set "_match=1" & call :PVok POWER "%_v%" 1 )
if /i "%_k%"=="power_timeouts"        ( set "_match=1" & call :PVok PWTIMEOUTS "%_v%" 1 )
if /i "%_k%"=="network"               ( set "_match=1" & call :PVok NETWORK "%_v%" 1 )
if /i "%_k%"=="openasar"              ( set "_match=1" & call :PVok OPENASAR "%_v%" 1 )
if /i "%_k%"=="gamemode_off"          ( set "_match=1" & call :PVok GAMEMODE "%_v%" 1 )
if /i "%_k%"=="gamebar_off"           ( set "_match=1" & call :PVok GAMEBAR "%_v%" 1 )
if /i "%_k%"=="edge_nudges_off"       ( set "_match=1" & call :PVok EDGE "%_v%" 1 )
if /i "%_k%"=="onedrive_off"         ( set "_match=1" & call :PVok ONEDRIVE "%_v%" 1 )
if /i "%_k%"=="systemresponsiveness"  ( set "_match=1" & call :PVok SYSRESP "%_v%" 0 )
if /i "%_k%"=="networkthrottling_off" ( set "_match=1" & call :PVok NETTHROTTLE "%_v%" 1 )
if /i "%_k%"=="largesystemcache"      ( set "_match=1" & call :PVok LARGECACHE "%_v%" 1 )
if /i "%_k%"=="minprocstate5"         ( set "_match=1" & call :PVok MINPROC "%_v%" 1 )
if /i "%_k%"=="bcdtimers"             ( set "_match=1" & call :PVok BCDTIMERS "%_v%" 1 )
if /i "%_k%"=="ipv6_off"              ( set "_match=1" & call :PVok IPV6 "%_v%" 1 )
if /i "%_k%"=="memcompress_off"       ( set "_match=1" & call :PVok MEMCOMPRESS "%_v%" 1 )
if /i "%_k%"=="nvme_flags"            ( set "_match=1" & call :PVok NVME "%_v%" 1 )
if /i "%_k%"=="gpu_telemetry_off"     ( set "_match=1" & call :PVok GPUTEL "%_v%" 1 )
if /i "%_k%"=="nagle_off"             ( set "_match=1" & call :PVok NAGLE "%_v%" 1 )
if /i "%_k%"=="win32priority"         ( set "_match=1" & call :PChkWin32 "%_v%" )
if /i "%_k%"=="dns"                   ( set "_match=1" & call :PChkDns "%_v%" )
if /i "%_k%"=="power_plan"            ( set "_match=1" & call :PChkPlan "%_v%" )
if not defined _match (
    >>"%_perrfile%" echo   ignored - unknown key: %_k%
    set /a _perr+=1
)
goto :eof

:PVok
rem %1 = directive var name   %2 = value   %3 = expected value (1 or 0)
if "%~2"=="%~3" (
    set "_P_%~1=1"
    set /a _pgood+=1
) else (
    >>"%_perrfile%" echo   bad value "%~2" for key %_k% ^(expected %~3^)
    set /a _perr+=1
)
goto :eof

:PChkWin32
if "%~1"=="42" ( set "_P_WIN32=42" & set /a _pgood+=1 & goto :eof )
if "%~1"=="38" ( set "_P_WIN32=38" & set /a _pgood+=1 & goto :eof )
if "%~1"=="26" ( set "_P_WIN32=26" & set /a _pgood+=1 & goto :eof )
if "%~1"=="2"  ( set "_P_WIN32=2"  & set /a _pgood+=1 & goto :eof )
>>"%_perrfile%" echo   bad value "%~1" for key win32priority (use 42, 38, 26 or 2)
set /a _perr+=1
goto :eof

:PChkPlan
rem  Explicit plan choice for custom presets. Without it, power=1 means Ultimate, which is
rem  a workstation plan Windows hides on battery-powered machines - fine on a desktop, and
rem  the thing to override on a laptop, especially one running an undervolt.
if /i "%~1"=="ultimate" ( set "_P_PWPLAN=ultimate" & set /a _pgood+=1 & goto :eof )
if /i "%~1"=="high"     ( set "_P_PWPLAN=high"     & set /a _pgood+=1 & goto :eof )
if /i "%~1"=="balanced" ( set "_P_PWPLAN=balanced" & set /a _pgood+=1 & goto :eof )
>>"%_perrfile%" echo   bad value "%~1" for key power_plan (use ultimate, high or balanced)
set /a _perr+=1
goto :eof

:PChkDns
if /i "%~1"=="cloudflare" ( set "_P_DNS=cloudflare" & set /a _pgood+=1 & goto :eof )
if /i "%~1"=="google"     ( set "_P_DNS=google"     & set /a _pgood+=1 & goto :eof )
if /i "%~1"=="quad9"      ( set "_P_DNS=quad9"      & set /a _pgood+=1 & goto :eof )
rem  Also accept a literal IPv4, so an unattended preset can point at a router or Pi-hole
rem  instead of only the three bundled providers. Same validator the interactive screen
rem  uses, so a preset cannot smuggle in something the menu would have rejected.
set "_IPCHK=%~1"
call :_ip4_ok && ( set "_P_DNS=%~1" & set /a _pgood+=1 & goto :eof )
>>"%_perrfile%" echo   bad value "%~1" for key dns (use cloudflare, google, quad9 or an IPv4 address)
set /a _perr+=1
goto :eof
rem =====================================================================================
rem  RESTORE from a preset JSON backup (registry values only)
rem =====================================================================================
:RestorePresetJson
cls
call :Logo
echo =====================  Restore from a preset backup (JSON)  =======================
echo  Restores the registry values a preset changed, from one of its JSON backups.
echo  Power-plan, DNS, BCD and service changes are reverted from their own menu items.
echo ===================================================================================
set "_rn=0"
for /f "delims=" %%F in ('dir /b /o-d "%BACKUP_DIR%\Preset_*.json" 2^>nul') do (
    set /a _rn+=1
    set "_rf[!_rn!]=%BACKUP_DIR%\%%F"
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
echo ===================================================================================

:RestorePresetJson_ask
set "sel="
set /p "sel=Choose a backup to restore: "
if not defined sel goto RestorePresetJson_ask
if "%sel%"=="0" goto MenuBackups
set "_rfile="
for /l %%I in (1,1,%_rn%) do if "%sel%"=="%%I" set "_rfile=!_rf[%%I]!"
if not defined _rfile goto RestorePresetJson_ask
echo.
echo  About to restore registry values from:
echo     %_rfile%
set "_cc="
set /p "_cc=Proceed with the restore? (Y/N): "
if /i not "%_cc%"=="Y" goto MenuBackups
call :Log "PRESET restore from %_rfile%"
set "PT_FILE=%_rfile%"
set "_prres=%TEMP%\pt_prres_%RANDOM%.txt"
del "%_prres%" >nul 2>&1
set "PT_PRRES=%_prres%"
rem  Child counts restored/failed values (an already-absent delete counts as success) and writes
rem  "ok fail badjson" so the batch can report the REAL outcome instead of an unconditional [OK].
start "" /min /wait powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue';$p=$env:PT_FILE;$ok=0;$fail=0;try{$items=Get-Content -Raw -LiteralPath $p | ConvertFrom-Json}catch{'0 0 1'|Out-File -FilePath $env:PT_PRRES -Encoding ASCII;exit 2};foreach($it in $items){ if(-not $it.present){ reg delete $it.key /v $it.name /f 2>$null | Out-Null; if($LASTEXITCODE -eq 0){$ok++}else{ reg query $it.key /v $it.name 2>$null | Out-Null; if($LASTEXITCODE -ne 0){$ok++}else{$fail++} } } elseif($it.oldtype -eq 'REG_DWORD'){ reg add $it.key /v $it.name /t REG_DWORD /d $it.olddata /f 2>$null | Out-Null; if($LASTEXITCODE -eq 0){$ok++}else{$fail++} } elseif($it.oldtype -eq 'REG_SZ' -and $it.restorable -ne $false){ $rk=$it.key -replace '^HKLM\\','HKLM:\' -replace '^HKCU\\','HKCU:\' -replace '^HKCR\\','Registry::HKEY_CLASSES_ROOT\' -replace '^HKU\\','Registry::HKEY_USERS\' -replace '^HKCC\\','Registry::HKEY_CURRENT_CONFIG\'; try{ if(-not (Test-Path -LiteralPath $rk)){New-Item -Path $rk -Force -ErrorAction Stop|Out-Null}; Set-ItemProperty -LiteralPath $rk -Name $it.name -Value ([string]$it.olddata) -Type String -ErrorAction Stop; $ok++ }catch{$fail++} } }; (''+$ok+' '+$fail+' 0')|Out-File -FilePath $env:PT_PRRES -Encoding ASCII; if($fail -gt 0){exit 1}else{exit 0}"
set "_prrc=%errorlevel%"
set "PT_FILE=" & set "PT_PRRES="
set "_okN=0" & set "_failN=0" & set "_badjson=0"
if exist "%_prres%" for /f "usebackq tokens=1,2,3" %%a in ("%_prres%") do ( set "_okN=%%a" & set "_failN=%%b" & set "_badjson=%%c" )
del "%_prres%" >nul 2>&1
echo.
if "!_badjson!"=="1" (
    echo [ERROR] That backup file could not be read as valid JSON. Nothing was changed.
    call :Log "FAIL: preset restore - bad JSON %_rfile%"
) else if "!_prrc!"=="0" (
    echo [OK] Restore finished: !_okN! value^(s^) put back, 0 failed. A reboot is recommended.
    call :Log "OK: preset restore ok=!_okN! fail=!_failN!"
) else (
    echo [WARN] Restore incomplete: !_okN! restored, !_failN! FAILED ^(not elevated, or a protected key^).
    echo        Re-run elevated if HKLM values did not restore. Details are in the log.
    call :Log "FAIL: preset restore ok=!_okN! fail=!_failN!"
)
echo      Reminder: revert DNS, power plan and BCD timers from their own menu items if needed.
pause
goto MenuBackups
rem =====================================================================================
rem  RESTORE a single per-value .reg backup (re-import one of the tiny tweak backups)
rem =====================================================================================
:RestoreRegBackup
cls
call :Logo
echo ====================  Restore a single value backup (.reg)  =======================
echo  Re-imports one of the small per-value .reg backups this script writes before each
echo  registry tweak - the same files you can also double-click in the backup folder.
echo  Full-registry exports (FullReg_*.reg) are not listed here; import those manually.
echo ===================================================================================
set "_qn=0"
for /f "delims=" %%F in ('dir /b /a-d /o-d "%BACKUP_DIR%\*.reg" 2^>nul ^| findstr /I /V /B "FullReg_"') do (
    set /a _qn+=1
    set "_qf[!_qn!]=%BACKUP_DIR%\%%F"
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
echo ===================================================================================

:RestoreRegBackup_ask
set "sel="
set /p "sel=Choose a backup to restore: "
if not defined sel goto RestoreRegBackup_ask
if "%sel%"=="0" goto MenuBackups
set "_qfile="
set "_qshow="
for /l %%I in (1,1,%_qn%) do if "%sel%"=="%%I" set "_qfile=!_qf[%%I]!"
for /l %%I in (1,1,%_qn%) do if "%sel%"=="%%I" set "_qshow=!_qnm[%%I]!"
if not defined _qfile goto RestoreRegBackup_ask
echo.
echo  This backup will put the following value(s) back to their saved state:
echo -----------------------------------------------------------------------------------
type "%_qfile%"
echo -----------------------------------------------------------------------------------
echo  A line like  "Name"=-  means the value did not exist before and will be removed.
set "_cc="
set /p "_cc=Import this .reg backup now? (Y/N): "
if /i not "%_cc%"=="Y" goto MenuBackups
echo   ^> Importing "%_qshow%"...
call :Log "REG restore (import) from %_qshow%"
reg import "%_qfile%" >nul 2>&1
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
echo ======================  Revert power settings (undo file)  ========================
echo  Runs one of the PowerPlan_*.bat undo files sincript writes before it changes your
echo  power scheme or its sleep / disk timeouts. Each one re-activates the scheme that
echo  was current at the time and puts that scheme's timeouts back, in seconds.
echo  Hibernation, minimum processor state and CPU power throttling are separate items -
echo  see "Reverting changes" in the README.
echo ===================================================================================
set "_pn=0"
for /f "delims=" %%F in ('dir /b /a-d /o-d "%BACKUP_DIR%\PowerPlan_*.bat" 2^>nul') do (
    set /a _pn+=1
    set "_pf[!_pn!]=%BACKUP_DIR%\%%F"
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
echo ===================================================================================

:RestorePowerBackup_ask
set "sel="
set /p "sel=Choose a backup to run: "
if not defined sel goto RestorePowerBackup_ask
if "%sel%"=="0" goto MenuBackups
set "_pfile="
for /l %%I in (1,1,%_pn%) do if "%sel%"=="%%I" set "_pfile=!_pf[%%I]!"
if not defined _pfile goto RestorePowerBackup_ask
echo.
echo  About to run:
echo     %_pfile%
set "_cc="
set /p "_cc=Proceed? (Y/N): "
if /i not "%_cc%"=="Y" goto MenuBackups
set "_FAILS=0" & set "_RUNTRACK=1"
call :Log "POWER revert from %_pfile%"
rem  /q suppresses the undo file's own pause - it is there for double-clicking from Explorer.
call "%_pfile%" /q
if errorlevel 1 (
    echo [WARN] The undo file reported a failure. Run it elevated, or open Control Panel ^>
    echo        Power Options and set the plan back by hand.
    call :Log "FAIL: power revert %_pfile%"
) else (
    echo [OK] Power settings restored from the backup.
    call :Log "OK: power revert %_pfile%"
)
echo.
echo  Current plan now:
for /f "tokens=*" %%i in ('powercfg /getactivescheme') do echo    %%i
pause
goto MenuBackups

:ManageBackups
cls
call :Logo
echo ==========================  Manage backup folder  =================================
echo  Everything this script backs up lives in one folder. The small per-value .reg files
echo  and preset .json files are the precise undo data and are left untouched here; only
echo  the large full-registry exports - which pile up each time you run a full registry
echo  backup - can be pruned, and even then the newest pair is always kept.
echo ===================================================================================
set "_cntAllReg=0"
for %%Z in ("!BACKUP_DIR!\*.reg") do set /a _cntAllReg+=1
set "_cntFull=0" & set "_mbFull=0"
for %%Z in ("!BACKUP_DIR!\FullReg_*.reg") do call :_mbAddFull "%%~zZ"
set /a _cntVal=_cntAllReg-_cntFull
if !_cntVal! lss 0 set "_cntVal=0"
set "_cntJson=0"
for %%Z in ("!BACKUP_DIR!\Preset_*.json") do set /a _cntJson+=1
set "_cntHosts=0"
for %%Z in ("!BACKUP_DIR!\hosts_*.bak") do set /a _cntHosts+=1
set "_cntLog=0"
for %%Z in ("!BACKUP_DIR!\PerfTweaks_*.log") do set /a _cntLog+=1
echo  Folder:  !BACKUP_DIR!
echo  Log now: !LOGFILE!
echo -----------------------------------------------------------------------------------
echo   Per-value .reg backups ^(single-value undo^) : !_cntVal!
echo   Full registry exports  ^(HKLM/HKCU^)         : !_cntFull!   ^(~!_mbFull! MB^)
echo   Preset backups ^(.json^)                     : !_cntJson!
echo   hosts backups  ^(.bak^)                      : !_cntHosts!
echo   Logs ^(.log^)                                : !_cntLog!
echo ===================================================================================
set "_c="
set /p "_c=Open this folder in Explorer now? (Y/N): "
if /i "%_c%"=="Y" start "" "!BACKUP_DIR!"
if !_cntFull! leq 2 goto _mbDone
echo.
echo  You have !_cntFull! full registry exports ^(~!_mbFull! MB^). The newest export alone is
echo  enough for a full restore, so the older ones are mostly just using disk space.
set "_c2="
set /p "_c2=Delete the older full exports, keeping the newest 2 files? (Y/N): "
if /i not "%_c2%"=="Y" goto _mbDone
set "_idx=0" & set "_delN=0"
for /f "delims=" %%F in ('dir /b /a-d /o-d "!BACKUP_DIR!\FullReg_*.reg" 2^>nul') do call :_mbPrune "%%F"
call :Log "MANAGE pruned !_delN! old full registry exports"
echo  [OK] Deleted !_delN! older full export^(s^); kept the 2 most recent.

:_mbDone
echo.
pause
goto MenuBackups

:_mbAddFull
rem  %1 = file size in bytes of one full export; updates the running count + MB total
set /a _cntFull+=1
set /a _mbFull+=%~1/1048576
goto :eof

:_mbPrune
rem  %1 = bare filename (caller feeds newest-first); keeps the first 2, deletes the rest
set /a _idx+=1
if !_idx! leq 2 goto :eof
del /f /q "!BACKUP_DIR!\%~1" >nul 2>&1
set /a _delN+=1
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
if defined _rd echo(!_rd!| findstr /r "[^ -~]" >nul && set "_naData=1"
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
rem  escape for JSON: backslash first (\ -> \\), THEN quote (" -> \"). The old code STRIPPED
rem  quotes, silently losing any " in the prior REG_SZ data so the restore wrote wrong data.
rem  Guard on "defined _rd": an EMPTY REG_SZ leaves _rd undefined, and !_rd:...! on an undefined
rem  var returns the literal pattern (\=\\), which is INVALID JSON and breaks ConvertFrom-Json for
rem  the whole preset backup. Empty -> "" (valid).
if defined _naData (
    >>"!PRESET_JSON_TMP!" echo {"key":"!_jk!","name":"!_jv!","present":true,"oldtype":"REG_SZ","restorable":false}
    goto :eof
)
set "_sz="
if defined _rd set "_sz=!_rd:\=\\!"
if defined _rd set "_sz=!_sz:"=\"!"
>>"!PRESET_JSON_TMP!" echo {"key":"!_jk!","name":"!_jv!","present":true,"oldtype":"REG_SZ","olddata":"!_sz!"}
goto :eof

