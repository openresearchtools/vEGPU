import AppKit
import SwiftUI

struct PersistentTabHost: NSViewControllerRepresentable {
    let model: NativeAppModel
    @Binding var selectedTab: NativeAppModel.Tab

    func makeNSViewController(context: Context) -> Controller {
        Controller(model: model, selectedTab: selectedTab)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.select(selectedTab)
    }

    final class Controller: NSViewController {
        private let model: NativeAppModel
        private var controllers: [NativeAppModel.Tab: NSViewController] = [:]
        private var selectedTab: NativeAppModel.Tab

        init(model: NativeAppModel, selectedTab: NativeAppModel.Tab) {
            self.model = model
            self.selectedTab = selectedTab
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            view = NSView()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            select(selectedTab)
        }

        func select(_ tab: NativeAppModel.Tab) {
            selectedTab = tab
            let selectedController = controller(for: tab)
            for (candidate, controller) in controllers {
                controller.view.isHidden = candidate != tab
            }
            selectedController.view.isHidden = false
        }

        private func controller(for tab: NativeAppModel.Tab) -> NSViewController {
            if let controller = controllers[tab] {
                return controller
            }
            let controller: NSViewController
            switch tab {
            case let .section(section):
                switch section {
                case .runtime:
                    controller = NSHostingController(rootView: AnyView(RuntimeView(model: model)))
                case .files:
                    controller = NSHostingController(rootView: AnyView(FilesTabView(model: model)))
                case .gui:
                    controller = NSHostingController(rootView: AnyView(GUIDisplayTabView(model: model)))
                case .externalDisplays:
                    controller = NSHostingController(rootView: AnyView(ExternalDisplaysView(model: model)))
                case .models:
                    controller = NSHostingController(rootView: AnyView(WebUITabBrowser(tabID: tab.id, title: "Models", url: URL(string: "http://127.0.0.1:9292/core")!)))
                case .chat:
                    controller = NSHostingController(rootView: AnyView(WebUITabBrowser(tabID: tab.id, title: "Chat", url: URL(string: "http://127.0.0.1:9292/")!)))
                }
            case let .webShortcut(id):
                if let shortcut = model.shortcuts.first(where: { $0.id == id }) {
                    controller = NSHostingController(rootView: AnyView(WebUITabBrowser(tabID: tab.id, title: shortcut.title, url: shortcut.url)))
                } else {
                    controller = NSHostingController(rootView: AnyView(Text("Web UI route not found").frame(maxWidth: .infinity, maxHeight: .infinity)))
                }
            }
            controllers[tab] = controller
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            controller.view.isHidden = true
            view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            return controller
        }
    }
}
