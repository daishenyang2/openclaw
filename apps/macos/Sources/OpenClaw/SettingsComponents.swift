import SwiftUI

struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @Binding var binding: Bool

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, binding: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._binding = binding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: self.$binding) {
                Text(self.title)
                    .font(.body)
            }
            .toggleStyle(.checkbox)

            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
