import SwiftUI

/// One set of measurements for every list that shows people, so Messages, Contacts and the pickers line up the same way:
/// the avatar sits on the screen gutter, the text starts [textInset] from it, and the separator starts with the text.
enum ListRow {
    static let avatar: CGFloat = 44
    static let spacing: CGFloat = 12
    static var textInset: CGFloat { avatar + spacing }
}

extension View {
    /// The row separator starts where the text does, not under the avatar (the system would guess, and guesses differently per row).
    func avatarRowSeparator() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + ListRow.textInset }
    }
}
