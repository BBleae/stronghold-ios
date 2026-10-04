import Foundation

/// Wire-protocol constants, mirrored from the upstream `shared/constants.js`.
enum GameConstants {
    /// PROTOCOL_VERSION — sent in `hello.version`; must equal the server's.
    static let protocolVersion = 1
    /// Max nickname length the server accepts (code points).
    static let nameMaxLength = 12
    /// Room codes are 4 characters.
    static let roomCodeLength = 4
    /// Heartbeat / liveness, matching the web client.
    static let pingInterval: TimeInterval = 4
    static let deadAfter: TimeInterval = 15
    static let requestTimeout: TimeInterval = 8
    /// Reconnect backoff: 500 ms ×2, capped at 10 s (±20 % jitter).
    static let reconnectBase: TimeInterval = 0.5
    static let reconnectMax: TimeInterval = 10
}

/// Match phases (`PHASE` in shared/constants.js).
enum GamePhase: String, Decodable {
    case lobby = "LOBBY"
    case infoCheck = "INFO_CHECK"
    case bandDraft = "BAND_DRAFT"
    case battleCheck = "BATTLE_CHECK"
    case roundStart = "ROUND_START"
    case spDraft = "SP_DRAFT"
    case prep = "PREP"
    case combat = "COMBAT"
    case unite = "UNITE"
    case settle = "SETTLE"
    case finalAssault = "FINAL_ASSAULT"
    case hiddenCore = "HIDDEN_CORE"
    case result = "RESULT"
}

/// Difficulty ids (`DIFFICULTIES`).
enum GameDifficulty: String, CaseIterable, Decodable {
    case funny = "FUNNY"
    case normal = "NORMAL"
    case hard = "HARD"
    case abyss = "ABYSS"

    var label: String {
        switch self {
        case .funny: return "标准"
        case .normal: return "险境"
        case .hard: return "绝境"
        case .abyss: return "终极"
        }
    }
}

/// Server error codes (`ERR` in shared/constants.js).
enum GameError: String, Decodable {
    case badMsg = "BAD_MSG"
    case rate = "RATE"
    case notInRoom = "NOT_IN_ROOM"
    case roomNotFound = "ROOM_NOT_FOUND"
    case roomFull = "ROOM_FULL"
    case roomStarted = "ROOM_STARTED"
    case notHost = "NOT_HOST"
    case notReady = "NOT_READY"
    case wrongPhase = "WRONG_PHASE"
    case noFunds = "NO_FUNDS"
    case handFull = "HAND_FULL"
    case boardFull = "BOARD_FULL"
    case badTile = "BAD_TILE"
    case badTarget = "BAD_TARGET"
    case soldOut = "SOLD_OUT"
    case maxLevel = "MAX_LEVEL"
    case notYourTurn = "NOT_YOUR_TURN"
    case already = "ALREADY"
    case tempNotEmpty = "TEMP_NOT_EMPTY"
    case eliminated = "ELIMINATED"
    case internalError = "INTERNAL"
    case applicationExpired = "APPLICATION_EXPIRED"

    /// Human-readable text, mirroring the server's ERR_TEXT where known.
    var text: String {
        switch self {
        case .badMsg: return "无效的操作"
        case .rate: return "操作太快了，请稍等"
        case .notInRoom: return "不在房间里"
        case .roomNotFound: return "房间不存在"
        case .roomFull: return "房间已满"
        case .roomStarted: return "对局已经开始"
        case .notHost: return "只有房主可以这样做"
        case .notReady: return "还有玩家未准备"
        case .wrongPhase: return "当前阶段不能这样操作"
        case .noFunds: return "资金不足"
        case .handFull: return "整备区已满"
        case .boardFull: return "棋盘已满"
        case .badTile: return "不能放在这里"
        case .badTarget: return "目标无效"
        case .soldOut: return "已售出"
        case .maxLevel: return "已是最高等级"
        case .notYourTurn: return "还没轮到你"
        case .already: return "重复操作"
        case .tempNotEmpty: return "临时整备区未清空"
        case .eliminated: return "你已被淘汰"
        case .internalError: return "服务器内部错误"
        case .applicationExpired: return "申请已过期"
        }
    }
}

/// A server error frame.
struct ServerError: Error, Equatable {
    let code: GameError?
    let rawCode: String
    let message: String
    let detail: String?
}

/// Server close codes worth distinguishing.
enum ServerCloseCode {
    static let sessionReplaced: UInt16 = 4001
    static let helloTimeout: UInt16 = 4002
    static let flooding: UInt16 = 1008
    static let shutdown: UInt16 = 1001
}
