import SwiftUI
import SwiftData
import ReflectDomain

/// A single row in the journal list: mood glyph, text preview and a secondary line with
/// the time (and a mic icon for voice entries).
///
/// Takes the `JournalEntry` model directly (not an `EntrySnapshot`) and reads only
/// `mood`/`text`/`createdAt`/`source` inside `body`. Two things fall out of that: SwiftUI's
/// Observation tracking sees exactly the properties this row displays, so it re-renders after
/// an in-place edit; and it never faults `insight`/`themes`/`actionItems`, which
/// `EntrySnapshot.init` would touch on every row for fields this row doesn't show.
struct EntryRow: View {
    let entry: JournalEntry

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            MoodGlyph(mood: entry.mood, size: .title3)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(preview)
                    .lineLimit(2)
                HStack(spacing: Spacing.xs) {
                    Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.source == .voice {
                        Image(systemName: "mic.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Voice entry", bundle: .module))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// First ~140 characters, whitespace-collapsed. Mirrors `EntrySnapshot.preview`'s
    /// algorithm without going through `EntrySnapshot` itself (see the type doc comment).
    private var preview: String {
        let collapsed = entry.text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if collapsed.count <= 140 {
            return collapsed
        }
        return String(collapsed.prefix(140))
    }
}

#Preview {
    let container = try! ReflectModelContainer.makeInMemory()
    let context = ModelContext(container)
    let entryA = JournalEntry(text: "A short reflection on the day.")
    entryA.mood = .good
    let entryB = JournalEntry(text: "A voice entry transcribed on-device.", source: .voice)
    context.insert(entryA)
    context.insert(entryB)
    try? context.save()

    return List {
        EntryRow(entry: entryA)
        EntryRow(entry: entryB)
    }
    .modelContainer(container)
}
