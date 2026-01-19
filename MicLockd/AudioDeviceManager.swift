import Foundation
import Combine
import CoreAudio
import AVFoundation
import UserNotifications

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    
    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        return lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

class AudioDeviceManager: ObservableObject {
    @Published var isLocked: Bool = false {
        didSet {
            saveSettings()
        }
    }
    @Published var currentDeviceUID: String = ""
    @Published var lockedDeviceUID: String? {
        didSet {
            saveSettings()
            if let uid = lockedDeviceUID, !uid.isEmpty {
                if let device = availableDevices.first(where: { $0.uid == uid }) {
                    lockedDeviceName = device.name
                } else if let deviceID = getDeviceIDFromUID(uid: uid) {
                    lockedDeviceName = getDeviceName(deviceID: deviceID)
                }
            } else {
                lockedDeviceName = nil
            }
        }
    }
    @Published var availableDevices: [AudioDevice] = []
    @Published var selectedDeviceUID: String? {
        didSet {
            saveSettings()
        }
    }
    
    var lockedDeviceName: String?
    @Published var isDeviceDisconnected: Bool = false
    
    var lockedDeviceUIDDisplay: String {
        return lockedDeviceUID ?? ""
    }
    
    private func getDeviceIDFromUID(uid: String) -> AudioDeviceID? {
        return availableDevices.first(where: { $0.uid == uid })?.id
    }
    
    private var lockedDeviceID: AudioDeviceID? {
        guard let uid = lockedDeviceUID, !uid.isEmpty else { return nil }
        return getDeviceIDFromUID(uid: uid)
    }
    
    private var propertyListener: AudioObjectPropertyListenerProc?
    private var devicesPropertyListener: AudioObjectPropertyListenerProc?
    private var selfPtr: UnsafeMutableRawPointer?
    private var devicesSelfPtr: UnsafeMutableRawPointer?
    private var defaultInputDevicePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    private let userDefaults = UserDefaults.standard
    private let isLockedKey = "MicLockd.isLocked"
    private let lockedDeviceUIDKey = "MicLockd.lockedDeviceUID"
    private let lockedDeviceNameKey = "MicLockd.lockedDeviceName"
    private let selectedDeviceUIDKey = "MicLockd.selectedDeviceUID"
    private var isLoadingSettings = false
    
    init() {
        loadSettings()
        updateCurrentDevice()
        refreshAvailableDevices()
        requestNotificationPermission()
        setupDevicesPropertyListener()
        
        if isLocked, let deviceUID = lockedDeviceUID, !deviceUID.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restoreLocking()
            }
        }
    }
    
    deinit {
        stopMonitoring()
        stopDevicesMonitoring()
    }
    
    func updateCurrentDevice() {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputDevicePropertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        
        if status == noErr {
            currentDeviceUID = getDeviceUID(deviceID: deviceID)
        } else {
            currentDeviceUID = ""
        }
    }
    
    func getDeviceName(deviceID: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &name
        )
        
        if status == noErr, let cfString = name?.takeRetainedValue() {
            return cfString as String
        }
        return "设备 \(deviceID)"
    }
    
    func getDeviceUID(deviceID: AudioDeviceID) -> String {
        var uid: Unmanaged<CFString>?
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &uid
        )
        
        if status == noErr, let cfString = uid?.takeRetainedValue() {
            return cfString as String
        }
        return ""
    }
    
    private func deviceHasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size
        )
        
        guard status == noErr && size > 0 else {
            return false
        }
        
        let streamCount = Int(size) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else {
            return false
        }
        
        let streamIDs = UnsafeMutablePointer<AudioStreamID>.allocate(capacity: streamCount)
        defer { streamIDs.deallocate() }
        
        size = UInt32(streamCount * MemoryLayout<AudioStreamID>.size)
        status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            streamIDs
        )
        
        guard status == noErr else {
            return false
        }
        
        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        size = 0
        let configStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size
        )
        
        return configStatus == noErr && size > 0
    }
    
    func refreshAvailableDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size
        )
        
        guard status == noErr && size > 0 else {
            if !availableDevices.isEmpty {
                checkLockedDeviceDisconnection()
            }
            availableDevices = []
            return
        }
        
        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        let deviceIDs = UnsafeMutablePointer<AudioDeviceID>.allocate(capacity: deviceCount)
        defer { deviceIDs.deallocate() }
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            deviceIDs
        )
        
        guard status == noErr else {
            if !availableDevices.isEmpty {
                checkLockedDeviceDisconnection()
            }
            availableDevices = []
            return
        }
        
        var devices: [AudioDevice] = []
        for i in 0..<deviceCount {
            let deviceID = deviceIDs[i]
            if deviceHasInputChannels(deviceID: deviceID) {
                let name = getDeviceName(deviceID: deviceID)
                let uid = getDeviceUID(deviceID: deviceID)
                devices.append(AudioDevice(id: deviceID, name: name, uid: uid))
            }
        }
        
        availableDevices = devices.sorted { $0.name < $1.name }
        checkLockedDeviceDisconnection()
        
        if isLocked, let lockedUID = lockedDeviceUID, !lockedUID.isEmpty {
            if availableDevices.contains(where: { $0.uid == lockedUID }) {
                selectedDeviceUID = lockedUID
            }
        } else if let savedSelectedUID = selectedDeviceUID, !savedSelectedUID.isEmpty,
           availableDevices.contains(where: { $0.uid == savedSelectedUID }) {
        } else if !currentDeviceUID.isEmpty,
                  availableDevices.contains(where: { $0.uid == currentDeviceUID }) {
            selectedDeviceUID = currentDeviceUID
        } else if let firstDevice = availableDevices.first {
            selectedDeviceUID = firstDevice.uid
        } else {
            selectedDeviceUID = nil
        }
    }
    
    func selectDevice(uid: String) {
        guard let device = availableDevices.first(where: { $0.uid == uid }) else { return }
        selectedDeviceUID = uid
        if setDefaultInputDevice(deviceID: device.id) {
            updateCurrentDevice()
            if isLocked {
                lockedDeviceUID = uid
            }
        }
    }
    
    func setDefaultInputDevice(deviceID: AudioDeviceID) -> Bool {
        var deviceIDToSet = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputDevicePropertyAddress,
            0,
            nil,
            size,
            &deviceIDToSet
        )
        
        return status == noErr
    }
    
    private let propertyListenerCallback: AudioObjectPropertyListenerProc = { (
        inObjectID: AudioObjectID,
        inNumberAddresses: UInt32,
        inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
        inClientData: UnsafeMutableRawPointer?
    ) -> OSStatus in
        guard let clientData = inClientData else {
            return noErr
        }
        
        let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
        
        DispatchQueue.main.async {
            if manager.isLocked, let lockedUID = manager.lockedDeviceUID, !lockedUID.isEmpty,
               let lockedID = manager.lockedDeviceID {
                var currentDeviceID: AudioDeviceID = 0
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                
                let status = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &currentDeviceID
                )
                
                if status == noErr && currentDeviceID != lockedID {
                    let deviceName = manager.lockedDeviceName ?? manager.getDeviceName(deviceID: lockedID)
                    let success = manager.setDefaultInputDevice(deviceID: lockedID)
                    
                    if success {
                        manager.sendDeviceRestoredNotification(deviceName: deviceName)
                    }
                }
            }
        }
        
        return noErr
    }
    
    func startLocking() {
        guard !isLocked else { return }
        
        if let selectedUID = selectedDeviceUID, !selectedUID.isEmpty,
           let device = availableDevices.first(where: { $0.uid == selectedUID }) {
            _ = setDefaultInputDevice(deviceID: device.id)
        }
        
        updateCurrentDevice()
        guard !currentDeviceUID.isEmpty else { return }
        
        lockedDeviceUID = currentDeviceUID
        isDeviceDisconnected = false
        if let device = availableDevices.first(where: { $0.uid == currentDeviceUID }) {
            lockedDeviceName = device.name
        } else {
            var deviceID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputDevicePropertyAddress,
                0,
                nil,
                &size,
                &deviceID
            )
            if status == noErr {
                lockedDeviceName = getDeviceName(deviceID: deviceID)
            }
        }
        
        isLocked = true
        selfPtr = Unmanaged.passUnretained(self).toOpaque()
        propertyListener = propertyListenerCallback
        
        guard let ptr = selfPtr else {
            isLocked = false
            return
        }
        
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputDevicePropertyAddress,
            propertyListenerCallback,
            ptr
        )
        
        if status != noErr {
            print("无法添加属性监听: \(status)")
            isLocked = false
            selfPtr = nil
        }
    }
    
    func stopLocking() {
        guard isLocked else { return }
        
        isLocked = false
        isDeviceDisconnected = false
        lockedDeviceUID = nil
        lockedDeviceName = nil
        stopMonitoring()
        
        if let selectedUID = selectedDeviceUID,
           !availableDevices.contains(where: { $0.uid == selectedUID }) {
            selectedDeviceUID = availableDevices.first?.uid
        }
    }
    
    private func stopMonitoring() {
        if propertyListener != nil, let ptr = selfPtr {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputDevicePropertyAddress,
                propertyListenerCallback,
                ptr
            )
            propertyListener = nil
            selfPtr = nil
        }
    }
    
    private func saveSettings() {
        guard !isLoadingSettings else { return }
        
        userDefaults.set(isLocked, forKey: isLockedKey)
        
        if let lockedUID = lockedDeviceUID, !lockedUID.isEmpty {
            userDefaults.set(lockedUID, forKey: lockedDeviceUIDKey)
        } else {
            userDefaults.removeObject(forKey: lockedDeviceUIDKey)
        }
        
        if let lockedName = lockedDeviceName {
            userDefaults.set(lockedName, forKey: lockedDeviceNameKey)
        } else {
            userDefaults.removeObject(forKey: lockedDeviceNameKey)
        }
        
        if let selectedUID = selectedDeviceUID, !selectedUID.isEmpty {
            userDefaults.set(selectedUID, forKey: selectedDeviceUIDKey)
        } else {
            userDefaults.removeObject(forKey: selectedDeviceUIDKey)
        }
    }
    
    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        
        isLocked = userDefaults.bool(forKey: isLockedKey)
        
        if let savedName = userDefaults.string(forKey: lockedDeviceNameKey) {
            lockedDeviceName = savedName
        }
        
        if let savedUID = userDefaults.string(forKey: lockedDeviceUIDKey), !savedUID.isEmpty {
            lockedDeviceUID = savedUID
        }
        
        if let selectedUID = userDefaults.string(forKey: selectedDeviceUIDKey), !selectedUID.isEmpty {
            selectedDeviceUID = selectedUID
        }
    }
    
    private func restoreLocking() {
        guard let lockedUID = lockedDeviceUID, !lockedUID.isEmpty else {
            isLocked = false
            return
        }
        
        guard let device = availableDevices.first(where: { $0.uid == lockedUID }) else {
            isDeviceDisconnected = true
            print("保存的设备已不存在，保持锁定状态等待设备重新连接")
            return
        }
        
        _ = setDefaultInputDevice(deviceID: device.id)
        updateCurrentDevice()
        lockedDeviceName = device.name
        
        let wasLocked = isLocked
        isLocked = false
        selfPtr = Unmanaged.passUnretained(self).toOpaque()
        propertyListener = propertyListenerCallback
        
        guard let ptr = selfPtr else {
            isLocked = false
            return
        }
        
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputDevicePropertyAddress,
            propertyListenerCallback,
            ptr
        )
        
        if status == noErr {
            isLocked = wasLocked
            isDeviceDisconnected = false
        } else {
            print("无法恢复锁定状态: \(status)")
            isLocked = false
            selfPtr = nil
        }
    }
    
    private func checkLockedDeviceDisconnection() {
        guard isLocked, let lockedUID = lockedDeviceUID, !lockedUID.isEmpty else { return }
        
        let deviceExists = availableDevices.contains { $0.uid == lockedUID }
        
        if !deviceExists {
            if !isDeviceDisconnected {
                print("检测到锁定的设备断连: UID=\(lockedUID)")
                let deviceName = lockedDeviceName ?? "未知设备"
                print("设备名称: \(deviceName)")
                sendDeviceDisconnectedNotification(deviceName: deviceName)
                isDeviceDisconnected = true
            }
        } else {
            guard let device = availableDevices.first(where: { $0.uid == lockedUID }) else { return }
            
            lockedDeviceName = device.name
            
            if isDeviceDisconnected {
                print("检测到锁定的设备重新连接: UID=\(lockedUID)")
                let deviceName = lockedDeviceName ?? "未知设备"
                sendDeviceReconnectedNotification(deviceName: deviceName)
                _ = setDefaultInputDevice(deviceID: device.id)
                selectedDeviceUID = lockedUID
                print("已自动切换回锁定的设备: \(deviceName)")
                isDeviceDisconnected = false
            } else {
                selectedDeviceUID = lockedUID
            }
        }
    }
    
    private let devicesPropertyListenerCallback: AudioObjectPropertyListenerProc = { (
        inObjectID: AudioObjectID,
        inNumberAddresses: UInt32,
        inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
        inClientData: UnsafeMutableRawPointer?
    ) -> OSStatus in
        guard let clientData = inClientData else {
            return noErr
        }
        
        let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
        
        DispatchQueue.main.async {
            print("设备列表发生变化，刷新设备列表...")
            manager.refreshAvailableDevices()
        }
        
        return noErr
    }
    
    private func setupDevicesPropertyListener() {
        devicesSelfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        guard let ptr = devicesSelfPtr else { return }
        
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesPropertyAddress,
            devicesPropertyListenerCallback,
            ptr
        )
        
        if status != noErr {
            print("无法添加设备列表监听: \(status)")
        }
    }
    
    private func stopDevicesMonitoring() {
        if let ptr = devicesSelfPtr {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesPropertyAddress,
                devicesPropertyListenerCallback,
                ptr
            )
            devicesSelfPtr = nil
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("请求通知权限失败: \(error)")
            }
        }
    }
    
    private func sendDeviceDisconnectedNotification(deviceName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                print("通知权限未授权，无法发送通知")
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = "设备已断开连接"
            content.body = "锁定的音频输入设备「\(deviceName)」已断开连接，设备重新连接后将自动切换回该设备。"
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("发送通知失败: \(error)")
                } else {
                    print("通知已发送: \(deviceName)")
                }
            }
        }
    }
    
    private func sendDeviceRestoredNotification(deviceName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                print("通知权限未授权，无法发送通知")
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = "设备已恢复"
            content.body = "检测到默认输入设备被更改，已自动恢复为锁定的设备「\(deviceName)」。"
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("发送通知失败: \(error)")
                } else {
                    print("守护通知已发送: \(deviceName)")
                }
            }
        }
    }
    
    private func sendDeviceReconnectedNotification(deviceName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                print("通知权限未授权，无法发送通知")
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = "设备已重新连接"
            content.body = "锁定的音频输入设备「\(deviceName)」已重新连接，已自动切换回该设备。"
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("发送通知失败: \(error)")
                } else {
                    print("重新连接通知已发送: \(deviceName)")
                }
            }
        }
    }
}
