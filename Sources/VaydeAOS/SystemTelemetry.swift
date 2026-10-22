import Combine
import Darwin
import Foundation
import Network

/// Local, permission-free system measurements. Call start/stop with the dashboard lifecycle.
/// Throughput is measured on the primary network-path interface, not summed across VPN layers.
@MainActor
final class SystemTelemetry: ObservableObject {
    struct NetworkInterface: Identifiable {
        var id: String { name }
        let name: String
        var addresses: [String] = []
        var isUp = false
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var receiveBytesPerSecond: Double = 0
        var sendBytesPerSecond: Double = 0
    }

    @Published private(set) var interfaces: [NetworkInterface] = []
    @Published private(set) var receiveBytesPerSecond: Double = 0
    @Published private(set) var sendBytesPerSecond: Double = 0
    /// One value per observed interval, at most 60 samples; empty until two samples exist.
    @Published private(set) var receiveHistory: [Double] = []
    @Published private(set) var sendHistory: [Double] = []
    @Published private(set) var cpuHistory: [Double] = []
    /// Fraction of aggregate CPU time spent outside the idle state, from 0 to 1.
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var cpuSampleAvailable = false
    /// Active, wired, and compressed physical pages; excludes inactive/cache pages.
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    let memoryTotalBytes = ProcessInfo.processInfo.physicalMemory
    var memoryUsage: Double { Double(memoryUsedBytes) / Double(max(memoryTotalBytes, 1)) }
    @Published private(set) var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    @Published private(set) var pathStatus = "CHECKING"
    @Published private(set) var primaryInterfaceName: String?
    @Published private(set) var isNetworkAvailable = false
    @Published private(set) var lastUpdated: Date?

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "VaydeAOS.network-path")
    private var pathInterfaceName: String?
    private var previousInterfaces: [String: NetworkInterface] = [:]
    private var previousTime: TimeInterval?
    private var previousCPUTicks: (busy: UInt64, idle: UInt64)?
    private var activeGeneration = UUID()

    func start() {
        guard timer == nil else { return }
        activeGeneration = UUID()
        let generation = activeGeneration
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let status: String
            switch path.status {
            case .satisfied: status = "ONLINE"
            case .requiresConnection: status = "CONNECTING"
            case .unsatisfied: status = "OFFLINE"
            @unknown default: status = "UNKNOWN"
            }
            let primary = path.availableInterfaces.first { path.usesInterfaceType($0.type) }?.name
            Task { @MainActor [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                self.isNetworkAvailable = available
                self.pathStatus = status
                self.pathInterfaceName = available ? primary : nil
            }
        }
        pathMonitor = monitor
        monitor.start(queue: monitorQueue)
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                self.sample()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        activeGeneration = UUID()
        timer?.invalidate()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        previousTime = nil
        previousInterfaces = [:]
        previousCPUTicks = nil
        cpuSampleAvailable = false
    }

    deinit {
        timer?.invalidate()
        pathMonitor?.cancel()
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 }
        if var current = readInterfaces() {
            if let elapsed, elapsed > 0 {
                for index in current.indices {
                    let item = current[index]
                    guard let previous = previousInterfaces[item.name], item.isUp, previous.isUp else { continue }
                    // A counter decrease means wrap/reset: establish a fresh baseline without a spike.
                    if item.receivedBytes >= previous.receivedBytes {
                        current[index].receiveBytesPerSecond = Double(item.receivedBytes - previous.receivedBytes) / elapsed
                    }
                    if item.sentBytes >= previous.sentBytes {
                        current[index].sendBytesPerSecond = Double(item.sentBytes - previous.sentBytes) / elapsed
                    }
                }
            }
            interfaces = current
            let primary = current.first { $0.name == pathInterfaceName && $0.isUp }
                ?? current.first { $0.isUp && !$0.addresses.isEmpty && $0.name.hasPrefix("en") }
                ?? current.first { $0.isUp && !$0.addresses.isEmpty && !$0.name.hasPrefix("lo") }
            let changedInterface = primaryInterfaceName != primary?.name
            primaryInterfaceName = primary?.name
            receiveBytesPerSecond = primary?.receiveBytesPerSecond ?? 0
            sendBytesPerSecond = primary?.sendBytesPerSecond ?? 0
            if changedInterface {
                receiveHistory.removeAll()
                sendHistory.removeAll()
            }
            if elapsed != nil, let primary, previousInterfaces[primary.name] != nil {
                append(receiveBytesPerSecond, to: &receiveHistory)
                append(sendBytesPerSecond, to: &sendHistory)
            }
            previousInterfaces = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
            previousTime = now
        }
        sampleCPU()
        sampleMemory()
        uptime = now
        lastUpdated = Date()
    }

    private func append(_ sample: Double, to history: inout [Double]) {
        history.append(sample)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }

    private func readInterfaces() -> [NetworkInterface]? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var items: [String: NetworkInterface] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let entry = pointer.pointee
            cursor = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            var item = items[name] ?? NetworkInterface(name: name)
            item.isUp = (entry.ifa_flags & UInt32(IFF_UP)) != 0 && (entry.ifa_flags & UInt32(IFF_RUNNING)) != 0
            if let address = entry.ifa_addr {
                let family = Int32(address.pointee.sa_family)
                if family == AF_LINK, let data = entry.ifa_data {
                    let counters = data.assumingMemoryBound(to: if_data.self).pointee
                    item.receivedBytes = UInt64(counters.ifi_ibytes)
                    item.sentBytes = UInt64(counters.ifi_obytes)
                } else if family == AF_INET || family == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let value = String(cString: host)
                        if !item.addresses.contains(value) { item.addresses.append(value) }
                    }
                }
            }
            items[name] = item
        }
        return items.values.sorted {
            if $0.isUp != $1.isUp { return $0.isUp }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func sampleCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let ticks = info.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let idle = UInt64(ticks.2)
        defer { previousCPUTicks = (busy, idle) }
        guard let previous = previousCPUTicks, busy >= previous.busy, idle >= previous.idle else { return }
        let busyDelta = busy - previous.busy
        let total = busyDelta + idle - previous.idle
        guard total > 0 else { return }
        cpuUsage = min(1, max(0, Double(busyDelta) / Double(total)))
        cpuSampleAvailable = true
        append(cpuUsage, to: &cpuHistory)
    }

    private func sampleMemory() {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        memoryUsedBytes = min(memoryTotalBytes, pages * UInt64(vm_kernel_page_size))
    }
}
