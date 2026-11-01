//
//  PredictiveEngine.swift
//  Eye~Helpi
//
//  The intuitive layer: learns the user's rhythms (when they check scenes,
//  scan documents, chat) and predicts their needs. It can also take
//  preventative action WITHOUT asking — but only inside a one-time
//  permission grant ("Autonomous mode"), and only for clearly helpful,
//  reversible, low-risk actions (e.g. easing off when the battery is low
//  to protect the device).
//

import Foundation
import UIKit

@MainActor
final class PredictiveEngine: NSObject, ObservableObject {

    static let shared = PredictiveEngine()

    @Published var suggestions: [PredictiveSuggestion] = []

    /// The one-time permission grant. Once on, Eye~Helpi acts on the user's
    /// behalf for safe, beneficial actions only.
    @Published var autoPilotEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoPilotEnabled, forKey: "eyehelpi.autopilot")
        }
    }

    struct PredictiveSuggestion: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let isAutoActed: Bool
    }

    enum UsageEvent: String {
        case sceneAnalysis, documentScan, chatMessage, voiceCommand
    }

    private static let usageKey = "eyehelpi.usage.rhythms"

    private var batteryLevel: Double {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? 1.0 : Double(level)
    }

    private var batteryPluggedIn: Bool {
        return UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }

    override init() {
        autoPilotEnabled = UserDefaults.standard.bool(forKey: "eyehelpi.autopilot")
        checkInsEnabled = UserDefaults.standard.bool(forKey: "eyehelpi.checkIns")
        super.init()
        refresh()
    }

    // MARK: - Learning rhythms

    func recordUsage(_ event: UsageEvent) {
        var events = Self.loadUsage()
        events.append([
            "hour": Calendar.current.component(.hour, from: Date()),
            "event": event.rawValue.hashValue,
        ])
        if events.count > 400 {
            events.removeFirst(events.count - 400)
        }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: Self.usageKey)
        }
    }

    private static func loadUsage() -> [[String: Int]] {
        guard let data = UserDefaults.standard.data(forKey: usageKey),
              let events = try? JSONDecoder().decode([[String: Int]].self, from: data) else {
            return []
        }
        return events
    }

    /// The hour the user most often uses Eye~Helpi — their predictive rhythm.
    var preferredHour: Int? {
        let events = Self.loadUsage()
        guard events.count >= 5 else { return nil }
        var histogram: [Int: Int] = [:]
        for event in events {
            histogram[event["hour"] ?? -1, default: 0] += 1
        }
        return histogram.max { $0.value < $1.value }?.key
    }

    // MARK: - Predictive refresh

    func refresh() {
        var suggestions: [PredictiveSuggestion] = []

        // Preventative: protect the device when the battery runs low.
        let level = batteryLevel
        if level <= 0.20, !batteryPluggedIn {
            let acted = autoPilotEnabled
            if acted {
                NotificationCenter.default.post(name: .init("eyehelpi.pauseExtras"), object: nil)
            }
            suggestions.append(PredictiveSuggestion(
                title: acted
                    ? "Battery low — I eased off to protect it"
                    : "Battery low — grant Autonomous mode and I'll ease off for you",
                detail: String(
                    format: "At %.0f%% I pause Live watch and voice listening (they resume on recharge). Nothing is lost — it's all reversible.",
                    level * 100
                ),
                isAutoActed: acted
            ))
        }

        // Predictive: greet at the user's rhythm.
        if let hour = preferredHour,
           Calendar.current.component(.hour, from: Date()) == hour {
            suggestions.append(PredictiveSuggestion(
                title: "Right on schedule",
                detail: "This is usually when you check in with me — the camera is warm and ready.",
                isAutoActed: false
            ))
        }

        self.suggestions = suggestions
    }

    /// Context injected into AI prompts so replies anticipate the moment.
    var contextLine: String {
        let hour = Calendar.current.component(.hour, from: Date())
        var parts: [String] = []
        parts.append(String(format: "device battery %.0f%%", batteryLevel * 100))
        if let preferred = preferredHour {
            parts.append("user usually checks in around \(preferred):00")
        }
        parts.append("current hour \(hour)")
        return "(context: " + parts.joined(separator: "; ") + ")"
    }

    // MARK: - Timed proactive check-in

    /// A one-time-a-day spoken greeting, delivered near the hour the user
    /// most often checks in.
    struct ProactiveCheckIn: Identifiable {
        let id = UUID()
        let message: String
    }

    /// The toggle shown in Device Hub.
    @Published var checkInsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(checkInsEnabled, forKey: "eyehelpi.checkIns")
        }
    }

    /// The check-in currently on screen (nil once dismissed).
    @Published private(set) var pendingCheckIn: ProactiveCheckIn?

    private static let checkInDeliveredKey = "eyehelpi.checkIn.delivered.day"

    /// True when the current hour is within one of the user's usual
    /// check-in hour.
    private var isNearPreferredHour: Bool {
        guard let hour = preferredHour else { return false }
        let now = Calendar.current.component(.hour, from: Date())
        let difference = ((now - hour + 12) % 24)
        return min(difference, 24 - difference) <= 1
    }

    /// Called on foregrounding and each minute while active. Delivers the
    /// greeting at most once a day, only when voice is enabled; the card is
    /// dismissible.
    func considerCheckIn() {
        guard checkInsEnabled,
              pendingCheckIn == nil,
              EyeVoice.shared.isEnabled,
              isNearPreferredHour else { return }
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: Self.checkInDeliveredKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.checkInDeliveredKey)
        let message = "Just checking in, my person — this is usually when we catch up. Anything you need?"
        EyeVoice.shared.speak(message)
        pendingCheckIn = ProactiveCheckIn(message: message)
    }

    func dismissCheckIn() {
        pendingCheckIn = nil
    }
}