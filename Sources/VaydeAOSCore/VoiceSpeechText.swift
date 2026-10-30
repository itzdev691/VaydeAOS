import Foundation

public enum VoiceSpeechText {
    public static func readable(_ markdown: String) -> String {
        let withoutCode = markdown.replacingOccurrences(of: "(?s)```.*?(?:```|$)",
            with: " Code is shown in the chat. ", options: .regularExpression)
        let plain = (try? AttributedString(markdown: withoutCode)).map { String($0.characters) } ?? withoutCode
        guard plain.count > 3_000 else { return plain }
        return String(plain.prefix(3_000)) + ". The rest of the response is in the chat."
    }
}
