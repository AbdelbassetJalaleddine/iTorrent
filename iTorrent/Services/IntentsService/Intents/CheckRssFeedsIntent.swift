//
//  CheckRssFeedsIntent.swift
//  iTorrent
//
//  Shortcuts action: refresh RSS feeds now, so auto-download adds new
//  torrents. Useful in the same automation as "Start Scheduled Torrents",
//  right before it.
//

import AppIntents
import MvvmFoundation

@available(iOS 17.0, *)
struct CheckRssFeedsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check RSS Feeds"
    static let description = IntentDescription("Refreshes your RSS feeds. Feeds with auto-download turned on add their new torrents (paused).")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        try await ITorrentIntentError.checkAppIsReady()
        let provider = await MainActor.run { Mvvm.shared.container.resolve(type: RssFeedProvider.self) }
        try await provider.fetchUpdates()
        return .result()
    }
}
