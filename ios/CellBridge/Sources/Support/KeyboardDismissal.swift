import SwiftUI
import UIKit

extension View {
    /// The keyboard goes away when the content is scrolled, and a Done button sits above it
    /// (the phone pad has no return key).
    func dismissibleKeyboard() -> some View {
        scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
    }
}
