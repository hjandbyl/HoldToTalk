import AppKit
import SwiftUI

struct NativeSidebarCollapseLock: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SidebarLockView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SidebarLockView)?.applyCollapsePolicy()
    }
}

private final class SidebarLockView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyCollapsePolicy()
    }

    func applyCollapsePolicy() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            var ancestor: NSView? = self
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   let splitViewController = splitView.delegate as? NSSplitViewController,
                   let sidebarItem = splitViewController.splitViewItems.first {
                    sidebarItem.canCollapse = false
                    sidebarItem.canCollapseFromWindowResize = false
                    sidebarItem.isCollapsed = false
                    return
                }

                ancestor = view.superview
            }
        }
    }
}
