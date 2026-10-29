// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI
import Foundation

// DLL Picker view for "Add DLL Override" action.
// Scans game folder and Wine prefix for .dll files and presents them grouped by location.

struct BCDDLLPickerView: View {
    let gameFolder: URL
    let winePrefix: URL
    let existingOverrides: [BCDDLLOverride]
    let onPick: (BCDDLLOverride) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var focus: BCDFocus
    @State private var dllsBySource: [DLLSource: [DLLFile]] = [:]
    @State private var isScanning = true
    @State private var searchText = ""
    @State private var selectedSource: DLLSource? = nil

    enum DLLSource: String, CaseIterable, Identifiable {
        case gameFolder = "Game Folder"
        case system32 = "Wine prefix / system32"
        case syswow64 = "Wine prefix / syswow64"
        var id: String { rawValue }
    }

    struct DLLFile: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let source: DLLSource
        var displayName: String { name }
    }

    var filteredDLLs: [DLLSource: [DLLFile]] {
        if searchText.isEmpty {
            return dllsBySource
        }
        var result: [DLLSource: [DLLFile]] = [:]
        for (source, files) in dllsBySource {
            let filtered = files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            if !filtered.isEmpty { result[source] = filtered }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    ProgressView("Scanning for DLLs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if dllsBySource.values.flatMap(\.self).isEmpty {
                    ContentUnavailableView(
                        "No DLLs found",
                        systemImage: "shippingbox",
                        description: Text("No .dll files found in the game folder or Wine prefix.")
                    )
                } else {
                    List {
                        // Search field
                        Section {
                            TextField("Search DLLs…", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .bcdFocusable("game.dllPicker.search", cornerRadius: 10) {}
                                .id("game.dllPicker.search")
                        }

                        // Source filter
                        Section("Filter by location") {
                            Picker("Source", selection: $selectedSource) {
                                Text("All locations").tag(nil as DLLSource?)
                                ForEach(DLLSource.allCases) { source in
                                    Text(source.rawValue).tag(source as DLLSource?)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        // DLLs grouped by source
                        let sources = selectedSource != nil ? [selectedSource!] : DLLSource.allCases
                        ForEach(sources) { source in
                            if let files = filteredDLLs[source], !files.isEmpty {
                                Section(header: Text("\(source.rawValue) (\(files.count))")) {
                                    ForEach(Array(files.enumerated()), id: \.element.id) { index, dll in
                                        BCDDLLPickerRow(
                                            dll: dll,
                                            isAlreadyOverridden: existingOverrides.contains { $0.dllName.lowercased() == dll.name.lowercased() },
                                            onTap: {
                                                let override = BCDDLLOverride(
                                                    dllName: dll.name,
                                                    mode: .builtin,
                                                    note: "Added from \(dll.source.rawValue)"
                                                )
                                                onPick(override)
                                                dismiss()
                                            },
                                            focusID: "game.dllPicker.\(source.rawValue).\(index)"
                                        )
                                    }
                                }
                            }
                        }

                        if filteredDLLs.values.flatMap(\.self).isEmpty && !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                }
            }
            .navigationTitle("Add DLL Override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await scanDLLs() }
        }
    }

    private func scanDLLs() async {
        var results: [DLLSource: [DLLFile]] = [:]

        // Scan game folder (recursive, up to 3 levels deep)
        if let gameDLLs = await scanFolder(gameFolder, source: .gameFolder, maxDepth: 3) {
            results[.gameFolder] = gameDLLs
        }

        // Scan Wine prefix system32
        let system32 = winePrefix.appendingPathComponent("windows/system32", isDirectory: true)
        if let sys32DLLs = await scanFolder(system32, source: .system32, maxDepth: 1) {
            results[.system32] = sys32DLLs
        }

        // Scan Wine prefix syswow64
        let syswow64 = winePrefix.appendingPathComponent("windows/syswow64", isDirectory: true)
        if let syswowDLLs = await scanFolder(syswow64, source: .syswow64, maxDepth: 1) {
            results[.syswow64] = syswowDLLs
        }

        await MainActor.run {
            self.dllsBySource = results
            self.isScanning = false
        }
    }

    private func scanFolder(_ folder: URL, source: DLLSource, maxDepth: Int) async -> [DLLFile]? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        var files: [DLLFile] = []
        var seen = 0

        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }

        for case let fileURL as URL in enumerator {
            if seen >= 1000 { break }
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "dll" else { continue }

            // Check depth
            let relativePath = fileURL.path.replacingOccurrences(of: folder.path, with: "")
            let depth = relativePath.split(separator: "/").count
            if depth > maxDepth { continue }

            seen += 1
            let relative = relativePath.isEmpty ? fileURL.lastPathComponent : String(relativePath.dropFirst())
            files.append(DLLFile(name: fileURL.lastPathComponent, path: relative, source: source))
        }

        // Sort: known important DLLs first, then alphabetically
        let priorityDLLs = [
            "xaudio2_7.dll", "xaudio2_8.dll", "xaudio2_9.dll",
            "x3daudio1_7.dll", "xapofx1_5.dll",
            "d3d11.dll", "dxgi.dll", "d3d12.dll", "d3d9.dll", "d3d8.dll",
            "dsound.dll", "dinput.dll", "dinput8.dll",
            "xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll",
            "vcruntime140.dll", "msvcp140.dll", "concrt140.dll",
            "mfplat.dll", "mfreadwrite.dll", "mf.dll",
            "OpenAL32.dll", "vulkan-1.dll",
            "PhysX3.dll", "PhysX3Common.dll", "PhysXFoundation.dll"
        ]

        files.sort { lhs, rhs in
            let lhsPriority = priorityDLLs.firstIndex(of: lhs.name.lowercased()) ?? Int.max
            let rhsPriority = priorityDLLs.firstIndex(of: rhs.name.lowercased()) ?? Int.max
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return files
    }
}

/// Row for a single DLL in the picker.
private struct BCDDLLPickerRow: View {
    let dll: BCDDLLPickerView.DLLFile
    let isAlreadyOverridden: Bool
    let onTap: () -> Void
    let focusID: String

    @EnvironmentObject private var focus: BCDFocus

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dll.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(isAlreadyOverridden ? .secondary : .primary)
                    Text(dll.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isAlreadyOverridden {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAlreadyOverridden)
        .bcdFocusable(focusID, cornerRadius: 10, action: onTap)
        .id(focusID)
    }
}

/// Convenience function to present the DLL picker.
func BCDPresentDLLPicker(
    gameFolder: URL,
    winePrefix: URL,
    existingOverrides: [BCDDLLOverride],
    onPick: @escaping (BCDDLLOverride) -> Void
) -> some View {
    BCDDLLPickerView(
        gameFolder: gameFolder,
        winePrefix: winePrefix,
        existingOverrides: existingOverrides,
        onPick: onPick
    )
}