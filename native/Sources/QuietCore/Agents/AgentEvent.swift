import Foundation

/// One entry of an agent session. Text is redacted and bounded in `init`, so no caller
/// downstream of a parser can hold or forward unmasked transcript content.
public struct AgentEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case user, assistant, toolCall, toolResult, reasoning, usage, notice }
    public static let textLimit = 4000
    public let kind: Kind
    public let timestamp: Date?
    public let title: String
    public let text: String
    public let tokens: Int?
    public let failed: Bool

    public init(_ kind: Kind, at timestamp: Date? = nil, title: String = "", text: String = "", tokens: Int? = nil, failed: Bool = false) {
        self.kind = kind; self.timestamp = timestamp; self.tokens = tokens; self.failed = failed
        self.title = String(Redactor.redact(String(title.prefix(200))).prefix(120))
        // Redact a wider window than is kept: a secret straddling the kept boundary is masked whole,
        // and the discarded remainder absorbs any secret cut short by the first truncation.
        let redacted = Redactor.redact(String(text.prefix(Self.textLimit * 2)))
        let kept = redacted.prefix(Self.textLimit)
        self.text = text.count > kept.count && redacted.count > Self.textLimit ? kept + "\n... (truncated)" : String(kept)
    }
}

/// What one log line contributed. `usageKey` lets a tail count repeated usage records once.
public struct AgentLogLine: Sendable {
    public var events: [AgentEvent] = []
    public var workingDirectory: String?
    public var usageKey: String?
    public init() {}
}
