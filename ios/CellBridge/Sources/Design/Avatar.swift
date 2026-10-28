import SwiftUI

/// A contact's picture stand-in: initials on a soft gradient whose hue is fixed by the name, like the system apps.
struct Avatar: View {
    let name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Self.palette[index].top, Self.palette[index].bottom],
                                         startPoint: .top, endPoint: .bottom))
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.46))
            } else {
                Text(initials).font(.system(size: size * 0.40, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Up to two capital letters; none for a bare number, which gets the person glyph.
    var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return words.prefix(2).compactMap { $0.first.map { String($0).uppercased(with: Locale(identifier: "tr_TR")) } }.joined()
    }

    /// Stable across launches (`hashValue` is not): the same name always gets the same colour.
    var index: Int { Int(name.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % UInt32(Self.palette.count)) }

    static let palette: [(top: Color, bottom: Color)] = [
        (Color(red: 0.98, green: 0.60, blue: 0.35), Color(red: 0.93, green: 0.40, blue: 0.20)),
        (Color(red: 0.38, green: 0.78, blue: 0.55), Color(red: 0.20, green: 0.62, blue: 0.40)),
        (Color(red: 0.42, green: 0.65, blue: 0.98), Color(red: 0.25, green: 0.45, blue: 0.90)),
        (Color(red: 0.72, green: 0.52, blue: 0.95), Color(red: 0.52, green: 0.34, blue: 0.85)),
        (Color(red: 0.97, green: 0.50, blue: 0.65), Color(red: 0.88, green: 0.30, blue: 0.48)),
        (Color(red: 0.35, green: 0.78, blue: 0.82), Color(red: 0.20, green: 0.60, blue: 0.68)),
        (Color(red: 0.98, green: 0.80, blue: 0.35), Color(red: 0.92, green: 0.62, blue: 0.15)),
        (Color(red: 0.62, green: 0.66, blue: 0.74), Color(red: 0.45, green: 0.50, blue: 0.60)),
    ]
}
