import AppKit
import ApplicationServices

/// Where the text caret is, in Accessibility coordinates
/// (global, origin at the top-left of the primary display).
struct Caret: Equatable {
    var rect: CGRect
    /// Which lookup produced the rect. Logged so we learn what Terminal supports.
    var strategy: String
}

enum CaretError: Error, Equatable, CustomStringConvertible {
    case noFocusedElement(Int32)
    case noSelectedRange(Int32)
    case selectionActive(Int)
    case noBounds(Int32)
    case notATerminal

    var description: String {
        switch self {
        case .noFocusedElement(let code): return "no focused element (AXError \(code))"
        case .noSelectedRange(let code): return "no selected text range (AXError \(code))"
        case .selectionActive(let length): return "text selection active (length \(length))"
        case .noBounds(let code): return "no bounds for caret range (AXError \(code))"
        case .notATerminal: return "focused web element is not a terminal"
        }
    }
}

/// Reads the caret position of an app through the Accessibility API.
/// Same approach Fig used: focused element, selected text range, bounds for that range.
/// Web based terminals (VS Code and other Electron apps) use xterm.js, which
/// keeps a cell sized helper textarea on the cursor; its frame is the caret.
enum CaretTracker {
    private static let xtermCaretClass = "xterm-helper-textarea"

    /// Electron apps build no accessibility tree until asked. This is the
    /// switch Electron provides for tools like this one; other apps ignore it.
    static func prepare(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func focusedElement(pid: pid_t) -> Result<AXUIElement, CaretError> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .failure(.noFocusedElement(err.rawValue))
        }
        return .success(value as! AXUIElement)
    }

    static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return (value as? String) ?? "unknown"
    }

    /// `trailingSpaces` is how many spaces sit between the last visible
    /// character and the caret, when the shell has told us. Nil means unknown.
    static func caret(pid: pid_t, trailingSpaces: Int? = nil) -> Result<Caret, CaretError> {
        let element: AXUIElement
        switch focusedElement(pid: pid) {
        case .success(let el): element = el
        case .failure(let err): return .failure(err)
        }

        // Only web content has DOM classes. There the text range APIs describe
        // the hidden textarea, not the terminal grid, so use its frame.
        var classValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classValue) == .success,
           let classes = classValue as? [String] {
            guard classes.contains(xtermCaretClass) else { return .failure(.notATerminal) }
            guard let rect = frame(of: element), rect.height > 0, rect.width > 0,
                  rect.origin.x.isFinite, rect.origin.y.isFinite
            else { return .failure(.noBounds(-1)) }
            return .success(Caret(rect: rect, strategy: "xterm-textarea"))
        }

        var rangeValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        guard err == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return .failure(.noSelectedRange(err.rawValue))
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return .failure(.noSelectedRange(-1))
        }
        // A real selection means the user is copying text, not typing.
        guard range.length <= 1 else {
            return .failure(.selectionActive(range.length))
        }

        // Terminal drops a trailing space from its accessibility text, so right
        // after typing a space the caret cell is reported at the start of the
        // next line. Detect that by comparing with the character before the
        // caret: if the caret cell is on a lower line while the previous
        // character is not at the right edge, the caret really sits one cell
        // after that character.
        let spaces = trailingSpaces ?? 1
        if spaces > 0, range.location > 0,
           case .success(let current) = bounds(of: CFRange(location: range.location, length: 1), in: element),
           case .success(let previous) = bounds(of: CFRange(location: range.location - 1, length: 1), in: element),
           previous.height > 0, previous.width > 0, previous.width < previous.height * 4,
           current.minY >= previous.maxY - 1 {
            let x = previous.maxX + previous.width * CGFloat(spaces)
            let rightEdge = frame(of: element)?.maxX
            if rightEdge == nil || x + previous.width <= rightEdge! {
                let rect = CGRect(x: x, y: previous.minY, width: previous.width, height: previous.height)
                return .success(Caret(rect: rect, strategy: "after-trailing-space"))
            }
        }

        // A zero-length range often has no bounds, so try the cell under the
        // caret first, then the bare insertion point, then the cell before it.
        var lastError: Int32 = 0
        let attempts: [(String, CFRange, Bool)] = [
            ("cell-at-caret", CFRange(location: range.location, length: 1), false),
            ("insertion-point", CFRange(location: range.location, length: 0), false),
            ("cell-before-caret", CFRange(location: max(0, range.location - 1), length: 1), true),
        ]
        for (name, candidate, useTrailingEdge) in attempts {
            switch bounds(of: candidate, in: element) {
            case .success(var rect):
                guard rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite else { continue }
                if useTrailingEdge {
                    rect.origin.x = rect.maxX
                }
                return .success(Caret(rect: rect, strategy: name))
            case .failure(let failure):
                lastError = failure.code
            }
        }
        return .failure(.noBounds(lastError))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> Result<CGRect, Int32Error> {
        var range = range
        guard let axRange = AXValueCreate(.cfRange, &range) else { return .failure(Int32Error(-1)) }
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        )
        guard err == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return .failure(Int32Error(err.rawValue))
        }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return .failure(Int32Error(-1)) }
        return .success(rect)
    }
}

struct Int32Error: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}

/// Watches the terminal app for anything that can leave the popup pointing at the
/// wrong place: another window or tab taking focus, or the window moving.
final class TerminalWatcher {
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private let onChange: () -> Void

    private static let notifications = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
    ]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Safe to call often. Re-attaches only when the terminal app has a new pid.
    func attach(to pid: pid_t) {
        guard pid != self.pid else { return }
        detach()
        CaretTracker.prepare(pid: pid)

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<TerminalWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }

        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        self.pid = pid
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        pid = 0
    }
}
