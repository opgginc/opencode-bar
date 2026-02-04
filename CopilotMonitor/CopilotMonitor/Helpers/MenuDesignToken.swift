import AppKit

/// Centralized design tokens for menu bar UI layout and typography.
/// All custom menu item views MUST use these constants to ensure visual consistency.
enum MenuDesignToken {
    /// Standard dimensions for menu items and UI elements
    enum Dimension {
        /// Menu width in points (standard macOS menu width)
        static let menuWidth: CGFloat = 300
        
        /// Standard menu item height in points
        static let itemHeight: CGFloat = 22
        
        /// Standard font size for menu items
        static let fontSize: CGFloat = 13
        
        /// Standard SF Symbol icon size
        static let iconSize: CGFloat = 16
        
        /// Status indicator dot size (e.g., circle.fill for status)
        static let statusDotSize: CGFloat = 8
    }
    
    /// Spacing and margin constants for layout
    enum Spacing {
        /// Left margin for text without icon
        static let leadingOffset: CGFloat = 14
        
        /// Left margin when icon is present
        static let leadingWithIcon: CGFloat = 36
        
        /// Right margin for menu items
        static let trailingMargin: CGFloat = 14
        
        /// Indent for sub-items within a menu section (e.g., reset time under usage row)
        static let submenuIndent: CGFloat = 18
        
        /// Y position offset for single-line text
        static let textYOffset: CGFloat = 3
        
        /// Y position offset for icons
        static let iconYOffset: CGFloat = 3
    }
    
    /// Typography helpers for consistent font usage
    enum Typography {
        /// Default system font at standard size
        static var defaultFont: NSFont {
            NSFont.systemFont(ofSize: Dimension.fontSize)
        }
        
        /// Monospaced font for numeric values and code
        static var monospacedFont: NSFont {
            NSFont.monospacedSystemFont(ofSize: Dimension.fontSize, weight: .regular)
        }
        
        /// Bold system font for emphasis
        static var boldFont: NSFont {
            NSFont.boldSystemFont(ofSize: Dimension.fontSize)
        }
    }
    
    /// Computed X position for right-aligned elements
    /// Calculation: menuWidth - trailingMargin - iconSize = 300 - 14 - 16 = 270
    static var rightElementX: CGFloat {
        Dimension.menuWidth - Spacing.trailingMargin - Dimension.iconSize
    }
}
