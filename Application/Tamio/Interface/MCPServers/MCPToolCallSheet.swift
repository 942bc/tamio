import AppKit
import SwiftUI
import TamioDesign
import TamioModule

/// Calls one MCP tool. The arguments are a form built from the tool's
/// `inputSchema`, or the raw JSON when the schema is complex or the user
/// asks for it.
struct MCPToolCallSheet: View {
    let server: RDMCPServer
    let tool: MCPTool
    let call: (JSONValue) async throws -> MCPCallResult

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var mode: Mode = .form
    @State private var rawJSON = "{}"
    @State private var result: MCPCallResult?
    @State private var error: String?
    @State private var isCalling = false

    private enum Mode: String, CaseIterable {
        case form = "Form"
        case json = "JSON"
    }

    private struct Field: Identifiable {
        let id: String
        let type: String
        let required: Bool
        let enumValues: [String]
    }

    private var fields: [Field] {
        guard case let .object(properties)? = tool.inputSchema["properties"] else { return [] }
        let required = Set(tool.inputSchema["required"]?.strings ?? [])
        return properties.keys.sorted().compactMap { key in
            guard case let .object(schema)? = properties[key] else { return nil }
            let type = schema["type"]?.string ?? "string"
            guard ["string", "number", "integer", "boolean"].contains(type) else { return nil }
            return Field(
                id: key,
                type: type,
                required: required.contains(key),
                enumValues: schema["enum"]?.strings ?? []
            )
        }
    }

    private var propertyCount: Int {
        if case let .object(properties)? = tool.inputSchema["properties"] { return properties.count }
        return 0
    }

    private var complexSchema: Bool { fields.count != propertyCount }

    var body: some View {
        SheetScaffold(tool.title ?? tool.name, lead: tool.description.map { LocalizedStringKey($0) }) {
            VStack(alignment: .leading, spacing: RX.Space.s4) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if mode == .form, !complexSchema {
                    form
                } else {
                    TextEditor(text: $rawJSON)
                        .font(.rxCode)
                        .scrollContentBackground(.hidden)
                        .padding(RX.Space.s2)
                        .frame(minHeight: 180)
                        .background(
                            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                                .fill(Color.rxTerminalBackground)
                        )
                    if complexSchema {
                        HelpText("This tool's schema is too complex for the form; use JSON.")
                    }
                }
                if let error {
                    HelpText(error, isError: true)
                }
                if let result {
                    resultView(result)
                }
            }
        } footer: {
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button("Call", action: performCall)
                .buttonStyle(.rxPrimary)
                .disabled(isCalling)
        }
        .frame(width: 620)
        .onAppear(perform: prepare)
        .onChange(of: mode) { _, newValue in
            if newValue == .json {
                rawJSON = prettyJSON(arguments())
            } else {
                applyJSON()
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(fields) { field in
                RXField(LocalizedStringKey(field.id + (field.required ? " *" : ""))) {
                    if field.type == "boolean" {
                        Toggle("", isOn: Binding(
                            get: { bools[field.id] ?? false },
                            set: { bools[field.id] = $0 }
                        ))
                        .labelsHidden()
                    } else if !field.enumValues.isEmpty {
                        RXPicker(
                            selection: Binding(
                                get: { values[field.id] ?? field.enumValues[0] },
                                set: { values[field.id] = $0 }
                            ),
                            options: field.enumValues.map { .init($0, $0) }
                        )
                    } else {
                        TextField(field.type, text: Binding(
                            get: { values[field.id] ?? "" },
                            set: { values[field.id] = $0 }
                        ))
                        .textFieldStyle(.rx)
                    }
                }
            }
        }
    }

    private func prepare() {
        rawJSON = prettyJSON(.object([:]))
    }

    private func arguments() -> JSONValue {
        if mode == .json {
            return (try? JSONDecoder().decode(JSONValue.self, from: Data(rawJSON.utf8))) ?? .object([:])
        }
        var object: [String: JSONValue] = [:]
        for field in fields {
            switch field.type {
            case "boolean":
                if let value = bools[field.id] { object[field.id] = .bool(value) }
            case "number", "integer":
                if let text = values[field.id], !text.isEmpty, let number = Double(text) {
                    object[field.id] = .number(number)
                }
            default:
                if let text = values[field.id], !text.isEmpty {
                    object[field.id] = .string(text)
                }
            }
        }
        return .object(object)
    }

    private func applyJSON() {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(rawJSON.utf8)) else { return }
        for field in fields {
            switch field.type {
            case "boolean":
                if let value = value[field.id]?.bool { bools[field.id] = value }
            default:
                if let text = value[field.id]?.string { values[field.id] = text }
            }
        }
    }

    private func performCall() {
        if mode == .json, (try? JSONDecoder().decode(JSONValue.self, from: Data(rawJSON.utf8))) == nil {
            error = String(localized: "The arguments are not valid JSON.")
            return
        }
        let value = arguments()
        isCalling = true
        error = nil
        Task {
            do {
                result = try await call(value)
            } catch {
                self.error = error.localizedDescription
            }
            isCalling = false
        }
    }

    @ViewBuilder
    private func resultView(_ result: MCPCallResult) -> some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            Text("Result")
                .font(.rxSectionTitle)
                .foregroundStyle(.rxInk)
            ForEach(Array(result.contents.enumerated()), id: \.offset) { _, content in
                switch content {
                case let .text(text):
                    Text(text)
                        .font(.rxCode)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .image(_, data):
                    if let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                    }
                case let .other(json):
                    Text(prettyJSON(json))
                        .font(.rxCode)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(RX.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                .fill(result.isError ? Color.rxDanger.opacity(0.1) : Color.rxPill)
        )
    }

    private func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
