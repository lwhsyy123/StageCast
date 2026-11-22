//
//  WirelessDiscoveryService.swift
//  StageCast
//
//  Created by Sun on 2026/11/19.
//
//  无线调试设备发现服务
//  使用 Network.framework 的 NWBrowser 浏览 adb 的 Bonjour 服务，
//  绕开 adb 自带 Openscreen mDNS 在部分 macOS 上不可用的问题。
//
//  支持三类服务：
//  - _adb-tls-connect._tcp ：Android 11+ 无线调试的调试端口（随机端口）
//  - _adb-tls-pairing._tcp ：Android 11+ 配对端口（配合 6 位配对码）
//  - _adb._tcp             ：旧版无线 adb（Android 10 及以下 / adb connect 广播）
//

import Foundation
import Network

// MARK: - 发现的设备

/// mDNS 发现到的无线调试端点
struct WirelessDiscoveredEndpoint: Identifiable, Equatable {
    /// 稳定标识（服务名 + 端口）
    var id: String { "\(serviceName):\(port)" }
    /// Bonjour 服务实例名（形如 adb-b779a8d6-F1L0Xg）
    let serviceName: String
    /// 解析出的主机地址
    let host: String
    /// 端口
    let port: Int
    /// 服务类型
    let serviceType: WirelessDiscoveryService.ServiceType

    /// 是否为配对服务
    var isPairing: Bool { serviceType == .pairing }

    /// 是否为调试连接服务
    var isConnect: Bool { serviceType == .connect || serviceType == .legacy }

    /// 展示用名称（去掉 adb- 前缀与 GUID 后缀）
    var displayName: String {
        var name = serviceName
        if name.hasPrefix("adb-") { name = String(name.dropFirst(4)) }
        // 末尾形如 -F1L0Xg 的随机后缀不适合展示
        if let dash = name.lastIndex(of: "-"), name.distance(from: name.startIndex, to: dash) > 4 {
            name = String(name[..<dash])
        }
        return name.isEmpty ? serviceName : name
    }
}

// MARK: - 发现服务

/// 无线调试设备发现服务
/// 浏览 Bonjour 服务并解析出可直连的 host:port
@MainActor
final class WirelessDiscoveryService {
    /// 支持的 Bonjour 服务类型
    enum ServiceType: String, CaseIterable {
        case connect = "_adb-tls-connect._tcp"
        case pairing = "_adb-tls-pairing._tcp"
        case legacy = "_adb._tcp"
    }

    /// 发现超时（秒）
    private let timeout: TimeInterval

    private var browsers: [ServiceType: NWBrowser] = [:]
    private var resolutions: [NWConnection] = []
    private var discovered: [WirelessDiscoveredEndpoint] = []
    private var seenKeys = Set<String>()

    init(timeout: TimeInterval = 3.0) {
        self.timeout = timeout
    }

    /// 开始发现
    /// - Returns: 去重后的端点列表（已解析到 host:port）
    func discover() async -> [WirelessDiscoveredEndpoint] {
        discovered = []
        seenKeys = []

        AppLogger.connection.debug("[WirelessDiscovery] 开始浏览 Bonjour 服务")
        startBrowsers()
        // 给 Bonjour 足够时间广播与解析
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        stop()
        AppLogger.connection.debug("[WirelessDiscovery] 浏览结束，解析到 \(discovered.count) 个端点")

        AppLogger.device.info("[WirelessDiscovery] 发现 \(discovered.count) 个端点")
        for item in discovered {
            AppLogger.device.info(
                "[WirelessDiscovery] \(item.serviceType.rawValue) \(item.serviceName) → \(item.host):\(item.port)"
            )
        }
        return discovered
    }

    /// 停止所有浏览与解析
    func stop() {
        browsers.values.forEach { $0.cancel() }
        browsers.removeAll()
        resolutions.forEach { $0.cancel() }
        resolutions.removeAll()
    }

    // MARK: - 私有方法

    private func startBrowsers() {
        for type in ServiceType.allCases {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: type.rawValue, domain: nil),
                using: params
            )

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    AppLogger.connection.debug("[WirelessDiscovery] 浏览就绪: \(type.rawValue)")
                case let .failed(error):
                    AppLogger.connection.debug("[WirelessDiscovery] 浏览失败 \(type.rawValue): \(error.localizedDescription)")
                case let .waiting(error):
                    AppLogger.connection.debug("[WirelessDiscovery] 浏览等待 \(type.rawValue): \(error.localizedDescription)")
                default:
                    break
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                AppLogger.connection.debug("[WirelessDiscovery] \(type.rawValue) 结果数: \(results.count)")
                let endpoints = results.map(\.endpoint)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for endpoint in endpoints {
                        self.resolve(endpoint, type: type)
                    }
                }
            }

            browser.start(queue: .main)
            browsers[type] = browser
        }
    }

    /// 解析 Bonjour 端点为 host:port
    private func resolve(_ endpoint: NWEndpoint, type: ServiceType) {
        guard case let .service(name, _, _, _) = endpoint else { return }

        // 强制 IPv4 解析：Bonjour 默认可能返回链路本地 IPv6（fe80::），
        // 无法用于 adb connect，且实测会导致「有结果但解析不到地址」。
        // NWProtocolIP.Options 无公开 init，这里用协议栈工厂方式设置 IP 版本。
        let params = NWParameters.tcp
        let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        ipOptions?.version = .v4

        let connection = NWConnection(to: endpoint, using: params)
        resolutions.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // 只有 ready 时 currentPath 才有远端地址；
                // 之前在 .preparing 就 cancel 导致永远解析不到（曾出现「结果数 2、解析 0 端点」）
                var resolvedHost: String?
                var resolvedPort = 0
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    switch host {
                    case let .ipv4(address):
                        // IPv4 文本可能带 %en0 之类的接口后缀，adb connect 不接受
                        resolvedHost = "\(address)".components(separatedBy: "%").first
                    case .ipv6:
                        // 链路本地 IPv6（fe80::）无法直接用于 adb connect，
                        // 且局域网内设备总有 IPv4，直接跳过避免误连
                        resolvedHost = nil
                    case let .name(hostName, _):
                        resolvedHost = hostName
                    @unknown default:
                        break
                    }
                    resolvedPort = Int(port.rawValue)
                }
                connection.cancel()
                guard let ip = resolvedHost, resolvedPort > 0 else {
                    AppLogger.connection.debug("[WirelessDiscovery] 解析失败: \(name) 无远端地址")
                    return
                }
                AppLogger.connection.debug("[WirelessDiscovery] 解析成功: \(name) -> \(ip):\(resolvedPort)")
                Task { @MainActor [weak self] in
                    self?.appendEndpoint(
                        WirelessDiscoveredEndpoint(
                            serviceName: name,
                            host: ip,
                            port: resolvedPort,
                            serviceType: type
                        )
                    )
                }
            case let .failed(error):
                AppLogger.connection.debug("[WirelessDiscovery] 解析失败 \(name): \(error.localizedDescription)")
                connection.cancel()
            case .cancelled:
                break
            default:
                // preparing / waiting：继续等待，不取消
                break
            }
        }
        connection.start(queue: .main)
    }

    private func appendEndpoint(_ endpoint: WirelessDiscoveredEndpoint) {
        let key = "\(endpoint.host):\(endpoint.port)"
        guard !seenKeys.contains(key) else { return }
        seenKeys.insert(key)
        discovered.append(endpoint)
    }
}
