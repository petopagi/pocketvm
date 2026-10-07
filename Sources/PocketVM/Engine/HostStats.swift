import Darwin
import Foundation

/// Live resource use of one machine, measured on its Virtualization XPC process.
struct MachineStats: Equatable {
    /// 100 = one full host core.
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var diskReadBytes: UInt64 = 0
    var diskWrittenBytes: UInt64 = 0
    var diskReadPerSecond: Double = 0
    var diskWritePerSecond: Double = 0
}

enum HostProcesses {
    /// Every running VM process (one per started `VZVirtualMachine`).
    static func virtualMachinePIDs() -> Set<pid_t> {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var result = Set<pid_t>()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(cString: path).hasSuffix("/com.apple.Virtualization.VirtualMachine") { result.insert(pid) }
        }
        return result
    }

    struct Sample {
        let time: TimeInterval
        let cpuNanoseconds: UInt64
        let memory: UInt64
        let read: UInt64
        let written: UInt64
    }

    static func sample(_ pid: pid_t) -> Sample? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { return nil }
        let cpuTicks = info.ri_user_time + info.ri_system_time
        return Sample(
            time: ProcessInfo.processInfo.systemUptime,
            cpuNanoseconds: cpuTicks * UInt64(timebase.numer) / UInt64(timebase.denom),
            memory: info.ri_phys_footprint,
            read: info.ri_diskio_bytesread,
            written: info.ri_diskio_byteswritten)
    }

    static func stats(from old: Sample, to new: Sample) -> MachineStats {
        let elapsed = max(0.001, new.time - old.time)
        return MachineStats(
            cpuPercent: Double(new.cpuNanoseconds &- old.cpuNanoseconds) / (elapsed * 1e9) * 100,
            memoryBytes: new.memory,
            diskReadBytes: new.read,
            diskWrittenBytes: new.written,
            diskReadPerSecond: Double(new.read &- old.read) / elapsed,
            diskWritePerSecond: Double(new.written &- old.written) / elapsed)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}

/// Samples every running machine every two seconds.
@MainActor
final class StatsSampler {
    static let shared = StatsSampler()
    private var timer: Timer?
    private var last: [UUID: HostProcesses.Sample] = [:]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { StatsSampler.shared.tick() }
        }
    }

    private func tick() {
        for machine in Library.shared.machines {
            guard machine.isActive, let pid = machine.hostPID, let now = HostProcesses.sample(pid) else {
                last[machine.id] = nil
                if machine.stats != nil && !machine.isActive { machine.stats = nil }
                continue
            }
            if let previous = last[machine.id] {
                machine.stats = HostProcesses.stats(from: previous, to: now)
            }
            machine.refreshDiskUsage()
            last[machine.id] = now
        }
    }
}

/// Byte counters of the host side of the NAT network.
enum NATInterface {
    struct Counters {
        let name: String
        let received: UInt64
        let sent: UInt64
    }

    /// The host interface that owns the guest's /24 (normally bridge100 at 192.168.64.1).
    static func counters(forGuest ip: String) -> Counters? {
        let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".") + "."
        guard let name = interfaceName(withAddressPrefix: prefix) else { return nil }
        return linkCounters()[name].map { Counters(name: name, received: $0.0, sent: $0.1) }
    }

    static func hostAddress(forGuest ip: String) -> String? {
        let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".") + "."
        var result: String?
        forEachIPv4 { name, address in if address.hasPrefix(prefix) { result = address } }
        return result
    }

    private static func interfaceName(withAddressPrefix prefix: String) -> String? {
        var result: String?
        forEachIPv4 { name, address in if address.hasPrefix(prefix) { result = name } }
        return result
    }

    private static func forEachIPv4(_ body: (String, String) -> Void) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            body(String(cString: entry.pointee.ifa_name), String(cString: host))
        }
    }

    /// 64-bit counters per interface, from the routing sysctl.
    private static func linkCounters() -> [String: (UInt64, UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }
        var result: [String: (UInt64, UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        result[String(cString: name)] = (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes)
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }
}
