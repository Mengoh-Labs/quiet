import Foundation

/// Masks recognisable credentials before agent text reaches the screen, a model or a store.
/// It over-masks on purpose: a hidden hash costs little, a displayed key cannot be taken back.
public enum Redactor {
    public static let mask = "[redacted]"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are fixed literals; a failure here is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: [])
    }
    private static let secretKey = "[A-Za-z0-9_.-]*(?:password|passwd|passphrase|secret|token|api[_-]?key|authorization|private[_-]?key|client[_-]?secret|access[_-]?key)[A-Za-z0-9_.-]*"
    private static let countKey = "(?:tokens|max_tokens|input_tokens|output_tokens|total_tokens|cached_input_tokens|cache_read_input_tokens|cache_creation_input_tokens)"
    private static let rules: [(NSRegularExpression, String)] = [
        (regex("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\\z)"), mask),
        (regex("([A-Za-z][A-Za-z0-9+.-]*://)[^\\s/:@]+:[^\\s/@]+@"), "$1\(mask)@"),
        (regex("(?i)\\b(bearer|basic)\\s+[A-Za-z0-9._~+/=-]+"), "$1 \(mask)"),
        (regex("\\b(?:sk-ant-[A-Za-z0-9_-]{8,}|sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"
            + "|glpat-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|A[KS]IA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,}"
            + "|hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{20,})"), mask),
        (regex("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{4,}"), mask),
        // A quoted value is masked through its closing quote: passphrases contain spaces.
        (regex("(?i)\\b(" + secretKey + "[\"']?\\s*[:=]\\s*)([\"'])(?:\\\\[\\s\\S]|(?!\\2)[^\\\\])*(?:\\2|\\z)"), "$1$2\(mask)$2"),
        // Only explicit numeric usage fields are counts; numeric passwords/tokens are credentials.
        (regex("(?i)\\b(?!" + countKey + "[\"']?\\s*[:=]\\s*\\d{1,12}(?![A-Za-z0-9_.-]))(" + secretKey + "[\"']?\\s*[:=]\\s*)(?![\"'])(?!\\[redacted\\])(?!(?:bearer|basic)\\s)[^\\s\"',;&}\\]]+"), "$1\(mask)")
    ]
    private static let opaque = regex("(?<![A-Za-z0-9_+=-])[A-Za-z0-9_+=-]{40,}(?![A-Za-z0-9_+=-])")

    public static func redact(_ text: String) -> String {
        var result = text
        for (rule, template) in rules {
            result = rule.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        // Long unbroken runs mixing cases and digits look like key material, not prose or paths.
        let matches = opaque.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let run = result[range]
            if run.contains(where: \.isUppercase), run.contains(where: \.isLowercase), run.contains(where: \.isNumber) {
                result.replaceSubrange(range, with: mask)
            }
        }
        return result
    }
}
