import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A model on the llama.cpp router pi is logged in to (`/api/llama`).
public struct LlamaModel: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    /// As llama.cpp reports it: loaded, loading, unloaded, sleeping...
    public var status: String
    /// The last load failed (out of GPU memory, a bad file).
    public var failed: Bool

    public init(id: String, status: String, failed: Bool = false) {
        self.id = id
        self.status = status
        self.failed = failed
    }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.string else { return nil }
        self.init(id: id, status: v["status"]?.string ?? "unknown", failed: v["failed"]?.bool ?? false)
    }

    /// pi can use it now (it lists only loaded router models).
    public var isLoaded: Bool { status == "loaded" || status == "sleeping" }
    /// pi's provider for router models.
    public static let provider = "llama.cpp"
    public var key: String { Self.provider + "/" + id }
}

/// The router as the server sees it: absent (pi isn't logged in to one),
/// unreachable, or its models.
public struct LlamaRouter: Sendable, Equatable {
    public var available: Bool
    public var error: String?
    public var models: [LlamaModel]

    public init(available: Bool, error: String? = nil, models: [LlamaModel] = []) {
        self.available = available
        self.error = error
        self.models = models
    }

    init(_ v: JSONValue) {
        available = v["available"]?.bool ?? false
        error = v["error"]?.string
        models = (v["models"]?.array ?? []).compactMap(LlamaModel.init)
    }
}

/// The Chat tab's chats and the folder they live in.
public struct ChatList: Sendable, Equatable {
    public var sessions: [SessionInfo]
    public var chatDir: String
}

extension PocketPiClient {
    public func llama() async throws -> LlamaRouter {
        LlamaRouter(try await get("/api/llama", as: JSONValue.self))
    }

    /// Load a router model (the server unloads the others first) and return
    /// once it's loaded. A big model can take minutes.
    public func loadLlama(model: String) async throws {
        var r = try request("/api/llama/load", body: ["model": .string(model)])
        r.timeoutInterval = 330
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PocketPiError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
    }

    /// The Chat tab's chats (plain conversations, kept out of the projects).
    public func chats(archived: Bool = false) async throws -> ChatList {
        let v = try await get("/api/sessions?chat=1" + (archived ? "&archived=1" : ""), as: JSONValue.self)
        let sessions = try JSONDecoder().decode([SessionInfo].self, from: try (v["sessions"] ?? .array([])).encoded())
        return ChatList(sessions: sessions, chatDir: v["chat_dir"]?.string ?? "")
    }
}
