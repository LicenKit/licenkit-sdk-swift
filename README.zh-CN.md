# LicenKit Swift SDK

[English](./README.md) | **简体中文**

为你的 macOS App 接入 [LicenKit](https://github.com/LicenKit/licenkit)，实现注册码激活、设备试用和授权校验。

- 使用注册码激活授权，或为当前设备领取试用。
- 启动时恢复已保存的授权，再向服务端核验。
- 使用 App 内置的 Ed25519 公钥，在离线时验证签名授权。
- 将凭据保存在 macOS 钥匙串中，正式环境与测试环境分别存储。
- 使用 Swift 并发（`async`/`await`），无需第三方依赖。

## 环境要求

- macOS 12 或更新版本。
- Swift 5.9 或更新版本。
- 已配置产品的 LicenKit 服务端。

## 安装

在 Xcode 中添加软件包依赖，使用以下仓库地址：

```text
https://github.com/LicenKit/licenkit-sdk-swift.git
```

将 **LicenKit** 库添加到 App 的构建目标，然后导入：

```swift
import LicenKit
```

## 快速接入

### 1. 配置 SDK

在使用 `LicenKit.shared` 前完成一次配置：

```swift
import Foundation
import LicenKit

let configuration = LicenKitConfiguration(
    serverURL: URL(string: "https://licenses.example.com")!,
    productID: "YOUR_PRODUCT_ID",
    signingPublicKey: "YOUR_PRODUCT_SIGNING_PUBLIC_KEY"
)

LicenKit.configure(with: configuration)
```

将示例值替换为你的服务端地址，以及管理后台产品页中显示的对应值。

| 参数 | 填写内容 |
| --- | --- |
| `serverURL` | LicenKit 服务根地址，不包含 `/api/v1/client`。 |
| `productID` | 管理后台产品页中的全局唯一产品编号。 |
| `signingPublicKey` | 随 App 内置的产品 Ed25519 公钥。使用 `signed` 授权时必填；仅使用 `opaque` 授权时可省略。 |
| `environment` | 默认 `.live`，用于正式环境；测试环境的 App 构建需显式传入 `.sandbox`。 |

SDK 从 App Bundle 的 `CFBundleShortVersionString` 读取版本号，并自动识别可执行文件架构（`arm64`、`x86_64` 或 `universal`）。请确保 App 已设置版本号；缺少构建信息时会返回配置错误。

### 2. 启动时恢复授权

以下示例放在 App 的异步启动流程中执行。先恢复已保存的授权或试用，这一步不发起网络请求。

```swift
let local = await LicenKit.shared.restoreLocalEntitlement()
var canUseProtectedFeatures: Bool

switch local {
case .usable:
    canUseProtectedFeatures = true
case .confirmedBlocked, .verificationRequired:
    canUseProtectedFeatures = false
}

// 此时就用 canUseProtectedFeatures 更新界面和受授权保护的功能。
```

`.usable` 表示本机保存的授权依据允许使用。`.confirmedBlocked` 恢复此前已确认的状态，例如授权到期或被撤销。`.verificationRequired` 表示需要重新核验后才能开放功能，例如首次启动，或已保存的凭据无法通过验证。

### 3. 向服务端核验

应用本机判断后，在后台向服务端核验，取得新状态时更新功能访问权限：

```swift
switch await LicenKit.shared.validate(trigger: .silent) {
case .success(let snapshot, _):
    canUseProtectedFeatures = snapshot.isUsable()
    // 根据这个结果更新界面和受授权保护的功能。

case .notPerformed:
    // 尚未到下次校验时间，没有发送请求。
    break

case .failure(_, _, let metadata):
    // 核验失败本身不表示授权已被撤销。
    print("授权核验失败，请求编号：", metadata.requestID ?? "无")
}
```

App 运行期间也需遵守授权和试用的到期时间，网络失败不会延长有效期。SDK 不会自动安排核验，也不会自动更新 App 界面。

## 常用操作

激活用户输入的注册码：

```swift
let activation = await LicenKit.shared.activate(licenseKey: "LICENSE_KEY_FROM_USER")
```

为当前设备领取试用：

```swift
let trial = await LicenKit.shared.startTrial()
```

用户点击“检查授权”或“重试”时主动核验：

```swift
let validation = await LicenKit.shared.validate(trigger: .userInitiated)
```

解绑当前设备，释放授权名额：

```swift
let deactivation = await LicenKit.shared.deactivate()
```

激活、试用和校验返回 `LicenKitResult`，分为 `.success`、`.notPerformed` 和 `.failure`。调用成功表示取得了授权状态，是否允许使用还需检查 `snapshot.isUsable()`。激活成功时，授权快照位于成功返回值的 `activationData.snapshot`。

解绑返回 `DeactivationResult`。若结果是 `.remoteConfirmedLocalRepairRequired`，表示服务端已解绑，但本机清理还需重试。此时应停止使用旧授权，并再次调用 `deactivate()` 完成清理。完整结果类型见 [API 参考](./docs/API_REFERENCE.md)。

设备试用与支付平台的订阅免费试用是两回事。如果用户通过订阅试用获得了注册码，应调用 `activate(licenseKey:)`。

## 授权模式

凭据模式由产品的授权配置决定：

| 模式 | 本机验证方式 |
| --- | --- |
| `opaque` | 恢复与当前设备凭据匹配的服务端授权记录，没有可独立验签的授权内容。 |
| `signed` | 额外使用 App 内置的 Ed25519 公钥验证签名授权令牌。 |

两种模式的在线授权校验都使用激活记录编号和设备指纹。设备试用使用试用记录编号和设备指纹，授权与试用凭据由 SDK 保存在钥匙串中。

## 接入注意事项

- **先恢复，再联网。** 启动时先等待 `restoreLocalEntitlement()` 完成，再发起在线核验。`currentSnapshot`、失败结果中的 `lastKnownValue`，以及 `.notPerformed` 中的缓存值，都不能代替这次本机验证。
- **按场景选择核验方式。** 启动、回到前台或网络恢复后的后台核验使用 `.silent`；用户主动操作使用 `.userInitiated`。两者的新校验请求至少间隔 30 秒，失败的请求也计入间隔。产品配置的核验间隔仅限制后台调用；到期、App 构建变化或签名令牌失效时，SDK 可以提前核验。
- **跳过核验通常无需打扰用户。** `.notPerformed` 不发送请求。用户主动核验遇到 `.minimumInterval` 时，可提示还需等待多久；`.productInterval` 通常无需提示。间隔结束后 SDK 不会自动重试。激活、领取试用和解绑不受这些校验间隔限制。
- **区分联网失败和授权状态。** 到期、暂停和撤销属于授权状态；请求失败表示本次核验未完成。超过离线宽限期会产生 `offlineGraceExceeded`，用于提示授权信息需要更新，不会仅因此停用仍有效的授权。
- **诊断信息不要包含秘密。** 排查问题时使用 `businessCode`、已脱敏的 `details` 和 `OperationMetadata.requestID`。不要记录注册码或签名授权令牌。

## 文档

以下详细文档使用简体中文：

- [API 参考](./docs/API_REFERENCE.md)
- [架构与安全](./docs/ARCHITECTURE.md)
- [服务端接入指南](https://github.com/LicenKit/licenkit/blob/main/docs/zh-CN/unified-client-validation-guide.md)

版本变更见 [更新日志](./CHANGELOG.md)，许可证条款见 [LICENSE](./LICENSE)。
