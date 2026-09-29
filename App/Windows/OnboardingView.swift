import MemorriCore
import SwiftUI

/// Explains the Screen Recording permission and shows its live status (contracts/ui-contract.md).
struct OnboardingView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Memorri needs Screen Recording access")
                .font(.title3.bold())
            Text("It is used to see the screens you choose to capture. Nothing leaves this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            PermissionControls(environment: environment)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Status badge and the buttons to fix it. Used by the onboarding window and by Settings.
struct PermissionControls: View {
    let environment: AppEnvironment

    var body: some View {
        let status = environment.state.permissionStatus

        VStack(alignment: .leading, spacing: 16) {
            StatusBadge(status: status)

            if status == .restartRequired {
                Text("macOS applies the permission after a restart. Relaunch Memorri to finish setup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open System Settings") { environment.openScreenRecordingSettings() }
                Button("Check again") { environment.checkPermission() }
                if status == .restartRequired {
                    Button("Relaunch Memorri") { environment.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct StatusBadge: View {
    let status: ScreenRecordingStatus

    var body: some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(color)
            .font(.headline)
    }

    private var text: String {
        switch status {
        case .granted: "Granted"
        case .notGranted: "Not granted"
        case .restartRequired: "Restart required"
        }
    }

    private var symbol: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .notGranted: "xmark.circle.fill"
        case .restartRequired: "arrow.clockwise.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .granted: .green
        case .notGranted: .red
        case .restartRequired: .orange
        }
    }
}
