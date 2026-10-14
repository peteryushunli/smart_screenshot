import Foundation

/// Best-effort detection of credentials and personal identifiers.
///
/// This is a safety net, not a guarantee. It catches common shapes (labelled passwords and tokens, email
/// addresses, phone numbers, long digit sequences such as card or account numbers, and long random-looking
/// tokens such as API keys) so they stay out of filenames and out of text sent to a cloud model.
public enum SensitiveText {
    /// Replaces likely sensitive values with placeholders such as `[email]` and strips URL query strings.
    /// Used on OCR text before it leaves the device.
    public static func redact(_ text: String) -> String {
        transform(text, mode: .redact)
    }

    /// Removes likely sensitive values and URLs entirely. Used on titles.
    public static func remove(from text: String) -> String {
        transform(text, mode: .remove)
    }

    public static func containsSensitiveContent(_ text: String) -> Bool {
        redact(text) != text
    }

    private enum Mode { case redact, remove }

    private static func transform(_ text: String, mode: Mode) -> String {
        func placeholder(_ kind: String) -> String { mode == .redact ? "[\(kind)]" : " " }
        var result = text

        // URLs can carry tokens in their query strings.
        switch mode {
        case .redact:
            result = result.replacing(#/(?i)\b(https?://[^\s?#]+)[?#]\S*/#) { "\($0.output.1)" }
        case .remove:
            result = result.replacing(#/(?i)\bhttps?://\S+/#) { _ in " " }
        }
        // Labelled secrets keep their label: "Password: hunter2" → "Password: [secret]" or "Password".
        result = result.replacing(
            #/(?i)\b(password|passwd|passcode|pin|otp|token|secret|api[ _-]?key)(\s*[:=]\s*)\S+/#
        ) { match in
            mode == .redact ? "\(match.output.1)\(match.output.2)[secret]" : "\(match.output.1) "
        }
        result = result.replacing(#/[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}/#) { _ in
            placeholder("email")
        }
        // Long tokens that mix letters and digits look random: API keys, access tokens, hashes, UUIDs.
        result = result.replacing(#/[A-Za-z0-9_\-+=]{20,}/#) { match in
            let token = match.output
            let mixesLettersAndDigits = token.contains(where: \.isLetter) && token.contains(where: \.isNumber)
            return mixesLettersAndDigits ? placeholder("secret") : String(token)
        }
        result = result.replacing(#/(?:\+\d{1,3}[ .\-]?)?\(?\d{3}\)?[ .\-]?\d{3}[ .\-]\d{4}\b/#) { _ in
            placeholder("number")
        }
        // Eight or more digits, optionally grouped by single spaces or hyphens. ISO dates are kept.
        result = result.replacing(#/\d(?:[ \-]?\d){7,}/#) { match in
            let digits = String(match.output)
            return digits.contains(#/\d{4}-\d{2}-\d{2}/#) ? digits : placeholder("number")
        }
        return result
    }
}
