// PoolChatAppLifecycle.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - App State

/// Represents the runtime state of the Pool Chat application.
/// Mirrors Core's AppState for lifecycle management.
@available(macOS 14.0, iOS 17.0, *)
public enum PoolChatAppState: String, Sendable {
    /// App is not running, no resources allocated
    case terminated
    /// App is running in background, reduced resources
    case suspended
    /// App is running and visible but not focused
    case background
    /// App is running, visible, and focused (active)
    case active
}

// MARK: - App Lifecycle Protocol

/// Protocol for managing Pool Chat's runtime lifecycle.
/// Equivalent to Core's AppRuntimeManaged protocol.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public protocol PoolChatAppLifecycle: AnyObject {
    /// Current runtime state
    var runtimeState: PoolChatAppState { get }

    /// Called when app should transition to active state (focused and visible)
    func activate()

    /// Called when app is visible but not focused
    func moveToBackground()

    /// Called when app is minimized or hidden
    func suspend()

    /// Called when app is being closed
    func terminate()

    /// Memory pressure notification
    func handleMemoryWarning()
}

// MARK: - Default Implementations

@available(macOS 14.0, iOS 17.0, *)
public extension PoolChatAppLifecycle {
    func activate() {}
    func moveToBackground() {}
    func suspend() {}
    func terminate() {}
    func handleMemoryWarning() {}
}
