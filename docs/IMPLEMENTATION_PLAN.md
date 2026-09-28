# Swift SDK V1 实现状态

本文件记录 SDK 仓库中的本地源码与测试范围，不代表 Swift 包已经发布、Server 已部署，或真实生产闭环已经完成。

## 当前源码合同

- Facade 的 `activate/startTrial/validate/deactivate` 统一返回 `LicenKitResult<Value>`，明确区分成功、冷却期未执行与失败。
- `EntitlementSnapshot` 统一表达 License、Trial、无凭据设备与 Release 资格，并保存来源、服务端时间、收到/生效的在线复核间隔、离线宽限期、业务码与安全 details。
- `validate()` 自动选择 `license/trial/none` 凭据，统一调用 `/api/v1/client/validate`；不再暴露独立 Trial 校验入口。
- 同期 `validate()` 共享一个 Task；所有会修改凭据或快照的操作经过同一 `OperationCoordinator` 顺序化。
- `validate()` 同时应用 Product 在线复核间隔与硬编码 30 秒门槛；Signed Token 本地验证失败时只绕过前者。命中门槛时返回 `.notPerformed(.cooldown, ...)`。
- 合法 `/validate` 业务响应与明确 HTTP 失败推进最近响应时间；无 HTTP 响应失败与 2xx 非法正文不推进。HTTP 失败不推进 `validatedAt`。
- `activate/startTrial/deactivate` 不受 `/validate` 冷却约束，也不写最近 `/validate` 响应时间；SDK 不安排后台请求。
- 在线复核间隔与离线宽限期只决定联网调度和提示强度；活动权益是否可用由业务状态、业务到期和 Signed 凭据有效性决定。
- `opaque` 与 `signed` 共享 Machine Token、业务到期、在线复核和离线宽限协议；`signed` 额外验证内置公钥、Token Header/Claims 及服务端状态一致性。
- 激活与 Trial Claim 都在请求前把客户端生成的 Token 持久化为验证中凭据；响应丢失、进程退出或最终 Keychain 写入失败后，显式重试复用同一 Token，由 Server 重复下发同一份正式凭据。Activation 验证中凭据不保存 Registration Key 或 Hash；`validate()` 不执行激活或 Trial 领取。
- 解绑只在服务端确认后删除 License 凭据；本地无凭据时返回 `source=.local`、`wasDeactivated=false`，不伪造在线事实。
- API 与业务状态保留原始 code、Request ID 和按字段脱敏的 details；网络失败不改写成到期、吊销或有效状态。
- 公共初始化只需要 `serverURL`、`productID` 和可选单个 `signingPublicKey`；Server 通过全局唯一 Product ID 解析 Instance。
- Release 版本来自宿主 App Bundle，平台固定为 `macos`，架构独立推导；请求超时固定为内部 15 秒，Keychain 不暴露 Access Group。
- Signed Token 仍包含 Server 侧 `ins` Claim；旧 `acc` Claim 不接受，但客户端不再把 Instance 作为配置或请求字段。

## 本地合同测试已覆盖

- 无凭据设备的 Trial available、not enabled、already claimed 映射，以及嵌套业务码保留；未登记 Release 不阻断 Trial。
- License、Trial 与无凭据三种严格请求形状；旧的扁平 License 请求和独立 Trial 校验路径被拒绝。
- License/Trial active 与全部业务终态映射，`businessCode/details` 不丢失。
- 服务端 `validated_at`、在线复核间隔、离线宽限期，以及业务到期对 freshness 与 usability 的独立影响。
- `opaque` 不要求公钥；`signed` 要求宿主内置的单个公钥，并验证响应 Key ID、Product、Activation、设备、版本、平台、架构与服务端状态。Token 不包含 `exp`、Release ID 或发布时间。
- 旧 `exp` Claim 不兼容；Plan 离线宽限期同时适用于 Opaque 与 Signed。
- 激活与 Trial 在服务端创建后响应丢失、进程退出或最终 Keychain 写入失败时，显式重试复用验证中 Token 并取得同一凭据；错误 Token 无法取得既有凭据；Trial 重试无需用户输入。
- 普通双门槛、Signed Token 失效绕过建议间隔、30 秒硬门槛，以及四类 Server 结果对最近响应时间/`validatedAt` 的不同更新规则。
- 同期 `validate()` 只发一个请求；激活、Trial 领取或解绑不会被旧校验响应覆盖。
- 4xx API 错误、5xx/网络/DNS/TLS/超时、协议错误和 Keychain 错误分开表达，同时保留安全诊断信息。
- 远端解绑失败保留 Machine Token；远端成功后删除；本地无凭据解绑不发请求。

2026-09-28 本地执行 `swift test`：39 个 `V1ContractTests` 全部通过。该结果证明当前检出的 SDK 源码与测试一致，不证明包已发布、Server 已部署或远端环境可用。

## 仍需跨仓与真实环境证明

- Swift 类型与实际 Server JSON 在 `opaque`、`signed`、Trial 和无凭据路径逐字段一致。
- Server 端 Product 不存在/已归档与 Trial 配置损坏保持 failure，不被转换成 Trial unavailable。
- CLI 与 Swift 对同一服务端状态给出同一可用性结论和原始业务码。
- `request_id` 能关联真实 Worker 日志，且敏感凭据不会进入日志或分析系统。
- 支付型订阅的 `expires_at` 已包含该 License 固化的宽限期，Swift 不重复叠加。
- 已签名宿主 App 的私有 Keychain 读写、升级保留与卸载/重装行为。
- Swift 包发布版本、Server 部署版本、D1 migration 和真实 Client API 联调完成。

只有上述远端与发布验收完成，才能把状态从“本地实现可验证”提升为“生产可用”。
