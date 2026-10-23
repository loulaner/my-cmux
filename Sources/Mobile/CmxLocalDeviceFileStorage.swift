import CmuxMobileTransport
import CryptoKit
import Darwin
import Foundation

/// Bundle-scoped private files. Directory-relative operations never follow item symlinks.
actor CmxLocalDeviceFileStorage: CmxLocalDeviceCredentialStorage {
    enum Failure: Error { case unavailable }
    private let baseURL: URL
    init(baseURL: URL) { self.baseURL = baseURL }

    func read(account: String) async throws -> Data? { try readFile(name: name(account)) }
    func write(_ data: Data, account: String) async throws { try writeFile(data, name: name(account)) }
    func readConfiguration() throws -> Data? { try readFile(name: "host-v1.json") }
    func writeConfiguration(_ data: Data) throws { try writeFile(data, name: "host-v1.json") }

    private func name(_ account: String) -> String {
        "devices-" + SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    private func directory() throws -> Int32 {
        guard baseURL.isFileURL, baseURL.path.hasPrefix("/") else { throw Failure.unavailable }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        for component in baseURL.path.split(separator: "/") {
            guard component != ".", component != ".." else { Darwin.close(fd); throw Failure.unavailable }
            let name = String(component)
            if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { Darwin.close(fd); throw Failure.unavailable }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw Failure.unavailable }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
            Darwin.close(fd); throw Failure.unavailable
        }
        return fd
    }
    private func readFile(name: String) throws -> Data? {
        let directory = try directory()
        defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= 1_048_576,
              fchmod(fd, 0o600) == 0 else { throw Failure.unavailable }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { return result }
            if count < 0, errno == EINTR { continue }
            guard count > 0, result.count + count <= 1_048_576 else { throw Failure.unavailable }
            result.append(contentsOf: bytes.prefix(count))
        }
    }
    private func writeFile(_ data: Data, name: String) throws {
        guard data.count <= 1_048_576 else { throw Failure.unavailable }
        let directory = try directory()
        defer { Darwin.close(directory) }
        var info = stat()
        let existing = fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW)
        guard (existing < 0 && errno == ENOENT) ||
                (existing == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1)
        else { throw Failure.unavailable }
        let temporary = ".pending-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0,
              fsync(directory) == 0 else { throw Failure.unavailable }
    }
}
