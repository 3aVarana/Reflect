import SwiftUI
import ReflectDomain

extension EnvironmentValues {
    /// Optional because there is no sensible default without a container. Consumers
    /// `guard let` and disable the affected control when `nil` — only Settings needs it
    /// in this phase.
    @Entry public var journalStore: JournalStore?
}
