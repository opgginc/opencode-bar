import AppKit
import os.log

private let statusBarIconLogger = Logger(subsystem: "com.opencodeproviders", category: "StatusBarIconView")

// MARK: - Status Bar Icon View
final class StatusBarIconView: NSView {
    private var addOnCost: Double = 0
    private var overrideText: String?
    private var iconOnlyMode = false
    private var isCriticalBadgeVisible = false
    private var isLoading = false
    private var hasError = false
    private var loadingAnimationTimer: Timer?
    private var loadingRotationDegrees: CGFloat = 0

    /// Called whenever the intrinsic width may have changed.
    var onIntrinsicContentSizeDidChange: (() -> Void)?

    private let leftPadding: CGFloat = 2
    private let iconSize: CGFloat = 16
    private let textSpacing: CGFloat = 4
    private let trailingPadding: CGFloat = 2
    private let statusBarHeight: CGFloat = 23
    private let loadingAnimationInterval: TimeInterval = 0.07
    private let loadingRotationStepDegrees: CGFloat = 30
    private let criticalBadgeSize: CGFloat = 6
    private let criticalBadgeInset: CGFloat = 1

    /// Nil means icon-only rendering (no text reservation).
    private var statusText: String? {
        if isLoading {
            return nil
        } else if hasError {
            return "Err"
        } else if iconOnlyMode {
            return nil
        } else if let overrideText {
            return overrideText
        } else if addOnCost > 0 {
            return formatCost(addOnCost)
        } else {
            return nil
        }
    }

    private var statusTextFont: NSFont {
        if hasError {
            return NSFont.systemFont(ofSize: 11, weight: .medium)
        }
        return NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    }

    private var currentIconSymbolName: String {
        isLoading ? "dollarsign.circle.fill" : "gauge.medium"
    }

    deinit {
        stopLoadingAnimation()
    }

    private var textColor: NSColor {
        guard let button = self.superview as? NSStatusBarButton else {
            return .white
        }
        return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }

    override var intrinsicContentSize: NSSize {
        let iconWidth = leftPadding + iconSize + trailingPadding

        guard let statusText else {
            return NSSize(width: iconWidth, height: statusBarHeight)
        }

        let textWidth = (statusText as NSString).size(withAttributes: [.font: statusTextFont]).width
        let totalWidth = iconWidth + textSpacing + textWidth + trailingPadding
        return NSSize(width: totalWidth, height: statusBarHeight)
    }

    func update(cost: Double = 0) {
        stopLoadingAnimation()
        addOnCost = cost
        overrideText = nil
        iconOnlyMode = false
        isLoading = false
        hasError = false
        redrawWithSizeUpdate()
    }

    func update(displayText: String) {
        stopLoadingAnimation()
        addOnCost = 0
        overrideText = displayText
        iconOnlyMode = false
        isLoading = false
        hasError = false
        redrawWithSizeUpdate()
    }

    func updateIconOnly() {
        stopLoadingAnimation()
        addOnCost = 0
        overrideText = nil
        iconOnlyMode = true
        isLoading = false
        hasError = false
        redrawWithSizeUpdate()
    }

    func setCriticalBadgeVisible(_ isVisible: Bool) {
        guard isCriticalBadgeVisible != isVisible else { return }
        isCriticalBadgeVisible = isVisible
        needsDisplay = true
    }

    func showLoading() {
        isLoading = true
        hasError = false
        overrideText = nil
        iconOnlyMode = false
        isCriticalBadgeVisible = false
        startLoadingAnimation()
        redrawWithSizeUpdate()
    }

    func showError() {
        stopLoadingAnimation()
        hasError = true
        isLoading = false
        addOnCost = 0
        overrideText = nil
        iconOnlyMode = false
        isCriticalBadgeVisible = false
        redrawWithSizeUpdate()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let color = textColor
        let yOffset: CGFloat = 4

        let iconOrigin = NSPoint(x: leftPadding, y: yOffset)
        drawCopilotIcon(at: iconOrigin, size: iconSize, color: color)
        drawCriticalBadgeIfNeeded(iconOrigin: iconOrigin, iconSize: iconSize)

        if let statusText {
            let textOrigin = NSPoint(x: leftPadding + iconSize + textSpacing, y: yOffset)
            drawStatusText(statusText, at: textOrigin, color: color)
        }
    }

    private func drawCopilotIcon(at origin: NSPoint, size: CGFloat, color: NSColor) {
        guard let icon = NSImage(systemSymbolName: currentIconSymbolName, accessibilityDescription: "Usage") else { return }
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
        drawIcon(tintedImage, in: iconRect)
    }

    private func drawStatusText(_ text: String, at origin: NSPoint, color: NSColor) {
        let font = statusTextFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        attrString.draw(at: origin)
    }

    private func drawCriticalBadgeIfNeeded(iconOrigin: NSPoint, iconSize: CGFloat) {
        guard isCriticalBadgeVisible, !isLoading, !hasError else { return }

        let badgeX = iconOrigin.x + iconSize - criticalBadgeSize + criticalBadgeInset
        let badgeY = iconOrigin.y + iconSize - criticalBadgeSize + criticalBadgeInset
        let badgeRect = NSRect(x: badgeX, y: badgeY, width: criticalBadgeSize, height: criticalBadgeSize)

        NSColor.systemRed.setFill()
        let path = NSBezierPath(ovalIn: badgeRect)
        path.fill()
    }

    private func redrawWithSizeUpdate() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onIntrinsicContentSizeDidChange?()
    }

    private func drawIcon(_ image: NSImage, in rect: NSRect) {
        guard isLoading else {
            image.draw(in: rect)
            return
        }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: loadingRotationDegrees)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func startLoadingAnimation() {
        guard loadingAnimationTimer == nil else { return }

        loadingRotationDegrees = 0
        let timer = Timer(timeInterval: loadingAnimationInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isLoading else {
                self.stopLoadingAnimation()
                return
            }

            self.loadingRotationDegrees = (self.loadingRotationDegrees + self.loadingRotationStepDegrees)
                .truncatingRemainder(dividingBy: 360)
            self.needsDisplay = true
        }

        loadingAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        statusBarIconLogger.info("Loading icon animation started")
    }

    private func stopLoadingAnimation() {
        guard let timer = loadingAnimationTimer else { return }
        timer.invalidate()
        loadingAnimationTimer = nil
        loadingRotationDegrees = 0
        statusBarIconLogger.info("Loading icon animation stopped")
    }

    private func formatCost(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }
}
