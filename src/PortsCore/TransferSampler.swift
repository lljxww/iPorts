import Foundation

public struct ByteCounters: Sendable {
    public let read: UInt64
    public let written: UInt64
    public let time: TimeInterval

    public init(read: UInt64, written: UInt64, time: TimeInterval) {
        self.read = read
        self.written = written
        self.time = time
    }
}

public struct TransferSampler: Sendable {
    private var previous: [String: ByteCounters] = [:]

    public init() {}

    public mutating func sample(_ counters: [String: ByteCounters]) -> [String: TransferRate] {
        defer { previous = counters }
        var rates: [String: TransferRate] = [:]
        for (id, current) in counters {
            guard let old = previous[id], current.time.isFinite, old.time.isFinite,
                current.time > old.time, current.read >= old.read, current.written >= old.written
            else { continue }
            let elapsed = current.time - old.time
            rates[id] = TransferRate(
                readBytesPerSecond: Double(current.read - old.read) / elapsed,
                writeBytesPerSecond: Double(current.written - old.written) / elapsed
            )
        }
        return rates
    }

    public mutating func reset() { previous.removeAll() }
}
