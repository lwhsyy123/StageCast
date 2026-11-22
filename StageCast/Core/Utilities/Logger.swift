//
//  Logger.swift
//  StageCast
//
//  Created by Sun on 2025/12/22.
//
//  统一日志框架
//  基于 os.log 实现分类日志记录
//

import Foundation
import os.log

// MARK: - 日志缓存

/// 内存中的日志环形缓存区，用于导出日志
final class LogBuffer {
    // MARK: - Singleton

    static let shared = LogBuffer()

    private init() {}

    // MARK: - Private Properties

    private var logs: [String] = []
    private let maxEntries = 5000
    private let lock = NSLock()

    // MARK: - Public Methods

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        logs.append(entry)

        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }
    }

    func append(_ message: String, category: String, level: String) {
        let formattedMessage = "[\(level)] [\(category)] \(message)"
        append(formattedMessage)
    }

    func getLogs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        logs.removeAll()
    }
}

// MARK: - 日志分类

/// 应用日志分类枚举
enum LogCategory: String {
    case app = "App"
    case device = "Device"
    case capture = "Capture"
    case rendering = "Rendering"
    case connection = "Connection"
    case recording = "Recording"
    case annotation = "Annotation"
    case performance = "Performance"
    case process = "Process"
    case permission = "Permission"
}

// MARK: - 日志管理器

/// 统一日志管理器
final class AppLogger {
    // MARK: - Singleton

    static let shared = AppLogger()

    private init() {}

    // MARK: - Private Properties

    private let subsystem = Bundle.main.bundleIdentifier ?? "com.haptictide.StageCast"

    /// 缓存的 Logger 实例
    private var loggers: [LogCategory: Logger] = [:]

    /// 日志级别控制
    var minimumLevel: OSLogType = .debug

    /// 是否在控制台输出
    var consoleOutputEnabled: Bool = true

    // MARK: - Public Methods

    /// 获取指定分类的 Logger
    func logger(for category: LogCategory) -> Logger {
        if let cached = loggers[category] {
            return cached
        }
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category] = logger
        return logger
    }

    /// Debug 级别日志
    func debug(
        _ message: String,
        category: LogCategory = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .debug, category: category, file: file, function: function, line: line)
    }

    /// Info 级别日志
    func info(
        _ message: String,
        category: LogCategory = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .info, category: category, file: file, function: function, line: line)
    }

    /// Warning 级别日志（使用 default 类型）
    func warning(
        _ message: String,
        category: LogCategory = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .default, category: category, file: file, function: function, line: line)
    }

    /// Error 级别日志
    func error(
        _ message: String,
        category: LogCategory = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .error, category: category, file: file, function: function, line: line)
    }

    /// Fault 级别日志（严重错误）
    func fault(
        _ message: String,
        category: LogCategory = .app,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .fault, category: category, file: file, function: function, line: line)
    }

    // MARK: - Private Methods

    private func log(
        _ message: String,
        level: OSLogType,
        category: LogCategory,
        file: String,
        function: String,
        line: Int
    ) {
        guard shouldLog(level: level) else { return }

        let logger = logger(for: category)
        let fileName = (file as NSString).lastPathComponent

        let formattedMessage = "[\(fileName):\(line)] \(function) - \(message)"

        switch level {
        case .debug:
            logger.debug("\(formattedMessage, privacy: .public)")
        case .info:
            logger.info("\(formattedMessage, privacy: .public)")
        case .default:
            logger.notice("\(formattedMessage, privacy: .public)")
        case .error:
            logger.error("\(formattedMessage, privacy: .public)")
        case .fault:
            logger.fault("\(formattedMessage, privacy: .public)")
        default:
            logger.log("\(formattedMessage, privacy: .public)")
        }

        // 写入内存缓存，供导出使用（仅 info 级别以上，不包含 debug）
        if level != .debug {
            LogBuffer.shared.append(formattedMessage, category: category.rawValue, level: levelString(level))
        }

        // 控制台输出（开发时使用）
        #if DEBUG
            if consoleOutputEnabled {
                let emoji = levelEmoji(level)
                let timestamp = ISO8601DateFormatter().string(from: Date())
                print("\(emoji) [\(timestamp)] [\(category.rawValue)] \(formattedMessage)")
            }
        #endif
    }

    private func shouldLog(level: OSLogType) -> Bool {
        // OSLogType.rawValue 的值:
        // .debug = 0x02 (2)
        // .info = 0x01 (1)
        // .default = 0x00 (0)
        // .error = 0x10 (16)
        // .fault = 0x11 (17)
        // 这些值不是按严重程度递增的，所以需要手动映射
        let levelPriority = logPriority(level)
        let minimumPriority = logPriority(minimumLevel)
        return levelPriority >= minimumPriority
    }

    /// 将 OSLogType 映射到严重程度优先级（数值越大越严重）
    private func logPriority(_ level: OSLogType) -> Int {
        switch level {
        case .debug: 0
        case .info: 1
        case .default: 2 // warning
        case .error: 3
        case .fault: 4
        default: 1
        }
    }

    private func levelString(_ level: OSLogType) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .default: "WARNING"
        case .error: "ERROR"
        case .fault: "FAULT"
        default: "LOG"
        }
    }

    private func levelEmoji(_ level: OSLogType) -> String {
        switch level {
        case .debug: "🔍"
        case .info: "ℹ️"
        case .default: "⚠️"
        case .error: "❌"
        case .fault: "💥"
        default: "📝"
        }
    }
}

// MARK: - 便捷访问扩展

extension AppLogger {
    // MARK: - 分类快捷方法

    /// 应用级日志
    static var app: CategoryLogger { CategoryLogger(.app) }

    /// 设备相关日志
    static var device: CategoryLogger { CategoryLogger(.device) }

    /// 捕获相关日志
    static var capture: CategoryLogger { CategoryLogger(.capture) }

    /// 渲染相关日志
    static var rendering: CategoryLogger { CategoryLogger(.rendering) }

    /// 连接相关日志
    static var connection: CategoryLogger { CategoryLogger(.connection) }

    /// 录制相关日志
    static var recording: CategoryLogger { CategoryLogger(.recording) }

    /// 标注相关日志
    static var annotation: CategoryLogger { CategoryLogger(.annotation) }

    /// 性能相关日志
    static var performance: CategoryLogger { CategoryLogger(.performance) }

    /// 进程相关日志
    static var process: CategoryLogger { CategoryLogger(.process) }

    /// 权限相关日志
    static var permission: CategoryLogger { CategoryLogger(.permission) }
}

// MARK: - 分类日志记录器

/// 分类日志记录器，提供更简洁的 API
struct CategoryLogger {
    let category: LogCategory

    init(_ category: LogCategory) {
        self.category = category
    }

    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        AppLogger.shared.debug(message, category: category, file: file, function: function, line: line)
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        AppLogger.shared.info(message, category: category, file: file, function: function, line: line)
    }

    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        AppLogger.shared.warning(message, category: category, file: file, function: function, line: line)
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        AppLogger.shared.error(message, category: category, file: file, function: function, line: line)
    }

    func fault(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        AppLogger.shared.fault(message, category: category, file: file, function: function, line: line)
    }
}

// MARK: - 全局便捷函数

/// 全局日志函数 - Debug
func logDebug(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    AppLogger.shared.debug(message, category: category, file: file, function: function, line: line)
}

/// 全局日志函数 - Info
func logInfo(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    AppLogger.shared.info(message, category: category, file: file, function: function, line: line)
}

/// 全局日志函数 - Warning
func logWarning(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    AppLogger.shared.warning(message, category: category, file: file, function: function, line: line)
}

/// 全局日志函数 - Error
func logError(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    AppLogger.shared.error(message, category: category, file: file, function: function, line: line)
}

/// 全局日志函数 - Fault
func logFault(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    AppLogger.shared.fault(message, category: category, file: file, function: function, line: line)
}

// MARK: - 性能日志扩展

extension AppLogger {
    /// 测量代码块执行时间
    static func measure<T>(
        _ label: String,
        category: LogCategory = .performance,
        operation: () throws -> T
    ) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try operation()
        let duration = CFAbsoluteTimeGetCurrent() - start
        shared.info("\(label) completed in \(String(format: "%.3f", duration * 1000))ms", category: category)
        return result
    }

    /// 异步测量代码块执行时间
    static func measureAsync<T>(
        _ label: String,
        category: LogCategory = .performance,
        operation: () async throws -> T
    ) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await operation()
        let duration = CFAbsoluteTimeGetCurrent() - start
        shared.info("\(label) completed in \(String(format: "%.3f", duration * 1000))ms", category: category)
        return result
    }
}
