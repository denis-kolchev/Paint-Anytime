import SwiftUI

struct LayerTransparencyLockIcon: View {
    let isLocked: Bool

    var body: some View {
        if isLocked {
            if #available(watchOS 26.0, *) {
                Image(systemName: "lock.square.dashed")
            } else {
                // Recreate the newer symbol using symbols available on watchOS 10 and 11.
                Image(systemName: "square.dashed")
                    .overlay {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .regular))
                    }
            }
        } else {
            Image(systemName: "square.dashed")
        }
    }
}
