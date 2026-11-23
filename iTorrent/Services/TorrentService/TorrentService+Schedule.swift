//
//  TorrentService+Schedule.swift
//  iTorrent
//
//  Daily download schedule.
//
//  - At the stop time every running torrent (downloading and seeding) is
//    paused. The queue order is remembered.
//  - At the start time every paused torrent that is not finished is started
//    through the queue (so the queue limits still apply), in the remembered
//    order.
//  - Outside the window the user can still start torrents manually.
//
//  iOS suspends the app when nothing is downloading, so the app cannot wake
//  itself up at the start time. The start is therefore also done:
//   - whenever the app becomes active inside the window (catch-up),
//   - by the "Start Scheduled Torrents" Shortcuts action (for a Time of Day
//     automation),
//   - after tapping the reminder notification posted at the start time.
//

import Combine
import Foundation
import LibTorrent
import UIKit
#if os(iOS)
import UserNotifications
#endif

extension TorrentService {
    static let scheduleNotificationIdentifier = "schedule.start"

    func setupSchedule() {
        disposeBag.bind {
            Timer.publish(every: 30, on: .main, in: .common)
                .autoconnect()
                .sink { [unowned self] _ in
                    checkSchedule()
                }

            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .receive(on: DispatchQueue.main)
                .sink { [unowned self] _ in
                    checkSchedule()
                }

            // Turning the schedule on or changing the times should not pause or
            // start anything right away: events start counting from now.
            preferences.$isScheduleEnabled
                .combineLatest(preferences.$scheduleStartMinutes, preferences.$scheduleStopMinutes)
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [unowned self] _ in
                    let now = Date()
                    preferences.scheduleHandledStart = now
                    preferences.scheduleHandledStop = now
                    updateScheduleNotification()
                }
        }

        updateScheduleNotification()
        checkSchedule()
    }

    /// Runs any start/stop event that is due and has not been handled yet.
    func checkSchedule(now: Date = Date()) {
        guard preferences.isScheduleEnabled else { return }

        let lastStart = Self.lastOccurrence(ofMinutes: preferences.scheduleStartMinutes, before: now)
        let lastStop = Self.lastOccurrence(ofMinutes: preferences.scheduleStopMinutes, before: now)
        guard lastStart != lastStop else { return } // start == stop: nothing to do

        if lastStart > lastStop {
            // Inside the window.
            if (preferences.scheduleHandledStart ?? .distantPast) < lastStart {
                preferences.scheduleHandledStart = now
                runScheduledStart()
            }
        } else {
            // Outside the window.
            if (preferences.scheduleHandledStop ?? .distantPast) < lastStop {
                preferences.scheduleHandledStop = now
                runScheduledStop()
            }
        }
    }

    /// Starts every paused torrent that is not finished, in queue order.
    /// Also used by the "Start Scheduled Torrents" Shortcuts action.
    func runScheduledStart() {
        let savedOrder = preferences.scheduleSavedOrder
        let rank = Dictionary(savedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        let handles = torrents.values
            .filter { handle in
                let snapshot = handle.snapshot
                return snapshot.isValid && snapshot.isPaused && snapshot.needsDownload && !snapshot.isStorageMissing
            }
            .sorted { first, second in
                let firstRank = rank[first.snapshot.infoHashes.best.hex] ?? Int.max
                let secondRank = rank[second.snapshot.infoHashes.best.hex] ?? Int.max
                if firstRank != secondRank { return firstRank < secondRank }
                return first.metadata.dateAdded < second.metadata.dateAdded
            }

        print("[Schedule] Start time: starting \(handles.count) torrents")
        start(handles)
        removeDeliveredScheduleNotification()
    }

    /// Pauses every running torrent (downloading and seeding).
    func runScheduledStop() {
        // Remember the queue order (running downloads and queued ones) for the next start.
        preferences.scheduleSavedOrder = TorrentQueue.shared.order

        let handles = torrents.values.filter { handle in
            let snapshot = handle.snapshot
            return !snapshot.isPaused || snapshot.isQueued
        }
        print("[Schedule] Stop time: pausing \(handles.count) torrents")
        pause(Array(handles))
    }
}

// MARK: - Time helpers
extension TorrentService {
    /// "HH:mm" for minutes since midnight.
    static func scheduleTimeString(_ minutes: Int) -> String {
        let value = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// Minutes since midnight from "HH:mm" (also accepts "H", "HHmm", "H.mm").
    static func scheduleMinutes(from text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(whereSeparator: { ":.,- ".contains($0) })
        let hours: Int
        let minutes: Int
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
            hours = h; minutes = m
        } else if parts.count == 1, let value = Int(parts[0]) {
            if cleaned.count <= 2 { hours = value; minutes = 0 }
            else { hours = value / 100; minutes = value % 100 }
        } else {
            return nil
        }
        guard (0 ... 23).contains(hours), (0 ... 59).contains(minutes) else { return nil }
        return hours * 60 + minutes
    }

    /// The most recent moment (today or yesterday) at the given local time that is <= now.
    static func lastOccurrence(ofMinutes minutes: Int, before now: Date) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let today = calendar.date(byAdding: .minute, value: minutes, to: startOfDay) ?? startOfDay
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }
}

// MARK: - Reminder notification
private extension TorrentService {
    /// Daily notification at the start time, in case the app is asleep then.
    func updateScheduleNotification() {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.scheduleNotificationIdentifier])
        guard preferences.isScheduleEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "schedule.notification.title", defaultValue: "Scheduled downloads")
        content.body = String(localized: "schedule.notification.body", defaultValue: "It's download time. Tap to start your paused torrents.")
        content.sound = nil

        let minutes = preferences.scheduleStartMinutes
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: Self.scheduleNotificationIdentifier, content: content, trigger: trigger))
        #endif
    }

    /// The app handled the start itself, so the reminder is not needed.
    func removeDeliveredScheduleNotification() {
        #if os(iOS)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.scheduleNotificationIdentifier])
        #endif
    }
}
