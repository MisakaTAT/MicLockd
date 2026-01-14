//
//  AudioDeviceManager.swift
//  MicLockd
//
//  Created by MisakaTAT on 2026/1/14.
//

import Foundation
import Combine
import CoreAudio
import AVFoundation
import UserNotifications

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String  // 设备的唯一标识符，比 ID 更稳定
    
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
            // 当锁定设备UID变化时，更新锁定的设备名称
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
    
    // 保存锁定的设备名称，用于断连时显示
    var lockedDeviceName: String?
    
    // 跟踪设备是否断连
    @Published var isDeviceDisconnected: Bool = false
    
    // 获取锁定设备的UID（用于显示）
    var lockedDeviceUIDDisplay: String {
        return lockedDeviceUID ?? ""
    }
    
    // 通过UID获取设备ID（用于API调用）
    private func getDeviceIDFromUID(uid: String) -> AudioDeviceID? {
        return availableDevices.first(where: { $0.uid == uid })?.id
    }
    
    // 获取当前锁定的设备ID（用于API调用）
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
    
    init() {
        loadSettings()
        updateCurrentDevice()
        refreshAvailableDevices()
        
        // 请求通知权限
        requestNotificationPermission()
        
        // 监听设备列表变化
        setupDevicesPropertyListener()
        
        // 如果之前是锁定状态，恢复锁定
        if isLocked, let deviceUID = lockedDeviceUID, !deviceUID.isEmpty {
            // 延迟一点执行，确保设备列表已加载
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restoreLocking()
            }
        }
    }
    
    deinit {
        stopMonitoring()
        stopDevicesMonitoring()
    }
    
    // 获取当前默认输入设备
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
    
    // 获取设备名称
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
    
    // 获取设备UID（唯一标识符，比ID更稳定）
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
    
    // 检查设备是否有输入通道
    private func deviceHasInputChannels(deviceID: AudioDeviceID) -> Bool {
        // 检查设备是否有输入流
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
        
        // 如果没有输入流，直接返回false
        guard status == noErr && size > 0 else {
            return false
        }
        
        // 获取输入流ID列表，验证设备确实有输入功能
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
        
        // 如果成功获取到输入流ID，说明设备有输入功能
        guard status == noErr else {
            return false
        }
        
        // 进一步验证：检查输入流的配置是否存在且有效
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
        
        // 只有当流配置也存在时，才确认设备有输入功能
        return configStatus == noErr && size > 0
    }
    
    // 刷新可用设备列表
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
            // 检测锁定的设备是否断连（在清空列表前）
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
            // 检测锁定的设备是否断连（在清空列表前）
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
        
        // 检测锁定的设备是否断连（每次刷新都检查）
        checkLockedDeviceDisconnection()
        
        // 恢复选中的设备，如果不存在则使用当前默认设备或第一个设备
        if let savedSelectedUID = selectedDeviceUID, !savedSelectedUID.isEmpty,
           availableDevices.contains(where: { $0.uid == savedSelectedUID }) {
            // 保存的设备仍然存在，保持选中
        } else if !currentDeviceUID.isEmpty,
                  availableDevices.contains(where: { $0.uid == currentDeviceUID }) {
            selectedDeviceUID = currentDeviceUID
        } else if let firstDevice = availableDevices.first {
            selectedDeviceUID = firstDevice.uid
        } else {
            selectedDeviceUID = nil
        }
    }
    
    // 选择并设置设备（通过UID）
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
    
    // 设置默认输入设备
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
    
    // 属性监听回调
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
                // 检查当前设备是否还是锁定的设备
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
                    // 设备被更改了，恢复锁定的设备
                    let deviceName = manager.lockedDeviceName ?? manager.getDeviceName(deviceID: lockedID)
                    let success = manager.setDefaultInputDevice(deviceID: lockedID)
                    
                    if success {
                        // 发送守护触发通知
                        manager.sendDeviceRestoredNotification(deviceName: deviceName)
                    }
                }
            }
        }
        
        return noErr
    }
    
    // 开始锁定
    func startLocking() {
        guard !isLocked else { return }
        
        // 如果选择了设备，先设置为默认设备
        if let selectedUID = selectedDeviceUID, !selectedUID.isEmpty,
           let device = availableDevices.first(where: { $0.uid == selectedUID }) {
            _ = setDefaultInputDevice(deviceID: device.id)
        }
        
        updateCurrentDevice()
        guard !currentDeviceUID.isEmpty else { return }
        
        // 保存设备UID和名称（在设备断开前保存）
        lockedDeviceUID = currentDeviceUID
        if let device = availableDevices.first(where: { $0.uid == currentDeviceUID }) {
            lockedDeviceName = device.name
        } else {
            // 如果设备不在列表中，通过ID获取名称
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
        
        // 注册属性监听
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
    
    // 停止锁定
    func stopLocking() {
        guard isLocked else { return }
        
        isLocked = false
        stopMonitoring()
    }
    
    // 停止监听
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
    
    // MARK: - 持久化设置
    
    private func saveSettings() {
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
        isLocked = userDefaults.bool(forKey: isLockedKey)
        
        // 加载保存的设备UID和名称
        if let savedUID = userDefaults.string(forKey: lockedDeviceUIDKey), !savedUID.isEmpty {
            lockedDeviceUID = savedUID
        }
        
        if let savedName = userDefaults.string(forKey: lockedDeviceNameKey) {
            lockedDeviceName = savedName
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
        
        // 使用 UID 来查找设备
        guard let device = availableDevices.first(where: { $0.uid == lockedUID }) else {
            // 设备不存在，标记为断连但保持锁定状态
            isDeviceDisconnected = true
            print("保存的设备已不存在，保持锁定状态等待设备重新连接")
            // 设备列表监听器已经在 setupDevicesPropertyListener 中设置，会自动检测设备重新连接
            return
        }
        
        // 设备存在，设置为默认设备并恢复锁定
        _ = setDefaultInputDevice(deviceID: device.id)
        updateCurrentDevice()
        
        // 更新设备名称（以防变化）
        lockedDeviceName = device.name
        
        // 重新开始锁定（临时设置 isLocked 为 false 以通过检查）
        let wasLocked = isLocked
        isLocked = false
        
        // 注册属性监听
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
    
    // MARK: - 设备断连检测
    
    private func checkLockedDeviceDisconnection() {
        guard isLocked, let lockedUID = lockedDeviceUID, !lockedUID.isEmpty else { return }
        
        // 使用 UID 来识别设备
        let deviceExists = availableDevices.contains { $0.uid == lockedUID }
        
        // 如果设备不存在，说明设备断连了
        if !deviceExists {
            // 如果之前设备是连接的，现在断连了，发送通知
            if !isDeviceDisconnected {
                print("检测到锁定的设备断连: UID=\(lockedUID)")
                
                // 使用保存的设备名称
                let deviceName = lockedDeviceName ?? "未知设备"
                print("设备名称: \(deviceName)")
                
                // 发送通知
                sendDeviceDisconnectedNotification(deviceName: deviceName)
                
                // 标记设备已断连，但保持锁定状态
                isDeviceDisconnected = true
            }
            // 不取消锁定状态，等待设备重新连接
        } else {
            // 设备存在
            guard let device = availableDevices.first(where: { $0.uid == lockedUID }) else { return }
            
            // 更新设备名称（以防变化）
            lockedDeviceName = device.name
            
            // 如果之前设备是断连的，现在重新连接了
            if isDeviceDisconnected {
                print("检测到锁定的设备重新连接: UID=\(lockedUID)")
                
                // 使用保存的设备名称
                let deviceName = lockedDeviceName ?? "未知设备"
                
                // 发送重新连接通知
                sendDeviceReconnectedNotification(deviceName: deviceName)
                
                // 自动切换回锁定的设备
                _ = setDefaultInputDevice(deviceID: device.id)
                print("已自动切换回锁定的设备: \(deviceName)")
                
                // 标记设备已重新连接
                isDeviceDisconnected = false
            }
        }
    }
    
    // MARK: - 设备列表变化监听
    
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
            // 刷新设备列表
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
    
    // MARK: - 通知功能
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("请求通知权限失败: \(error)")
            }
        }
    }
    
    private func sendDeviceDisconnectedNotification(deviceName: String) {
        // 检查通知权限
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
        // 检查通知权限
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
        // 检查通知权限
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
