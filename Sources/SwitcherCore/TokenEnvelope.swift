import Foundation

/// Парные кавычки и скобки вокруг слова — оформление, а не буквы другой раскладки.
struct TokenEnvelope {
    let prefix: String
    let body: String
    let suffix: String

    init(_ token: String) {
        let pairs: [Character: Character] = ["\"": "\"", "'": "'", "«": "»", "“": "”",
                                              "„": "”", "‘": "’", "(": ")", "[": "]", "{": "}"]
        var body = token[...]
        var prefix = "", suffix = ""
        while body.count > 2, let first = body.first, let last = body.last, pairs[first] == last {
            prefix.append(first)
            suffix.insert(last, at: suffix.startIndex)
            body = body.dropFirst().dropLast()
        }
        self.prefix = prefix
        self.body = String(body)
        self.suffix = suffix
    }

    func wrap(_ text: String) -> String { prefix + text + suffix }
}
