import Foundation

/// SHA-256 (FIPS 180-4), in plain Swift, with the shape of CryptoKit's: `SHA256.hash(data:)`, or `update(data:)` and
/// `finalize()` for input that arrives in pieces. Used for fingerprints (the goal's approval hash, ids, proof files), never
/// for secrets. It is here and not a library's because it is the only hash Workbench uses and a crypto package costs
/// Linux about 35 s of every cold build (docs/plan/P18-linux.md); `SHA256Tests` holds it to the published vectors and,
/// on macOS, to CryptoKit.
public struct SHA256: Sendable {
    public typealias Digest = [UInt8]

    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    /// Input not yet hashed: always fewer than 64 bytes between calls.
    private var pending: [UInt8] = []
    private var length: UInt64 = 0
    private var schedule = [UInt32](repeating: 0, count: 64)

    public init() { pending.reserveCapacity(64) }

    public static func hash(data: Data) -> Digest {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    public mutating func update(data: Data) {
        length &+= UInt64(data.count)
        data.withUnsafeBytes { raw in
            var input = raw.bindMemory(to: UInt8.self)[...]
            if !pending.isEmpty {
                let take = min(64 - pending.count, input.count)
                pending.append(contentsOf: input.prefix(take))
                input = input.dropFirst(take)
                if pending.count == 64 {
                    pending.withUnsafeBufferPointer { compress($0) }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            while input.count >= 64 {
                compress(UnsafeBufferPointer(rebasing: input.prefix(64)))
                input = input.dropFirst(64)
            }
            if !input.isEmpty { pending.append(contentsOf: input) }
        }
    }

    /// The digest of everything fed so far. The hasher itself is left as it was, so more input may follow.
    public func finalize() -> Digest {
        var copy = self
        let bits = length &* 8
        var tail: [UInt8] = [0x80]
        let zeros = (55 &- Int(length % 64) &+ 64) % 64
        tail.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        let savedLength = copy.length
        copy.update(data: Data(tail))
        copy.length = savedLength
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in copy.state {
            for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: word >> UInt32(shift))) }
        }
        return out
    }

    // MARK: The compression function

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    /// One 64-byte block.
    private mutating func compress(_ block: UnsafeBufferPointer<UInt8>) {
        for i in 0..<16 {
            let j = i * 4
            schedule[i] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16 | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let a = schedule[i - 15], b = schedule[i - 2]
            let s0 = Self.rotr(a, 7) ^ Self.rotr(a, 18) ^ (a >> 3)
            let s1 = Self.rotr(b, 17) ^ Self.rotr(b, 19) ^ (b >> 10)
            schedule[i] = schedule[i - 16] &+ s0 &+ schedule[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
            let choose = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ choose &+ Self.k[i] &+ schedule[i]
            let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ majority
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}
