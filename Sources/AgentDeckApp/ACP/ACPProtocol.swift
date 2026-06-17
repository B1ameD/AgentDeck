import Foundation

// Agent Client Protocol (ACP) v1 —— 线协议类型与 JSON-RPC 帧编解码。
// 传输:换行分隔的 JSON-RPC 2.0,跑在适配器子进程的 stdin/stdout(经 spike 实测,见 docs/ACP_INTEGRATION_PLAN.md)。
// 本文件是**纯逻辑**(无进程 I/O),便于用录制报文单测;进程壳在 ACPClient.swift。
// 范围:spike 只建模 initialize / session.new / session.prompt / session.update / request_permission 所需字段,
// 其余字段经 JSONValue 透传,不强求完整 schema。

// MARK: - JSONValue(动态 JSON——JSON-RPC 的 params/result 形态不定)

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的 JSON 值")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // 便捷取值
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - JSON-RPC 帧

/// 入站帧:可能是响应(id+result/error)、agent→client 请求(id+method)、或通知(method,无 id)。
/// 出站帧由 ACPClient 直接构造 JSON,不走这个类型。
public struct ACPIncomingFrame: Decodable, Sendable {
    public var id: ACPID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: ACPError?

    public var isResponse: Bool { id != nil && method == nil && (result != nil || error != nil) }
    public var isRequest: Bool { id != nil && method != nil }     // agent→client,需回应
    public var isNotification: Bool { id == nil && method != nil } // 无需回应
}

/// JSON-RPC id 可以是数字或字符串;我们出站统一发数字,但入站要两者都认。
public enum ACPID: Codable, Equatable, Sendable, Hashable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n); return }
        self = .string(try c.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

public struct ACPError: Decodable, Equatable, Sendable, Error {
    public var code: Int
    public var message: String
    public var data: JSONValue?
}

// MARK: - 帧编解码(纯逻辑,单测主目标)

public enum ACPCodec {
    private static let decoder = JSONDecoder()

    /// 解析一行 JSON-RPC 帧。空行返回 nil;坏 JSON 抛错由调用方记录(不致命)。
    public static func decodeFrame(_ line: String) throws -> ACPIncomingFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try decoder.decode(ACPIncomingFrame.self, from: data)
    }

    /// 构造一条出站请求/通知行(末尾不含换行,由调用方补)。
    public static func encodeRequest(id: Int?, method: String, params: [String: JSONValue]) -> String {
        var obj: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { obj["id"] = .number(Double(id)) }
        if !params.isEmpty { obj["params"] = .object(params) }
        return encodeObject(obj)
    }

    /// 构造对 agent→client 请求的响应行。
    public static func encodeResponse(id: ACPID, result: [String: JSONValue]) -> String {
        let idValue: JSONValue
        switch id {
        case .number(let n): idValue = .number(Double(n))
        case .string(let s): idValue = .string(s)
        }
        return encodeObject(["jsonrpc": .string("2.0"), "id": idValue, "result": .object(result)])
    }

    private static func encodeObject(_ obj: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(JSONValue.object(obj)),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - 高层语义类型(从 result/params 投影)

/// initialize 结果里的 agent 能力(spike 只取所需)。
public struct ACPAgentCapabilities: Sendable, Equatable {
    public var protocolVersion: Int
    public var loadSession: Bool
    public var agentName: String?
    public var authMethods: [String]

    public init(from result: JSONValue) {
        protocolVersion = result["protocolVersion"]?.intValue ?? 0
        let caps = result["agentCapabilities"]
        loadSession = caps?["loadSession"].flatMap { if case .bool(let b) = $0 { return b }; return nil } ?? false
        agentName = result["agentInfo"]?["name"]?.stringValue
        authMethods = (result["authMethods"]?.arrayValue ?? []).compactMap {
            $0["id"]?.stringValue ?? $0.stringValue
        }
    }
}

/// session/new 结果:sessionId + 可用模式 + 配置项(模型/effort 由 agent 自报)。
public struct ACPNewSession: Sendable, Equatable {
    public var sessionId: String
    public var currentModeId: String?
    public var availableModes: [ACPMode]
    public var configOptions: [ACPConfigOption]

    public init?(from result: JSONValue) {
        guard let sid = result["sessionId"]?.stringValue else { return nil }
        sessionId = sid
        let modes = result["modes"]
        currentModeId = modes?["currentModeId"]?.stringValue
        availableModes = (modes?["availableModes"]?.arrayValue ?? []).compactMap(ACPMode.init(from:))
        configOptions = (result["configOptions"]?.arrayValue ?? []).compactMap(ACPConfigOption.init(from:))
    }
}

public struct ACPMode: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public init?(from v: JSONValue) {
        guard let id = v["id"]?.stringValue, let name = v["name"]?.stringValue else { return nil }
        self.id = id; self.name = name; self.description = v["description"]?.stringValue
    }
}

public struct ACPConfigOption: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public init?(from v: JSONValue) {
        guard let id = v["id"]?.stringValue, let name = v["name"]?.stringValue else { return nil }
        self.id = id; self.name = name; self.description = v["description"]?.stringValue
    }
}

/// 一条权限请求的选项(allow_once / allow_always / reject_once / reject_always)。
public struct ACPPermissionOption: Sendable, Equatable {
    public var optionId: String
    public var name: String
    public var kind: String
    public init?(from v: JSONValue) {
        guard let oid = v["optionId"]?.stringValue, let name = v["name"]?.stringValue,
              let kind = v["kind"]?.stringValue else { return nil }
        self.optionId = oid; self.name = name; self.kind = kind
    }
    public var isAllow: Bool { kind.hasPrefix("allow") }
    public var remembers: Bool { kind.hasSuffix("always") }
}
