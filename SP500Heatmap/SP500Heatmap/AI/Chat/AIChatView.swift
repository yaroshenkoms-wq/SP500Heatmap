import SwiftUI

private struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var pending = false
    var failed = false
    var quick = false
    var sources: [AIHeadline] = []
}

@MainActor
private final class AIChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var busy = false
    private let box = AIChatSessionBox()
    private var task: Task<Void, Never>?

    func reset() { task?.cancel(); box.reset(); messages = []; busy = false }

    /// Свободный вопрос — модель с инструментами.
    func ask(_ text: String, code: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        messages.append(ChatMessage(role: .user, text: q))
        messages.append(ChatMessage(role: .assistant, text: "", pending: true))
        let idx = messages.count - 1
        busy = true
        task = Task {
            do {
                try await box.send(q, code: code) { [weak self] partial in
                    guard let self, self.messages.indices.contains(idx) else { return }
                    self.messages[idx].text = partial
                    self.messages[idx].pending = partial.isEmpty
                }
                if messages.indices.contains(idx) {
                    messages[idx].pending = false
                    if messages[idx].text.isEmpty { messages[idx].failed = true }
                }
            } catch {
                if messages.indices.contains(idx) { messages[idx].pending = false; messages[idx].failed = true }
            }
            busy = false
        }
    }

    /// Готовый вопрос без модели — шаблонный ответ.
    func quick(_ question: AIQuestion, code: String) {
        guard !busy else { return }
        messages.append(ChatMessage(role: .user, text: question.text(code, indexName: Self.indexName)))
        messages.append(ChatMessage(role: .assistant, text: "", pending: true, quick: true))
        let idx = messages.count - 1
        busy = true
        task = Task {
            let a = await AIQuickAnswers.answer(question, code: code)
            if Task.isCancelled { return }
            if messages.indices.contains(idx) {
                messages[idx].text = a.lines.joined(separator: "\n")
                messages[idx].sources = a.sources
                messages[idx].pending = false
            }
            busy = false
        }
    }

    static func indexName(_ id: String) -> String {
        IndexStore.shared.indices.first { $0.id == id }?.name ?? (id == "ibex35" ? "IBEX 35" : id)
    }
}

/// Чат с ИИ: полная модель с инструментами или, без неё, быстрые ответы по готовым вопросам.
struct AIChatView: View {
    var suggestions: [AIQuestion] = AIQuestion.suggested
    var autoAsk: AIQuestion?

    @StateObject private var model = AIChatModel()
    @AppStorage(AppLanguage.storageKey) private var languageChoice = ""
    @State private var input = ""
    @State private var safariLink: SafariLink?
    @State private var didAuto = false
    @FocusState private var focused: Bool

    private var code: String { AppLanguage.effectiveCode }
    private var fullChat: Bool { AIChatEngine.isUsable(languageCode: code) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !fullChat { quickNote }
                        ForEach(model.messages) { bubble($0) }
                        if model.messages.isEmpty || !fullChat || !model.busy { suggestionList }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: 800).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages) { _, _ in withAnimation { proxy.scrollTo("end") } }
            }
            if fullChat { inputBar }
        }
        .themeScreen()
        .toolbar {
            if !model.messages.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.reset() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel(Text("New chat"))
                }
            }
        }
        .sheet(item: $safariLink) { SafariView(url: $0.url).ignoresSafeArea() }
        .onChange(of: languageChoice) { _, _ in model.reset() }
        .task {
            guard let q = autoAsk, !didAuto else { return }
            didAuto = true
            if fullChat { model.ask(q.text(code, indexName: AIChatModel.indexName), code: code) } else { model.quick(q, code: code) }
        }
    }

    // MARK: части

    private var quickNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundColor(Theme.gold)
            Text("Full chat needs Apple Intelligence on a supported device, turned on, in a supported language. Quick answers below are built from live app data.")
                .font(Theme.ui(.footnote)).foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).panelCard()
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fullChat ? "Suggested questions" : "Quick answers")
                .font(Theme.ui(.caption, weight: .medium)).foregroundColor(Theme.muted)
            ForEach(suggestions) { q in
                Button {
                    if fullChat { model.ask(q.text(code, indexName: AIChatModel.indexName), code: code) } else { model.quick(q, code: code) }
                } label: {
                    HStack {
                        Text(verbatim: q.text(code, indexName: AIChatModel.indexName))
                            .font(Theme.ui(.subheadline)).foregroundColor(Theme.text).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundColor(Theme.gold)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelCard()
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.role == .user {
            Text(verbatim: m.text)
                .font(Theme.ui(.subheadline)).foregroundColor(Theme.bg)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.gold, in: RoundedRectangle(cornerRadius: Theme.radius))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if m.pending && m.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.gold)
                        Text("Looking up data…").font(Theme.ui(.footnote)).foregroundColor(Theme.muted)
                    }
                } else if m.failed {
                    Text("The on-device model couldn't answer. Try rephrasing, or use a quick answer.")
                        .font(Theme.ui(.footnote)).foregroundColor(Theme.danger)
                } else {
                    Text(verbatim: m.text).font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if !m.sources.isEmpty { sources(m.sources) }
                    if !m.pending {
                        Text(m.quick ? "Automatic summary" : "On-device AI")
                            .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                        Text("AI-generated, may be inaccurate. Not investment advice.")
                            .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).panelCard()
        }
    }

    private func sources(_ list: [AIHeadline]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(Theme.ui(.caption, weight: .medium)).foregroundColor(Theme.muted)
            ForEach(list) { h in
                Button { if let u = h.url.flatMap(URL.init(string:)) { safariLink = SafariLink(url: u) } } label: {
                    Label { Text(verbatim: h.title + (h.publisher.map { " · \($0)" } ?? "")).lineLimit(2).multilineTextAlignment(.leading) }
                        icon: { Image(systemName: "link") }
                        .font(Theme.ui(.caption)).foregroundColor(Theme.gold)
                }
                .buttonStyle(.plain).disabled(h.url == nil)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(AppLanguage.string("Ask about markets, a stock, or your portfolio…"), text: $input, axis: .vertical)
                .lineLimit(1...4)
                .font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38).outlinedControl()
            }
            .buttonStyle(.plain)
            .disabled(model.busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(Text("Send"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.bg)
    }

    private func send() {
        let q = input
        input = ""
        model.ask(q, code: code)
    }
}

/// Окно «Бриф + Чат»: открывается кнопкой ✨ на главном экране, со страницы компании и из портфеля.
struct AIAssistantView: View {
    enum Tab: Hashable { case brief, chat }
    var initialTab: Tab = .brief
    var suggestions: [AIQuestion] = AIQuestion.suggested
    var autoAsk: AIQuestion?

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab

    init(initialTab: Tab = .brief, suggestions: [AIQuestion] = AIQuestion.suggested, autoAsk: AIQuestion? = nil) {
        self.initialTab = initialTab; self.suggestions = suggestions; self.autoAsk = autoAsk
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(selection: $tab) {
                    Text("Brief").tag(Tab.brief)
                    Text("Chat").tag(Tab.chat)
                } label: { Text("AI assistant") }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                // Обе вкладки живут сразу: беседа не теряется при переключении на бриф.
                ZStack {
                    MarketBriefView(compact: false)
                        .opacity(tab == .brief ? 1 : 0).allowsHitTesting(tab == .brief)
                    AIChatView(suggestions: suggestions, autoAsk: autoAsk)
                        .opacity(tab == .chat ? 1 : 0).allowsHitTesting(tab == .chat)
                }
            }
            .themeScreen()
            .navigationTitle(Text("AI assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .themeNavBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(Text("Close"))
                }
            }
        }
        .tint(Theme.gold)
        .presentationDetents([.large])
    }
}

/// Кнопка «Спросить ИИ» для страницы компании и портфеля: открывает окно чата с готовым вопросом.
struct AskAIButton: View {
    var question: AIQuestion
    var suggestions: [AIQuestion] = AIQuestion.suggested
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Label("Ask AI", systemImage: "sparkles")
                .font(Theme.ui(.caption, weight: .medium))
                .padding(.horizontal, 12).frame(minHeight: 32).outlinedControl()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $show) { AIAssistantView(initialTab: .chat, suggestions: suggestions, autoAsk: question) }
    }
}
