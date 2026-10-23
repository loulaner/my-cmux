import CMUXMobileCore
import Foundation

actor LocalDirectScriptedTransport: CmxByteTransport {
    var chunks: [Data]
    var sent: [Data] = []
    var closed = false
    init(chunks: [Data]) { self.chunks = chunks }
    func connect() {}
    func receive() -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
    func send(_ data: Data) { sent.append(data) }
    func close() { closed = true }
}
