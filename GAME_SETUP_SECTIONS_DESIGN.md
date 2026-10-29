# BCD Game Setup — New Sections Design Proposal

**Status:** Draft proposal  
**Target:** BCD game setup page (`BCDGameSetupPage.swift`, `BCDGameSetupTables.swift`, `BCDGameSetupPageLiveSetup.swift`)  
**Goal:** Give users granular control over launch args, DLL overrides, runtime verification, and audio diagnostics — per game.

---

## 1. Launch Arguments Section

### Purpose
Unified UI to configure what the game/launcher receives at startup.

### Two Modes

| Mode | Source | What user sees |
|------|--------|----------------|
| **Steam game (BCD Dock)** | Steam's own launch options + BCD Dock args | "Steam launch options" text field (synced from Steam) + "BCD Dock extra args" field |
| **Non-Steam (standalone .exe)** | `LibraryEntry.arguments` + `LibraryEntry.launchArguments` | Single "Command line arguments" field; placeholder shows `%command%` convention |

### Data Model

```swift
// LibraryEntry additions
var steamLaunchOptions: String?      // from Steam, read-only display
var bcdDockExtraArgs: String         // appended after Steam's options
var standaloneArgs: String           // for non-Steam entries
```

### UI Layout

```
┌─ Launch Arguments ────────────────────────────────────┐
│ Steam game:                                           │
│   Steam launch options:  [ -novid -high        ]  ← read from Steam
│   BCD Dock extra args:   [ -dx11                 ]  ← user editable
│                                                       │
│ Non-Steam game:                                       │
│   Command line args:     [ %command% -windowed   ]  ← user editable
│                                                       │
│ [i] %command% expands to the game's executable path  │
└───────────────────────────────────────────────────────┘
```

### Persistence
- Steam: written to Steam cloud via `steam_launch_options` API on save
- Non-Steam: stored in `LibraryEntry.arguments` (already exists)

---

## 2. DLL Override Section

### Purpose
Let users pick any `.dll` from the game folder (or wine prefix) and set override mode (`builtin`, `native`, `builtin,native`, `native,builtin`, `disable`).

### Data Model

```swift
struct DLLOverride: Codable, Hashable, Identifiable {
    var id: String { dllName }                    // e.g. "xaudio2_9.dll"
    var dllName: String                           // filename only
    var sourcePath: String?                       // relative to game folder or wine prefix; nil = wine search path
    var mode: OverrideMode                        // .builtin, .native, .builtinNative, .nativeBuiltin, .disable
    var note: String?                             // user note
}

enum OverrideMode: String, CaseIterable, Codable {
    case builtin = "b"
    case native = "n"
    case builtinNative = "b,n"
    case nativeBuiltin = "n,b"
    case disable = ""

    var display: String {
        switch self {
        case .builtin: return "Builtin (Wine)"
        case .native: return "Native (Windows)"
        case .builtinNative: return "Builtin → Native fallback"
        case .nativeBuiltin: return "Native → Builtin fallback"
        case .disable: return "Disabled"
        }
    }
}
```

### Discovery
- Scan game folder (`%DOCUMENTS%\My Games\...`, game install dir) for `.dll`
- Scan wine prefix `drive_c/windows/system32/` and `drive_c/windows/syswow64/`
- Show in picker grouped by folder

### UI Layout

```
┌─ DLL Overrides ───────────────────────────────────────┐
│ [+ Add DLL Override]                                  │
│                                                       │
│ ┌ xaudio2_9.dll ──────────────────────────────────┐  │
│ │ Source:  Game folder / Fallout4/                  │  │
│ │ Mode:    [Builtin (Wine) ▼]                       │  │
│ │ Note:    Fixes missing footsteps/voices/radio     │  │
│ │ [Remove]                                          │  │
│ └───────────────────────────────────────────────────┘  │
│                                                       │
│ ┌ d3d11.dll ──────────────────────────────────────┐  │
│ │ Source:  Wine prefix / system32/                  │  │
│ │ Mode:    [Native (Windows) ▼]                     │  │
│ │ [Remove]                                          │  │
│ └───────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────┘
```

### Persistence
- Written to game's config file (`GameProfiles.swift` → per-game `.cfg`)
- At launch, `WINEDLLOVERRIDES` env var built from all enabled overrides:
  ```
  WINEDLLOVERRIDES=xaudio2_9=b;d3d11=n;dxgi=b,n
  ```

---

## 3. Runtime Verification Section

### Purpose
Show what runtimes the game needs, what's installed, verify integrity, and install missing ones.

### Detection Strategy

| Runtime | How to detect need |
|---------|-------------------|
| **Visual C++ 2015–2022** | Scan game `.exe`/`.dll` imports for `vcruntime140`, `msvcp140`, `concrt140`, `MFC` |
| **DirectX June 2010** | Scan for `d3dx9_`, `d3dx10_`, `d3dx11_`, `xaudio2_`, `xinput1_3`, `X3DAudio`, `XAPOFX` |
| **.NET Framework** | Check for `mscoree.dll` dependency or `.config` with `<runtime>` |
| **OpenAL** | Scan for `OpenAL32.dll` import |
| **Vulkan** | Scan for `vulkan-1.dll` import |
| **PhysX** | Scan for `PhysX*.dll`, `Nx*.dll` |

### Data Model

```swift
struct RuntimeRequirement: Identifiable {
    var id: String { name }
    let name: String
    let category: Category
    let requiredFiles: [String]           // DLL names to look for
    let installURL: URL?                  // Microsoft/WineHQ download
    let licenseURL: URL?
    var status: Status = .unknown
    var installedVersion: String?
    var installPath: String?
}

enum Category { case vcRuntime, directX, dotNet, openAL, vulkan, physX, other }

enum Status { case unknown, notNeeded, missing, installed, outdated, corrupted }
```

### Verification Logic
1. **Static scan** — parse PE imports of game exe + all DLLs in game folder
2. **Registry check** — read Wine prefix `HKLM\Software\Microsoft\VisualStudio\...` for VC++ versions
3. **File hash check** — compare installed DLL SHA-256 against known good hashes (pinned in BCD)
4. **Functional test** — launch a tiny probe exe that loads each DLL and calls a known entry point

### UI Layout

```
┌─ Runtime Verification ────────────────────────────────┐
│ [Scan Now]                      Last scan: 2h ago     │
│                                                       │
│ ┌ Visual C++ 2015–2022 ────────────────────────────┐ │
│ │ Status:  [●] Installed (14.44.35211.0)           │ │
│ │ Needed:  vcruntime140, msvcp140, concrt140, MFC  │ │
│ │ [Verify integrity]  [Reinstall]  [Remove]        │ │
│ └──────────────────────────────────────────────────┘ │
│                                                       │
│ ┌ DirectX June 2010 (D3DX, XAudio, XInput) ────────┐ │
│ │ Status:  [○] Not needed — Wine builtin + DXMT    │ │
│ │ Note:    BCD uses DXMT; native DirectX not used  │ │
│ └──────────────────────────────────────────────────┘ │
│                                                       │
│ ┌ .NET Framework (Wine Mono) ──────────────────────┐ │
│ │ Status:  [○] Not needed — native C++ game        │ │
│ └──────────────────────────────────────────────────┘ │
│                                                       │
│ ┌ OpenAL ──────────────────────────────────────────┐ │
│ │ Status:  [●] Installed (1.23.1)                  │ │
│ │ [Verify]  [Reinstall]                            │ │
│ └──────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────┘
```

### Persistence
- Results cached per game; re-scan on game update or manual tap
- Install actions call existing `VCRuntimeDownload.install()` / `WineMonoModel.install()`

---

## 4. Audio Troubleshooting Section

### Purpose
Diagnose why audio is missing/muted: missing files, wrong DLL, submix routing, device routing.

### Diagnostic Checks

| Check | Method | What it reveals |
|-------|--------|-----------------|
| **XAudio2 DLL loaded** | Parse Wine log for `xaudio2_7/8/9` load lines | Is builtin or native loading? |
| **Submix voices created** | Wine `+xaudio2` debug channel | Are submix voices being created for dialogue/Foley/radio? |
| **Audio device open** | Wine `+winmm,+dsound,+pulse` | Is CoreAudio endpoint opened? |
| **Game audio files exist** | Scan game folder for `.wav`, `.xwm`, `.fsb`, `.bnk`, `.wem` | Missing assets? |
| **Audio config in game** | Read game's `.ini` / registry for master volume, device selection | Muted in config? |
| **Wine audio driver** | `winecfg` Audio tab (via Windows desktop entry) | Correct driver selected? |

### Data Model

```swift
struct AudioDiagnostic: Identifiable {
    var id: String { name }
    let name: String
    let category: Category
    var status: Status = .unknown
    var detail: String
    var action: Action?
}

enum Category { case dll, submix, device, files, config, driver }

enum Status { case unknown, ok, warning, error, notApplicable }

struct Action {
    let label: String
    let kind: Kind
    enum Kind { case openSettings, runCommand(String), openLog, copyToClipboard(String) }
}
```

### UI Layout

```
┌─ Audio Troubleshooting ───────────────────────────────┐
│ [Run Diagnostics]                    Last run: 5m ago │
│                                                       │
│ ┌ XAudio2 DLL ──────────────────────────────────────┐ │
│ │ Status:  [⚠] Native xaudio2_9.dll loaded         │ │
│ │ Detail:  Submix voices may not route on iOS       │ │
│ │ Action:  [Force builtin xaudio2_9] → sets override│ │
│ └──────────────────────────────────────────────────┘ │
│                                                       │
│ ┌ Submix Voices ────────────────────────────────────┐ │
│ │ Status:  [?] Unknown — run Wine with +xaudio2     │ │
│ │ Action:  [Launch with debug audio]                │ │
│ └──────────────────────────────────────────────────┘ │
│                                                       │
│ ┌ Audio Device ─────────────────────────────────────┐ │
│ │ Status:  [✓] CoreAudio endpoint active            │ │
│ │ Detail:  Stereo, 48kHz, iPhone speaker            │ │
│ └──────────────────────────────────────────────────┘ │
│                                                       │
│ ┌ Game Audio Files ─────────────────────────────────┐ │
│ │ Status:  [✓] Found: Sound.bsa, 12,400 .xwm files │ │
│ │ Detail:  Fallout4 - Sounds.ba2 present            │ │
│ └──────────────────────────────────────────────────┘ │
│                                                       │
│ ┌ Game Audio Config ────────────────────────────────┐ │
│ │ Status:  [⚠] Master volume = 0.5 in Fallout4.ini │ │
│ │ Action:  [Open Fallout4.ini]  [Set to 1.0]        │ │
│ └──────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────┘
```

### "Launch with debug audio" Action
- Creates a temporary launch with `WINEDEBUG=+xaudio2,+dsound,+winmm,+pulse`
- Captures log to `Documents/Logs/audio-diag-<timestamp>.txt`
- Opens log viewer after game exits

---

## Integration Points

### 1. `BCDGameSetupTables.swift`
Add new section IDs and setting keys:

```swift
// New section IDs
static let launchArgsSection = "launchArgs"
static let dllOverridesSection = "dllOverrides"
static let runtimeVerifySection = "runtimeVerify"
static let audioDiagSection = "audioDiag"

// Launch args keys
static let steamLaunchOptionsKey = "launch.steamOptions"
static let bcdDockExtraArgsKey = "launch.bcdDockExtra"
static let standaloneArgsKey = "launch.standaloneArgs"

// DLL override keys (stored as JSON array in single key)
static let dllOverridesKey = "dllOverrides"

// Runtime verify: no persistent keys (cached scan results)

// Audio diag: no persistent keys (run-on-demand)
```

### 2. `BCDGameSetupPage.swift` — `sections(_:)`
Append new sections after `fixesSection` and `desktopSection`:

```swift
static func sections(_ s: BCDGameSetupState) -> [BCDGameSettingGroup] {
    var out = [windowsSection(s), componentsSection(s), fexSection(s)]
    if let places = savesSection(s) { out.append(places) }
    out.append(fixesSection(s))
    out.append(launchArgsSection(s))      // NEW
    out.append(dllOverridesSection(s))    // NEW
    out.append(runtimeVerifySection(s))   // NEW
    out.append(audioDiagSection(s))       // NEW
    if let desktop = desktopSection(s) { out.append(desktop) }
    return out
}
```

### 3. `BCDGameSetupPageLiveSetup.swift` — State & Persistence
- Add `launchArgs`, `dllOverrides`, `runtimeScan`, `audioDiag` to `BCDGameSetupState`
- Implement `setupLine`/`readLine` for each key
- On save: merge into game's config file + write `WINEDLLOVERRIDES` to bcd.cfg env vars

### 4. `BCDGameSetup/BCDGamePageLiveSetup.swift` — UI
New view builders for each section using existing patterns (`BCDGameSetting`, `BCDGameSettingGroup`, `BCDSettingsActionRow`, `BCDProgressBar`).

### 5. Native Bridge (`WineProcessBridge.m`)
- Add `madeira_build_winedlloverrides()` called at session start
- Reads game's config + bcd.cfg → builds `WINEDLLOVERRIDES` env var
- Already exports `env.NAME` from bcd.cfg; extend to merge game-specific overrides

---

## Dependencies & New Files

| Area | New Files / Changes |
|------|---------------------|
| **Models** | `DLLOverride.swift`, `RuntimeRequirement.swift`, `AudioDiagnostic.swift` |
| **Scanners** | `PEImportScanner.swift` (static analysis of game exe/DLLs), `RuntimeScanner.swift` |
| **Diagnostics** | `AudioDiagnostics.swift` (orchestrates debug launches, parses logs) |
| **UI** | New section builders in `BCDGameSetupPageLiveSetup.swift` |
| **Persistence** | Extend `BCDGameSetupState`, `GameProfiles.swift` for new keys |
| **Native** | `WineProcessBridge.m`: `madeira_build_winedlloverrides()` |

---

## Rollout Phases

| Phase | Scope |
|-------|-------|
| **1** | Launch Arguments (Steam + standalone) — minimal UI, high impact |
| **2** | DLL Overrides — picker + JSON persistence + `WINEDLLOVERRIDES` builder |
| **3** | Runtime Verification — static scan + VC++/Mono install buttons |
| **4** | Audio Diagnostics — debug launch + log parsing + one-tap fixes |

---

## Open Questions

1. **DLL picker scope** — limit to game folder + wine prefix, or allow Files app import?
2. **Runtime scan performance** — PE parsing on large game folders may need background queue + caching.
3. **Audio debug launch** — requires separate Wine session; may need "diagnostic mode" flag in `MADEIRA_ARGS`.
4. **Steam launch options sync** — requires `SteamGamesRules` to expose per-app launch options API.

---

## Related Existing Code

| File | Relevance |
|------|-----------|
| `BCDGameSetupPage.swift` | Section definitions, settings UI |
| `BCDGameSetupTables.swift` | Keys, parsing, validation |
| `BCDGameSetupPageLiveSetup.swift` | Live state, save/load |
| `Library.swift` | `LibraryEntry` — arguments, launch mode |
| `WineProcessBridge.m` | Session start, env var export, `madeira_vcruntime_dir` |
| `VCRuntimeDownload.swift` | VC++ runtime install API |
| `WineMono.swift` | Wine Mono install API |
| `BCDLiveStore.swift` | Steam launch options handling |
| `BCDLaunchers.swift` | Launcher arguments merging |

---

*End of design proposal*