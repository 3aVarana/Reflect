import SwiftUI
import SwiftData
import ReflectDomain
import ReflectIntelligence

/// Intelligence status, privacy explainer and delete-all. Export/JSON is Phase 6.
struct SettingsView: View {
    @Environment(\.journalStore) private var journalStore
    // Only checked for `.isEmpty` to enable/disable "Delete all entries" — fetch a single
    // row rather than every entry's full text.
    @Query(SettingsView.hasAnyEntryDescriptor) private var probeEntries: [JournalEntry]
    @State private var isShowingDeleteConfirmation = false
    @State private var deleteErrorMessage: String?

    var body: some View {
        Form {
            Section(String(localized: "Intelligence", bundle: .module)) {
                HStack(spacing: Spacing.s) {
                    Circle()
                        .fill(intelligenceStatusColor)
                        .frame(width: 8, height: 8)
                    Text(IntelligenceAvailability.current.message)
                }
            }

            Section(String(localized: "Privacy", bundle: .module)) {
                Text("Everything stays on this device. No accounts, no network, no analytics.", bundle: .module)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Text("Delete all entries", bundle: .module)
                }
                .disabled(journalStore == nil || probeEntries.isEmpty)
            }
        }
        .navigationTitle(Text("Settings", bundle: .module))
        .confirmationDialog(
            String(localized: "Delete all entries?", bundle: .module),
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete All", bundle: .module), role: .destructive) {
                deleteAll()
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text("This can't be undone.", bundle: .module)
        }
        .alert(
            String(localized: "Couldn't delete entries", bundle: .module),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { isPresented in if !isPresented { deleteErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private var intelligenceStatusColor: Color {
        IntelligenceAvailability.current == .available ? .green : .orange
    }

    private func deleteAll() {
        guard let journalStore else { return }
        Task {
            do {
                try await journalStore.deleteAll()
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
        }
    }

    private static var hasAnyEntryDescriptor: FetchDescriptor<JournalEntry> {
        var descriptor = FetchDescriptor<JournalEntry>()
        descriptor.fetchLimit = 1
        return descriptor
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(try! ReflectModelContainer.makeInMemory())
}
