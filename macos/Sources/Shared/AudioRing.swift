// A single-producer/single-consumer ring of float samples.
//
// The producer is the thread running the emulator; the consumer is an audio
// unit render block, which may not allocate, may not block and may not take a
// lock.  So: fixed storage, two monotonic counters, and acquire/release to
// publish one to the other (see CRC8650/rc8650_shim.h).

import Foundation
import CRC8650

public final class AudioRing: @unchecked Sendable {

    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<UInt64>
    private let readIndex: UnsafeMutablePointer<UInt64>

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        writeIndex = .allocate(capacity: 1)
        readIndex = .allocate(capacity: 1)
        writeIndex.initialize(to: 0)
        readIndex.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    /// Samples written but not yet read.
    public var available: Int {
        Int(rc8650_atomic_load(writeIndex) &- rc8650_atomic_load(readIndex))
    }

    public var free: Int { capacity - available }

    /// Producer side.  Writes as much as fits and returns how much that was.
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let w = rc8650_atomic_load(writeIndex)
        let r = rc8650_atomic_load(readIndex)
        let room = capacity - Int(w &- r)
        let n = min(room, samples.count)
        guard n > 0 else { return 0 }
        var offset = Int(w % UInt64(capacity))
        var written = 0
        while written < n {
            let run = min(n - written, capacity - offset)
            (storage + offset).update(from: samples.baseAddress! + written, count: run)
            written += run
            offset = (offset + run) % capacity
        }
        rc8650_atomic_store(writeIndex, w &+ UInt64(n))
        return n
    }

    /// Consumer side.  Reads as much as is there and returns how much that was.
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let w = rc8650_atomic_load(writeIndex)
        let r = rc8650_atomic_load(readIndex)
        let n = min(Int(w &- r), count)
        guard n > 0 else { return 0 }
        var offset = Int(r % UInt64(capacity))
        var got = 0
        while got < n {
            let run = min(n - got, capacity - offset)
            (destination + got).update(from: storage + offset, count: run)
            got += run
            offset = (offset + run) % capacity
        }
        rc8650_atomic_store(readIndex, r &+ UInt64(n))
        return n
    }

    /// Drop everything queued.  Only safe from the consumer side, or with the
    /// producer known to be stopped.
    public func clear() {
        rc8650_atomic_store(readIndex, rc8650_atomic_load(writeIndex))
    }
}

/// A flag one thread sets and another reads, with no ordering requirements
/// beyond eventual visibility.
public final class AtomicFlag: @unchecked Sendable {
    private let cell: UnsafeMutablePointer<UInt32>

    public init(_ value: Bool = false) {
        cell = .allocate(capacity: 1)
        cell.initialize(to: value ? 1 : 0)
    }

    deinit { cell.deallocate() }

    public var value: Bool {
        get { rc8650_atomic_load_relaxed(cell) != 0 }
        set { rc8650_atomic_store_relaxed(cell, newValue ? 1 : 0) }
    }
}
