import AppKit
import ApplicationServices
import StillePostCore

/// Die Auswahl wird ausschließlich auf ausdrücklichen Auftrag gelesen. Für
/// Services ist deren eigenes Pasteboard zulässig, niemals das allgemeine.
@MainActor final class SelectedTextAccess {
    struct Capture {
        let text: String
        let applicationName: String
        let bundleID: String?
        let target: SelectedTextAccess?
        let restriction: String?
        var requiresLocalOnly = false
    }
    private let application: NSRunningApplication
    private let applicationElement: AXUIElement
    private let element: AXUIElement
    private let snapshot: TextSelectionSnapshot
    private let elementIdentity: UUID
    private var observer: NSObjectProtocol?
    private(set) var foreignApplicationActivated = false
    private var attemptedReplacement = false
    var onInvalidated: (() -> Void)?
    var permitsReplacement: Bool { snapshot.supportsReplacement && !foreignApplicationActivated && !attemptedReplacement }

    private init(application: NSRunningApplication, applicationElement: AXUIElement, element: AXUIElement,
                 snapshot: TextSelectionSnapshot, elementIdentity: UUID) {
        self.application = application; self.applicationElement = applicationElement; self.element = element
        self.snapshot = snapshot; self.elementIdentity = elementIdentity
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      activated.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      activated.processIdentifier != self.application.processIdentifier else { return }
                self.foreignApplicationActivated = true; self.onInvalidated?()
            }
        }
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    static func capture(serviceText: String? = nil) throws -> Capture {
        if let serviceText { try TextSelectionSnapshot.validate(serviceText) }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier, !application.isTerminated else {
            if let serviceText {
                return Capture(text:serviceText,applicationName:L10n.text("selection.service_origin"),bundleID:nil,
                    target:nil,restriction:L10n.text("selection.service_unverified"),requiresLocalOnly:true)
            }
            throw SelectionCleanupFailure.noTarget
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        do {
            guard AXIsProcessTrusted() else { throw SelectionCleanupFailure.permission }
            guard let focused = attribute(appElement, kAXFocusedUIElementAttribute, deadline:deadline),
                  CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw SelectionCleanupFailure.noAccess }
            let element = focused as! AXUIElement, token = UUID()
            let snapshot = try read(element, application: application, identity: token, deadline:deadline)
            if let serviceText, !serviceText.utf8.elementsEqual(snapshot.text.utf8) { throw SelectionCleanupFailure.changed }
            let target = SelectedTextAccess(application: application, applicationElement: appElement,
                element: element, snapshot: snapshot, elementIdentity: token)
            return Capture(text: snapshot.text, applicationName: application.localizedName ?? "", bundleID: application.bundleIdentifier,
                target: target, restriction: snapshot.supportsReplacement ? nil : SelectionCleanupFailure.unsupported.localizedDescription)
        } catch let failure as SelectionCleanupFailure {
            switch failure {
            case .noAccess, .permission:
                guard let serviceText else { throw failure }
                return Capture(text:serviceText,applicationName:application.localizedName ?? "",bundleID:application.bundleIdentifier,
                    target:nil,restriction:failure.localizedDescription,requiresLocalOnly:true)
            default:throw failure
            }
        }
    }

    func replace(with text: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        guard permitsReplacement, NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier, !application.isTerminated,
              let running = NSRunningApplication(processIdentifier: application.processIdentifier),
              running.launchDate == application.launchDate,
              let focused = Self.attribute(applicationElement, kAXFocusedUIElementAttribute, deadline:deadline),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw SelectionCleanupFailure.changed }
        let currentElement = focused as! AXUIElement
        let current = try Self.read(currentElement, application: running,
                                    identity: CFEqual(element, currentElement) ? elementIdentity : UUID(), deadline:deadline)
        guard snapshot.permitsReplacement(with: current, foreignApplicationActivated: foreignApplicationActivated) else {
            throw SelectionCleanupFailure.changed
        }
        attemptedReplacement = true
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              !foreignApplicationActivated, Self.setTimeout(element,deadline:deadline) else { throw SelectionCleanupFailure.changed }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            throw SelectionCleanupFailure.unconfirmed
        }
        // Nur die eingesetzte Stelle nachlesen, nicht den vollständigen Dokumenttext.
        var range = CFRange(location: snapshot.range.location, length: text.utf16.count)
        guard let value = AXValueCreate(.cfRange, &range) else { throw SelectionCleanupFailure.unconfirmed }
        var inserted: CFTypeRef?
        guard Self.setTimeout(element,deadline:deadline), AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &inserted) == .success,
              inserted as? String == text else { throw SelectionCleanupFailure.unconfirmed }
    }

    private static func read(_ element: AXUIElement, application: NSRunningApplication, identity: UUID, deadline:TimeInterval) throws -> TextSelectionSnapshot {
        if attribute(element,kAXSubroleAttribute,deadline:deadline) as? String == kAXSecureTextFieldSubrole as String
            || (attribute(element,NSAccessibility.Attribute.containsProtectedContent.rawValue,deadline:deadline) as? Bool) == true {
            throw SelectionCleanupFailure.secure
        }
        guard let value = attribute(element,kAXSelectedTextRangeAttribute,deadline:deadline), CFGetTypeID(value) == AXValueGetTypeID() else {
            throw SelectionCleanupFailure.noAccess
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue,.cfRange,&range), range.location >= 0, range.length > 0 else { throw SelectionCleanupFailure.empty }
        guard range.length <= TextSelectionSnapshot.maximumUTF8Bytes else { throw SelectionCleanupFailure.tooLarge }
        guard let selected = attribute(element,kAXSelectedTextAttribute,deadline:deadline) as? String else { throw SelectionCleanupFailure.noAccess }
        var writable: DarwinBoolean = false
        let canWrite = setTimeout(element,deadline:deadline) && AXUIElementIsAttributeSettable(element,kAXSelectedTextAttribute as CFString,&writable) == .success && writable.boolValue
        let process = "\(application.processIdentifier):\(application.launchDate?.timeIntervalSince1970 ?? 0)"
        return try TextSelectionSnapshot(applicationIdentity: process, elementIdentity: identity,
            range: NSRange(location: range.location,length: range.length), text: selected, supportsReplacement: canWrite)
    }

    private static func setTimeout(_ element: AXUIElement, deadline:TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element,Float(remaining)); return true
    }

    private static func attribute(_ element: AXUIElement, _ name: String, deadline:TimeInterval) -> CFTypeRef? {
        guard setTimeout(element,deadline:deadline) else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }
}
