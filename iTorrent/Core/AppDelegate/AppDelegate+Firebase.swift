//
//  AppDelegate+Firebase.swift
//  iTorrent
//
//  Created by Даниил Виноградов on 20.04.2024.
//

import Foundation
#if canImport(FirebaseCore) && !NO_FIREBASE
import FirebaseCore
#endif

extension AppDelegate {
    func registerFirebase() {
#if canImport(FirebaseCore) && !NO_FIREBASE
        FirebaseApp.configure()
#endif
    }
}
