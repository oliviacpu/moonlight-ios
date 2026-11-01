//
//  ShelfAppRoot.swift
//  Shelf (Moonlight TV)
//
//  Entry point the Objective-C AppDelegate calls to build the root view
//  controller. Keeps a reference to the hosting controller so the shelf can
//  push the stream view controller onto the UIKit navigation stack.
//

import SwiftUI
import UIKit

@objc(ShelfAppRoot)
public final class ShelfAppRoot: NSObject {

    @MainActor static weak var hostingController: UIViewController?
    @MainActor static let model = ShelfModel()

    @MainActor @objc public static func makeRootViewController() -> UIViewController {
        let controller = UIHostingController(rootView: ShelfRootView().environmentObject(model))
        controller.view.backgroundColor = .black
        hostingController = controller
        model.start()
        return controller
    }

    /// Pushes the stream controller for an app and calls `completion` once the
    /// stream has ended and the shelf is visible again.
    @MainActor static func presentStream(appID: String, completion: @escaping () -> Void) -> Bool {
        guard let navigation = hostingController?.navigationController else {
            return false
        }
        guard let stream = ShelfCore.shared.streamViewController(appID: appID, onExit: {
            ShelfCore.shared.streamDidEnd()
            completion()
        }) else {
            return false
        }
        navigation.pushViewController(stream, animated: true)
        return true
    }
}
