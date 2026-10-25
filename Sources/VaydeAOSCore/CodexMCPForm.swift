import Foundation

public struct CodexMCPField: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let required: Bool
    public let options: [String]
    let values: [String]
    let schema: CodexValue

    func value(_ answer: String?) -> CodexValue? {
        guard let answer, !answer.isEmpty else { return nil }
        switch schema["type"].text {
        case "boolean":
            return answer == "true" ? .bool(true) : answer == "false" ? .bool(false) : nil
        case "integer", "number":
            guard let number = Double(answer), number.isFinite,
                  schema["type"].text != "integer" || number.rounded() == number else { return nil }
            if case .number(let minimum) = schema["minimum"], number < minimum { return nil }
            if case .number(let maximum) = schema["maximum"], number > maximum { return nil }
            return .number(number)
        case "string":
            if !values.isEmpty && !values.contains(answer) { return nil }
            if case .number(let minimum) = schema["minLength"], Double(answer.unicodeScalars.count) < minimum { return nil }
            if case .number(let maximum) = schema["maxLength"], Double(answer.unicodeScalars.count) > maximum { return nil }
            return .string(answer)
        default: return nil
        }
    }

    public func optionValue(at index: Int) -> String { values[index] }
}

public struct CodexMCPElicitation: Equatable, Sendable {
    public let fields: [CodexMCPField]
    public let url: URL?

    init?(params: CodexValue) {
        if params["mode"].text == "url" {
            guard let value = params["url"].text, let url = URL(string: value),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  params["elicitationId"].text != nil else { return nil }
            self.url = url; fields = []; return
        }
        guard params["mode"].text == "form" else { return nil }
        let schema = params["requestedSchema"]
        guard schema["type"].text == "object", case .object(let properties) = schema["properties"],
              properties.count <= 30,
              Set(schema.fields.keys).isSubset(of: ["type", "properties", "required", "$schema", "additionalProperties"]) else { return nil }
        let required = Set(schema["required"].values.compactMap(\.text))
        guard required.isSubset(of: Set(properties.keys)) else { return nil }
        var fields: [CodexMCPField] = []
        for (id, field) in properties.sorted(by: { $0.key < $1.key }) {
            guard let type = field["type"].text,
                  ["string", "boolean", "integer", "number"].contains(type),
                  Set(field.fields.keys).isSubset(of: ["type", "title", "description", "default", "enum", "enumNames", "oneOf", "minLength", "maxLength", "minimum", "maximum", "format"]) else { return nil }
            var values: [String] = [], labels: [String] = []
            if type == "boolean" { values = ["true", "false"]; labels = ["Yes", "No"] }
            else if field["enum"] != .null {
                values = field["enum"].values.compactMap(\.text)
                guard type == "string", !values.isEmpty, values.count == field["enum"].values.count else { return nil }
                let names = field["enumNames"].values.compactMap(\.text)
                labels = names.count == values.count ? names : values
            } else if field["oneOf"] != .null {
                values = field["oneOf"].values.compactMap { $0["const"].text }
                labels = field["oneOf"].values.compactMap { $0["title"].text }
                guard type == "string", !values.isEmpty, values.count == field["oneOf"].values.count,
                      labels.count == values.count else { return nil }
            }
            var detail = [field["description"].text, field["format"].text.map { "Format: " + $0 }].compactMap { $0 }
            for (key, label) in [("minLength", "Minimum length"), ("maxLength", "Maximum length"), ("minimum", "Minimum"), ("maximum", "Maximum")] {
                if case .number(let value) = field[key] { detail.append("\(label): \(value.formatted())") }
            }
            fields.append(CodexMCPField(id: id, title: field["title"].text ?? id,
                detail: detail.joined(separator: "\n"), required: required.contains(id), options: labels, values: values, schema: field))
        }
        self.fields = fields; url = nil
    }

    func content(answers: [String: String]) -> CodexValue? {
        var content: [String: CodexValue] = [:]
        for field in fields {
            if let value = field.value(answers[field.id]) { content[field.id] = value }
            else if field.required || !(answers[field.id] ?? "").isEmpty { return nil }
        }
        return .object(content)
    }
}
