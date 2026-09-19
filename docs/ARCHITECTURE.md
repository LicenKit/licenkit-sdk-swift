# Swift SDK 架构与安全边界

## 模块职责

- `LicenKit`：统一组织激活、校验、解绑和 Trial，不包含 UI；
- `LicenKitAPIClient`：实现 V1 JSON Envelope，区分传输错误与业务错误；
- `Ed25519Verifier`：只验证 `signed` 模式的紧凑 JWS；
- `ClaimsEvaluator`：核对 Account、Product、Activation、设备、时间和 Product Release；
- `KeychainStore`：按 Product 与设备指纹保存 License/Trial 凭据；
- `MacOSFingerprintProvider`：保持现有 IOKit 设备指纹实现。

## 凭证信任模型

`opaque` 与 `signed` 共享在线协议和 Machine Token。差异只在 `signed` 额外返回 Signed License Token：

```text
activate / validate
  ├─ opaque -> 保存在线凭据 -> validOnline
  └─ signed -> 查找内置 kid -> Ed25519 验签 -> Claims/Release 检查 -> 保存 -> validOnline
```

本地检查：

```text
stored credential
  ├─ opaque -> temporarilyUnverified (isUsable=false)
  ├─ signed -> validLocally / expired / updateEntitlementRequired / untrusted
  └─ trial  -> onlineValidationRequired
```

运行时从授权服务下载的公钥不能成为信任根。密钥轮换通过 App 同时内置新旧 key ID 实现；服务端撤销密钥不能瞬间改变完全离线设备上的旧 Token，风险窗口由 Token TTL 和受信 App 更新共同限制。

## Release 资格

SDK 配置中的 `releaseVersion` 与 `releasePlatform` 是构建常量。服务端根据两者查找 Product Release，客户端不提交 `released_at`。`signed` 模式使用签名保护的 `rel/ver/plt/rat` 再次检查：

- 版本和平台必须与当前构建完全一致；
- Token、License 到期时间分别检查；
- 永久 License 的 `rat > upd` 返回 `updateEntitlementRequired`，不冒充 License 到期。

## Trial

Trial Claim 与 License 凭据分别存储。Trial Token 只支持在线校验，不参与 Ed25519 验签；本地缓存的 `expiresAt` 只用于展示和诊断，不能成为服务端确认有效的替代品。正常 License 激活并保存后清除同设备的 Trial 凭据。

## 错误和脱敏

- DNS、TLS、超时、一般网络错误和 HTTP 5xx 属于传输错误；
- 服务端 4xx 业务拒绝保留原始 code、message、request ID 和 details；
- details 只按敏感字段名脱敏 Token、Secret、密码、注册码和 Authorization，不隐藏整个错误包；
- 签名格式/算法/Claims 错误、缺少受信 key ID、Release 不合格、指纹失败和 Keychain OSStatus 分开表达；
- 网络失败不会改写成 revoked、expired 或 valid。

## 解绑顺序

1. 从 Keychain 读取 Activation ID 与 Machine Token；
2. 调用远端 `/deactivate`；
3. 远端失败时返回 `.remoteFailed(localCredentialsPreserved: true, ...)`；
4. 只有远端确认成功后清理本地凭据并返回 `.completed`。
