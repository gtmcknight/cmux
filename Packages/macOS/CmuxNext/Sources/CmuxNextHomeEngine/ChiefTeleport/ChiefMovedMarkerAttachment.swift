import Foundation

/// The file-system watch behind ``ChiefMovedMarkerWatcher``: one vnode source on the deepest of the
/// home's `state` folder, the home, or its parent that exists, re-armed after every event (the folder
/// it watched may be the one that appeared or went away), then a wake on the stream.
// Wraps a DispatchSourceFileSystemObject (no Foundation async equivalent; the documented carve-out).
// `source` and `cancelled` are set once in `start()` before the source resumes (no handler can run
// yet), and after that only on `queue`, where every handler runs.
nonisolated final class ChiefMovedMarkerAttachment: @unchecked Sendable { // crash-allow: `source` and `cancelled` are written once in start() before any handler runs, then only on `queue`
    private let folders: [URL]
    private let continuation: AsyncStream<Void>.Continuation
    /// Event delivery for the source (not a lock: nothing else reads this state).
    private let queue = DispatchQueue(label: "cmux.chief.movedMarker", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var cancelled = false

    init(home: URL, continuation: AsyncStream<Void>.Continuation) {
        folders = [home.appendingPathComponent("state", isDirectory: true), home, home.deletingLastPathComponent()]
        self.continuation = continuation
    }

    /// Arms the first watch on the caller's thread, so a change right after `changes()` returns is seen.
    func start() {
        arm()
    }

    /// Stops the watch (the stream ended).
    func cancel() {
        queue.async { [self] in
            cancelled = true
            source?.cancel()
            source = nil
        }
    }

    private func arm() {
        source?.cancel()
        source = nil
        guard !cancelled else { return }
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                  eventMask: [.write, .delete, .rename, .link], queue: queue)
            watch.setEventHandler { [weak self] in self?.fired() }
            watch.setCancelHandler { close(descriptor) }
            source = watch
            watch.resume()
            return
        }
    }

    private func fired() {
        arm()
        continuation.yield()
    }
}
