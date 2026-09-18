# LicenKit Swift SDK

[English](README.md) | **简体中文**

> 现代、轻量、高性能的 [LicenKit](https://github.com/LicenKit/licenkit) 软件授权与脱网密码学离线验签原生 Swift SDK。

---

## 🎯 概览 (Overview)

**LicenKit Swift SDK** (`licenkit-sdk-swift`) 是专为 Apple 开发者打造的原生软件授权接入库。首期工程聚焦于 **macOS 桌面平台**，提供极致轻量、零第三方外部依赖、高安全的客户端授权验证与试用管理能力。

### 核心亮点 (Key Features)

- 🔒 **零外部依赖 (Zero External Dependencies)**：完全基于 Apple 原生技术栈（`Foundation`、`CryptoKit`、`Security`、`IOKit`），无需引入任何三方二进制或 Pod，构建极快、体积极小、零供应链安全风险。
- ⚡ **原生现代并发 (Swift Concurrency Native)**：核心 API 全面基于 `async/await` 现代异步并发范式设计，强类型且线程安全。
- 🛡️ **双模验签保障 (Dual-Mode Verification)**：
  - **在线心跳探活**：与 LicenKit 边缘引擎（Cloudflare Workers + D1）毫秒级同步席位激活、宽限期状态及续费情况；
  - **脱网纯离线数学验签**：基于 **Ed25519** 椭圆曲线数字签名算法，在完全脱网环境下秒级完成抗篡改、抗伪造数学验签。
- 🎁 **开箱即用免费试用 (Free Trial Support)**：内置单设备免密免费试用申请（`requestTrial`），离线签发 `LK-TRIAL` Token，单机防刷，支持试用期到期无缝升级商业授权。
- 💻 **原生硬件指纹绑定 (Hardware Fingerprinting)**：调用 macOS 系统级 `IOPlatformUUID` 提取唯一设备特征，防止 License 跨机器被恶意扩散或盗用，并配备高可用安全回退哈希机制。
- 🔑 **系统级凭据保护 (Keychain Security)**：激活凭据与离线 License Token 自动安全保存在 macOS Keychain 中，拒绝以明文 Plist 或本地文件形式暴露，支持 iCloud Keychain 跨设备无感漫游恢复。
- 🎛️ **功能特性门禁 (Feature Entitlements)**：内置多级功能标记（Feature Flags）判定接口，按需解锁高级功能模块。

---

## 📦 安装集成 (Installation)

### Swift Package Manager (SPM)

在 Xcode 项目中：
1. 点击 **File** -> **Add Package Dependencies...**
2. 在搜索框输入仓库地址：
   ```text
   https://github.com/LicenKit/licenkit-sdk-swift.git
   ```
3. 选择版本规则（推荐：*Up to Next Major Version*，从 `0.2.0` 起），并将 `LicenKit` 添加到您的 macOS App Target 中。

或者在您的 `Package.swift` 中声明依赖：

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyMacApp",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/LicenKit/licenkit-sdk-swift.git", from: "0.2.0")
    ],
    targets: [
        .target(
            name: "MyMacApp",
            dependencies: [
                .product(name: "LicenKit", package: "licenkit-sdk-swift")
            ]
        )
    ]
)
```

---

## 🚀 快速上手 (Quick Start)

### 1. 初始化客户端

建议在应用启动时（例如 `NSApplicationDelegate` 或 `@main App` 的初始化方法中）配置 LicenKit：

```swift
import LicenKit

let config = LicenKitConfiguration(
    serverUrl: "https://licenkit-api.yourdomain.com",
    accountId: "acc_live_9x8a7b6c",
    productId: "prd_macos_pro",
    publicKey: "MCowBQYDK2VwAyEA9F7G4hH..." // 32字节 Ed25519 公钥 (Base64 或 SPKI)
)

// 设置全局共享实例
LicenKit.configure(with: config)
```

### 2. 检查本地授权（极速静默核验）

应用每次启动时，首选执行纯本地脱网检查，实现 0 毫秒感知进入主界面：

```swift
Task {
    do {
        // 自动从 Keychain 读取缓存的 Token（兼容商业版与试用版）并执行 Ed25519 验签与指纹校验
        let status = try await LicenKit.shared.verifyOffline()
        
        switch status {
        case .valid(let claims):
            print("商业许可证有效！到期时间: \(claims.expirationDate)")
            // 正常解锁全部商业特性
            
        case .trial(let claims):
            print("正在免费试用中！到期时间: \(claims.expirationDate)")
            // 开放试用期特性
            
        case .inGracePeriod(let claims, let remainingSeconds):
            print("脱网宽限期中，剩余离线时间: \(remainingSeconds) 秒")
            // 允许使用，并在后台静默发起在线心跳
            Task { _ = try? await LicenKit.shared.validate() }
            
        case .expired:
            print("许可证已过期，请续订")
            
        case .trialExpired:
            print("免费试用已结束，提示用户购买商业版许可证")
            
        case .untrusted(let reason):
            print("未通过验签: \(reason)")
        }
    } catch LicenKitError.unactivated {
        print("当前机器尚未激活或认领试用，提示用户输入序列号或点击免费试用")
    }
}
```

### 3. 一键认领免密试用 (Free Trial)

当用户首次打开软件并点击“开始免费试用”时：

```swift
Task {
    do {
        let result = try await LicenKit.shared.requestTrial()
        if result.expired {
            print("该设备试用期已结束，无法重复认领")
        } else {
            print("试用认领成功！试用期至: \(result.expiresAt ?? Date())")
            // 本地 Keychain 已自动缓存试用 Token，再次启动自动免密脱网放行
        }
    } catch {
        print("请求试用失败: \(error)")
    }
}
```

### 4. 在线激活商业许可证 (Online Activation)

当用户输入购买的激活码（`LIC-XXXX-XXXX-XXXX-XXXX`）时：

```swift
Task {
    do {
        let result = try await LicenKit.shared.activate(licenseKey: "LIC-ABCD-1234-EFGH-5678")
        print("激活成功！机器席位 ID: \(result.machineId)")
        // 本地 Keychain 已自动升级为商业授权凭据与 Ed25519 签名 Token
    } catch let error as LicenKitError {
        switch error {
        case .maxMachinesReached:
            print("激活失败：当前授权席位已满")
        case .networkError(let message):
            print("网络连接失败，请检查网络设置: \(message)")
        case .apiError(let code, let msg):
            print("服务端拒绝 [\(code)]: \(msg)")
        default:
            print("激活遇到异常: \(error)")
        }
    }
}
```

### 5. 功能特性门禁校验 (Feature Entitlements)

根据授权或试用策略中配置的 Feature 列表保护高级能力：

```swift
if LicenKit.shared.hasFeature("pro_export_4k") {
    // 渲染或启用 4K 导出模块
} else {
    // 提示升级或禁用该选项
}
```

### 6. 解绑席位 (Deactivation)

当用户换机或主动退出授权时：

```swift
Task {
    do {
        try await LicenKit.shared.deactivate()
        print("已成功解绑本机席位，已清空本地 Keychain 凭据")
    } catch {
        print("解绑席位失败: \(error)")
    }
}
```

---

## 📚 深入文档 (Documentation)

更详尽的技术规范与进阶主题请参考 `docs/` 目录：

- 🏛️ **[架构设计与安全模型 (ARCHITECTURE.md)](./docs/zh-CN/ARCHITECTURE.md)**：深入了解分层设计、双模验证工作流、硬件指纹提取机理与 iOS 跨端兼容预留。
- 🧩 **[模块划分与功能说明 (MODULES_AND_FEATURES.md)](./docs/zh-CN/MODULES_AND_FEATURES.md)**：核心模块（Core、Crypto、Network、Storage、Platform）详细功能设计与运行态状态机。
- 📖 **[API 规范与参考手册 (API_REFERENCE.md)](./docs/zh-CN/API_REFERENCE.md)**：完整公开类、接口签名、配置项字典与全量错误码列表。

---

## 📄 许可协议 (License)

本项目基于 [Apache-2.0 License](LICENSE) 开源协议分发与使用。
