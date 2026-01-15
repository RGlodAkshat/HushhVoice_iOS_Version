import Foundation

struct ProfileData: Equatable {
    var fullName: String = ""
    var phone: String = ""
    var email: String = ""

    var isComplete: Bool {
        !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && email.contains("@")
    }
}
