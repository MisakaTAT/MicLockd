import SwiftUI
import AppKit

@main
struct MicLockdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var audioManager = AudioDeviceManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioManager)
                .frame(width: 520, height: 420)
                .fixedSize()
                .onAppear {
                    appDelegate.setAudioManager(audioManager)
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.first {
                            window.styleMask.remove(.resizable)
                            window.setContentSize(NSSize(width: 520, height: 420))
                            window.center()
                            window.isMovableByWindowBackground = true
                            window.delegate = appDelegate
                        }
                    }
                } 
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 420)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 MicLockd") {
                }
            }
        }
    }
}
