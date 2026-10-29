import Foundation

/// Phone numbers and web addresses inside a text, made tappable. A number becomes a `tel:` link, which the thread
/// turns into a call through the bridge instead of letting iOS dial it on a SIM the iPhone does not have.
enum MessageLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector else { return result }
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text), let target = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            let url: URL?
            if match.resultType == .phoneNumber, let number = match.phoneNumber {
                let dialable = number.filter { $0.isASCII && ($0.isNumber || $0 == "+") }
                url = dialable.isEmpty ? nil : URL(string: "tel:" + dialable)
            } else {
                url = match.url
            }
            guard let url else { continue }
            result[target..<end].link = url
            result[target..<end].underlineStyle = .single
        }
        return result
    }
}
