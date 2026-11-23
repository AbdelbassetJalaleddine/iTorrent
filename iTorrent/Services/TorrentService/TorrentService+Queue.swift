//
//  TorrentService+Queue.swift
//  iTorrent
//
//  Ordered download queue that enforces "Max active torrents" and
//  "Max downloading torrents" for every torrent.
//
//  Torrents started by the user are not auto-managed by libtorrent, so the
//  libtorrent queue limits do not apply to them. Here every start request
//  goes into an ordered queue (#1, #2, #3...), and torrents only start while
//  there is a free slot. As soon as a torrent finishes, is paused or is
//  removed, the next queued torrent starts.
//
//  Slow torrents: a download that stays below the "slow torrent" speed for a
//  while does not take up a slot, so the next queued torrent can start next
//  to it. When the higher priority torrent becomes fast again, extra
//  torrents that are slow go back into the queue (fast ones keep going).
//

import Combine
import Foundation
import LibTorrent

// MARK: - Tuning
private enum QueueTiming {
    /// A just-started torrent needs time to find peers; never treat it as slow before this.
    static let startGracePeriod: TimeInterval = 60
    /// How long a download must stay below the threshold to count as slow.
    static let becomeSlowAfter: TimeInterval = 30
    /// How long a slow download must stay above the threshold to count as fast again.
    static let becomeFastAfter: TimeInterval = 15
    /// How long we trust our own resume()/pause() calls before the snapshot catches up.
    static let pendingTimeout: TimeInterval = 10
}

// MARK: - Public API
extension TorrentService {
    enum QueueMove {
        case top, up, down, bottom
    }

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
        refreshQueuedTorrents()
    }

    func start(_ handle: TorrentHandle) {
        start([handle])
    }

    /// Pause torrents and remove them from the queue.
    func pause(_ handles: [TorrentHandle]) {
        for handle in handles {
            let hash = handle.snapshot.infoHashes.best.hex
            let wasQueued = TorrentQueue.shared.contains(hash)
            TorrentQueue.shared.forget(hash)
            pauseTracked(handle)
            if wasQueued { handle.__unthrottledUpdatePublisher.send() }
        }
        processQueue()
        refreshQueuedTorrents()
    }

    func pause(_ handle: TorrentHandle) {
        pause([handle])
    }

    /// Change the position of queued torrents.
    func moveInQueue(_ handles: [TorrentHandle], _ move: QueueMove) {
        let store = TorrentQueue.shared
        let order = store.order
        // Work in queue order, so a multi-selection keeps its relative order.
        let hashes = handles
            .map { $0.snapshot.infoHashes.best.hex }
            .filter { store.contains($0) }
            .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        let ordered = move == .top || move == .down ? Array(hashes.reversed()) : hashes
        for hash in ordered {
            TorrentQueue.shared.move(hash, move)
        }
        processQueue()
        refreshQueuedTorrents()
    }

    /// 1-based position among queued torrents, nil if not queued.
    func queuePosition(of handle: TorrentHandle) -> Int? {
        TorrentQueue.shared.position(of: handle.snapshot.infoHashes.best.hex)
    }

    /// Applies the queue: starts queued torrents while there is room and
    /// puts slow extra torrents back into the queue when they are not needed.
    func processQueue() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        let store = TorrentQueue.shared
        let handlesByHash = Dictionary(torrents.values.map { ($0.snapshot.infoHashes.best.hex, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()

        // Snapshots are refreshed asynchronously, so right after resume() or
        // pause() a snapshot may still show the old state. Remember what we
        // asked for until the snapshot catches up.
        pendingStarts = pendingStarts.filter { hash, date in
            guard let handle = handlesByHash[hash] else { return false }
            return handle.snapshot.isPaused && now.timeIntervalSince(date) < QueueTiming.pendingTimeout
        }
        pendingPauses = pendingPauses.filter { hash, date in
            guard let handle = handlesByHash[hash] else { return false }
            return !handle.snapshot.isPaused && now.timeIntervalSince(date) < QueueTiming.pendingTimeout
        }

        func isRunning(_ hash: String) -> Bool {
            if pendingStarts[hash] != nil { return true }
            if pendingPauses[hash] != nil { return false }
            return handlesByHash[hash].map { !$0.snapshot.isPaused } ?? false
        }

        // 1. Keep the stored order in sync with reality.
        var orderChanged = false
        for hash in store.order {
            guard let handle = handlesByHash[hash] else {
                store.forget(hash); orderChanged = true
                continue
            }
            let snapshot = handle.snapshot
            let running = isRunning(hash)
            if store.contains(hash) {
                // Queued torrent was started from somewhere else.
                if running { store.markRunning(hash); orderChanged = true }
            } else if !running || !snapshot.needsDownload {
                // Paused from somewhere else, or finished downloading.
                store.forget(hash); orderChanged = true
            }
        }
        // Downloads that run but are unknown to the queue (e.g. started before
        // this feature existed) keep their slot: put them first.
        for (hash, handle) in handlesByHash where isRunning(hash) && handle.snapshot.needsDownload && !store.isTracked(hash) {
            store.adoptRunning(hash)
        }

        // Forget speed tracking for torrents that are not running.
        startedAt = startedAt.filter { isRunning($0.key) }
        slowHashes = slowHashes.filter { isRunning($0) }
        speedTransitionSince = speedTransitionSince.filter { isRunning($0.key) }

        // 2. Count what is running.
        let maxActive = preferences.maxActiveTorrents
        let maxDownloading = preferences.maxDownloadingTorrents
        // Slow downloads do not use a slot, but never run more than twice the limit.
        let maxRunningDownloads = maxDownloading > 0 ? max(maxDownloading * 2, maxDownloading + 1) : 0

        func fits(_ count: Int, _ limit: Int) -> Bool {
            limit <= 0 || count < limit
        }

        let runningDownloads = store.order.filter { hash in
            isRunning(hash) && (handlesByHash[hash]?.snapshot.needsDownload ?? false)
        }
        var slow: Set<String> = []
        for hash in runningDownloads {
            guard let snapshot = handlesByHash[hash]?.snapshot else { continue }
            if updateSlowState(hash, downloadRate: snapshot.downloadRate, now: now) {
                slow.insert(hash)
            }
        }

        var fastDownloads = runningDownloads.count - slow.count
        var totalDownloads = runningDownloads.count
        var runningSeeds: [TorrentHandle] = []
        for (hash, handle) in handlesByHash where isRunning(hash) && !handle.snapshot.needsDownload {
            if pendingStarts[hash] == nil { runningSeeds.append(handle) }
        }
        var active = fastDownloads + runningSeeds.count + pendingStarts.keys.filter { hash in
            !(handlesByHash[hash]?.snapshot.needsDownload ?? true)
        }.count

        // 3. Enough fast downloads: put slow extra torrents back into the queue.
        //    The first `maxDownloading` torrents by priority always keep running.
        var toRequeue: [TorrentHandle] = []
        if maxDownloading > 0, fastDownloads >= maxDownloading {
            for (rank, hash) in runningDownloads.enumerated() where rank >= maxDownloading {
                guard slow.contains(hash), pendingStarts[hash] == nil, let handle = handlesByHash[hash] else { continue }
                toRequeue.append(handle)
                totalDownloads -= 1
            }
        }

        // 4. Start queued torrents in order while there is room.
        var toStart: [TorrentHandle] = []
        var seedsToRequeue: [TorrentHandle] = []
        for hash in store.queuedItems {
            guard let handle = handlesByHash[hash] else { continue }
            let snapshot = handle.snapshot
            if snapshot.isStorageMissing { continue }

            if snapshot.needsDownload {
                guard fits(fastDownloads, maxDownloading), fits(totalDownloads, maxRunningDownloads) else { continue }
                if !fits(active, maxActive) {
                    // Downloads have priority over seeding: put a seeding
                    // torrent back into the queue to free an active slot.
                    guard !runningSeeds.isEmpty else { continue }
                    seedsToRequeue.append(runningSeeds.removeFirst())
                    active -= 1
                }
                fastDownloads += 1 // counts as fast during its start grace period
                totalDownloads += 1
            } else {
                guard fits(active, maxActive) else { continue }
            }

            active += 1
            toStart.append(handle)
        }

        // 5. Apply.
        for handle in toRequeue + seedsToRequeue {
            pauseTracked(handle)
            store.enqueue(handle.snapshot.infoHashes.best.hex)
            handle.__unthrottledUpdatePublisher.send()
        }
        for handle in toStart {
            store.markRunning(handle.snapshot.infoHashes.best.hex)
            resumeTracked(handle)
            handle.__unthrottledUpdatePublisher.send()
        }

        if orderChanged || !toStart.isEmpty || !toRequeue.isEmpty || !seedsToRequeue.isEmpty {
            refreshQueuedTorrents()
        }
    }

    /// Resume a torrent and remember it as running until its snapshot updates.
    func resumeTracked(_ handle: TorrentHandle) {
        let hash = handle.snapshot.infoHashes.best.hex
        pendingPauses[hash] = nil
        pendingStarts[hash] = Date()
        startedAt[hash] = Date()
        slowHashes.remove(hash)
        speedTransitionSince[hash] = nil
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
    func applyQueueToNewTorrent(_ handle: TorrentHandle, start: Bool = true, attempt: Int = 0) {
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
                if attempt < 20 { applyQueueToNewTorrent(handle, start: start, attempt: attempt + 1) }
                return
            }
            pauseTracked(handle)
            // Added paused: keep it paused, outside of the queue.
            guard start else {
                handle.__unthrottledUpdatePublisher.send()
                return
            }
            TorrentQueue.shared.enqueue(snapshot.infoHashes.best.hex)
            processQueue()
            handle.__unthrottledUpdatePublisher.send()
            refreshQueuedTorrents()
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
                .combineLatest(preferences.$maxDownloadingTorrents, preferences.$slowTorrentThreshold)
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [unowned self] _ in
                    processQueue()
                }

            // Periodic check: tracks download speeds for the slow-torrent rule,
            // and is a safety net in case some state change was missed.
            Timer.publish(every: 5, on: .main, in: .common)
                .autoconnect()
                .sink { [unowned self] _ in
                    processQueue()
                }
        }

        processQueue()
    }
}

private extension TorrentService {
    /// Returns whether a running download currently counts as slow.
    /// Uses delays in both directions so short speed spikes or drops do
    /// not start and stop torrents all the time.
    func updateSlowState(_ hash: String, downloadRate: UInt64, now: Date) -> Bool {
        let thresholdKBs = preferences.slowTorrentThreshold
        guard thresholdKBs > 0 else {
            slowHashes.remove(hash)
            speedTransitionSince[hash] = nil
            return false
        }

        if let started = startedAt[hash], now.timeIntervalSince(started) < QueueTiming.startGracePeriod {
            return false
        }

        let isBelow = downloadRate < UInt64(thresholdKBs) * 1024
        let isSlow = slowHashes.contains(hash)
        guard isBelow != isSlow else {
            speedTransitionSince[hash] = nil
            return isSlow
        }

        let since = speedTransitionSince[hash] ?? now
        speedTransitionSince[hash] = since
        let required = isSlow ? QueueTiming.becomeFastAfter : QueueTiming.becomeSlowAfter
        guard now.timeIntervalSince(since) >= required else { return isSlow }

        speedTransitionSince[hash] = nil
        if isSlow { slowHashes.remove(hash) } else { slowHashes.insert(hash) }
        return !isSlow
    }

    /// Queue positions changed: refresh every queued torrent so "#N" updates.
    func refreshQueuedTorrents() {
        queueChanged.send()
        let queued = Set(TorrentQueue.shared.queuedItems)
        for handle in torrents.values where queued.contains(handle.snapshot.infoHashes.best.hex) {
            handle.__unthrottledUpdatePublisher.send()
        }
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

    /// 1-based position in the queue, nil when not queued.
    var queuePosition: Int? {
        guard isPaused else { return nil }
        return TorrentQueue.shared.position(of: infoHashes.best.hex)
    }
}

extension TorrentHandle.ObservedSnapshot {
    /// The torrent is waiting in the queue for a free slot.
    var isQueued: Bool {
        isPaused && TorrentQueue.shared.contains(infoHashes.best.hex)
    }

    /// 1-based position in the queue, nil when not queued.
    var queuePosition: Int? {
        guard isPaused else { return nil }
        return TorrentQueue.shared.position(of: infoHashes.best.hex)
    }
}

extension TorrentHandle {
    /// "Queued #2" (or "Queued" when the position is unknown).
    static func queuedStateName(position: Int?) -> String {
        guard let position else { return queuedStateName }
        return "\(queuedStateName) #\(position)"
    }
}

// MARK: - Storage
/// Persisted queue: the priority order of the torrents the queue manages
/// (queued ones and the downloads it started), plus which of them are
/// waiting. Thread safe, because snapshots may be read from background queues.
nonisolated final class TorrentQueue: @unchecked Sendable {
    static let shared = TorrentQueue()

    init() {
        if let order = defaults.stringArray(forKey: Self.orderKey) {
            order_ = order
            queued_ = Set(defaults.stringArray(forKey: Self.queuedKey) ?? [])
        } else {
            // Data from the first version of the queue (queued items only).
            let legacy = defaults.stringArray(forKey: Self.legacyKey) ?? []
            order_ = legacy
            queued_ = Set(legacy)
        }
    }

    /// All managed torrents, highest priority first.
    var order: [String] {
        lock.lock(); defer { lock.unlock() }
        return order_
    }

    /// Waiting torrents, highest priority first.
    var queuedItems: [String] {
        lock.lock(); defer { lock.unlock() }
        return order_.filter { queued_.contains($0) }
    }

    /// Whether the torrent is waiting in the queue.
    func contains(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return queued_.contains(hash)
    }

    /// Whether the torrent is known to the queue (waiting or running).
    func isTracked(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return order_.contains(hash)
    }

    /// 1-based position among waiting torrents.
    func position(of hash: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard queued_.contains(hash) else { return nil }
        var position = 0
        for item in order_ where queued_.contains(item) {
            position += 1
            if item == hash { return position }
        }
        return nil
    }

    /// Mark as waiting. New torrents go to the end; known ones keep their place.
    /// Returns true if the torrent was not waiting before.
    @discardableResult
    func enqueue(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !order_.contains(hash) { order_.append(hash) }
        let inserted = queued_.insert(hash).inserted
        save()
        return inserted
    }

    /// The torrent started; it keeps its priority.
    func markRunning(_ hash: String) {
        lock.lock(); defer { lock.unlock() }
        if !order_.contains(hash) { order_.append(hash) }
        queued_.remove(hash)
        save()
    }

    /// A running download the queue did not start: give it top priority.
    func adoptRunning(_ hash: String) {
        lock.lock(); defer { lock.unlock() }
        guard !order_.contains(hash) else { return }
        order_.insert(hash, at: 0)
        save()
    }

    /// Stop managing the torrent (paused by the user, finished or removed).
    func forget(_ hash: String) {
        lock.lock(); defer { lock.unlock() }
        order_.removeAll { $0 == hash }
        queued_.remove(hash)
        save()
    }

    func move(_ hash: String, _ move: TorrentService.QueueMove) {
        lock.lock(); defer { lock.unlock() }
        guard let index = order_.firstIndex(of: hash) else { return }

        switch move {
        case .top:
            order_.remove(at: index)
            order_.insert(hash, at: 0)
        case .bottom:
            order_.remove(at: index)
            order_.append(hash)
        case .up:
            // Swap with the previous waiting torrent.
            guard let target = order_[..<index].lastIndex(where: { queued_.contains($0) }) else { return }
            order_.remove(at: index)
            order_.insert(hash, at: target)
        case .down:
            // Swap with the next waiting torrent.
            guard let target = order_[(index + 1)...].firstIndex(where: { queued_.contains($0) }) else { return }
            order_.remove(at: index)
            order_.insert(hash, at: target)
        }
        save()
    }

    private func save() {
        defaults.set(order_, forKey: Self.orderKey)
        defaults.set(order_.filter { queued_.contains($0) }, forKey: Self.queuedKey)
    }

    private static let orderKey = "torrentQueueOrder"
    private static let queuedKey = "torrentQueueWaiting"
    private static let legacyKey = "torrentStartQueue"
    private let defaults = UserDefaults(suiteName: "group.itorrent.life-activity") ?? .standard
    private let lock = NSLock()
    private var order_: [String]
    private var queued_: Set<String>
}
