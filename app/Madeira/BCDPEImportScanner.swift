// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// PE import scanner for runtime verification (BCDGameSetupPage.swift: runtimeVerifySection).
// Scans a game's executable and DLLs for import dependencies to detect required runtimes.

/// A detected runtime requirement with its status and details.
struct BCDRuntimeRequirement: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let category: Category
    let requiredFiles: [String]
    let installURL: URL?
    let licenseURL: URL?
    var status: Status = .unknown
    var installedVersion: String?
    var installPath: String?
    var detail: String = ""

    enum Category: Equatable { case vcRuntime, directX, dotNet, openAL, vulkan, physX, other }
    enum Status: Equatable { case unknown, notNeeded, missing, installed, outdated, corrupted }

    static func == (lhs: BCDRuntimeRequirement, rhs: BCDRuntimeRequirement) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.installedVersion == rhs.installedVersion && lhs.installPath == rhs.installPath
    }
}

/// Result of a PE import scan.
struct BCDPEScanResult {
    let imports: Set<String>                    // All unique DLL names imported (lowercase)
    let executableImports: [String: Set<String>] // Per-file imports (lowercase DLL names)
    let scannedFiles: [String]                   // Files that were scanned
    let errors: [String]                         // Any errors encountered
}

/// Scans PE files (EXE/DLL) for import dependencies.
actor BCDPEImportScanner {
    static let shared = BCDPEImportScanner()

    // Known runtime DLL patterns and their categories
    private static let runtimePatterns: [(pattern: String, category: BCDRuntimeRequirement.Category, name: String, requiredFiles: [String], installURL: URL?, licenseURL: URL?)] = [
        // Visual C++ 2015-2022
        ("vcruntime140", .vcRuntime, "Visual C++ 2015–2022 Runtime", ["vcruntime140.dll", "vcruntime140_1.dll"], URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe"), URL(string: "https://aka.ms/vs/17/release/license")),
        ("msvcp140", .vcRuntime, "Visual C++ 2015–2022 Runtime", ["msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll"], URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe"), URL(string: "https://aka.ms/vs/17/release/license")),
        ("concrt140", .vcRuntime, "Visual C++ 2015–2022 Runtime", ["concrt140.dll"], URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe"), URL(string: "https://aka.ms/vs/17/release/license")),
        ("mfc140", .vcRuntime, "Visual C++ 2015–2022 Runtime (MFC)", ["mfc140.dll", "mfc140u.dll", "mfcm140.dll", "mfcm140u.dll"], URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe"), URL(string: "https://aka.ms/vs/17/release/license")),
        ("vcomp140", .vcRuntime, "Visual C++ 2015–2022 Runtime (OpenMP)", ["vcomp140.dll"], URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe"), URL(string: "https://aka.ms/vs/17/release/license")),
        // Older VC++ runtimes
        ("msvcp120", .vcRuntime, "Visual C++ 2013 Runtime", ["msvcp120.dll", "msvcr120.dll"], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=40784"), nil),
        ("msvcp110", .vcRuntime, "Visual C++ 2012 Runtime", ["msvcp110.dll", "msvcr110.dll"], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=30679"), nil),
        ("msvcp100", .vcRuntime, "Visual C++ 2010 Runtime", ["msvcp100.dll", "msvcr100.dll"], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=5555"), nil),

        // DirectX June 2010 (D3DX, XAudio, XInput, X3DAudio, XAPOFX, XACT)
        ("d3dx9_", .directX, "DirectX June 2010 (D3DX9)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("d3dx10_", .directX, "DirectX June 2010 (D3DX10)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("d3dx11_", .directX, "DirectX June 2010 (D3DX11)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("d3dcompiler_", .directX, "DirectX June 2010 (D3DCompiler)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("xaudio2_", .directX, "DirectX June 2010 (XAudio2)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("x3daudio1_", .directX, "DirectX June 2010 (X3DAudio)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("xapofx1_", .directX, "DirectX June 2010 (XAPOFX)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("xactengine2_", .directX, "DirectX June 2010 (XACT Engine 2)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("xactengine3_", .directX, "DirectX June 2010 (XACT Engine 3)", [], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("xinput1_3", .directX, "DirectX June 2010 (XInput 1.3)", ["xinput1_3.dll"], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),
        ("xinput9_1_0", .directX, "DirectX June 2010 (XInput 9.1.0)", ["xinput9_1_0.dll"], URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109"), nil),

        // .NET Framework (Wine Mono)
        ("mscoree", .dotNet, ".NET Framework (Wine Mono)", ["mscoree.dll"], URL(string: "https://dl.winehq.org/wine-builds/mono/wine-mono-11.0.0-x86.msi"), URL(string: "https://www.winehq.org/")),

        // OpenAL
        ("openal32", .openAL, "OpenAL", ["OpenAL32.dll"], URL(string: "https://openal-soft.org/"), nil),

        // Vulkan
        ("vulkan-1", .vulkan, "Vulkan", ["vulkan-1.dll"], URL(string: "https://vulkan.lunarg.com/sdk/home"), nil),

        // PhysX
        ("physx", .physX, "NVIDIA PhysX", ["PhysX3.dll", "PhysX3Common.dll", "PhysX3Cooking.dll", "PhysX3Extensions.dll", "PhysX3Gpu.dll", "PhysX3Vehicle.dll", "PhysXFoundation.dll", "PhysXPvdSDK.dll"], URL(string: "https://developer.nvidia.com/physx-sdk"), nil),
        ("nx", .physX, "NVIDIA PhysX (legacy)", ["NxCharacter.dll", "NxCooking.dll", "NxExtensions.dll"], nil, nil),

        // DirectX wrappers (d3d8, d3d9, d3d10, d3d11, dxgi, ddraw)
        ("d3d8", .directX, "DirectX 8 wrapper", ["d3d8.dll"], nil, nil),
        ("d3d9", .directX, "DirectX 9 wrapper", ["d3d9.dll"], nil, nil),
        ("d3d10", .directX, "DirectX 10 wrapper", ["d3d10.dll", "d3d10_1.dll", "d3d10core.dll"], nil, nil),
        ("d3d11", .directX, "DirectX 11 wrapper", ["d3d11.dll"], nil, nil),
        ("dxgi", .directX, "DXGI wrapper", ["dxgi.dll"], nil, nil),
        ("ddraw", .directX, "DirectDraw wrapper", ["ddraw.dll"], nil, nil),

        // DirectSound / Audio
        ("dsound", .directX, "DirectSound wrapper", ["dsound.dll"], nil, nil),

        // Other common runtimes
        ("mfplat", .other, "Media Foundation Platform", ["mfplat.dll", "mfreadwrite.dll", "mf.dll"], nil, nil),
        ("mfreadwrite", .other, "Media Foundation Read/Write", ["mfreadwrite.dll"], nil, nil),
        ("wmvcore", .other, "Windows Media Video", ["wmvcore.dll"], nil, nil),
        ("wmadmod", .other, "Windows Media Audio Decoder", ["wmadmod.dll"], nil, nil),
        ("msmpeg2vdec", .other, "MPEG-2 Video Decoder", ["msmpeg2vdec.dll"], nil, nil),
        ("msmpeg2adec", .other, "MPEG-2 Audio Decoder", ["msmpeg2adec.dll"], nil, nil),
        ("quartz", .other, "DirectShow (quartz.dll)", ["quartz.dll"], nil, nil),
        ("devenum", .other, "DirectShow Device Enumerator", ["devenum.dll"], nil, nil),
    ]

    /// Scan a game folder for all PE imports (executable + DLLs up to 3 levels deep, max 3000 files).
    /// Returns a set of all unique imported DLL names (lowercase).
    func scanGameFolder(_ gameFolder: URL, drive: URL) async -> BCDPEScanResult {
        var allImports: Set<String> = []
        var executableImports: [String: Set<String>] = [:]
        var scannedFiles: [String] = []
        var errors: [String] = []
        var seen = 0

        guard let enumerator = FileManager.default.enumerator(at: gameFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return BCDPEScanResult(imports: [], executableImports: [:], scannedFiles: [], errors: ["Cannot enumerate game folder"])
        }

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            if seen >= 3000 { break }

            // Only scan .exe and .dll files
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "exe" || ext == "dll" else { continue }

            // Limit depth to 3 folders deep from game folder
            let relativePath = fileURL.path.replacingOccurrences(of: gameFolder.path, with: "")
            let depth = relativePath.split(separator: "/").count
            if depth > 4 { continue }

            seen += 1
            scannedFiles.append(relativePath)

            let imports = importNames(fileURL)
            if !imports.isEmpty {
                let lowerImports = imports.map { $0.lowercased() }
                allImports.formUnion(lowerImports)
                executableImports[fileURL.lastPathComponent] = Set(lowerImports)
            }
        }

        return BCDPEScanResult(imports: allImports, executableImports: executableImports, scannedFiles: scannedFiles, errors: errors)
    }

    /// Analyze imports and produce runtime requirements with status.
    func analyzeRuntimeRequirements(imports: Set<String>, drive: URL, gameFolder: URL) async -> [BCDRuntimeRequirement] {
        var requirements: [String: BCDRuntimeRequirement] = [:]

        // Match imports against known patterns
        for importName in imports {
            for (pattern, category, name, requiredFiles, installURL, licenseURL) in Self.runtimePatterns {
                if importName.hasPrefix(pattern) || importName == pattern {
                    let key = name
                    if requirements[key] == nil {
                        requirements[key] = BCDRuntimeRequirement(
                            name: name,
                            category: category,
                            requiredFiles: requiredFiles,
                            installURL: installURL,
                            licenseURL: licenseURL,
                            status: .unknown,
                            detail: "Imported by game: \(importName)"
                        )
                    } else {
                        var req = requirements[key]!
                        req.detail += "; \(importName)"
                        requirements[key] = req
                    }
                }
            }
        }

        // Check what's actually installed in the Wine prefix and game folder
        for (key, var req) in requirements {
            req.status = await checkRuntimeStatus(req, drive: drive, gameFolder: gameFolder)
            requirements[key] = req
        }

        // Also check for VC++ runtime via registry in Wine prefix
        let vcRuntimes = await checkVCRuntimeRegistry(drive: drive)
        for (name, version) in vcRuntimes {
            if var req = requirements["Visual C++ 2015–2022 Runtime"] ?? requirements["Visual C++ 2013 Runtime"] ?? requirements["Visual C++ 2012 Runtime"] ?? requirements["Visual C++ 2010 Runtime"] {
                if req.status == .missing || req.status == .unknown {
                    req.status = .installed
                    req.installedVersion = version
                    req.installPath = "Wine prefix registry"
                    req.detail = "Found in Wine registry: \(name) \(version)"
                    requirements[req.name] = req
                }
            }
        }

        // Add "Not needed" entries for common runtimes that weren't imported but user might expect
        // DirectX June 2010 - note that Wine + DXMT handles this
        if !requirements.keys.contains(where: { $0.contains("DirectX June 2010") }) {
            // Check if any DirectX-related imports were found
            let hasDirectXImports = imports.contains { imp in
                imp.hasPrefix("d3dx9_") || imp.hasPrefix("d3dx10_") || imp.hasPrefix("d3dx11_") ||
                imp.hasPrefix("d3dcompiler_") || imp.hasPrefix("xaudio2_") || imp.hasPrefix("x3daudio1_") ||
                imp.hasPrefix("xapofx1_") || imp.hasPrefix("xactengine") || imp.hasPrefix("xinput")
            }
            if hasDirectXImports {
                requirements["DirectX June 2010 (Wine builtin + DXMT)"] = BCDRuntimeRequirement(
                    name: "DirectX June 2010 (Wine builtin + DXMT)",
                    category: .directX,
                    requiredFiles: [],
                    installURL: nil,
                    licenseURL: nil,
                    status: .notNeeded,
                    detail: "BCD uses Wine's builtin DirectX + DXMT; native DirectX June 2010 not needed"
                )
            }
        }

        return requirements.values.sorted { lhs, rhs in
            // Sort by category priority, then by status (issues first), then by name
            let catOrder: [BCDRuntimeRequirement.Category] = [.vcRuntime, .directX, .dotNet, .openAL, .vulkan, .physX, .other]
            let lhsCat = catOrder.firstIndex(of: lhs.category) ?? 99
            let rhsCat = catOrder.firstIndex(of: rhs.category) ?? 99
            if lhsCat != rhsCat { return lhsCat < rhsCat }

            let statusOrder: [BCDRuntimeRequirement.Status] = [.missing, .corrupted, .outdated, .unknown, .installed, .notNeeded]
            let lhsStatus = statusOrder.firstIndex(of: lhs.status) ?? 99
            let rhsStatus = statusOrder.firstIndex(of: rhs.status) ?? 99
            if lhsStatus != rhsStatus { return lhsStatus < rhsStatus }

            return lhs.name < rhs.name
        }
    }

    /// Check if a runtime is installed in the Wine prefix or game folder.
    private func checkRuntimeStatus(_ req: BCDRuntimeRequirement, drive: URL, gameFolder: URL) async -> BCDRuntimeRequirement.Status {
        // Check Wine prefix system32/syswow64
        let system32 = drive.appendingPathComponent("windows/system32", isDirectory: true)
        let syswow64 = drive.appendingPathComponent("windows/syswow64", isDirectory: true)

        for file in req.requiredFiles {
            // Check game folder (recursive, up to 3 deep)
            if await fileExistsInGameFolder(file, gameFolder: gameFolder) {
                return .installed
            }
            // Check Wine prefix
            if FileManager.default.fileExists(atPath: system32.appendingPathComponent(file).path) ||
               FileManager.default.fileExists(atPath: syswow64.appendingPathComponent(file).path) {
                return .installed
            }
        }

        // For VC++ runtime, check registry
        if req.category == .vcRuntime {
            let vcRuntimes = await checkVCRuntimeRegistry(drive: drive)
            if !vcRuntimes.isEmpty {
                return .installed
            }
        }

        // For .NET, check if Wine Mono is installed
        if req.category == .dotNet {
            let monoPath = drive.appendingPathComponent("Program Files/Mono", isDirectory: true)
            if FileManager.default.fileExists(atPath: monoPath.path) {
                return .installed
            }
        }

        // For DirectX June 2010 - Wine builtin handles it
        if req.category == .directX && req.name.contains("DirectX June 2010") {
            return .notNeeded
        }

        return req.requiredFiles.isEmpty ? .notNeeded : .missing
    }

    private func fileExistsInGameFolder(_ fileName: String, gameFolder: URL) async -> Bool {
        let lowerName = fileName.lowercased()
        guard let enumerator = FileManager.default.enumerator(at: gameFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased() == lowerName { return true }
        }
        return false
    }

    /// Check Wine registry for installed VC++ runtimes.
    private func checkVCRuntimeRegistry(drive: URL) async -> [(String, String)] {
        var results: [(String, String)] = []
        let regPath = drive.appendingPathComponent("ProgramData/BCD/Runtimes/status.txt", isDirectory: false)
        guard let text = try? String(contentsOf: regPath, encoding: .utf8) else { return results }

        let names = ["xna": "XNA Framework 4.0", "physx": "PhysX (legacy)", "openal": "OpenAL", "dx2010": "DirectX June 2010"]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, (parts[1] == "installed" || parts[1] == "partly"), let name = names[parts[0]] {
                results.append((name, parts[1] == "partly" ? "partly" : "installed"))
            }
        }
        return results
    }

    /// Read PE import directory from a file (reused from LibraryModel).
    nonisolated func importNames(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count) ?? Data() } catch { return Data() }
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        let dos = read(0, 64); guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return [] }
        let base = UInt64(u32(dos, 60)); guard base < 16 * 1024 * 1024 else { return [] }
        let header = read(base, 264); guard header.count == 264, u32(header, 0) == 0x4550 else { return [] }
        let sections = Int(header[6]) | Int(header[7]) << 8
        let optSize = Int(header[20]) | Int(header[21]) << 8
        guard sections <= 96, optSize >= 120 else { return [] }
        let pe64 = header[24] == 0x0b && header[25] == 2
        guard header[24] == 0x0b, header[25] == 1 || pe64 else { return [] }
        let imports = u32(header, pe64 ? 144 : 128)
        let delayed = optSize >= (pe64 ? 224 : 208) ? u32(header, pe64 ? 240 : 224) : 0
        let table = read(base + 24 + UInt64(optSize), sections * 40)
        func fileOffset(_ rva: UInt32) -> UInt64? {
            guard table.count == sections * 40 else { return nil }
            for index in 0..<sections {
                let i = index * 40, va = u32(table, index * 40 + 12), size = u32(table, index * 40 + 16)
                if rva >= va, rva - va < size { return UInt64(u32(table, i + 20)) + UInt64(rva - va) }
            }
            return nil
        }
        var names: [String] = []
        for (rva, stride, nameField) in [(imports, 20, 12), (delayed, 32, 4)] {
            guard rva != 0, let start = fileOffset(rva) else { continue }
            for i in 0..<256 {
                let descriptor = read(start + UInt64(i * stride), stride)
                guard descriptor.count == stride else { break }
                var nameRVA = u32(descriptor, nameField); if nameRVA == 0 { break }
                if stride == 32 && u32(descriptor, 0) & 1 == 0 {
                    let imageBase = u32(header, 52)
                    guard !pe64, nameRVA >= imageBase else { continue }
                    nameRVA -= imageBase
                }
                guard let offset = fileOffset(nameRVA) else { continue }
                let data = read(offset, 128)
                let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
                names.append(name)
            }
        }
        return names
    }
}

/// Convenience function to run a full runtime scan for a game.
func BCDScanGameRuntimes(gameFolder: URL, drive: URL) async -> [BCDRuntimeRequirement] {
    let scanner = BCDPEImportScanner.shared
    let scanResult = await scanner.scanGameFolder(gameFolder, drive: drive)
    return await scanner.analyzeRuntimeRequirements(imports: scanResult.imports, drive: drive, gameFolder: gameFolder)
}