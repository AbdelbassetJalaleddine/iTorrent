//
//  NetworkMonitoringService.swift
//  iTorrent
//
//  Created by Даниил Виноградов on 02.04.2024.
//

import Combine
import Foundation
import MvvmFoundation
import Network
#if canImport(CoreTelephony)
import CoreTelephony
#else
// Mock for CoreTelephony enum state for unsupported platforms
enum CTCellularDataRestrictedState {
    case restrictedStateUnknown
    case restricted
    case notRestricted
}
#endif

class NetworkMonitoringService {
    // Raw cellular availability, ignores app and system restrictions
    @Published var isCellularAvailable: Bool = false
    @Published var availableInterfaces: [NWInterface] = []
    // True when the system reports a usable internet path that iTorrent is allowed to use
    @Published var isConnected: Bool = true
    @Published var cellularState: CTCellularDataRestrictedState = .restrictedStateUnknown
    /// Names of the interfaces iTorrent may use, in the system's order of
    /// preference (the first one is the primary network). Cellular is left out
    /// when it is not allowed. Published again when their IP addresses change,
    /// so libtorrent can listen on the new addresses.
    @Published var allowedInterfaceNames: [String] = []

    init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            updateAvailableInterfaces()
            if !didReceiveFirstPath {
                didReceiveFirstPath = true
                firstPathReceived.signal()
            }
        }

#if canImport(CoreTelephony) && !targetEnvironment(macCatalyst)
        cellularData.cellularDataRestrictionDidUpdateNotifier = { [weak self] newState in
            guard let self else { return }
            cellularState = newState
            updateAvailableInterfaces()
        }
#endif
        preferences.$isCellularEnabled.receive(on: DispatchQueue.main).sink { [unowned self] _ in
            updateAvailableInterfaces()
        }.store(in: disposeBag)

        let queue = DispatchQueue(label: "monitor queue", qos: .userInitiated)
        monitor.start(queue: queue)
    }

    /// The system reports the network state shortly after the monitor starts.
    /// Waiting for it at launch lets libtorrent start on the right addresses
    /// right away (it does not recover UDP trackers and DHT well when its
    /// listen addresses change right after start).
    func waitForFirstPathUpdate(timeout: TimeInterval = 1) {
        guard !didReceiveFirstPath else { return }
        _ = firstPathReceived.wait(timeout: .now() + timeout)
    }

    /// IP addresses of the given interfaces that can reach other networks
    /// (no loopback, link-local or unique-local addresses), in the order of `names`.
    nonisolated static func routableAddresses(of names: [String]) -> [String] {
        var addressesByName: [String: [String]] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socketAddress = entry.ifa_addr,
                  entry.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard names.contains(name) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let bytes = withUnsafeBytes(of: &address) { Array($0) }
                // Skip loopback (127/8) and link-local (169.254/16)
                guard bytes[0] != 127, !(bytes[0] == 169 && bytes[1] == 254),
                      inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil
                else { continue }
                addressesByName[name, default: []].append(String(cString: buffer))
            case AF_INET6:
                var address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: &address) { Array($0) }
                // Only global unicast (2000::/3): skips loopback, link-local and unique-local
                guard bytes[0] & 0xE0 == 0x20,
                      inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil
                else { continue }
                addressesByName[name, default: []].append(String(cString: buffer))
            default:
                continue
            }
        }
        return names.flatMap { addressesByName[$0] ?? [] }
    }

    private let firstPathReceived = DispatchSemaphore(value: 0)
    private var didReceiveFirstPath = false
    private var allowedSignature: [String]?
    private let disposeBag = DisposeBag()
    private let monitor = NWPathMonitor()
#if canImport(CoreTelephony) && !targetEnvironment(macCatalyst)
    private let cellularData = CTCellularData()
#endif
    @Injected private var preferences: PreferencesStorage
}

private extension NetworkMonitoringService {
    func updateAvailableInterfaces() {
#if canImport(CoreTelephony) && !targetEnvironment(macCatalyst)
        let isCellularRestricted = cellularData.restrictedState == .restricted || !preferences.isCellularEnabled
#else
        let isCellularRestricted = false
#endif

        let isCellularAvailableUpdate = monitor.currentPath.availableInterfaces.contains(where: { $0.type == .cellular })
        if isCellularAvailable != isCellularAvailableUpdate {
            isCellularAvailable = isCellularAvailableUpdate
        }

        let updatedInterfaces: [NWInterface]

        // If cellular restricted and there is no WiFi or Wired interface
        // remove all interfaces to prevent VPN interface from working throw Cellular
        if isCellularRestricted, !monitor.currentPath.availableInterfaces.contains(where: { Self.nonCellularTypes.contains($0.type) }) {
            updatedInterfaces = []
        } else {
            updatedInterfaces = monitor.currentPath.availableInterfaces
        }

        let isConnectedUpdate = monitor.currentPath.status == .satisfied && !updatedInterfaces.isEmpty
        if isConnected != isConnectedUpdate {
            isConnected = isConnectedUpdate
        }

        // Interfaces libtorrent may listen on: never cellular when it is not allowed,
        // even while Wi-Fi is connected (otherwise peers connect over cellular).
        var allowedNames: [String] = []
        for interface in updatedInterfaces where !(isCellularRestricted && interface.type == .cellular) {
            if !allowedNames.contains(interface.name) { allowedNames.append(interface.name) }
        }
        let signature = allowedNames + Self.routableAddresses(of: allowedNames)
        if allowedSignature != signature {
            allowedSignature = signature
            allowedInterfaceNames = allowedNames
        }

        // Do not notify duplicates, otherwise iTorrent will drop connection for nothing
        guard availableInterfaces != updatedInterfaces else { return }
        availableInterfaces = updatedInterfaces
    }

    static let nonCellularTypes: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet]
}
