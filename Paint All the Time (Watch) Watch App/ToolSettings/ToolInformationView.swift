import SwiftUI

struct ToolInformationView: View {
    let title: String
    let description: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(description)
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color.black.ignoresSafeArea())
            .containerBackground(.black, for: .navigation)
        }
    }
}
