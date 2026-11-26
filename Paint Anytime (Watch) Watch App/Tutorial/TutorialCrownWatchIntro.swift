import SwiftUI

/// One turn of the Crown hint: up, short hold, back down, rest.
/// Shared by the pill beside the physical Crown and the mini-watch intro.
enum TutorialCrownTurn {
    struct Phase {
        var travel: Double
        var turningUp: Bool
        var turningDown: Bool
    }

    static func phase(at time: TimeInterval, cycle: Double, still: Bool) -> Phase {
        guard !still else { return Phase(travel: 0, turningUp: false, turningDown: false) }
        let time = max(0, time).truncatingRemainder(dividingBy: cycle)
        let travel = time < 0.85 ? time / 0.85
            : time < 1 ? 1 : time < 1.85 ? 1 - (time - 1) / 0.85 : 0
        return Phase(travel: travel, turningUp: time < 0.85, turningDown: time >= 1 && time < 1.85)
    }
}

/// A Crown seen from the side: ribs projected around a cylinder emerge at one edge,
/// cross the face and disappear around the other edge as `travel` grows.
struct TutorialCrownCylinder: View {
    var travel: Double
    var cornerRadius: CGFloat = 3
    var ribInset: CGFloat = 2
    var ribScale: CGFloat = 1

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.45), .white.opacity(0.15)],
                                     startPoint: .top, endPoint: .bottom))
            Canvas { context, size in
                for rib in 0..<10 {
                    let angle = Double(rib) * .pi / 5 - travel * .pi * 1.2
                    let depth = cos(angle)
                    guard depth > 0 else { continue }
                    let y = size.height / 2 + sin(angle) * (size.height / 2 - 1)
                    var line = Path()
                    line.move(to: CGPoint(x: ribInset, y: y))
                    line.addLine(to: CGPoint(x: size.width - ribInset, y: y))
                    context.stroke(line, with: .color(.white.opacity(0.3 + 0.7 * depth)),
                                   lineWidth: (0.7 + 0.5 * depth) * ribScale)
                }
            }
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.white.opacity(0.85), lineWidth: 1)
        }
    }
}

/// A stylized watch whose Crown turns, shown in the basic course's zoom lesson at the
/// centre of the screen before the hint settles into the pill beside the physical Crown. Drawn from shapes only:
/// no product imagery, no recognizable watch face.
struct TutorialCrownWatchIntro: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    /// Every dimension is laid out at this multiple, so shapes stay sharp at any size.
    private let k: CGFloat = 1.45

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let turn = TutorialCrownTurn.phase(at: timeline.date.timeIntervalSince(startedAt),
                                               cycle: 2.8, still: reduceMotion)
            watch(turn)
        }
        .padding(.vertical, 8 * k)
        .padding(.leading, 12 * k)
        .padding(.trailing, 8 * k)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18 * k, style: .continuous))
    }

    private func watch(_ turn: TutorialCrownTurn.Phase) -> some View {
        HStack(alignment: .top, spacing: 1 * k) {
            VStack(spacing: -3 * k) {
                strap
                ZStack {
                    RoundedRectangle(cornerRadius: 15 * k, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 11 * k, style: .continuous)
                        .fill(.black)
                        .padding(4 * k)
                    screenContent(turn.travel)
                        .padding(10 * k)
                }
                .frame(width: 50 * k, height: 60 * k)
                strap
            }
            VStack(spacing: 3 * k) {
                TutorialCrownCylinder(travel: turn.travel, cornerRadius: 2.5 * k,
                                      ribInset: 1.5 * k, ribScale: 0.8 * k)
                    .frame(width: 7 * k, height: 15 * k)
                Capsule()
                    .fill(Color(white: 0.35))
                    .frame(width: 3.5 * k, height: 13 * k)
            }
            .padding(.top, 25 * k)
            VStack(spacing: 4 * k) {
                Image(systemName: "chevron.up")
                    .opacity(reduceMotion || turn.turningUp ? 1 : 0.3)
                Image(systemName: "chevron.down")
                    .opacity(reduceMotion || turn.turningDown ? 1 : 0.3)
            }
            .font(.system(size: 8 * k, weight: .bold))
            .foregroundStyle(.white)
            .padding(.top, 24 * k)
            .padding(.leading, 2 * k)
        }
    }

    private var strap: some View {
        RoundedRectangle(cornerRadius: 4 * k, style: .continuous)
            .fill(Color(white: 0.28))
            .frame(width: 32 * k, height: 14 * k)
    }

    /// The screen shows what the Crown does: content grows while it turns up.
    private func screenContent(_ travel: Double) -> some View {
        Circle()
            .fill(.white.opacity(0.85))
            .frame(width: 10 * k, height: 10 * k)
            .scaleEffect(1 + travel * 1.2)
    }
}
