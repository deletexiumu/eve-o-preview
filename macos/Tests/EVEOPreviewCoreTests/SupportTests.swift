// SPDX-License-Identifier: GPL-3.0-or-later
//
// HexColor、RetryPolicy 与几何辅助方法的用例。

import Testing
import EVEOPreviewCore

/// 颜色解析、重试延迟与矩形运算。
struct SupportTests {
    /// 合法的 `#RRGGBB`：不区分大小写，`#` 可省略。
    @Test func hexColorValid() throws {
        let green = try #require(HexColor.components("#ADFF2F"))
        #expect(abs(green.red - 173.0 / 255) < 1e-12 && green.green == 1 && abs(green.blue - 47.0 / 255) < 1e-12)
        #expect(HexColor.components("ffffff")?.blue == 1)
        #expect(HexColor.components(" #000000 ")?.red == 0)
    }

    /// 非法写法返回 nil。
    @Test(arguments: ["", "#FFF", "#GGGGGG", "#FFFFFFFF", "red", "#12345", "##FFFFFF", "#+12345"])
    func hexColorInvalid(text: String) {
        #expect(HexColor.components(text) == nil)
    }

    /// 分量格式化为大写的 `#RRGGBB`，越界分量被夹取。
    @Test func hexColorFormat() {
        #expect(HexColor.string(red: 1, green: 0.5, blue: 0) == "#FF8000")
        #expect(HexColor.string(red: 2, green: -1, blue: .nan) == "#FF0000")
    }

    /// 重试延迟：0.5、1、2、4、8，之后一直是 8 秒；attempt 小于 1 按 1 处理。
    @Test func retryDelays() {
        #expect((1...7).map(RetryPolicy.delay(forAttempt:)) == [0.5, 1, 2, 4, 8, 8, 8])
        #expect(RetryPolicy.delay(forAttempt: 0) == 0.5)
        #expect(RetryPolicy.delay(forAttempt: Int.max) == 8)
    }

    /// 相交只算面积大于 0 的重叠；共享一条边不算。
    @Test func rectIntersection() {
        let a = ScreenRect(x: 0, y: 0, width: 100, height: 100)
        #expect(a.intersection(ScreenRect(x: 50, y: 50, width: 100, height: 100))
            == ScreenRect(x: 50, y: 50, width: 50, height: 50))
        #expect(!a.intersects(ScreenRect(x: 100, y: 0, width: 10, height: 10)))
        #expect(a.contains(ScreenPoint(x: 0, y: 0)) && !a.contains(ScreenPoint(x: 100, y: 50)))
    }

    /// 主屏：没有标记时取第一块；按点查找屏幕。
    @Test func screenLookup() {
        var unmarked = Fixtures.leftScreen
        unmarked.isMain = false
        #expect([unmarked, Fixtures.mainScreen].mainScreen == Fixtures.mainScreen)
        #expect([unmarked].mainScreen == unmarked)
        #expect([Fixtures.mainScreen, Fixtures.leftScreen].screen(containing: ScreenPoint(x: -10, y: 10))
            == Fixtures.leftScreen)
        #expect([ScreenInfo]().mainScreen == nil)
    }
}
