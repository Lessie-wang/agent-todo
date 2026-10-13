// agent-todo · desktop widget host
//
// A single Swift file, compiled into a minimal .app bundle by build.sh. The
// panel is an always-on-top, non-activating window that floats over every Space
// (including full-screen apps), so the todo list is one glance away.
//
// It does four things:
//   1. open the panel and load ui.html
//   2. watch ~/.agent-todo/todos.json (mtime/size) and push its contents to the
//      page — the page is the only renderer
//   3. translate page messages (save todos / expand-collapse / fit height) into
//      file writes and window resizes
//   4. provide a menu-bar item and a global hotkey (⌥⌘X), because closing the
//      window only hides it (the app is an accessory, with no Dock icon)
//
// Deliberate trade-offs:
//   - sorting, de-duping and id assignment live in the page only; Swift does not
//     re-implement them, so there is no second copy of the rules to drift
//   - right after the page saves, Swift re-stamps the file so its own write is
//     not pushed back at it (no echo)
//   - closing hides rather than quits, so a menu-bar entry and a hotkey are
//     mandatory — otherwise the window would become unreachable

import AppKit
import Carbon
import WebKit

// ---------------------------------------------------------------- paths

let ENV = ProcessInfo.processInfo.environment

let dataDir: URL = {
    if let p = ENV["AGENT_TODO_HOME"], !p.isEmpty {
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-todo")
}()
let dataFile = dataDir.appendingPathComponent("todos.json")

let resourceDir: URL = Bundle.main.resourceURL
    ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let uiFile = resourceDir.appendingPathComponent("ui.html")

let EMPTY = #"{"collapsed":false,"seq":0,"todos":[]}"#

// ---------------------------------------------------------------- weak bridge

// WKUserContentController strongly retains its handlers; passing `self` directly
// would form the cycle webView -> configuration -> controller -> self -> webView.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

// ---------------------------------------------------------------- app

final class Overlay: NSObject, NSApplicationDelegate, NSWindowDelegate,
                     WKNavigationDelegate, WKScriptMessageHandler {

    var panel: NSPanel!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var timer: Timer?
    var ready = false

    var lastStamp: String = ""      // mtime|size, to tell whether the file changed
    var mini = false
    var userResized = false         // once you drag the size yourself, stop auto-fitting
    var fullHeight: CGFloat = 460
    let miniContentHeight: CGFloat = 34
    let worker = DispatchQueue(label: "agenttodo.io")

    // ---------- lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        setupStatusItem()
        installHotKey()
        buildPanel()
        loadUI()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pollIfChanged()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ n: Notification) { timer?.invalidate() }

    // closing hides, it does not quit; quitting goes through the menu-bar item
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }

    // fallback way back in: even if the menu-bar icon is crowded out, `open` the
    // app again and this brings the hidden panel back
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示 / 隐藏浮窗", action: #selector(togglePanelVisible), keyEquivalent: "h").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "重新载入界面", action: #selector(reload), keyEquivalent: "r").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    // an accessory app has no Dock icon, so the menu bar is the visible front door
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "☑︎"
        statusItem.button?.toolTip = "agent-todo"
        let m = NSMenu()
        m.addItem(withTitle: "显示 / 隐藏浮窗", action: #selector(togglePanelVisible), keyEquivalent: "").target = self
        m.addItem(withTitle: "收拢 / 展开", action: #selector(toggleMiniFromHost), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "重新载入界面", action: #selector(reload), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = m
        if ENV["AGENT_TODO_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let w = self.statusItem.button?.window
                fputs("status visible=\(self.statusItem.isVisible) frame=\(String(describing: w?.frame))\n", stderr)
            }
        }
    }

    @objc func reload() { webView.reload() }

    @objc func togglePanelVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func toggleMiniFromHost() {
        webView.evaluateJavaScript("window.__hostToggleMini && window.__hostToggleMini()", completionHandler: nil)
    }

    // global hotkey ⌥⌘X — RegisterEventHotKey needs no Accessibility permission,
    // unlike a global NSEvent monitor
    func installHotKey() {
        let id = EventHotKeyID(signature: OSType(0x41444F31), id: 1)   // 'ADO1'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(cmdKey | optionKey),
                                         id, GetApplicationEventTarget(), 0, &hotKeyRef)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            DispatchQueue.main.async { overlay.togglePanelVisible() }
            return noErr
        }, 1, &spec, nil, &hotKeyHandler)
        if ENV["AGENT_TODO_DEBUG"] != nil { fputs("hotkey ⌥⌘X register status=\(status)\n", stderr) }
    }

    // ---------- panel

    func buildPanel() {
        let w: CGFloat = 340
        // NSScreen.main is random for an app with no key window, so a multi-monitor
        // setup would land on the wrong display. Use the screen the mouse is on.
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.screens.first
        let screen = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.maxX - w - 16,
                          y: screen.maxY - fullHeight - 16,
                          width: w, height: fullHeight)

        panel = NSPanel(contentRect: rect,
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.title = "待办"
        panel.appearance = NSAppearance(named: .aqua)
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true          // clicking the panel keeps your app focused
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.level = .statusBar                     // a notch above .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = NSColor(srgbRed: 0.957, green: 0.925, blue: 0.875, alpha: 1)   // #f4ecdf
        panel.minSize = NSSize(width: 260, height: 34)
        panel.setFrameAutosaveName("AgentTodoOverlay")   // remember position and size

        // the handler must be registered before the WKWebView, or the page sees undefined
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "todo")
        if #available(macOS 13.3, *) { cfg.preferences.isElementFullscreenEnabled = false }

        webView = WKWebView(frame: panel.contentLayoutRect, configuration: cfg)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = panel.backgroundColor }
        panel.contentView = webView

        panel.orderFrontRegardless()                 // not makeKeyAndOrderFront — that steals focus
        fullHeight = panel.frame.height

        if ENV["AGENT_TODO_DEBUG"] != nil {
            fputs("resourceDir=\(resourceDir.path)\n", stderr)
            fputs("ui=\(FileManager.default.fileExists(atPath: uiFile.path))\n", stderr)
            fputs("data=\(dataFile.path)\npanel frame=\(panel.frame)\n", stderr)
        }
    }

    func loadUI() {
        guard FileManager.default.fileExists(atPath: uiFile.path) else {
            fputs("overlay: ui.html not found at \(uiFile.path)\n", stderr)
            return
        }
        webView.loadFileURL(uiFile, allowingReadAccessTo: resourceDir)
    }

    func webView(_ v: WKWebView, didFinish nav: WKNavigation!) {
        ready = true
        lastStamp = ""          // force one push
        pollIfChanged()
    }

    // ---------- read / write

    func stamp() -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: dataFile.path) else {
            return "none"
        }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (a[.size] as? NSNumber)?.intValue ?? 0
        return "\(m)|\(s)"
    }

    func pollIfChanged() {
        guard ready else { return }
        let now = stamp()
        if now == lastStamp { return }
        lastStamp = now
        push(readData() ?? EMPTY)
    }

    func readData() -> String? {
        guard let d = try? Data(contentsOf: dataFile) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func push(_ json: String) {
        // JSON is already a valid JS literal; just neutralise characters that would
        // break the statement
        let safe = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\n", with: " ")
        webView.evaluateJavaScript("window.__todo_load(\(safe))") { _, err in
            if let err { fputs("overlay: push failed \(err)\n", stderr) }
        }
        if let n = openCount(fromJSON: json) { setStatusTitle(n) }
    }

    func writeData(_ json: String) {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        do {
            try json.write(to: dataFile, atomically: true, encoding: .utf8)
        } catch {
            fputs("overlay: writing todos.json failed \(error)\n", stderr)
            return
        }
        lastStamp = stamp()     // our own write — don't echo it back
    }

    // ---------- menu-bar count

    func openCount(fromJSON json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return openCount(fromObject: obj)
    }

    func openCount(fromObject obj: Any) -> Int? {
        guard let todos = (obj as? [String: Any])?["todos"] as? [[String: Any]] else { return nil }
        return todos.filter { !(($0["done"] as? Bool) ?? false) }.count
    }

    func setStatusTitle(_ n: Int) {
        statusItem?.button?.title = n > 0 ? "☑︎ \(n)" : "☑︎"
    }

    // ---------- page callbacks

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let cmd = d["cmd"] as? String else {
            fputs("overlay: unrecognised message \(m.body)\n", stderr); return
        }
        if ENV["AGENT_TODO_DEBUG"] != nil { fputs("msg: \(d)\n", stderr) }

        switch cmd {
        case "resize":
            setMini((d["mini"] as? Bool) ?? false)
        case "fit":
            fit(CGFloat((d["h"] as? NSNumber)?.doubleValue ?? 0))
        case "save":
            guard let data = d["data"] else { return }
            if let n = openCount(fromObject: data) { setStatusTitle(n) }
            guard let blob = try? JSONSerialization.data(
                      withJSONObject: data,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let s = String(data: blob, encoding: .utf8) else { return }
            worker.async { [weak self] in self?.writeData(s) }
        default:
            break
        }
    }

    /// Hug the content height: few todos means a small panel, not a big empty one.
    /// Once you drag the size yourself this stops.
    func fit(_ contentH: CGFloat) {
        guard !mini, !userResized, contentH > 0 else { return }
        let chrome = panel.frame.height - panel.contentLayoutRect.height
        let limit = (panel.screen?.visibleFrame.height ?? 900) * 0.8
        let want = min(max(contentH + chrome, 120), limit)
        guard abs(want - panel.frame.height) > 4 else { return }
        var f = panel.frame
        f.origin.y += f.height - want      // keep the top edge put
        f.size.height = want
        panel.setFrame(f, display: true, animate: false)
        fullHeight = want
    }

    // only fires when a human drags the border (restoring size, or a programmatic
    // resize, does not trigger it)
    func windowWillStartLiveResize(_ n: Notification) {
        userResized = true
        if ENV["AGENT_TODO_DEBUG"] != nil { fputs("user resized — auto-fit off\n", stderr) }
    }

    func setMini(_ on: Bool) {
        guard on != mini else { return }
        mini = on
        let chrome = panel.frame.height - panel.contentLayoutRect.height   // title bar height
        var f = panel.frame
        if on {
            fullHeight = f.height
            let h = miniContentHeight + chrome
            f.origin.y += f.height - h        // keep the top edge put
            f.size.height = h
        } else {
            let h = max(fullHeight, 200)
            f.origin.y -= (h - f.height)
            f.size.height = h
        }
        panel.setFrame(f, display: true, animate: false)
    }
}

// ---------------------------------------------------------------- start

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // as early as possible, or the Dock icon flashes
app.appearance = NSAppearance(named: .aqua)
let overlay = Overlay()               // top-level so it lives for the whole process
app.delegate = overlay
app.run()
