import PodLoungeCore
import SwiftUI

/// Card and workspace title. "The" is quieter and there is no space before the room name.
struct RoomTitleText: View {
    var workspace: WorkspaceID
    var size: CGFloat
    var nameWeight: Font.Weight = .semibold
    var color: Color = LoungeTheme.text

    var body: some View {
        let label = ClubPodNaming.roomLabel(for: workspace)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label.quiet)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color.opacity(0.55))
            Text(label.name)
                .font(.system(size: size, weight: nameWeight))
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.joined)
    }
}

/// Sidebar title. "The" is quieter, the same way the room names are written.
struct ValetTitleText: View {
    var size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("The")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(LoungeTheme.text.opacity(0.55))
            Text("Valet")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(LoungeTheme.text)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LoungeCopy.valet)
    }
}
