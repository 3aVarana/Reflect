import SwiftUI
import ReflectIntelligence

/// The Insights tab placeholder. Phase 4 replaces this with the weekly digest and trends;
/// for now it explains why insights aren't available yet (or that the journal works fully
/// without them).
struct InsightsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                String(localized: "Insights", bundle: .module),
                systemImage: "sparkles",
                description: Text(IntelligenceAvailability.current.message)
            )
            .navigationTitle(Text("Insights", bundle: .module))
        }
    }
}

#Preview {
    InsightsPlaceholderView()
}
