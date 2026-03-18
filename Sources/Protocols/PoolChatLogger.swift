// PoolChatLogger.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import os.log

// MARK: - Log Level

public enum PoolChatLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

// MARK: - Log Category

public enum PoolChatLogCategory: String, Sendable {
    case general = "General"
    case network = "Network"
    case runtime = "Runtime"
    case security = "Security"
    case ui = "UI"
    case poolChat = "PoolChat"
}

// MARK: - Logger Protocol

public protocol PoolChatLogger: Sendable {
    func log(
        _ message: String,
        level: PoolChatLogLevel,
        category: PoolChatLogCategory,
        file: String,
        function: String,
        line: Int
    )
}

// MARK: - Default os.Logger Fallback

private struct DefaultOSLogger: PoolChatLogger {
    private static let subsystem = "ai.olib.stealthos.poolchat"

    func log(
        _ message: String,
        level: PoolChatLogLevel,
        category: PoolChatLogCategory,
        file: String,
        function: String,
        line: Int
    ) {
        let logger = os.Logger(subsystem: Self.subsystem, category: category.rawValue)
        let filename = (file as NSString).lastPathComponent
        let formattedMessage = "[\(filename):\(line)] \(function) - \(message)"

        switch level {
        case .debug:
            logger.debug("\(formattedMessage)")
        case .info:
            logger.info("\(formattedMessage)")
        case .warning:
            logger.warning("\(formattedMessage)")
        case .error:
            logger.error("\(formattedMessage)")
        case .critical:
            logger.critical("\(formattedMessage)")
        }
    }
}

private let _defaultLogger: PoolChatLogger = DefaultOSLogger()

// MARK: - Global Log Function

/// Package-level logging function matching Core's `log()` signature.
/// Delegates to the injected logger or falls back to `os.Logger`.
@available(macOS 14.0, iOS 17.0, *)
internal func log(
    _ message: String,
    level: PoolChatLogLevel = .info,
    category: PoolChatLogCategory = .general,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    let logger = PoolChatConfiguration.logger ?? _defaultLogger
    logger.log(message, level: level, category: category, file: file, function: function, line: line)
}
