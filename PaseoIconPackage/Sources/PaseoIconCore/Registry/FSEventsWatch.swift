import CoreServices
import Foundation

public enum FSEventsWatchError: MessageError {
    case couldNotStart(String)

    public var message: String {
        switch self {
        case .couldNotStart(let dir): "Could not start watching \(dir)"
        }
    }
}

/// The production watch behind `RegistryWatcher`: FSEvents on the leveldb
/// directory with per-file events, because Chromium appends to an existing
/// `.log` and a plain directory watch never sees that. A root change (the
/// directory deleted or replaced, which a reinstall does) is reported as the
/// watch dying, so the watcher re-attaches on its next read.
public enum FSEventsWatch {
    @MainActor
    public static func open(directory: String, onChange: @escaping () -> Void, onError: @escaping () -> Void) throws -> () -> Void {
        let stream = try Stream(directory: directory, onChange: onChange, onError: onError)
        return { stream.stop() }
    }

    @MainActor
    private final class Stream {
        private var ref: FSEventStreamRef?
        private let onChange: () -> Void
        private let onError: () -> Void
        private var stopped = false

        init(directory: String, onChange: @escaping () -> Void, onError: @escaping () -> Void) throws {
            self.onChange = onChange
            self.onError = onError
            var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            context.info = Unmanaged.passUnretained(self).toOpaque()
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Stream.callback,
                &context,
                [directory] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                flags
            ) else {
                throw FSEventsWatchError.couldNotStart(directory)
            }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                throw FSEventsWatchError.couldNotStart(directory)
            }
            ref = stream
        }

        func stop() {
            guard let stream = ref, !stopped else { return }
            stopped = true
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            ref = nil
        }

        private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
            guard !stopped else { return }
            var rootChanged = false
            var relevant = false
            for (path, flag) in zip(paths, flags) {
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rootChanged = true }
                if RegistryWatcher.isRegistryFileEvent(path) { relevant = true }
            }
            if rootChanged {
                stop()
                onError()
                return
            }
            if relevant { onChange() }
        }

        private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self).compactMap { $0 as? String }
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            // The stream was scheduled on the main queue, so this runs there.
            MainActor.assumeIsolated { stream.handle(paths: paths, flags: flags) }
        }
    }
}
