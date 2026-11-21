// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的韩文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与协议一致，每条的用途见 UpdateStrings.swift。
// 用词按 v1.1 设计 11.3 节的词表：업데이트、업데이트 확인…、릴리스 노트、업데이트 설치、이 버전 건너뛰기、
// 나중에、서명；缩略图 썸네일（反馈文档 5.5 节）。「重新启动」与现有的权限页一致写 다시 실행，
// 「应用程序」文件夹写 응용 프로그램 폴더（同 1.0.0 的韩文发布说明）。
// 文体同 Strings+ko.swift：说明句用 -습니다/-십시오 体，按钮与标签用名词形。
// 版本号后面接 버전，避免按版本号的读音选助词。

import Foundation

/// 更新域的韩文实现。
struct UpdateStringsKO: UpdateStrings {
    // MARK: 菜单栏菜单

    var menuCheckForUpdates: String { "업데이트 확인…" }
    func menuUpdateAvailable(_ version: String) -> String { "업데이트 사용 가능: \(version)…" }
    func menuRestartToUpdate(_ version: String) -> String { "다시 실행하여 \(version) 버전으로 업데이트" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "업데이트" }
    var autoCheckToggle: String { "자동으로 업데이트 확인" }
    var autoCheckHelp: String { "하루에 한 번 GitHub에 접속합니다. 개인 정보는 전송되지 않습니다." }
    var autoInstallToggle: String { "자동으로 업데이트 설치" }
    var autoInstallHelp: String { "백그라운드에서 다운로드합니다. EVE 클라이언트가 1분 동안 실행되지 않으면 설치하고 다시 실행하며, EVE-O Preview를 종료할 때도 설치합니다." }
    var currentVersionLabel: String { "현재 버전" }
    var lastCheckedLabel: String { "마지막 확인" }
    var lastCheckedNever: String { "확인한 적 없음" }
    var checkNowButton: String { "지금 확인" }

    // MARK: 状态行

    var statusChecking: String { "확인 중…" }
    var statusUpToDate: String { "EVE-O Preview가 최신 버전입니다." }
    func statusAvailable(_ version: String) -> String { "\(version) 버전을 사용할 수 있습니다." }
    func statusReady(_ version: String) -> String { "\(version) 버전이 다운로드되었으며 종료할 때 설치됩니다." }
    func statusRateLimited(_ time: String) -> String {
        "GitHub가 요청을 제한하고 있습니다. \(time) 이후에 다시 시도하십시오."
    }
    var statusRateLimitedLater: String { "GitHub가 요청을 제한하고 있습니다. 나중에 다시 시도하십시오." }
    var statusUnavailable: String { "이 빌드에서는 업데이트를 사용할 수 없습니다." }

    // MARK: 更新窗口

    var windowTitle: String { "소프트웨어 업데이트" }
    func headline(_ version: String) -> String { "EVE-O Preview \(version) 사용 가능" }
    func currentVersionLine(_ version: String) -> String { "현재 \(version) 버전을 사용하고 있습니다." }
    var releaseNotesHeader: String { "새로운 기능" }
    var installButton: String { "업데이트 설치" }
    var installHelp: String { "설치 후 앱이 다시 실행됩니다. 썸네일이 몇 초 동안 사라집니다." }
    var skipButton: String { "이 버전 건너뛰기" }
    var laterButton: String { "나중에" }
    var openReleasePageButton: String { "릴리스 페이지 열기" }
    var cancelButton: String { "취소" }
    var closeButton: String { "닫기" }
    var retryButton: String { "다시 시도" }
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "다운로드 중… \(received) / \($0)" } ?? "다운로드 중… \(received)"
    }
    var progressVerifying: String { "검증 중…" }
    var progressInstalling: String { "설치 중…" }
    var progressRelaunching: String { "다시 실행 중…" }
    var testFeedBadge: String { "테스트 주소" }
    var notifyOnlyIntro: String { "이 사본은 스스로 업데이트할 수 없습니다." }
    var currentVersionUnchanged: String { "현재 버전은 바뀌지 않았습니다." }
    var reopenManually: String { "업데이트가 설치되었습니다. EVE-O Preview를 종료한 후 다시 여십시오." }

    // MARK: 不能自动安装的原因

    var blockerTranslocated: String {
        "macOS가 임시 읽기 전용 위치에서 앱을 실행하고 있습니다. 앱을 응용 프로그램 폴더로 옮긴 후 다시 여십시오."
    }
    var blockerReadOnlyVolume: String { "앱이 읽기 전용 디스크에 있습니다. 먼저 응용 프로그램 폴더로 복사하십시오." }
    var blockerLocationNotWritable: String { "앱이 들어 있는 폴더를 변경할 권한이 없습니다." }
    var blockerAdHocSignature: String { "이 빌드에는 고정된 서명이 없어 새 버전을 검증할 수 없습니다." }
    var blockerDevelopmentSignature: String { "로컬에서 서명한 개발용 빌드입니다." }
    var blockerUnsigned: String { "이 빌드는 서명되지 않았습니다." }

    // MARK: 错误

    var errorNetwork: String { "GitHub에 연결할 수 없습니다. 인터넷 연결을 확인하십시오." }
    func errorHTTPStatus(_ code: Int) -> String { "GitHub가 오류를 반환했습니다(\(code))." }
    var errorMalformedFeed: String { "릴리스 정보를 읽을 수 없습니다." }
    var errorAssetMissing: String { "이 릴리스에는 자동 업데이트용 설치 파일이 없습니다." }
    var errorDiskSpace: String { "다운로드에 필요한 디스크 공간이 부족합니다." }
    var errorChecksum: String { "다운로드한 파일이 체크섬과 일치하지 않아 삭제했습니다." }
    var errorDiskImage: String { "다운로드한 디스크 이미지를 열 수 없습니다." }
    var errorVerification: String { "새 버전을 검증할 수 없어 설치하지 않았습니다." }
    func errorUnsupportedSystem(_ minimum: String) -> String { "이 버전에는 macOS \(minimum) 이상이 필요합니다." }
    var errorSwapFailed: String { "앱을 교체할 수 없습니다." }
}
