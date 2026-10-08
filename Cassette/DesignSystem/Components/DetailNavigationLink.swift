import SwiftUI

private struct DetailNavigationPathKey: EnvironmentKey {
    static let defaultValue: Binding<NavigationPath>? = nil
}

extension EnvironmentValues {
    var detailNavigationPath: Binding<NavigationPath>? {
        get { self[DetailNavigationPathKey.self] }
        set { self[DetailNavigationPathKey.self] = newValue }
    }
}

/// Detail pages push through the same root binding that the system writes when popping.
/// The source card can disappear from a lazy shelf without owning presentation state.
struct DetailNavigationLink<Label: View>: View {
    let destination: HomeDestination
    @ViewBuilder let label: () -> Label
    @Environment(\.detailNavigationPath) private var path

    var body: some View {
        if let path {
            Button {
                path.wrappedValue.append(destination)
            } label: {
                label()
            }
        } else {
            // Standalone previews and other hosts without a root path binding.
            NavigationLink(value: destination, label: label)
        }
    }
}
