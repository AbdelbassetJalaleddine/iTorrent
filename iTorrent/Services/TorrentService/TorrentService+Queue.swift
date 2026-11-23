//
//  TorrentService+Queue.swift
//  iTorrent
//
//  Queue that enforces "Max active torrents" and "Max downloading torrents"
//  for torrents the user starts manually.
//
//  Torrents started by the user are not auto-managed by libtorrent, so the
//  libtorrent queue limits do not apply to them. Without this, selecting every
//  torrent and pressing Start would start all of them at once. Here every
//  start request goes into an ordered queue, and torrents are only started
//  while there is a free slot. As soon as a torrent finishes, is paused or is
//  removed, the next queued torrent starts.
//

import Combine
import Foundation
import LibTorrent

// MARK: - Public API
extension TorrentService {
    /// Start torrents while respecting the queue limits.
    /// Torrents that do not fit into the limits are queued and start later.
    func start(_ handles: [TorrentHandle]) {
        var changed: [TorrentHandle] = []
        for handle in handles {
            let snapshot = handle.snapshot
            guard snapshot.isPaused, !snapshot.isStorageMissing else { continue }
            if TorrentQueue.shared.enqueue(snapshot.infoHashes.best.hex) {
                changed.append(handle)
            }
        }
        processQueue()
        changed.forEach { $0.__unthrottledUpdatePublisher.send() }
    }

    func start(_ handle: TorrentHandle) {
        start([handle])
    }

    /// Pause torrents and remove them from the queue.
    func pause(_ handles: [TorrentHandle]) {
        for handle in handles {
            let hash = handle.snapshot.infoHashes.best.hex
            let wasQueued = TorrentQueue.shared.remove(hash)
            pauseTracked(handle)
            if wasQueued { handle.__unthrottledUpdatePublisher.send() }
        }
        processQueue()
    }

    func pause(_ handle: TorrentHandle) {
        pause([handle])
    }

    /// Starts as many queued torrents as the limits allow.
    func processQueue() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        let queue = TorrentQueue.shared
        let handlesByHash = Dictionary(torrents.values.map { ($0.snapshot.infoHashes.best.hex, $0) }, uniquingKeysWith: { first, _ in first })

        // Snapshots are refreshed asynchronously, so right after resume() or
        // pause() a snapshot may still show the old state. Remember what we
        // asked for until the snapshot catches up (or 10 seconds pass).
        let now = Date()
        pendingStarts = pendingStarts.filter { hash, date in
            guard let handle = handlesByHash[hash] else { return false }
            return handle.snapshot.isPaused && now.timeIntervalSince(date) < 10
        }
        pendingPauses = pendingPauses.filter { hash, date in
            guard let handle = handlesByHash[hash] else { return false }
            return !handle.snapshot.isPaused && now.timeIntervalSince(date) < 10
        }

        func isRunning(_ hash: String, _ snapshot: TorrentHandle.Snapshot) -> Bool {
            if pendingStarts[hash] != nil { return true }
            if pendingPauses[hash] != nil { return false }
            return !snapshot.isPaused
        }

        // Drop entries that no longer make sense (removed / started elsewhere).
        for hash in queue.items {
            guard let handle = handlesByHash[hash] else {
                queue.remove(hash)
                continue
            }
            if isRunning(hash, handle.snapshot) {
                queue.remove(hash)
            }
        }

        guard !queue.items.isEmpty else { return }

        let maxActive = preferences.maxActiveTorrents
        let maxDownloading = preferences.maxDownloadingTorrents

        var active = 0
        var downloading = 0
        var runningSeeds: [TorrentHandle] = []
        for (hash, handle) in handlesByHash {
            let snapshot = handle.snapshot
            guard isRunning(hash, snapshot) else { continue }
            active += 1
            if snapshot.needsDownload {
                downloading += 1
            } else if pendingStarts[hash] == nil {
                runningSeeds.append(handle)
            }
        }

        func fits(_ count: Int, _ limit: Int) -> Bool {
            limit <= 0 || count < limit
        }

        var toStart: [TorrentHandle] = []
        var toRequeue: [TorrentHandle] = []
        for hash in queue.items {
            guard let handle = handlesByHash[hash] else { continue }
            let snapshot = handle.snapshot
            if snapshot.isStorageMissing { continue }

            if snapshot.needsDownload {
                guard fits(downloading, maxDownloading) else { continue }
                if !fits(active, maxActive) {
                    // Downloads have priority over seeding: put a seeding
                    // torrent back into the queue to free an active slot.
                    guard !runningSeeds.isEmpty else { continue }
                    toRequeue.append(runningSeeds.removeFirst())
                    active -= 1
                }
                downloading += 1
            } else {
                guard fits(active, maxActive) else { continue }
            }

            active += 1
            toStart.append(handle)
        }

        for seed in toRequeue {
            pauseTracked(seed)
            queue.enqueue(seed.snapshot.infoHashes.best.hex)
            seed.__unthrottledUpdatePublisher.send()
        }

        for handle in toStart {
            let hash = handle.snapshot.infoHashes.best.hex
            queue.remove(hash)
            resumeTracked(handle)
            handle.__unthrottledUpdatePublisher.send()
        }
    }

    /// Resume a torrent and remember it as running until its snapshot updates.
    func resumeTracked(_ handle: TorrentHandle) {
        let hash = handle.snapshot.infoHashes.best.hex
        pendingPauses[hash] = nil
        pendingStarts[hash] = Date()
        handle.resume()
    }

    /// Pause a torrent and remember it as paused until its snapshot updates.
    func pauseTracked(_ handle: TorrentHandle) {
        let hash = handle.snapshot.infoHashes.best.hex
        pendingStarts[hash] = nil
        if !handle.snapshot.isPaused { pendingPauses[hash] = Date() }
        handle.pause()
    }

    /// Torrents that are added while the limits are full are queued too.
    func applyQueueToNewTorrent(_ handle: TorrentHandle, attempt: Int = 0) {
        // libtorrent starts new torrents itself (as "auto managed"), and only
        // counts auto managed torrents against its limits. Take control of
        // the new torrent so the same limits apply to every torrent, then
        // let the queue decide when it starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak handle] in
            guard let self, let handle else { return }
            let snapshot = handle.snapshot
            guard snapshot.isValid else { return }
            // libtorrent ignores pause while it validates resume data; retry.
            if snapshot.state == .checkingResumeData {
                if attempt < 20 { applyQueueToNewTorrent(handle, attempt: attempt + 1) }
                return
            }
            pauseTracked(handle)
            TorrentQueue.shared.enqueue(snapshot.infoHashes.best.hex)
            processQueue()
            handle.__unthrottledUpdatePublisher.send()
        }
    }

    func setupQueue() {
        disposeBag.bind {
            // Re-check the queue whenever any torrent changes its state.
            updateNotifier
                .filter { model in
                    guard let handle = model.handle else { return true }
                    let old = model.oldSnapshot
                    let new = handle.snapshot
                    return old.isPaused != new.isPaused || old.needsDownload != new.needsDownload || old.state != new.state
                }
                .sink { [unowned self] _ in
                    processQueue()
                }

            // Limits changed in Preferences.
            preferences.$maxActiveTorrents
                .combineLatest(preferences.$maxDownloadingTorrents)
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [unowned self] _ in
                    processQueue()
                }

            // Safety net in case some state change was missed.
            Timer.publish(every: 5, on: .main, in: .common)
                .autoconnect()
                .sink { [unowned self] _ in
                    processQueue()
                }
        }


        processQueue()
    }
}

// MARK: - Snapshot helpers
extension TorrentHandle.Snapshot {
    /// The torrent still has something to download (or metadata to fetch).
    var needsDownload: Bool {
        !hasMetadata || !isFinished
    }

    /// The torrent is waiting in the queue for a free slot.
    var isQueued: Bool {
        isPaused && TorrentQueue.shared.contains(infoHashes.best.hex)
    }
}

extension TorrentHandle.ObservedSnapshot {
    /// The torrent is waiting in the queue for a free slot.
    var isQueued: Bool {
        isPaused && TorrentQueue.shared.contains(infoHashes.best.hex)
    }
}

// MARK: - Storage
/// Ordered, persisted list of queued torrents (info hash hex strings).
/// Thread safe, because snapshots may be read from background queues.
nonisolated final class TorrentQueue: @unchecked Sendable {
    static let shared = TorrentQueue()

    init() {
        items_ = defaults.stringArray(forKey: Self.key) ?? []
    }

    var items: [String] {
        lock.lock(); defer { lock.unlock() }
        return items_
    }

    func contains(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items_.contains(hash)
    }

    /// Returns true if the hash was added.
    @discardableResult
    func enqueue(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !items_.contains(hash) else { return false }
        items_.append(hash)
        save()
        return true
    }

    /// Returns true if the hash was in the queue.
    @discardableResult
    func remove(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = items_.firstIndex(of: hash) else { return false }
        items_.remove(at: index)
        save()
        return true
    }

    private func save() {
        defaults.set(items_, forKey: Self.key)
    }

    private static let key = "torrentStartQueue"
    private let defaults = UserDefaults(suiteName: "group.itorrent.life-activity") ?? .standard
    private let lock = NSLock()
    private var items_: [String]
}
