import SwiftUI

struct AddMusicView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryManager

    @State private var showFilePicker = false
    @State private var importSuccess: String? = nil

    var body: some View {
        NavigationStack {
            List {

                // ─────────────────────────────────────────────────────────────
                // MARK: Scan app storage (files transferred via Mac/Finder)
                // Hidden from release builds — most users never transfer files
                // this way (the "Import Audio Files" picker below covers the
                // same files plus anywhere else in Files app), and this
                // duplicate entry point was confusing. Left in for DEBUG since
                // it's still useful for testing scanSpecificDirectory().
                // ─────────────────────────────────────────────────────────────
                #if DEBUG
                Section {
                    Button {
                        if let docs = FileManager.default
                            .urls(for: .documentDirectory, in: .userDomainMask).first {
                            library.scanSpecificDirectory(docs)
                            importSuccess = "Scanning app storage…"
                        }
                    } label: {
                        importRow(
                            icon: "folder.fill", color: AppTheme.dynamicAccent.opacity(0.85),
                            title: "Scan App Storage",
                            subtitle: "Scans files you've transferred to this app"
                        )
                    }
                    .buttonStyle(.plain)
                } header: {
                    sectionLabel("App Storage")
                } footer: {
                    Text("Files dragged into this app via Finder/Files app (Mac USB or Files → On My iPhone → Lumisound) are stored here. Subfolders are included.")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(AppTheme.surface)
                #endif

                // ─────────────────────────────────────────────────────────────
                // MARK: Import individual files from anywhere
                // ─────────────────────────────────────────────────────────────
                Section {
                    Button {
                        showFilePicker = true
                    } label: {
                        importRow(
                            icon: "doc.badge.plus", color: AppTheme.dynamicAccent,
                            title: "Import Audio Files",
                            subtitle: "Browse Files app — select any MP3, M4A, FLAC, WAV…"
                        )
                    }
                    .buttonStyle(.plain)
                } header: {
                    sectionLabel("Individual Files")
                } footer: {
                    Text("Navigate to any folder in the Files app (Downloads, iCloud Drive, etc.) and select multiple songs to import.")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(AppTheme.surface)

                // ─────────────────────────────────────────────────────────────
                // ─────────────────────────────────────────────────────────────
                // MARK: Cloud Backup
                // ─────────────────────────────────────────────────────────────
                Section {
                    NavigationLink {
                        UploadMusicView()
                    } label: {
                        importRow(
                            icon: "icloud.and.arrow.up",
                            color: AppTheme.dynamicAccent,
                            title: "Cloud Backup & Upload",
                            subtitle: "Upload tracks to your account — restore them anytime"
                        )
                    }
                } header: {
                    sectionLabel("Cloud Storage")
                } footer: {
                    Text("Requires a Lumisound account. Uploaded tracks can be redownloaded to any device after reinstalling.")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(AppTheme.surface)

                // ─────────────────────────────────────────────────────────────
                // MARK: Mac / USB transfer instructions
                // ─────────────────────────────────────────────────────────────
                Section {
                    HStack(spacing: 14) {
                        iconBadge("laptopcomputer", color: Color(white: 0.42))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transfer via Mac (USB or WiFi)")
                                .fontWeight(.medium).foregroundStyle(AppTheme.textPrimary)
                            Text("Finder → your iPhone → Files tab → Lumisound → drag files/folders in")
                                .font(.caption).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
                .listRowBackground(AppTheme.surface)

                // MARK: Feedback banner
                if let msg = importSuccess {
                    Section {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.success)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(EditionScreenBackground())
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(AppTheme.dynamicAccent)
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker(mode: .audioFiles) { urls in
                    showFilePicker = false
                    guard !urls.isEmpty else { return }
                    library.importFiles(urls: urls)
                    // importFiles runs asynchronously (and can fail — surfaced via
                    // library.errorMessage elsewhere), so claiming "imported" here
                    // would be premature; match the in-progress phrasing used above
                    // for the other two import paths.
                    importSuccess = "Importing \(urls.count) file\(urls.count == 1 ? "" : "s")…"
                }
                .ignoresSafeArea()
            }
        }
    }

    private func importRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).foregroundStyle(AppTheme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    /// Consistent rounded-square icon badge used by every Add Music row, so the
    /// rows share one visual language instead of mixing bare glyphs and badges.
    private func iconBadge(_ systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
                .frame(width: 40, height: 40)
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
