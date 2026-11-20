// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的韩文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：热键 단축키，循环组 순환 그룹，缩略图 썸네일，
// 客户端 클라이언트，鼠标按键 마우스 버튼，辅助功能 손쉬운 사용（macOS 韩文版的官方名称）。

import Foundation

/// 热键域的韩文实现。
struct HotkeyStringsKO: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String { "순환 그룹과 단축키. 각 단축키는 어디서나 또는 EVE 안에서만 작동합니다." }
    var cycleGroupsHeader: String { "순환 그룹" }
    var addGroup: String { "새 순환 그룹" }
    var noGroups: String { "아직 순환 그룹이 없습니다." }
    var groupName: String { "이름" }
    var deleteGroup: String { "그룹 삭제" }
    var forwardHotkeys: String { "앞으로 단축키" }
    var backwardHotkeys: String { "뒤로 단축키" }
    var noMembers: String { "아직 멤버가 없습니다." }
    var addMember: String { "멤버 추가" }
    func newGroupName(_ index: Int) -> String { "그룹 \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "캐릭터 단축키" }
    var globalHotkeysHeader: String { "공통 단축키" }
    var hotkeyToggleHideAll: String { "모든 썸네일 보기 또는 숨기기" }
    var hotkeyMinimizeAll: String { "모든 클라이언트 최소화" }
    var hotkeyCycleLogin: String { "로그인 화면 클라이언트 순환" }
    var hotkeyRulesHint: String {
        "키보드 단축키에는 Control, Option, Command 중 하나가 필요합니다. F1–F20과 숫자 키패드는 단독으로 쓸 수 있습니다. "
            + "마우스 가운데 버튼과 측면 버튼은 단독으로 쓸 수 있으며, 누른 클릭은 게임에 전달되지 않습니다."
    }
    var mouseHotkeyHint: String {
        "마우스 단축키에는 손쉬운 사용 권한이 필요합니다. 범위가 전역인 마우스 버튼은 모든 앱에서 가로채집니다. "
            + "먼저 게임이나 마우스 소프트웨어에서 이 버튼의 다른 할당을 해제하세요."
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "단축키 기본 범위" }
    var scopeGlobal: String { "전역" }
    var scopeGame: String { "EVE 안에서만" }
    func scopeFollowDefault(_ current: String) -> String { "기본값 따르기(현재: \(current))" }
    func scopeMenuHelp(_ resolved: String) -> String { "범위: \(resolved)" }
    var menuHotkeysOnlyInEVE: String { "단축키를 EVE 안에서만 사용" }

    // MARK: 录制器

    var addHotkey: String { "+ 추가" }
    var recordingPrompt: String { "키나 마우스 측면 버튼을 누르세요(포인터는 이 창 안에)…" }
    var recorderHelp: String {
        "클릭한 뒤 키 조합이나 마우스 가운데·측면 버튼을 누르세요. Esc는 취소, Delete는 지우기입니다."
    }
    var removeHotkey: String { "이 단축키 삭제" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "인식할 수 없음" }
    var hotkeyMissingModifier: String { "보조 키 필요" }
    var hotkeyReserved: String { "macOS 예약" }
    var hotkeyAccessibilityRequired: String { "손쉬운 사용 필요" }
    var hotkeyEventTapUnavailable: String { "마우스를 감지할 수 없음" }
    func hotkeyDuplicate(_ other: String) -> String { "\(other)와(과) 중복" }
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "등록 실패(\(status))" }
}
