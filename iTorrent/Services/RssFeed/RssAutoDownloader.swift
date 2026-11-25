//
//  RssAutoDownloader.swift
//  iTorrent
//
//  Automatically adds new torrents from RSS feeds.
//
//  - Turned on per feed, with optional "must contain" / "must not contain"
//    word filters on the item title.
//  - Items that are already in the feed when the rule is turned on are
//    ignored, only items that appear later are added.
//  - Torrents are added paused: they start with the daily schedule or when
//    the user starts them.
//  - Rules are stored separately from the feeds, so the saved feed format
//    does not change.
//

import Combine
import Foundation
import LibTorrent
import MvvmFoundation
import UIKit
import UserNotifications

struct RssAutoDownloadRule: Codable, Equatable {
    var isEnabled: Bool = false
    /// Space or comma separated words; the title must contain all of them.
    var mustContain: String = ""
    /// Space or comma separated words; the title must contain none of them.
    var mustNotContain: String = ""
    /// Items already handled (or present when the rule was turned on).
    var seenItems: [String] = []
}

final class RssAutoDownloader: ObservableObject {
    static let shared = RssAutoDownloader()

    @Published private(set) var rules: [String: RssAutoDownloadRule]

    /// How often feeds are checked while the app is running.
    static let checkInterval: TimeInterval = 15 * 60
    private static let storageKey = "RssAutoDownloadRules"
    private static let maxSeenItems = 1000
    private static let maxFailedAttempts = 3

    private var failedAttempts: [String: Int] = [:]
    private var isProcessing = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let rules = try? JSONDecoder().decode([String: RssAutoDownloadRule].self, from: data)
        {
            self.rules = rules
        } else {
            rules = [:]
        }
    }

    var hasEnabledRules: Bool {
        rules.values.contains(where: \.isEnabled)
    }
}

// MARK: - Rule editing
extension RssAutoDownloader {
    func rule(for feed: RssModel) -> RssAutoDownloadRule {
        rules[Self.key(for: feed)] ?? .init()
    }

    func rulePublisher(for feed: RssModel) -> AnyPublisher<RssAutoDownloadRule, Never> {
        let key = Self.key(for: feed)
        return $rules.map { $0[key] ?? .init() }.removeDuplicates().eraseToAnyPublisher()
    }

    func setEnabled(_ enabled: Bool, for feed: RssModel) {
        var rule = rule(for: feed)
        guard rule.isEnabled != enabled else { return }
        rule.isEnabled = enabled
        if enabled {
            // Only items that appear from now on are added.
            rule.seenItems = Array(feed.items.map(Self.key(for:)).prefix(Self.maxSeenItems))
        }
        update(rule, for: feed)
    }

    func setMustContain(_ text: String, for feed: RssModel) {
        var rule = rule(for: feed)
        rule.mustContain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update(rule, for: feed)
    }

    func setMustNotContain(_ text: String, for feed: RssModel) {
        var rule = rule(for: feed)
        rule.mustNotContain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update(rule, for: feed)
    }

    func removeRule(for feed: RssModel) {
        rules[Self.key(for: feed)] = nil
        save()
    }
}

// MARK: - Processing
extension RssAutoDownloader {
    /// Adds new matching items of the given feeds. Call after the feeds were refreshed.
    func process(_ feeds: [RssModel]) async {
        // The torrent engine is only set up once the app's window exists.
        // When iOS runs a background refresh without it, try again later.
        guard !UIApplication.shared.connectedScenes.isEmpty else { return }
        guard hasEnabledRules, !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        for feed in feeds {
            let feedKey = Self.key(for: feed)
            guard var rule = rules[feedKey], rule.isEnabled else { continue }
            var seen = Set(rule.seenItems)

            // Oldest first, so torrents are added in release order.
            for item in feed.items.reversed() {
                let itemKey = Self.key(for: item)
                guard !seen.contains(itemKey) else { continue }

                guard Self.matches(item.title ?? "", rule: rule) else {
                    seen.insert(itemKey); rule.seenItems.append(itemKey)
                    continue
                }

                let result = await add(item)
                switch result {
                case .added(let name):
                    notifyAdded(name, feed: feed)
                    fallthrough
                case .alreadyAdded, .noTorrent:
                    seen.insert(itemKey); rule.seenItems.append(itemKey)
                    failedAttempts[itemKey] = nil
                case .failed:
                    // Network problem: retry later, but not forever.
                    let attempts = (failedAttempts[itemKey] ?? 0) + 1
                    failedAttempts[itemKey] = attempts
                    if attempts >= Self.maxFailedAttempts {
                        seen.insert(itemKey); rule.seenItems.append(itemKey)
                        failedAttempts[itemKey] = nil
                    }
                }
            }

            if rule.seenItems.count > Self.maxSeenItems {
                rule.seenItems.removeFirst(rule.seenItems.count - Self.maxSeenItems)
            }
            // The rule may have been edited while we were downloading.
            if var current = rules[feedKey] {
                current.seenItems = rule.seenItems
                rules[feedKey] = current
            }
        }
        save()
    }
}

private extension RssAutoDownloader {
    enum AddResult {
        case added(String)
        case alreadyAdded
        case noTorrent
        case failed
    }

    func add(_ item: RssItemModel) async -> AddResult {
        let name = item.title ?? ""

        // Magnet link (in the enclosure or the item link)
        let magnet = [item.enclosure?.url, item.link]
            .compactMap { $0 }
            .lazy
            .compactMap { MagnetURI(with: $0) }
            .first
        if let magnet {
            guard !TorrentService.shared.checkTorrentExists(with: magnet.infoHashes) else { return .alreadyAdded }
            TorrentService.shared.addTorrent(by: magnet, startPaused: true)
            return .added(name)
        }

        // .torrent file
        let remoteURLs = [item.enclosure?.url, item.link]
            .compactMap { $0 }
            .filter { ["http", "https"].contains($0.scheme?.lowercased()) }
        guard !remoteURLs.isEmpty else { return .noTorrent }

        for url in remoteURLs {
            guard let file = try? await TorrentFile.download(from: url) else { continue }
            guard !TorrentService.shared.checkTorrentExists(with: file.infoHashes) else { return .alreadyAdded }
            TorrentService.shared.addTorrent(by: file, startPaused: true)
            return .added(name)
        }
        return .failed
    }

    func notifyAdded(_ name: String, feed: RssModel) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "rss.autoDownload.added", defaultValue: "Added from RSS")
        content.body = name.isEmpty ? feed.title : name
        content.sound = .default
        let request = UNNotificationRequest(identifier: "rss.autoDownload.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func update(_ rule: RssAutoDownloadRule, for feed: RssModel) {
        rules[Self.key(for: feed)] = rule
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func key(for feed: RssModel) -> String {
        feed.xmlLink.absoluteString
    }

    static func key(for item: RssItemModel) -> String {
        if let guid = item.guid, !guid.isEmpty { return "guid:" + guid }
        return "item:" + [item.title, item.link?.absoluteString, item.enclosure?.url.absoluteString]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ title: String, rule: RssAutoDownloadRule) -> Bool {
        let required = words(rule.mustContain)
        let excluded = words(rule.mustNotContain)
        let allRequired = required.allSatisfy { title.localizedCaseInsensitiveContains($0) }
        let noneExcluded = !excluded.contains { title.localizedCaseInsensitiveContains($0) }
        return allRequired && noneExcluded
    }
}
