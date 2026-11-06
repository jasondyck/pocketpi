import PocketPiKit
import SwiftUI

/// First run: where pocketpi is served on the tailnet.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("machine.tailnet.ts.net:9457", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .accessibilityIdentifier("address")
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address `tailscale serve` gives pocketpi. This phone must be on the tailnet, and its Tailscale login allowed by POCKETPI_ALLOWED_USERS.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
                Section {
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("connect")
                }
            }
            .navigationTitle("pocketpi")
        }
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await model.connect(to: address) } catch { self.error = error.localizedDescription }
        }
    }
}
