import SwiftUI
import UIKit

// MARK: - LuaEffectScriptsView
//
// Picker + community-sharing UI for Lua-scripted audio effects (see
// `LuaEffectEngine`) — the scripted counterpart to the fixed 27-effect grid
// in `EffectsView`. Mirrors `LuaThemePresetsView`'s list-of-rows + apply +
// toast pattern so this feels like the same feature family, not a bolted-on
// second system.
struct LuaEffectScriptsView: View {
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var bundled: [LuaUserScriptLibrary.ScriptRef] = LuaEffectEngine.bundledScripts()
    @State private var userScripts: [LuaUserScriptLibrary.ScriptRef] = LuaEffectEngine.userScripts()
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importName = ""

    var body: some View {
        List {
            Section {
                Text("Each effect is a Lua script that computes its own EQ curve, speed/pitch, and optional rotation/tremolo/vibrato — real math and loops, not 10 fixed numbers. Import a script someone shared with you, or write your own.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(bundled) { ref in
                    scriptRow(ref)
                }
            } header: {
                Text("Bundled Examples")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                if userScripts.isEmpty {
                    Text("No imported scripts yet.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(userScripts) { ref in
                        scriptRow(ref)
                            .swipeActions {
                                Button(role: .destructive) {
                                    LuaEffectEngine.deleteUserScript(ref)
                                    userScripts = LuaEffectEngine.userScripts()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("Imported")
            }
            .listRowBackground(AppTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle("Scripted Effects")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    importText = UIPasteboard.general.string ?? ""
                    importName = ""
                    showImportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            importSheet
        }
    }

    private func scriptRow(_ ref: LuaUserScriptLibrary.ScriptRef) -> some View {
        Button {
            do {
                let effect = try LuaEffectEngine.resolve(ref, track: player.currentSong)
                player.applyEffect(effect)
                ToastCenter.shared.show("Applied \u{201C}\(effect.name)\u{201D}", category: .success, icon: effect.icon)
            } catch {
                ToastCenter.shared.show(error.localizedDescription, category: .error, icon: "exclamationmark.triangle.fill")
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.displayName)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("\(ref.id).lua")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                if player.audioSettings.activeEffectID == "lua:\(ref.id)" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                Section("Script Name") {
                    TextField("e.g. my_bass_curve", text: $importName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Lua Source") {
                    TextEditor(text: $importText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                }
                Section {
                    Text("Paste a script someone shared with you — it must set a global `effect` table (see the bundled examples for the exact shape).")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .navigationTitle("Import Effect Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let name = importName.trimmingCharacters(in: .whitespaces)
                            let ref = try LuaEffectEngine.importScript(source: importText, suggestedName: name.isEmpty ? "custom_effect" : name)
                            userScripts = LuaEffectEngine.userScripts()
                            showImportSheet = false
                            ToastCenter.shared.show("Imported \u{201C}\(ref.displayName)\u{201D}", category: .success, icon: "square.and.arrow.down")
                        } catch {
                            ToastCenter.shared.show("Couldn't import script: \(error.localizedDescription)", category: .error, icon: "exclamationmark.triangle.fill")
                        }
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
