import Foundation

struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: PresentedError, rhs: PresentedError) -> Bool {
        lhs.id == rhs.id
    }
}
