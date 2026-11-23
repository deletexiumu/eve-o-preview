// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppEnvironmentRules 的用例（v1.1 设计 4.2 节的两张规则表、14.1 节）。

import Testing
import EVEOPreviewCore

/// 签名类别与安装位置类别的规则。
struct AppEnvironmentRulesTests {
    /// 测试用的主目录。
    private let home = "/Users/tester"

    /// 位置类别的简写：只读卷默认为否。
    private func location(_ path: String?, readOnly: Bool = false) -> InstallLocationKind {
        AppEnvironmentRules.locationKind(bundlePath: path, homeDirectory: home, isReadOnlyVolume: readOnly)
    }

    // MARK: - signatureKind

    /// 没签名时其余参数都不看。
    @Test func unsignedWins() {
        #expect(AppEnvironmentRules.signatureKind(isSigned: false, isAdHoc: true,
                                                  signerName: AppEnvironmentRules.releaseSignerName) == .unsigned)
    }

    /// ad-hoc 先于证书名判断。
    @Test func adHocBeforeSignerName() {
        #expect(AppEnvironmentRules.signatureKind(isSigned: true, isAdHoc: true,
                                                  signerName: AppEnvironmentRules.releaseSignerName) == .adHoc)
    }

    /// 发布证书的通用名称完全相等时是 release。
    @Test func releaseSigner() {
        #expect(AppEnvironmentRules.releaseSignerName == "EVE-O Preview Release")
        #expect(AppEnvironmentRules.signatureKind(isSigned: true, isAdHoc: false,
                                                  signerName: "EVE-O Preview Release") == .release)
    }

    /// 其他证书（含本机的开发证书、名字只差大小写、没有名字）都是 development。
    @Test(arguments: ["EVEO Preview Dev", "eve-o preview release", nil] as [String?])
    func otherSignersAreDevelopment(name: String?) {
        #expect(AppEnvironmentRules.signatureKind(isSigned: true, isAdHoc: false, signerName: name) == .development)
    }

    // MARK: - locationKind

    /// 没有包路径（`swift run`）。
    @Test func notBundled() {
        #expect(location(nil) == .notBundled)
        #expect(location(nil, readOnly: true) == .notBundled)
    }

    /// 转移运行的真实路径形式，先于只读卷判断（转移运行的路径本身也在只读卷上）。
    @Test func translocated() {
        let path = "/private/var/folders/xy/abc123/T/AppTranslocation/1A2B3C4D-0000-1111-2222-333344445555/d/EVE-O Preview.app"
        #expect(location(path) == .translocated)
        #expect(location(path, readOnly: true) == .translocated)
    }

    /// 只读卷（直接从 dmg 打开），先于 /Applications 判断。
    @Test func readOnlyVolume() {
        #expect(location("/Volumes/EVE-O Preview/EVE-O Preview.app", readOnly: true) == .readOnlyVolume)
        #expect(location("/Applications/EVE-O Preview.app", readOnly: true) == .readOnlyVolume)
    }

    /// /Applications 下（含子目录）。
    @Test func applications() {
        #expect(location("/Applications/EVE-O Preview.app") == .applications)
        #expect(location("/Applications/Games/EVE-O Preview.app") == .applications)
    }

    /// ~/Applications 下；主目录末尾带不带 `/` 都一样。
    @Test func userApplications() {
        #expect(location("/Users/tester/Applications/EVE-O Preview.app") == .userApplications)
        #expect(AppEnvironmentRules.locationKind(bundlePath: "/Users/tester/Applications/EVE-O Preview.app",
                                                 homeDirectory: "/Users/tester/", isReadOnlyVolume: false)
            == .userApplications)
    }

    /// 其他位置：下载文件夹、别的用户的应用程序文件夹、名字只是前缀相同的目录。
    @Test func otherLocations() {
        #expect(location("/Users/tester/Downloads/EVE-O Preview.app") == .other)
        #expect(location("/Users/someone/Applications/EVE-O Preview.app") == .other)
        #expect(location("/ApplicationsExtra/EVE-O Preview.app") == .other)
        #expect(location("/Users/testerX/Applications/EVE-O Preview.app") == .other)
        #expect(AppEnvironmentRules.locationKind(bundlePath: "/Users/tester/Applications/EVE-O Preview.app",
                                                 homeDirectory: "", isReadOnlyVolume: false) == .other)
    }
}
