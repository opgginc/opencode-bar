import AppKit

// MARK: - Provider Alert
/// Alert data for a provider with low quota
struct ProviderAlert {
    let identifier: ProviderIdentifier
    let remainingPercent: Double
}



/// Multi-provider status bar icon view
/// Displays: [$XXX 🔴ClaudeIcon 5% 🔴GeminiIcon 8%]
final class MultiProviderStatusBarIconView: NSView {
    private var totalOverageCost: Double = 0
    private var alerts: [ProviderAlert] = []
    private var isLoading = false
    private var hasError = false

    /// Dynamic width calculation based on content
    /// Base: $ icon (16px) + padding (6px) = 22px
    /// Cost text: variable width
    /// Per alert: icon (14px) + space (2px) + percent text + padding (4px)
    override var intrinsicContentSize: NSSize {
        let baseIconWidth = MenuDesignToken.Dimension.itemHeight // $ icon + padding

        if isLoading || hasError {
            let text = isLoading ? "..." : "Err"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            return NSSize(width: baseIconWidth + textWidth + 4, height: 23)
        }

        // Calculate cost text width
        let costText = formatCost(totalOverageCost)
        let costFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let costWidth = (costText as NSString).size(withAttributes: [.font: costFont]).width

        var totalWidth = baseIconWidth + costWidth + 4

        // Add width for each alert
        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        for alert in alerts {
            let percentText = String(format: "%.0f%%", alert.remainingPercent)
            let percentWidth = (percentText as NSString).size(withAttributes: [.font: percentFont]).width
            totalWidth += 14 + 2 + percentWidth + 4 // icon + space + text + padding
        }

        return NSSize(width: totalWidth, height: 23)
    }

    func update(overageCost: Double, alerts: [ProviderAlert]) {
        self.totalOverageCost = overageCost
        self.alerts = alerts
        self.isLoading = false
        self.hasError = false
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func showLoading() {
        isLoading = true
        hasError = false
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func showError() {
        hasError = true
        isLoading = false
        totalOverageCost = 0
        alerts = []
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Use view's own appearance to detect menu bar background (not app appearance)
        let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        var xOffset: CGFloat = 2
        let yOffset: CGFloat = 5

        drawDollarIcon(at: NSPoint(x: xOffset, y: yOffset), isDark: isDark)
        xOffset += 20

        if isLoading {
            drawText("...", at: NSPoint(x: xOffset, y: yOffset), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), isDark: isDark)
            return
        }

        if hasError {
            drawText("Err", at: NSPoint(x: xOffset, y: yOffset), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), isDark: isDark)
            return
        }

        let costText = formatCost(totalOverageCost)
        let costFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        drawText(costText, at: NSPoint(x: xOffset, y: yOffset), font: costFont, isDark: isDark)

        let costWidth = (costText as NSString).size(withAttributes: [.font: costFont]).width
        xOffset += costWidth + 4

        for alert in alerts {
            drawProviderAlert(alert, at: NSPoint(x: xOffset, y: yOffset), isDark: isDark)

            let percentText = String(format: "%.0f%%", alert.remainingPercent)
            let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            let percentWidth = (percentText as NSString).size(withAttributes: [.font: percentFont]).width

            xOffset += 14 + 2 + percentWidth + 4
        }
    }

    private func drawDollarIcon(at origin: NSPoint, isDark: Bool) {
        let text = "$"
        let font = NSFont.boldSystemFont(ofSize: 14)
        // Use adaptive color for light/dark mode visibility
        let textColor = isDark ? NSColor.white : NSColor.black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        attrString.draw(at: origin)
    }

    private func drawProviderAlert(_ alert: ProviderAlert, at origin: NSPoint, isDark: Bool) {
        let iconName: String
        switch alert.identifier {
        case .claude:
            iconName = "ClaudeIcon"
        case .codex:
            iconName = "CodexIcon"
        case .geminiCLI:
            iconName = "GeminiIcon"
        case .copilot:
            iconName = "CopilotIcon"
        case .openRouter:
            // No OpenRouterIcon asset exists, use SF Symbol fallback
            iconName = "dollarsign.circle"
        case .openCode:
            // Asset is named "OpencodeIcon" (lowercase 'c')
            iconName = "OpencodeIcon"
        case .antigravity:
            iconName = "AntigravityIcon"
        case .openCodeZen:
            iconName = "OpencodeIcon"
        case .kimi:
            iconName = "k.circle"
        }

        guard let icon = NSImage(named: iconName) else {
            // Fallback: draw colored circle
            drawAlertCircle(at: origin, isDark: isDark)
            return
        }

        // Tint icon red for alert
        icon.isTemplate = true
        let tintedImage = NSImage(size: icon.size)
        tintedImage.lockFocus()
        NSColor.systemRed.set()
        let imageRect = NSRect(origin: .zero, size: icon.size)
        imageRect.fill()
        icon.draw(in: imageRect, from: .zero, operation: .destinationIn, fraction: 1.0)
        tintedImage.unlockFocus()
        tintedImage.isTemplate = false

        let iconRect = NSRect(x: origin.x, y: origin.y, width: 14, height: 14)
        tintedImage.draw(in: iconRect)

        // Draw percentage text next to icon
        let percentText = String(format: "%.0f%%", alert.remainingPercent)
        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        drawText(percentText, at: NSPoint(x: origin.x + 16, y: origin.y), font: percentFont, isDark: isDark)
    }

    private func drawAlertCircle(at origin: NSPoint, isDark: Bool) {
        let rect = NSRect(x: origin.x, y: origin.y, width: 14, height: 14)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.systemRed.setFill()
        path.fill()
    }

    private func drawText(_ text: String, at origin: NSPoint, font: NSFont, isDark: Bool) {
        // Use adaptive color for light/dark mode visibility
        let textColor = isDark ? NSColor.white : NSColor.black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        attrString.draw(at: origin)
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 10 {
            return String(format: "%.1f", cost)
        } else if cost > 0 {
            return String(format: "%.2f", cost)
        } else {
            return "0"
        }
    }
}
