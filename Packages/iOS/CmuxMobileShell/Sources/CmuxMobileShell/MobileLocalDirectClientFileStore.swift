public import Foundation
import Darwin

/// Serialized private-file storage for a single local-direct capability; no Keychain or defaults.
public actor MobileLocalDirectClientFileStore: MobileLocalDirectClientStoring {
    /// Safe storage failures without file contents or paths.
    public enum Failure: Error, Sendable { case invalidRecord, unavailable }
    private let baseURL: URL
    private let filename = "client-v1.json"
    /// Creates a store without accessing disk. Supply the sandbox Application Support/local-direct directory.
    public init(baseURL: URL) { self.baseURL = baseURL }

    /// Reads one bounded, owner-only regular file and validates its entire record.
    public func load() throws -> MobileLocalDirectClientRecord? {
        guard let directory = try directory(create: false) else { return nil }
        defer { Darwin.close(directory) }
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw posixFailure("file.open") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o777 == 0o600, info.st_size <= 8192 else { throw Failure.invalidRecord }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, data.count + count <= 8192 else { throw Failure.unavailable }
            data.append(contentsOf: bytes.prefix(count))
        }
        do { return try JSONDecoder().decode(MobileLocalDirectClientRecord.self, from: data) }
        catch { throw Failure.invalidRecord }
    }

    /// Writes a protected temporary inode, then atomically replaces the saved record.
    public func save(_ record: MobileLocalDirectClientRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard let directory = try directory(create: true) else { throw Failure.unavailable }
        defer { Darwin.close(directory) }
        let temporary = ".pending-" + UUID().uuidString
        let fd = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure("file.open") }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try protect(baseURL.appendingPathComponent(temporary))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixFailure("file.write") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixFailure("file.sync") }
        guard renameat(directory, temporary, directory, filename) == 0 else { throw posixFailure("file.rename") }
        guard fsync(directory) == 0 else { throw posixFailure("directory.sync") }
    }

    /// Deletes the local file only, without contacting the Mac.
    public func forget() throws {
        guard let directory = try directory(create: false) else { return }
        defer { Darwin.close(directory) }
        guard unlinkat(directory, filename, 0) == 0 || errno == ENOENT else { throw posixFailure("file.unlink") }
        guard fsync(directory) == 0 else { throw posixFailure("directory.sync") }
    }

    /// Plans directory traversal without performing filesystem access.
    static func directoryPlan(baseURL: URL, trustedContainerRoot: URL?) throws -> (anchor: String, components: [String]) {
        guard baseURL.isFileURL, baseURL.path.hasPrefix("/") else { throw Failure.unavailable }
        let path = baseURL.path.hasPrefix("/var/") ? "/private" + baseURL.path : baseURL.path
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { throw Failure.unavailable }
        guard let root = trustedContainerRoot else { return ("/", components) }
        guard root.isFileURL, root.path.hasPrefix("/") else { throw Failure.unavailable }
        let anchor = root.path.hasPrefix("/var/") ? "/private" + root.path : root.path
        let rootComponents = anchor.split(separator: "/").map(String.init)
        guard !rootComponents.isEmpty, !rootComponents.contains(".."), !rootComponents.contains("."),
              components.count > rootComponents.count, components.starts(with: rootComponents) else {
            throw Failure.unavailable
        }
        return (anchor, Array(components.dropFirst(rootComponents.count)))
    }

    private func directory(create: Bool) throws -> Int32? {
        #if os(iOS)
        // Resolve only the system-owned sandbox anchor, never baseURL or its descendants.
        let root: URL? = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        #else
        let root: URL? = nil
        #endif
        let plan: (anchor: String, components: [String])
        do { plan = try Self.directoryPlan(baseURL: baseURL, trustedContainerRoot: root) }
        catch { diagnose("directory.plan", error: error); throw error }
        var fd = open(plan.anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure("directory.openAnchor") }
        do {
            for component in plan.components {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard create else { Darwin.close(fd); return nil }
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw posixFailure("directory.mkdirChild") }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw posixFailure("directory.openChild") }
                Darwin.close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw posixFailure("directory.stat") }
            guard info.st_uid == geteuid() else {
                diagnose("directory.owner", error: Failure.unavailable); throw Failure.unavailable
            }
            if create {
                guard fchmod(fd, 0o700) == 0 else { throw posixFailure("directory.chmod") }
                try protect(baseURL)
            } else {
                guard info.st_mode & 0o777 == 0o700 else { throw Failure.unavailable }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Only fixed call-site stages and OS error identifiers enter the local log.
    private func posixFailure(_ stage: StaticString) -> Failure {
        let code = errno
        NSLog("LocalDirectStorage stage=%@ errno=%d", String(describing: stage), code)
        return .unavailable
    }

    private func diagnose(_ stage: StaticString, error: any Error) {
        let value = error as NSError
        NSLog("LocalDirectStorage stage=%@ domain=%@ code=%ld", String(describing: stage), value.domain, value.code)
    }

    private func protect(_ url: URL) throws {
        #if os(iOS)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        } catch { diagnose("protection.file", error: error); throw Failure.unavailable }
        #endif
        var value = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        do { try value.setResourceValues(resources) }
        catch { diagnose("protection.backup", error: error); throw Failure.unavailable }
    }
}
