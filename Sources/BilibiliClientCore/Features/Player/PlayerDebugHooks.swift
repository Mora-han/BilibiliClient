import Foundation
#if os(iOS)
import AVKit
import UIKit
#endif

/// 播放相关的调试启动参数（平台无关；网络兜底那条 macOS 也会读）。
///
/// - `-openVideo <bvid>` 见 `RootView.LaunchArgs`：起来就落在视频详情页。
/// - `-playerDebug dump|fullscreen`：见下方 `PlayerDebugHooks`（仅 iOS）。
/// - `-legacyApi`：wbi 接口被风控（返回 `-352`）时，详情与 playurl 改走老的非 wbi 接口，
///   让调试流程不被风控卡住。正常启动不带此参数，行为完全不变。
enum PlayerDebugArgs {
    static var mode: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-playerDebug"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var legacyAPI: Bool {
        ProcessInfo.processInfo.arguments.contains("-legacyApi")
    }

    /// `-landscape`：强制横屏（模拟器没有旋转 UI，复现 iPad 横屏排版靠它）。
    static var forceLandscape: Bool {
        ProcessInfo.processInfo.arguments.contains("-landscape")
    }
}

#if os(iOS)
/// 播放器调试钩子（视觉回归 / 闪退复现用），由启动参数驱动，正常启动零影响。
///
/// - `-playerDebug dump` 8 秒后把 `AVPlayerViewController` 的控件层级写进
///   `Documents/player_debug.log`（模拟器无 GUI、点不了屏，先用它摸清按钮长什么样）。
/// - `-playerDebug fullscreen` 8 秒后自动点一下系统「全屏」按钮，用来复现
///   「点全屏就闪退」——闪退报告会落在模拟器的 CrashReporter 里。
/// - `-landscape` 进播放页后强制横屏（模拟器没有旋转 UI，复现 iPad 横屏排版用）。
enum PlayerDebugHooks {
    private static let logName = "player_debug.log"

    static var mode: String? { PlayerDebugArgs.mode }

    /// `-landscape`：把窗口转到横屏。模拟器没有旋转按钮，横屏排版只能这么触发。
    /// 三件套一起上：先把「设备朝向」spoof 成横屏，再让接口对齐它，最后发几何更新——
    /// 只发 `requestGeometryUpdate` 在模拟器上会被无视，只调 `attemptRotation...`
    /// 又会按真实设备朝向转回竖屏。
    static func armOrientationIfNeeded() {
        guard PlayerDebugArgs.forceLandscape else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            log("requested landscape")
        }
    }

    static func arm(controller: AVPlayerViewController) {
        guard let mode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            switch mode {
            case "dump": dump(controller)
            case "fullscreen": tapFullscreen(controller)
            default: log("unknown mode \(mode)")
            }
            // 全屏模式：4 秒后再点一次（全屏里的同一个按钮）退出，验证来回一趟都不崩
            if mode == "fullscreen" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    log("tapping fullscreen again to exit")
                    tapFullscreen(controller)
                }
            }
        }
    }

    private static func tapFullscreen(_ controller: AVPlayerViewController) {
        var buttons = collectButtons(in: controller.view)
        // 退出全屏那一次：内容可能已经挂在全屏窗口下、不在此 controller.view 里，
        // 找不到候选就全窗口再搜一遍（按对象去重，避免同一个按钮算两次）
        if !buttons.contains(where: isFullscreenButton) {
            var seen = Set<ObjectIdentifier>()
            for window in UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }) {
                for b in collectButtons(in: window) where seen.insert(ObjectIdentifier(b)).inserted {
                    buttons.append(b)
                }
            }
        }
        log("found \(buttons.count) buttons")
        for b in buttons { log(describe(b)) }
        let candidates = buttons.filter { isFullscreenButton($0) }
        log("fullscreen candidates: \(candidates.count)")
        guard let target = candidates.first else {
            log("no fullscreen button found")
            return
        }
        // dump 显示 `_fullScreenButtonWasPressed` 挂在 touchUpInside（rawValue 64）上
        log("sending touchUpInside -> \(describe(target))")
        target.sendActions(for: .touchUpInside)
    }

    private static func isFullscreenButton(_ button: UIButton) -> Bool {
        let haystack = [button.accessibilityLabel, button.accessibilityIdentifier,
                        button.currentTitle]
            .compactMap { $0 }
            .joined(separator: " ").lowercased()
        // 页内叫 Fullscreen Button；进全屏后同一个开关变成 Close Button（_doneButtonWasPressed）
        return haystack.contains("ull") || haystack.contains("全屏") || haystack.contains("全畫面")
            || haystack.contains("close button") || haystack.contains("退出全屏")
    }

    private static func dump(_ controller: AVPlayerViewController) {
        let buttons = collectButtons(in: controller.view)
        log("dump: \(buttons.count) buttons")
        for b in buttons { log(describe(b)) }
        // 控件可能不都是 UIButton：把整个子树的类名也记一份
        log("view tree:")
        for line in describeTree(controller.view, depth: 0, limit: 6) { log(line) }
    }

    private static func describe(_ button: UIButton) -> String {
        var targets: [String] = []
        for target in button.allTargets {
            for event in [UIControl.Event.touchUpInside, .primaryActionTriggered] {
                if let actions = button.actions(forTarget: target, forControlEvent: event) {
                    targets += actions.map { "\(event.rawValue):\($0)" }
                }
            }
        }
        let rect = button.convert(button.bounds, to: nil)
        return "btn label=\(button.accessibilityLabel ?? "-") id=\(button.accessibilityIdentifier ?? "-") "
            + "class=\(type(of: button)) actions=\(targets) frame=\(rect)"
    }

    private static func collectButtons(in root: UIView) -> [UIButton] {
        var result: [UIButton] = []
        var queue: [UIView] = [root]
        while let view = queue.popLast() {
            if let button = view as? UIButton { result.append(button) }
            queue.append(contentsOf: view.subviews)
        }
        return result
    }

    private static func describeTree(_ view: UIView, depth: Int, limit: Int) -> [String] {
        guard depth <= limit else { return [] }
        var lines = [String(repeating: "  ", count: depth) + "\(type(of: view))"]
        for sub in view.subviews {
            lines += describeTree(sub, depth: depth + 1, limit: limit)
        }
        return lines
    }

    private static func log(_ message: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(logName)
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        NSLog("[PlayerDebug] \(message)")
    }
}
#endif
