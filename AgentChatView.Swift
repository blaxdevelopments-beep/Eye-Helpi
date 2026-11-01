//
//  AgentChatView.swift
//  Eye~Helpi
//
//  The chat companion for the local Eye~Helpi Python agent: it sends typed
//  commands straight to the same Ollama chat endpoint main.py uses, so the
//  phone can talk to Eye~Helpi while the desktop agent keeps running its
//  device-control tools. Conversation memory persists across launches,
//  replies can be spoken (en-AU), and a HUD chip shows which brain answered.
//

import PhotosUI
import SwiftUI

/// How the live brain-status chip in the Chat toolbar reads right now.
enum BrainStatus {
    case ollama     // the local Ollama host answered - green
    case cloudOnly  // host down, but the OpenAI fallback answers - orange
    case offline    // nothing usable right now - grey
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String
    var text: String

    init(role: String, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Older saves carry no id; keep decoding them (they get a fresh one).
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The id is written so starred messages survive across launches.
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
    }
}

@MainActor
final class AgentChatModel: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isThinking = false
    @Published var connectionNote = ""
    @Published var brain = ""
    @Published var brainStatus: BrainStatus = .offline
    @Published var searchText = ""
    @Published var attachedImage: UIImage?
    @Published private(set) var starredIDs: Set<UUID> = Set(AgentChatModel.loadStarredIDs())
    @Published private(set) var otherMatches: [ConversationMatchGroup] = []
    /// The message to center when the results list next renders (set when
    /// jumping into a match in another conversation).
    @Published var jumpTarget: ChatMessage.ID?

    /// The conversation the screen is currently showing.
    private(set) var conversation: Conversation

    private var assistantIndex: Int?
    private var streamTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?

    /// Kept so a single conversation still can't grow unbounded.
    private static let historyLimit = 10_000

    init() {
        // The Chat tab opens the most recently active conversation,
        // migrating the pre-multi-conversation history on first run.
        conversation = ConversationArchive.shared.mostRecent()
            ?? ConversationArchive.shared.newConversation()
        messages = Array(conversation.messages.suffix(Self.historyLimit))
        if messages.isEmpty {
            messages = [ChatMessage(role: "assistant", text: AgentConfig.greeting)]
        }
    }

    // MARK: - Memory

    /// Opens another conversation in this screen. Streaming state is torn
    /// down cleanly first. `keepingQuery` keeps the search active so a jump
    /// from another conversation's results lands on the matched message.
    func load(conversation newConversation: Conversation, keepingQuery: Bool = false) {
        streamTask?.cancel()
        streamTask = nil
        assistantIndex = nil
        isThinking = false
        connectionNote = ""
        brain = ""
        if !keepingQuery {
            searchText = ""
        }
        attachedImage = nil
        conversation = newConversation
        messages = Array(newConversation.messages.suffix(Self.historyLimit))
        if messages.isEmpty {
            messages = [ChatMessage(role: "assistant", text: AgentConfig.greeting)]
        }
        sweepOtherConversations()
    }

    /// Starts a fresh conversation and opens it.
    func newConversation() {
        load(conversation: ConversationArchive.shared.newConversation())
    }

    private func saveHistory() {
        conversation.messages = Array(messages.suffix(Self.historyLimit))
        conversation.updatedAt = Date()
        // Auto-name from the first user message so the list reads naturally.
        if conversation.name.isEmpty || conversation.name == "New chat",
           let first = messages.first(where: { $0.role == "user" }) {
            conversation.name = String(first.text.prefix(40))
        }
        ConversationArchive.shared.save(conversation)
    }

    func clearMemory() {
        streamTask?.cancel()
        streamTask = nil
        assistantIndex = nil
        messages = [ChatMessage(role: "assistant", text: AgentConfig.greeting)]
        connectionNote = ""
        brain = ""
        saveHistory()
    }

    // MARK: - Sending

    /// True when a send is possible: drafted text or an attached photo,
    /// and not mid-stream.
    var canSend: Bool {
        !isThinking && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil)
    }

    /// Sends the drafted text (or the default photo prompt, when a photo
    /// is attached) and streams the reply. A photo rides the same base64
    /// path the camera analysis uses.
    func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage
        let prompt = image != nil && typed.isEmpty
            ? "What do you see in this picture?"
            : typed
        guard !prompt.isEmpty, !isThinking else { return }

        draft = ""
        attachedImage = nil
        connectionNote = ""
        messages.append(ChatMessage(role: "user", text: prompt))
        messages.append(ChatMessage(role: "assistant", text: ""))
        assistantIndex = messages.count - 1
        isThinking = true
        PredictiveEngine.shared.recordUsage(.chatMessage)
        saveHistory()

        // History for the model: persona + predictive context, then everything
        // except the empty assistant placeholder we are streaming into.
        var history: [OllamaMessage] =
            [OllamaMessage(role: "system", content: AgentConfig.persona + "\n" + PredictiveEngine.shared.contextLine)]
            + messages.dropLast().map { OllamaMessage(role: $0.role, content: $0.text) }

        // Attach the photo to the user turn being sent.
        if let image, let base64 = image.jpegBase64() {
            history[history.count - 1] = OllamaMessage(
                role: "user",
                content: prompt,
                images: [base64]
            )
        }

        let service = AgentService(host: AgentConfig.host)

        streamTask?.cancel()
        streamTask = Task {
            do {
                let reply = try await service.streamChat(
                    messages: history,
                    onDelta: { delta in
                        self.appendToAssistant(delta)
                    },
                    onBrain: { value in
                        self.brain = value
                    }
                )
                if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    replaceAssistant("(no reply came back - is llama3.2-vision pulled?)")
                } else {
                    EyeVoice.shared.speak(reply)
                }
            } catch URLError.cancelled {
                // Superseded by a newer send.
            } catch is CancellationError {
                // Superseded by a newer send.
            } catch {
                replaceAssistant(
                    "I could not reach my brain at \(AgentConfig.host) (\(error.localizedDescription)). "
                    + "Make sure Ollama is running on your computer, pull the model with "
                    + "`ollama pull \(AgentConfig.modelName)`, and check the agent host in the Setup tab. "
                    + "With an OpenAI key set, I also fall back to the cloud when Ollama is unreachable."
                )
            }
            isThinking = false
            assistantIndex = nil
            saveHistory()
        }
    }

    // MARK: - Brain status

    /// Probes the local Ollama host first, then the OpenAI fallback, and
    /// reports the best brain that answered plus a human note for the
    /// manual check.
    private func evaluate() async -> (BrainStatus, String) {
        let service = AgentService(host: AgentConfig.host)
        do {
            let models = try await service.availableModels()
            let note = models.contains(AgentConfig.modelName)
                ? "Connected. \(AgentConfig.modelName) is ready."
                : "Connected, but \(AgentConfig.modelName) is not pulled yet - run `ollama pull \(AgentConfig.modelName)`."
            return (.ollama, note)
        } catch {
            guard let fallback = OpenAIFallbackService() else {
                return (.offline, "No answer from \(AgentConfig.host) (\(error.localizedDescription)). No OpenAI key set - add one in the Setup tab to use the cloud.")
            }
            do {
                let (valid, detail) = try await fallback.isKeyValid()
                if valid {
                    return (
                        .cloudOnly,
                        "Ollama at \(AgentConfig.host) is unreachable - I'm answering through the OpenAI cloud (\(OpenAIFallbackService.modelName)) instead."
                    )
                }
                return (.offline, "Ollama is unreachable and the OpenAI cloud refused us (\(detail ?? "key rejected")). Check the key or billing in the Setup tab.")
            } catch {
                return (.offline, "No answer from \(AgentConfig.host) and the cloud could not be reached either (\(error.localizedDescription)).")
            }
        }
    }

    /// One silent heartbeat tick: refreshes the toolbar chip only.
    func pollStatus() async {
        let (status, _) = await evaluate()
        brainStatus = status
    }

    /// Manual check from tapping the chip: refreshes the chip and shows the
    /// detailed connection note.
    func checkConnection() {
        connectionNote = "Checking..."
        Task {
            let (status, note) = await evaluate()
            brainStatus = status
            connectionNote = note
        }
    }

    /// Pings the brain every 30 seconds while the Chat screen is visible.
    func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task {
            while !Task.isCancelled {
                await pollStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    // MARK: - Search

    /// True while the search field holds a query, in which case the log
    /// shows only matching history instead of the full conversation.
    var isSearching: Bool {
        !Self.normalizedQuery(searchText).isEmpty
    }

    /// The saved messages whose text contains the query, case-insensitively,
    /// oldest first.
    var searchResults: [ChatMessage] {
        let query = Self.normalizedQuery(searchText)
        guard !query.isEmpty else { return [] }
        return messages.filter { $0.text.localizedStandardContains(query) }
    }

    /// Runs a search from the search field: blank means no query.
    private static func normalizedQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sweeps every other saved conversation for the query, off the main
    /// thread; the grouped results land in `otherMatches`.
    func sweepOtherConversations() {
        let query = Self.normalizedQuery(searchText)
        sweepTask?.cancel()
        guard !query.isEmpty else {
            otherMatches = []
            return
        }
        let excludedID = conversation.id
        sweepTask = Task.detached(priority: .userInitiated) { [weak self] in
            let groups = ConversationArchive.searchOtherConversations(query: query, excluding: excludedID)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, Self.normalizedQuery(searchText) == query else { return }
                otherMatches = groups
            }
        }
    }

    // MARK: - Stars

    private static let starredKey = "eyehelpi.chat.starred"

    private static func loadStarredIDs() -> [UUID] {
        guard let data = UserDefaults.standard.data(forKey: starredKey),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return ids
    }

    /// The current conversation's starred messages, oldest first.
    var starredMessages: [ChatMessage] {
        messages.filter { starredIDs.contains($0.id) }
    }

    /// Long-press on a bubble: stars it, or unstars it if already starred.
    func toggleStar(_ message: ChatMessage) {
        if starredIDs.contains(message.id) {
            starredIDs.remove(message.id)
        } else {
            starredIDs.insert(message.id)
        }
        persistStarredIDs()
    }

    private func persistStarredIDs() {
        guard let data = try? JSONEncoder().encode(Array(starredIDs)) else { return }
        UserDefaults.standard.set(data, forKey: Self.starredKey)
    }

    // MARK: - Export

    /// True when there is at least one non-empty message to export.
    var canExportTranscript: Bool {
        messages.contains { !$0.text.isEmpty }
    }

    /// Writes the whole conversation to a formatted text file and returns
    /// its URL, ready for the share sheet. Returns nil when there is
    /// nothing to export.
    func makeTranscriptFile() -> URL? {
        guard canExportTranscript else { return nil }
        let lines = messages.map { message -> String in
            let speaker = message.role == "assistant" ? "Eye~Helpi" : "Me"
            return "\(speaker): \(message.text)"
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let described = DateFormatter()
        described.dateStyle = .long
        described.timeStyle = .short

        let header = "Eye~Helpi transcript — \(described.string(from: Date()))"
        let text = header + "\n\n" + lines.joined(separator: "\n\n")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Eye~Helpi transcript \(stamp.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return url
    }

    // MARK: - Streaming helpers

    private func appendToAssistant(_ delta: String) {
        guard let index = assistantIndex, messages.indices.contains(index) else { return }
        messages[index].text += delta
    }

    private func replaceAssistant(_ text: String) {
        guard let index = assistantIndex, messages.indices.contains(index) else { return }
        messages[index].text = text
    }
}

/// Where a push from the Chat screen can go.
enum ChatRoute: Hashable {
    case conversations
}

struct AgentChatView: View {

    @StateObject private var model = AgentChatModel()
    @ObservedObject private var voiceState = EyeVoice.shared
    @AppStorage("eyehelpi.deepThink") private var deepThink = false
    @FocusState private var inputFocused: Bool
    @State private var sharedTranscript: TranscriptExport?
    @State private var chatPath: [ChatRoute] = []
    @State private var pickerItem: PhotosPickerItem?
    @State private var starredOnly = false

    var body: some View {
        NavigationStack(path: $chatPath) {
            VStack(spacing: 0) {
                searchBar
                chatLog
                inputBar
            }
            .background(EyeTheme.background.ignoresSafeArea())
            .navigationTitle("Eye~Helpi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        chatPath.append(.conversations)
                    } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityLabel("Conversations")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.clearMemory()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        deepThink.toggle()
                    } label: {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(deepThink ? EyeTheme.accent : .secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        EyeVoice.shared.isEnabled.toggle()
                    } label: {
                        Image(systemName: voiceState.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportTranscript()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!model.canExportTranscript)
                    .accessibilityLabel("Export transcript")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.checkConnection()
                    } label: {
                        BrainStatusChip(status: model.brainStatus)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 4) {
                    if deepThink {
                        StatusChip(text: "deep think: gpt-4o cloud first", color: EyeTheme.accent)
                    }
                    if !model.brain.isEmpty {
                        StatusChip(
                            text: model.brain == "cloud"
                                ? "brain: gpt-4o-mini cloud"
                                : "brain: ollama llama3.2-vision",
                            color: model.brain == "cloud" ? EyeTheme.accent : .green
                        )
                    }
                    if !model.connectionNote.isEmpty {
                        Text(model.connectionNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.thinMaterial)
                    }
                }
            }
            // Drafts handed over from eyehelpi://chat?text=... deep links.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: Notification.Name("eyehelpi.incomingDraft")
                )
            ) { notification in
                if let text = notification.userInfo?["text"] as? String {
                    model.draft = text
                }
            }
            .onAppear(perform: model.startHeartbeat)
            .onDisappear(perform: model.stopHeartbeat)
            // A photo chosen from the library attaches to the next message.
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    model.attachedImage = image
                }
            }
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .conversations:
                    ConversationListView(
                        chat: model,
                        onSelect: { summary in
                            // Decode only the picked conversation, at the
                            // moment it is opened.
                            if let conversation = ConversationArchive.shared.conversation(withID: summary.id) {
                                model.load(conversation: conversation)
                            }
                            chatPath = []
                        },
                        onNew: {
                            model.newConversation()
                            chatPath = []
                        }
                    )
                }
            }
            .sheet(item: $sharedTranscript) { export in
                ShareSheet(items: [export.url])
                    .ignoresSafeArea()
            }
        }
    }

    /// Writes the conversation to a text file and opens the iOS share sheet.
    private func exportTranscript() {
        guard let url = model.makeTranscriptFile() else { return }
        sharedTranscript = TranscriptExport(url: url)
    }

    /// The query field that sits above the chat log. While it holds a
    /// query, the log below shows only matching history.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search past chats...", text: $model.searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if model.isSearching {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            // Starred-only view: shows just the replies worth keeping.
            Button {
                starredOnly.toggle()
                if starredOnly {
                    model.searchText = ""
                }
            } label: {
                Image(systemName: starredOnly ? "star.fill" : "star")
                    .foregroundStyle(starredOnly ? EyeTheme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(starredOnly ? "Show all messages" : "Show starred only")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(EyeTheme.surface))
        .overlay(Capsule().strokeBorder(EyeTheme.hairline))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var chatLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.isSearching {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.searchResults) { message in
                            MessageBubble(
                                message: message,
                                query: model.searchText,
                                starred: model.starredIDs.contains(message.id),
                                onStarToggle: { model.toggleStar(message) }
                            )
                            .id(message.id)
                        }
                        if model.searchResults.isEmpty, !model.otherMatches.isEmpty {
                            Text("No matches in this conversation — check the others below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        if !model.otherMatches.isEmpty {
                            HStack(spacing: 8) {
                                EyeSigil()
                                EyeTheme.hud("in other conversations")
                                Spacer()
                            }
                            .padding(.top, 8)
                            ForEach(model.otherMatches) { group in
                                OtherConversationCard(group: group, query: model.searchText) { messageID in
                                    // Open that conversation and center the match.
                                    if let conversation = ConversationArchive.shared.conversation(withID: group.id) {
                                        model.load(conversation: conversation, keepingQuery: true)
                                        model.jumpTarget = messageID
                                    }
                                }
                            }
                        }
                        if model.searchResults.isEmpty, model.otherMatches.isEmpty {
                            Text("No matches in the saved history.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding()
                } else if starredOnly {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.starredMessages) { message in
                            MessageBubble(
                                message: message,
                                starred: true,
                                onStarToggle: { model.toggleStar(message) }
                            )
                            .id(message.id)
                        }
                        if model.starredMessages.isEmpty {
                            Text("No starred messages yet — long-press a bubble to star it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding()
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageBubble(
                                message: message,
                                starred: model.starredIDs.contains(message.id),
                                onStarToggle: { model.toggleStar(message) }
                            )
                            .id(message.id)
                        }
                        if model.isThinking {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("thinking...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 12)
                        }
                    }
                    .padding()
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: model.messages) { _, _ in
                // Searching and the starred view pin the scroll position.
                guard !model.isSearching, !starredOnly else { return }
                if let last = model.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.searchText) { _, _ in
                // Sweep the other saved conversations for the same query.
                model.sweepOtherConversations()
                // Jump straight to the oldest match as the query changes.
                if let oldest = model.searchResults.first {
                    proxy.scrollTo(oldest.id, anchor: .top)
                }
            }
            .onChange(of: model.jumpTarget) { _, target in
                guard let target else { return }
                // Give the lazy list a beat to build the row, then center it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo(target, anchor: .center)
                }
                model.jumpTarget = nil
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            attachmentChip
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title2)
                        .foregroundStyle(EyeTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach a photo")

                TextField("Command Eye~Helpi...", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { model.send() }

                Button {
                    model.send()
                    inputFocused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!model.canSend)
            }
            .padding()
        }
    }

    /// The small thumbnail shown while a photo waits to be sent; tapping
    /// its x removes the attachment.
    @ViewBuilder private var attachmentChip: some View {
        if let image = model.attachedImage {
            HStack(spacing: 10) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            model.attachedImage = nil
                            pickerItem = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attached photo")
                    }
                    .offset(x: 4, y: -4)
                Text("Photo attached — Eye~Helpi will look at it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(EyeTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EyeTheme.hairline))
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}

private struct MessageBubble: View {

    let message: ChatMessage
    var query: String? = nil
    var starred: Bool = false
    var onStarToggle: (() -> Void)? = nil

    @AppStorage("eyehelpi.replySize") private var replySizeRaw = ReplyTextSize.standard.rawValue

    private var isFromEyeHelpi: Bool {
        message.role == "assistant"
    }

    @ViewBuilder private var bubbleText: some View {
        if let query, !query.isEmpty {
            HighlightedChatText(text: message.text.isEmpty ? " " : message.text, query: query)
        } else {
            Text(message.text.isEmpty ? " " : message.text)
        }
    }

    var body: some View {
        HStack {
            if !isFromEyeHelpi {
                Spacer(minLength: 40)
            }
            bubbleText
                .font(ReplyTextSize.font(for: replySizeRaw))
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isFromEyeHelpi ? EyeTheme.surface : EyeTheme.accent.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(EyeTheme.hairline)
                        )
                )
                .overlay(alignment: isFromEyeHelpi ? .topTrailing : .topLeading) {
                    if starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(EyeTheme.accent)
                            .shadow(color: EyeTheme.accent.opacity(0.8), radius: 3)
                            .offset(x: isFromEyeHelpi ? 4 : -4, y: -4)
                    }
                }
                .foregroundStyle(isFromEyeHelpi ? Color.primary : EyeTheme.accent)
                // Long-press stars the bubble (or unstars it).
                .onLongPressGesture {
                    onStarToggle?()
                }
            if isFromEyeHelpi {
                Spacer(minLength: 40)
            }
        }
    }
}

/// Message text with every case-insensitive occurrence of the search query
/// carrying a highlight.
private struct HighlightedChatText: View {

    let text: String
    let query: String

    @AppStorage("eyehelpi.replySize") private var replySizeRaw = ReplyTextSize.standard.rawValue

    var body: some View {
        Text(highlighted)
    }

    private var highlighted: AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        var searchStart = text.startIndex
        // Case-insensitive, diacritic-insensitive: the same matching the
        // filter uses (Foundation's localized-standard rules).
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        while searchStart <= text.endIndex,
              let range = text.range(of: query, options: options, range: searchStart..<text.endIndex) {
            if cursor < range.lowerBound {
                result += AttributedString(String(text[cursor..<range.lowerBound]))
            }
            var match = AttributedString(String(text[range]))
            match.backgroundColor = EyeTheme.accent.opacity(0.35)
            // Matches stay semibold at the chosen reading size.
            match.font = ReplyTextSize.font(for: replySizeRaw).weight(.semibold)
            result += match
            cursor = range.upperBound
            searchStart = range.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }
        return result
    }
}

// MARK: - Conversations (storage)

/// One named conversation with the assistant, with its own message history.
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(id: UUID = UUID(),
         name: String = "New chat",
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         messages: [ChatMessage] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

/// Multi-conversation storage: every chat with Eye~Helpi lives as its own
/// JSON file in Application Support/Conversations, written atomically on
/// every change, so conversations persist independently of each other. A
/// small summary index backs the list screen and launch, so neither ever
/// decodes full message histories — launch reads only the one file it
/// opens. The pre-multi-conversation history in UserDefaults is migrated
/// into a conversation file on first run.
@MainActor
final class ConversationArchive {

    static let shared = ConversationArchive()

    private let directory: URL
    private let indexURL: URL
    private static let legacyHistoryKey = "eyehelpi.chat.history"
    private static let migratedKey = "eyehelpi.chat.migrated"

    /// Cached summaries; nil until first use.
    private var summaries: [ConversationSummary]?

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        indexURL = base.appendingPathComponent("index.json")
    }

    // MARK: Reading

    /// Lightweight entries for the list screen, most recently active first.
    /// Reads the summary index — never the full message histories.
    func allSummaries() -> [ConversationSummary] {
        migrateLegacyHistory()
        return loadSummaries().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The conversation the Chat tab should open. Decodes only the one file
    /// it actually opens, so launch stays fast no matter how many
    /// conversations exist.
    func mostRecent() -> Conversation? {
        migrateLegacyHistory()
        guard let newest = loadSummaries().max(by: { $0.updatedAt < $1.updatedAt }) else {
            return nil
        }
        return decode(newest.id)
    }

    /// Loads one conversation in full, at the moment it is opened.
    func conversation(withID id: UUID) -> Conversation? {
        decode(id)
    }

    // MARK: Writing

    /// A fresh empty conversation, persisted immediately so it appears in
    /// the list.
    func newConversation() -> Conversation {
        let conversation = Conversation()
        save(conversation)
        return conversation
    }

    func save(_ conversation: Conversation) {
        guard let data = try? JSONEncoder().encode(conversation) else { return }
        try? data.write(to: fileURL(for: conversation.id), options: .atomic)
        // Keep the summary index in step so the list never decodes bodies.
        var list = loadSummaries()
        let entry = summary(of: conversation)
        list.removeAll { $0.id == entry.id }
        list.append(entry)
        summaries = list
        if let indexData = try? JSONEncoder().encode(list) {
            try? indexData.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: Internals

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func decode(_ id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(Conversation.self, from: data)
    }

    private func loadSummaries() -> [ConversationSummary] {
        if let summaries { return summaries }
        let loaded: [ConversationSummary]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([ConversationSummary].self, from: data),
           indexCoversFiles(decoded) {
            loaded = decoded
        } else {
            // First run (or a missing index): one rebuild pass over files.
            loaded = rebuildSummaries()
        }
        summaries = loaded
        return loaded
    }

    /// True when every conversation file on disk has a matching entry.
    private func indexCoversFiles(_ summaries: [ConversationSummary]) -> Bool {
        Set(fileIDsOnDisk()) == Set(summaries.map(\.id))
    }

    private func fileIDsOnDisk() -> [UUID] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }

    /// The slow path, used once when there is no usable index yet.
    private func rebuildSummaries() -> [ConversationSummary] {
        fileIDsOnDisk()
            .compactMap { id in decode(id).map { summary(of: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func summary(of conversation: Conversation) -> ConversationSummary {
        let preview = conversation.messages.last { !$0.text.isEmpty }
            .map { message in
                let speaker = message.role == "assistant" ? "Eye~Helpi" : "Me"
                return "\(speaker): \(message.text)"
            } ?? "No messages yet"
        return ConversationSummary(
            id: conversation.id,
            name: conversation.name,
            updatedAt: conversation.updatedAt,
            preview: String(preview.prefix(120))
        )
    }

    /// Brings the single-chat UserDefaults history into this store, once.
    private func migrateLegacyHistory() {
        guard !UserDefaults.standard.bool(forKey: Self.migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.migratedKey) }
        guard let data = UserDefaults.standard.data(forKey: Self.legacyHistoryKey),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !messages.isEmpty else { return }
        let conversation = Conversation(name: "Previous chats", messages: messages)
        save(conversation)
        UserDefaults.standard.removeObject(forKey: Self.legacyHistoryKey)
    }

    // MARK: Cross-conversation search

    /// Sweeps every saved conversation except the excluded one for the
    /// query, off the main thread. Runs off `ConversationMatchGroup`s,
    /// most recently active conversation first, a few snippets per group.
    /// This never runs on the main thread: it decodes full message files.
    nonisolated static func searchOtherConversations(query: String, excluding excludedID: UUID) -> [ConversationMatchGroup] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conversations", isDirectory: true)

        // Names and dates come from the small summary index.
        let summaries: [ConversationSummary]
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let decoded = try? JSONDecoder().decode([ConversationSummary].self, from: data) {
            summaries = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            summaries = []
        }

        var groups: [ConversationMatchGroup] = []
        for summary in summaries where summary.id != excludedID {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(summary.id.uuidString).json")),
                  let conversation = try? JSONDecoder().decode(Conversation.self, from: data) else {
                continue
            }
            var matches: [ConversationMatchGroup.Match] = []
            for message in conversation.messages {
                if matches.count >= 5 { break }
                guard !message.text.isEmpty,
                      message.text.range(of: query, options: options) != nil else { continue }
                matches.append(ConversationMatchGroup.Match(
                    id: message.id,
                    role: message.role,
                    snippet: snippet(in: message.text, query: query)
                ))
            }
            if !matches.isEmpty {
                groups.append(ConversationMatchGroup(
                    id: summary.id,
                    name: summary.name,
                    updatedAt: summary.updatedAt,
                    matches: matches
                ))
            }
        }
        return groups
    }

    /// A short window around the query's first occurrence, so a match is
    /// recognisable without loading the whole message.
    nonisolated private static func snippet(in text: String, query: String) -> String {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let range = text.range(of: query, options: options) else {
            return String(text.prefix(120))
        }
        let lower = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[lower..<upper])
        if lower > text.startIndex {
            snippet = "…" + snippet
        }
        if upper < text.endIndex {
            snippet += "…"
        }
        return snippet
    }
}

// MARK: - Conversations (list screen)

/// A lightweight entry for the list screen: name, preview and date only,
/// so the list never has to decode full message histories.
struct ConversationSummary: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var updatedAt: Date
    var preview: String
}

/// One other conversation whose history matched the query, with a few
/// snippet matches (the view highlights the query inside them).
struct ConversationMatchGroup: Identifiable, Equatable {
    struct Match: Identifiable, Equatable {
        let id: UUID
        let role: String
        let snippet: String
    }

    let id: UUID
    let name: String
    let updatedAt: Date
    let matches: [Match]
}

/// The conversation list: every chat with Eye~Helpi as a command-deck card
/// (name, last message preview, date), with a New Chat button. Picking one
/// opens the familiar Chat screen loaded with that conversation's history.
struct ConversationListView: View {

    @ObservedObject var chat: AgentChatModel
    let onSelect: (ConversationSummary) -> Void
    let onNew: () -> Void

    @State private var conversations: [ConversationSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    EyeSigil()
                    EyeTheme.hud("your conversations")
                    Spacer()
                }
                .padding(.horizontal, 4)

                if conversations.isEmpty {
                    Text("No conversations yet — start one below, my person.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                }

                ForEach(conversations) { summary in
                    Button {
                        onSelect(summary)
                    } label: {
                        ConversationCard(
                            summary: summary,
                            isActive: summary.id == chat.conversation.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .hudBackground()
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onNew()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("New chat")
            }
        }
        .onAppear {
            conversations = ConversationArchive.shared.allSummaries()
        }
    }
}

/// One conversation in the list: name, last message preview and date, in
/// the command-deck card style.
private struct ConversationCard: View {

    let summary: ConversationSummary
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isActive {
                        EyeSigil()
                    }
                    Text(summary.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(summary.preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(dateText)
                .font(EyeTheme.hudFont)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(EyeTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isActive ? EyeTheme.accent.opacity(0.5) : EyeTheme.hairline)
        )
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: summary.updatedAt).uppercased()
    }
}

/// A match found in another conversation: its name, date and a few
/// highlighted snippets. Tapping a snippet opens that conversation and
/// centers the matched message.
private struct OtherConversationCard: View {

    let group: ConversationMatchGroup
    let query: String
    let onSelectMatch: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.footnote)
                    .foregroundStyle(EyeTheme.accent)
                Text(group.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(dateText)
                    .font(EyeTheme.hudFont)
                    .foregroundStyle(.secondary)
            }
            ForEach(group.matches) { match in
                Button {
                    onSelectMatch(match.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(match.role == "assistant" ? "Eye~Helpi" : "Me")
                            .font(EyeTheme.hudFont)
                            .foregroundStyle(EyeTheme.accent)
                        HighlightedChatText(text: match.snippet, query: query)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(EyeTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EyeTheme.hairline))
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: group.updatedAt).uppercased()
    }
}

#Preview {
    NavigationStack {
        ConversationListView(
            chat: AgentChatModel(),
            onSelect: { _ in },
            onNew: {}
        )
    }
}

// MARK: - Transcript export

/// The file handed to the share sheet (identifiable so `.sheet(item:)` works).
private struct TranscriptExport: Identifiable {
    let id = UUID()
    let url: URL
}

/// The iOS share sheet, wrapped for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Live brain-status chip

/// The Chat toolbar's live status chip: green when the local Ollama host
/// answers, orange when only the OpenAI fallback is available, grey when
/// nothing is usable. Tapping it forces an immediate check with a note.
struct BrainStatusChip: View {

    let status: BrainStatus

    var body: some View {
        StatusChip(text: text, color: color)
    }

    private var text: String {
        switch status {
        case .ollama: return "brain: live"
        case .cloudOnly: return "brain: cloud only"
        case .offline: return "brain: offline"
        }
    }

    private var color: Color {
        switch status {
        case .ollama: return .green
        case .cloudOnly: return .orange
        case .offline: return .secondary
        }
    }
}