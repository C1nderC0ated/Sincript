# Sincript

<img width="178" height="97" alt="{4166AFF4-89CF-41C6-84E0-CC0A51EE1796}" src="https://github.com/user-attachments/assets/92274647-6952-4a5b-a115-0fe5c40d10f2" />

A single, menu-driven batch script (`PerfTweaks.cmd`) that applies a
**curated, mostly reversible** set of performance, privacy, and maintenance tweaks 
for **Windows 10 and Windows 11**. Each screen says how its change is undone, or that it
cannot be — see [Reverting changes](#reverting-changes).

Everything is opt-in from a menu, every registry change is backed up before it
is made, and the script can create a System Restore Point and a full registry
export on request. There is no silent "apply everything" — you choose what runs.

The script also detects at startup whether it is running on a **laptop or a
desktop** (ACPI battery presence — one registry query, no WMI/PowerShell; shown
as `Machine=` on the main menu's second header line and in the log; the first line carries
`CPU=` (intel / amd, from the registry), `GPU=`, `Disk=` for the SSD/HDD probe below, and
`Refresh=` for each display's current refresh rate). Actions that are typically
counterproductive on the detected machine class — the always-on power plan,
hibernation off, BCD dynamic-tick off, and the timer-resolution autostart on
laptops; `LargeSystemCache` on desktops — print an **`[ADVISORY]`** line before
their confirmation prompt. The **SysMain** toggle works the same way against a
different probe: it checks what the Windows disk actually is (SSD vs mechanical)
and warns first, because SysMain genuinely helps a spinning disk. That check asks
the drive directly — *does it incur a seek penalty*, which is literally the
SSD-vs-spinning question and what Windows itself uses — rather than going through
the Storage WMI cmdlets, which fail on more machines than you'd expect (one faulty
vendor storage provider takes the whole namespace down with it, and OEM laptops
ship those as standard). Advisories are informational only: they never block an
action, never change a default, and never alter what a preset applies.

The **runtime** is a single self-contained `PerfTweaks.cmd` (no installer, no
dependencies). The release also ships optional bundled inputs, a
timer-resolution helper, an example custom preset, and a developer test
harness — see [Release contents](#release-contents).

---

## Release contents

| Path | Role |
|------|------|
| `PerfTweaks.cmd` | The tool — copy this anywhere you want to run it |
| `SetTimerResolution.exe` | Optional timer-resolution helper for the action |
| `boot.config`, `hosts` | Optional inputs for the Unity and hosts actions (place next to the script) |
| `sincript_presets/` | Folder for custom `.preset` files; includes `example.preset` |
| `tests/` | Static-analysis harness (`Run-Tests.ps1`) — for development/CI, not needed on end-user PCs |

---

## Requirements

- Windows 10 or Windows 11 (tested on recent builds, including 24H2 / build 26100).
- **Administrator rights** for the full feature set. The script **auto-elevates**: on launch it requests elevation through UAC and relaunches itself elevated. Approve the prompt for HKLM changes, services, BCD edits, restore points, and similar.
- If you **decline UAC** (or elevation probes are unavailable), the script warns and asks whether to continue in **limited mode** — only per-user (HKCU) tweaks and read-only status screens work reliably there; privileged actions report `[WARN]` instead of a misleading `[OK]`.
- No installation beyond copying the files you need.

## How to run

1. Place `PerfTweaks.cmd` anywhere (Desktop, a USB stick, etc.).
2. Double-click it (or right-click → *Run as administrator*).
3. Approve the UAC prompt.
4. Use the number keys to navigate the menu, then press `Enter`.

> **Recommended first step:** open **`8. Backups & status`** and create a
> **System Restore Point** and/or a **full registry backup** before applying anything.

---

## Menu overview

### Main menu
| # | Item | What it covers |
|---|------|----------------|
| 1 | Cleanup & repair | Temp/log/crash-dump/DO-cache cleanup (optional shaders, Recycle Bin, Event Viewer, Disk Cleanup / Storage Sense), SFC/DISM, Windows Update reset, Store repair, WinSxS compaction |
| 2 | Performance tweaks | GameDVR off, game-task priorities, snappier UI timings, optional Game Mode / **Game Bar overlay residual** / mouse-acceleration / file-extensions / Storage Sense / Search-scope / SysMain toggles |
| 3 | Privacy & telemetry | Telemetry, ad ID, Cortana/web search, location, activity history, feedback off; **Windows AI** (Copilot, Recall, Click to Do) and inking/typing/speech personalization off; Win11 quiet surface (extra Start/lock tips, search-box suggestions, tailored experiences); also the **Widgets / News and Interests** feed, Start **app-launch tracking**, and `dmwappushservice`; optional firewall block for the telemetry service; optional **Edge** nudges and optional **OneDrive** sync block |
| 4 | Power plan | High-performance / Ultimate plan, disable sleep & disk timeouts, optional 5% min processor state, hibernation off (captured in the power undo file first), CPU power throttling off. **Declining the plan switch keeps you on this screen** — every other change applies to the plan you are already on |
| 5 | Network & DNS | TCP tuning, DNS provider switch (Cloudflare / Google / Quad9 / **your own resolver** / back to DHCP) that first **lists every DNS server typed in by hand**, **flush the DNS cache on its own**, full network stack reset |
| 6 | Apps & files | OpenAsar for Discord, Unity `boot.config`, custom `hosts` file, lightweight Steam launcher, Windows timer resolution, startup-apps manager |
| 7 | Advanced | At-your-own-risk items: CPU mitigations, boot timers, NVMe flags, IPv6, memory compression, GPU telemetry, and **stopping driver installs from Windows Update** |
| 8 | Backups & status | Restore point, full registry export, current-status report, preset-backup (JSON) restore, single-value `.reg` restore, **power-settings revert**, **telemetry services/tasks revert**, backup-folder manager |
| 9 | Apply recommended safe set | One-click core tweaks from categories 1–5 (no prompts). Its power core means **Ultimate Performance** and never-sleep timeouts — on a laptop or an undervolted CPU, use menu 4 instead |
| 10 | Presets | Auto-apply **light / moderate / heavy** preset, build your own **custom** preset, or restore a preset's JSON backup |
| 11 | What was excluded | Explains what the script deliberately leaves out, and why |
| 12 | System tools | General-purpose tools, not tweaks: **PATH editor**, **find what is locking a file**, and a read-only **crash & hardware-error report** |
| 0 | Exit | |

### Sub-menus
- **Cleanup & repair** — Disk cleanup (temps, logs, thumbnails, crash dumps, Delivery Optimization cache, DNS flush; optional shader caches, Recycle Bin, Event Viewer clear (the prompt says that this also erases the history the crash & hardware-error report reads), launch Disk Cleanup / Storage Sense; free-space before/after report) · SFC + DISM repair (their native progress output now streams live to the console) · Windows Update reset · re-register Microsoft Store · compact WinSxS.

  Every delete in the cleanup is anchored on an environment variable (`%TEMP%`,
  `%SystemRoot%`, `%LocalAppData%`), and each of those is **checked before anything
  is deleted**: it has to be set, point at a folder that exists, and not be a drive
  root. Anything that doesn't check out is skipped, out loud. That guard is there
  because batch doesn't complain about an unset variable — it expands to nothing —
  so on a machine with a broken environment `del /f /s /q "%TEMP%\*.*"` would
  quietly become `del /f /s /q "\*.*"`: a recursive delete from the root of the
  drive. Quoting the paths doesn't help; the quotes are intact, it's the contents that collapsed.
- **Performance tweaks** — GameDVR / policy off and gaming MMCSS priorities (core) · optional SystemResponsiveness / network throttling / `Win32PrioritySeparation` / LargeSystemCache · optional **Game Mode** and **Game Bar overlay residual** (recording is already off in core; the overlay prompt is separate and does not uninstall Xbox) · mouse acceleration / file extensions / Storage Sense / Search scope / SysMain / verbose boot status.
- **Privacy & telemetry** — Telemetry / ad ID / Cortana / activity / location / Windows AI (Copilot, Recall, Click to Do) · Win11 **quiet surface** (extra Start/lock Content Delivery tips, search-box suggestions, tailored experiences) · the **Widgets / News and Interests** feed and Start **app-launch tracking** ("Most used") · `dmwappushservice` disabled alongside DiagTrack · optional per-user sync-service disable · optional DiagTrack **firewall** block · optional **Edge** first-run / hubs sidebar / shopping nudges (Edge only; does not uninstall Edge) · optional **OneDrive sync block**.

  Two honest notes on that list. `dmwappushservice` is the WAP-push telemetry
  transport, but it also carries **MDM enrolment** — on a work or school managed
  PC, skip this action. And the **OneDrive** policy (`DisableFileSyncNGSC`) is
  *opt-in only*: it is not a telemetry knob but the documented ADMX policy that
  prevents OneDrive being used for file storage, so it stops the client syncing
  altogether. It used to sit inside the privacy core, which meant *Apply
  recommended safe set* and every preset applied it unprompted — including
  **light**, which this README calls "nothing risky". It now has its own prompt
  and its own preset key.
- **Power plan** — Pick the plan explicitly (**1** Ultimate Performance · **2** High Performance · **3** Balanced · **N** leave it alone) and set monitor/standby/disk timeouts to never · or, if you decline the plan, apply the same individual changes to **your current plan**: timeouts, hibernation off, minimum processor state 5%, CPU power throttling off. The active plan is printed before the first question. Hibernation is captured into the power undo file before it is turned off, like the plan and the timeouts. Only the plan switch is plan-level — `powercfg -change` and `:SetMinProcState` both target whichever scheme is active, so staying on Balanced and still turning off sleep is a supported combination rather than a workaround.
- **Network & DNS** — Apply TCP tweaks (autotuning, RSS/RSC — the previous netsh values are **not saved**; optional **Nagle / delayed-ACK off** for lower latency, and optional **Delivery Optimization off** so Windows Update stops uploading files to other PCs, both backed up) · DNS menu (Cloudflare, Google, Quad9, your own resolver, or back to automatic/DHCP) on every physical adapter · flush DNS cache only · reset network stack (**cannot be undone**).

  *Back to automatic* is DHCP, **not your previous servers**: sincript does not save a DNS
  server you typed in yourself (a router, a Pi-hole). So before you change anything, the
  DNS screen — and the presets' DNS question — lists every server typed in by hand, per
  adapter, for IPv4 and IPv6, read straight from the registry. Note the ones you want to
  keep. If the registry cannot be read, it says so with a `[WARN]` rather than claiming
  there are none.
- **Apps & files** — Install OpenAsar · apply a Unity `boot.config` · apply a custom `hosts` blocklist · restore the original `hosts` · install **SteamLight** (a lightweight Steam launcher + Desktop shortcut) · apply/remove a higher **timer resolution** (SetTimerResolution autostart) · remove built-in Store apps (**debloat**) · **manage startup programs** (flip Run-key and Startup-folder entries between Enabled and Disabled via the same reversible `StartupApproved` switch Task Manager uses; the prior state is saved to a `.reg` backup before every flip).
- **Advanced** — Disable/enable CPU mitigations · set/revert boot (BCD) timers · NVMe feature flags · disable IPv6 · disable memory compression · disable GPU telemetry (NVIDIA telemetry tasks + registry, or the AMD User Experience Program opt-out) · GPU hardware scheduling (HAGS) on/off · set a permanent per-program CPU priority (per `.exe`, via Image File Execution Options) · stop or allow **driver installs from Windows Update**, using the documented *Do not include drivers with Windows Updates* policy. It has its own screen, which prints the trade-offs before the choice (see [Notes & caveats](#notes--caveats)).
- **Presets** — Apply a built-in **light**, **moderate**, or **heavy** preset (no per-item prompts) · apply a **custom** preset from a `.preset` file · **restore** the registry values a preset changed from one of its JSON backups.
- **System tools** — **Edit PATH** (System or User) with dead-entry and duplicate cleanup · **Find what is locking a file** and optionally close the holder · a read-only **crash & hardware-error report** from the event logs. All three are described under [System tools](#system-tools).
- **Backups & status** — Create a System Restore Point · export HKLM + HKCU · restore from a preset JSON backup · restore a single value backup (`.reg`) · revert the power plan and timeouts from a `PowerPlan_*.bat` undo file · revert the telemetry services and scheduled tasks from a `Telemetry_*.bat` undo file · manage/open the backup folder · show the current state of key tweaks (incl. Game Bar `AppCaptureEnabled` and search-box suggestions), system-drive free space, each display's current refresh rate, the active power plan, hibernation, minimum processor state, DNS, TCP autotuning, GPU hardware scheduling (HAGS), the Windows Update driver policy (blocked / allowed / not set, and whether a work or school MDM policy also sets it), memory compression, the **page file** (how it is set, the file(s) in use with their size and peak, RAM, committed memory against its limit, and the crash-dump type — with an `[ADVISORY]` only for problems Microsoft's own documentation describes, such as no page file or one too small for the dump; sincript never changes it), the `hosts` line count, and whether OpenAsar is installed.

---

## Command line

sincript is an interactive menu by default. One preset can also be applied unattended:

```
PerfTweaks.cmd /preset:NAME [/dns:VALUE] [/plan:VALUE] [/norestore]
```

| Option | Values | Meaning |
|---|---|---|
| `/preset:` | `light` · `moderate` · `heavy` | The built-in presets, exactly as the menu applies them — the two paths share one definition of each, so they cannot drift |
| `/preset:` | any `NAME` | Applies `sincript_presets\NAME.preset`, parsed by the same validator the menu uses. The name is held to a whitelist — letters, digits, `_`, `.` and `-` — so separators, wildcards, spaces and `..` are all refused and it cannot reach outside that folder. A preset file whose name contains a space is still selectable from the menu |
| `/dns:` | `cloudflare` · `google` · `quad9` · an IPv4 | Omit it and DNS is left alone. The interactive presets *ask*; an unattended run must not guess. Overrides a `dns=` key in a custom preset |
| `/plan:` | `ultimate` · `high` · `balanced` | Which scheme a preset containing `power=1` activates. Unset means `ultimate`. Overrides a `power_plan=` key |
| `/norestore` | — | Skip the System Restore Point, which is otherwise created first |
| `/?` | — | Help |

**On a laptop, pass `/plan:high` or `/plan:balanced`.** Unset means Ultimate Performance — the plan Windows *hides* on battery-powered machines, which pins sustained maximum clocks. If the machine runs an undervolt (ThrottleStop, XTU, vendor tuning) that step change is where a stable undervolt stops being stable, and the CPU reports it as an uncorrectable machine check, bugcheck `0x124`. Interactively there is an advisory and a prompt to reconsider at; unattended there is only this option, so the advisory is printed and logged before anything is applied. See [Notes & caveats](#notes--caveats).

**It requires an already-elevated window and will not relaunch itself.** The menu self-elevates and exits immediately, which is right for a person and useless for automation — the caller would get an exit code describing the *relaunch* rather than the work. Start it from an elevated prompt, or from a scheduled task set to run with highest privileges.

Everything is validated before anything is changed: a bad option, an invalid `/dns:`/`/plan:`, an unknown preset or a preset file with no valid directives all abort having touched nothing — not even the restore point. Argument errors are reported before environment errors, so a typo does not hide behind *"not elevated"*.

| Exit code | Meaning |
|---|---|
| `0` | Applied, no failures |
| `1` | Applied, but at least one change failed (see the `[FAIL]` lines and the log) |
| `2` | Bad usage — unknown option, invalid value, no such preset, or no writable backup folder |
| `3` | Not elevated; nothing was attempted |

## Presets

**`10. Presets`** applies a whole bundle of tweaks in one go, with **no
per-item prompts** (only a couple of yes/no questions — restore point, and DNS
choice where relevant). There are three built-in presets plus your own custom presets.

| Preset | What it applies | DNS |
|--------|-----------------|-----|
| **Light** | Cleanup core (temp/log cleanup, DNS flush), privacy/telemetry core, network core (TCP autotuning, RSS/RSC). Nothing risky. | Asks (Cloudflare / Google / Quad9 / skip) |
| **Moderate** | The full **recommended safe set** (cleanup + privacy + performance + power + network cores) — same as menu item 9. Optionally installs OpenAsar (bundled `app.asar` if present, otherwise downloads the latest nightly). | — (uses the safe set; DNS unchanged) |
| **Heavy** | Everything in the safe set **plus** foreground/latency tuning: `SystemResponsiveness = 0`, network throttling off, `Win32PrioritySeparation = 42`, Game Mode off, Nagle off, IPv6 off, NVMe flags, GPU telemetry off, BCD timers, memory compression off. | Asks (Cloudflare / Google / Quad9 / skip) |

**Heavy deliberately does *not* include** CPU-mitigation changes, network-stack 
reset, system repair (SFC/DISM), debloat, `LargeSystemCache`, the timer-resolution
autostart, or the Windows Update driver block — those stay manual under their own menus. Heavy shows a warning and 
offers a restore point first.

### Preset backups (JSON)

Manual menu actions each write their own tiny `.reg` backup. **Presets are
different:** every registry value a preset changes is recorded into **one JSON
file** in `Documents\PerfTweaks_Backups`, named `Preset_<name>_<random>.json`.
The script prints the exact path when the preset finishes.

To put those registry values back, use **`8. Backups & status → 4. Restore
from a preset backup (JSON)`** (also reachable from the Presets menu). It reads
the JSON and, per value, either restores the previous data or deletes the value
if it didn't exist before.

> The JSON backup covers **registry values only**. The power plan and the disabled
> telemetry services and scheduled tasks have their own revert screens under Backups &
> status. DNS can only go back to automatic (DHCP), because sincript does not save the
> servers you had, and BCD timers only go back to Windows defaults. Two parts have **no
> in-app revert**, and sincript saves nothing before they change: the netsh TCP settings (every
> preset) and memory compression (heavy). OpenAsar (moderate) is undone from its `.bak`,
> and the cleanup every preset runs **cannot be undone**. A System Restore Point (offered
> before moderate and heavy) is the broadest single way back.

## Custom presets

You can define your own preset as a small text file and have the script apply it.

1. Create a folder named **`sincript_presets`** next to `PerfTweaks.cmd`.
2. Put a text file in it ending in **`.preset`** (e.g. `mypreset.preset`). A ready-to-edit **`example.preset`** ships with Sincript.
3. Run **`10. Presets → 4. Custom preset`**, pick your file, review the summary, and confirm.

### File format

- One directive per line, written as **`key=value`**.
- **No spaces around the `=`** (`cleanup=1`, not `cleanup = 1`).
- Start each directive in **column 1** (no leading spaces).
- A line beginning with **`#`** or **`;`** is a comment and is ignored.
- **Inline comments are not supported** — put comments on their own lines, not after a value.

### Keys

| Key | Value | Effect |
|-----|-------|--------|
| `cleanup` | `1` | Cleanup core (temps/logs/thumbnails/crash dumps/minidumps/Delivery Optimization cache, DNS flush) — interactive-only buckets are not included |
| `privacy` | `1` | Privacy/telemetry core |
| `performance` | `1` | Performance core (GameDVR off, game-task priorities, UI timings) |
| `power` | `1` | Power core — switches to the Ultimate/High plan **and** sets no sleep/disk timeouts (unchanged meaning) |
| `power_timeouts` | `1` | Sleep/disk timeouts set to never on the **current** plan, with no plan switch. Redundant alongside `power=1`, and skipped if both are set |
| `power_plan` | `ultimate`, `high` or `balanced` | Which plan `power=1` activates. Unset means `ultimate`, unchanged from before — but Ultimate is a workstation plan Windows hides on battery-powered machines, so `high` is the safer choice on a laptop |
| `network` | `1` | Network core (TCP autotuning, RSS/RSC) |
| `openasar` | `1` | Install OpenAsar silently (bundled `app.asar` if present, otherwise downloads the latest nightly) |
| `gamemode_off` | `1` | Disable Windows Game Mode |
| `gamebar_off` | `1` | Disable Game Bar / Xbox Game Bar overlay leftovers (`AppCaptureEnabled`, Nexus, startup panel) — recording is already off in the performance core |
| `edge_nudges_off` | `1` | Edge policy: hide first-run experience, disable hubs sidebar and shopping assistant (does not uninstall Edge) |
| `onedrive_off` | `1` | Block OneDrive file sync by policy (`DisableFileSyncNGSC`) — **stops OneDrive syncing entirely**, not just telemetry. Never applied by the built-in presets |
| `systemresponsiveness` | `0` | `SystemResponsiveness = 0` (favor foreground) |
| `networkthrottling_off` | `1` | Network throttling off (`0xFFFFFFFF`) |
| `largesystemcache` | `1` | Enable `LargeSystemCache` *(situational; can hurt on desktops)* |
| `minprocstate5` | `1` | Minimum processor state 5% |
| `bcdtimers` | `1` | BCD timer set (`useplatformclock` off, `useplatformtick`/`disabledynamictick` on, TSC enhanced) |
| `ipv6_off` | `1` | Disable IPv6 (`DisabledComponents = 0xFF`) |
| `memcompress_off` | `1` | Disable memory compression *(raises RAM pressure on low-memory PCs)* |
| `nvme_flags` | `1` | NVMe feature flags *(may be blocked on fully-patched Windows)* |
| `gpu_telemetry_off` | `1` | Disable GPU telemetry (NVIDIA tasks + opt-out; opt-out on AMD) |
| `nagle_off` | `1` | Disable Nagle on all interfaces (`TcpAckFrequency` / `TCPNoDelay`) |
| `win32priority` | `42`, `38`, `26` or `2` | `Win32PrioritySeparation`. **`42`** (0x2A) = short **fixed** quantum — the classic "42" tweak; because the quantum is fixed, Windows' Processor-Scheduling dialog reads it back as *background services* (that's what fixed means, not a bug). **`38`** (0x26) = short **variable** quantum, strong foreground boost — the exact value Windows' own *Programs* radio writes; the foreground app gets the longer slice. **`26`** (0x1A) = long fixed quantum. **`2`** = Windows default. `42` and `38` are opposite trade-offs (throughput vs foreground latency); pick to taste. |
| `dns` | `cloudflare`, `google`, `quad9`, or a literal IPv4 address | DNS servers on every physical adapter, connected or not (VPN and other virtual adapters are left alone). A literal address goes through the same validator the interactive screen uses, so a preset cannot set something the menu would have refused |

Keys not listed here (and `1`-keys given any other value) are **rejected**.

There is deliberately no key for blocking driver installs from Windows Update. It trades security fixes for control, so it is offered only on its own screen, where the costs are printed before you choose.

### What happens with a bad file

The script validates the whole file first and shows a summary: how many
directives it recognized and how many problems it found, each listed
(`unknown key`, or `bad value … (expected …)`). Then:

- **Some valid, some bad** → it reports the problems and asks whether to apply the valid ones anyway.
- **Nothing valid** → it aborts without changing anything and points you back to this key list.

Like the built-in presets, a custom preset writes a single JSON registry backup you can restore from the Backups menu.

---

## System tools

**`12. System tools`** holds general-purpose tools rather than tweaks. 
None of them changes anything on its own — you read first, then decide. The crash report only ever reads.

### Edit PATH

Edits the **System** (`HKLM`, all users, needs Administrator) or **User** (`HKCU`, just you) `PATH`.

- Lists `PATH` as numbered entries and flags any folder that no longer exists as
  **`[missing]`** — the dead entries worth clearing out.
- Add a folder, remove one by number, drop **all** dead entries, or clean duplicates.
- **It never uses `setx`.** `setx` is documented to crop a value at 1024
  characters — a real machine `PATH` is routinely longer, so it would silently
  destroy most of it — and to rewrite `REG_EXPAND_SZ` as `REG_SZ`, freezing
  `%SystemRoot%`-style references into literal paths. Sincript reads the **raw**
  value and writes it back as `REG_EXPAND_SZ`, so both the length and the `%VAR%`
  references survive.
- The whole `Environment` key is backed up to a `.reg` (via `reg export`, which is
  exact for `REG_EXPAND_SZ`) **before** any edit — and if that backup can't be
  written, **the edit doesn't happen**. A `PATH` you can't put back isn't worth the risk.
- After a change it broadcasts `WM_SETTINGCHANGE`, so new programs and shells see
  the new `PATH` without a sign-out. Programs **already open keep the old value**
  until they restart — expected, and the tool says so.

Editing the System `PATH` needs an elevated window. If you aren't elevated,
sincript says so up front and offers the User `PATH` instead, rather than letting the save fail.

### Find what is locking a file

Answers *"what has this file open?"* when Windows won't let you delete or replace
something, using the Windows **Restart Manager** — the same API installers use.

- Give it a full file path; it lists every process holding the file (PID + name).
- Core Windows processes are marked **`[critical]`** using Windows' own
  classification, and sincript **will not close them** — a reboot is the only
  safe way to release a file they hold.
- Closing a holder is optional, one process at a time, and confirmed. It loses
  that program's unsaved work but does not delete the file; sincript then
  re-checks and tells you whether the file is actually free.
- No reboot and no extra downloads: `openfiles` needs a global flag *and* a
  reboot before it reports anything, and Sysinternals `handle.exe` would be an
  external dependency — so neither is used.

### Crash & hardware-error report

**`12. System tools → 3.`** answers *"what has gone wrong on this PC lately?"* from the Windows **System** and **Application** event logs. It is **read-only**: nothing is changed.

What it looks for, over the last 30 days:

| Line in the report | Events (provider · ID) |
|---|---|
| Unexpected restarts | Kernel-Power 41 (split into *bugcheck*, *power button held*, *no code*) · EventLog 6008. A 41 that recorded no code, next to a WER 1001 that did, counts as a bugcheck |
| Bugchecks (blue screens) | WER-SystemErrorReporting 1001, and the code inside Kernel-Power 41. One crash is counted once, shown as `0x00000124 WHEA_UNCORRECTABLE_ERROR`-style hex, with the name for 13 common codes |
| Hardware errors | WHEA-Logger, classified by **event ID** from the provider's own manifest, not by level; informational WHEA records (level 4, e.g. id 3) are not read. **UNCORRECTED**: the "fatal hardware error" IDs (1, 16, 18, 20, 22, 24, 26, 29, 40, 42, 44, 46, 48; Windows logs 29 at the *warning* level) and any ID not known to be corrected. **Corrected**: 2, 17, 19, 21, 23, 25, 27, 28, 41, 43, 45, 47, 49. Raw event IDs are shown |
| Display driver resets (TDR) | Display 4101, with the driver name |
| Disk retries / resets / bad blocks | disk 153 · storahci / stornvme 129 · disk 7. Event 129 is logged under the storage driver's own name, and only Windows' own drivers are read, so the "none found" line says *(Windows storage drivers only)* |
| NTFS corruption | Ntfs 55, and Ntfs 98 when its state is a number other than 0 ("healthy") |
| Low virtual memory | Resource-Exhaustion-Detector 2004 |
| Crash-dump setup failed | volmgr 46 (a crash at that boot leaves no dump and no code) |
| App crashes | Application Error 1000, by app / faulting module |
| On the same timeline | Service Control Manager 7045 (driver and service installs), and sincript's own sessions, taken from its log files, with the undo files each one wrote before a change: per-value `.reg` backups, `Preset_*.json`, `PowerPlan_*.bat` and `Telemetry_*.bat`. A full registry export changes nothing, so it does not count |

How it stays honest:

- **It reads what was logged, not what it says.** It reads provider names, event IDs, levels and named data fields, never the message text. Message text is translated, and rendering it is what makes the usual `Get-WinEvent` approach slow: about 5.7 ms per event, against 3,717 events in 243 ms here.
- **Each log is proven readable first.** `Get-WinEvent -FilterHashtable` answers a log it cannot read with *"no events were found"* (measured), which would turn a failed read into a clean result. sincript reads each log's oldest record first and uses a reader whose failures are errors, not empty answers. An unreadable log prints **COULD NOT BE READ**, its checks print **NOT DONE** (or **NOT READ** for app crashes), and the final line is **[FAIL]**, in words that name the log.
- **"None found" always says how far back it looked.** Logs roll over (20 MB by default) and can be cleared — Cleanup's *clear all Event Viewer logs* option does exactly that. The report states how many days each log still covers and when it was last cleared. The final line is **[OK]** only when both logs cover the full 30 days and reading was not cut short; otherwise it is **[WARN]**.
- **A hardware-error storm cannot hide the latest events.** Both logs are read newest first, the System log first, up to 30,000 matching events in all (one shared cap). At that cap the most recent events are the ones kept, the report says where it stopped, the days covered shrink to what was actually read, and the final line is **[WARN]**. If the System log uses up the whole cap, the Application log and its app-crash line say **NOT READ**, never "none". The cap is 30,000 because the summary and the timeline each took 2–4 s on 30,000 synthetic events, and up to 5.7 s on 50,000.
- **Hints only add, never reassure.** Each hint (press **H**) appears only when its evidence is there, and is phrased from the Microsoft page listed below. Examples:
  - a driver installed in the week before the first crash;
  - an undervolt tool installed when there are machine-check errors (a WHEA error from the processor core, or a 0x124 bugcheck);
  - a sincript session that wrote undo files before the problems started (Backups & status can restore from them).
- **Privacy.** Nothing in the report or the saved file contains message text, file paths or user names. A driver or service install event carries its full command line, and on the machine this was built on one held a VPN private key. That path is used only to tell a driver from a service and is never shown or saved.

**S** saves the report as `CrashReport_<date>_<n>.txt` in `Documents\PerfTweaks_Backups`: plain ASCII, the same summary plus the full timeline, the final `[OK]` / `[WARN]` / `[FAIL]` line and the hints. It keeps app, module, service and driver names and dates — it is your own file, and those names are what make it useful — so look it over before you share it. *Manage / open backup folder* counts these files.

It takes three short PowerShell steps; the screen says so, and that no input is accepted meanwhile (keys pressed then reach the next prompt). On the development machine the whole screen took 7–12 s, almost all of it PowerShell start-up (2.1–2.6 s per step there); reading the logs took under a second.

It deliberately does **not** offer the popular `TdrDelay` / `TdrLevel` "fix" for display-driver resets — see [What was excluded](#what-was-excluded--the-philosophy).

Sources for the hints (Microsoft Learn):
- *Advanced troubleshooting for Event ID 41*
- *Bug Check 0x124*
- *Bug Check 0x117* and *Testing and debugging TDR*
- *Data corruption and disk errors troubleshooting guidance*
- *Understanding storage timeouts and Event 129 errors* and *Interpreting Event 153 errors*
- *Event ID 46 is logged when you start a computer*
- *Application or service memory leaks troubleshooting guidance*
- *Troubleshoot unexpected reboots using system event logs*

---

## Safety & backups

The script is built around being undoable.

- **Per-value registry backups.** Before changing any registry value, the script saves a small `.reg` file with **only that one value's previous state** to `Documents\PerfTweaks_Backups` (~1 KB each). Double-click it to put the value back. Values containing quotes or empty `REG_SZ` data are backed up in a form that restores correctly; filenames use a wide random suffix so two values under the same key can't overwrite each other's undo file in one pass. Re-applying a value already at the target (`REG_DWORD` or `REG_SZ`) is skipped, so a redundant apply can't overwrite its original backup. If the `.reg` backup cannot be written, the live registry write is **refused**.
- **Power settings are captured before they change.** The power action used to be the one place that mutated state with nothing saved — which is why the minimum-processor-state prompt admitted "no in-app undo". It now writes a runnable `PowerPlan_<random>.bat` into the backup folder first, holding the scheme that was active, its monitor / standby / disk idle timeouts in seconds, the minimum processor state in percent, and whether hibernation was on (the Power screen's hibernation switch; an already-off hibernation is written as a comment, not turned on, and when `HibernateEnabled` is not set the file goes by Windows' `HibernateEnabledDefault` and says so). Every restore line in that file runs through a small counting helper, so it ends with `[OK] Restored n` or `[WARN] n restored, m FAILED` rather than a flat success line - generated output is real cmd and gets the same honesty rule as the script that wrote it — and **Backups & status → Revert power settings** runs it back. The file re-activates the saved plan as its **first** line and again at the end: the plan is the one thing you most need back, so a run that stops part-way still leaves you on it rather than stranded on the new one. Values are read from the registry rather than parsed out of `powercfg /query` output, because that output is localized — text parsing would quietly capture nothing on a non-English Windows. A setting the scheme never stored explicitly is restored from the plan's own default (`DefaultPowerSchemeValues`), or failing that from the value that was in effect (`powercfg /query`, read as hex so the display language does not matter); only a value none of the three can supply is written into the file as a comment instead of guessed at. A failed capture **warns rather than blocks**: unlike an overwritten file, the plan and its timeouts stay reachable through Control Panel, and hibernation through `powercfg /hibernate on`, which the warning names — so refusing the action would cost more than it protects.
- **File backups are write-once.** For the three actions that replace a *file* — apply/reset `hosts`, OpenAsar, and the Unity `boot.config` — the backup kept beside the original (`hosts.bak`, `app.asar.bak`, `boot.config.bak`) is written **once** and never overwritten afterwards. That matters because all three are meant to be re-run: the OpenAsar screen says so outright, since a Discord update reverts the patch. Copying unconditionally on every run meant the second run backed up *the already-applied file over the pristine original*, so "restore the `.bak`" restored the modification onto itself. A separate randomized snapshot (`hosts_<random>.bak`, `Discord_app.asar.bak`) goes to the backup folder each run, so re-runs accumulate rather than overwrite. If no backup lands at all, the write is **refused** rather than performed and apologised for afterwards.
- **Full registry export** (optional) — exports all of `HKLM` and `HKCU` to `Documents\PerfTweaks_Backups`. It verifies both exports actually produced a file before reporting success, so a failed or partial backup (not elevated, or the folder isn't writable) is flagged `[ERROR]` instead of a misleading `[OK]`. Importing it puts back every value it holds, but it cannot remove a value created after it was taken; the per-value backups can (a line `"Name"=-`).
- **System Restore Point** (optional) — created on demand; `Apply recommended safe set` also offers to make one first.
- **Log file** — every action is logged to `Documents\PerfTweaks_Backups\PerfTweaks_<random>.log` as a clean `[timestamp] EXEC / OK / FAIL` timeline. It records each command's *outcome*, not its raw output, so it stays readable and doesn't fill with deleted-file paths or (on non-English Windows) garbled OEM-code-page error text.
- **Honest status lines.** Registry-heavy actions finish with `[OK]` only when every write succeeded; otherwise `[WARN]` with a count and inline `[FAIL]` lines pointing at what didn't apply (usually: not elevated, or a protected key). DNS, full-registry backup, OpenAsar, preset JSON restore, and admin-only repair actions (DISM/SFC, Windows Update reset, WinSxS compaction, memory compression, Store re-register) follow the same principle. The **apply hosts** and **reset hosts** actions refuse to overwrite the system `hosts` file until a backup has landed; restore can use the Documents `hosts_*.bak` if the local `.bak` is missing.

All backups and logs live in **`Documents\PerfTweaks_Backups`** inside your user
**Documents** folder. The script auto-detects the real Documents path
(including OneDrive-redirected Documents) and falls back to `%USERPROFILE%\Documents` if needed.

## Reverting changes

| Change | How to undo |
|--------|-------------|
| Any single registry tweak | Double-click its `.reg` backup in `Documents\PerfTweaks_Backups`, or use Backups & status → **Restore a single value backup (.reg)** |
| CPU mitigations | Advanced → **Re-enable CPU mitigations**, which puts back Windows' secure default. Your exact previous values are in the two `.reg` backups the disable wrote (`HKLM_SYSTEM_CurrentControlSet_Control_Session_Manager_Memory_Management_*.reg`; other changes share that name, so open one in Notepad to see which value it holds) |
| Windows Update driver installs blocked (Advanced → 11) | Advanced → **Windows Update driver installs** → **2**. This deletes the policy value (*Not configured*, the Windows default); you can also merge its `.reg` backup. Restart Windows afterwards: Windows Update rereads its policy only when its service restarts. If the Group Policy Editor (`gpedit.msc`) sets the same policy, change it there instead — Group Policy writes its own value back |
| Boot (BCD) timers | Advanced → **Revert BCDEdit timer tweaks** deletes all four values, which leaves Windows' defaults. A value you had set yourself before (for example `useplatformclock`) is not saved by sincript |
| DNS | Network → DNS → **Revert to automatic (DHCP)**, on every physical adapter. That is DHCP, **not your previous setting**: sincript does not save a server you had typed in yourself (a router, a Pi-hole). The DNS screen — and the presets' DNS question — lists every typed-in server, per adapter and for IPv4 and IPv6, before you change anything. Note them, then re-enter an IPv4 one with **Custom server**, or any of them in an elevated PowerShell: `Set-DnsClientServerAddress -InterfaceAlias "<adapter>" -ServerAddresses <server>,<server>`. VPN and other virtual adapters are never changed |
| Hibernation (Power plan) | Backups & status → **Revert power settings** with a `PowerPlan_*.bat` written by this version: it turns hibernation back on if it was on before (an already-off hibernation is left off). A file that says it could not read the state or that the earlier state is unknown, or one written by an older version, does not restore it: in an elevated Command Prompt, run `powercfg /hibernate on`. Fast Startup uses the hibernation file, so it only works again once this is back on |
| Disable IPv6 (Advanced, preset `ipv6_off`, heavy) | Backups & status → **Restore a single value backup (.reg)**, then pick the `HKLM_SYSTEM_CurrentControlSet_Services_Tcpip6_Parameters_*.reg` file. It holds the `DisabledComponents` value you had. From a preset, use **Restore from a preset backup (JSON)** instead. You can also set `DisabledComponents` to `0`, the Windows default. Reboot either way |
| TCP tweaks (Network → Apply TCP tweaks; every preset's network core) | **No in-app revert, and sincript does not save the previous values.** `netsh int tcp show global` and `netsh int tcp show heuristics` show the current state (the heuristics setting sincript turns off is only in the second), and `netsh int tcp set global rss=default rsc=default` puts those two back to the system default. Nagle / delayed-ACK and Delivery Optimization are registry values: see the first row |
| Reset network stack | **Cannot be undone.** `netsh winsock reset` returns the Winsock catalog to a clean state and removes custom providers, so some VPN or security software may need a repair. `netsh int ip reset` rewrites the TCP/IP registry keys, which Microsoft describes as the same as removing and reinstalling TCP/IP. Re-enter any static IP settings afterwards |
| Custom `hosts` | Apps & files → **Restore / reset hosts → 1** puts back the oldest original, `hosts.bak`. Each run's snapshot is also in the backup folder as `hosts_<random>.bak`, and a reset names the file that holds what it replaced |
| Timer resolution | Apps & files → **Remove timer resolution** |
| Windows Game Mode | Settings → Gaming → Game Mode (or merge the value backup) |
| Game Bar / overlay residual | Merge the `AppCaptureEnabled` / GameBar value backups, or Settings → Gaming → Game Bar |
| Edge first-run / sidebar / shopping nudges | Merge the Edge policy `.reg` backups under `Policies\Microsoft\Edge`, or delete those policy values |
| Minimum processor state | Backups & status → **Revert power settings** (it is captured), or the plan's advanced power settings → Processor power management → Minimum processor state, back to the plan's own value. Balanced ships at 5%, so sincript's 5% changes nothing there; High performance ships at 100% plugged in |
| Power plan, sleep / disk timeouts, minimum processor state | Backups & status → **Revert power settings**, and pick the `PowerPlan_*.bat` written before the change |
| Telemetry services (DiagTrack, dmwappushservice) and the telemetry scheduled tasks | Backups & status → **Revert telemetry services / tasks**, and pick the `Telemetry_*.bat` written before Privacy ran. It restores the start types that were in place, starts a service again if it was running, and re-enables the tasks that were enabled — anything you had already disabled yourself is left alone |
| NVIDIA telemetry tasks (*GPU telemetry*) | The same screen: pick the `Telemetry_nvidia_*.bat` written before the change. It re-enables only the tasks that were enabled |
| Removed built-in apps (debloat) | Most reinstall from the Microsoft Store. LTSC editions (IoT LTSC included) have no Store, and OneDrive comes back from Microsoft's OneDrive download instead |
| OpenAsar | Copy `app.asar.bak` from beside the replaced file back over it, or use the backup-folder copy `<flavour>_app.asar.bak` (for example `Discord_app.asar.bak`); or reinstall Discord. A Discord update also replaces it |
| Unity `boot.config` | In the game's `*_Data` folder, copy `boot.config.bak` back over `boot.config`. If the game had none, delete `boot.config` |
| SteamLight | Delete `SteamLight.bat` from the Steam folder and the `SteamLight` shortcut from the Desktop. Steam itself is not changed |
| NVMe flags | Backups & status → **Restore a single value backup (.reg)** for each of the four `HKLM_SYSTEM_CurrentControlSet_Policies_Microsoft_FeatureManagement_Overrides_*.reg` files (one per flag), or delete the four values; then reboot |
| Compact WinSxS | The component cleanup **cannot be undone**: it deletes superseded component versions at once instead of after Windows' 30-day wait. CompactOS can be: `compact.exe /compactos:never` |
| Cleanup | **Cannot be undone.** Deleted temp files, logs and caches, an emptied Recycle Bin and cleared event logs are gone |
| Startup entry enabled/disabled | Flip it again under Apps & files → **Manage startup programs**, merge its `.reg` backup, or use Task Manager → Startup apps |
| Memory compression | PowerShell: `Enable-MMAgent -MemoryCompression -PageCombining` (the action turns both off). There is no in-app revert, and sincript does not save the previous state |
| Page file / crash-dump type | Nothing to undo — sincript only *shows* them (Backups & status → Show current status). To change them yourself: `SystemPropertiesAdvanced` → Performance **Settings** → **Advanced** → **Virtual memory**, and **Startup and Recovery** for the dump type |
| Crash & hardware-error report | Nothing to undo — it only reads. A saved `CrashReport_*.txt` in the backup folder can simply be deleted |
| A `PATH` edit | Double-click the `…Environment_….reg` backup written before the edit (in `Documents\PerfTweaks_Backups`). It is the **whole `Environment` key**, so it also puts back any other variable in that key that has changed since |
| SysMain / Superfetch | Merge its `.reg` backup, or `sc config SysMain start= auto` |
| Storage Sense / Delivery Optimization / CPU power throttling | Merge each one's `.reg` backup (they are policy values; the backup restores "not configured") |
| Windows AI (Copilot / Recall) | Merge their `.reg` backups, or restore the preset JSON backup |
| OneDrive sync block | Merge its `.reg` backup (Privacy writes one before the change) |
| Telemetry firewall block | Elevated PowerShell: `Set-NetFirewallRule -Group DiagTrack -Action Allow` |
| Telemetry scheduled tasks | Task Scheduler → find the task → **Enable**, or PowerShell: `Get-ScheduledTask -TaskName <name> \| Enable-ScheduledTask` |
| Registry values changed by a preset | Backups & status → **Restore from a preset backup (JSON)** (or run the relevant menu item to reverse it) |
| Everything at once | Roll back to the **System Restore Point** — the broadest way back, though not for files the cleanup deleted. Importing the **full registry backup** puts back every value it holds, but it cannot remove a value that did not exist when it was taken (most of sincript's policy values), so on its own it is not a full undo |

---

## Optional bundled files

Some actions can use files placed **next to `PerfTweaks.cmd`**. They are optional:

- **`app.asar`** — an OpenAsar build for the Discord action. If absent, the script offers to download the latest nightly from the official OpenAsar GitHub releases (https://github.com/GooseMod/OpenAsar).
- **`boot.config`** — a Unity engine boot configuration applied to a game's `*_Data` folder.
- **`hosts`** — an ad/telemetry blocklist that the "apply hosts" action installs (the original is backed up first).
- **`SetTimerResolution.exe`** — the timer-resolution helper from [valleyofdoom/TimerResolution](https://github.com/valleyofdoom/TimerResolution). *Apps & files → Apply timer resolution* copies it to `C:\ProgramData\Sincript`, registers a hidden logon task that holds your chosen resolution, and (on Windows 10 2004+/11) sets the registry switch that makes the change system-wide.

**SteamLight** needs no bundled file. *Apps & files → Install SteamLight* finds
your Steam folder via the registry, writes a `SteamLight.bat` launcher **into
that folder**, and adds a `SteamLight` Desktop shortcut. The launcher starts
Steam with resource-saving flags (single core, no shaders, no shared textures, no
Big Picture, high-DPI off, etc.) for lower RAM/CPU use. Running Steam's web pages in a
single process saves the most memory, but it also turns off the sandbox that keeps a
compromised store or community page away from the rest of your PC, so the install asks
about it separately, and the answer is No unless you choose it. It
references `steam.exe` relative to its own folder, so it keeps working even if
Steam is on another drive. To change the flags, edit the `start` line in the generated
`SteamLight.bat`: they are written into that line, not into a variable you can edit.

---

## Recent changes

Newest first. Feature details live in the sections above — this is just what changed.

- **Fixed: *Cleanup* emptied your temp folder twice, once under a name like `MARISI~1`.** That is the folder's old 8.3 short name: on many PCs whose user folder has a space, Windows stores `%TEMP%` in that form, so `%TEMP%` and `%LocalAppData%\Temp` were one folder cleaned twice. *Cleanup* now compares their short forms and cleans the folder once, under the readable long name. **Test 133.**
- **Fixed: names in other alphabets showed as `?`.** Adapter names on the DNS screens, startup entries, PATH entries and the programs the lock finder names came out as `????` on a PC whose code page for non-Unicode programs lacks their letters, such as a Russian interface with US English set for non-Unicode programs. The DNS menu itself showed the problem: `reg query` hands text to cmd in the console's code page. Those reads now switch the console to UTF-8 for a moment and back, and the workers behind them write UTF-8 and keep every letter. The crash report stays ASCII on purpose — its lines are fixed-width, and the names it shows are program files. **Test 156**, run in a hidden console, checks that a UTF-8 name read from code page 437 comes back intact and that 437 is restored; it also checks every one of those reads and workers.
- **Comments in `PerfTweaks.cmd` cut to about a third.** 1,651 comment lines became 641, and the script went from 7,005 lines to 5,995. Fix histories and long explanations went; each routine keeps what it is for, its inputs and outputs, and any rule that stops a known bug coming back. No code line changed — a script compared every non-comment line before and after — and all 155 tests pass.
- **New: the CPU vendor on the main-menu header.** `CPU=intel` or `CPU=amd` sits next to `GPU=`, on the main menu and on *Status*. It comes from the value Windows fills in at boot, `VendorIdentifier` under `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0` — one registry query, no WMI or PowerShell — and any other vendor shows as `other`, an unreadable value as `unknown`. `Machine=` moved to the second header line, in front of the undervolt tool, because with `CPU=` added the first line would have run past the 98-column separators at its widest. **Tests 119 and 152** follow the new layout, and 119 also checks where `CPU=` comes from.
- **The committed-memory advisory says what "committed" means.** Committed memory is what programs have reserved, not the RAM in use, so it can reach its limit while RAM still looks half free; Windows then shows its own "low virtual memory" warning. The figures were already right — only the wording invited reading them as RAM. **Test 145** still checks that each number lands in its place.
- **New: the current refresh rate on the main-menu header.** `Refresh=144Hz` sits next to `Disk=`; two displays show as `144/60Hz`, more as `+N`, and *Status* lists up to eight in a new **[Display]** section. A short background PowerShell worker reads it once per launch from Windows' own display API (`DisplayManager`), rounded to whole hertz (143.998 Hz shows as 144). The menu never waits for it: the header says `pending` for the first few seconds, `remote` in a remote session, and `unknown` if the read failed, with the reason in the log. It shows the current mode only; VRR, G-SYNC, FreeSync and Dynamic Refresh Rate panels run below it anyway. **Tests 152–155.**
- **New: crash & hardware-error report (System tools → 3).** A read-only screen over the last 30 days of the System and Application logs: unexpected restarts, bugchecks with their names, WHEA hardware errors (uncorrected and corrected), display-driver resets, disk and NTFS errors, low virtual memory, crash-dump setup failures and app crashes, with driver installs and sincript's own sessions on the same timeline. It reads event IDs and named fields, never message text, proves each log readable before saying "none found", and says how many days the log still covers. WHEA errors are classified by event ID, not by level (id 29 is fatal but logged as a warning). Hints appear only on evidence and cite Microsoft, and the report can be saved. Also: *Cleanup*'s clear-all-logs prompt now says it erases this history, and *What was excluded* lists the TdrDelay/TdrLevel "fix". **Tests 147–151**, plus 31 and 51.
- **New: the page file on the *Status* screen.** *Backups & status → Show current status* has a **[Page file]** section: how the page file is set, the file(s) in use with size, use and peak, committed memory against its limit, and the crash-dump type, all from registry values, WMI and `GetPerformanceInfo`, never localized text. It warns only about problems Microsoft documents: no page file, so committed memory is capped below RAM; crash dumps on with no page file on the Windows drive; a custom page file there too small for a complete memory dump; committed memory that peaked at 90% or more of a limit that cannot grow; and Windows running on a temporary page file. A system-managed page file is never judged small, since Windows grows it itself, and a change still waiting for a restart is worded that way. sincript never changes the page file or the dump type; the screen says where to. **Tests 143–146**, plus 110.
- **New: stop or allow driver installs from Windows Update (Advanced → 11).** One documented policy, *Do not include drivers with Windows Updates* (`ExcludeWUDriversInQualityUpdate`), with the stored value shown first, like the HAGS screen. Before you choose, the screen lists the costs: Windows Update stops offering drivers, including the BIOS and firmware updates PC makers ship that way, which can carry security fixes; Microsoft recommends leaving them on; nothing installed is removed; and Group Policy or an MDM (work/school) setting can override it. It names those when set, says when Home or a build before 1607 does not list the policy, and adds a firmware advisory on laptops. Both directions read the value back, so a `[FAIL]` never sits above an `[OK]`, and a differing local Group Policy setting is a counted `[WARN]`. Turning drivers back on deletes the value (*Not configured*). It is in no preset, not in *Apply recommended* and not on `/preset:`; *Status* shows it. **Tests 139–142**, plus 15.
- **Honesty pass: every undo claim now matches what the code can undo.** The DNS screen said *Fully reversible.*, but *Revert to automatic (DHCP)* cannot bring back a resolver you typed in; it now says so, and first lists every hand-typed DNS server per adapter, IPv4 and IPv6. The old line showed a single value, on one real PC a Wi-Fi Direct adapter's, which hid the router address in use. Hibernation is now captured in `PowerPlan_*.bat` before *Also disable hibernation*, and **Revert power settings** turns it back on if it was on; when the earlier state is unknown, the file says so and names `powercfg /hibernate on`. "Reversible", "harmless" and "revert from their own menus" were removed wherever the code did not back them: the Advanced header, the lock finder's close, WinSxS cleanup, TCP tuning and memory compression in the presets, BCD timers and NVMe flags. The TCP screen now says the old values are not saved, and the network-stack reset says it cannot be undone. Also fixed: a hosts reset that named `hosts.bak` as the backup when that file already existed, a backup prune that said the newest export alone is enough, *Apply recommended* not saying it means Ultimate Performance, and an unverified claim about IPv6 DNS. *Reverting changes* gained ten rows and seven were corrected. **Tests 136–138**, plus 126.
- **Fixed: a `%` or `^` in the Windows user name sent cleanup, backups and the log to another user's folders, or to a junk folder.** A path passed as a `call` argument is parsed a second time, which swallows a `%` and doubles a `^`. For a user `Bo%b & Co`, backups and the log went into the Documents of a user `Bob & Co`, and cleanup deleted that user's temp files and thumbnail cache; for `Bo^b & Co`, sincript made a folder `C:\Users\Bo^^b & Co` and cleaned nothing. The six cleanup deletes under the profile and the 21 log lines that carry a path now pass it by name (`:RunVar`, `:LogVar`), so nothing is parsed again. **Tests 133–135.**
- **Fixed: a `!` or `&` in the Windows user name sent cleanup, backups and the log to another user's folders — and with `&`, cleanup could empty that user's whole profile.** Profile paths were read with `%…%` while delayed expansion was on, which eats a `!`: for a user `Bo!b`, cleanup deleted the temp files and thumbnail cache of a user `Bob` when that account existed, and wrote the log into Bob's Documents. For a user `Bob & Co`, a separate `:Run` bug cut every delete at the `&`, so if an account `Bob` existed, every file in its profile was deleted, `NTUSER.DAT` included. Backups went to a folder that was not the user's, so the revert screens found nothing; OpenAsar could not find Discord, and PowerShell workers lost their results. Every profile path is now captured with delayed expansion off and read late (`!TEMP!`). **Tests 132, 133.**
- **NVIDIA's driver-update check is no longer switched off as "telemetry", and the NVIDIA tasks get an undo file.** *GPU telemetry* disabled `NvDriverUpdateCheckDaily_*` along with NVIDIA's two telemetry tasks. That task is NVIDIA's update check, not telemetry, and nothing said it was being turned off. It is left alone now. The telemetry tasks themselves are captured first into a `Telemetry_nvidia_*.bat`, which **Backups & status → Revert telemetry services / tasks** lists and runs, the same way the Windows telemetry tasks already worked. If an earlier run turned the update check off and you want it back, enable `NvDriverUpdateCheckDaily_…` in Task Scheduler (under `\NVIDIA`). **Tests 68, 126.**
- **Small honesty fixes from the same audit.** Each of these said success, or showed a fact, for something that had not happened: OneDrive removal printed `[OK]` for any uninstaller exit code; choosing Ultimate Performance could activate High Performance without a word; the lock finder said a file was "free" when its query had failed; disabling memory compression reported a total failure when only the second of its two switches failed; a failed preset backup showed the *previous* preset's backup path; the backup prune counted delete attempts as deletions; and the exit screen said "Log saved to" when no log could be written. Also fixed: the Storage Sense option wrote a per-user copy of a policy Windows only reads machine-wide (the leftover value is harmless); a log line lost its `%`; the debloat screen called the Xbox TCUI package "the game-bar component" (Game Bar itself was never removed); and an emphasis marker used two colour variables that were never defined. **Tests 67, 130, 131.**
- **Four maintenance actions stop saying `[OK]` regardless.** *Windows Update reset*, *Compact WinSxS* and *DISM + SFC* printed `[OK] … finished. See the output above` whenever the window was elevated — but those commands' output is swallowed, so there was nothing above to see — and *Cleanup* ended in `[OK] Cleanup done.` even when clearing the event logs, its one irreversible step, had failed. Now the reset checks that SoftwareDistribution and catroot2 were really renamed (before the services start again and recreate them) and names any that was not; DISM's exit code decides DISM's line (0 or 3010 means done, anything else is `[FAIL]` with the code); CompactOS reports its own result; SFC, whose exit codes are undocumented, is pointed to its own verdict instead of being guessed at; and the event-log step says how many logs it cleared and how many refused. **Test 129.**
- **SteamLight no longer turns off Steam's browser sandbox without asking.** Its launch flags included `-cef-disable-sandbox` and `-no-cef-sandbox`, and `-cef-single-process` did the same thing less visibly: Chromium's documentation says single-process mode "prevents the use of the sandbox". The screen and this README described all of them as saving RAM and CPU. The sandbox is what keeps a compromised store or community page away from the rest of your PC, so single-process mode (with the two switches it was tested with) is now a separate question with that trade-off written out, answered No unless you type Y. The memory it saves is real, so it stays available. **Re-run *Install SteamLight*** to regenerate an existing `SteamLight.bat` — the old one still carries all three flags. **Test 128.**
- **Fixed: a `!` in sincript's folder name broke elevation and every bundled file.** The folder was captured correctly, with delayed expansion off, and then read back as `%SCRIPT_DIR%`, which put the path into each line before delayed expansion ran and lost the `!` all over again. From a folder named `sin!cript test` the elevated relaunch pointed at a file that did not exist (so UAC seemed to have been *declined*), the working directory never changed, and `hosts`, `boot.config`, `SetTimerResolution.exe`, `app.asar` and every preset were reported missing. The path is read late everywhere now, and the three routines that received it as a `call` argument get it through a variable instead. The lock finder had the same bug for typed paths — `Wow!.pdf` came back "No such file" — and is fixed the same way. **Test 127.** A `!` in the Windows *user name* was a separate problem: see the entry above.
- **Fixed: a `"` typed at the timer-resolution prompt closed sincript, and `50!0` passed as a number.** The check that the value is all digits spliced it into its own code with `%_res%`. A quote then ended the string early — *The syntax of the command is incorrect.*, and the window closed — and delayed expansion dropped a lone `!` before the digits were checked. The check reads the value late now (`!_res!`), which takes it verbatim, and **test 122** fails if any `for /f` validator splices typed input in again.
- **Fixed: *Revert power settings* closed sincript.** Every `PowerPlan_*.bat` written since the plan-default fallback was added ended in a syntax error: the generator reused its double-quote variable as a cache, so the file's last check came out as `if %~1== pause`. The restore itself ran and printed `[OK]`, then the error ended the undo file — and because the revert screen `call`ed it, and a syntax error ends *all* batch processing, sincript closed as well. The generator has its own cache variable now, both revert screens run the undo file in a child `cmd` so a broken file can only end itself, and **test 126** runs both generators and dry-runs what they write instead of only reading their text. An undo file written by the broken version still puts the settings back — the error is on its last line — but exits with code 255, so the revert screen shows `[WARN]` after the file's own `[OK]`.
- **Fixed: typing landed *inside* a question instead of after it.** Fourteen `set /p` prompts were longer than the 100-column console the script asks for, and a prompt longer than the line makes cmd put the input caret at *(length mod width)* — so at the Disk Cleanup, firewall-block, Edge and OneDrive questions the first keystroke overwrote the middle of the text. The prompt wording was never the problem; the explanation now sits on its own line above a short question, in the same style the advisories already use, and a new check measures every prompt against the width the script sets.
- **New: an undo file for the telemetry services and tasks.** Privacy disables two services and nine scheduled tasks, and that was the one corner with nothing captured first — `sc config` and `schtasks /Change` leave no `.reg` behind. A runnable `Telemetry_<stamp>.bat` is now written *before* anything is disabled, on every path that reaches the disables, and **Backups & status → 7** replays it. State comes from the registry and `Get-ScheduledTask`, never from localized `sc qc` text; anything you had already disabled yourself is written as a comment rather than restored.
- **Audit pass: two dozen fixes, mostly about honest reporting.** `:Run`/`:RunLive` no longer split a path containing a space (doubled quotes meant `del` of `"C:\Program"` and `Files\..."`); `if errorlevel 1` missed negative exit codes, so DISM's HRESULTs logged as OK; the Store re-register, timer-resolution removal and restore-point steps each claimed success without checking; four `for /f` validators accepted anything after a `;`, one of which let a shared `.preset` run PowerShell as admin; 189 typed-input comparisons are late-expanded so a lone `"` cannot abort the script; the power undo records the value actually in effect rather than a comment; and the backup prune keeps the newest of *each* registry hive instead of the two newest files.
- **Fixed: *Manage startup programs* rendered nothing until a key was pressed.** Two variables in that path were named `_susig` and `_SUSIG` — and `cmd` variable names are **case-insensitive**, so those were one slot: clearing the value blanked the file path. The empty path reached PowerShell as a null `-FilePath`, and `Out-File` **prompts** for a missing mandatory parameter — in a minimized window nobody can answer, so the screen sat waiting. The fingerprint check added alongside it was also silently inert. Renamed, plus a guard so a missing path can never reach `Out-File` at all. **Test 118** now derives every `set "NAME="` in the script and fails on any pair differing only by case; it immediately found a second latent pair (`_src` / `_SRC`) in the OpenAsar installer.
- **HAGS screen states what HAGS currently is.** The toggle offered on/off without saying which was already stored, so the choice was blind and a second visit could not tell whether the first had worked. It now reads `HwSchMode` and reports on / off / not-set (not-set being the Windows default on 2004+), with a note that the stored value is not necessarily what the GPU is doing until a reboot. One `reg query`, no PowerShell — the screen stays instant. **Test 119.**
- **Status carries the same machine header as the main menu.** `Build · Win11 · GPU · Machine · Disk` appeared only on the main menu, so Status showed less about the machine than the screen you came from. **Test 119.**
- **New: undervolt-tool detection.** The header and Status now report whether a tool that *can* undervolt is installed — ThrottleStop, Intel XTU, AMD Ryzen Master — and every one found is listed, since having two is normal. It costs about 100 ms of registry queries, no PowerShell. It reports a **tool, never a voltage**: nothing here can read an actual offset, so "no known tool found" is explicitly labelled *unknown, not no* — a BIOS/EFI undervolt leaves no signature. That asymmetry is deliberate and asserted: the probe may only ever **strengthen** the Ultimate Performance warning, never soften it, because a false negative is exactly how someone gets talked into the plan that produced a WHEA `0x124` on real hardware. When a tool is found, the laptop advisory names it and spells out the consequence. **Test 120.**
- **Validators could have been bypassed *and* executed what they rejected.** `cmd` runs each side of a pipe in a child and re-parses the expanded text there, so `echo(!value!| findstr …` never showed the value to `findstr`: `1.1.1.1&cmd` ran `cmd` and got approved. Affected `:_ip4_ok` (typed resolvers, and `dns=` in a preset), the Unity job-worker prompt, and the non-ASCII test in both backup writers. All now validate in-shell or through a file — no child process, nothing re-parsed. **Tests 101, 116.**
- **Startup flips could have hit the wrong entry.** Entries are addressed by number and the toggle pass re-enumerates, so an entry added or removed in between shifted the target; only the bounds were checked. The list pass now fingerprints the enumeration and the toggle pass refuses on a mismatch. **Test 117.**
- **Session state leaked between actions.** Custom-preset directives, the `_PWPLAN` power-plan choice and the `_RUNTRACK` failure tally all survived into later actions — so a preset could apply keys its own file never contained, and menu 4 could decide which plan a later preset activated. **Tests 88, 102–104.**
- **"Exit" could have stopped meaning exit.** `:RequireBundledFile` aborted by jumping to a menu from inside a `call`, leaving the frame pending; the next `exit /b` returned into it instead of ending the script. It returns a status now, and no `call`ed routine may jump to a menu. **Test 105.**
- **Silence where there should have been a message.** An uncreatable backup folder went unreported while `:Log` spewed a path error per call; debloat printed `[OK]` whatever happened, and unelevated found nothing while saying so cheerfully; a declined UAC prompt just closed the window. All now report, and debloat refuses unelevated. **Tests 106–108.**
- **Disk and environment used to be untidied.** Each Windows Update reset orphaned another 1–5 GB in `%SystemRoot%` with nothing to remove or even mention it; eight worker temp files used fixed names two windows would share; one handoff variable was never cleared. **Tests 109–110.**
- **A menu with no input spun at 100% CPU forever.** `set /p` cannot tell an exhausted stdin from a bare Enter, so a redirected or closed stdin left every prompt looping with no exit. Bounded now, with a clear message. **Test 113.**
- **Small correctness fixes.** A hybrid AMD+NVIDIA machine got only the AMD half; a malformed preset file could abort the run; the OpenAsar download guard could never fire because `del` clears errorlevel; the backup-folder size total counted every export under 1 MB as zero. **Tests 111–112, 115.**
- **New: a `/preset:` command line.** `PerfTweaks.cmd /preset:light|moderate|heavy|NAME [/dns:…] [/plan:…] [/norestore]`, with real exit codes — see [Command line](#command-line). It shares one definition of each preset with the menu rather than a second copy, validates everything before changing anything, and does **not** self-elevate (a relaunch would return an exit code for the relaunch, not the work). `/plan:` exists because unattended there is no prompt to reconsider at and `power=1` otherwise means Ultimate Performance — on an undervolted laptop a real bugcheck `0x124`. **Test 114.**
- **Known, not fixed — the per-value `.reg` backup mangles data containing `!`.** `:SafeRegAdd` captures `reg query` output while delayed expansion is on, which eats `!` and substitutes environment variables: `pre!PATH!post` is backed up with the entire PATH inside it. Unreachable in practice — every `REG_SZ` value sincript touches holds a number or one word — but it is a silent corruption of an undo, so it is recorded rather than left implicit. The fix means restructuring the script's most safety-critical routine; the full registry export (**Backups & status → 2**) is exact for every type and is the fallback.
- **Network & DNS: your own resolver, and flushing the cache on its own.** *Set DNS* was three providers or nothing; there is now a **Custom server** option for a router, a Pi-hole, NextDNS or a corporate resolver, and the preset key `dns` accepts a literal IPv4 as well as the three names. A typed address is free text on its way to a command line, so it is charset-checked (digits and dots only, which is what stops `&`/`|`/`<`/`>` being read as operators), range-checked per octet, and every use is late-expanded so even a value that got through would stay literal — the preset door runs the same validator, or it would just be the way round the menu. **Flush DNS cache** is its own item on menu 5 now instead of being reachable only inside *Reset network stack*: flushing is the fix you actually want when a site moved and Windows is still using the old address, and it should not cost you a winsock reset to get it. The DNS screen also prints what is currently set before offering to change it, read from the Tcpip interface keys rather than `netsh` output — that output is localized, so parsing it would show nothing on a non-English Windows and the failure would read as *no DNS set* rather than as an error. Custom-DNS input is guarded by **test 101**.
- **The power-settings undo file reports what actually happened.** `PowerPlan_*.bat` used to end with a flat *Power settings restored.* whatever the outcome, so a run that could write nothing — not elevated, or the scheme since deleted — still read as success. Every restore line now goes through a small counting helper and the file ends with `[OK] Restored n` or `[WARN] n restored, m FAILED`, carrying the failure count as its exit code. Generated output is real `cmd` and gets the same honesty rule as the script that wrote it; **test 91** now checks the generated file the way the rest of the suite checks this one.
- **The power plan is a choice now, and Ultimate carries a real warning.** Menu 4 used to ask a yes/no where "yes" silently meant **Ultimate Performance** — a workstation plan Windows *hides* on battery-powered machines, which pins the minimum processor state at 100% and disables both core parking and PCIe link power management. On a laptop running an undervolt (ThrottleStop, XTU, vendor tuning) that step change to sustained maximum clocks is exactly where a stable undervolt stops being stable: the core computes wrong and the CPU reports it as an uncorrectable machine check. Not theoretical — it produced a **WHEA 0x124** on real hardware during testing, `MCi_STATUS` decoding to *internal parity error* with *processor context corrupt*, no memory address attached. The plan is now picked from a list with the trade-offs written out, laptops get an advisory naming the undervolt interaction specifically, and Balanced is reachable so there is an in-app way back to the Windows default. New preset key **`power_plan=ultimate|high|balanced`**; `power=1` alone still means Ultimate. Guarded by **tests 88-90**.
- **Disk probe now runs once per machine, not once per session.** Putting `Disk=` on the main-menu header made every launch wait a second or two before the menu drew. The cost was never the IOCTL — that part is microseconds — it is `Add-Type` compiling the P/Invoke shim in C# at runtime. Swapping in a "faster" detector would mean `Get-PhysicalDisk` / `Get-Partition`, which are precisely what this probe exists to avoid, so the answer was to run the trusted probe less often rather than to trust a worse one. The result is cached in `%LOCALAPPDATA%\Sincript\sysdisk.cache`, keyed on disk 0's device instance path — a plain registry read, instant and locale-independent — so the cache self-invalidates when the storage hardware changes. A failed probe is never cached (one bad run would otherwise become permanent), and a cached value that is not `ssd` or `hdd` is re-probed instead of trusted. Delete that file to force a fresh probe. Guarded by **test 97**.
- **Main-menu header shows the disk type; separators are uniform.** `Disk=ssd` / `Disk=hdd` / `Disk=unknown` now sits next to `Build`, `Win11`, `GPU` and `Machine`, so the SSD-vs-HDD answer driving the SysMain advisory is visible from the front screen rather than only at the prompt that uses it. The probe is cached, so it costs one minimized PowerShell window on the first menu draw and nothing afterwards. Every `====` / `----` separator in the script now renders the same width — **98** columns today, which test 96 enforces — after 61 lines ran a column or two wider than the rest and made the menus sit unevenly, most visibly on the main menu where the closing rule ran two characters past the header. Guarded by **tests 95–96**.
- **Power settings get a real undo, and two things stop being undisclosed.** The power action now captures a `PowerPlan_*.bat` before it changes the scheme or the timeouts, restorable from **Backups & status → Revert power settings** (new item 6; Manage moves to 7). It reads the values out of the registry, not localized `powercfg /query` text, and honest-declines anything the scheme never set. The Performance screen now states that "faster shutdown" includes **`AutoEndTasks=1`**, which force-closes apps at shutdown and takes unsaved work with it — previously sold as pure speed. And **Status** now prints the `Machine class` and `Windows disk` probe results, so the `[ADVISORY]` lines can be checked against what sincript actually concluded rather than taken on trust. Guarded by **tests 91–94**.
- **Power plan: decline the switch, keep the options.** Menu 4 used to end at the main menu the moment you said no to the high-performance plan — taking hibernation-off, minimum CPU state and power-throttling-off with it, none of which need a plan switch at all. `powercfg -change` always targets the *active* scheme, so those settings were never plan-dependent; they were only welded to the switch by sharing a routine. `:DoPowerCore` is now an aggregate over `:DoPowerPlanSwitch` (which scheme is active) and `:DoPowerTimeouts` (tunes the active one), so declining the switch offers *"apply individual power changes to your CURRENT plan instead?"* and continues. The screen also prints your current plan before asking. New preset key **`power_timeouts=1`** applies the timeouts without touching the plan; `power=1` keeps its exact previous meaning and suppresses the redundant second pass. Guarded by **tests 88–90**.
- **Undo-integrity pass (file backups, disclosure, honest tallies).** A debug audit found the registry path fully protected while the *file* path was not. Fixed: the beside-the-file backups for `hosts`, `app.asar` and `boot.config` are now **write-once**, so re-running an action can no longer bury the pristine original (same bug class the `:SafeRegAdd` idempotence skip already guarded); `hosts` restore prefers the oldest Documents snapshot instead of the newest, which was the copy this script itself had just written; OpenAsar and the Unity `boot.config` now **refuse** to write when no backup landed, and `:StartupWorker` verifies its undo `.reg` before flipping an entry. Disclosure: the privacy core's `DisableFileSyncNGSC` (OneDrive) is now an **opt-in prompt plus `onedrive_off` preset key** rather than something *Apply recommended* and every preset applied silently, and the Privacy screen now names the Widgets feed, Start app-launch tracking and `dmwappushservice` (with its MDM caveat). Also: `:Performance` / *Apply recommended* set `_RUNTRACK` so failed service calls are counted, OpenAsar reports a per-flavour failure tally instead of letting one success speak for three, the downloaded nightly is cleaned out of `%TEMP%`, the Status hosts line no longer prints an empty section, `DisableStatusMessages` is compared numerically instead of by substring, and `:BackupSingleValue` maps all five hives. Static harness is now **87** checks (tests 76–87), each mutation-tested against a deliberately re-broken copy.
- **Cleanup expansion.** Core cleanup (presets too) now also clears crash dumps, minidumps, and the Delivery Optimization cache — still Prefetch-free and CleanRoot-gated. Interactive Cleanup adds optional shader / NVIDIA Downloader caches, Recycle Bin empty, Disk Cleanup (`cleanmgr`) and Storage Sense settings launches, plus a free-space before/after report. Status shows system-drive free space, `AppCaptureEnabled`, and search-box suggestions. Guarded by **tests 72–75**.
- **TimerRes remove honesty.** Optional `GlobalTimerResolutionRequests` revert now resets `_FAILS` and finishes via `:Summary` (same bargain as Apply) — no more blind `[OK] Reverted` after a failed HKLM write. Guarded by **test 65**.
- **Win11 quiet surface + Game Bar residual.** Privacy core now also quiets the remaining Start/lock Content Delivery tips, search-box suggestions, and tailored experiences (still reversible via `:SafeRegAdd`). Performance optionally disables Game Bar / Xbox overlay chrome (`AppCaptureEnabled`, Nexus, startup panel) without uninstalling Xbox — recording stays off in the performance core. Privacy optionally applies documented Edge policies (hide first-run, hubs sidebar off, shopping assistant off). Custom preset keys: `gamebar_off=1`, `edge_nudges_off=1`. Guarded by **tests 69–71**.
- **Reliability pass (backup / restore / honesty).** Registry writes now refuse to proceed if the per-value `.reg` (or preset JSON temp) did not land — the same bargain PATH and hosts apply already had. Idempotent skip covers **REG_SZ** as well as DWORD, so a re-apply cannot bury the true-original undo. Hosts **reset** aborts without a landed `hosts.bak`; hosts **restore** falls back to Documents `hosts_*.bak` when the local `.bak` is missing. Presets abort if the JSON temp cannot be created. Timer-resolution install reports via `:Summary` / `_FAILS`; Store re-register is elevation-gated with an exit-code check. SteamLight verifies the Desktop `.lnk` before claiming it; memory-compression disable no longer swallows failures (preset path bumps `_FAILS`); NVIDIA telemetry tasks are found by name prefix (`NvTmRep_` / `NvTmMon_` / `NvDriverUpdateCheckDaily_`) instead of hardcoded GUID `\TN` paths. Guarded by **tests 60–68** (plus Store on **test 28**). Static harness is now **156** checks.
- **VerboseStatus (optional):** Added an opt-in boot/logon diagnostic tweak (`verbosestatus=1`) with honest reporting explaining when `DisableStatusMessages` suppresses it. Guarded by **test 59**.
- **Disable Widgets / News & Interests, and Windows Spotlight on the lock screen:** Included in the Privacy Core, and presets. Guarded by **test 59**.
- **Fixed: parentheses in a status message crashed the tool (mitigations).**  `:Summary` printed its message inside a one-line `if ( ) else ( )` block, so the first `)` in the text — e.g. the mitigations line's `(incl. Downfall/GDS)`, or an empty `()` — closed the block early and aborted the script (*"was unexpected at this time"*). `:Summary` is now written with `goto` branching so the message is never inside `( )`; any caller text is safe. Guarded by **test 58**, which fails if the routine is ever put back into a parenthesised block.
- **System tools (menu 12).** New **PATH editor** — System or User, lists entries, flags dead ones, add / remove-by-number / drop-dead / de-duplicate — and **find what is locking a file** (Restart Manager: lists every holder, marks critical Windows processes and refuses to close them, optional confirmed per-process close, checks for parens in paths). The PATH editor never uses `setx` (it crops at 1024 characters and freezes `%SystemRoot%` into literal paths), backs up the whole value first, and broadcasts the change so new programs see it without a sign-out. Guarded by tests 31–42, 55.
- **Privacy: Windows AI off by policy.** Copilot (user *and* machine policy), **Recall** (enablement blocked, snapshot saving off, data analysis off), **Click to Do**, plus inking/typing personalization and online speech recognition. It rides along everywhere privacy is applied — menu 3, *Apply recommended*, and every preset — through the same backed-up, reversible path. The Privacy screen now also states two things it previously implied away: `AllowTelemetry=0` is only honored on Enterprise/Education (**Home and Pro clamp it to Basic, 1**), and stopping DiagTrack also stops **Xbox achievement sync and the Feedback Hub**. Guarded by tests 43–46.
- **More optional knobs.** *Performance:* Storage Sense off · Windows Search classic scope · **SysMain/Superfetch off**, which first probes the Windows disk and warns before the prompt if it looks like a mechanical HDD. *Power:* CPU power throttling off. *Network:* Delivery Optimization off. *Privacy:* four more telemetry scheduled tasks — looked up **by name** and reported as *found vs disabled* instead of a blind "done" — plus an optional **firewall block** for the telemetry service that flips Windows' own DiagTrack rules. Guarded by tests 47–50.
- **Three popular tweaks verified against Microsoft's documentation and declined** — regrouping svchost (`SvcHostSplitThresholdInKB`), lowering `ServicesPipeTimeout`, and disabling the prefetcher. They are listed with their reasons on *What was excluded*, and test 51 fails if any of them is ever quietly added back.
- **Elevation works when the script path contains an apostrophe** (e.g. `C:\Users\O'Brien\`) — the UAC relaunch now passes `%~f0` via `$env:PT_SELF` instead of embedding it in `Start-Process -FilePath '…'`, where a `'` broke the string and killed the relaunch with no prompt. Guarded by **test 26** (with SteamLight's `PT_SLDIR` hand-off).
- **Per-value backups decline non-ASCII string data instead of corrupting it.** Undo files are written with `echo` (console code page), so non-ASCII `REG_SZ` *prior data* came back as mojibake; such values are now marked *not auto-restorable — use the full backup* (like `REG_BINARY`) and skipped on preset restore. The full `reg export` still restores them correctly.
- **Safe defaults on confirmation prompts.** Each `(Y/N)` gate clears its variable first, so a bare **Enter** = *skip* rather than a stale `Y` (restore-point prompts default to **Yes**). This stops the irreversible **clear-all-Event-Viewer-logs** step firing from a stray Enter.
- **Cleaner log file.** `:Run` logs only `[timestamp] EXEC / OK / FAIL`, not raw command output (which dumped file paths and garbled OEM-code-page errors on non-English Windows). Outcomes are still recorded.
- **SteamLight reports honestly.** `[OK]` is gated on the launcher `.bat` actually being written, so an unwritable Steam folder (e.g. under `Program Files` without elevation) yields `[ERROR]` instead of false success.
- **Honest registry-action reporting.** Registry-heavy actions/presets track a failure tally, print inline `[FAIL]`, and finish via `:Summary` with `[OK]`/`[WARN]`; `:Run` counts failure only when genuinely not elevated. Guarded by tests 13–15, 24–25, 27.
- **Limited mode when UAC is declined.** On failed elevation the script sets a not-elevated flag, explains HKLM/service/boot changes won't work, and asks to continue per-user-only; repair actions gate their final line on elevation. Guarded by tests 17, 28.
- **Preset parser empty-value guard.** A `key=` line with no value no longer aborts the script. Guarded by test 16.
- **hosts apply requires a backup first** — confirmed landed before overwriting the system `hosts`. Guarded by test 18.
- **Preset JSON restore honesty + quote-safe REG_SZ.** `[WARN]`/`[ERROR]` on partial/unreadable backups; `REG_SZ` restores via `Set-ItemProperty` so quotes survive. Guarded by tests 19, 23.
- **OpenAsar targets the newest Discord build by version**, not folder-name order (which could pick an older build after a digit rollover). Guarded by test 20.
- **Per-value backup integrity.** Quotes in prior `REG_SZ` data are escaped, empty values handled, and filenames use `%RANDOM%%RANDOM%` so two values under one key can't collide. Guarded by tests 21–22.
- **Startup programs manager (Apps & files).** New *Manage startup programs* item lists the `Run` keys (HKCU, HKLM, HKLM-WOW64) and both Startup folders and flips entries **Enabled**/**Disabled** via the reversible `StartupApproved` switch Task Manager uses. Nothing is deleted; each flip saves prior state to a tiny UTF-16 `.reg` backup (so non-ASCII names restore), and one PowerShell worker with a fixed sort order flips localized (e.g. Cyrillic) names exactly. Guarded by test 12.
- **Fixed: restoring/resetting the hosts file crashed the script.** An unescaped `)` in `(AV tamper protection?)` inside a one-line `if ( ) else ( )` ended the block early and aborted the batch (*"was unexpected at this time"*) after the file was already written. The parens are escaped and test 9 (cmd block-parse simulation) now catches any unescaped `)` in a block.
- **Fixed: the Ultimate power plan never activated, and clones piled up.** `powercfg -duplicatescheme` with no destination GUID minted a random-GUID copy each run while `/setactive` targeted the canonical GUID, so the High Performance fallback activated and a clone accrued per power-core run. Duplication now targets the canonical GUID itself. Guarded by test 10.
- **Fixed: a failed OpenAsar download could install a broken file.** `Invoke-WebRequest` can leave a partial file, and both paths only checked existence; they now trust the child exit code and delete the leftover first. Guarded by test 11.
- **No more false "success" messages (first wave).** The **full registry backup** confirms both `HKLM` and `HKCU` exports wrote a file (else `[ERROR]`); **DNS apply/reset** counts adapters changed vs failed (e.g. `3 adapter(s), 0 failed`); **OpenAsar** reports which backup was saved, since AV / Controlled Folder Access often blocks the copy into Discord's own folder.
- **Performance: a `Win32PrioritySeparation` choice** — `1` = 42 (0x2A, short fixed quantum — the classic tweak; the Windows dialog will show *background services*, because a fixed quantum treats all apps equally), `2` = 38 (0x26, short variable quantum — the value Windows' *Programs* radio writes, foreground gets the longer slice), `3` = 2 (Windows default — undoes a previous 42 or 38), `N` = unchanged. One mutually-exclusive prompt, so its single-value `.reg` backup captures the true prior value rather than one just written.
- **Prefetch is no longer cleared** — it's placebo (Windows rebuilds it) and against the script's own stance; removed from cleanup/recommended/presets and listed on **What was excluded**.
- **Backup-folder manager (Backups & status).** New *Manage / open backup folder* item summarizes `Documents\PerfTweaks_Backups` by category (counts + MB), opens it in Explorer, and offers a safe prune of **older full-registry exports** while keeping the newest pair. The small `.reg` and preset-JSON undo data is never deleted.
- **In-app single-value restore (Backups & status).** New *Restore a single value backup (.reg)* item lists per-value `.reg` backups (newest first) and re-imports your pick, logged; full-registry exports (`FullReg_*.reg`) are filtered out. The preset-JSON restore is unchanged.
- **Per-app CPU priority (Advanced).** New *Set permanent process priority* pins a per-`.exe` priority (High / Above normal / Normal / Below normal / Low) via Image File Execution Options (`CpuPriorityClass`), reversible with *Remove override*. Target the `.exe` that actually runs (Task Manager → Details); Realtime isn't offered.
- **Reversibility + WinUtil tweaks.** Nagle and the per-user sync-services disable are now backed up, and the status helper is hardened against a `>` in registry data. Added opt-in items: mouse acceleration off, show file extensions, and **Activity History** off (`PublishUserActivities` / `UploadUserActivities`).
- **GPU hardware scheduling (HAGS).** New Advanced toggle for `HwSchMode` (reversible; needs a reboot and Windows 10 2004+ with a supporting GPU). Kept out of presets because turning it off disables features like NVIDIA DLSS 3 Frame Generation.
- **AMD telemetry opt-out.** The GPU-telemetry action and `gpu_telemetry_off` key now also opt out of the **AMD User Experience Program** (backed up), pointing to AMD Software → Preferences. Previously a no-op on AMD.
- **Status screen + localization.** Adds hibernation, minimum processor state, HAGS and memory compression (read-only), and — with DNS apply/reset — no longer depends on English output: it reads registry/cmdlet properties, filters TCP via `netsh` on the `:` separator (dodging `Get-NetTCPSetting` where `MSFT_NetTCPSetting` is missing), and applies DNS to all physical adapters. Works on Cyrillic Windows.
- **Presets, custom presets & JSON backups.** New **`10. Presets`** menu (light / moderate / heavy + custom `.preset` files), each writing one restorable JSON backup; *What was excluded* moved to item 11.
- **Console-font fix.** The last two inline-PowerShell spots (Unity core detection, `boot.config` rewrite) use the minimized-window pattern; boot.config paths pass via environment variables.
- **Community-guide tweaks.** BCD timers also set `useplatformtick yes`; optional minimum processor state 5%; optional Game Mode off; a *debloat* action (apps reinstallable from the Store).
- **Timer resolution.** SetTimerResolution installs as a hidden logon task plus a system-wide registry switch (needs a reboot); fully removable.
- **Backups moved to Documents** (`Documents\PerfTweaks_Backups`, OneDrive-aware) instead of the drive root.
- **Console compatibility (Windows 10 / Server 2022).** ASCII-only / no BOM, echo-off guard, working-directory fix, suppressed `mode`/`color` errors, ASCII logo — so `@echo off` and the menu render on legacy `cmd.exe`.
- **Unity `boot.config` is CPU-aware** — sets `job-worker-count` / `-maximum-count` to logical processors − 1 before copying into the game's `*_Data` folder.
- **Bundled-file error handling.** Missing/empty `boot.config` or `hosts`, and copy failures, now stop with a clear message.

---

## Troubleshooting

Newest issues first — most are about *elevation* or *reboots*, because that's where
Windows quietly ignores a change that the script did make.

- **A driver still arrived after I blocked driver updates (Advanced → 11).**
  - Restart first: Windows Update rereads its policy only when its service restarts.
  - The policy does not cover drivers that ship inside Windows' own security updates, drivers a feature update installs, or drivers you or a vendor tool install.
  - A newly connected device may still fetch its first driver through Device Installation's own Windows Update search. That is a separate setting sincript does not change, and Microsoft does not document whether this policy covers it.
  - If the Group Policy Editor (`gpedit.msc`) also sets *Do not include drivers with Windows Updates*, Group Policy writes its value back at the next refresh or restart. sincript checks for that after a change and reports it with a `[WARN]`; change the policy in `gpedit.msc` instead.
  - Microsoft does not list Home among the editions for this policy, so on **Home** its effect is unverified.
  - On a work or school PC, a domain or MDM policy may set it differently. The screen names an MDM value when it finds one, but it cannot see a domain policy. On a PC that gets its updates from a WSUS or Configuration Manager server, drivers normally come from that server, and Microsoft's Configuration Manager guidance lists this value among those to remove in that setup — ask your IT first.
- **A tweak "did nothing" until I rebooted.** Expected for several of them — CPU
  mitigations, memory compression, NVMe flags, boot timers, timer resolution. The
  registry value is written immediately; Windows only acts on it at boot. Reboot, 
  then re-check.
- **A privileged change shows `[WARN]` / a `[FAIL]` line.** The window isn't elevated,
  or the key is protected. Close it, relaunch, approve the UAC prompt. `[WARN]` in
  limited mode is honest reporting, not a failure of the script.
- **`AllowTelemetry=0` didn't stick / telemetry still runs.** On **Home and Pro**,
  Windows clamps `AllowTelemetry` to Basic (1) — only Enterprise/Education honor 0. The
  script says so on the Privacy screen; this is Windows, not a bug.
- **Disable CPU mitigations, but another tool still flags Downfall/GDS.** Make sure
  you're on the current build — the combined value is `0x2000003` (it used to be `3`,
  which left Downfall mitigated). Then **reboot** and re-check with
  `Get-SpeculationControlSettings` in PowerShell; the mitigation change only applies at boot.
- **Processor-scheduling dialog shows "background services" after option 1 (42).** Not a
  bug: `42` is a **fixed** quantum, and a fixed quantum treats all apps equally, which is
  exactly what that radio reports. If you want the foreground-favouring value, pick
  **option 2 (38)** — the same value Windows' own *Programs* radio writes.
- **A backup didn't restore a value cleanly.** Non-ASCII `REG_SZ` data and `REG_BINARY`
  are marked *not auto-restorable — use the full backup*; the small per-value `.reg`
  undo can't carry them, but the full `reg export` restores them correctly.
- **Backups aren't in my Documents.** They're written under whichever account is
  elevated. If you elevated with a *different* admin account, they're in that 
  account's Documents.
- **A short black window flickers during DNS / OpenAsar / restore-point / status.** That's
  a deliberately minimized, short-lived PowerShell window so the main console's
  font/colors aren't disturbed. Normal.

## Notes & caveats

- **Run as administrator.** HKLM changes, services, scheduled tasks, BCD edits, and restore points all need elevation. The script elevates itself; approve UAC for the full toolset. In limited mode after declining UAC, expect `[WARN]` on privileged actions — intentional honesty, not a bug.
- **Backups go to your Documents.** They're written under the account that is elevated. On a normal single-admin PC (UAC consent prompt) that's your own Documents; if you elevate with a *different* administrator account, they land in that account's Documents instead.
- **A reboot is recommended** after several tweaks (memory compression, mitigations, NVMe flags, boot timers, timer resolution) for them to fully take effect.
- **Every launch starts one short background PowerShell process.** It measures the refresh rate for the header, runs minimized for two or three seconds and exits on its own; the menu does not wait for it. If it cannot run, the header says `unknown` and the log says why.
- **Brief minimized windows.** Some actions (DNS, Store re-register, OpenAsar download, restore point, the status screen, the check after a Windows Update driver change, the crash & hardware-error report) run PowerShell in a short-lived minimized window so the main window's font/colors aren't disturbed. The flicker is normal.
- **The first launch on a machine is slower than the rest.** The main-menu header shows `Disk=ssd` / `Disk=hdd`, and that answer comes from asking the drive directly whether it incurs a seek penalty — which needs a small C# shim compiled at runtime, so it costs a second or two. The result is cached in `%LOCALAPPDATA%\Sincript\sysdisk.cache`, keyed on the storage hardware, so every launch after the first is instant. Delete that file to force a fresh probe; swapping the drive invalidates it on its own.
- **The "Advanced" menu is genuinely advanced.** A few highlights:
- **If you undervolt, do not pick Ultimate Performance.** This is the one warning in this README written from a real crash rather than a precaution. Ultimate Performance pins the minimum processor state at 100% and disables core parking and PCIe link power management, so selecting it moves the CPU to sustained maximum clocks in one step. Required voltage scales with frequency, so an undervolt that is perfectly stable in daily use can be *short* at max — the core then computes wrong and the CPU reports an **uncorrectable machine check** (bugcheck `0x124`, `MCi_STATUS` decoding to *internal parity error* with *processor context corrupt*). It looks like a random BSOD and it is not: it is the undervolt meeting a frequency it was never validated at. Nothing about it is thermal, and the machine can be completely stable otherwise. On a laptop running ThrottleStop, Intel XTU or vendor tuning, pick **2 (High Performance)** or **3 (Balanced)** instead — or ease the offset first. Windows hides Ultimate on battery-powered machines for related reasons; sincript prints an advisory there but will not override your choice.
  - *Disable CPU mitigations* trades security hardening for speed. It disables the Spectre/Meltdown/MDS/SSBD/L1TF set (`FeatureSettingsOverride` bits 0-1) **and** Downfall/GDS (bit 25, `0x2000000`, per Microsoft KB5029778) in one step — the combined value is `0x2000003` (decimal 33554435), with the override mask widened to match so every bit is actually honoured. Only do this where you understand and accept the exposure; a reboot is required. *Re-enable CPU mitigations* puts back Windows' secure default; your exact previous values are in the two `.reg` backups the disable wrote.
  - *NVMe feature flags* may be blocked by Microsoft on fully-patched systems; the script tells you so.
  - *Disable memory compression* frees a little CPU but increases RAM pressure on low-memory PCs.
  - *Windows Update driver installs* (item 11) sets one documented policy, *Do not include drivers with Windows Updates* (`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\ExcludeWUDriversInQualityUpdate = 1`). Know what it costs before you use it:
    - Windows Update stops offering drivers in its update scans. That includes GPU, Wi-Fi and chipset drivers, and also the BIOS/UEFI and device **firmware** that PC makers publish through Windows Update as driver packages. Those can carry security fixes. Microsoft's own guidance is to leave driver updates on.
    - It removes nothing already installed. It does not stop drivers that ship inside Windows' own security updates, or drivers a feature update installs.
    - Windows Update rereads the policy only when its service restarts, so restart Windows after a change. The screen shows the **stored** value, which is not proof of what Windows Update enforces until then.
    - Microsoft lists it for Pro, Enterprise, Education and IoT Enterprise, from Windows 10 1607 (build 14393) on, and does not list Home among its editions. On Home (edition ID `Core...`), on an edition sincript cannot read, or on an older build, sincript still writes it if you ask, but says it cannot verify the effect.
    - If the Group Policy Editor (`gpedit.msc`) sets the same policy, Group Policy writes its own value back at the next refresh or restart. The screen says so before the choice. After a change, sincript reads the local Group Policy file (`%SystemRoot%\System32\GroupPolicy\Machine\Registry.pol`). A setting there that matches the change gets an `[i]`. One that differs is a `[WARN]`, counted like a failed write so no `[OK]` follows, and logged. The summary under it says the change was made and read back and what Group Policy will do: override a block, or put its own value back after *Allow*. If you allow drivers and gpedit holds `0` (*Disabled*), drivers stay allowed, and the summary says so. That check starts a short minimized PowerShell window, so it runs only after a change, never when the screen is drawn. It reads the policy's own entry and the two delete markers (`**del.` for this value, `**DelVals` for the whole key), and the last one in the file wins. It does not parse the list forms (`**DeleteValues`, `**DeleteKeys`); gpedit writes this policy as a plain DWORD.
    - On a work or school PC, MDM can set the same policy. By default, Group Policy wins over MDM for Windows Update, so this can override your organization's setting; the screen names an MDM value when it finds one, and with no local value it reports the MDM value as the state. MDM can also tell Windows Update to ignore Group Policy altogether (`IgnoreWindowsUpdateGroupPolicies`, for now a Windows Insider policy); then the screen says a local value does nothing, and a block is reported as written but unverified.
    - On a laptop, an extra advisory points out that laptop makers can ship BIOS/UEFI, battery and embedded-controller firmware this way. While the block is on, check the maker's support site or tool yourself.
    - Turning it back on **deletes** the value (*Not configured*) rather than writing `0` (*Disabled*), so nothing is left behind. It is never part of a preset, *Apply recommended* or `/preset:`.
- **Opt-in only.** Riskier items such as disabling mitigations and enabling `LargeSystemCache` are never part of the "recommended safe set" — you must select them yourself.
- **Console appearance.** The script uses a magenta theme and a small "SIN" logo. It runs in your default console font (Consolas on most systems) and changes no system-wide console, scaling, or registry settings beyond the tweaks you choose.

## "What was excluded" — the philosophy

The in-app **`11. What was excluded`** screen lists, by category, the popular
"tweaks" this script intentionally omits — for example security-weakening
changes (disabling Defender, the firewall, UAC, or SmartScreen), placebo or
obsolete registry values, clearing the Prefetch folder (Windows just rebuilds
it, slowing the next few launches), firewall rules that block Google/YouTube IP
ranges, hard-coded MTU values, bulk undocumented GPU dumps, and raising `TdrDelay`
to "fix" display-driver resets. It also covers
items from popular gaming guides that are deliberately skipped — Windows
activation scripts, replacing Defender with a third-party antivirus, aggressive
RAM / standby "cleaners", and forcing MSI mode or NIC parameter edits (which the
experienced guides themselves advise against). Read it to understand the safety rationale.

**Disabling Windows Update is excluded; one scoped driver policy is not.**
- *Fully disabling Windows Update* (stopping the service, pointing it at a fake server, blocking its hosts) stays on the excluded list, because it stops security updates.
- Advanced → 11 is deliberately narrower: one documented Group Policy value that stops Windows Update offering **drivers**. Cumulative and security updates keep arriving, and deleting the value undoes it.
- It is still a trade-off, because driver and firmware security fixes stop too. That is why it sits under Advanced with its costs printed first.
- The separate *Device installation settings* switch (`SearchOrderConfig`) is not offered at all:
  - The value that dialog writes is not documented by Microsoft. It reads `3` on a test machine, which is none of the values (`0`, `1`, `2`) that Microsoft's matching Device Installation policy defines.
  - Microsoft's IoT Enterprise guidance uses the Windows Update driver policy alone to stop driver installs from Windows Update. It adds the Device Installation policies only when turning off every Windows Update feature.

Five tweaks other optimizers ship were checked against
Microsoft's own documentation and left out on the evidence:

- **Regrouping svchost services** (`SvcHostSplitThresholdInKB`). Windows splits
  services into separate processes above 3.5 GB of RAM *on purpose*: Microsoft
  documents the benefits as reliability, **inter-service isolation**, per-service
  resource management and clearer diagnostics — and describes the footprint saving
  from regrouping as *modest*. Isolation is worth more than the RAM, so this sits
  under security-weakening alongside VBS/HVCI.
- **Lowering `ServicesPipeTimeout` to 30000.** 30 seconds already *is* the
  Service Control Manager's default, so the write changes nothing — and `60000` is
  the well-known **fix** people apply when a service legitimately needs longer to
  start, so applying this would silently undo it.
- **Disabling the prefetcher** (`EnablePrefetcher=0`). The same cost as clearing
  the Prefetch folder — which this script already declines, because the next
  launches just get slower — only permanent, and for close to nothing on an SSD.
  SysMain on/off is offered separately, under Performance.
- **Raising `TdrDelay` or setting `TdrLevel=0`** to "fix" *Display driver stopped
  responding and has recovered*. Microsoft documents these GraphicsDrivers values
  for testing and debugging during driver development and says end users shouldn't
  change them; `TdrLevel=0` turns detection off entirely. The crash & hardware-error
  report points at the causes Microsoft lists instead: the display driver first,
  then over-clocked parts, cooling and power.
- **Setting a fixed page file, or turning it off.** Microsoft's page-file guidance
  says the right size depends on the crash-dump setting and the peak committed
  memory of that particular machine, so a value copied from another PC is a guess.
  With no page file at all, committed memory is capped just below RAM, and no crash
  dump can be written without a dedicated dump file. sincript therefore never writes
  the page-file setting: *Show current status* displays it, and warns only when
  Microsoft documents a problem with it. Unlike the four above, this item is
  described here only; the in-app *What was excluded* screen does not list it.

---

## Tests

Sincript ships with a **static-analysis** harness in `tests/`. `PerfTweaks.cmd`
is interactive and changes the system, so it can't be safely unit-tested by
*running* it; instead `tests/Run-Tests.ps1` (156 checks on stock Windows
PowerShell 5.1 — no Pester) parses the script text for invariants that tend to
break silently, including:

- every menu `goto` / `call` resolves to a real label
- no unescaped `)` inside a `( )` block (cmd parser simulation — that class of bug crashed the hosts restore)
- no duplicate `boot.config` keys; `example.preset` keys match the in-script validator
- honest reporting (`:Summary`, `_FAILS`, elevation gating, DNS/OpenAsar/backup guards) does not regress
- backup undo integrity (quote escaping, collision-resistant filenames, hosts backup-before-overwrite)
- the PATH editor never invokes `setx`, keeps `REG_EXPAND_SZ`, and backs up before writing
- the lock finder refuses to close processes Windows marks critical
- advisories (laptop, desktop, disk) stay warning-only and appear **before** their prompt
- the tweaks listed on *What was excluded* are never quietly written back
- every cleanup delete is gated on a proven root, so an unset variable can never collapse `"%TEMP%\*.*"` into `"\*.*"`
- Win11 quiet-surface keys stay in privacy core; Game Bar residual and Edge nudges stay **opt-in** (not folded into performance/privacy cores)
- cleanup core stays Prefetch-free; optional shader/Recycle/cleanmgr buckets stay interactive-only; free-space helpers and Status Disk line stay wired
- file backups stay **write-once** (`hosts`, `app.asar`, `boot.config`); the `hosts` copies in Documents are one per run, while the Documents copy of `app.asar` is a single fixed-name write-once file — either way a re-run can never bury the original
- OpenAsar and the Unity `boot.config` refuse to write with no backup landed, and `:StartupWorker` verifies its undo `.reg` before flipping an entry
- the OneDrive sync block stays **out** of the privacy core and stays wired as an opt-in prompt plus `onedrive_off` preset key
- the Privacy screen keeps naming what the core actually changes (Widgets feed, Start app-launch tracking, `dmwappushservice`)
- actions that track `_FAILS` also set `_RUNTRACK`; OpenAsar keeps a per-flavour failure tally and cleans up its downloaded nightly
- the power action keeps the plan switch separate from the plan-agnostic timeouts, declining the switch still reaches the other options, and `power=1` keeps its original meaning
- the power undo file is captured **before** anything changes, once per action, read from the registry rather than localized `powercfg` text, and stays reachable from the Backups menu
- the `AutoEndTasks` trade-off stays on the Performance screen, and `:Status` keeps showing the hardware probes that drive the advisories
- the main-menu header keeps its `Disk=` marker and probes before printing it, and every separator keeps rendering 98 columns (caret escapes counted as one)
- the disk probe stays cached per machine, keyed on the storage hardware, and never persists a failed or malformed result
- a typed DNS resolver is charset- and range-checked before it reaches a command line, every use is late-expanded, and the preset key runs through the same validator
- the file stays ASCII-only, uniform CRLF and BOM-free — an editor that quietly normalises the bytes is caught here rather than at the next run
- every menu dispatches exactly the numbers it prints, so a renumbering cannot leave a dead option or an unreachable branch
- every `set /p` prompt fits the console width the script asks for — a longer one makes cmd put the input caret at (length mod width), so typing lands *inside* the question
- every `set /p` variable is compared and validated late-expanded (`!var!`, never `%var%`), so a lone `"` in a typed answer cannot abort the run; the targets are read out of the script, so a new prompt is covered the day it is added
- the shipped data files (`hosts`, `boot.config`) are ASCII, BOM-free and end with a newline, so the next `>> hosts` cannot glue onto the last blocked name
- the telemetry undo file is captured **before** the first `sc config`, reads state from the registry and `Get-ScheduledTask` rather than localized `sc qc` / `schtasks /Query` text, and distinguishes "already disabled before Sincript" from "disabled by Sincript"
- no `reg add` / `reg delete` exists outside `:SafeRegAdd` / `:SafeRegDelete`, so no registry change can skip its backup, its `[FAIL]` line or the `_FAILS` tally
- the script's own path is read late everywhere after its capture, and never passed as a `call` argument, so a `!` in its folder survives
- every path under the user profile is read late too, and test 133 **runs** the real cleanup in fake profiles whose user names hold `!`, `%`, `^` and `&`, next to the two profiles the old code hit instead: nothing of theirs may be touched. No such path rides a `call` argument (test 134), and the Documents capture is run with a faked registry answer (test 135)
- the maintenance actions (Windows Update reset, Compact WinSxS, DISM + SFC, Cleanup) report each critical step's real outcome, never a blanket `[OK]`
- partial and failed results elsewhere are reported as such: a non-zero uninstaller exit, a plan fallback, a failed lock query, one of two memory-compression switches, a failed preset backup, a delete that did not happen, a log that was never written
- SteamLight's default flags keep Steam's browser sandbox; the flags that turn it off come only from an explicit, disclosed opt-in
- the undo-file generators (power, telemetry, NVIDIA tasks) are **run**, not only read — into `%TEMP%`, with `powercfg` and the task list faked and anything that could change the system blocked — and each file they write is dry-run the way the Backups menu runs it; the power generator runs with hibernation on, off, default-only and unreadable, and as a capture retried after sincript turned hibernation off. It exists because reading the generator's text missed a file that ended in a syntax error — and it is one of several tests that run code (126, 133, 135, 136, 141, 142, 144, 145, 146, 148, 149, 151, 154, 155); the first four exist because reading the text had missed a real bug
- the DNS screen names its real undo (DHCP, and a typed-in server is not saved) and lists every typed-in resolver per adapter for IPv4 and IPv6; test 136 **runs** that listing with every registry query answered from a file, including an unreadable registry (a `[WARN]`, never "none") and values it cannot name (counted, not hidden)
- the power revert screen names, on screen, what its undo file does not cover, and hibernation is captured into that file before it is turned off
- no screen promises an undo the code does not have: each audited screen must carry the wording that says what its undo really is, and must not carry the false wording it used to
- the Windows Update driver toggle writes the one documented, correctly spelled policy value under the right key; turns drivers back on by deleting it; reads the value back and counts a wrong or unreadable result before reporting; checks the Group Policy Editor's file on the write path only; and stays out of presets, the safe set and `/preset:`. Its screen prints the costs before the choices, reads state with no PowerShell, uses one state vocabulary everywhere, and fits the console. Status and *What was excluded* agree with it (tests 139–140)
- tests 141 and 142 **run** the Windows Update driver screen and its two handlers, with every registry read answered from a file and the writes stubbed: which stored values count as blocked, which editions count as Home, what an MDM value, the ignore-Group-Policy switch or an unreadable registry does to the state line, that a wrong read-back ends in `[FAIL]` and `[WARN]` rather than `[OK]`, and how a Group Policy Editor setting in a faked `Registry.pol` is reported
- the Status screen's page-file section stays **read-only**: its worker may use only commands, methods and types on a read-only allowlist, read with PowerShell's own parser, and no other code line in the script may even name a page-file or crash-dump setting (test 143). Its classifier is **run** on 39 synthetic machines, with the registry and WMI faked and anything that could change the system blocked: a system-managed file is never judged small, a missing, unrecognised or unreadable setting is never judged, and the peak probe that costs a C# compile runs only where its verdict can fire (144). The display is run on every record at its widest and must fit the console (145), and the worker's real compile and `GetPerformanceInfo` call run once, checked against an independent reading (146)
- the crash & hardware-error report only reads: it never goes through `Get-WinEvent` (whose `-FilterHashtable` answers an unreadable log with "no events"), proves each log readable before counting, reads newest first so an event cap keeps the latest events, classifies WHEA errors by event ID in one place and does not read the informational ones, and says how many days each log covers (test 147). Its classification is **run** on synthetic events — one crash counted once, WHEA id 29 uncorrected at the warning level, an unreadable log never "none found", no driver or sincript session blamed from outside the week before the first crash, a capped read bounded by the days it read (148) — and its collector is **run** against a faked event-log reader in which one log is refused, both at the first read and mid-read, and in which a cap of 3 must keep the three newest events (149)
- no PowerShell helper in its workers is named like an alias (an alias runs instead of the function: `R` is Invoke-History, `Rd` is Remove-Item), and no two of their variables differ only by case — both were real, silent bugs while it was being built (150)
- its final line, hints and saved report are **run** in a contained `cmd`: `[FAIL]` for an unreadable System or Application log, `[WARN]` for a capped or short read, `[OK]` only for a full one; every hint prints on its own evidence and on nothing else; the saved report carries the final line; and a hints file that cannot be written is flagged, never shown as "No hints" (151)
- the refresh rate on the main-menu header never makes the menu wait: the first draw starts one background worker that reads Windows' display API, later draws only look for its answer, and nothing is cached across launches. The header fits the console at its widest (tests 152–153). The parser that turns the worker's answer into the header value is **run** on 32 synthetic answers, including malformed ones and records holding `& ) " % !`, which must all read `unknown` with nothing else printed (154). Its state machine is **run** over simulated menu draws: an answer that lands is kept and its file deleted; a worker that never started gives up at draw 10 and a started one at draw 30; and a late answer still replaces `unknown` (155)
- names in other alphabets survive: the DNS screens, the startup, PATH and lock-finder lists and their result messages read with the console switched to UTF-8 and back, and their workers write UTF-8. **Run** in a hidden console from code page 437, a UTF-8 name comes back intact and 437 is restored (156)

Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

Exit code `0` means all 156 checks passed; `1` means at least one failed, with
the offending detail printed. See `tests/tests_README.md` for the full numbered list.

---

## Disclaimer

Use at your own risk. These tweaks modify system settings; while the script
backs up each change and can create a restore point, you are responsible for
your system. **Make a restore point and/or a full registry backup first** (the
script provides both). Sincript is an independent utility and is not affiliated
with or endorsed by Microsoft, NVIDIA, AMD, Discord, or any other vendor mentioned.
