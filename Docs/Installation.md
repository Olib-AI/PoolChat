# Installation

[Back to README](../README.md)

## Contents

- [Swift Package Manager](#swift-package-manager)
- [Local Package (XcodeGen)](#local-package-xcodegen)
- [Requirements](#requirements)

## Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Olib-AI/PoolChat.git", from: "1.5.0")
]
```

Then add the dependency to your target:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "PoolChat", package: "PoolChat")
        ]
    )
]
```

**Note:** PoolChat depends on [ConnectionPool](https://github.com/Olib-AI/ConnectionPool). SPM will resolve it automatically.

## Local Package (XcodeGen)

If using XcodeGen, add to your `project.yml`:

```yaml
packages:
  PoolChat:
    path: LocalPackages/PoolChat

targets:
  YourApp:
    dependencies:
      - package: PoolChat
        product: PoolChat
```

Then regenerate: `xcodegen generate`

## Requirements

- iOS 17.0+
- macOS 14.0+
- Swift 6.0+
- Xcode 16+
- [ConnectionPool](https://github.com/Olib-AI/ConnectionPool) (resolved automatically via SPM)

Calling features additionally need microphone and camera usage descriptions in your `Info.plist`, and audio and video capture is only testable on physical devices.

## Next Steps

- [Quick Start](QuickStart.md) for configuration, key exchange, and sending messages
- [Configuration](Configuration.md) for the logger and storage provider protocols
