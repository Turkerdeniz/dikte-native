import Darwin
import Foundation
import OSLog

private struct ProcessResourceSnapshot {
    let userNanoseconds: UInt64
    let systemNanoseconds: UInt64
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let threadCount: Int

    static func capture() -> ProcessResourceSnapshot {
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let taskResult = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, taskSize)

        var usage = rusage_info_v4()
        let usageResult: Int32 = withUnsafeMutableBytes(of: &usage) { bytes in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            // libproc declares this parameter as `rusage_info_t *` even though it writes the
            // selected rusage structure into the pointed-to storage. Passing `&opaque` here
            // allocates only pointer-sized storage and lets the kernel overwrite the stack.
            // Rebind the actual rusage_info_v4 buffer instead, preserving its full size.
            let buffer = baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(getpid(), RUSAGE_INFO_V4, buffer)
        }

        return ProcessResourceSnapshot(
            userNanoseconds: taskResult == taskSize ? task.pti_total_user : 0,
            systemNanoseconds: taskResult == taskSize ? task.pti_total_system : 0,
            residentBytes: taskResult == taskSize ? task.pti_resident_size : 0,
            physicalFootprintBytes: usageResult == 0 ? usage.ri_phys_footprint : 0,
            diskReadBytes: usageResult == 0 ? usage.ri_diskio_bytesread : 0,
            diskWrittenBytes: usageResult == 0 ? usage.ri_diskio_byteswritten : 0,
            threadCount: taskResult == taskSize ? Int(task.pti_threadnum) : 0
        )
    }
}

@MainActor
final class PerformanceTracker {
    private static let log = OSLog(subsystem: "com.turkerdenizer.dikte.native", category: "Performance")
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private var processingStartedAt: UInt64
    private let startResources = ProcessResourceSnapshot.capture()
    private var activeStage: (name: String, startedAt: UInt64, signpostID: OSSignpostID)?
    private var stages: [StageDuration] = []

    init() {
        processingStartedAt = startedAt
    }

    func begin(_ name: String) {
        endStage()
        let signpostID = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "PipelineStage", signpostID: signpostID,
                    "%{public}s", name)
        activeStage = (name, DispatchTime.now().uptimeNanoseconds, signpostID)
    }

    func markProcessingStarted() {
        processingStartedAt = DispatchTime.now().uptimeNanoseconds
    }

    func finish() -> PerformanceDiagnostics {
        endStage()
        let endResources = ProcessResourceSnapshot.capture()
        let endedAt = DispatchTime.now().uptimeNanoseconds
        return PerformanceDiagnostics(
            stages: stages,
            totalMilliseconds: milliseconds(endedAt - processingStartedAt),
            userCPUMilliseconds: milliseconds(delta(endResources.userNanoseconds, startResources.userNanoseconds)),
            systemCPUMilliseconds: milliseconds(delta(endResources.systemNanoseconds, startResources.systemNanoseconds)),
            residentBytesStart: startResources.residentBytes,
            residentBytesEnd: endResources.residentBytes,
            physicalFootprintBytesStart: startResources.physicalFootprintBytes,
            physicalFootprintBytesEnd: endResources.physicalFootprintBytes,
            diskReadBytes: delta(endResources.diskReadBytes, startResources.diskReadBytes),
            diskWrittenBytes: delta(endResources.diskWrittenBytes, startResources.diskWrittenBytes),
            threadCountStart: startResources.threadCount,
            threadCountEnd: endResources.threadCount,
            thermalState: Self.thermalStateTitle
        )
    }

    private func endStage() {
        guard let activeStage else { return }
        let endedAt = DispatchTime.now().uptimeNanoseconds
        stages.append(StageDuration(name: activeStage.name,
                                    milliseconds: milliseconds(endedAt - activeStage.startedAt)))
        os_signpost(.end, log: Self.log, name: "PipelineStage", signpostID: activeStage.signpostID,
                    "%{public}s", activeStage.name)
        self.activeStage = nil
    }

    private func delta(_ newer: UInt64, _ older: UInt64) -> UInt64 { newer >= older ? newer - older : 0 }
    private func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

    private static var thermalStateTitle: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Yükseliyor"
        case .serious: "Yüksek"
        case .critical: "Kritik"
        @unknown default: "Bilinmiyor"
        }
    }
}
