import XCTest
@testable import OpenCode_Bar

final class MenuDesignTokenTests: XCTestCase {
    func testDimensionValues() {
        XCTAssertEqual(MenuDesignToken.Dimension.menuWidth, 300)
        XCTAssertEqual(MenuDesignToken.Dimension.itemHeight, 22)
        XCTAssertEqual(MenuDesignToken.Dimension.fontSize, 13)
        XCTAssertEqual(MenuDesignToken.Dimension.iconSize, 16)
        XCTAssertEqual(MenuDesignToken.Dimension.geminiIconSize, 17)
        XCTAssertEqual(MenuDesignToken.Dimension.statusDotSize, 8)
    }
    
    func testSpacingValues() {
        XCTAssertEqual(MenuDesignToken.Spacing.leadingOffset, 14)
        XCTAssertEqual(MenuDesignToken.Spacing.leadingWithIcon, 36)
        XCTAssertEqual(MenuDesignToken.Spacing.trailingMargin, 14)
        XCTAssertEqual(MenuDesignToken.Spacing.textYOffset, 3)
        XCTAssertEqual(MenuDesignToken.Spacing.iconYOffset, 3)
    }
    
    func testComputedValues() {
        // rightElementX = 300 - 14 - 16 = 270
        XCTAssertEqual(MenuDesignToken.rightElementX, 270)
    }
    
    func testTypography() {
        XCTAssertNotNil(MenuDesignToken.Typography.defaultFont)
        XCTAssertNotNil(MenuDesignToken.Typography.monospacedFont)
        XCTAssertNotNil(MenuDesignToken.Typography.boldFont)
        
        // Verify font sizes are correct
        XCTAssertEqual(MenuDesignToken.Typography.defaultFont.pointSize, 13)
        XCTAssertEqual(MenuDesignToken.Typography.monospacedFont.pointSize, 13)
        XCTAssertEqual(MenuDesignToken.Typography.boldFont.pointSize, 13)
    }
}
