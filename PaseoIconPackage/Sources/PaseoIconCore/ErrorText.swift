import Foundation

/// An error that carries the sentence the tray should show for it.
public protocol MessageError: Error {
    var message: String { get }
}

/// The message to show for a thrown value. Everything that reports a failure
/// to the user needs this, and a caught error is `any Error`, so each would
/// otherwise carry its own copy of the same narrowing.
public func errorText(_ error: any Error) -> String {
    if let error = error as? any MessageError { return error.message }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSURLErrorDomain {
        return nsError.localizedDescription
    }
    return String(describing: error)
}

// Every error this codebase throws through a user-facing path renders as a
// sentence. Binary and Snappy are reachable from SSTable, which calls both
// unwrapped, so a torn file surfaces through `LevelDBReadError.cause`.
extension SSTableError: MessageError {}
extension LocalStorageError: MessageError {}
extension BinaryError: MessageError {}
extension SnappyError: MessageError {}
