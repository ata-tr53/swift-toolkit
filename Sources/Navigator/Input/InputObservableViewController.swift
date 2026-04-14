//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

#if os(macOS)

import AppKit

/// Base implementation of `NSViewController` which implements
/// ``InputObservable`` to forward AppKit events to observers.
open class InputObservableViewController: NSViewController, InputObservable {
    let inputObservers = CompositeInputObserver()

    override open func viewDidAppear() {
        super.viewDidAppear()
        // On macOS, the view or window needs to explicitly accept first responder status
        view.window?.makeFirstResponder(self)
    }

    // MARK: - InputObservable

    @discardableResult
    public func addObserver(_ observer: any InputObserving) -> InputObservableToken {
        inputObservers.addObserver(observer)
    }

    public func removeObserver(_ token: InputObservableToken) {
        inputObservers.removeObserver(token)
    }

    // MARK: - NSResponder

    override open var acceptsFirstResponder: Bool {
        true
    }

    override open func resignFirstResponder() -> Bool {
        if isViewLoaded {
            // Equivalent to endEditing on iOS
            view.window?.makeFirstResponder(nil)
        }
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard Events (AppKit)

    override open func keyDown(with event: NSEvent) {
        if let keyEvent = KeyEvent(phase: .down, event: event) {
            Task { _ = await inputObservers.didReceive(keyEvent) }
        } else {
            super.keyDown(with: event)
        }
    }

    override open func keyUp(with event: NSEvent) {
        if let keyEvent = KeyEvent(phase: .up, event: event) {
            Task { _ = await inputObservers.didReceive(keyEvent) }
        } else {
            super.keyUp(with: event)
        }
    }

    // MARK: - Mouse Events (AppKit)

    override open func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        on(.down, event: event)
    }

    override open func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        on(.move, event: event)
    }

    override open func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        on(.up, event: event)
    }

    private func on(_ phase: PointerEvent.Phase, event: NSEvent) {
        Task {
            // Convert window coordinates to view coordinates
            let locationInWindow = event.locationInWindow
            let location = view.convert(locationInWindow, from: nil)
            
            // AppKit events have an eventNumber we can use as an ID
            let id = AnyHashable(event.eventNumber)

            _ = await inputObservers.didReceive(PointerEvent(
                pointer: .mouse(MousePointer(id: id, buttons: MouseButtons(event: event))),
                phase: phase,
                location: location,
                modifiers: KeyModifiers(flags: event.modifierFlags)!
            ))
        }
    }
}

// MARK: - AppKit Extensions for Readium Types

extension KeyEvent {
    init?(phase: KeyEvent.Phase, event: NSEvent) {
        guard
            let key = Key(event: event),
            var modifiers = KeyModifiers(flags: event.modifierFlags)
        else {
            return nil
        }

        if let modKey = KeyModifiers(key: key) {
            modifiers.remove(modKey)
        }

        self.init(phase: phase, key: key, modifiers: modifiers)
    }
}

extension Key {
    init?(event: NSEvent) {
        // AppKit uses raw keyCodes for standard navigation keys
        switch event.keyCode {
        case 36, 76: self = .enter // Return and Enter
        case 48: self = .tab
        case 49: self = .space
        case 125: self = .arrowDown
        case 126: self = .arrowUp
        case 123: self = .arrowLeft
        case 124: self = .arrowRight
        case 119: self = .end
        case 115: self = .home
        case 121: self = .pageDown
        case 116: self = .pageUp
        case 55, 54: self = .command
        case 59, 62: self = .control
        case 58, 61: self = .option
        case 56, 60: self = .shift
        case 53: self = .escape
        default:
            guard let character = event.charactersIgnoringModifiers, !character.isEmpty else {
                return nil
            }
            self = .character(character)
        }
    }
}

extension MouseButtons {
    init(event: NSEvent) {
        self.init()
        // 0 is left click, 1 is right click
        if event.buttonNumber == 0 {
            insert(.main)
        } else if event.buttonNumber == 1 {
            insert(.secondary)
        }
    }
}

extension KeyModifiers {
    init?(flags: NSEvent.ModifierFlags) {
        self.init()

        if flags.contains(.shift) {
            insert(.shift)
        }
        if flags.contains(.control) {
            insert(.control)
        }
        if flags.contains(.option) {
            insert(.option)
        }
        if flags.contains(.command) {
            insert(.command)
        }
    }
}

#else

import UIKit

/// Base implementation of `UIViewController` which implements
/// ``InputObservable`` to forward UIKit touches and presses events to
/// observers.
open class InputObservableViewController: UIViewController, InputObservable {
    let inputObservers = CompositeInputObserver()

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        becomeFirstResponder()
    }

    // MARK: - InputObservable

    @discardableResult
    public func addObserver(_ observer: any InputObserving) -> InputObservableToken {
        inputObservers.addObserver(observer)
    }

    public func removeObserver(_ token: InputObservableToken) {
        inputObservers.removeObserver(token)
    }

    // MARK: - UIResponder

    override open var canBecomeFirstResponder: Bool {
        true
    }

    override open func resignFirstResponder() -> Bool {
        // Force end editing of the view to make sure any subview is also
        // resigning its first responder status.
        // This is helpful in the EPUB navigator because the web views may be
        // first responders to intercept keyboard events.
        if isViewLoaded {
            view.endEditing(true)
        }

        return super.resignFirstResponder()
    }

    override open func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isFirstResponder {
            on(.down, presses: presses, with: event)
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override open func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isFirstResponder {
            on(.change, presses: presses, with: event)
        } else {
            super.pressesChanged(presses, with: event)
        }
    }

    override open func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isFirstResponder {
            on(.cancel, presses: presses, with: event)
        } else {
            super.pressesCancelled(presses, with: event)
        }
    }

    override open func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isFirstResponder {
            on(.up, presses: presses, with: event)
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    private func on(_ phase: KeyEvent.Phase, presses: Set<UIPress>, with event: UIPressesEvent?) {
        Task {
            for press in presses {
                guard let event = KeyEvent(phase: phase, uiPress: press) else {
                    continue
                }
                _ = await inputObservers.didReceive(event)
            }
        }
    }

    override open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        on(.down, touches: touches, event: event)
    }

    override open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        on(.move, touches: touches, event: event)
    }

    override open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        on(.cancel, touches: touches, event: event)
    }

    override open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        on(.up, touches: touches, event: event)
    }

    private func on(_ phase: PointerEvent.Phase, touches: Set<UITouch>, event: UIEvent?) {
        Task {
            for touch in touches {
                guard let view = view else {
                    continue
                }

                _ = await inputObservers.didReceive(PointerEvent(
                    pointer: Pointer(touch: touch, event: event),
                    phase: phase,
                    location: touch.location(in: view),
                    modifiers: KeyModifiers(event: event)
                ))
            }
        }
    }
}

extension Pointer {
    init(touch: UITouch, event: UIEvent?) {
        let id = AnyHashable(ObjectIdentifier(touch))

        self = switch touch.type {
        case .direct, .indirect:
            .touch(TouchPointer(id: id))
        case .pencil, .indirectPointer:
            .mouse(MousePointer(id: id, buttons: MouseButtons(event: event)))
        @unknown default:
            .mouse(MousePointer(id: id, buttons: MouseButtons(event: event)))
        }
    }
}

extension KeyEvent {
    init?(phase: KeyEvent.Phase, uiPress: UIPress) {
        guard
            let key = Key(uiPress: uiPress),
            var modifiers = KeyModifiers(uiPress: uiPress)
        else {
            return nil
        }

        if let modKey = KeyModifiers(key: key) {
            modifiers.remove(modKey)
        }

        self.init(phase: phase, key: key, modifiers: modifiers)
    }
}

extension Key {
    init?(uiPress: UIPress) {
        guard let key = uiPress.key else {
            return nil
        }

        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter:
            self = .enter
        case .keyboardTab:
            self = .tab
        case .keyboardSpacebar:
            self = .space
        case .keyboardDownArrow:
            self = .arrowDown
        case .keyboardUpArrow:
            self = .arrowUp
        case .keyboardLeftArrow:
            self = .arrowLeft
        case .keyboardRightArrow:
            self = .arrowRight
        case .keyboardEnd:
            self = .end
        case .keyboardHome:
            self = .home
        case .keyboardPageDown:
            self = .pageDown
        case .keyboardPageUp:
            self = .pageUp
        case .keyboardComma, .keypadComma:
            self = .command
        case .keyboardLeftControl, .keyboardRightControl:
            self = .control
        case .keyboardLeftAlt, .keyboardRightAlt:
            self = .option
        case .keyboardLeftShift, .keyboardRightShift:
            self = .shift
        case .keyboardEscape:
            self = .escape
        default:
            let character = key.charactersIgnoringModifiers
            guard character != "" else {
                return nil
            }
            self = .character(character)
        }
    }
}

extension MouseButtons {
    init(event: UIEvent?) {
        self.init()

        guard let mask = event?.buttonMask else {
            return
        }

        if mask.contains(.primary) {
            insert(.main)
        }
        if mask.contains(.secondary) {
            insert(.secondary)
        }
    }
}

extension KeyModifiers {
    init(event: UIEvent?) {
        if let flags = event?.modifierFlags {
            self.init(flags: flags)
        } else {
            self.init()
        }
    }

    init(flags: UIKeyModifierFlags) {
        self.init()

        if flags.contains(.shift) {
            insert(.shift)
        }
        if flags.contains(.control) {
            insert(.control)
        }
        if flags.contains(.alternate) {
            insert(.option)
        }
        if flags.contains(.command) {
            insert(.command)
        }
    }

    init?(uiPress: UIPress) {
        guard let flags = uiPress.key?.modifierFlags else {
            return nil
        }

        self = []

        if flags.contains(.shift) {
            insert(.shift)
        }
        if flags.contains(.command) {
            insert(.command)
        }
        if flags.contains(.control) {
            insert(.control)
        }
        if flags.contains(.alternate) {
            insert(.option)
        }
    }
}

#endif
