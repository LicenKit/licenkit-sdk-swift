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
    productID: "prd_01...",
    signingPublicKey: "base64-encoded-ed25519-public-key"
)

LicenKit.configure(with: configuration)

switch await LicenKit.shared.validate(trigger: .silent) {
case .success(let snapshot, let metadata):
    print(snapshot.state, metadata.requestID as Any)

case .notPerformed(.minimumInterval(let retryAfter), let cached, _):
    print("校验请求需等待 \(retryAfter) 秒", cached?.state as Any)

case .notPerformed(.productInterval, let cached, _):
    print(cached?.state as Any)

case .failure(let error, let lastKnown, let metadata):
    print(error, lastKnown?.state as Any, metadata.requestID as Any)
}

// 用户点击“检查授权”或“重试”时使用 .userInitiated。
let manualResult = await LicenKit.shared.validate(trigger: .userInitiated)
```

公共初始化参数只有：

- `serverURL`：LicenKit 服务根地址；
- `productID`：Admin 产品页展示的全局唯一 Product ID；
- `signingPublicKey`：Admin 产品页交付的 Ed25519 公钥。仅使用 `opaque` 凭证时可省略；使用 `signed` 凭证时必须提供。

SDK 从宿主 App Bundle 的 `CFBundleShortVersionString` 读取版本号；操作系统固定识别为 `macos`，主可执行文件架构单独推导为 `arm64`、`x86_64` 或 `universal`。这些值作为 `release_version + release_platform + release_arch` 随请求发送，但宿主业务代码不需要配置。缺少构建信息时操作会明确返回配置错误。网络超时固定为 SDK 内部的 15 秒；Keychain 只供当前 App 使用，不暴露 Access Group 配置。

Product Release 不是所有授权的前置登记表。只有永久授权同时存在 `updates_until` 时，Server 才尝试用这组构建身份查询发布时间；未登记时按宽容策略继续放行，查到且 `released_at > updates_until` 时才返回需要更新权益。Signed License Token 不包含 Release ID、发布时间或独立 `exp`，本地只验证签名、构建身份、设备绑定和 License 业务期限。

写操作也返回显式结果，不通过 `throws` 隐藏上次状态：

```swift
let activation = await LicenKit.shared.activate(licenseKey: userInput)
let trial = await LicenKit.shared.startTrial()
let deactivation = await LicenKit.shared.deactivate()
```

## 宿主应用应遵守的边界

- 只在 `EntitlementSnapshot.isUsable(at:)` 为 `true` 时启用授权功能。在线复核间隔与离线宽限期只决定联网调度和提示强度，不会单独停用授权。
- `validate(trigger:)` 明确区分宿主静默复核与用户主动复核。所有新请求均受固定 30 秒限制；Product 在线复核间隔只限制静默调用。已知 Trial/License 首次到期、Release 身份变化后首次复核，以及 Signed Token 本地失效时，静默调用可跳过 Product 间隔。
- 两种未执行原因分别为 `.minimumInterval` 与 `.productInterval`，对应独立的 SDK 本地代码；前者可在用户主动操作时提示剩余等待时间，后者通常无需展示。命中任一门槛都不发网络请求。
- 30 秒从上次实际发出 `/validate` 请求时起算，包括随后超时或收到非法响应的请求；Product 间隔仍从上次明确服务端响应时起算。并发请求共享结果；静默跳过不会吞掉用户主动复核。
- 两种门槛只约束 `validate`；`activate()`、`startTrial()` 与 `deactivate()` 不受限制，也不会启动该冷却。SDK 不在门槛结束时自动联网。
- 合法 `/validate` 业务响应和明确 HTTP 失败会更新最近响应时间；DNS/TLS/超时等无 HTTP 响应失败及 2xx 非法正文不会更新。HTTP 失败不推进 `validatedAt`。
- `failure.lastKnownValue` 只用于展示和故障上下文，不能冒充本次校验成功。
- `businessCode`、安全的 `details` 与 `OperationMetadata.requestID` 应进入诊断链路；Registration Key、Machine Token、Trial Token 和 Signed Token 不得写入日志。
- `deactivate()` 仅在服务端确认后清除 License 凭据；远端失败时保留 Machine Token 以便重试。
- Signed Token 不含 `exp`。Product 的 `validation_interval_seconds` 控制在线复核尝试频率；License Plan 的 `offline_grace_seconds` 在签发时固化到 License，超过后返回 `offlineGraceExceeded` 强提示但仍允许使用。
- `activate()` 与 `startTrial()` 在请求前把客户端生成的 Token 写为验证中凭据；响应丢失、进程退出或最终凭据写入失败后，显式重试会复用同一 Token，由服务端重复下发同一份正式凭据。`validate()` 不执行这两个动作，其他设备不能只凭注册码或相同指纹取得既有凭据。
- Product/设备 Trial 不等于 Paddle 免费订阅试用。后者得到普通 License Key，应调用 `activate()`。

## 文档

- [API 参考](./docs/API_REFERENCE.md)
- [架构与安全边界](./docs/ARCHITECTURE.md)
- [本地实现状态](./docs/IMPLEMENTATION_PLAN.md)
- 服务端仓库中的[统一客户端校验开发指南](https://github.com/LicenKit/licenkit/blob/main/docs/zh-CN/unified-client-validation-guide.md)

## 平台与依赖

实现使用 Swift Concurrency、Foundation、CryptoKit、Security 和 IOKit，不引入第三方网络或密码学库。当前首发支持 macOS。
