# Swift SDK 架构与安全边界

## 目标

SDK 的核心不是“缓存一个布尔值”，而是保存一份带来源、服务端时间、有效窗口和原始业务诊断的授权快照。这样宿主 App 可以区分：当前可用、服务端确认的业务终态、近期缓存、纯本地状态，以及一次没有成功的调用。

本文描述 SDK 仓库中的本地架构，不代表 Swift 包已发布或服务端已部署。

## 模块职责

- `LicenKit`：面向宿主 App 的 Facade，组织激活、本机证据恢复、在线复核、Trial 领取和解绑，不包含 UI。
- `OperationCoordinator`：顺序化会修改凭据或快照的操作；同期实际校验请求共享同一 Task，静默跳过不会吞掉用户主动校验。
- `LicenKitAPIClient`：实现 V1 JSON Envelope，区分传输错误、API 错误和协议错误，并保留 Request ID 与安全 details。
- `EntitlementSnapshot`：统一保存业务状态、来源、新鲜度边界、业务码和诊断信息。
- `CredentialStore` / `KeychainStore`：分别保存 License、Trial、与凭据绑定的快照、最近一次校验请求尝试和解绑恢复记录；秘密不进入普通偏好设置。
- `Ed25519Verifier`：使用宿主内置的单个 Ed25519 公钥验证 `signed` 模式紧凑 JWS，并校验响应 Key ID 与 Token `kid` 一致。
- `ClaimsEvaluator`：核对 Product、Activation、设备、版本、操作系统、架构与各层到期时间；Instance 由 Server 通过全局唯一 Product ID 解析。
- `MacOSFingerprintProvider`：生成稳定设备指纹。

## 统一数据流

```text
宿主 App
  │
  ├─ restoreLocalEntitlement → 本机可信结论 → 宿主访问决策
  │
  ├─ activate / startTrial / deactivate ─┐
  │                                      ├─ OperationCoordinator
  └─ validate(trigger: .silent / .userInitiated) ─┘
                     │
                     ├─ 读取 Keychain 中的 License / Trial / none
                     ├─ 检查最近请求尝试 + 固定 30 秒
                     ├─ 静默调用再检查 Product 间隔及豁免条件
                     ├─ 命中门槛 → notPerformed(minimumInterval / productInterval)
                     └─ 记录请求尝试 → /client/validate
                                      │
                                      ├─ state：统一业务状态
                                      ├─ validation：服务端时间与建议间隔
                                      ├─ meta.request_id：链路诊断
                                      └─ credential_update：仅 License
```

本机恢复与所有凭据和快照写入位于同一顺序化边界内。宿主先等待本机结果，再启动在线复核；本机恢复本身不发请求。这样一次较早开始的校验不会在激活、Trial 领取或解绑之后才写回旧状态。同步的进程内 `currentSnapshot` 由锁保护，但它不是独立的冷启动放行依据；持久化来源仍是 Keychain。

## 结果层与状态层

SDK 分三层表达事实：

1. `LocalEntitlementResult` 回答“现有本机证据能否立即使用”：可用、已确认阻断，或需要核验。
2. `LicenKitResult` 回答“本次在线复核或领取、激活操作发生了什么”：成功、因间隔未执行，或失败；解绑另用 `DeactivationResult` 表达远端确认与本地清理阶段。
3. `EntitlementSnapshot.state` 回答“授权业务事实是什么”：需要激活、Trial、License、Release 不合格或未知。

服务端认证凭据后得到的到期、暂停、吊销和 Activation 失效属于业务状态，因此返回 `.success(snapshot)`；无效凭据、Product 不存在/已归档、Trial 配置损坏、传输和协议问题属于 `.failure`。失败结果可以携带 `lastKnownValue`，但不会篡改成新的业务状态。

## 新鲜度模型

服务端提供 `validated_at`、Product 级必填 `validation_interval_seconds`，以及 License 级可空 `offline_grace_seconds`。在线复核间隔范围为 3600 至 86400 秒；离线宽限期来自签发 License 时固化的 Plan 配置。

`freshness(at:)` 在在线复核间隔内返回 `fresh`，之后到离线宽限期之间返回 `offlineGrace`，超过宽限期返回 `offlineGraceExceeded`。这些状态只表达在线证据的新鲜度和宿主提示强度。

`isUsable(at:)` 由 active 业务状态、Trial/License 业务到期和 Signed 凭据是否有效决定。超过在线复核间隔或离线宽限期仍可用；服务端返回的 License `expires_at` 已包含支付订阅的支付宽限，客户端不重复计算。

业务新鲜度与请求门槛不是同一状态。`validatedAt` 来自合法业务响应；`lastValidateResponseAt` 表示最近一次取得明确 `/validate` Server 结果的本地时间，是静默 Product 间隔的起点。单独保存的 `StoredValidationAttempt.startedAt` 是固定 30 秒门槛的起点，请求发起前写入，因此无响应失败和非法 2xx 正文也受 30 秒限制。旧快照尚无请求尝试记录时，暂用其 `lastValidateResponseAt` 保留原有 30 秒窗口。

Product 间隔仅限制 `.silent`：用户主动校验、active Trial/License 首次跨过已知业务到期、Release 身份变化后首次静默复核，以及 Signed Token 本地失效均可跳过。到期和 Release 身份变化以最近请求尝试为一次性标记，即使请求超时，也不会因同一条件每 30 秒反复静默请求。快照保存生成可信服务端状态时的版本、平台和架构；旧快照缺少该身份时允许一次静默复核。Signed 凭据缺少内置公钥或公钥配置无效则保留配置错误，不当作可通过联网修复的 Token 失效。

只有两类 `/validate` 结果会写 `lastValidateResponseAt`：合法的成功业务数据，以及具有明确 HTTP 状态的失败。DNS、TLS、超时、断网等没有 HTTP 响应的失败和 2xx 非法业务数据不写该时间；HTTP 失败也不写 `validatedAt` 或新业务快照。所有实际请求尝试都会先写 `StoredValidationAttempt`。`activate()`、`startTrial()` 和 `deactivate()` 不读写请求门槛时间。

## 来源语义

- `server`：本次从服务端获得的快照。
- `cache`：近期服务端快照仍有效，未发起新的网络请求。
- `signedLocal`：复用近期快照前重新验证了本地 Signed Token。
- `local`：纯本地构造、没有服务端确认，例如无 License 凭据时解绑。

来源、新鲜度与可用性是三个维度。`source=server` 仍可能是已到期或已吊销；`source=cache` 可以处于 `offlineGraceExceeded` 但继续可用；`source=local` 不能伪造 `validatedAt`。

## 凭证信任模型

`opaque` 与 `signed` 共享在线协议和 Machine Token。差异只在 `signed` 额外返回 Signed License Token：

```text
online response
  ├─ opaque → 签名字段必须为空 → 保存在线凭据与快照
  └─ signed → 内置公钥 → Ed25519 验签 → Claims/构建身份/状态一致性 → 保存
```

运行时从授权服务下载的公钥不能成为信任根。当前 SDK 公共配置只接收一个由 Admin 交付、随 App 构建内置的公钥；当前产品模型也只有一个 active 签名密钥，不对宿主 App 暴露密钥字典或轮换接口。将来如果引入真实的密钥轮换，需要同时设计 Server 生命周期、Admin 操作和客户端多公钥迁移窗口，不能只把参数改回字典。

Signed 模式还检查：

- Token 仍携带 Server 签发的 `ins`，旧 `acc` Claim 不接受；宿主 App 不再重复配置 Instance；
- `prd/act/fp/ver/plt/arc` 与当前 Product、Activation、设备和自动读取的构建身份一致；
- Token 不包含 Product Release ID 或发布时间；Release 发布时间只由 Server 在有限期更新权益校验中使用；
- active License 的 features、更新期限与含支付宽限期的最终到期时间等于签名 Claims；
- Token Payload 不包含 `exp`；业务到期由 `lexp` 表达，在线复核间隔和离线宽限期通过响应元数据表达。

本机恢复要求保存的服务端快照与当前 License/Trial 凭据绑定。绑定值由 Product、设备指纹、凭据身份和 Token 计算，避免同类型旧快照配合另一份凭据放行；升级前缺少绑定的旧快照需要先在线复核。`opaque` 与 Trial 不具有可离线验签的权益载荷，本机结论基于 Keychain 中 SDK 曾保存的凭据和服务端快照。Signed License 跨过相同的业务到期日时，本机停止放行，已缓存的 active 状态仍可进入在线复核；真实签名或字段不一致继续报告原始错误。

解绑先保存包含原 Machine Token 的恢复记录，再请求 Server。收到明确确认后立即撤销进程内旧 License 的放行资格，接着保存已确认阶段、清凭据、写后续快照并清恢复记录；任何后续失败都返回远端已确认和具体本地错误。成功写入的本机 `activationRequired` 仍保留 `.local` 来源，另在持久化记录中标识远端解绑已确认，使重启后的本机判定能够恢复阻断，又不会伪称 Server 已判定 Trial 资格。响应丢失时记录保持待确认，可在重启后凭原 Token 重试；Server 对已解绑的同一 Activation 返回已解绑状态。待确认期间仍按已有可信本机证据恢复使用资格，并允许在线复核更新状态；远端确认后本机不再使用旧快照放行。新的激活与 Trial 领取须等待 `deactivate()` 完成恢复。

## Trial 与无凭据状态

Trial Claim 与 License 凭据分别存储。客户端在首次请求前把自己生成的 Trial Token 持久化为验证中凭据；响应丢失或最终 Keychain 写入失败后，再次调用 `startTrial()` 使用同一 Token，服务端重复下发同一 Trial，不同 Token 不能只凭指纹取得既有凭据。后续统一校验使用 `credential.kind=trial`。Trial Token 不参与 Ed25519 验签。正常 License 激活并保存后清除同设备 Trial 凭据。

Activation 验证中凭据只保存客户端生成的 Machine Token，不保存 Registration Key 明文或 Hash，也不保存设备名称。再次调用 `activate()` 时，SDK 复用该 Token，但使用用户本次输入的 Registration Key；由 Server 判断目标 License 并决定是首次创建还是重复下发既有 Activation。正式 License 凭据也不保存 Registration Key Hash。`validate()` 不执行激活或 Trial 领取。

Machine Token 与 Trial Token 是 bearer credential：安全性来自 256 位 CSPRNG 随机性、TLS、Keychain 的 `ThisDeviceOnly` 本机存储、服务端只保存 Hash，以及资源范围与设备指纹的联合校验。这里承诺的是“另一设备只知道 Registration Key 或设备指纹时，不能取得既有凭据”。设备指纹不是密码学设备证明；如果攻击者已经从失陷客户端导出 Token，并能伪造该设备指纹，当前协议不能阻止重放。若产品威胁模型需要覆盖该场景，应另行引入设备私钥签名或平台证明，不能仅靠增加本地 Hash 判断来实现。

没有本地凭据时，统一校验使用 `credential.kind=none`。对 active Product，它可以返回 Trial available、not enabled 或 already claimed；Product Release 是否登记不影响 Trial。Product 不存在/已归档和 Trial 配置损坏仍是失败，不伪装成 Trial 不可用。

## 被动冷却边界

门槛只在宿主调用 `validate(trigger:)` 时判断。`.silent` 表示应用启动、前台切换等无用户刷新意图的调用；`.userInitiated` 表示用户明确点击检查或重试。门槛结束不会创建后台任务、监听网络恢复、发出事件或自动重试。显式激活、Trial 领取和解绑始终执行自身操作；它们返回的 `validatedAt` 是业务事实，不能冒充 `/validate` 最近响应时间。

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
