import Foundation
import OSLog

/// File System Directory Monitor (FSEvents-based)
/// Callback when changes are detected for FileTreeStateStore to trigger reload
final class DirectoryWatcher {
    private let logger = Logger.make(category: "DirectoryWatcher")
    private var source: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private let path: String
    private let queue = DispatchQueue(label: "DirectoryWatcher", qos: .utility)

    var onChange: (() -> Void)?

    init(path: String) {
        self.path = path
    }

    deinit {
        stop()
    }

    // MARK: - Start monitoring

    func start() {
        stop()
        dirFd = open(path, O_EVTONLY)
        guard dirFd >= 0 else {
            logger.warning("Cannot open directory for watching: \(self.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFd,
            eventMask: [.write, .rename, .delete, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.logger.debug("Directory changed: \(self?.path ?? "")")
            DispatchQueue.main.async { self?.onChange?() }
        }
        src.setCancelHandler { [weak self] in
            guard let fd = self?.dirFd, fd >= 0 else { return }
            close(fd)
            self?.dirFd = -1
        }
        src.resume()
        source = src
        logger.debug("Watching directory: \(self.path)")
    }

    // MARK: - Stop monitoring

    func stop() {
        source?.cancel()
        source = nil
    }
}
