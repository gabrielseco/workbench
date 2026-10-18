import Foundation

/// A denied Bash command cut into the simple commands it chains, with what the shell would do beyond them.
/// Not a shell parser: it only has to be careful, so what it cannot read it reports as a feature and the
/// classifier rates it up.
struct ShellSplit: Equatable {
    struct Segment: Equatable {
        /// The text as written, trimmed.
        var raw: String
        /// Words with quotes removed; redirections are not among them.
        var words: [String]
        /// Files written by `>` or `>>`, other than `/dev/null` and descriptor copies like `2>&1`.
        var redirects: [String]
        /// The operator that ended the previous segment, nil for the first.
        var joinedBy: String?
        var hasSubstitution = false
        var hasVariable = false
        var hasHeredoc = false
    }

    var segments: [Segment]
    /// `$(…)` or a backtick outside single quotes.
    var hasSubstitution = false
    /// `$name` or `${…}` outside single quotes, such as a loop variable.
    var hasVariable = false
    var hasHeredoc = false
    /// A quote or escape that never closed.
    var isUnbalanced = false

    static func split(_ text: String) -> ShellSplit {
        var result = ShellSplit(segments: [])
        var raw = ""
        var word = ""
        var words: [String] = []
        var redirects: [String] = []
        var inWord = false
        var pendingRedirect = false
        var joiner: String?
        var local = Segment(raw: "", words: [], redirects: [], joinedBy: nil)
        var quote: Character?
        let chars = Array(text)
        var i = 0

        func endWord() {
            guard inWord else { return }
            if pendingRedirect {
                redirects.append(word)
                pendingRedirect = false
            } else {
                words.append(word)
            }
            word = ""
            inWord = false
        }
        func endSegment(next: String?) {
            endWord()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                local.raw = trimmed
                local.words = words
                local.redirects = redirects
                local.joinedBy = joiner
                result.segments.append(local)
            }
            local = Segment(raw: "", words: [], redirects: [], joinedBy: nil)
            raw = ""
            words = []
            redirects = []
            joiner = next
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if let q = quote {
                raw.append(c)
                if c == q {
                    quote = nil
                } else if q == "\"", c == "\\", let next {
                    word.append(next)
                    raw.append(next)
                    i += 1
                } else if q == "\"", c == "`" || (c == "$" && next == "(") {
                    result.hasSubstitution = true
                    local.hasSubstitution = true
                    word.append(c)
                } else if q == "\"", c == "$", let next, next.isLetter || next == "{" || next == "_" {
                    result.hasVariable = true
                    local.hasVariable = true
                    word.append(c)
                } else {
                    word.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                inWord = true
                raw.append(c)
            case "\\":
                inWord = true
                raw.append(c)
                if let next {
                    word.append(next)
                    raw.append(next)
                    i += 1
                } else {
                    result.isUnbalanced = true
                }
            case " ", "\t":
                raw.append(c)
                endWord()
            case "\n", ";":
                endSegment(next: String(c == "\n" ? ";" : c))
            case "&", "|":
                if next == c {
                    i += 1
                    endSegment(next: String([c, c]))
                } else {
                    endSegment(next: String(c))
                }
            case ">":
                // `2>&1` and `>/dev/null` write nothing; `> f` and `>> f` write f.
                endWordKeepingDescriptor(&word, &inWord, &words)
                let scan = Self.scanRedirect(chars, at: i)
                raw += scan.text
                pendingRedirect = scan.writesFile
                i = scan.end - 1
            case "<":
                if next == "<" {
                    result.hasHeredoc = true
                    local.hasHeredoc = true
                    // The body is not a command; stop reading here.
                    endSegment(next: nil)
                    return finish(result, raw: text, quote: quote)
                }
                raw.append(c)
                endWord()
            case "`":
                result.hasSubstitution = true
                local.hasSubstitution = true
                inWord = true
                raw.append(c)
                word.append(c)
            case "$":
                inWord = true
                raw.append(c)
                word.append(c)
                if next == "(" {
                    result.hasSubstitution = true
                    local.hasSubstitution = true
                } else if let next, next.isLetter || next == "{" || next == "_" {
                    result.hasVariable = true
                    local.hasVariable = true
                }
            default:
                inWord = true
                raw.append(c)
                word.append(c)
            }
            i += 1
        }
        endSegment(next: nil)
        return finish(result, raw: text, quote: quote)
    }

    /// The operator at `index` (`>`, `>>`, `>&2`): its text, whether a file name follows, and where it ends.
    private struct Redirect {
        var text: String
        var writesFile: Bool
        var end: Int
    }

    private static func scanRedirect(_ chars: [Character], at index: Int) -> Redirect {
        var text = ">"
        var j = index + 1
        if j < chars.count, chars[j] == ">" {
            text.append(">")
            j += 1
        }
        guard j < chars.count, chars[j] == "&" else { return Redirect(text: text, writesFile: true, end: j) }
        text.append("&")
        j += 1
        while j < chars.count, chars[j].isNumber || chars[j] == "-" {
            text.append(chars[j])
            j += 1
        }
        return Redirect(text: text, writesFile: false, end: j)
    }

    private static func finish(_ split: ShellSplit, raw: String, quote: Character?) -> ShellSplit {
        var out = split
        if quote != nil { out.isUnbalanced = true }
        out.segments.removeAll { $0.words.isEmpty && $0.redirects.isEmpty }
        // A `/dev/null` target is not a write.
        for index in out.segments.indices {
            out.segments[index].redirects.removeAll { $0 == "/dev/null" }
        }
        return out
    }
}

/// `2>file`: the `2` is a descriptor, not an argument.
private func endWordKeepingDescriptor(
    _ word: inout String, _ inWord: inout Bool, _ words: inout [String]
) {
    if inWord, !word.isEmpty, word.allSatisfy(\.isNumber) {
        word = ""
        inWord = false
    } else if inWord {
        words.append(word)
        word = ""
        inWord = false
    }
}
