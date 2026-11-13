import SwiftUI
import TamioDesign
import TamioModule

private enum MCPAuthKind: String, CaseIterable, Identifiable {
    case none, bearer, headers, oauth
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .none: return "None"
        case .bearer: return "Bearer Token"
        case .headers: return "Custom Headers"
        case .oauth: return "OAuth"
        }
    }
}

struct MCPServerEditorSheet: View {
    let server: RDMCPServer.ID?
    let onClose: (RDMCPServer.ID?) -> Void

    @EnvironmentObject var store: TamioStore

    @State private var name = ""
    @State private var endpoint = ""
    @State private var comment = ""
    @State private var transport: MCPTransportKind = .streamableHTTP
    @State private var kind: MCPAuthKind = .none
    @State private var token = ""
    @State private var headers: [MCPHeader] = []
    @State private var oauth = MCPServerOAuth()
    @State private var oauthError: String?

    private var isNew: Bool { server == nil }

    var body: some View {
        SheetScaffold(isNew ? String(localized: "New MCP Server") : String(localized: "Edit MCP Server")) {
            VStack(alignment: .leading, spacing: 14) {
                RXField("Name") {
                    TextField("Weather", text: $name)
                        .textFieldStyle(.rx)
                }
                RXField("Endpoint", help: "The server's MCP endpoint.", error: endpointError) {
                    TextField("https://example.com/mcp", text: $endpoint)
                        .textFieldStyle(.rxMono)
                }
                RXField("Transport", help: "Most current MCP servers use Streamable HTTP; older ones use SSE.") {
                    RXPicker(selection: $transport, options: [
                        .init(.streamableHTTP, "Streamable HTTP"),
                        .init(.sse, "HTTP + SSE (legacy)"),
                    ])
                }
                RXField("Authentication") {
                    RXPicker(selection: $kind, options: MCPAuthKind.allCases.map { .init($0, $0.title) })
                }
                switch kind {
                case .none:
                    EmptyView()
                case .bearer:
                    RXField("Token") {
                        SecureField("Bearer token", text: $token)
                            .textFieldStyle(.rx)
                    }
                case .headers:
                    headersField
                case .oauth:
                    oauthFields
                }
                RXField("Comment") {
                    TextField("Optional", text: $comment)
                        .textFieldStyle(.rx)
                }
            }
        } footer: {
            if let server {
                Button("Delete…") {
                    MCPServerActions.delete(server)
                    onClose(nil)
                }
                .buttonStyle(.rx)
            }
            Spacer()
            Button("Cancel") { onClose(nil) }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create" : "Save", action: save)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
        }
        .frame(width: 560)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var headersField: some View {
        RXField("Headers") {
            VStack(alignment: .leading, spacing: RX.Space.s2) {
                ForEach(headers.indices, id: \.self) { index in
                    HStack(spacing: RX.Space.s2) {
                        TextField("X-API-Key", text: $headers[index].name)
                            .textFieldStyle(.rx)
                        SecureField("Value", text: $headers[index].value)
                            .textFieldStyle(.rx)
                        Button {
                            headers.remove(at: index)
                        } label: {
                            Image(rx: "minus.circle")
                        }
                        .buttonStyle(.rxPlain)
                        .accessibilityLabel(String(localized: "Remove Header"))
                    }
                }
                Button("Add Header") { headers.append(.init()) }
                    .buttonStyle(.rxPlain)
            }
        }
    }

    @ViewBuilder
    private var oauthFields: some View {
        RXField("OAuth") {
            VStack(alignment: .leading, spacing: RX.Space.s2) {
                if oauth.isSignedIn {
                    Text("Signed in")
                        .font(.rxHelp)
                        .foregroundStyle(.rxSuccess)
                } else {
                    Text("Not signed in")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                }
                HStack(spacing: RX.Space.s2) {
                    Button {
                        if oauth.isSignedIn {
                            oauth.accessToken = ""
                            oauth.refreshToken = ""
                            oauth.expiresAt = nil
                        } else {
                            signIn()
                        }
                    } label: {
                        Text(LocalizedStringKey(oauth.isSignedIn ? "Sign Out" : "Sign In…"))
                    }
                    .buttonStyle(.rx)
                }
                if let oauthError {
                    HelpText(oauthError, isError: true)
                }
                TextField("Client ID", text: $oauth.clientID)
                    .textFieldStyle(.rx)
                SecureField("Client Secret (if required)", text: $oauth.clientSecret)
                    .textFieldStyle(.rx)
                TextField("Scopes, separated by spaces", text: scopesText)
                    .textFieldStyle(.rx)
                TextField("Authorization endpoint (optional)", text: $oauth.authorizationEndpoint)
                    .textFieldStyle(.rx)
                TextField("Token endpoint (optional)", text: $oauth.tokenEndpoint)
                    .textFieldStyle(.rx)
                TextField("Registration endpoint (optional)", text: $oauth.registrationEndpoint)
                    .textFieldStyle(.rx)
                HelpText("Leave the endpoints empty to discover them from the server.")
            }
        }
    }

    private var scopesText: Binding<String> {
        Binding(
            get: { oauth.scopes.joined(separator: " ") },
            set: { oauth.scopes = $0.split(separator: " ").map(String.init) }
        )
    }

    private var trimmedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var endpointError: String? {
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty
        else {
            return String(localized: "Enter an http:// or https:// URL.")
        }
        guard scheme == "http" || scheme == "https" else {
            return String(localized: "Enter an http:// or https:// URL.")
        }
        return nil
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, endpointError == nil else { return false }
        switch kind {
        case .bearer:
            return !token.isEmpty
        case .headers:
            return headers.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        default:
            return true
        }
    }

    private func load() {
        guard let server else { return }
        let value = store.mcpServerGroup[server]
        name = value.name
        endpoint = value.endpoint
        comment = value.comment
        transport = value.transportKind
        switch value.auth {
        case .none:
            kind = .none
        case let .bearer(saved):
            kind = .bearer
            token = saved
        case let .headers(saved):
            kind = .headers
            headers = saved
        case let .oauth(saved):
            kind = .oauth
            oauth = saved
        }
    }

    private func signIn() {
        oauthError = nil
        Task {
            do {
                oauth = try await MCPOAuthCoordinator.signIn(endpoint: trimmedEndpoint, oauth: oauth)
            } catch {
                oauthError = error.localizedDescription
            }
        }
    }

    private func save() {
        var value = server.map { store.mcpServerGroup[$0] } ?? RDMCPServer()
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.endpoint = trimmedEndpoint
        value.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        value.transport = transport
        switch kind {
        case .none:
            value.auth = .none
        case .bearer:
            value.auth = .bearer(token: token)
        case .headers:
            value.auth = .headers(headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
        case .oauth:
            value.auth = .oauth(oauth)
        }
        store.mcpServerGroup.insert(value)
        onClose(value.id)
    }
}
