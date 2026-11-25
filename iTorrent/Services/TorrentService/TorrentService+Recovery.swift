//
//  TorrentService+Recovery.swift
//  iTorrent
//
//  Brings torrents back to life after the internet connection drops.
//
//  When the connection disappears for a while, libtorrent loses all peers and
//  backs off from trackers that failed to answer, so downloads can stay at
//  0 B/s even after the connection comes back (until the torrent is paused
//  and started again by hand). This does that automatically:
//   - when the connection comes back, stalled torrents are restarted and all
//     trackers are re-announced;
//   - a watchdog restarts torrents that have been stuck at 0 B/s while the
//     device is online (covers the case where Wi-Fi stays connected but the
//     router loses internet, which the system does not always report).
//

import Combine
import Foundation
import LibTorrent

extension TorrentService {
    /// How long a running download may stay at 0 B/s before it gets restarted.
    private static let stallTimeout: TimeInterval = 120
    /// Minimum time between two automatic restarts of the same torrent.
    private static let restartInterval: TimeInterval = 300
    /// Time to let the network settle after it comes back.
    private static let reconnectDelay: TimeInterval = 5

    func setupConnectionRecovery() {
        disposeBag.bind {
            network.$isConnected
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [unowned self] isConnected in
                    if !isConnected {
                        wasDisconnected = true
                        return
                    }
                    guard wasDisconnected else { return }
                    wasDisconnected = false
                    scheduleConnectionRecovery()
                }

            // Switching networks (e.g. Wi-Fi -> Cellular, or a new Wi-Fi)
            // also breaks every existing connection.
            network.$availableInterfaces
                .dropFirst()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [unowned self] interfaces in
                    guard !interfaces.isEmpty else { return }
                    scheduleConnectionRecovery()
                }

            Timer.publish(every: 30, on: .main, in: .common)
                .autoconnect()
                .sink { [unowned self] _ in
                    checkStalledTorrents()
                }
        }
    }
}

private extension TorrentService {
    func scheduleConnectionRecovery() {
        guard Date() >= recoveryReadyDate else { return }
        // Only the latest request runs (network changes often come in bursts)
        recoveryGeneration += 1
        let generation = recoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
            guard let self, recoveryGeneration == generation else { return }
            recoverConnections()
        }
    }

    func recoverConnections() {
        guard network.isConnected else { return }
        print("[Recovery] Connection restored, reviving torrents")

        let now = Date()
        for handle in torrents.values {
            let snapshot = handle.snapshot
            guard !snapshot.isPaused else { continue }

            let hash = snapshot.infoHashes.best.hex
            if snapshot.needsDownload, snapshot.downloadRate == 0 {
                restart(handle)
                lastAutoRestart[hash] = now
                stalledSince[hash] = nil
            } else {
                handle.forceReannounce()
            }
        }
        session.reannounceToAllTrackers()
    }

    func checkStalledTorrents() {
        let now = Date()
        var stillTracked: [String: Date] = [:]

        for handle in torrents.values {
            let snapshot = handle.snapshot
            let hash = snapshot.infoHashes.best.hex

            let isStalledDownload = !snapshot.isPaused &&
                snapshot.needsDownload &&
                snapshot.downloadRate == 0 &&
                (snapshot.state == .downloading || snapshot.state == .downloadingMetadata)
            guard isStalledDownload else { continue }

            let since = stalledSince[hash] ?? now
            stillTracked[hash] = since

            guard network.isConnected,
                  now.timeIntervalSince(since) >= Self.stallTimeout,
                  now.timeIntervalSince(lastAutoRestart[hash] ?? .distantPast) >= Self.restartInterval
            else { continue }

            print("[Recovery] Restarting stalled torrent: \(snapshot.name)")
            restart(handle)
            lastAutoRestart[hash] = now
            stillTracked[hash] = now
        }

        stalledSince = stillTracked
        lastAutoRestart = lastAutoRestart.filter { now.timeIntervalSince($0.value) < Self.restartInterval * 4 }
    }

    /// Same as pressing Pause and then Start: drops dead connections,
    /// resets tracker back-off and asks trackers / DHT for fresh peers.
    func restart(_ handle: TorrentHandle) {
        let hash = handle.snapshot.infoHashes.best.hex
        // Keep the torrent counted as running, so the queue does not
        // start another torrent in its place during the restart.
        pendingStarts[hash] = Date()
        handle.pause()
        handle.resume()
        handle.forceReannounce()
    }
}
