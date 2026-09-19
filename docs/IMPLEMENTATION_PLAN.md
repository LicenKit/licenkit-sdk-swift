# Swift SDK V1 实现计划

## 1. 当前差距

当前源码：

- `LicenKitConfiguration` 强制要求单个 `publicKey`；
- `activate` 强制要求服务端返回 Offline Token；
- 激活成功后默认按 Ed25519 流程验签；
- Keychain 凭据结构没有明确区分在线和签名离线模式；
- 存在注册码漫游保存逻辑；
- 解绑可能在远端失败后仍清理本地凭据；
- 文档把所有 License 描述成可离线验证。

这些行为与 V1 Server 已确认合同不一致。

## 2. 实现顺序

### S1 模型和配置

- [ ] `trustedSigningKeys` 替代单个必填公钥；
- [ ] 新增 `VerificationMode`；
- [ ] Stored Credentials 保存 mode；
- [ ] 重新定义 LicenseStatus；
- [ ] 删除默认 roaming license key。

### S2 激活分支

- [ ] 按响应 mode 分支；
- [ ] 在线模式不要求 Offline Token；
- [ ] 签名离线模式严格要求 Token、key ID 和受信公钥；
- [ ] Claims 不包含注册码；
- [ ] 两种模式分别持久化。

### S3 本地与在线验证

- [ ] `checkLocalStatus`；
- [ ] 在线模式缓存状态；
- [ ] 签名离线验签；
- [ ] Token 和 License 双到期时间；
- [ ] 密钥轮换 keyring；
- [ ] 网络失败与业务拒绝分离。

### S4 解绑和错误

- [ ] 远端成功后清理本地；
- [ ] 幂等处理 Activation 不存在；
- [ ] 远端失败保留本地凭据；
- [ ] 透传服务端 code、details 和 request ID；
- [ ] 保留 Keychain OSStatus 和传输错误。

## 3. 测试矩阵

| 场景 | 预期 |
| --- | --- |
| 在线模式配置为空 keyring | 激活和验证成功 |
| 在线响应没有 Offline Token | 成功 |
| 签名离线响应没有 Token | 明确失败 |
| 签名离线响应 key ID 未受信 | 明确配置错误 |
| Offline Token 被篡改 | untrusted |
| Offline Token 过期 | expired 或 online validation required |
| License 早于 Token 到期 | 按 License 到期时间拒绝 |
| 网络超时 | transport error，不转换为 revoked |
| 服务端返回 suspended | suspended，并保留服务端信息 |
| 解绑网络失败 | 保留本地凭据并返回 remote failure |
| 新旧签名 key 并存 | 均可验证对应未过期 Token |

## 4. 完成定义

- 文档、公开 API、实现和测试一致；
- Server 契约测试覆盖两种响应；
- Swift 单元测试不依赖特制测试专用流程；
- 示例 App 分别演示在线与签名离线模式；
- 现有 44 个测试需要重新分类，不能只因旧测试继续通过就认为 V1 对齐完成。
