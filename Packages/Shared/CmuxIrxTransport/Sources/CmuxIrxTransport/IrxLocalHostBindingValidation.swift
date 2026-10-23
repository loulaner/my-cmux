/// Validates the complete native bound-socket set before local admission starts.
/// This is a post-bind snapshot check, not a guarantee against transient or later binds.
struct IrxLocalHostBindingValidation {
    enum Failure: Error { case mismatch }

    func port(sockets: [String], requestedAddress: String, requestedPort: Int) throws -> Int {
        guard !sockets.isEmpty else { throw Failure.mismatch }
        var actualPort: Int?
        for socket in sockets {
            let parts = socket.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == requestedAddress,
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(parts[1]), (1...65535).contains(port), String(port) == parts[1],
                  requestedPort == port || (requestedPort == 0 && requestedAddress == "127.0.0.1"),
                  actualPort == nil || actualPort == port else { throw Failure.mismatch }
            // The requested host comes from the validated IPv4 configuration.
            actualPort = port
        }
        guard let actualPort else { throw Failure.mismatch }
        return actualPort
    }
}
