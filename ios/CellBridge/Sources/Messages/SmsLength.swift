import Foundation

/// How many SMS a text will take. Plain GSM 7-bit text fits 160 characters (153 per part when split); anything outside that
/// alphabet, which includes the Turkish ş, ğ and ı, makes it UCS-2: 70 (67 per part).
enum SmsLength {
    struct Measure: Equatable {
        let units: Int
        let perMessage: Int
        let parts: Int
    }

    private static let basic = Set("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
    private static let extended = Set("^{}\\[~]|€\u{000C}")

    static func measure(_ text: String) -> Measure {
        let characters = Array(text)
        if characters.allSatisfy({ basic.contains($0) || extended.contains($0) }) {
            let units = characters.reduce(0) { $0 + (extended.contains($1) ? 2 : 1) }
            return units <= 160 ? Measure(units: units, perMessage: 160, parts: units == 0 ? 0 : 1)
                                : Measure(units: units, perMessage: 153, parts: (units + 152) / 153)
        }
        let units = text.utf16.count
        return units <= 70 ? Measure(units: units, perMessage: 70, parts: 1) : Measure(units: units, perMessage: 67, parts: (units + 66) / 67)
    }
}
