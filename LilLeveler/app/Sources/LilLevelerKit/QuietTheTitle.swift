import SwiftUI

/// Room wordmark with a quieter "The" and no space: TheRoof.
struct QuietTheTitle: View {
    var name: String
    var size: CGFloat
    var color: Color

    var body: some View {
        HStack(spacing: 0) {
            Text("The")
                .font(.system(size: size, weight: .medium, design: .rounded))
                .foregroundStyle(color.opacity(0.55))
            Text(name)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The" + name)
    }
}
