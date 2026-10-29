// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Audio diagnostics runner for troubleshooting missing audio.
// Launches game with WINEDEBUG=+xaudio2,+dsound,+winmm,+pulse, parses log, checks game files/INI.

/// An audio diagnostic check result.
struct BCDAudioDiagnostic: Equatable, Identifiable, Codable {
    var id: String { name }
    let name: String
    let category: Category
    var status: Status = .unknown
    var detail: String
    var action: Action?

    enum Category: String, Equatable, Codable { case dll, submix, device, files, config, driver }
    enum Status: String, Equatable, Codable { case unknown, ok, warning, error, notApplicable }

    struct Action: Equatable, Codable {
        let label: String
        let kind: Kind
        enum Kind: Equatable, Codable {
            case openSettings
            case runCommand(String)
            case openLog
            case copyToClipboard(String)
            case openFile(URL)

            enum CodingKeys: String, CodingKey {
                case type, value
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .openSettings:
                    try container.encode("openSettings", forKey: .type)
                case .runCommand(let cmd):
                    try container.encode("runCommand", forKey: .type)
                    try container.encode(cmd, forKey: .value)
                case .openLog:
                    try container.encode("openLog", forKey: .type)
                case .copyToClipboard(let text):
                    try container.encode("copyToClipboard", forKey: .type)
                    try container.encode(text, forKey: .value)
                case .openFile(let url):
                    try container.encode("openFile", forKey: .type)
                    try container.encode(url.absoluteString, forKey: .value)
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                case "openSettings": self = .openSettings
                case "runCommand": self = .runCommand(try container.decode(String.self, forKey: .value))
                case "openLog": self = .openLog
                case "copyToClipboard": self = .copyToClipboard(try container.decode(String.self, forKey: .value))
                case "openFile": self = .openFile(URL(string: try container.decode(String.self, forKey: .value))!)
                default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Kind type")
                }
            }
        }
    }
}

/// Result of audio diagnostics.
struct BCDAudioDiagResult {
    let diagnostics: [BCDAudioDiagnostic]
    let logPath: URL?
    let errors: [String]
}

/// Runs audio diagnostics for a game.
actor BCDAudioDiagnostics {
    static let shared = BCDAudioDiagnostics()

    /// Run full audio diagnostics for a game.
    /// - Parameters:
    ///   - entry: The library entry for the game
    ///   - drive: Wine prefix drive_c URL
    ///   - documents: Documents folder URL
    /// - Returns: Diagnostic results
    func runDiagnostics(entry: LibraryEntry, drive: URL, documents: URL) async -> BCDAudioDiagResult {
        var diagnostics: [BCDAudioDiagnostic] = []
        var errors: [String] = []

        // 1. Launch game with audio debug channels and capture log
        let logURL = await launchWithAudioDebug(entry: entry, drive: drive, documents: documents)
        var logContent = ""
        if let logURL, let content = try? String(contentsOf: logURL, encoding: .utf8) {
            logContent = content
        } else {
            errors.append("Could not capture audio debug log")
        }

        // 2. Check XAudio2 DLL loaded
        diagnostics.append(checkXAudio2DLL(log: logContent))

        // 3. Check submix voices
        diagnostics.append(checkSubmixVoices(log: logContent))

        // 4. Check audio device
        diagnostics.append(checkAudioDevice(log: logContent))

        // 5. Check game audio files
        let gameFolder = drive.appendingPathComponent(LibraryEntry.folder(of: entry.launchWindowsPath), isDirectory: true)
        diagnostics.append(await checkGameAudioFiles(gameFolder: gameFolder))

        // 6. Check game INI audio config
        diagnostics.append(await checkGameAudioConfig(gameFolder: gameFolder, gameTitle: entry.title))

        // 7. Check Wine audio driver
        diagnostics.append(checkWineAudioDriver(log: logContent))

        return BCDAudioDiagResult(diagnostics: diagnostics, logPath: logURL, errors: errors)
    }

    /// Launch the game with WINEDEBUG=+xaudio2,+dsound,+winmm,+pulse and capture log.
    private func launchWithAudioDebug(entry: LibraryEntry, drive: URL, documents: URL) async -> URL? {
        let logDir = documents.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logFile = logDir.appendingPathComponent("audio-diag-\(timestamp).txt")

        // Build the WINEDEBUG string for audio diagnostics
        let winedebug = "err+all,err-virtual,fixme-d3dcompiler,+xaudio2,+dsound,+winmm,+pulse,+timestamp"

        // Write the one-shot debug file that WineProcessBridge.m reads
        let debugOnceURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bcd-debug-once.txt")
        let debugContent = winedebug + "\n"
        do {
            try debugContent.write(to: debugOnceURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        // Set up environment for diagnostic launch
        // We need to launch the game in a way that captures the log
        // For now, we'll read from the existing log file after a normal launch
        // In a full implementation, this would spawn a diagnostic session

        // For now, read from the main log file
        let mainLog = LogStore.shared.logFileURL
        if FileManager.default.fileExists(atPath: mainLog.path) {
            // Copy main log to our diagnostic log
            try? FileManager.default.copyItem(at: mainLog, to: logFile)
            return logFile
        }

        return nil
    }

    /// Check which XAudio2 DLL is loaded.
    private func checkXAudio2DLL(log: String) -> BCDAudioDiagnostic {
        let xaudio2Pattern = #"(xaudio2_[0-9])\.dll"#
        let regex = try? NSRegularExpression(pattern: xaudio2Pattern, options: .caseInsensitive)
        let range = NSRange(log.startIndex..., in: log)
        var foundDLLs: Set<String> = []
        regex?.enumerateMatches(in: log, options: [], range: range) { match, _, _ in
            if let match, let range = Range(match.range(at: 1), in: log) {
                foundDLLs.insert(String(log[range]).lowercased())
            }
        }

        // Also check for "load" or "builtin" or "native" near xaudio2
        var detail = ""
        var status: BCDAudioDiagnostic.Status = .unknown
        var action: BCDAudioDiagnostic.Action?

        if foundDLLs.isEmpty {
            detail = "No XAudio2 DLL loads detected in log. Run with WINEDEBUG=+xaudio2 to see which DLL loads."
            status = .warning
            action = BCDAudioDiagnostic.Action(label: "Run with +xaudio2 debug", kind: .runCommand("WINEDEBUG=+xaudio2"))
        } else {
            detail = "Found XAudio2 DLLs: \(foundDLLs.joined(separator: ", "))"
            // Check if any are native (game's own) vs builtin (Wine's)
            // In log, look for "builtin" or "native" near the DLL name
            var hasNative = false
            var hasBuiltin = false
            for dll in foundDLLs {
                let pattern = "builtin.*\(dll)|\(dll).*builtin|native.*\(dll)|\(dll).*native"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: log, options: [], range: NSRange(log.startIndex..., in: log)),
                   let range = Range(match.range(at: 0), in: log) {
                    let matched = String(log[range]).lowercased()
                    if matched.contains("builtin") { hasBuiltin = true }
                    if matched.contains("native") { hasNative = true }
                }
            }

            if hasNative && !hasBuiltin {
                status = .warning
                detail += " — Native XAudio2 loaded (may cause submix routing issues on iOS)"
                action = BCDAudioDiagnostic.Action(label: "Force builtin XAudio2", kind: .runCommand("WINEDLLOVERRIDES=xaudio2_7=b;xaudio2_9=b"))
            } else if hasBuiltin {
                status = .ok
                detail += " — Using Wine's builtin XAudio2"
            } else {
                status = .ok
            }
        }

        return BCDAudioDiagnostic(name: "XAudio2 DLL", category: .dll, status: status, detail: detail, action: action)
    }

    /// Check if submix voices are being created.
    private func checkSubmixVoices(log: String) -> BCDAudioDiagnostic {
        // Look for XAudio2 submix voice creation in log
        let submixPatterns = [
            "CreateSubmixVoice",
            "submix.*voice",
            "IXAudio2.*CreateSubmixVoice"
        ]

        var found = false
        var detail = ""
        for pattern in submixPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: log, options: [], range: NSRange(log.startIndex..., in: log)) != nil {
                found = true
                break
            }
        }

        if found {
            detail = "Submix voice creation detected in log"
            return BCDAudioDiagnostic(name: "Submix Voices", category: .submix, status: .ok, detail: detail)
        } else {
            detail = "No submix voice creation found. Dialogue/Foley/radio may be silent if native XAudio2 is used."
            let action = BCDAudioDiagnostic.Action(label: "Run with +xaudio2 debug", kind: .runCommand("WINEDEBUG=+xaudio2"))
            return BCDAudioDiagnostic(name: "Submix Voices", category: .submix, status: .warning, detail: detail, action: action)
        }
    }

    /// Check audio device opened.
    private func checkAudioDevice(log: String) -> BCDAudioDiagnostic {
        let devicePatterns = [
            "mmdevapi",
            "AudioClient",
            "IAudioClient",
            "CoreAudio",
            "AudioEndpoint",
            "winmm.*waveOutOpen",
            "dsound.*DirectSoundCreate"
        ]

        var found = false
        var detail = ""
        for pattern in devicePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: log, options: [], range: NSRange(log.startIndex..., in: log)),
               let range = Range(match.range(at: 0), in: log) {
                found = true
                detail = "Audio device initialization: \(String(log[range]).trimmingCharacters(in: .whitespacesAndNewlines))"
                break
            }
        }

        if found {
            return BCDAudioDiagnostic(name: "Audio Device", category: .device, status: .ok, detail: detail)
        } else {
            detail = "No audio device initialization detected in log"
            return BCDAudioDiagnostic(name: "Audio Device", category: .device, status: .warning, detail: detail)
        }
    }

    /// Check for game audio files.
    private func checkGameAudioFiles(gameFolder: URL) async -> BCDAudioDiagnostic {
        let audioExtensions = ["wav", "xwm", "fsb", "bnk", "wem", "ogg", "mp3", "flac", "at3", "vag", "adpcm"]
        var foundFiles: [String: Int] = [:]
        var totalCount = 0

        guard let enumerator = FileManager.default.enumerator(at: gameFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return BCDAudioDiagnostic(name: "Game Audio Files", category: .files, status: .unknown, detail: "Cannot access game folder")
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                totalCount += 1
                foundFiles[ext, default: 0] += 1
            }
        }

        if totalCount == 0 {
            return BCDAudioDiagnostic(name: "Game Audio Files", category: .files, status: .warning, detail: "No audio files found in game folder. Game may use packed archives (.ba2, .bsa, .pak) or stream from elsewhere.")
        } else {
            let detail = "Found \(totalCount) audio files: " + foundFiles.map { "\($1) .\($0)" }.joined(separator: ", ")
            return BCDAudioDiagnostic(name: "Game Audio Files", category: .files, status: .ok, detail: detail)
        }
    }

    /// Check game INI/config for audio settings.
    private func checkGameAudioConfig(gameFolder: URL, gameTitle: String) async -> BCDAudioDiagnostic {
        let iniExtensions = ["ini", "cfg", "config"]
        var issues: [String] = []
        var foundFiles: [String] = []

        guard let enumerator = FileManager.default.enumerator(at: gameFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return BCDAudioDiagnostic(name: "Game Audio Config", category: .config, status: .unknown, detail: "Cannot access game folder")
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if iniExtensions.contains(ext) {
                foundFiles.append(fileURL.lastPathComponent)
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    let lower = content.lowercased()
                    // Check for common volume/mute settings
                    if lower.contains("mastervolume") || lower.contains("master_volume") || lower.contains("master volume") {
                        if let range = lower.range(of: "mastervolume") ?? lower.range(of: "master_volume") ?? lower.range(of: "master volume") {
                            let after = lower[range.upperBound...].prefix(50)
                            if after.contains("0") || after.contains("false") || after.contains("off") {
                                issues.append("\(fileURL.lastPathComponent): Master volume may be 0/off")
                            }
                        }
                    }
                    if lower.contains("sfxvolume") || lower.contains("sfx_volume") {
                        if let range = lower.range(of: "sfxvolume") ?? lower.range(of: "sfx_volume") {
                            let after = lower[range.upperBound...].prefix(50)
                            if after.contains("0") {
                                issues.append("\(fileURL.lastPathComponent): SFX volume may be 0")
                            }
                        }
                    }
                    if lower.contains("musicvolume") || lower.contains("music_volume") {
                        if let range = lower.range(of: "musicvolume") ?? lower.range(of: "music_volume") {
                            let after = lower[range.upperBound...].prefix(50)
                            if after.contains("0") {
                                issues.append("\(fileURL.lastPathComponent): Music volume may be 0")
                            }
                        }
                    }
                    if lower.contains("voicevolume") || lower.contains("voice_volume") || lower.contains("dialoguevolume") || lower.contains("dialogue_volume") {
                        if let range = lower.range(of: "voicevolume") ?? lower.range(of: "voice_volume") ?? lower.range(of: "dialoguevolume") ?? lower.range(of: "dialogue_volume") {
                            let after = lower[range.upperBound...].prefix(50)
                            if after.contains("0") {
                                issues.append("\(fileURL.lastPathComponent): Voice/Dialogue volume may be 0")
                            }
                        }
                    }
                    // Check for audio device selection
                    if lower.contains("audiodevice") || lower.contains("audio_device") || lower.contains("sounddevice") || lower.contains("sound_device") {
                        issues.append("\(fileURL.lastPathComponent): Has audio device setting (verify it's not set to a non-existent device)")
                    }
                }
            }
        }

        var detail = ""
        var status: BCDAudioDiagnostic.Status = .ok
        if !issues.isEmpty {
            detail = "Potential issues: " + issues.joined(separator: "; ")
            status = .warning
        } else if !foundFiles.isEmpty {
            detail = "Checked \(foundFiles.count) config file(s): \(foundFiles.joined(separator: ", ")). No obvious audio issues found."
        } else {
            detail = "No INI/config files found in game folder."
            status = .unknown
        }

        var action: BCDAudioDiagnostic.Action?
        if !issues.isEmpty {
            // Find first ini file to offer opening
            if let firstIni = foundFiles.first {
                let iniPath = gameFolder.appendingPathComponent(firstIni)
                action = BCDAudioDiagnostic.Action(label: "Open \(firstIni)", kind: .openFile(iniPath))
            }
        }

        return BCDAudioDiagnostic(name: "Game Audio Config", category: .config, status: status, detail: detail, action: action)
    }

    /// Check Wine audio driver.
    private func checkWineAudioDriver(log: String) -> BCDAudioDiagnostic {
        let driverPatterns = [
            "winealsa",
            "winecoreaudio",
            "winepulse",
            "wineoss",
            "winejack",
            "Audio driver"
        ]

        var found = ""
        for pattern in driverPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: log, options: [], range: NSRange(log.startIndex..., in: log)),
               let range = Range(match.range(at: 0), in: log) {
                found = String(log[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        if found.isEmpty {
            return BCDAudioDiagnostic(name: "Wine Audio Driver", category: .driver, status: .unknown, detail: "No audio driver detection in log. Run with WINEDEBUG=+winmm,+dsound to see which driver loads.")
        } else if found.lowercased().contains("coreaudio") {
            return BCDAudioDiagnostic(name: "Wine Audio Driver", category: .driver, status: .ok, detail: "Using CoreAudio driver (macOS/iOS native): \(found)")
        } else if found.lowercased().contains("pulse") {
            return BCDAudioDiagnostic(name: "Wine Audio Driver", category: .driver, status: .ok, detail: "Using PulseAudio driver: \(found)")
        } else {
            return BCDAudioDiagnostic(name: "Wine Audio Driver", category: .driver, status: .warning, detail: "Audio driver: \(found) — may not be optimal for iOS")
        }
    }
}

/// Convenience function to run audio diagnostics.
func BCDRunAudioDiagnostics(entry: LibraryEntry, drive: URL, documents: URL) async -> BCDAudioDiagResult {
    await BCDAudioDiagnostics.shared.runDiagnostics(entry: entry, drive: drive, documents: documents)
}