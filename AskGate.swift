//
//  AskGate.swift
//  Eye~Helpi
//
//  The permission engine: Eye~Helpi gains access to device controls by
//  asking its secondary user through the user's preferred output channel:
//  audio (it asks out loud), display (an on-screen Approve/Deny card) or
//  both. Grants can be one-time or "always" per action category.
//

import Foundation
import SwiftUI

/// How Eye~Helpi asks for permission — the user's preference.
enum AskChannel: String, CaseIterable, Codable, Identifiable {
    case audio
    case display
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audio: return "Audio — it asks me out loud"
        case .display: return "Display — it asks on my screen"
        case .both: return "Both — spoken and on-screen"
        }
    }
}

/// A single pending permission request.
struct AskCard: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let category: String
    var isApproved: Bool?
}