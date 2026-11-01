//
//  UplinkEngine.swift
//  Eye~Helpi
//
//  The Opportunistic Uplink Engine: Eye~Helpi's independent network layer.
//  A Network.framework path monitor watches for any valid path - Wi-Fi,
//  cellular, even the peer-to-peer beams BeamHub rides on - and whenever one
//  appears, queued state updates and vector embeddings drain to the
//  companion desktop agent (eye_helpi_agent, "python main.py serve") over
//  the engine's own URLSession. Nothing in the sync path touches the main
//  thread: batching, encoding and uploading all run off it, and the UI just
//  observes the published status chip.
//
//  Memory efficiency first:
//  - the outbound queue lives on disk, not in RAM, and is hard-capped
//    (oldest items drop first past the cap)
//  - uploads go out in small chunks, so at most one batch is ever in memory
//  - a delivered chunk is released the moment its request returns
//

import Combine
import Foundation
import Network
import SwiftUI

// MARK: - Queue items

/// One outbound item: a device state update or a vector embedding.
struct UplinkItem: Codable, Identifiable {
    enum Kind: String, Codable {
        case stateUpdate
        case vectorEmbedding
    }

    let id: UUID
    let kind: Kind
    let createdAt: Date
    let payload: [String: String]
    let vector: [Float]?

    init(kind: Kind, payload: [String: String], vector: [Float]? = nil) {
        id = UUID()
        self.kind = kind
        createdAt = Date()
        self.payload = payload
        self.vector = vector
    }
}

private struct UplinkBatch: Codable {
    let items: [UplinkItem]
}

// MARK: - Bounded disk queue

/// The uplink's memory-light outbound storage. All access is serialized on
/// a private queue and the file is rewritten atomically on every change, so
/// RAM never holds more than the chunk currently being sent.
final class UplinkStore: @unchecked Sendable {

    /// Hard cap: past this the oldest items drop. Keeps the queue, its file
    /// and the uplink's RAM footprint bounded forever.
    static let maxItems = 60

    /// How many items ride in one upload request ("chunked uploads").
    static let chunkSize = 8

    private let queue = DispatchQueue(label: "eyehelpi.uplink.store")
    private var items: [UplinkItem] = []
    private let fileURL: URL

    init() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uplink", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("queue.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([UplinkItem].self, from: data) {
            items = loaded
        }
    }

    var count: Int { queue.sync { items.count } }
    var isEmpty: Bool { queue.sync { items.isEmpty } }

    func append(_ item: UplinkItem) {
        queue.sync {
            items.append(item)
            if items.count > Self.maxItems {
                items.removeFirst(items.count - Self.maxItems)
            }
            persistLocked()
        }
    }

    /// The next chunk to send, or nil when the queue is fully drained.
    func nextChunk() -> [UplinkItem]? {
        queue.sync {
            items.isEmpty ? nil : Array(items.prefix(Self.chunkSize))
        }
    }

    /// Releases a delivered chunk and its payload for good.
    func remove(_ chunk: [UplinkItem]) {
        queue.sync {
            let delivered = Set(chunk.map(\.id))
            items.removeAll { delivered.contains($0.id) }
            persistLocked()
        }
    }

    /// Callers must hold `queue`.
    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Transport (never touches the main thread)

private enum UplinkTransport {

    /// The engine's own sockets: a session dedicated to uplink traffic,
    /// independent of the chat and cloud-fallback sessions, so background
    /// sync never contends with user-facing calls. It dials on its own terms
    /// whenever a valid path exists and fails fast when none does.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// The companion agent's uplink sink (main.py serve, default port 8765).
    static var endpoint: URL {
        var trimmed = AgentConfig.uplinkHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if !trimmed.isEmpty, !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: trimmed + "/api/uplink")
            ?? URL(string: AgentConfig.defaultUplinkHost + "/api/uplink")!
    }

    /// Sends one chunk. Throws when the companion agent did not confirm
    /// receipt; the caller keeps the chunk queued in that case.
    static func upload(_ chunk: [UplinkItem]) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The agent gates its routes behind its web token; the phone presents
        // the same BLAXDEV key when one is stored.
        if let apiKey = ApiKeyManager.shared.get(key: "BLAXDEV_API_KEY") {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(UplinkBatch(items: chunk))

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Delivered: the encoded chunk and its payload are released here.
    }
}

// MARK: - Engine

final class UplinkEngine: ObservableObject {

    static let shared = UplinkEngine()

    enum Status: Equatable {
        case offline   // no valid path right now
        case ready     // path up, nothing queued yet
        case syncing   // a chunk is in flight
        case synced    // last drain finished clean
    }

    @Published private(set) var status: Status = .offline
    @Published private(set) var queuedCount = 0
    @Published private(set) var lastSyncedAt: Date?

    private var monitor: NWPathMonitor?
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pathSatisfied = false
    private let store = UplinkStore()

    private init() {}

    /// Starts watching for valid paths. Call once at app launch.
    func start() {
        guard monitor == nil else { return }
        // The default monitor evaluates every interface, including the
        // peer-to-peer ones (Bluetooth / Wi-Fi Direct / AWDL) that BeamHub
        // rides on - those show up as `usesInterfaceType(.other)` and are
        // accepted below as valid uplink paths.
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] (path: NWPath) in
            let satisfied = path.status == .satisfied || path.usesInterfaceType(.other)
            Task { @MainActor in self?.pathChanged(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "eyehelpi.uplink.monitor"))
        queuedCount = store.count
    }

    // MARK: Producers (main thread only - they only touch published state)

    /// Queues a state update for the next uplink window. Cheap and
    /// non-blocking: the item lands straight on bounded disk storage.
    func enqueueState(_ payload: [String: String]) {
        store.append(UplinkItem(kind: .stateUpdate, payload: payload))
        syncUpWithQueue()
    }

    /// Queues a vector embedding (text plus its float vector).
    func enqueueEmbedding(text: String, vector: [Float]) {
        store.append(
            UplinkItem(kind: .vectorEmbedding, payload: ["text": text], vector: vector)
        )
        syncUpWithQueue()
    }

    private func syncUpWithQueue() {
        queuedCount = store.count
        guard pathSatisfied else {
            status = .offline
            return
        }
        if syncTask == nil {
            startSync()
        }
    }

    // MARK: Path changes

    private func pathChanged(_ satisfied: Bool) {
        pathSatisfied = satisfied
        if !satisfied {
            syncTask?.cancel()
            syncTask = nil
            retryTask?.cancel()
            retryTask = nil
            status = .offline
        } else if syncTask == nil {
            startSync()
        }
    }

    // MARK: Draining (all off the main thread)

    private func startSync() {
        retryTask?.cancel()
        retryTask = nil
        guard !store.isEmpty else {
            status = .ready
            return
        }
        status = .syncing
        syncTask = Task(priority: .utility) { [weak self] in
            await self?.drainQueue()
        }
    }

    /// Drains the queue chunk by chunk. Runs inside a utility task - the
    /// only main-thread visits are the tiny published-state updates.
    private func drainQueue() async {
        let store = self.store

        while !Task.isCancelled {
            guard let chunk = store.nextChunk() else { break }
            do {
                try await UplinkTransport.upload(chunk)
                store.remove(chunk)
                let remaining = store.count
                let now = Date()
                await MainActor.run { [weak self] in
                    self?.queuedCount = remaining
                    self?.lastSyncedAt = now
                    self?.status = remaining > 0 ? .syncing : .synced
                }
            } catch {
                // The agent is unreachable or the path dropped mid-drain:
                // everything stays queued for the next valid path.
                await MainActor.run { [weak self] in
                    self?.status = self?.pathSatisfied == true ? .ready : .offline
                    self?.scheduleRetry()
                }
                return
            }
        }

        await MainActor.run { [weak self] in
            self?.syncTask = nil
            if self?.pathSatisfied == true, store.isEmpty {
                self?.status = .synced
            }
        }
    }

    /// A quiet backoff retry while the path is up but the agent is down, so
    /// a drained-then-restored agent reconnects without user action.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await MainActor.run { [weak self] in
                self?.retryIfIdle()
            }
        }
    }

    private func retryIfIdle() {
        guard pathSatisfied, syncTask == nil, !store.isEmpty else { return }
        startSync()
    }
}

// MARK: - Status chip

/// The small always-visible chip: UPLINK: OFFLINE / READY / SYNCING / SYNCED.
struct UplinkStatusChip: View {

    @ObservedObject private var uplink = UplinkEngine.shared

    var body: some View {
        StatusChip(text: text, color: color)
    }

    private var text: String {
        switch uplink.status {
        case .offline:
            return "uplink: offline"
        case .ready:
            return uplink.queuedCount > 0 ? "uplink: queued \(uplink.queuedCount)" : "uplink: ready"
        case .syncing:
            return "uplink: syncing · \(uplink.queuedCount)"
        case .synced:
            return "uplink: synced"
        }
    }

    private var color: Color {
        switch uplink.status {
        case .offline: return .secondary
        case .ready: return .orange
        case .syncing: return EyeTheme.accent
        case .synced: return .green
        }
    }
}