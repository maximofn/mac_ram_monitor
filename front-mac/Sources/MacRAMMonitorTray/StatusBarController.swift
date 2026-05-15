import AppKit
import Foundation

private let repoURL = URL(string: "https://github.com/maximofn/mac_ram_monitor")!
private let coffeeURL = URL(string: "https://www.buymeacoffee.com/maximofn")!

enum TrayState: Sendable {
    case connecting
    case connected(Snapshot)
    case disconnected(String)
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let renderer: IconRenderer
    private let backendURL: String
    private var state: TrayState = .connecting
    private var lastAppearance: IconAppearance = .dark
    private var lastRenderedKey: String = ""
    private let compactModeDefaultsKey = "MacRAMMonitorTray.compactMode"
    private var compactMode: Bool

    init(renderer: IconRenderer, backendURL: String) {
        self.renderer = renderer
        self.backendURL = backendURL
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.compactMode = UserDefaults.standard.bool(forKey: compactModeDefaultsKey)
        super.init()
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.toolTip = "Mac RAM Monitor — connecting to \(backendURL)"
        }
        // System-wide light/dark toggle. Don't KVO `effectiveAppearance` on the
        // button — AppKit re-evaluates that during repaints and any reaction
        // there feeds back into refreshIcon → set image → repaint → KVO loop.
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        lastAppearance = currentAppearance
        applyState(.connecting)
    }

    deinit {
        DistributedNotificationCenter.default.removeObserver(self)
    }

    @objc private func appearanceChanged() {
        Task { @MainActor in
            self.lastAppearance = self.currentAppearance
            self.lastRenderedKey = ""
            self.refreshIcon()
        }
    }

    func applyState(_ new: TrayState) {
        state = new
        refreshIcon()
        refreshMenu()
        refreshTooltip()
    }

    private var currentAppearance: IconAppearance {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        switch match {
        case .darkAqua, .vibrantDark: return .dark
        default: return .light
        }
    }

    private func refreshIcon() {
        let (mem, connected): (Memory?, Bool) = {
            switch state {
            case .connected(let snap): return (snap.memory, true)
            default: return (nil, false)
            }
        }()
        // Dedupe identical renders — at 1 Hz most ticks have identical visible state.
        let key = renderKey(memory: mem, connected: connected, appearance: lastAppearance)
        if key == lastRenderedKey { return }
        lastRenderedKey = key
        if let img = renderer.renderImage(memory: mem, connected: connected, appearance: lastAppearance, compact: compactMode) {
            statusItem.button?.image = img
        }
    }

    private func renderKey(memory: Memory?, connected: Bool, appearance: IconAppearance) -> String {
        var parts: [String] = ["\(connected)", "\(appearance)", "compact=\(compactMode)"]
        if let m = memory {
            // Bucket the visible state to whatever appears in the icon — int
            // pct + GiB-rounded label. Avoids repaints on sub-percent jitter.
            let pct = Int(m.usedPercent.rounded())
            let usedHundredthsGiB = Int((Double(m.usedBytes) / (1024 * 1024 * 1024) * 10).rounded())
            parts.append("\(pct):\(usedHundredthsGiB)")
        }
        return parts.joined(separator: "|")
    }

    private func refreshTooltip() {
        guard let button = statusItem.button else { return }
        switch state {
        case .connecting:
            button.toolTip = "Mac RAM Monitor — connecting to \(backendURL)"
        case .connected(let snap):
            let m = snap.memory
            let header = "RAM — \(formatBytes(m.usedBytes)) / \(formatBytes(m.totalBytes)) (\(Int(m.usedPercent.rounded()))%)"
            var lines: [String] = [header]
            lines.append("Available: \(formatBytes(m.availableBytes))")
            if snap.swap.totalBytes > 0 {
                lines.append("Swap: \(formatBytes(snap.swap.usedBytes)) / \(formatBytes(snap.swap.totalBytes)) (\(Int(snap.swap.usedPercent.rounded()))%)")
            } else {
                lines.append("Swap: not in use")
            }
            button.toolTip = lines.joined(separator: "\n")
        case .disconnected(let err):
            button.toolTip = "Backend offline: \(err)"
        }
    }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch state {
        case .connecting:
            menu.addItem(disabledItem("Connecting to \(backendURL)…"))
            menu.addItem(.separator())
        case .disconnected(let err):
            menu.addItem(disabledItem("Backend offline: \(err)"))
            menu.addItem(disabledItem("Backend: \(backendURL)"))
            menu.addItem(.separator())
        case .connected(let snap):
            let header = "Memory"
            let item = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            item.submenu = ramSubmenu(for: snap)
            menu.addItem(item)

            menu.addItem(.separator())
            menu.addItem(disabledItem("Backend: \(backendURL)"))
            if let kernel = snap.kernel {
                menu.addItem(disabledItem("Kernel: \(kernel)"))
            }
            menu.addItem(disabledItem("Updated: \(shortTime(snap.timestamp))"))
            menu.addItem(.separator())
        }

        let toggleTitle = compactMode ? "Cambiar a extendido" : "Cambiar a compacto"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleCompactMode), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let repo = NSMenuItem(title: "Repository", action: #selector(openRepo), keyEquivalent: "")
        repo.target = self
        menu.addItem(repo)
        let coffee = NSMenuItem(title: "Buy me a coffee", action: #selector(openCoffee), keyEquivalent: "")
        coffee.target = self
        menu.addItem(coffee)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func ramSubmenu(for snap: Snapshot) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let mem = snap.memory
        m.addItem(disabledItem("Total: \(formatBytes(mem.totalBytes))"))
        m.addItem(disabledItem(String(format: "Used: %@ (%.1f%%)",
                                       formatBytes(mem.usedBytes), mem.usedPercent)))
        m.addItem(disabledItem("Available: \(formatBytes(mem.availableBytes))"))
        m.addItem(disabledItem("Free: \(formatBytes(mem.freeBytes))"))
        // Linux exposes Buffers/Cached separately; on macOS those roll into the
        // unified buffer cache so the values come back as 0. Skip the lines if
        // both are zero rather than showing two misleading "0 B" entries.
        if mem.buffersBytes > 0 || mem.cachedBytes > 0 {
            m.addItem(disabledItem("Buffers: \(formatBytes(mem.buffersBytes))"))
            m.addItem(disabledItem("Cached: \(formatBytes(mem.cachedBytes))"))
        }

        m.addItem(.separator())
        if snap.swap.totalBytes > 0 {
            m.addItem(disabledItem("Swap total: \(formatBytes(snap.swap.totalBytes))"))
            m.addItem(disabledItem(String(format: "Swap used: %@ (%.1f%%)",
                                           formatBytes(snap.swap.usedBytes), snap.swap.usedPercent)))
            m.addItem(disabledItem("Swap free: \(formatBytes(snap.swap.freeBytes))"))
        } else {
            m.addItem(disabledItem("Swap: not in use"))
        }

        m.addItem(.separator())
        if snap.processes.isEmpty {
            m.addItem(disabledItem("No process data"))
        } else {
            m.addItem(disabledItem("Top processes by RSS (\(snap.processes.count))"))
            for proc in snap.processes {
                let line = String(
                    format: "  %6d %5.1f%%  %@ (%@)",
                    proc.pid,
                    proc.memoryPercent,
                    proc.name as NSString,
                    formatBytes(proc.rssBytes) as NSString
                )
                m.addItem(disabledItem(line))
            }
        }
        return m
    }

    @objc private func openRepo() { NSWorkspace.shared.open(repoURL) }
    @objc private func openCoffee() { NSWorkspace.shared.open(coffeeURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleCompactMode() {
        compactMode.toggle()
        UserDefaults.standard.set(compactMode, forKey: compactModeDefaultsKey)
        lastRenderedKey = ""
        refreshIcon()
        refreshMenu()
    }
}

// MARK: - Helpers

private func disabledItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
}

private func formatBytes(_ bytes: UInt64) -> String {
    let gib: Double = 1024 * 1024 * 1024
    let mib: Double = 1024 * 1024
    let b = Double(bytes)
    if b >= gib { return String(format: "%.2f GiB", b / gib) }
    if b >= mib { return String(format: "%.0f MiB", b / mib) }
    return "\(bytes) B"
}

/// "2026-05-06T10:11:12.345Z" → "10:11:12".
private func shortTime(_ rfc3339: String) -> String {
    guard let tIdx = rfc3339.firstIndex(of: "T") else { return rfc3339 }
    let after = rfc3339[rfc3339.index(after: tIdx)...]
    if let dot = after.firstIndex(of: ".") {
        return String(after[..<dot])
    }
    if let plus = after.firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
        return String(after[..<plus])
    }
    return String(after)
}
