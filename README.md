# LicenKit Swift SDK

LicenKit Swift SDK 是面向 macOS App 的 V1 授权客户端。它用同一个快照模型表达 License、Product/设备 Trial、无凭据设备和 Release 资格，并把业务终态与网络/协议失败分开。

> 当前仓库内容是本地实现，不表示该版本已经发布，也不表示对应 LicenKit Server 已经部署到生产环境。

## 凭证模式

- `opaque`：保存 Machine Token；授权状态来自近期服务端校验，没有可离线验签的权益载荷。
- `signed`：使用相同 Machine Token，并额外保存由 App 内置 Ed25519 公钥验证的 Signed License Token。

两种模式共享 `/activate`、`/validate` 和 `/deactivate`。Trial 首次通过 `/trials/claim` 领取，后续也走统一 `/validate`。

## 快速开始

```swift
let configuration = LicenKitConfiguration(
    serverURL: URL(string: "https://license.example.com")!,
    instanceID: "ins_01...",
    productID: "prd_01...",
    releaseVersion: "2.4.0",
    releasePlatform: "macos-universal",
    trustedSigningKeys: [
        "key_01...": "base64-encoded-ed25519-public-key"
    ]
)

LicenKit.configure(with: configuration)

switch await LicenKit.shared.validate() {
case .success(let snapshot, let metadata):
    print(snapshot.state, metadata.requestID as Any)

case .notPerformed(.cooldown, let cached, _):
    print(cached?.state as Any)

case .failure(let error, let lastKnown, let metadata):
    print(error, lastKnown?.state as Any, metadata.requestID as Any)
}
```

写操作也返回显式结果，不通过 `throws` 隐藏上次状态：

```swift
let activation = await LicenKit.shared.activate(licenseKey: userInput)
let trial = await LicenKit.shared.startTrial()
let deactivation = await LicenKit.shared.deactivate()
```

## 宿主应用应遵守的边界

- 只在 `EntitlementSnapshot.isUsable(at:)` 为 `true` 时启用授权功能；`state` 为 active 并不自动绕过校验窗口或 Token 到期。
- `validate()` 同时执行 Server 建议间隔与硬编码 30 秒门槛；Signed Token 过期或无效只绕过建议间隔。命中门槛时返回 `.notPerformed(.cooldown, ...)`，并发调用共享同一请求 Task。
- 冷却只约束 `validate()`；`activate()`、`startTrial()` 与 `deactivate()` 不受限制，也不会启动该冷却。SDK 不在门槛结束时自动联网。
- 合法 `/validate` 业务响应和明确 HTTP 失败会更新最近响应时间；DNS/TLS/超时等无 HTTP 响应失败及 2xx 非法正文不会更新。HTTP 失败不推进 `validatedAt`。
- `failure.lastKnownValue` 只用于展示和故障上下文，不能冒充本次校验成功。
- `businessCode`、安全的 `details` 与 `OperationMetadata.requestID` 应进入诊断链路；Registration Key、Machine Token、Trial Token 和 Signed Token 不得写入日志。
- `deactivate()` 仅在服务端确认后清除 License 凭据；远端失败时保留 Machine Token 以便重试。
- Signed Token Payload 只保存绝对 `exp`；明文到期字段必须与 `exp` 对齐。`exp` 取“签发时间 + License 快照 TTL”与 License 最终有效截止时间（如有）中的较早值；Plan 的原始 TTL 不进入 Token，也不要求覆盖 3600 秒建议间隔。
- Product/设备 Trial 不等于 Paddle 免费订阅试用。后者得到普通 License Key，应调用 `activate()`。

## 文档

- [API 参考](./docs/API_REFERENCE.md)
- [架构与安全边界](./docs/ARCHITECTURE.md)
- [本地实现状态](./docs/IMPLEMENTATION_PLAN.md)
- 服务端仓库中的[统一客户端校验开发指南](https://github.com/LicenKit/licenkit/blob/main/docs/zh-CN/unified-client-validation-guide.md)

## 平台与依赖

实现使用 Swift Concurrency、Foundation、CryptoKit、Security 和 IOKit，不引入第三方网络或密码学库。当前首发支持 macOS。
