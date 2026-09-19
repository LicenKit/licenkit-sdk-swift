# LicenKit Swift SDK

LicenKit Swift SDK 是面向 macOS App 的原生授权客户端。它连接 LicenKit Server，负责设备激活、在线验证、签名离线验证和 Keychain 凭据管理。

> 当前仓库正在对齐 LicenKit V1 协议。本文档描述目标合同，现有代码仍存在无条件要求公钥和 Offline Token 等差距，不能把本文档视为已经完成的功能声明。

## 两种验证模式

| 模式 | 服务端凭证 | SDK 是否需要公钥 | 断网能力 |
| --- | --- | --- | --- |
| `online` | Activation ID + Machine Token | 否 | 不能证明当前授权，只能表达缓存状态或需要联网 |
| `signed_offline` | 以上凭证 + Ed25519 Offline Token | 是 | Token 有效期内可以离线验证 |

Machine Token 是在线设备凭证，不是 Offline Token。SDK 不会把两者混为同一种授权能力。

## 目标配置

```swift
let configuration = LicenKitConfiguration(
    serverURL: URL(string: "https://license.example.com")!,
    accountID: "acc_01...",
    productID: "prd_01...",
    trustedSigningKeys: [
        "key_01...": "<Ed25519 public key>"
    ]
)

LicenKit.configure(with: configuration)
```

`trustedSigningKeys` 默认为空，因此纯在线产品不需要公钥。签名离线 License 返回的 key ID 必须在该字典中存在，否则 SDK 明确返回配置错误。

## 目标调用流程

```swift
let activation = try await LicenKit.shared.activate(licenseKey: userInput)
let localStatus = try await LicenKit.shared.checkLocalStatus()
let refreshedStatus = try await LicenKit.shared.validate()
```

- `activate` 必须联网；
- `checkLocalStatus` 在签名离线模式下验签，在在线模式下准确表达缓存或待联网状态；
- `validate` 使用 Activation ID、Machine Token 和设备指纹向服务端确认状态；
- `deactivate` 只有远端解绑成功后才报告完整成功。

## 本地凭据

SDK 在 Keychain 中保存 Activation ID、Machine Token、验证模式、可选 Offline Token 和最近验证时间。激活完成后默认不长期保存或通过 iCloud Keychain 同步注册码。

## 文档

- [架构与安全边界](./docs/ARCHITECTURE.md)
- [目标 API 合同](./docs/API_REFERENCE.md)
- [当前差距与实现计划](./docs/IMPLEMENTATION_PLAN.md)

服务端领域、支付和通知合同位于 LicenKit 主仓库的 `docs/` 目录。

## 技术边界

- Swift Concurrency；
- Foundation、CryptoKit、Security、IOKit；
- 不引入第三方网络或密码学库；
- 首发支持 macOS，其他 Apple 平台不作为 V1 完成条件。
