import SwiftUI
import MediaPlayer

struct AddMusicView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryManager

    /// Called right after the "iPhone Music Library" row kicks off a scan —
    /// lets the presenting screen (LibraryView) jump straight to the new
    /// Apple Music tab so the user actually sees where the import lands,
    /// instead of dismissing back to whatever tab they started from with no
    /// visible sign anything happened. `nil` for any future presentation
    /// context that doesn't have an Apple Music tab to jump to.
    var onImportAppleMusic: (() -> Void)? = nil

    @State private var showFilePicker = false
    @State private var importSuccess: String? = nil

    var body: some View {
        NavigationStack {
            List {

                // ─────────────────────────────────────────────────────────────
                // MARK: Primary — iPhone Music Library (Apple Music / iTunes)
                // This IS "the device's music library" on iOS.
                // ─────────────────────────────────────────────────────────────
                Section {
                    Button {
                        library.requestAccessAndScan()
                        importSuccess = "Scanning iPhone music library…"
                        onImportAppleMusic?()
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppTheme.dynamicAccent)
                                    .frame(width: 44, height: 44)
                                Image(systemName: "music.note.house.fill")
                                    .foregroundStyle(.white)
                                    .font(.system(size: 20))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("iPhone Music Library")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text("Your songs synced via iTunes, Finder, or Apple Music")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)

                    // Show current access status
                    let status = MPMediaLibrary.authorizationStatus()
                    if status == .denied || status == .restricted {
                        Label("Access denied — tap above to open Settings", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                    } else if status == .authorized {
                        Label("\(library.allSongs.count) songs in library", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.success)
                    }
                } header: {
                    sectionLabel("Your iPhone's Music")
                } footer: {
                    Text("On iOS, your iPhone's music library is managed by Apple Music / iTunes. Tap above to grant access and scan all songs stored on your device.")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(AppTheme.surface)

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
