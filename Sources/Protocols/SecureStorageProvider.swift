// SecureStorageProvider.swift
// PoolChat
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Data Category

/// Storage category for organizing encrypted data.
/// Maps to Core's SecureDataStore.DataCategory at the bridge layer.
public enum StorageDataCategory: String, Sendable {
    case chat = "chat"
}

// MARK: - Secure Storage Provider Protocol

/// Protocol abstracting encrypted storage operations used by ChatHistoryService.
/// Implementors should provide AES-256-GCM (or equivalent) encrypted persistence.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public protocol SecureStorageProvider: AnyObject {

    /// Save a Codable object with encryption
    func save<T: Codable>(_ object: T, forKey key: String, category: StorageDataCategory) async throws

    /// Load and decrypt a Codable object
    func load<T: Codable>(_ type: T.Type, forKey key: String, category: StorageDataCategory) async throws -> T?

    /// Delete encrypted data for a key
    func delete(forKey key: String, category: StorageDataCategory) async throws

    /// List all keys in a category
    func listKeys(in category: StorageDataCategory) -> [String]

    /// Save raw Data with encryption
    func saveData(_ data: Data, forKey key: String, category: StorageDataCategory) async throws

    /// Load raw encrypted Data
    func loadData(forKey key: String, category: StorageDataCategory) async throws -> Data?
}
