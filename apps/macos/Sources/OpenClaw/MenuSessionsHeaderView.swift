import SwiftUI

struct MenuSessionsHeaderView: View {
    let count: Int
    let statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if self.count == 1 { return "1 session · 24h" }
        return "\(self.count) sessions · 24h"
    }
}
