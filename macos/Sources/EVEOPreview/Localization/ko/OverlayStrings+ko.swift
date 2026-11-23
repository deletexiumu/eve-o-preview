// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域的韩文文字（docs/macos/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与菜单栏一致：오버레이、채널、「레이아웃 잠금」。

import Foundation

/// 浮窗与两页共用设置控件的韩文文字。
struct OverlayStringsKO: OverlayStrings {
    // MARK: 浮窗的列表
    func newMessages(_ count: Int) -> String { "새 메시지 \(count)개" }
    var noActiveCharacter: String { "현재 창에 캐릭터가 없습니다" }
    var emptyList: String { "아직 메시지가 없습니다" }

    // MARK: 浮窗的右键菜单
    var menuScrollToLatest: String { "최신으로 스크롤" }
    var menuCopyLine: String { "이 줄 복사" }
    var menuOpenInBrowser: String { "브라우저에서 열기" }
    var menuClear: String { "목록 지우기" }
    var menuLockLayout: String { "레이아웃 잠금" }
    var menuResetFrame: String { "위치와 크기를 기본값으로 되돌리기" }
    var menuHide: String { "이 오버레이 숨기기" }
    var menuOpenSettings: String { "설정 열기…" }

    // MARK: 浮窗设置
    var overlayHeader: String { "오버레이" }
    var opacity: String { "배경 불투명도" }
    var fontSize: String { "글자 크기" }
    var resetFrame: String { "위치를 기본값으로 되돌리기" }
    var gestureHelp: String { "오른쪽 버튼으로 드래그하거나 Option을 누른 채 왼쪽 버튼으로 드래그해 이동하고, 포인터를 가장자리에 놓고 왼쪽 버튼으로 드래그해 크기를 바꾸며, 스크롤해 목록을 넘깁니다." }
    var visibilityLabel: String { "표시 범위" }
    var visibilityAlways: String { "항상 표시" }
    var visibilityGameOnly: String { "EVE 안에서만: EVE 창이 맨 앞에 없으면 숨김" }
    var positionLabel: String { "위치" }
    var sizeLabel: String { "크기" }
    var frameHelp: String { "위치는 주 디스플레이의 왼쪽 위를 기준으로 한 포인트 단위입니다. 크기는 220×120에서 900×900까지이며, 화면 밖의 위치는 화면 안으로 되돌립니다." }

    // MARK: 频道列表
    var channelsHeader: String { "채널" }
    var addFromLogs: String { "로그에서 추가" }
    var addByNamePlaceholder: String { "채널 이름을 입력하고 Return 키를 누르세요" }
    var removeChannel: String { "제거" }
    var noChannels: String { "아직 채널이 없습니다" }
    var refreshChannels: String { "새로 고침" }
    var noDiscoveredChannels: String { "최근 채팅 로그가 없습니다" }
    func channelListeners(_ count: Int) -> String { "캐릭터 \(count)명" }

    // MARK: 内置频道
    var builtInLocal: String { "로컬" }
    var builtInCorp: String { "코퍼레이션" }
    var builtInAlliance: String { "얼라이언스" }
    var builtInFleet: String { "플릿" }
}
