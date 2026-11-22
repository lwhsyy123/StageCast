//
//  AndroidDeviceProvider.swift
//  StageCast
//
//  Created by Sun on 2025/12/22.
//
//  Android 设备提供者
//  通过 adb 扫描并管理 Android 设备列表
//

import Combine
import Foundation

// MARK: - 无线连接错误

/// Android 无线连接错误
enum AndroidWirelessError: LocalizedError {
    case connectFailed(String)
    case enableFailed(String)
    case ipNotFound

    var errorDescription: String? {
        switch self {
        case let .connectFailed(reason): L10n.android.wirelessConnectFailedDetail(reason)
        case let .enableFailed(reason): L10n.android.wirelessEnableFailed(reason)
        case .ipNotFound: L10n.android.wirelessIPNotFound
        }
    }
}

// MARK: - 无线端口缓存

/// 无线连接端口缓存条目
/// Android 11+ 的无线调试端口是随机的，缓存下来可免去每次手动输入
struct WirelessPortCacheEntry: Codable {
    /// 端口号
    let port: Int
    /// 是否为 TLS 无线调试端口（非 5555 视为 TLS）
    let usesTLS: Bool
    /// 最后成功时间
    let updatedAt: Date
}

// MARK: - 无线连接诊断

/// 无线连接的单步诊断结果
struct WirelessDiagnosticStep: Identifiable, Equatable {
    let id = UUID()
    /// 步骤名称
    let title: String
    /// 执行的命令
    let command: String?
    /// 原始输出
    let output: String
    /// 是否成功
    let isSuccess: Bool
}

/// mDNS 发现到的无线调试服务
struct WirelessMDNSService: Identifiable, Equatable {
    let id = UUID()
    /// 服务名（形如 adb-XXXXXX-YYYYY）
    let name: String
    /// 完整服务类型
    let serviceType: String
    /// 已解析的地址（可能为空）
    let address: String?

    /// 从服务名推断配对/调试类型
    var isPairingService: Bool {
        serviceType.contains("_adb-tls-pairing")
    }

    var isConnectService: Bool {
        serviceType.contains("_adb-tls-connect")
    }
}

// MARK: - Android 设备提供者

@MainActor
final class AndroidDeviceProvider: ObservableObject {
    // MARK: - 状态

    /// 已发现的设备列表
    @Published private(set) var devices: [AndroidDevice] = []

    /// 是否正在监控
    @Published private(set) var isMonitoring = false

    /// 最后一次错误
    @Published private(set) var lastError: String?

    /// adb 服务是否运行中
    @Published private(set) var isAdbServerRunning = false

    // MARK: - 私有属性

    private let processRunner = ProcessRunner()
    private var monitoringTask: Task<Void, Never>?
    private let toolchainManager: ToolchainManager

    /// 轮询间隔（秒）
    private let pollingInterval: TimeInterval = 2.0

    // MARK: - 生命周期

    init(toolchainManager: ToolchainManager) {
        self.toolchainManager = toolchainManager
    }

    deinit {
        monitoringTask?.cancel()
    }

    // MARK: - 公开方法

    /// 开始监控设备
    func startMonitoring() {
        guard !isMonitoring else {
            AppLogger.device.debug("设备监控已在运行中")
            return
        }

        AppLogger.device.info("开始监控 Android 设备")
        isMonitoring = true
        lastError = nil

        monitoringTask = Task {
            await startAdbServer()

            while !Task.isCancelled, isMonitoring {
                await refreshDevices()
                await attemptWirelessReconnectIfNeeded()
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            }

            AppLogger.device.info("设备监控已停止")
        }
    }

    /// 停止监控
    func stopMonitoring() {
        AppLogger.device.info("停止监控 Android 设备")
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // MARK: - 无线连接

    /// 通过 IP:端口 连接设备（Android 11+ 无线调试，或已执行 adb tcpip 的设备）
    /// - Parameters:
    ///   - host: 设备 IP
    ///   - port: 端口，默认 5555
    /// - Returns: 连接结果说明
    func connectWireless(host: String, port: Int = 5555) async throws -> String {
        let address = "\(host):\(port)"
        AppLogger.device.info("[Wireless] 连接 \(address)")

        // 与 scrcpy --tcpip 一致：先尝试直连，失败且当前有 USB 设备时自动开启 TCP 模式再连
        if let firstError = await tryAdbConnect(address: address) {
            AppLogger.device.info("[Wireless] 首次连接失败: \(firstError)")

            // 针对 adb 异常状态（No route to host / 连接卡住）自动重启 server 重试一次
            if firstError.lowercased().contains("no route to host")
                || firstError.lowercased().contains("failed") {
                await restartAdbServer()
                if let retryError = await tryAdbConnect(address: address) {
                    AppLogger.device.warning("[Wireless] 重启 adb 后仍失败: \(retryError)")
                } else {
                    AppLogger.device.info("[Wireless] 重启 adb 后连接成功")
                    await refreshDevices()
                    return address
                }
            }

            AppLogger.device.info("[Wireless] 尝试自动开启 TCP 模式")

            // 找一台 USB 设备来开启 tcpip
            let usbSerial = devices.first { $0.connectionType == .usb && $0.state == .device }?.serial
            if let usbSerial {
                do {
                    let deviceIP = try await enableWirelessDebugging(serial: usbSerial, port: port)
                    AppLogger.device.info("[Wireless] 已开启 TCP 模式，设备 IP: \(deviceIP)")
                    // tcpip 会让 adbd 重启，等待其重新监听
                    try? await Task.sleep(nanoseconds: 3_000_000_000)

                    let target = deviceIP == host ? address : "\(deviceIP):\(port)"
                    if let secondError = await tryAdbConnect(address: target) {
                        await refreshDevices()
                        throw AndroidWirelessError.connectFailed(secondError)
                    }
                    await refreshDevices()
                    return target
                } catch let error as AndroidWirelessError {
                    throw error
                } catch {
                    throw AndroidWirelessError.connectFailed(error.localizedDescription)
                }
            }

            await refreshDevices()
            throw AndroidWirelessError.connectFailed(firstError)
        }

        await refreshDevices()
        return address
    }

    /// 重启 adb server
    /// 实测发现：adb 在切换网络或长时间空闲后会进入异常状态，
    /// 表现为「手机 ping 通、端口也通，但 adb connect 报 No route to host」，
    /// 此时必须 kill-server + start-server 才能恢复。
    private func restartAdbServer() async {
        AppLogger.device.info("[Wireless] 重启 adb server")
        _ = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["kill-server"]
        )
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["start-server"]
        )
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// 执行一次 adb connect
    /// - Returns: 成功返回 nil，失败返回错误描述
    private func tryAdbConnect(address: String) async -> String? {
        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["connect", address]
            )
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            AppLogger.device.info("[Wireless] adb connect \(address) -> \(output)")

            if !result.isSuccess { return output.isEmpty ? "connect 失败" : output }
            // adb connect 即使失败也可能返回 0
            let lower = output.lowercased()
            if lower.contains("failed") || lower.contains("cannot") || lower.contains("unable")
                || lower.contains("refused") {
                return output
            }
            // 二次确认设备确实出现在列表中
            let verify = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["devices"]
            )
            if verify.stdout.contains(address) { return nil }
            return "设备未出现在 adb devices 列表中"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - mDNS 自动发现

    /// 通过 mDNS 扫描局域网内开启无线调试的设备
    /// 等价于 `adb mdns services`，输出形如：
    /// adb-XXXXXX-YYYYY _adb-tls-connect._tcp 192.168.1.5:37001
    func discoverWirelessServices() async -> [WirelessMDNSService] {
        AppLogger.device.info("[Wireless] mDNS 扫描无线调试服务")
        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["mdns", "services"]
            )
            let output = (result.stdout + result.stderr)
            AppLogger.device.info("[Wireless] adb mdns services -> \(output)")
            return Self.parseMDNSServices(output)
        } catch {
            AppLogger.device.error("[Wireless] mDNS 扫描失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 解析 `adb mdns services` 输出
    static func parseMDNSServices(_ output: String) -> [WirelessMDNSService] {
        var services: [WirelessMDNSService] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("List of discovered") else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }

            let name = parts[0]
            let serviceType = parts[1]
            let address = parts.count >= 3 ? parts[2] : nil

            services.append(
                WirelessMDNSService(
                    name: name,
                    serviceType: serviceType,
                    address: address
                )
            )
        }
        return services
    }

    // MARK: - 配对（Android 11+ 无线调试）

    /// 使用配对码完成 adb pair
    /// - Parameters:
    ///   - host: 设备 IP
    ///   - port: 配对端口（手机「无线调试 → 使用配对码配对」页显示）
    ///   - code: 6 位配对码
    /// - Returns: 诊断步骤
    func pairWireless(host: String, port: Int, code: String) async -> WirelessDiagnosticStep {
        let address = "\(host):\(port)"
        AppLogger.device.info("[Wireless] adb pair \(address)")

        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["pair", address, code]
            )
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = output.lowercased().contains("successfully paired")
            AppLogger.device.info("[Wireless] adb pair 结果: \(output)")
            return WirelessDiagnosticStep(
                title: L10n.android.wireless.stepPair,
                command: "adb pair \(address) \(code)",
                output: output.isEmpty ? (ok ? "Successfully paired" : "无输出") : output,
                isSuccess: ok
            )
        } catch {
            return WirelessDiagnosticStep(
                title: L10n.android.wireless.stepPair,
                command: "adb pair \(address)",
                output: error.localizedDescription,
                isSuccess: false
            )
        }
    }

    // MARK: - 连接诊断

    /// 带完整诊断的无线连接
    /// 依次执行：kill-server → connect → 检查 devices → （失败时）尝试 tcpip
    /// - Returns: 每一步的诊断结果，最后一项的 isSuccess 表示整体是否成功
    func connectWirelessWithDiagnostics(host: String, port: Int = 5555) async -> [WirelessDiagnosticStep] {
        var steps: [WirelessDiagnosticStep] = []
        let address = "\(host):\(port)"

        // 步骤 1：重启 adb server（规避 IPv6 优先导致的 No route to host）
        steps.append(await runDiagnostic(
            title: L10n.android.wireless.stepKillServer,
            arguments: ["kill-server"]
        ))

        // 步骤 2：启动 server
        steps.append(await runDiagnostic(
            title: L10n.android.wireless.stepStartServer,
            arguments: ["start-server"]
        ))

        // 步骤 3：连接
        var connectStep = await runDiagnostic(
            title: L10n.android.wireless.stepConnect,
            arguments: ["connect", address]
        )
        steps.append(connectStep)

        // 若报 No route to host，自动重启 server 再试一次（adb 异常状态的常见表现）
        if !connectStep.output.contains("connected to") {
            let lower = connectStep.output.lowercased()
            if lower.contains("no route") || lower.contains("failed") {
                steps.append(await runDiagnostic(
                    title: L10n.android.wireless.stepRestartAdb,
                    arguments: ["kill-server"]
                ))
                steps.append(await runDiagnostic(
                    title: L10n.android.wireless.stepStartServer,
                    arguments: ["start-server"]
                ))
                connectStep = await runDiagnostic(
                    title: L10n.android.wireless.stepConnectRetry,
                    arguments: ["connect", address]
                )
                steps.append(connectStep)
            }
        }

        // 步骤 4：确认设备出现在列表中
        let verifyStep = await runDiagnostic(
            title: L10n.android.wireless.stepVerify,
            arguments: ["devices"]
        )
        let appeared = verifyStep.output.contains(address)
        steps.append(
            WirelessDiagnosticStep(
                title: verifyStep.title,
                command: verifyStep.command,
                output: verifyStep.output,
                isSuccess: appeared
            )
        )

        if appeared {
            await refreshDevices()
            return steps
        }

        // 步骤 5：连接失败且当前有 USB 设备 → 尝试开启 tcpip 后重连
        let usbSerial = devices.first { $0.connectionType == .usb && $0.state == .device }?.serial
        if let usbSerial {
            let tcpipStep = await runDiagnostic(
                title: L10n.android.wireless.stepTcpip,
                arguments: ["-s", usbSerial, "tcpip", "\(port)"]
            )
            steps.append(tcpipStep)

            if tcpipStep.isSuccess {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                steps.append(await runDiagnostic(
                    title: L10n.android.wireless.stepReconnect,
                    arguments: ["connect", address]
                ))
                let recheck = await runDiagnostic(
                    title: L10n.android.wireless.stepVerify,
                    arguments: ["devices"]
                )
                let ok = recheck.output.contains(address)
                steps.append(
                    WirelessDiagnosticStep(
                        title: recheck.title,
                        command: recheck.command,
                        output: recheck.output,
                        isSuccess: ok
                    )
                )
            }
        }

        await refreshDevices()
        return steps
    }

    /// 执行一条 adb 命令并包装成诊断步骤
    private func runDiagnostic(title: String, arguments: [String]) async -> WirelessDiagnosticStep {
        let command = "adb " + arguments.joined(separator: " ")
        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: arguments
            )
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            AppLogger.device.info("[Wireless] \(command) -> \(output)")
            return WirelessDiagnosticStep(
                title: title,
                command: command,
                output: output.isEmpty ? "(无输出)" : output,
                isSuccess: result.isSuccess
            )
        } catch {
            return WirelessDiagnosticStep(
                title: title,
                command: command,
                output: error.localizedDescription,
                isSuccess: false
            )
        }
    }

    /// 断开无线设备
    func disconnectWireless(host: String, port: Int = 5555) async {
        let address = "\(host):\(port)"
        AppLogger.device.info("[Wireless] 断开 \(address)")
        _ = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["disconnect", address]
        )
        await refreshDevices()
    }

    /// 为 USB 连接的设备开启无线调试（adb tcpip）
    /// 说明：执行后设备的 adbd 会重启为 TCP 模式，USB 连接短暂中断
    /// - Parameter serial: 当前 USB 设备的序列号
    /// - Returns: 设备 IP（用于后续 connect）
    func enableWirelessDebugging(serial: String, port: Int = 5555) async throws -> String {
        AppLogger.device.info("[Wireless] 为 \(serial) 开启 TCP 模式（端口 \(port)）")

        // 先取设备 IP
        let ipResult = try await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["-s", serial, "shell", "ip", "route"]
        )
        guard let ip = Self.extractDeviceIP(from: ipResult.stdout) else {
            AppLogger.device.error("[Wireless] 无法解析设备 IP，ip route 输出: \(ipResult.stdout)")
            throw AndroidWirelessError.ipNotFound
        }
        AppLogger.device.info("[Wireless] 设备 IP: \(ip)")

        let tcpipResult = try await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["-s", serial, "tcpip", "\(port)"]
        )
        let tcpipOutput = (tcpipResult.stdout + tcpipResult.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.device.info("[Wireless] adb tcpip 输出: \(tcpipOutput)")

        guard tcpipResult.isSuccess, tcpipOutput.lowercased().contains("restarting") else {
            throw AndroidWirelessError.enableFailed(tcpipOutput)
        }

        return ip
    }

    /// 从 `ip route` 输出中提取设备局域网 IP
    /// 示例: "172.16.104.0/24 dev wlan0 proto kernel scope link src 172.16.104.95"
    static func extractDeviceIP(from output: String) -> String? {
        let pattern = #"src\s+(\d{1,3}(?:\.\d{1,3}){3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let ipRange = Range(match.range(at: 1), in: output)
        else { return nil }
        let ip = String(output[ipRange])
        // 过滤回环与常见虚拟网卡地址
        guard !ip.hasPrefix("127."), !ip.hasPrefix("0.") else { return nil }
        return ip
    }

    // MARK: - 自动重连

    /// 记录上次成功连接过的无线地址（用于掉线后自动重连）
    private var lastWirelessAddress: String?

    /// 掉线重连尝试计数，避免无限循环
    private var wirelessReconnectAttempts = 0

    /// 「设备条目完全消失」场景的重连尝试计数
    private var wirelessVanishedReconnectAttempts = 0

    /// 当检测到无线设备 offline 时自动重连
    /// adb 的 TCP 连接在手机息屏/网络抖动后会变为 offline，通常 kill-server 后重连即可恢复
    private func attemptWirelessReconnectIfNeeded() async {
        // 找出处于 offline 的无线设备
        let offlineWireless = devices.first {
            $0.connectionType == .wifi && $0.state == .offline
        }
        guard let offline = offlineWireless else {
            wirelessReconnectAttempts = 0
            await handleWirelessDeviceVanished()
            return
        }
        wirelessVanishedReconnectAttempts = 0

        guard wirelessReconnectAttempts < 3 else { return }
        wirelessReconnectAttempts += 1

        let address = offline.serial
        AppLogger.device.info("[Wireless] 检测到 \(address) offline，自动重连（第 \(wirelessReconnectAttempts) 次）")

        // 先尝试单纯重连
        _ = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["disconnect", address]
        )
        _ = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["connect", address]
        )
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // 检查是否恢复
        if let check = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["devices"]
        ), check.stdout.contains("\(address)\tdevice") {
            AppLogger.device.info("[Wireless] 自动重连成功: \(address)")
            wirelessReconnectAttempts = 0
            return
        }

        // 仍失败则重启 server 再试
        await restartAdbServer()
        _ = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["connect", address]
        )
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        AppLogger.device.info("[Wireless] 重启 adb 后重连 \(address) 完成")
    }

    /// 无线设备从 adb devices 列表完全消失时的恢复（TCP 静默断开场景）
    /// 记住最后在线的地址，消失后按固定次数尝试重连
    private func handleWirelessDeviceVanished() async {
        let onlineWireless: AndroidDevice? = devices.first { device in
            let isWifi = device.connectionType == .wifi
            let isOnline = device.state == .device
            return isWifi && isOnline
        }
        if let online = onlineWireless {
            lastWirelessAddress = online.serial
            return
        }
        guard let last = lastWirelessAddress else { return }
        guard wirelessVanishedReconnectAttempts < 3 else { return }
        wirelessVanishedReconnectAttempts += 1
        AppLogger.device.info("[Wireless] 设备 \(last) 从列表消失，尝试重连（第 \(wirelessVanishedReconnectAttempts) 次）")
        _ = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["connect", last]
        )
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let check = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["devices"]
        ), check.stdout.contains("\(last)\tdevice") {
            AppLogger.device.info("[Wireless] 消失设备重连成功: \(last)")
            wirelessVanishedReconnectAttempts = 0
        }
    }

    // MARK: - 输入解析

    /// 解析用户输入，支持 `IP` 与 `IP:端口` 两种格式
    /// - Returns: host 与可选端口；格式非法返回 nil
    nonisolated static func parseHostPort(_ raw: String) -> (host: String, port: Int?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 {
            return (String(parts[0]), nil)
        }
        guard parts.count == 2,
              let port = Int(parts[1]),
              (1...65535).contains(port)
        else {
            return nil
        }
        let host = String(parts[0])
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    // MARK: - 端口缓存

    private static let portCachePrefix = "wireless.portCache"

    /// 缓存键：按 IP
    private static func portCacheKey(host: String) -> String {
        portCachePrefix + ".ip." + host
    }

    /// 缓存键：按设备 GUID
    private static func portCacheKey(guid: String) -> String {
        portCachePrefix + ".guid." + guid
    }

    /// 读取缓存端口（按 IP）
    func cachedPort(forHost host: String) -> WirelessPortCacheEntry? {
        readCache(key: Self.portCacheKey(host: host))
    }

    /// 记录成功的端口
    func rememberPort(_ port: Int, host: String, guid: String?) {
        let entry = WirelessPortCacheEntry(
            port: port,
            usesTLS: port != 5555,
            updatedAt: Date()
        )
        writeCache(entry, key: Self.portCacheKey(host: host))
        if let guid, !guid.isEmpty {
            writeCache(entry, key: Self.portCacheKey(guid: guid))
        }
        AppLogger.device.info(
            "[Wireless] 已缓存端口 \(port)（host=\(host), guid=\(guid ?? "-")）"
        )
    }

    private func readCache(key: String) -> WirelessPortCacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WirelessPortCacheEntry.self, from: data)
    }

    private func writeCache(_ entry: WirelessPortCacheEntry, key: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - mDNS 发现

    /// App 端 Bonjour 发现服务
    /// adb 自带的 Openscreen mDNS 在部分 macOS 上不可用（本地网络权限限制），
    /// 这里用系统 Network.framework 作为主发现通道。
    private lazy var discoveryService = WirelessDiscoveryService()

    /// 通过系统 mDNS 发现无线调试端点
    func discoverWirelessEndpoints() async -> [WirelessDiscoveredEndpoint] {
        await discoveryService.discover()
    }

    /// 读取设备上的无线调试端口（需要 USB 连接）
    /// - Returns: TLS 端口与 legacy tcpip 端口的候选列表
    private func readDeviceWirelessPorts(serial: String) async -> [Int] {
        var ports: [Int] = []
        for prop in ["service.adb.tls.port", "service.adb.tcp.port"] {
            guard let result = try? await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["-s", serial, "shell", "getprop", prop]
            ) else { continue }
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(value), port > 0, port <= 65535, !ports.contains(port) {
                ports.append(port)
            }
        }
        if !ports.isEmpty {
            AppLogger.device.info("[Wireless] 从设备读取到端口: \(ports)")
        }
        return ports
    }

    /// 读取设备无线调试 GUID（跨 IP 变化稳定，作为缓存键的补充）
    private func readWirelessGUID(address: String) async -> String? {
        guard let result = try? await processRunner.run(
            toolchainManager.adbPath,
            arguments: ["-s", address, "shell", "getprop", "persist.adb.wifi.guid"]
        ) else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 智能连接

    /// 智能无线连接：按「显式端口 → 缓存 → 5555」依次尝试
    /// 后续阶段会再插入 USB 读取与 mDNS 发现
    func connectWirelessSmart(input: String) async throws -> String {
        guard let parsed = Self.parseHostPort(input) else {
            throw AndroidWirelessError.connectFailed(L10n.android.wireless.invalidHost)
        }
        let host = parsed.host

        // 组装候选端口
        var candidates: [Int] = []
        if let explicit = parsed.port {
            candidates = [explicit]
        } else {
            // ① 缓存端口
            if let cached = cachedPort(forHost: host) {
                candidates.append(cached.port)
            }

            // ② USB 在场时直接读设备端口（Android 11+ 随机 TLS 端口）
            if let usbSerial = devices.first(where: { $0.connectionType == .usb && $0.state == .device })?.serial {
                for port in await readDeviceWirelessPorts(serial: usbSerial) where !candidates.contains(port) {
                    candidates.append(port)
                }
            }

            // ③ 系统 mDNS 发现（与输入 IP 匹配的调试端口优先）
            let endpoints = await discoverWirelessEndpoints()
            let matched = endpoints.filter { $0.isConnect && $0.host == host }
            for endpoint in matched where !candidates.contains(endpoint.port) {
                candidates.append(endpoint.port)
            }

            // ④ 兜底 5555（旧设备 / 已执行 adb tcpip）
            if !candidates.contains(5555) {
                candidates.append(5555)
            }
        }
        AppLogger.device.info("[Wireless] 候选端口列表: \(candidates)")

        var lastError: String?
        for port in candidates {
            let address = "\(host):\(port)"
            AppLogger.device.info("[Wireless] 尝试端口 \(port)")
            if let error = await tryAdbConnect(address: address) {
                lastError = error
                continue
            }
            // 成功：刷新设备并缓存端口
            await refreshDevices()
            let guid = await readWirelessGUID(address: address)
            rememberPort(port, host: host, guid: guid)
            return address
        }

        // 全部候选失败：走原有兜底（重启 adb / 自动 tcpip）
        AppLogger.device.info("[Wireless] 候选端口全部失败，进入兜底流程")
        let fallbackPort = parsed.port ?? 5555
        do {
            return try await connectWireless(host: host, port: fallbackPort)
        } catch {
            throw AndroidWirelessError.connectFailed(lastError ?? error.localizedDescription)
        }
    }

    /// 手动刷新设备列表
    func refreshDevices() async {

        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["devices", "-l"]
            )

            if result.isSuccess {
                var newDevices = parseDevices(from: result.stdout)

                // 为已授权设备获取详细信息
                for i in newDevices.indices {
                    if newDevices[i].state == .device {
                        newDevices[i] = await enrichDeviceInfo(newDevices[i])
                    }
                }

                // 同一物理设备可能同时存在 USB + 多个无线 transport（mDNS 实例、IP:port）。
                // 去重键：persist.adb.wifi.guid 优先；部分厂商（ColorOS）不设该 prop，
                // 回退用 Wi-Fi serial 的 host IP（host:port 形式）。USB 优先保留。
                func dedupeKey(for entry: AndroidDevice) -> String? {
                    if let guid = entry.wirelessGUID, !guid.isEmpty { return "guid:" + guid }
                    if entry.connectionType == .wifi {
                        let host = entry.serial.split(separator: ":").first.map(String.init) ?? ""
                        if host.contains(".") { return "ip:" + host }
                    }
                    return nil
                }
                var deduped: [AndroidDevice] = []
                var indexByKey: [String: Int] = [:]
                for entry in newDevices {
                    if let key = dedupeKey(for: entry) {
                        if let idx = indexByKey[key] {
                            if entry.connectionType == .usb && deduped[idx].connectionType != .usb {
                                deduped[idx] = entry
                            }
                        } else {
                            indexByKey[key] = deduped.count
                            deduped.append(entry)
                        }
                    } else {
                        deduped.append(entry)
                    }
                }
                if deduped.count != newDevices.count {
                    AppLogger.device
                        .info("设备去重: \(newDevices.count) 个 transport → \(deduped.count) 台物理设备")
                }
                newDevices = deduped

                // 只在设备列表真正变化时更新
                if newDevices != devices {
                    AppLogger.device.info("Android 设备列表已更新: \(newDevices.count) 个设备")
                    for device in newDevices {
                        AppLogger.device
                            .info(
                                "  - \(device.serial): \(device.state.rawValue), 名称: \(device.displayName), Android \(device.androidVersion ?? "?")"
                            )
                    }
                    devices = newDevices
                }

                isAdbServerRunning = true
                lastError = nil
            } else {
                AppLogger.device.error("adb devices 命令失败: \(result.stderr)")
                lastError = "adb 命令执行失败: \(result.stderr)"
            }
        } catch {
            AppLogger.device.error("刷新设备列表失败: \(error.localizedDescription)")
            lastError = error.localizedDescription
            isAdbServerRunning = false
        }
    }

    /// 获取设备详细信息
    private func enrichDeviceInfo(_ device: AndroidDevice) async -> AndroidDevice {
        var enriched = device

        // 并行获取所有属性以提高效率
        async let brand = getDeviceProperty(device.serial, property: "ro.product.brand")
        async let marketName = getDeviceProperty(device.serial, property: "ro.product.marketname")
        async let androidVersion = getDeviceProperty(device.serial, property: "ro.build.version.release")
        async let sdkVersion = getDeviceProperty(device.serial, property: "ro.build.version.sdk")
        async let wirelessGUID = getDeviceProperty(device.serial, property: "persist.adb.wifi.guid")

        enriched.brand = await brand
        enriched.marketName = await marketName
        enriched.androidVersion = await androidVersion
        enriched.sdkVersion = await sdkVersion
        enriched.wirelessGUID = await wirelessGUID

        // 获取定制系统信息
        await enrichCustomOsInfo(&enriched)

        // 某些设备没有 marketname，尝试其他属性
        // 注意：只有当值看起来像有效的市场名称时才使用（包含空格或长度超过型号）
        if !isValidMarketName(enriched.marketName) {
            let vendorMarketName = await getDeviceProperty(device.serial, property: "ro.product.vendor.marketname")
            if isValidMarketName(vendorMarketName) {
                enriched.marketName = vendorMarketName
            }
        }
        if !isValidMarketName(enriched.marketName) {
            let configMarketingName = await getDeviceProperty(device.serial, property: "ro.config.marketing_name")
            if isValidMarketName(configMarketingName) {
                enriched.marketName = configMarketingName
            }
        }
        // OnePlus 等设备使用 ro.product.odm.marketname
        if !isValidMarketName(enriched.marketName) {
            let odmMarketName = await getDeviceProperty(device.serial, property: "ro.product.odm.marketname")
            if isValidMarketName(odmMarketName) {
                enriched.marketName = odmMarketName
            }
        }
        // 尝试 ro.display.series（某些 OnePlus 设备使用）
        if !isValidMarketName(enriched.marketName) {
            let displaySeries = await getDeviceProperty(device.serial, property: "ro.display.series")
            if isValidMarketName(displaySeries) {
                enriched.marketName = displaySeries
            }
        }
        // 尝试 ro.vendor.oplus.market.name（OPLUS/OnePlus 设备）
        if !isValidMarketName(enriched.marketName) {
            let oplusMarketName = await getDeviceProperty(device.serial, property: "ro.vendor.oplus.market.name")
            if isValidMarketName(oplusMarketName) {
                enriched.marketName = oplusMarketName
            }
        }
        // 尝试 ro.oplus.market.name
        if !isValidMarketName(enriched.marketName) {
            let oplusMarketName2 = await getDeviceProperty(device.serial, property: "ro.oplus.market.name")
            if isValidMarketName(oplusMarketName2) {
                enriched.marketName = oplusMarketName2
            }
        }

        // 如果还是没有有效的市场名称，清空它让 displayName 使用 brand + model
        if !isValidMarketName(enriched.marketName) {
            enriched.marketName = nil
        }

        return enriched
    }

    /// 检查是否是有效的市场名称
    /// 有效的市场名称通常包含空格（如 "OnePlus 13T"）或者长度大于典型型号
    private func isValidMarketName(_ name: String?) -> Bool {
        guard let name = name, !name.isEmpty else { return false }
        // 包含空格的名称通常是有效的市场名称
        if name.contains(" ") { return true }
        // 纯数字或型号代码通常不是有效的市场名称
        let alphanumericOnly = name.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "", options: .regularExpression)
        // 如果全是大写字母和数字的组合（如 PKX110, SM_G998B），可能是型号
        let isLikelyModelCode = alphanumericOnly.uppercased() == alphanumericOnly && alphanumericOnly.count <= 10
        return !isLikelyModelCode
    }

    /// 启动 adb 服务
    func startAdbServer() async {
        AppLogger.device.info("启动 adb 服务...")

        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["start-server"]
            )
            isAdbServerRunning = result.isSuccess

            if result.isSuccess {
                AppLogger.device.info("adb 服务已启动")
            } else {
                AppLogger.device.error("adb 服务启动失败: \(result.stderr)")
            }
        } catch {
            isAdbServerRunning = false
            lastError = L10n.adb.startFailed(error.localizedDescription)
            AppLogger.device.error("adb 服务启动异常: \(error.localizedDescription)")
        }
    }

    /// 停止 adb 服务
    func stopAdbServer() async {
        AppLogger.device.info("停止 adb 服务...")

        do {
            _ = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["kill-server"]
            )
            isAdbServerRunning = false
            devices = []
            AppLogger.device.info("adb 服务已停止")
        } catch {
            lastError = L10n.adb.stopFailed(error.localizedDescription)
            AppLogger.device.error("停止 adb 服务失败: \(error.localizedDescription)")
        }
    }

    /// 获取特定设备
    func device(for serial: String) -> AndroidDevice? {
        devices.first { $0.serial == serial }
    }

    // MARK: - 私有方法

    /// 解析 adb devices -l 输出
    private func parseDevices(from output: String) -> [AndroidDevice] {
        output
            .components(separatedBy: .newlines)
            .compactMap { AndroidDevice.parse(from: $0) }
    }
}

// MARK: - 设备操作扩展

extension AndroidDeviceProvider {
    /// 获取设备属性
    func getDeviceProperty(_ serial: String, property: String) async -> String? {
        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["-s", serial, "shell", "getprop", property]
            )
            if result.isSuccess {
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // 忽略
        }
        return nil
    }

    /// 获取设备品牌
    func getDeviceBrand(_ serial: String) async -> String? {
        await getDeviceProperty(serial, property: "ro.product.brand")
    }

    /// 获取 Android 版本
    func getAndroidVersion(_ serial: String) async -> String? {
        await getDeviceProperty(serial, property: "ro.build.version.release")
    }

    /// 获取定制系统信息
    /// 支持：ColorOS, MIUI, HyperOS, One UI, OxygenOS, Flyme, EMUI, MagicOS 等
    private func enrichCustomOsInfo(_ device: inout AndroidDevice) async {
        let serial = device.serial

        // ColorOS (OnePlus/OPPO/Realme)
        if let colorOsVersion = await getDeviceProperty(serial, property: "ro.oplus.version") {
            device.customOsName = "ColorOS"
            device.customOsVersion = colorOsVersion
            return
        }
        if let colorOsVersion = await getDeviceProperty(serial, property: "ro.build.version.opporom") {
            device.customOsName = "ColorOS"
            device.customOsVersion = colorOsVersion
            return
        }

        // MIUI/HyperOS (Xiaomi/Redmi/POCO)
        if let miuiVersion = await getDeviceProperty(serial, property: "ro.miui.ui.version.name") {
            // 检查是否是 HyperOS
            if let hyperOsVersion = await getDeviceProperty(serial, property: "ro.mi.os.version.name"),
               !hyperOsVersion.isEmpty
            {
                device.customOsName = "HyperOS"
                device.customOsVersion = hyperOsVersion
            } else {
                device.customOsName = "MIUI"
                device.customOsVersion = miuiVersion
            }
            return
        }

        // One UI (Samsung)
        if let oneUiVersion = await getDeviceProperty(serial, property: "ro.build.version.oneui") {
            // One UI 版本通常是数字格式，如 50100 表示 5.1
            let formatted = formatOneUiVersion(oneUiVersion)
            device.customOsName = "One UI"
            device.customOsVersion = formatted
            return
        }

        // OxygenOS (OnePlus 海外版)
        if let oxygenVersion = await getDeviceProperty(serial, property: "ro.oxygen.version") {
            device.customOsName = "OxygenOS"
            device.customOsVersion = oxygenVersion
            return
        }

        // Flyme (Meizu)
        if let flymeVersion = await getDeviceProperty(serial, property: "ro.build.display.id") {
            if flymeVersion.lowercased().contains("flyme") {
                device.customOsName = "Flyme"
                // 提取版本号
                if let match = flymeVersion.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) {
                    device.customOsVersion = String(flymeVersion[match])
                }
                return
            }
        }

        // EMUI/HarmonyOS (Huawei)
        if let emuiVersion = await getDeviceProperty(serial, property: "ro.build.version.emui") {
            // 检查是否是 HarmonyOS
            if let harmonyVersion = await getDeviceProperty(serial, property: "hw_sc.build.os.version"),
               !harmonyVersion.isEmpty
            {
                device.customOsName = "HarmonyOS"
                device.customOsVersion = harmonyVersion
            } else {
                device.customOsName = "EMUI"
                // EMUI 版本格式通常是 EmotionUI_X.X.X
                if let match = emuiVersion.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) {
                    device.customOsVersion = String(emuiVersion[match])
                }
            }
            return
        }

        // MagicOS (Honor)
        if let magicVersion = await getDeviceProperty(serial, property: "ro.build.version.magic") {
            device.customOsName = "MagicOS"
            device.customOsVersion = magicVersion
            return
        }

        // Vivo OriginOS
        if let originVersion = await getDeviceProperty(serial, property: "ro.vivo.os.version") {
            device.customOsName = "OriginOS"
            device.customOsVersion = originVersion
            return
        }
    }

    /// 格式化 One UI 版本号
    /// 例如：50100 -> 5.1, 40000 -> 4.0
    private func formatOneUiVersion(_ version: String) -> String {
        guard let versionNum = Int(version) else { return version }
        let major = versionNum / 10000
        let minor = (versionNum % 10000) / 100
        if minor == 0 {
            return "\(major)"
        }
        return "\(major).\(minor)"
    }
}
