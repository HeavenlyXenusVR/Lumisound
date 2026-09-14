import SwiftUI

// MARK: - CorruptFilesView

struct CorruptFilesView: View {

    @StateObject private var service = CorruptFileFinderService.shared
    @State private var showDeleteConfirmation = false

    // MARK: Body

    var body: some View {
        List {
            // Status section
            Section {
                // Last scan date row
                HStack {
                    Label("Last Scan", systemImage: "clock")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    if let date = service.lastScanDate {
                        Text(date, style: .relative)
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("ago")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        Text("Never")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                // Corrupt file count row
                HStack {
                    Label("Corrupt Files Found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text("\(service.corruptFiles.count)")
                        .font(AppTheme.monoFont(size: 14))
                        .foregroundStyle(
                            service.corruptFiles.isEmpty ? AppTheme.success : AppTheme.warning
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            (service.corruptFiles.isEmpty ? AppTheme.success : AppTheme.warning)
                                .opacity(0.15),
                            in: Capsule()
                        )
                }

                // Scan Now button
                Button {
                    guard let docs = FileManager.default.urls(
                        for: .documentDirectory, in: .userDomainMask
                    ).first else { return }
                    Task { await service.runScan(in: docs) }
                } label: {
                    HStack {
                        Label("Scan Now", systemImage: "arrow.clockwise")
                            .foregroundStyle(AppTheme.dynamicAccent)
                        Spacer()
                        if service.isScanning {
                            ProgressView()
                                .tint(AppTheme.dynamicAccent)
                        }
                    }
                }
                .disabled(service.isScanning)

                // Lets Aria trash whatever a scan flags automatically,
                // without waiting for a manual "Delete All" tap — on by
                // default (see `CorruptFileFinderService.autoDeleteEnabled`).
                // Trashing (not a hard delete) means turning this off just
                // stops the automation; it isn't the only safety net.
                Toggle(isOn: Binding(
                    get: { service.autoDeleteEnabled },
                    set: { service.autoDeleteEnabled = $0 }
                )) {
                    Label("Let Aria Auto-Delete", systemImage: "sparkles")
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .tint(AppTheme.dynamicAccent)

            } header: {
                sectionHeader("Status")
            } footer: {
                Text("When on, Aria automatically removes corrupt files she finds — moved to Recently Deleted, recoverable for 30 days, never a permanent delete.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .listRowBackground(tintedRowBackground(.pink))

            // Corrupt files list
            if !service.corruptFiles.isEmpty {
                Section {
                    ForEach(service.corruptFiles) { entry in
                        corruptRow(for: entry)
                    }
                } header: {
                    sectionHeader("Corrupt Files")
                }
                .listRowBackground(tintedRowBackground(.pink))

                // Delete all section
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Label(
                                "Delete All \(service.corruptFiles.count) Corrupt File\(service.corruptFiles.count == 1 ? "" : "s")",
                                systemImage: "trash"
                            )
                            .foregroundStyle(AppTheme.error)
                        }
                    }
                } header: {
                    sectionHeader("Actions")
                }
                .listRowBackground(tintedRowBackground(.pink))

            } else if !service.isScanning && service.lastScanDate != nil {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(AppTheme.success)
                        Text("No corrupt files found")
                            .font(AppTheme.headlineFont(size: 16))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("All audio files in your Documents folder passed the integrity check.")
                            .font(AppTheme.bodyFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            }
        }
        // Without an explicit style this defaults to a grouped-card look —
        // see FavoritesView's identical fix.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Corrupt File Finder")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Delete All Corrupt Files?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(service.corruptFiles.count) File\(service.corruptFiles.count == 1 ? "" : "s")", role: .destructive) {
                Task { await service.deleteCorruptFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(service.corruptFiles.count) flagged file\(service.corruptFiles.count == 1 ? "" : "s") from your device. This action cannot be undone.")
        }
    }

    // MARK: - Corrupt Row

    private func corruptRow(for entry: CorruptFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.warning)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.fileName)
                        .font(AppTheme.bodyFont(size: 14).weight(.medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text(entry.formattedSize)
                            .font(AppTheme.monoFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.elevatedSurface, in: Capsule())
                    }

                    Text(entry.reasonText)
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
