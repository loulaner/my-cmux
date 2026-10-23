import CMUXMobileCore
import Foundation

/// Strict first-frame JSON; RPC framing limits are deliberately not inherited.
struct CmxLocalDirectWire: Codable, Sendable {
    enum Failure: Error { case connectionClosed, protocolViolation }
    var version = 1
    var operation: String?
    var status: String?
    var displayName: String?
    var deviceID: String?
    var token: String?

    static func decode(_ data: Data, response: Bool) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CmxLocalDirectAdmission.Failure.denied
        }
        let keys: Set<String>
        switch (response, value.operation, value.status) {
        case (false, "pair", nil): keys = ["version", "operation", "displayName"]
        case (false, "authenticate", nil): keys = ["version", "operation", "deviceID", "token"]
        case (true, nil, "paired"): keys = ["version", "status", "deviceID", "token"]
        case (true, nil, "authenticated"): keys = ["version", "status", "deviceID"]
        case (true, nil, "denied"): keys = ["version", "status"]
        default: throw CmxLocalDirectAdmission.Failure.denied
        }
        guard Set(object.keys) == keys else { throw CmxLocalDirectAdmission.Failure.denied }
        return value
    }

    func framed() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= 4096 else { throw CmxLocalDirectAdmission.Failure.denied }
        return try MobileSyncFrameCodec.encodeFrame(bytes)
    }

    static func read(from transport: any CmxByteTransport) async throws -> (Data, Data) {
        var buffer = Data()
        while true {
            let frames: [Data]
            do {
                frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer,
                    maximumFrameByteCount: 4096, maximumDecodedFrameCount: 1)
            } catch { throw Failure.protocolViolation }
            if let frame = frames.first { return (frame, buffer) }
            let received: Data?
            do { received = try await transport.receive() }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw Failure.connectionClosed
            }
            guard let chunk = received, !chunk.isEmpty else { throw Failure.connectionClosed }
            guard chunk.count <= 65536 else { throw Failure.protocolViolation }
            buffer.append(chunk)
        }
    }

    static func validID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    static func tokenBytes(_ value: String?) throws -> Data {
        guard let value, let bytes = Data(base64Encoded: value), bytes.count == 32,
              bytes.base64EncodedString() == value else { throw CmxLocalDirectAdmission.Failure.denied }
        return bytes
    }
}
