//
//  StartScheduledTorrentsIntent.swift
//  iTorrent
//
//  Shortcuts action for the daily schedule. iOS suspends iTorrent when
//  nothing is downloading, so it can't wake itself up at the start time.
//  A Shortcuts "Time of Day" automation running this action wakes it up.
//
//  It is an AudioPlaybackIntent: iOS runs it in the app's process in the
//  background and lets it start audio, which iTorrent uses to keep
//  downloading in the background.
//

import AppIntents
import UIKit

@available(iOS 17.0, *)
struct StartScheduledTorrentsIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Start Scheduled Torrents"
    static let description = IntentDescription("Starts every paused torrent that isn't finished, following the download queue. Run it from a Time of Day automation at your schedule's start time.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        try await ITorrentIntentError.checkAppIsReady()
        await MainActor.run {
            PreferencesStorage.shared.scheduleHandledStart = Date()
            TorrentService.shared.runScheduledStart()

            // Keep downloading after the action finishes.
            if UIApplication.shared.applicationState != .active,
               PreferencesStorage.shared.isBackgroundDownloadEnabled
            {
                BackgroundService.shared.start()
            }
        }
        return .result()
    }
}

/// Errors shown in Shortcuts.
enum ITorrentIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "iTorrent was closed by iOS. Open iTorrent once, then the automation will work again."
        }
    }

    /// iTorrent sets up its services when its window is created. If iOS
    /// launched the app only for this action, that has not happened yet.
    static func checkAppIsReady() async throws {
        let isReady = await MainActor.run { !UIApplication.shared.connectedScenes.isEmpty }
        guard isReady else { throw ITorrentIntentError.appNotReady }
    }
}
