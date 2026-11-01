//
//  HomeKitStatus.swift
//  Eye~Helpi
//
//  Read-only HomeKit bridge: surfaces the user's homes and accessory power
//  states so Eye~Helpi can answer "what's on at home right now?". Nothing is
//  ever controlled - this is observation only. Simulator shows no homes;
//  this comes alive on the real iPhone.
//

import Foundation
import HomeKit

@MainActor
final class HomeKitStatus: NSObject, ObservableObject, HMHomeManagerDelegate {

    @Published var authorizationDenied = false
    @Published var homes: [HomeSummary] = []

    struct HomeSummary: Identifiable {
        let id: UUID
        let name: String
        let accessoryCount: Int
        let poweredOn: Int
    }

    // Created lazily: HMHomeManager starts HomeKit work the moment it exists,
    // so it must not be allocated while the app is launching. The delegate is
    // wired here so no update can arrive before the manager exists.
    private lazy var manager: HMHomeManager = {
        let manager = HMHomeManager()
        manager.delegate = self
        return manager
    }()

    func refresh() {
        guard manager.authorizationStatus == .authorized else {
            authorizationDenied = manager.authorizationStatus == .restricted
            homes = []
            return
        }
        authorizationDenied = false
        homes = manager.homes.map { home in
            let powerStates = home.accessories.compactMap { accessory in
                accessory.services
                    .flatMap { $0.characteristics }
                    .first { $0.characteristicType == HMCharacteristicTypePowerState }
            }.compactMap { $0.value as? Bool }
            return HomeSummary(
                id: home.uniqueIdentifier,
                name: home.name,
                accessoryCount: home.accessories.count,
                poweredOn: powerStates.filter { $0 }.count
            )
        }
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.refresh() }
    }
}