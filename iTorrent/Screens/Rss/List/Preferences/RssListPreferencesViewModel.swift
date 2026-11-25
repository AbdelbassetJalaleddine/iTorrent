//
//  RssListPreferencesViewModel.swift
//  iTorrent
//
//  Created by Даниил Виноградов on 10.04.2024.
//

import MvvmFoundation
import Combine
import UIKit

class RssListPreferencesViewModel: BaseCollectionViewModelWith<RssModel> {
    override func prepare(with model: RssModel) {
        var sections: [MvvmCollectionSectionModel] = []
        defer { self.sections = sections }

        sections.append(.init(id: "prefs", style: .plain) {
            PRButtonViewModel(with: .init(title: %"rsslist.preference.url", value: Just(model.xmlLink.absoluteString).eraseToAnyPublisher(), tinted: false, singleLine: true, selectAction: { [unowned self] in
                UIPasteboard.general.string = model.xmlLink.absoluteString
                alertWithTimer(title: %"rsslist.preference.urlCopy")
                dismissSelection.send()
            }))
            PRButtonViewModel(with: .init(title: %"rsslist.preference.name", value: model.displayTitle, singleLine: true, selectAction: { [unowned self] in
                textInput(title: %"rsslist.preference.name", placeholder: model.title, defaultValue: model.customTitle) { [unowned self] res in
                    dismissSelection.send()
                    guard let res else { return }
                    model.customTitle = res
                }
            }))
            PRButtonViewModel(with: .init(title: %"rsslist.preference.description", value: model.displayDescription, singleLine: true, selectAction: { [unowned self] in
                textInput(title: %"rsslist.preference.description", placeholder: model.description, defaultValue: model.customDescription) { [unowned self] res in
                    dismissSelection.send()
                    guard let res else { return }
                    model.customDescription = res
                }
            }))
            PRSwitchViewModel(with: .init(title: %"rsslist.preference.notifications", value: .init(get: {
                !model.muteNotifications
            }, set: { value in
                model.muteNotifications = !value
            })))
        })

        let autoDownloader = RssAutoDownloader.shared
        let anyText = String(localized: "rsslist.autoDownload.any", defaultValue: "Any")
        let noneText = String(localized: "rsslist.autoDownload.none", defaultValue: "None")
        let wordsHint = String(localized: "rsslist.autoDownload.wordsHint", defaultValue: "Words separated by spaces or commas. Not case sensitive.")
        let mustContainTitle = String(localized: "rsslist.autoDownload.mustContain", defaultValue: "Must Contain")
        let mustNotContainTitle = String(localized: "rsslist.autoDownload.mustNotContain", defaultValue: "Must Not Contain")

        sections.append(.init(id: "autoDownload",
                              header: String(localized: "rsslist.autoDownload", defaultValue: "Auto-download"),
                              footer: String(localized: "rsslist.autoDownload.footer", defaultValue: "New items that match are added as paused torrents. They start at your schedule's start time, or when you start them. Items already in the feed when you turn this on are skipped. Must Contain: the title needs all of the words. Must Not Contain: the title can't have any of them."),
                              style: .plain)
        {
            PRSwitchViewModel(with: .init(title: String(localized: "rsslist.autoDownload.enabled", defaultValue: "Auto-add New Torrents"), value: .init(get: {
                autoDownloader.rule(for: model).isEnabled
            }, set: { value in
                autoDownloader.setEnabled(value, for: model)
            })))
            PRButtonViewModel(with: .init(title: mustContainTitle, value: autoDownloader.rulePublisher(for: model).map { $0.mustContain.isEmpty ? anyText : $0.mustContain }.eraseToAnyPublisher(), singleLine: true, selectAction: { [unowned self] in
                textInput(title: mustContainTitle, message: wordsHint, placeholder: "1080p", defaultValue: autoDownloader.rule(for: model).mustContain) { [unowned self] res in
                    dismissSelection.send()
                    guard let res else { return }
                    autoDownloader.setMustContain(res, for: model)
                }
            }))
            PRButtonViewModel(with: .init(title: mustNotContainTitle, value: autoDownloader.rulePublisher(for: model).map { $0.mustNotContain.isEmpty ? noneText : $0.mustNotContain }.eraseToAnyPublisher(), singleLine: true, selectAction: { [unowned self] in
                textInput(title: mustNotContainTitle, message: wordsHint, placeholder: "CAM", defaultValue: autoDownloader.rule(for: model).mustNotContain) { [unowned self] res in
                    dismissSelection.send()
                    guard let res else { return }
                    autoDownloader.setMustNotContain(res, for: model)
                }
            }))
        })
    }
}
