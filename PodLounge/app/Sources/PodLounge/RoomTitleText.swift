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
