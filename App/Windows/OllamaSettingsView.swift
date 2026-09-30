import MemorriCore
import SwiftUI

/// Settings → Ollama (contracts/ui-contract.md): the connection to the local model server.
struct OllamaSettingsView: View {
    let environment: AppEnvironment

    @State private var addressText = ""
    @State private var addressMessage: String?
    @State private var status: ServerStatus = .unchecked
    @State private var isChecking = false

    var body: some View {
        ScrollView {
            content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            addressText = environment.ollamaSettings.address.text
            runCheck()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            connectionSection
        }
    }

    // MARK: Connection (user story 1)

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.headline)
            HStack {
                Text("Server address")
                TextField("http://localhost:11434", text: $addressText)
                    .frame(width: 260)
                    .onSubmit { applyAddress() }
                Button("Apply") { applyAddress() }
            }
            if let addressMessage {
                Text(addressMessage).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(isChecking ? "Checking…" : status.message)
                    .foregroundStyle(status.isUsable ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check connection") { runCheck() }
                    .disabled(isChecking)
            }
        }
    }

    private func applyAddress() {
        if environment.ollamaSettings.setAddress(addressText) {
            addressMessage = nil
            addressText = environment.ollamaSettings.address.text
            runCheck()
        } else {
            addressMessage = "Memorri only talks to Ollama on this Mac. Use localhost, 127.0.0.1 or ::1."
            addressText = environment.ollamaSettings.address.text        // keep the previous value
        }
    }

    /// Never on the main actor; a second press while one runs joins it.
    private func runCheck() {
        isChecking = true
        let service = environment.ollama
        Task {
            let result = await service.check()
            status = result
            isChecking = false
        }
    }
}
