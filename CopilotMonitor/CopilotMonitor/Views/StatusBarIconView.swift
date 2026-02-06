import AppKit

// MARK: - Status Bar Icon View
final class StatusBarIconView: NSView {
    private var addOnCost: Double = 0
    private var isLoading = false
    private var hasError = false
    private var overrideText: String?
    private var iconOnlyMode = false

    /// Text to display when cost is zero (avoids duplication between sizing and drawing)
    private var zeroCostStatusText: String {
        if isLoading {
            return "..."
        } else if hasError {
            return "Err"
        } else if let text = overrideText {
            return text
        } else {
            return "OC Bar"
        }
    }

    private var textColor: NSColor {
        guard let button = self.superview as? NSStatusBarButton else {
            return .white
        }
        return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }

    /// Dynamic width calculation based on content
    /// - Copilot icon (16px) + padding (6px) = 22px base
    /// - With add-on cost: icon + cost text width
    /// - Without add-on cost: icon + "OC Bar" text width
    /// - Icon only mode: just icon width
    override var intrinsicContentSize: NSSize {
        let baseIconWidth = MenuDesignToken.Dimension.itemHeight // icon (16) + right padding (6)

        if iconOnlyMode && !isLoading && !hasError {
            return NSSize(width: baseIconWidth - 2, height: 23)
        }

        if addOnCost > 0 {
            // Calculate cost text width dynamically
            let costText = formatCost(addOnCost)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            let textWidth = (costText as NSString).size(withAttributes: [.font: font]).width
            return NSSize(width: baseIconWidth + textWidth + 4, height: 23)
        } else {
            // "OC Bar" or custom text width
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let textWidth = (zeroCostStatusText as NSString).size(withAttributes: [.font: font]).width
            return NSSize(width: baseIconWidth + textWidth + 4, height: 23)
        }
    }

    func update(cost: Double = 0) {
        addOnCost = cost
        isLoading = false
        hasError = false
        overrideText = nil
        iconOnlyMode = false
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func update(displayText: String) {
        overrideText = displayText
        addOnCost = 0
        isLoading = false
        hasError = false
        iconOnlyMode = false
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func updateIconOnly() {
        iconOnlyMode = true
        addOnCost = 0
        isLoading = false
        hasError = false
        overrideText = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func showLoading() {
        isLoading = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func showError() {
        hasError = true
        isLoading = false
        addOnCost = 0  // Reset add-on cost to hide dollar sign
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let color = textColor
        let yOffset: CGFloat = 4

        drawCopilotIcon(at: NSPoint(x: 2, y: yOffset), size: 16, color: color)

        if iconOnlyMode && !isLoading && !hasError {
            return
        }

        if addOnCost > 0 {
            drawCostText(at: NSPoint(x: 22, y: yOffset), color: color)
        } else {
            drawOCBarText(at: NSPoint(x: 22, y: yOffset), color: color)
        }
    }

    private func drawCopilotIcon(at origin: NSPoint, size: CGFloat, color: NSColor) {
        guard let icon = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Usage") else { return }
        icon.isTemplate = true

        let tintedImage = NSImage(size: icon.size)
        tintedImage.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: icon.size)
        imageRect.fill()
        icon.draw(in: imageRect, from: .zero, operation: .destinationIn, fraction: 1.0)
        tintedImage.unlockFocus()
        tintedImage.isTemplate = false

        let iconRect = NSRect(x: origin.x, y: origin.y, width: size, height: size)
        tintedImage.draw(in: iconRect)
    }

    private func drawOCBarText(at origin: NSPoint, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let attrString = NSAttributedString(string: zeroCostStatusText, attributes: attributes)
        attrString.draw(at: origin)
    }

    private func drawCostText(at origin: NSPoint, color: NSColor) {
        let text = formatCost(addOnCost)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        attrString.draw(at: origin)
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 10 {
            return String(format: "$%.1f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}
