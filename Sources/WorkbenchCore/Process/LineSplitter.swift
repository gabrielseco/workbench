import Foundation

/// Turns a stream of bytes into lines without ever holding more than `maxLineBytes` for one line.
///
/// A line longer than the limit is not buffered: its first `previewBytes` are kept, the rest is counted and
/// dropped, and one `.oversized` is emitted when the line ends. A final line with no newline is emitted by
/// `finish()`.
struct LineSplitter {
    enum Output: Equatable {
        case line(Data)
        case oversized(preview: Data, totalBytes: Int)
    }

    let maxLineBytes: Int
    let previewBytes: Int
    private var current = Data()
    private var total = 0
    private var overflowed = false

    init(maxLineBytes: Int, previewBytes: Int = 4096) {
        self.maxLineBytes = max(1, maxLineBytes)
        self.previewBytes = min(previewBytes, self.maxLineBytes)
    }

    mutating func feed(_ chunk: Data, emit: (Output) -> Void) {
        var start = chunk.startIndex
        while start < chunk.endIndex {
            if let newline = chunk[start...].firstIndex(of: 0x0A) {
                append(chunk[start..<newline])
                emitCurrent(emit)
                start = chunk.index(after: newline)
            } else {
                append(chunk[start...])
                break
            }
        }
    }

    mutating func finish(emit: (Output) -> Void) {
        if total > 0 { emitCurrent(emit) }
    }

    private mutating func append(_ part: Data) {
        total += part.count
        guard !overflowed else { return }
        if total > maxLineBytes {
            overflowed = true
            current = current.prefix(previewBytes)
            let room = max(0, previewBytes - current.count)
            current.append(part.prefix(room))
        } else {
            current.append(part)
        }
    }

    private mutating func emitCurrent(_ emit: (Output) -> Void) {
        if overflowed {
            emit(.oversized(preview: current, totalBytes: total))
        } else {
            emit(.line(current))
        }
        current = Data()
        total = 0
        overflowed = false
    }
}
