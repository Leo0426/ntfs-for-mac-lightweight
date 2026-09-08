import AppKit
import SwiftUI

// PROTOTYPE — answers whether the selected C layout stays clear across safety states.
// It uses in-memory fixtures only and must never call disk, process, Finder, or network APIs.
@main
@MainActor
struct NTFSLiteScenarioPrototypeApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var scenarioID: ScenarioID = .setupNeedsAttention

    init() {
        ScenarioCatalogValidation.validate()
    }

    private var launchBehavior: SceneLaunchBehavior {
        CommandLine.arguments.contains("--show-window") ? .presented : .suppressed
    }

    var body: some Scene {
        MenuBarExtra("NTFS 演示") {
            Text("演示模式 · 仅模拟数据")
            Text("当前：\(scenarioID.menuSummary)")
            Button("打开 NTFS 轻量助手") {
                openWindow(id: "prototype-main")
            }
            Divider()
            Button("退出原型") {
                NSApplication.shared.terminate(nil)
            }
        }

        Window("NTFS 轻量助手 · C 版原型", id: "prototype-main") {
            ScenarioWindow(scenarioID: $scenarioID)
        }
        .defaultSize(width: 820, height: 620)
        .defaultLaunchBehavior(launchBehavior)
        .windowResizability(.contentMinSize)
    }
}
