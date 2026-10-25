import Foundation

@testable import WorkbenchCore

#if canImport(CryptoKit)
import CryptoKit
#endif

/// A digest computed some other way than by the code under test: CryptoKit where it exists. Elsewhere, `SHA256Tests`
/// has already held the implementation to the published vectors, so the product's own function is the reference.
func referenceSHA256(_ data: Data) -> [UInt8] {
    #if canImport(CryptoKit)
    return Array(CryptoKit.SHA256.hash(data: data))
    #else
    return WorkbenchCore.SHA256.hash(data: data)
    #endif
}
