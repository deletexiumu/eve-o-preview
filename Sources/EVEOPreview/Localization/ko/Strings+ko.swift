// SPDX-License-Identifier: GPL-3.0-or-later
//
// 韩文界面文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见协议里的注释（Strings.swift、SettingsStrings.swift）。
//
// 用词的依据：
// - 反馈文档 5.5 节的词表：썸네일、클라이언트、프로필、순환 그룹、단축키、테두리、강조 표시 等。
// - EVE 韩文客户端的叫法：角色是 캐릭터，登录界面是 로그인 화면。
// - macOS 韩文的官方名称：「编辑」菜单各项取 AppKit 的 MenuCommands.loctable（윈도우 的写法也随系统）；
//   权限名取系统设置（화면 기록、손쉬운 사용），「系统设置 > 隐私与安全性」是
//   「시스템 설정 > 개인정보 보호 및 보안」，访达保留 Finder。
// - 文体：说明句用 -습니다/-십시오 体，按钮与标签用名词形。

import Foundation
import EVEOPreviewCore

// MARK: - 菜单栏

/// 菜单栏菜单，韩文。
struct MenuStringsKO: MenuStrings {
    var showAll: String { "모든 썸네일 보기" }
    var hideAll: String { "모든 썸네일 가리기" }
    var profiles: String { "프로필" }
    var minimizeAll: String { "모든 클라이언트 최소화" }
    var settings: String { "설정…" }
    var quit: String { "EVE-O Preview 종료" }
    var permissionsMissing: String { "권한이 부족합니다…" }
    var fakeMode: String { "데모 모드(가상 클라이언트)" }
    var noClients: String { "EVE 클라이언트를 찾을 수 없음" }
    func resumeCapture(_ title: String) -> String { "캡처 재개: \(title)" }
    // 韩文没有复数变化，用量词「개」。
    func clientCount(_ count: Int) -> String { "클라이언트 \(count)개" }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，韩文。全部取 macOS 韩文的菜单名。
struct EditMenuStringsKO: EditMenuStrings {
    var title: String { "편집" }
    var undo: String { "실행 취소" }
    var redo: String { "실행 복귀" }
    var cut: String { "오려두기" }
    var copy: String { "복사하기" }
    var paste: String { "붙여넣기" }
    var selectAll: String { "전체 선택" }
    var closeWindow: String { "윈도우 닫기" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，韩文。
struct ThumbnailStringsKO: ThumbnailStrings {
    var minimize: String { "최소화" }
    var minimizeAll: String { "모두 최소화" }
    var skipCycle: String { "순환에서 건너뛰기" }
    var hide: String { "이 썸네일 가리기" }
    var resetSize: String { "기본 크기로 되돌리기" }
    var resumeCapture: String { "캡처 재개" }
    var needsAccessibility: String { "손쉬운 사용 권한 필요" }
    func unavailable(_ item: String, reason: String) -> String { "\(item) (\(reason))" }
    var settings: String { "설정…" }
    // 占位文字。
    var waiting: String { "화면을 기다리는 중…" }
    var needsScreenRecording: String { "화면 기록 권한이 필요합니다" }
    var captureStopped: String { "캡처가 중지되었습니다. 오른쪽 클릭으로 재개할 수 있습니다." }
    var minimized: String { "최소화됨" }
}

// MARK: - 设置窗口

/// 设置窗口，韩文。单位：pt（点）、초（秒）、fps、ms。
struct SettingsStringsKO: SettingsStrings {
    // 窗口与通用。
    var windowTitle: String { "EVE-O Preview 설정" }
    var points: String { "pt" }
    var reset: String { "재설정" }
    var defaultColor: String { "기본값" }
    var cancel: String { "취소" }
    var confirm: String { "확인" }
    var delete: String { "삭제" }
    var online: String { "온라인" }
    var offline: String { "오프라인" }
    var forward: String { "앞으로" }
    var backward: String { "뒤로" }
    func seconds(_ value: Double) -> String { String(format: "%.1f초", value) }
    func fps(_ value: Double) -> String { String(format: "%.0f fps", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
    var fakeModeNotice: String {
        "데모 모드: 썸네일은 가상 클라이언트의 화면입니다. 전환과 최소화는 데모 데이터만 바꿉니다."
    }
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "설정 파일의 버전은 \(found)이지만 이 빌드는 \(supported)까지만 지원합니다. "
            + "기본 설정으로 실행 중이며 변경 사항은 저장되지 않습니다."
    }
    func loadFailedNotice(_ message: String) -> String {
        "설정 파일을 읽을 수 없습니다(\(message)). 기본 설정으로 실행 중이며 변경 사항은 저장되지 않습니다."
    }
    func quarantinedNotice(_ path: String) -> String {
        "설정 파일이 손상되어 다음 위치로 옮겼습니다: \(path). 기본 설정을 사용합니다."
    }
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "\(path) 읽기 실패: \(reason)"
        case .write: return "\(path) 쓰기 실패: \(reason)"
        case .quarantine: return "손상된 설정 파일 \(path) 격리 실패: \(reason)"
        case .backup: return "이전 버전 설정을 \(path)에 백업하지 못함: \(reason)"
        }
    }
    var configContentInvalid: String { "파일 내용이 올바른 설정이 아닙니다" }

    // 页名称。
    var pageClients: String { "클라이언트" }
    var pagePreviews: String { "썸네일 및 레이아웃" }
    var pageSwitching: String { "전환 및 단축키" }
    var pageAlerts: String { "알림" }
    var pageProfiles: String { "프로필" }
    var pageGeneral: String { "일반" }
    var pagePermissions: String { "권한" }
    var pageAbout: String { "정보" }

    // 客户端页。
    var clientsSubtitle: String { "실행 중인 클라이언트와 이 프로필에 기록된 캐릭터입니다." }
    var hideAllThumbnails: String { "모든 썸네일 가리기" }
    var charactersHeader: String { "캐릭터" }
    var charactersFooter: String { "이 캐릭터가 활성 상태일 때 강조 표시 테두리에 쓰이는 색상입니다." }
    var noCharacters: String { "아직 캐릭터가 없습니다. EVE를 실행하고 캐릭터로 로그인하십시오." }
    var loginClientsHeader: String { "로그인 화면의 클라이언트" }
    var showThumbnail: String { "썸네일 보기" }
    var highlightColorHelp: String { "활성 상태일 때의 강조 표시 색상" }

    // 预览与布局页。
    var previewsSubtitle: String { "썸네일의 크기, 모양, 동작입니다. 변경 사항은 즉시 적용됩니다." }
    var defaultSize: String { "기본 크기" }
    var minimumSize: String { "최소 크기" }
    var maximumSize: String { "최대 크기" }
    var unifySizes: String { "모든 썸네일을 기본 크기로 되돌리기" }
    var appearanceHeader: String { "모양" }
    var opacity: String { "불투명도" }
    var showTitle: String { "캐릭터 이름 보기" }
    var titleFontSize: String { "이름 글꼴 크기" }
    var titleColor: String { "이름 색상" }
    var borderEnabled: String { "테두리 보기" }
    var borderColor: String { "테두리 색상" }
    var borderThickness: String { "테두리 두께" }
    var highlightEnabled: String { "활성 클라이언트 강조 표시" }
    var highlightColor: String { "강조 표시 색상" }
    var highlightThickness: String { "강조 표시 두께" }
    var zoomHeader: String { "마우스 오버 확대" }
    var zoomEnabled: String { "마우스를 올리면 확대" }
    var zoomFactor: String { "확대 배율" }
    var zoomAnchor: String { "기준점" }
    var behaviorHeader: String { "동작" }
    var alwaysOnTop: String { "썸네일을 항상 위에 표시" }
    var hideActiveClient: String { "활성 클라이언트의 썸네일 가리기" }
    var hideWhenNotEVE: String { "EVE가 앞에 있지 않으면 썸네일 가리기" }
    var hideDelay: String { "가리기 지연 시간" }
    var layoutHeader: String { "레이아웃" }
    var snapEnabled: String { "드래그할 때 자석 맞춤" }
    var lockAspectRatio: String { "크기 조절 시 가로세로 비율 유지" }
    var lockLayout: String { "레이아웃 잠금" }
    var gestureHint: String {
        "오른쪽 드래그 또는 Option-드래그로 이동하고, 가장자리를 드래그하여 크기를 조절합니다. "
            + "Shift를 누른 채 드래그하면 자석 맞춤을 하지 않습니다."
    }
    var captureHeader: String { "캡처 및 위치" }
    var frameRate: String { "프레임 속도" }
    var titleBarCrop: String { "제목 막대 자르기" }
    var pollInterval: String { "윈도우 확인 간격" }
    var loginPositionX: String { "로그인 썸네일 X" }
    var loginPositionY: String { "로그인 썸네일 Y" }
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "왼쪽 위"
        case .n: return "위"
        case .ne: return "오른쪽 위"
        case .w: return "왼쪽"
        case .center: return "가운데"
        case .e: return "오른쪽"
        case .sw: return "왼쪽 아래"
        case .s: return "아래"
        case .se: return "오른쪽 아래"
        }
    }

    // 配置方案页。
    var profilesSubtitle: String { "각 프로필은 설정, 레이아웃, 순환 그룹을 한 벌로 묶은 것입니다." }
    var activeBadge: String { "사용 중" }
    var switchTo: String { "전환" }
    var rename: String { "이름 변경" }
    var clone: String { "복제" }
    var newProfile: String { "새 프로필" }
    var configFile: String { "설정 파일" }
    var revealConfig: String { "Finder에서 보기" }
    var profileName: String { "프로필 이름" }
    var profileNameRule: String { "1~64자로, 다른 프로필과 겹치지 않는 이름을 사용하십시오(대소문자 구분 없음)." }
    func deleteProfileConfirm(_ name: String) -> String { "‘\(name)’ 프로필을 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다." }
    func cloneTitle(_ name: String) -> String { "‘\(name)’ 복제" }
    func renameTitle(_ name: String) -> String { "‘\(name)’ 이름 변경" }
    func copyName(_ name: String) -> String { "\(name) 사본" }

    // 通用页。
    var generalSubtitle: String { "모든 프로필에 적용되는 설정입니다." }
    var interfaceLanguage: String { "표시 언어" }
    var followSystem: String { "시스템 설정 따르기" }
    var machineTranslationNote: String { "일부 번역은 기계 번역입니다. 수정 제안을 환영합니다." }

    // 权限页。
    var permissionsSubtitle: String { "두 권한 모두 ‘시스템 설정 > 개인정보 보호 및 보안’에서 허용합니다." }
    var screenRecording: String { "화면 기록" }
    var screenRecordingDetail: String {
        "클라이언트 윈도우를 캡처하고 제목을 읽는 데 필요합니다. 보통 이 앱을 다시 실행한 뒤에 적용됩니다."
    }
    var accessibility: String { "손쉬운 사용" }
    var accessibilityDetail: String {
        "클라이언트 윈도우의 복원, 앞으로 가져오기, 최소화와 마우스 버튼 단축키에 필요합니다. 허용하면 바로 적용됩니다."
    }
    var granted: String { "허용됨" }
    var notGranted: String { "허용 안 됨" }
    var request: String { "요청" }
    var openSystemSettings: String { "시스템 설정 열기" }
    var relaunchHint: String { "화면 기록을 허용한 뒤 다시 실행" }
    var relaunch: String { "다시 실행" }
    var signingHint: String {
        "macOS는 코드 서명별로 권한을 기록합니다. ad-hoc 서명 빌드는 다시 빌드할 때마다 권한을 다시 허용해야 합니다. "
            + "자체 서명 인증서를 쓰는 방법은 README를 참고하십시오."
    }

    // 关于页。
    var version: String { "버전" }
    var devVersion: String { "개발 빌드" }
    var aboutSubtitle: String { "여러 EVE Online 클라이언트를 위한 실시간 썸네일과 빠른 전환(macOS 네이티브)." }
    var aboutSummary: String {
        "클라이언트마다 실시간 썸네일을 보여 주고 클릭으로 전환합니다. 순환 그룹 단축키와 여러 프로필을 지원합니다."
    }
    var upstreamHeader: String { "원본 프로젝트 및 라이선스" }
    var upstreamText: String { "이 앱은 EveOPlus/eve-o-preview의 기능을 macOS용으로 새로 구현한 것입니다." }
    var licenseText: String { "원본 프로젝트와 마찬가지로 GNU General Public License v3.0(GPL-3.0)으로 배포됩니다." }
    var disclaimerHeader: String { "참고" }
    var focusOnlyText: String {
        "이 도구는 윈도우 포커스만 전환합니다. 여러 클라이언트에 입력을 동시에 보내지 않으며 "
            + "게임 메모리를 읽거나 수정하지 않습니다."
    }
    var gameLogText: String {
        "전투 알림은 EVE 클라이언트가 직접 기록한 게임 로그 파일만 읽습니다. "
            + "게임 메모리를 읽지 않고, 파일을 수정하지 않으며, 입력을 보내지 않습니다."
    }
    var eveIPText: String {
        "EVE Online 및 관련 로고는 CCP ehf.의 상표입니다. 이 프로젝트는 CCP와 관련이 없으며 CCP의 승인을 받지 않았습니다."
    }
}
