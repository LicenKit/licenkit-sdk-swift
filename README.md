# LicenKit Swift SDK

LicenKit Swift SDK 是面向 macOS App 的 V1 授权客户端，提供统一的在线激活、在线校验、主动解绑、设备试用和签名凭证本地检查。

## 两种凭证模式

| 模式 | 服务端凭证 | 是否需要内置公钥 | 本地能力 |
| --- | --- | --- | --- |
| `opaque` | Activation ID + Machine Token | 否 | 只能表达缓存状态或需要联网，不能声称完成离线验签 |
| `signed` | 上述在线凭证 + Ed25519 Signed License Token | 是 | Token 有效期内可以验证签名、设备、Release 和权益 |

两种模式都使用相同的 `/activate`、`/validate` 和 `/deactivate` 在线协议。`signed` 只是在在线凭证之外增加本地可验证凭证，不替代 Machine Token。

## 配置

```swift
let configuration = LicenKitConfiguration(
    serverURL: URL(string: "https://license.example.com")!,
    accountID: "acc_01...",
    productID: "prd_01...",
    releaseVersion: "2.4.0",
    releasePlatform: "macos-universal",
    trustedSigningKeys: [
        "key_01...": "<Ed25519 public key>"
    ]
)

LicenKit.configure(with: configuration)
```

`opaque` 产品可以使用空 `trustedSigningKeys`。`signed` 响应中的 `signing_key_id` 必须命中这个随 App 受信发布链交付的字典；SDK 不会把运行时从授权服务下载的公钥自动升级为信任根。

## 调用

```swift
let activation = try await LicenKit.shared.activate(licenseKey: userInput)
let onlineStatus = try await LicenKit.shared.validate()
let localStatus = try await LicenKit.shared.checkLocalStatus()
let deactivation = try await LicenKit.shared.deactivate()
```

- `activate()` 和 `validate()` 始终联网，并自动携带 Account、Product、设备指纹、Release 版本和工件平台；
- `checkLocalStatus()` 仅在 `signed` 模式返回 `.validLocally`；
- `opaque` 模式本地检查返回 `.temporarilyUnverified`，默认 `isUsable == false`；
- `deactivate()` 远端失败时保留本地 Machine Token，便于重试释放席位；
- 正常 License 激活成功后清除本地 Product Trial Claim。

无需支付方式的设备试用使用 `startTrial()` 与 `validateTrial()`。Trial Token 只存入 Keychain；V1 试用不签发 Signed License Token，因此 `checkLocalStatus()` 只会返回 `.onlineValidationRequired`，不会根据本地到期时间声称试用仍有效。

## 安全与错误边界

- Keychain 保存 Activation ID、Machine Token、凭证模式、可选 Signed License Token、最近在线验证时间和非敏感条款摘要；
- 不长期保存注册码，也不自动同步注册码到 iCloud Keychain；
- 网络、DNS、TLS、超时、服务端 5xx、服务端业务错误、签名错误、Release 不合格和 Keychain OSStatus 分开表达；
- API 错误保留原始 `code`、`request_id` 与按字段脱敏后的 `details`；
- Signed License Token 要求 `alg=EdDSA`、`typ=licenkit-license+jwt`、受信 `kid`，并验证 Release 的 `ver`、`plt`、`rat` 与 `updates_until`。

## 技术边界

实现仅使用 Swift Concurrency、Foundation、CryptoKit、Security 和 IOKit，不引入第三方网络或密码学库。首发支持 macOS。

更多信息见 [API Reference](./docs/API_REFERENCE.md) 与 [Architecture](./docs/ARCHITECTURE.md)。
