# Swift SDK V1 实现状态

本文件记录 SDK 仓库中的本地源码与测试范围，不代表 Swift 包已经发布、Server 已部署，或真实生产闭环已经完成。

## 当前源码合同

- Facade 的 `activate/startTrial/validate/deactivate` 统一返回 `LicenKitResult<Value>`，明确区分成功、冷却期未执行与失败。
- `EntitlementSnapshot` 统一表达 License、Trial、无凭据设备与 Release 资格，并保存来源、服务端时间、收到/生效的校验间隔、Signed Token 到期、业务码与安全 details。
- `validate()` 自动选择 `license/trial/none` 凭据，统一调用 `/api/v1/client/validate`；不再暴露独立 Trial 校验入口。
- 同期 `validate()` 共享一个 Task；所有会修改凭据或快照的操作经过同一 `OperationCoordinator` 顺序化。
- `validate()` 同时应用 Server 建议间隔与硬编码 30 秒门槛；Signed Token 过期或无效只绕过建议间隔。命中门槛时返回 `.notPerformed(.cooldown, ...)`。
- 合法 `/validate` 业务响应与明确 HTTP 失败推进最近响应时间；无 HTTP 响应失败与 2xx 非法正文不推进。HTTP 失败不推进 `validatedAt`。
- `activate/startTrial/deactivate` 不受 `/validate` 冷却约束，也不写最近 `/validate` 响应时间；SDK 不安排后台请求。
- 活动权益的可用截止时间不晚于校验窗口、业务到期或 Signed Token 到期中的任一项。
- `opaque` 与 `signed` 共享 Machine Token 在线协议；`signed` 额外验证内置公钥、Token Header/Claims、外层到期时间及服务端状态一致性。
- Product/设备 Trial 首次使用 `/trials/claim`，后续通过统一校验；正常 License 激活后清除本地 Trial 凭据。
- 解绑只在服务端确认后删除 License 凭据；本地无凭据时返回 `source=.local`、`wasDeactivated=false`，不伪造在线事实。
- API 与业务状态保留原始 code、Request ID 和按字段脱敏的 details；网络失败不改写成到期、吊销或有效状态。
- Instance 合同使用 `instanceID/instance_id/ins`；旧 Account 命名不作为兼容别名接受。

## 本地合同测试已覆盖

- 无凭据设备的 Trial available、not enabled、already claimed 和 unknown Release 映射，以及嵌套业务码保留。
- License、Trial 与无凭据三种严格请求形状；旧的扁平 License 请求和独立 Trial 校验路径被拒绝。
- License/Trial active 与全部业务终态映射，`businessCode/details` 不丢失。
- 服务端 `validated_at`、空/过小/过大的建议间隔，以及业务/Token 到期对 freshness 的截断。
- `opaque` 不要求公钥；`signed` 要求受信 `kid`，并验证 Instance、Product、Activation、设备、Release、`exp` 与服务端状态。
- Signed Token TTL 可以短于建议间隔；Payload 只写绝对 `exp`，实际时刻为“签发时间 + License 快照 TTL”与 License 最终有效截止时间（如有）中的较早值。外层到期时间与 `exp` 不一致、状态与 Claims 不一致时明确拒绝。
- 普通双门槛、Signed Token 失效绕过建议间隔、30 秒硬门槛，以及四类 Server 结果对最近响应时间/`validatedAt` 的不同更新规则。
- 同期 `validate()` 只发一个请求；激活、Trial 领取或解绑不会被旧校验响应覆盖。
- 4xx API 错误、5xx/网络/DNS/TLS/超时、协议错误和 Keychain 错误分开表达，同时保留安全诊断信息。
- 远端解绑失败保留 Machine Token；远端成功后删除；本地无凭据解绑不发请求。

2026-09-23 本地执行严格并发检查与 warnings-as-errors 模式的 `swift test`：32 个 `V1ContractTests` 全部通过；同样编译约束下的 Release 构建也已通过。该结果证明当前检出的 SDK 源码、测试和本地构建一致，不证明包已发布或远端环境可用。

## 仍需跨仓与真实环境证明

- Swift 类型与实际 Server JSON 在 `opaque`、`signed`、Trial 和无凭据路径逐字段一致。
- Server 端 Product 不存在/已归档与 Trial 配置损坏保持 failure，不被转换成 Trial unavailable。
- CLI 与 Swift 对同一服务端状态给出同一可用性结论和原始业务码。
- `request_id` 能关联真实 Worker 日志，且敏感凭据不会进入日志或分析系统。
- 支付型订阅的 `expires_at` 已包含该 License 固化的宽限期，Swift 不重复叠加。
- 已签名宿主 App 的 Keychain 读写、升级保留、卸载/重装与 Access Group 行为。
- Swift 包发布版本、Server 部署版本、D1 migration 和真实 Client API 联调完成。

只有上述远端与发布验收完成，才能把状态从“本地实现可验证”提升为“生产可用”。
