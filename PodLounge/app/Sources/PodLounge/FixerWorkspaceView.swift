import PodLoungeCore
import PodProducerKit
import SwiftUI

/// The PodProducer desk, aimed at the open project's depot.
struct FixerWorkspaceView: View {
    @EnvironmentObject private var session: ProjectSession
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button("← Lounge") { session.leaveWorkspace() }
                    .buttonStyle(LoungeButtonStyle())
                    .disabled(session.navigationLocked)
                    .accessibilityIdentifier("lounge.back")
                VStack(alignment: .leading, spacing: 1) {
                    RoomTitleText(workspace: .fixer, size: 18)
                    Text("Add a depot file, mix, and record. Stay here until Stop. Back to Lounge does not stop a take.")
                        .font(.system(size: 11))
                        .foregroundStyle(LoungeTheme.textDim)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                Button("Project Notes") { showNotes = true }
                    .buttonStyle(LoungeButtonStyle())
                    .accessibilityIdentifier("fixer.notes")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ProducerDeskView(model: session.fixer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showNotes) {
            FixerNotesSheet()
        }
    }
}

private struct FixerNotesSheet: View {
    @EnvironmentObject private var session: ProjectSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project notes")
                .font(.system(size: 18, weight: .semibold))
            Text("Notes stay with this project. They are not a mix and they are not a take.")
                .font(.system(size: 12))
                .foregroundStyle(LoungeTheme.textDim)
            TextEditor(text: noteBinding)
                .font(.system(size: 13))
                .foregroundStyle(LoungeTheme.text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minWidth: 420, minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(LoungeTheme.field))
                .disabled(session.package == nil)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(LoungeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
        .preferredColorScheme(.dark)
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { session.notes[.fixer] ?? "" },
            set: { newValue in
                var copy = session.notes
                copy[.fixer] = newValue
                session.notes = copy
            }
        )
    }
}
