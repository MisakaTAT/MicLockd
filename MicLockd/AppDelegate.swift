import AppKit
import SwiftUI
import ServiceManagement
import Combine
import CoreAudio

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var audioManager: AudioDeviceManager?
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        
        DispatchQueue.main.async {
            self.configureWindow()
        }
        
        setupLoginItem()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func configureWindow() {
        if let window = NSApplication.shared.windows.first {
            window.styleMask.remove(.resizable)
            window.setContentSize(NSSize(width: 520, height: 420))
            window.center()
            window.delegate = self
        }
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.accessory)
        }
        
        return false
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "MicLockd")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        updateMenuBar()
    }
    
    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                if popover == nil, let audioManager = audioManager {
                    popover = NSPopover()
                    popover?.contentSize = NSSize(width: 520, height: 420)
                    popover?.behavior = .transient
                    let contentView = ContentView()
                        .environmentObject(audioManager)
                    popover?.contentViewController = NSHostingController(rootView: contentView)
                }
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        }
    }
    
    @objc func toggleLock() {
        guard let audioManager = audioManager else { return }
        if audioManager.isLocked {
            audioManager.stopLocking()
        } else {
            audioManager.startLocking()
        }
        updateMenuBar()
    }
    
    @objc func toggleLoginItem() {
        let enabled = isLoginItemEnabled()
        setLoginItemEnabled(!enabled)
        updateMenuBar()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func updateMenuBar() {
        let menu = NSMenu()
        
        let deviceMenu = NSMenu()
        let deviceMenuItem = NSMenuItem(title: "选择设备", action: nil, keyEquivalent: "")
        deviceMenuItem.submenu = deviceMenu
        
        if let audioManager = audioManager {
            for device in audioManager.availableDevices {
                let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                item.state = (device.uid == audioManager.selectedDeviceUID) ? .on : .off
                item.isEnabled = !audioManager.isLocked
                deviceMenu.addItem(item)
            }
            
            if audioManager.availableDevices.isEmpty {
                let item = NSMenuItem(title: "无可用设备", action: nil, keyEquivalent: "")
                item.isEnabled = false
                deviceMenu.addItem(item)
            }
            
            deviceMenu.addItem(NSMenuItem.separator())
            let refreshItem = NSMenuItem(title: "刷新设备列表", action: #selector(refreshDevices), keyEquivalent: "")
            refreshItem.target = self
            refreshItem.isEnabled = !audioManager.isLocked
            deviceMenu.addItem(refreshItem)
        } else {
            let item = NSMenuItem(title: "加载中...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            deviceMenu.addItem(item)
        }
        
        menu.addItem(deviceMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        let lockTitle = audioManager?.isLocked == true ? "解锁设备" : "锁定设备"
        let lockMenuItem = NSMenuItem(title: lockTitle, action: #selector(toggleLock), keyEquivalent: "")
        lockMenuItem.target = self
        lockMenuItem.state = (audioManager?.isLocked == true) ? .on : .off
        menu.addItem(lockMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let showWindowItem = NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: "")
        showWindowItem.target = self
        menu.addItem(showWindowItem)
        
        let loginItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        
        if let button = statusItem?.button, let audioManager = audioManager {
            let iconName = audioManager.isLocked ? "mic.fill" : "mic.slash.fill"
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "MicLockd")
            button.image?.isTemplate = true
        }
    }
    
    @objc func selectDevice(_ sender: NSMenuItem) {
        if let deviceUID = sender.representedObject as? String {
            audioManager?.selectDevice(uid: deviceUID)
            updateMenuBar()
        }
    }
    
    @objc func refreshDevices() {
        audioManager?.refreshAvailableDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.updateMenuBar()
        }
    }
    
    func setAudioManager(_ manager: AudioDeviceManager) {
        audioManager = manager
        
        manager.$isLocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBar()
            }
            .store(in: &cancellables)
        
        manager.$availableDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBar()
            }
            .store(in: &cancellables)
        
        manager.$selectedDeviceUID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBar()
            }
            .store(in: &cancellables)
        
        updateMenuBar()
    }
    
    // MARK: - Login Item Management
    
    func setupLoginItem() {
        if !isLoginItemEnabled() {
            setLoginItemEnabled(true)
        }
    }
    
    func isLoginItemEnabled() -> Bool {
        let service = SMAppService.mainApp
        return service.status == .enabled
    }
    
    func setLoginItemEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}
