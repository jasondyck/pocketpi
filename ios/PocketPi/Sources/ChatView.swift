import PhotosUI
import PocketPiKit
import SwiftUI
import UIKit

/// Makes the session once per screen (the client comes from the environment,
/// which an initializer can't read).
struct ChatView: View {
    @Environment(AppModel.self) private var model
    private let path: String?
    private let cwd: String
    @State private var session: ChatSession?

    init(path: String, cwd: String) { self.path = path; self.cwd = cwd }
    init(newIn cwd: String) { self.path = nil; self.cwd = cwd }

    var body: some View {
        Group {
            if let session { ChatScreen(session: session) } else { Color.clear }
        }
        .onAppear {
            guard session == nil, let client = model.client else { return }
            let s = path.map { ChatSession(client: client, path: $0, cwd: cwd) } ?? ChatSession(client: client, newIn: cwd)
            s.onTurnFinished = { [model] in Task { await model.refresh() } }
            session = s
        }
    }
}

private struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var session: ChatSession
    @State private var atBottom = true
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if session.transcript.isEmpty, session.path == nil {
                        EmptyChat(project: model.projectName(for: session.cwd), cwd: Format.tilde(session.cwd, home: model.home))
                    }
                    ForEach(session.transcript.items) { item in
                        TranscriptItemView(item: item, transcript: session.transcript, home: model.home)
                    }
                    if session.isStreaming {
                        WorkingLine(activity: session.transcript.activity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            // The reason this app exists: the keyboard follows the finger down.
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 90
            } action: { _, near in
                atBottom = near
            }
            .onChange(of: session.transcript) {
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.callout.weight(.semibold))
                            .padding(10)
                            .glass(in: Circle(), interactive: true)
                    }
                    .padding()
                    .accessibilityLabel("Jump to the end")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(session: session)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            StatusBanner(status: session.status)
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(session.title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { chatMenu }
        }
        .task { await session.start() }
        .onDisappear { session.leave() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.start() } }
        }
        .sheet(item: $session.pendingRequest) { req in
            ExtensionSheet(request: req) { answer in Task { await session.respond(to: req, answer) } }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await session.rename(newName) } }
        }
        .overlay(alignment: .top) {
            if let t = session.toast {
                Toast(text: t)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        if session.toast == t { session.toast = nil }
                    }
            }
        }
    }

    private var subtitle: String {
        var parts = [model.projectName(for: session.cwd)]
        if let s = session.state { parts.append(s.modelLabel) }
        if let p = session.stats?.contextPercent { parts.append("\(Int(p.rounded()))% context") }
        return parts.joined(separator: " · ")
    }

    private var chatMenu: some View {
        Menu {
            if let stats = session.stats {
                let percent = stats.contextPercent.map { String(Int($0.rounded())) + "%" } ?? "–"
                Section("This chat") {
                    Text(verbatim: "Context " + percent + " of " + Format.tokens(stats.contextWindow))
                    Text(verbatim: Format.tokens(stats.totalTokens) + " tokens · " + Format.cost(stats.cost))
                }
            }
            if session.state?.model?["reasoning"]?.bool == true, session.thinkingLevels.count > 1 {
                Picker("Thinking", selection: Binding(
                    get: { session.state?.thinkingLevel ?? "" },
                    set: { l in Task { await session.setThinkingLevel(l) } })
                ) {
                    ForEach(session.thinkingLevels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Button("Rename", systemImage: "pencil") {
                newName = session.state?.sessionName ?? session.title
                renaming = true
            }
            .disabled(session.key == nil && session.path == nil)
            Button("Compact context", systemImage: "arrow.down.right.and.arrow.up.left") {
                Task { await session.compact() }
            }
            .disabled(session.isStreaming || session.path == nil)
        } label: {
            ContextRing(fraction: session.stats?.contextFraction ?? 0)
        }
    }
}

private struct EmptyChat: View {
    let project: String
    let cwd: String
    var body: some View {
        VStack(spacing: 6) {
            Text("What should pi do?").font(.title2.weight(.semibold))
            Text("\(project) · \(cwd)").font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

private struct WorkingLine: View {
    let activity: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.signalText)
            Text(activity).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityIdentifier("working")
    }
}

private struct StatusBanner: View {
    let status: ChatSession.Status
    var body: some View {
        switch status {
        case .opening, .reconnecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status == .opening ? "Opening…" : "Reconnecting…")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glass(in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        case .failed(let msg):
            Text(msg)
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.danger)
        case .idle, .connected:
            EmptyView()
        }
    }
}

struct ContextRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction > 0.85 ? Theme.danger : fraction > 0.65 ? .orange : Theme.signalText,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel("Chat settings, context \(Int(fraction * 100)) percent")
    }
}

private struct Toast: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(text)
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glass(in: Capsule())
            .padding(.top, 8)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }
}

/// confirm / select / input / editor dialogs from pi extensions.
private struct ExtensionSheet: View {
    let request: ExtensionRequest
    let answer: (ChatSession.Answer) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var answered = false

    var body: some View {
        NavigationStack {
            Form {
                if let m = request.message { Section { Text(m) } }
                switch request.method {
                case .confirm:
                    Section {
                        Button("Confirm") { finish(.confirmed(true)) }
                        Button("Cancel", role: .cancel) { finish(.confirmed(false)) }
                    }
                case .select:
                    Section {
                        ForEach(request.options, id: \.self) { o in Button(o) { finish(.value(o)) } }
                    }
                case .input:
                    Section { TextField(request.placeholder ?? "", text: $text) }
                    Section { Button("Submit") { finish(.value(text)) } }
                case .editor:
                    Section { TextEditor(text: $text).frame(minHeight: 200).font(.body.monospaced()) }
                    Section { Button("Submit") { finish(.value(text)) } }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(.cancelled) } }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { text = request.prefill ?? "" }
        // Swiped away: pi is still waiting for an answer.
        .onDisappear { if !answered { answer(.cancelled) } }
    }

    private func finish(_ a: ChatSession.Answer) {
        answered = true
        answer(a)
        dismiss()
    }
}

// MARK: - composer

private struct FloatingBar: ViewModifier {
    func body(content: Content) -> some View {
        if LiquidGlass.available {
            content.glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content
        }
    }
}

private struct Composer: View {
    @Bindable var session: ChatSession
    @State private var images: [ImageAttachment] = []
    @State private var picks: [PhotosPickerItem] = []
    @State private var sending = false
    @FocusState private var focused: Bool

    private var hasText: Bool { !session.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(session.transcript.steering + session.transcript.followUp, id: \.self) { q in
                Text(q).font(.footnote).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(images) { a in
                            AttachmentThumb(attachment: a) { images.removeAll { $0.id == a.id } }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $picks, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus").font(.title3).frame(width: 34, height: 34)
                }
                .accessibilityLabel("Attach images")
                TextField(session.isStreaming ? "Steer pi…" : "Message pi", text: $session.composer, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, LiquidGlass.available ? 4 : 12)
                    .padding(.vertical, 8)
                    .background(LiquidGlass.available ? Color.clear : Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("composer")
                sendButton
            }
            // iOS 26: one floating glass bar over the transcript, like Messages.
            .padding(LiquidGlass.available ? 6 : 0)
            .modifier(FloatingBar())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LiquidGlass.available ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.bar))
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let a = ImageShrinker.attachment(from: data) { images.append(a) }
                }
                picks = []
            }
        }
    }

    @ViewBuilder private var sendButton: some View {
        if session.isStreaming && !hasText && images.isEmpty {
            Button { Task { await session.stop() } } label: {
                Image(systemName: "stop.fill")
                    .font(.callout)
                    .frame(width: 34, height: 34)
                    .background(Color.primary, in: Circle())
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.callout.weight(.bold))
                    .frame(width: 34, height: 34)
                    .background(hasText || !images.isEmpty ? Theme.signal : Theme.surface, in: Circle())
                    .foregroundStyle(Theme.signalInk)
            }
            .disabled(sending || (!hasText && images.isEmpty))
            .accessibilityLabel("Send")
        }
    }

    private func send() {
        let text = session.composer
        let imgs = images
        session.composer = ""
        images = []
        sending = true
        Task {
            defer { sending = false }
            do { try await session.send(text, images: imgs) } catch {
                if session.composer.isEmpty { session.composer = text }
                images = imgs
                session.toast = error.localizedDescription
            }
        }
    }
}

private struct AttachmentThumb: View {
    let attachment: ImageAttachment
    let remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let data = Data(base64Encoded: attachment.base64), let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }
}

/// Downscale on the phone before upload, like shrink() in app.js: pi gets a
/// readable picture, not a 12-megapixel one.
enum ImageShrinker {
    static func attachment(from data: Data, maxSide: CGFloat = 1568) -> ImageAttachment? {
        guard let img = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = out.jpegData(compressionQuality: 0.85) else { return nil }
        return ImageAttachment(base64: jpeg.base64EncodedString(), mimeType: "image/jpeg")
    }
}
