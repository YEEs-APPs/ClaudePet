import Cocoa
import ApplicationServices

// MARK: - 글 쓰는 자리 찾기 (PoC)
//
// 맨 앞 앱에서 글자 커서(입력 위치)가 있는 줄의 화면 영역을 손쉬운 사용 API 로 읽는다.
// 펫이 그 줄을 가리고 있으면 마우스가 멀리 있어도 투명해지게 하는 데 쓴다 (AppDelegate.updateHoverFade).
//
// - 설정(PetPlacement.caretFade, 기본 꺼짐)을 켰을 때만 돈다. 권한 창도 켤 때만 뜬다.
// - 권한이 없거나 앱이 값을 주지 않으면 zone 이 nil 이라, 예전처럼 마우스 기준으로만 투명해진다.
// - 조회는 백그라운드 큐에서 pollInterval 마다 한 번, 응답은 messagingTimeout 까지만 기다린다.
//   앞선 조회가 안 끝났으면 건너뛰므로 느린 앱이 있어도 메인 스레드와 펫은 그대로 돈다.

final class CaretLocator {
    static let pollInterval: TimeInterval = 0.25
    static let messagingTimeout: Float = 0.2
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// 글자 커서가 있는 줄 (Cocoa 화면 좌표). 못 읽으면 nil. 메인 스레드에서만 읽고 쓴다
    private(set) var zone: NSRect?

    private let queue = DispatchQueue(label: "claudepet.caret-locator", qos: .utility)
    private var querying = false
    private var lastPoll = Date.distantPast
    private var nudgedPids = Set<pid_t>()   // queue 에서만 쓴다

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 시스템의 손쉬운 사용 권한 안내 창을 띄운다 (이미 허용돼 있으면 아무 일도 없다)
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    init() {
        // 시스템 전체 객체에 걸면 이 프로세스의 모든 손쉬운 사용 호출에 적용된다
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), CaretLocator.messagingTimeout)
    }

    /// 메인 스레드에서 자주 불러도 된다 (스스로 pollInterval 로 줄인다)
    func tick(enabled: Bool, now: Date = Date()) {
        guard enabled else { zone = nil; return }
        guard now.timeIntervalSince(lastPoll) >= CaretLocator.pollInterval, !querying else { return }
        lastPoll = now
        guard CaretLocator.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primaryHeight = NSScreen.screens.first?.frame.height else {
            zone = nil
            return
        }
        let pid = app.processIdentifier
        querying = true
        queue.async { [weak self] in
            guard let self else { return }
            let line = self.caretLine(pid: pid)
            DispatchQueue.main.async {
                self.querying = false
                // 손쉬운 사용 좌표는 주 화면 왼쪽 위가 원점이라 Cocoa 좌표(왼쪽 아래 원점)로 뒤집는다
                self.zone = line.map {
                    NSRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height)
                }
            }
        }
    }

    // MARK: - 손쉬운 사용 조회 (queue 에서 실행)

    /// 글자 커서가 있는 줄: 세로는 커서 높이, 가로는 입력 요소 너비 (요소 크기를 못 읽으면 커서 자리만)
    private func caretLine(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        guard let focusedRef = copy(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            nudge(app, pid: pid)
            return nil
        }
        let focused = focusedRef as! AXUIElement
        guard let caret = caretRect(focused) else {
            nudge(app, pid: pid)
            return nil
        }
        var line = caret
        if let frame = elementFrame(focused), frame.width > caret.width,
           frame.minY <= caret.midY, caret.midY <= frame.maxY {
            line = CGRect(x: frame.minX, y: caret.minY, width: frame.width, height: caret.height)
        }
        return line
    }

    private func caretRect(_ element: AXUIElement) -> CGRect? {
        // 방법 1: 선택 범위(글자 번호) → 그 범위의 화면 영역
        if let rangeRef = copy(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) {
                if let rect = bounds(element, range), isPlausible(rect) { return rect }
                // 길이 0 인 범위에 영역을 주지 않는 앱이 있어, 커서 바로 앞 글자의 영역으로 대신한다
                if range.length == 0, range.location > 0,
                   let rect = bounds(element, CFRange(location: range.location - 1, length: 1)), isPlausible(rect) {
                    return rect
                }
            }
        }
        return markerRect(element)
    }

    /// 방법 2: 글자 표식(text marker) 범위 → 화면 영역.
    /// Chromium(Electron) 의 여러 줄 입력창은 방법 1 에 빈 사각형(0x0)을 주고 이 경로로만 자리를 준다.
    /// 글 입력 요소가 아니어도(버튼 등) 근처 입력창의 영역을 돌려주는 일이 있어 입력 요소일 때만 쓴다.
    private func markerRect(_ element: AXUIElement) -> CGRect? {
        guard let role = copy(element, kAXRoleAttribute) as? String,
              CaretLocator.textRoles.contains(role),
              let markerRange = copy(element, "AXSelectedTextMarkerRange") else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect), isPlausible(rect) else { return nil }
        return rect
    }

    private func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// 값이 없을 때 (0,0,0,0) 이나 터무니없는 크기를 돌려주는 앱을 거른다
    private func isPlausible(_ rect: CGRect) -> Bool {
        return rect.height > 0 && rect.height < 200 && rect.width < 5000
            && !(rect.origin.x == 0 && rect.origin.y == 0)
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let posRef = copy(element, kAXPositionAttribute), CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = copy(element, kAXSizeAttribute), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// Electron 앱은 보조 기술이 요청해야 입력 요소를 손쉬운 사용에 드러낸다 (Electron 문서의 AXManualAccessibility).
    /// 커서 자리를 못 읽은 앱에 한 번만 요청해 두면 다음 조회부터 읽힌다. 지원하지 않는 앱은 무시한다.
    private func nudge(_ app: AXUIElement, pid: pid_t) {
        guard nudgedPids.insert(pid).inserted else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
