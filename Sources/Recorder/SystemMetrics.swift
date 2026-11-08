import Foundation
import Darwin

enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical

    init(kernelLevel: Int32) {
        switch kernelLevel {
        case ..<2: self = .normal
        case 2..<4: self = .warning
        default: self = .critical
        }
    }
}

struct MetricsReading: Codable, Equatable, Sendable {
    var footprintBytes: UInt64?
    var speechServiceFootprintBytes: UInt64?
    var pressure: MemoryPressure?
    var swapUsedBytes: UInt64?
    var swapIns: UInt64?
    var swapOuts: UInt64?
}

protocol SystemMetricsSource: Sendable {
    func read(includeSpeechService: Bool) -> MetricsReading
}

struct LiveSystemMetrics: SystemMetricsSource {
    static let appleSpeechServiceName = "localspeechrecognition"

    let speechServiceName: String

    init(speechServiceName: String = LiveSystemMetrics.appleSpeechServiceName) {
        self.speechServiceName = speechServiceName
    }

    func read(includeSpeechService: Bool) -> MetricsReading {
        let swapCounts = Self.swapCounts()
        return MetricsReading(
            footprintBytes: Self.ownFootprint(),
            speechServiceFootprintBytes: includeSpeechService ? Self.footprint(ofProcessNamed: speechServiceName) : nil,
            pressure: Self.pressureLevel().map(MemoryPressure.init(kernelLevel:)),
            swapUsedBytes: Self.swapUsed(),
            swapIns: swapCounts?.ins,
            swapOuts: swapCounts?.outs
        )
    }

    private static func ownFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }

    private static func pressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }

    private static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    private static func swapCounts() -> (ins: UInt64, outs: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(stats.swapins), UInt64(stats.swapouts))
    }

    static func footprint(ofProcessNamed name: String) -> UInt64? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return nil }
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = pids.withUnsafeMutableBytes {
            Int(proc_listallpids($0.baseAddress, Int32($0.count)))
        }
        guard found > 0 else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        for pid in pids.prefix(found) where pid > 0 {
            let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            guard length > 0 else { continue }
            let processName = nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard processName == name else { continue }
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if status == 0 { return usage.ri_phys_footprint }
        }
        return nil
    }
}
