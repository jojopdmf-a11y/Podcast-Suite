import PodLoungeCore
import SwiftUI

struct WorkspaceScaffoldView: View {
    @EnvironmentObject private var session: ProjectSession
    let workspace: WorkspaceID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    Button("← Lounge") { session.leaveWorkspace() }
                        .buttonStyle(LoungeButtonStyle())
                        .disabled(session.navigationLocked)
                        .accessibilityIdentifier("lounge.back")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.title)
                            .font(.system(size: 28, weight: .semibold))
                        Text("\(workspace.title) — coming next")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LoungeTheme.cyan)
                    }
                    Spacer()
                }
                Text(workspace.scaffoldMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(LoungeTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if workspace == .fixer {
                    // FUTURE Fixer integration: while a take is recording, the user
                    // stays in Fixer until Stop. Back to Lounge must not stop a take.
                    // This scaffold does not record; there is nothing to stop.
                    Text("While a take is recording, stay in Fixer until Stop. Leaving this screen does not stop a take.")
                        .font(.system(size: 13))
                        .foregroundStyle(LoungeTheme.amber)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LoungeTheme.amber.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(LoungeTheme.amber.opacity(0.55), lineWidth: 1)
                        )
                }
                Text("Project notes")
                    .font(.system(size: 13, weight: .semibold))
                TextEditor(text: noteBinding)
                    .font(.system(size: 13))
                    .foregroundStyle(LoungeTheme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LoungeTheme.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LoungeTheme.cyan.opacity(0.3), lineWidth: 1)
                    )
                    .disabled(session.package == nil)
                Text(session.package == nil
                    ? "Create or open a project to keep notes. Nothing on this screen records or processes audio."
                    : "Notes are saved with Save Project. They are project metadata, not a mix, a recording, or a processed result.")
                    .font(.system(size: 12))
                    .foregroundStyle(LoungeTheme.textDim)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { session.notes[workspace] ?? "" },
            set: { newValue in
                var copy = session.notes
                copy[workspace] = newValue
                session.notes = copy
            }
        )
    }
}
