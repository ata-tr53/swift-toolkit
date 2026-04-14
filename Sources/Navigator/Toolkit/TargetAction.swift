//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Represents a couple (`target`, `action`) which can be invoked from a `sender`.
final class TargetAction {
    private weak var target: AnyObject?
    private let action: Selector

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
    }

#if os(macOS)
    func invoke(from sender: Any?) {
        if let target = target {
            NSApplication.shared.sendAction(action, to: target, from: sender)
        }
    }
#else
    func invoke(from sender: Any?) {
        if let target = target {
            UIApplication.shared.sendAction(action, to: target, from: sender, for: nil)
        }
    }
#endif
}
