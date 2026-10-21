import SwiftUI

/// Connect the tutor to Claude: either your own tutor server (holds the API key, e.g. on Railway)
/// or an API key stored on this iPad. Used in onboarding, the tutor panel and Settings.
struct ConnectionForm: View {
    @EnvironmentObject var settings: AppSettings
    var compact = false
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Connect with", selection: $settings.connection) {
                ForEach(TutorConnection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch settings.connection {
            case .server:
                TextField("Server URL, e.g. margin.up.railway.app", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Access token (APP_TOKEN on the server)", text: $settings.serverToken)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !compact {
                    Text("Your Claude API key stays on the server as ANTHROPIC_API_KEY. The app only stores the access token, in the Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .apiKey:
                SecureField("Anthropic API key (sk-ant-…)", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !compact {
                    Text("Stored in the Keychain and only sent to api.anthropic.com. Get a key at console.anthropic.com.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(testing ? "Checking…" : "Test connection") { test() }
                    .disabled(!settings.isTutorConfigured || testing)
                Spacer()
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(status.hasPrefix("✓") ? Color.green : Color.red)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .onChange(of: settings.connection) { _, _ in status = nil }
    }

    private func test() {
        testing = true
        status = nil
        let client = settings.makeClient()
        let model = settings.tutorModel
        let modelName = settings.modelOption.name
        Task {
            do {
                let models = try await client.listModels()
                status = models.isEmpty || models.contains(model) ? "✓ Connected" : "✓ Connected (\(modelName) isn't listed for this key)"
            } catch {
                status = (error as? AnthropicError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}
