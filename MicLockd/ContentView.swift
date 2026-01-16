import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioDeviceManager
    
    var body: some View {
        VStack(spacing: 16) {
            header
            mainCard
            footerHint
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .fixedSize()
        .background(background)
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioDeviceManager())
}

private extension ContentView {
    var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                
                Image(systemName: audioManager.isLocked ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(audioManager.isLocked ? .green : .secondary)
            }
            .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("MicLockd")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Text("锁定默认音频输入设备")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            statusPill
        }
        .frame(height: 44)
    }
    
    var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.thickMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.separator, lineWidth: 1)
        )
        .accessibilityLabel("锁定状态")
        .accessibilityValue(statusText)
    }
    
    var statusColor: Color {
        if audioManager.isLocked {
            return audioManager.isDeviceDisconnected ? .red : .green
        }
        return .orange
    }
    
    var statusText: String {
        if audioManager.isLocked {
            return audioManager.isDeviceDisconnected ? "设备断开" : "已锁定"
        }
        return "未锁定"
    }
    
    var mainCard: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text("输入设备")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        audioManager.refreshAvailableDevices()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(audioManager.isLocked)
                    .help("刷新设备列表")
                }
                
                if audioManager.isLocked && audioManager.isDeviceDisconnected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 14))
                        Text(audioManager.lockedDeviceName ?? "未知设备")
                            .foregroundStyle(.primary)
                            .font(.subheadline)
                        Text("(已断开)")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("锁定的设备已断开，重新连接后将自动切换回该设备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if audioManager.availableDevices.isEmpty {
                    Text("未找到可用输入设备")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("选择设备", selection: Binding(
                        get: { audioManager.selectedDeviceUID ?? audioManager.availableDevices.first?.uid ?? "" },
                        set: { audioManager.selectDevice(uid: $0) }
                    )) {
                        ForEach(audioManager.availableDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(audioManager.isLocked)
                    
                    Text(audioManager.isLocked ? "锁定时无法切换设备（先解锁）" : "选择后会立即设置为默认输入设备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                infoRow(title: "锁定目标", value: lockedTargetText)
                if audioManager.isLocked && !audioManager.lockedDeviceUIDDisplay.isEmpty {
                    infoRow(title: "设备UID", value: audioManager.lockedDeviceUIDDisplay)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: {
                if audioManager.isLocked {
                    audioManager.stopLocking()
                } else {
                    audioManager.startLocking()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: audioManager.isLocked ? "lock.open" : "lock")
                        .font(.system(size: 14, weight: .medium))
                    Text(audioManager.isLocked ? "解锁" : "锁定")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(audioManager.isLocked ? .orange : .green)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }
    
    var footerHint: some View {
        Text(audioManager.isLocked
             ? "已启用锁定：系统默认输入设备被改动时，会自动切回锁定目标。"
             : "提示：先在上方选择设备，再点击'锁定'按钮。")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
    
    var lockedTargetText: String {
        return audioManager.lockedDeviceName ?? "—"
    }
    
    @ViewBuilder
    func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 20)
    }
    
    var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.20),
                Color.clear,
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
    }
}
