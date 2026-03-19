# Contributing to PoolChat

Thank you for your interest in contributing to PoolChat. This guide will help you get started.

## Getting Started

1. Fork the repository.
2. Clone your fork locally.
3. Create a new branch from `main` for your work.

## Development

- **Xcode**: 16.0 or later
- **Platforms**: iOS 17+, macOS 14+
- **Language**: Swift 6
- **Dependencies**: PoolChat depends on [ConnectionPool](https://github.com/Olib-AI/ConnectionPool). Ensure it resolves correctly through Swift Package Manager.

Open `Package.swift` in Xcode or add the package to your project to build and run tests.

## Code Style

- Follow the patterns and conventions already present in the codebase.
- Use Swift 6 strict concurrency. Mark view-layer entry points with `@MainActor` and use the `nonisolated` delegate pattern for callbacks.
- Keep files focused and reasonably sized.

## Pull Requests

- Keep each PR focused on a single feature or fix.
- Describe **why** the change is needed, not just what changed.
- Ensure all tests pass and there are no new warnings before submitting.
- Link any related issues in the PR description.

## Issues

- Use the provided issue templates (bug report or feature request).
- Search existing issues before creating a new one to avoid duplicates.

## License

By contributing to PoolChat, you agree that your contributions will be licensed under the [MIT License](LICENSE).
