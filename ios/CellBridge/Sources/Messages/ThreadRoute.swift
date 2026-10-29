import Foundation

/// One conversation to show: the key finds its texts, the peer is who to write to while there are none yet.
struct ThreadRoute: Hashable {
    let key: String
    let peer: String
    /// Opened from somewhere that means "write now" (a contact's Message button): the keyboard comes up.
    var focusesComposer = false
}
