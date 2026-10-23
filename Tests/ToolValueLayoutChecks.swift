import Foundation

@main
struct ToolValueLayoutChecks {
    static func main() {
        for height in 0...300 {
            let metrics = ToolValueControlMetrics(availableHeight: CGFloat(height))
            let total = metrics.buttonHeight * 2 + metrics.valueHeight + metrics.spacing * 2
            precondition(total <= min(CGFloat(height), 112) + 0.001)
            precondition(metrics.spacing >= 0 && metrics.buttonHeight >= 0 && metrics.valueHeight >= 0)
            // Equal button heights and gaps place the value at the exact center.
            let valueCenter = metrics.buttonHeight + metrics.spacing + metrics.valueHeight / 2
            precondition(abs(valueCenter - total / 2) < 0.001)
        }
        let regular = ToolValueControlMetrics(availableHeight: 180)
        precondition(regular.spacing == 8 && regular.buttonHeight == 30 && regular.valueHeight == 36)
        let compact = ToolValueControlMetrics(availableHeight: 72)
        precondition(compact.spacing == 0 && compact.buttonHeight == 26 && compact.valueHeight == 20)
        let withoutGaps = ToolValueControlMetrics(availableHeight: 96)
        precondition(withoutGaps.spacing == 0 && withoutGaps.buttonHeight == 30 && withoutGaps.valueHeight == 36)
        print("Tool value layout checks passed: bounds, symmetry, and continuous compact layout.")
    }
}
