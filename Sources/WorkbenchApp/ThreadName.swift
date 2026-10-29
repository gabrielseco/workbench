import Foundation

/// A thread name made from what the person wrote, so the sheet never asks for one.
enum ThreadName {
    static let limit = 40

    /// The request's first line as lower-case words joined by '-', cut at a word; "goal" when it has no letters or digits.
    static func suggest(from request: String) -> String {
        let line = request.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }) ?? ""
        var words: [String] = []
        var word = ""
        for scalar in line.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        var name = ""
        for word in words {
            let next = name.isEmpty ? word : name + "-" + word
            if next.count > limit { break }
            name = next
        }
        if name.isEmpty, let first = words.first { name = String(first.prefix(limit)) }
        return name.isEmpty ? "goal" : name
    }
}
