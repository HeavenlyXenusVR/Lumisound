import SwiftUI
import UniformTypeIdentifiers

// MARK: - UserMusicInfoSheet

struct UserMusicInfoSheet: View {
    let track: UserMusicTrack
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoRow(label: "Title", value: track.title)
                    infoRow(label: "Artist", value: track.artist.isEmpty ? "—" : track.artist)
                    infoRow(label: "Album", value: track.album.isEmpty ? "—" : track.album)
                    infoRow(label: "Duration", value: track.durationText)
                } header: {
                    Text("Metadata")
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    infoRow(label: "File", value: track.filename)
                    infoRow(label: "Format", value: track.ext.uppercased())
                    infoRow(label: "Server Path", value: track.serverPath)
                } header: {
                    Text("File Info")
                }
                .listRowBackground(AppTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(EditionScreenBackground())
            .navigationTitle("File Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(AppTheme.dynamicAccent)
                }
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
