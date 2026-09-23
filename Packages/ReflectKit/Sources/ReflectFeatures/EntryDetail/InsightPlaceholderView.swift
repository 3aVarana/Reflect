import SwiftUI
import ReflectIntelligence

/// The seam Phase 2 replaces with the real `InsightPanel`. Nothing writes mood/summary/
/// themes yet, so this only ever shows the current intelligence availability message.
struct InsightPlaceholderView: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label {
                    Text("Insights", bundle: .module)
                        .font(.headline)
                } icon: {
                    Image(systemName: "sparkles")
                }
                Text(IntelligenceAvailability.current.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    InsightPlaceholderView()
        .padding()
}
