import SwiftUI

/// Small pill showing a task's repeat frequency (e.g. weekly, once), matching
/// the browser's repeat badge. Hidden for the default "daily".
struct RepeatBadge: View {
    let task: KidTask

    var body: some View {
        if let r = task.repeatBadge {
            Text(r)
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        }
    }
}
