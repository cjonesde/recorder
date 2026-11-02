import Darwin

enum AudioMemory {
    static func erase(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let bytes = count * MemoryLayout<Float>.stride
        _ = memset_s(samples, bytes, 0, bytes)
    }

    static func discard(_ samples: inout [Float]) {
        samples.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { erase(base, count: buffer.count) }
        }
        samples.removeAll(keepingCapacity: false)
    }
}
