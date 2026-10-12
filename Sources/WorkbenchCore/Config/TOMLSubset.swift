import Foundation

/// The values `config.toml` may contain.
enum TOMLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case number(Decimal)
    case bool(Bool)
    case array([TOMLValue])

    var typeName: String {
        switch self {
        case .string: "string"
        case .int: "integer"
        case .number: "number"
        case .bool: "boolean"
        case .array: "array"
        }
    }
}

struct TOMLEntry: Equatable, Sendable {
    var value: TOMLValue
    var line: Int
}

struct TOMLTable: Equatable, Sendable {
    var line: Int
    var entries: [String: TOMLEntry] = [:]
}

struct TOMLDocument: Equatable, Sendable {
    /// Keys before any `[table]` header live in the table named "".
    var tables: [String: TOMLTable] = ["": TOMLTable(line: 0)]
}

/// A deliberately small TOML reader: `[table]` headers, `key = value`, strings (basic and literal), integers,
/// decimals, booleans, and arrays of those, possibly spread over several lines. Anything else (dotted keys,
/// inline tables, dates, multi-line strings, nested tables) is rejected with a clear message rather than
/// misread. The config is tiny and ours; a dependency would be the larger risk.
enum TOMLSubset {
    static func parse(_ text: String) -> (document: TOMLDocument, problems: [ConfigProblem]) {
        var document = TOMLDocument()
        var problems: [ConfigProblem] = []
        var currentTable = ""

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func fail(_ code: ConfigProblem.Code, _ line: Int, _ message: String) {
            problems.append(ConfigProblem(code: code, line: line, message: message))
        }

        var index = 0
        while index < lines.count {
            let number = index + 1
            if let delimiter = multilineStringDelimiter(in: lines[index]) {
                fail(.unsupportedSyntax, number, "multi-line strings are not supported")
                // Skip the string body so it does not produce a cascade of unrelated errors.
                index += 1
                let opening = lines[number - 1]
                let closedOnSameLine = opening.components(separatedBy: delimiter).count > 2
                while !closedOnSameLine, index < lines.count {
                    let closes = lines[index].contains(delimiter)
                    index += 1
                    if closes { break }
                }
                continue
            }
            let stripped: String
            do { stripped = try stripComment(lines[index]).trimmingCharacters(in: .whitespaces) } catch {
                fail(.syntax, number, "unterminated string")
                index += 1
                continue
            }
            index += 1
            if stripped.isEmpty { continue }

            if stripped.hasPrefix("[") {
                guard stripped.hasSuffix("]"), !stripped.hasPrefix("[["), stripped.count > 2 else {
                    fail(.unsupportedSyntax, number, "unsupported table header '\(stripped)'")
                    continue
                }
                let name = String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                    fail(.unsupportedSyntax, number, "table name '\(name)' must be a plain name (no dots or quotes)")
                    continue
                }
                if document.tables[name] != nil {
                    fail(.duplicateTable, number, "table [\(name)] is defined more than once")
                } else {
                    document.tables[name] = TOMLTable(line: number)
                }
                currentTable = name
                continue
            }

            guard let eq = stripped.firstIndex(of: "=") else {
                fail(.syntax, number, "expected 'key = value', found '\(stripped)'")
                continue
            }
            let key = String(stripped[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                fail(.unsupportedSyntax, number, "key '\(key)' must be a plain name (no dots or quotes)")
                continue
            }
            var valueText = String(stripped[stripped.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            // An array may continue over following lines until its brackets balance.
            var broken = false
            while depth(of: valueText) > 0 {
                guard index < lines.count else {
                    fail(.syntax, number, "array for '\(key)' is never closed")
                    broken = true
                    break
                }
                do { valueText += "\n" + (try stripComment(lines[index])) } catch {
                    fail(.syntax, index + 1, "unterminated string")
                    broken = true
                }
                index += 1
            }
            if broken { continue }

            do {
                let value = try parseValue(valueText)
                if document.tables[currentTable]!.entries[key] != nil {
                    fail(.duplicateKey, number, "key '\(key)' appears more than once")
                } else {
                    document.tables[currentTable]!.entries[key] = TOMLEntry(value: value, line: number)
                }
            } catch let error as ValueError {
                fail(error.code, number, "\(key): \(error.message)")
            } catch {
                fail(.syntax, number, "\(key): \(error)")
            }
        }
        return (document, problems)
    }

    // MARK: Scanning

    /// `"""` or `'''` as the start of a value, if the line has one.
    private static func multilineStringDelimiter(in line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"\"\"") { return "\"\"\"" }
        if value.hasPrefix("'''") { return "'''" }
        return nil
    }

    private struct ValueError: Error {
        var code: ConfigProblem.Code
        var message: String
    }

    /// Removes a trailing `# comment`, leaving `#` inside strings alone.
    private static func stripComment(_ line: String) throws -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if let q = quote {
                result.append(ch)
                if q == "\"" && escaped { escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
            } else if ch == "#" {
                return result
            } else {
                if ch == "\"" || ch == "'" { quote = ch }
                result.append(ch)
            }
        }
        if quote != nil { throw ValueError(code: .syntax, message: "unterminated string") }
        return result
    }

    /// Bracket depth of a value text, ignoring brackets inside strings.
    private static func depth(of text: String) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for ch in text {
            if let q = quote {
                if q == "\"" && escaped { escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "[" {
                depth += 1
            } else if ch == "]" {
                depth -= 1
            }
        }
        return depth
    }

    // MARK: Values

    private static func parseValue(_ text: String) throws -> TOMLValue {
        var scanner = Scanner(chars: Array(text))
        scanner.skipSpace()
        guard !scanner.atEnd else { throw ValueError(code: .syntax, message: "missing value") }
        let value = try scanner.value()
        scanner.skipSpace()
        guard scanner.atEnd else {
            throw ValueError(code: .syntax, message: "unexpected text after value: '\(String(scanner.rest))'")
        }
        return value
    }

    private struct Scanner {
        var chars: [Character]
        var pos = 0

        init(chars: [Character]) { self.chars = chars }

        var atEnd: Bool { pos >= chars.count }
        var rest: ArraySlice<Character> { chars[pos...] }

        mutating func skipSpace() {
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
        }

        mutating func value() throws -> TOMLValue {
            guard let ch = chars[safe: pos] else { throw ValueError(code: .syntax, message: "missing value") }
            switch ch {
            case "\"":
                if chars[safe: pos + 1] == "\"", chars[safe: pos + 2] == "\"" {
                    throw ValueError(code: .unsupportedSyntax, message: "multi-line strings are not supported")
                }
                return .string(try basicString())
            case "'":
                return .string(try literalString())
            case "[":
                return try array()
            case "{":
                throw ValueError(code: .unsupportedSyntax, message: "inline tables are not supported")
            default:
                return try bareValue()
            }
        }

        mutating func basicString() throws -> String {
            pos += 1  // opening quote
            var out = ""
            while pos < chars.count {
                let ch = chars[pos]
                pos += 1
                switch ch {
                case "\"":
                    return out
                case "\\":
                    guard let esc = chars[safe: pos] else { break }
                    pos += 1
                    switch esc {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    default:
                        throw ValueError(code: .unsupportedSyntax, message: "unsupported escape '\\\(esc)' in string")
                    }
                default:
                    out.append(ch)
                }
            }
            throw ValueError(code: .syntax, message: "unterminated string")
        }

        mutating func literalString() throws -> String {
            pos += 1
            var out = ""
            while pos < chars.count {
                let ch = chars[pos]
                pos += 1
                if ch == "'" { return out }
                out.append(ch)
            }
            throw ValueError(code: .syntax, message: "unterminated string")
        }

        mutating func array() throws -> TOMLValue {
            pos += 1  // [
            var items: [TOMLValue] = []
            while true {
                skipSpace()
                guard let ch = chars[safe: pos] else {
                    throw ValueError(code: .syntax, message: "array is never closed")
                }
                if ch == "]" {
                    pos += 1
                    return .array(items)
                }
                items.append(try value())
                skipSpace()
                if chars[safe: pos] == "," {
                    pos += 1
                } else if chars[safe: pos] != "]" {
                    throw ValueError(code: .syntax, message: "expected ',' or ']' in array")
                }
            }
        }

        mutating func bareValue() throws -> TOMLValue {
            var token = ""
            while pos < chars.count, !chars[pos].isWhitespace, chars[pos] != ",", chars[pos] != "]" {
                token.append(chars[pos])
                pos += 1
            }
            if token == "true" { return .bool(true) }
            if token == "false" { return .bool(false) }
            if token.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil, let n = Int(token) {
                return .int(n)
            }
            if token.range(of: #"^-?[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                let d = Decimal(string: token)
            {
                return .number(d)
            }
            throw ValueError(code: .syntax, message: "cannot read value '\(token)' (strings must be quoted)")
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
