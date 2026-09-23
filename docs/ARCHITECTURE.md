# Swift SDK 架构与安全边界

## 目标

SDK 的核心不是“缓存一个布尔值”，而是保存一份带来源、服务端时间、有效窗口和原始业务诊断的授权快照。这样宿主 App 可以区分：当前可用、服务端确认的业务终态、近期缓存、纯本地状态，以及一次没有成功的调用。

本文描述 SDK 仓库中的本地架构，不代表 Swift 包已发布或服务端已部署。

## 模块职责

- `LicenKit`：面向宿主 App 的 Facade，组织激活、统一校验、Trial 领取、解绑和快照读取，不包含 UI。
- `OperationCoordinator`：顺序化会修改凭据或快照的操作；并发 `validate()` 共享同一 Task。
- `LicenKitAPIClient`：实现 V1 JSON Envelope，区分传输错误、API 错误和协议错误，并保留 Request ID 与安全 details。
- `EntitlementSnapshot`：统一保存业务状态、来源、新鲜度边界、业务码和诊断信息。
- `CredentialStore` / `KeychainStore`：分别保存 License、Trial 与快照；秘密不进入普通偏好设置。
- `Ed25519Verifier`：验证 `signed` 模式的紧凑 JWS 和受信 `kid`。
- `ClaimsEvaluator`：核对 Instance、Product、Activation、设备、Release 与各层到期时间。
- `MacOSFingerprintProvider`：生成稳定设备指纹。

## 统一数据流

```text
宿主 App
  │
  ├─ activate / startTrial / deactivate ─┐
  │                                      ├─ OperationCoordinator
  └─ validate ── 同期调用共享一个 Task ─┘
                     │
                     ├─ 读取 Keychain 中的 License / Trial / none
                     ├─ 检查 lastValidateResponseAt 与适用的两个门槛
                     ├─ 命中门槛 → notPerformed(cooldown)
                     └─ 门槛已结束 → /client/validate
                                      │
                                      ├─ state：统一业务状态
                                      ├─ validation：服务端时间与建议间隔
                                      ├─ meta.request_id：链路诊断
                                      └─ credential_update：仅 License
```

所有凭据和快照写入都位于同一顺序化边界内。这样一次较早开始的校验不会在激活、Trial 领取或解绑之后才写回旧状态。同步的进程内 `currentSnapshot` 由锁保护；持久化来源仍是 Keychain。

## 结果层与状态层

SDK 分两层表达事实：

1. `LicenKitResult` 回答“本次操作发生了什么”：成功、因冷却未执行，或失败。
2. `EntitlementSnapshot.state` 回答“授权业务事实是什么”：需要激活、Trial、License、Release 不合格或未知。

服务端认证凭据后得到的到期、暂停、吊销和 Activation 失效属于业务状态，因此返回 `.success(snapshot)`；无效凭据、Product 不存在/已归档、Trial 配置损坏、传输和协议问题属于 `.failure`。失败结果可以携带 `lastKnownValue`，但不会篡改成新的业务状态。

## 新鲜度模型

服务端提供 `validated_at` 与可空的 `validation_interval_seconds`。客户端保留原始值，同时计算 3600 至 86400 秒范围内的生效间隔；空值使用 3600 秒。

活动权益的可用截止时间为：

```text
min(
  validated_at + effective_validation_interval,
  business_expires_at（若有）,
  signed_token_exp（若有）
)
```

只有当前时间早于该截止时间，且业务状态仍为 active，`isUsable(at:)` 才为真。服务端返回的 License `expires_at` 已包含支付订阅的宽限期；客户端不重复计算。

业务新鲜度与请求冷却不是同一状态。`validatedAt` 来自合法业务响应；`lastValidateResponseAt` 表示最近一次取得明确 `/validate` Server 结果的本地时间。普通路径同时检查 `lastValidateResponseAt + effectiveInterval` 与 `lastValidateResponseAt + 30 seconds`。Signed Token 过期或本地验证失败时跳过前者，但仍检查后者。

只有两类 `/validate` 结果会写 `lastValidateResponseAt`：合法的成功业务数据，以及具有明确 HTTP 状态的失败。DNS、TLS、超时、断网等没有 HTTP 响应的失败和 2xx 非法业务数据不写该时间；HTTP 失败也不写 `validatedAt` 或新业务快照。`activate()`、`startTrial()` 和 `deactivate()` 不读写请求冷却时间。

## 来源语义

- `server`：本次从服务端获得的快照。
- `cache`：近期服务端快照仍有效，未发起新的网络请求。
- `signedLocal`：复用近期快照前重新验证了本地 Signed Token。
- `local`：纯本地构造、没有服务端确认，例如无 License 凭据时解绑。

来源与可用性是两个维度。`source=server` 仍可能是已到期或已吊销；`source=cache` 仍须通过新鲜度；`source=local` 不能伪造 `validatedAt`。

## 凭证信任模型

`opaque` 与 `signed` 共享在线协议和 Machine Token。差异只在 `signed` 额外返回 Signed License Token：

```text
online response
  ├─ opaque → 签名字段必须为空 → 保存在线凭据与快照
  └─ signed → 内置 kid → Ed25519 验签 → Claims/Release/状态一致性 → 保存
```

运行时从授权服务下载的公钥不能成为信任根。密钥轮换通过 App 同时内置新旧 key ID 实现；服务端撤销密钥不能瞬间改变完全离线设备上的旧 Token，风险窗口由 Token TTL 和受信 App 更新共同限制。

Signed 模式还检查：

- Token `ins` 与 SDK 的 `instanceID` 完全相同；旧 `acc` Claim 不接受；
- `prd/act/fp/ver/plt` 与当前 Product、Activation、设备和构建一致；
- 外层 `signed_license_token_expires_at` 等于签名内 `exp`；
- active License 的 features、更新期限与含支付宽限期的最终到期时间等于签名 Claims；
- Token Payload 只包含绝对 `exp`，不包含 Plan 的 TTL 原值；`exp` 取“签发时间 + License 快照 TTL”与 License 最终有效截止时间（如有）中的较早值，TTL 可以短于 3600 秒建议间隔。

## Trial 与无凭据状态

Trial Claim 与 License 凭据分别存储。首次领取使用 `/trials/claim`；后续统一校验使用 `credential.kind=trial`。Trial Token 不参与 Ed25519 验签。正常 License 激活并保存后清除同设备 Trial 凭据。

没有本地凭据时，统一校验使用 `credential.kind=none`。对 active Product，它可以返回 Trial available、not enabled、already claimed 或 Release 不合格；Product 不存在/已归档和 Trial 配置损坏仍是失败，不伪装成 Trial 不可用。

## 被动冷却边界

冷却只在宿主主动调用 `validate()` 时判断。门槛结束不会创建后台任务、监听网络恢复、发出事件或自动重试。显式激活、Trial 领取和解绑始终执行自身操作；它们返回的 `validatedAt` 是业务事实，不能冒充 `/validate` 最近响应时间。

## 错误、诊断与脱敏

- DNS、TLS、超时、一般网络错误和 HTTP 5xx 属于传输错误。
- HTTP 5xx 仍保留响应中的安全 code、Request ID 与 details。
- 4xx 请求/凭据/配置拒绝保留原始 code、message、Request ID 和 details。
- 服务端业务终态保留在快照的 `businessCode` 与 `details` 中。
- details 递归按字段名脱敏 Token、Secret、密码、Registration Key 和 Authorization，不隐藏整个错误包。
- 签名、协议、设备指纹和 Keychain OSStatus 分开表达。

## 解绑顺序

1. 从 Keychain 读取 Activation ID 与 Machine Token。
2. 没有 License 凭据时，不发远端请求；写入 `source=local` 的需要激活快照，并返回 `wasDeactivated=false`。
3. 有凭据时调用 `/deactivate`。
4. 远端失败时返回 `.failure`，保留凭据用于重试。
5. 远端确认后清理 License 凭据，写入本地需要激活快照，并返回 `wasDeactivated=true`。

## 发布边界

单元测试和 `swift build` 只能证明仓库中的本地代码。Package 发布、Server 部署、真实 Worker/D1、Keychain 权限和宿主 App 签名环境必须分别验收，不能用本地测试结果代替生产闭环。
