# Swift SDK V1 实现状态

本文件只记录 SDK 仓库内的本地实现状态，不代表服务端部署或真实生产闭环已经完成。

## 已实现

- `trustedSigningKeys` 可为空，`opaque` 激活和校验不要求公钥；
- `signed` 响应要求 Token、`signing_key_id` 与内置受信公钥，并在保存前立即验签；
- 两种模式共享 `activate/validate/deactivate` 请求模型，均携带 Product Release 身份；
- Token Header、Claims、Activation、设备指纹、Token/License 到期和更新权益本地检查；
- Product/设备 Trial Claim 独立在线领取与校验，本地不返回有效试用；
- License 与 Trial 使用独立 Keychain 记录，正常 License 激活后清除 Trial；
- 解绑远端失败保留本地凭据；
- 传输、服务端业务、签名、Release 和凭据存储错误分开；
- 原始 API code、request ID 与按字段脱敏的 details 可到达宿主 App。

## 本地测试覆盖

- 无公钥 `opaque` 激活；
- `signed` 缺失 key ID 对应公钥；
- 新旧签名 key 并存；
- `updates_until` 与 License 到期语义分离；
- Trial 本地只能返回 `onlineValidationRequired`；
- 解绑网络失败不删除本地 Machine Token；
- 4xx 业务错误与 5xx 传输错误分离；
- `LICENSE_CHECKOUT_VERIFICATION_ONLY`、request ID 和 details 透传；
- `PRODUCT_RELEASE_UNKNOWN` 保留为独立缓存状态且原始 API 错误仍抛给宿主 App。

## 仍需服务端联调证明

- 真实 `opaque` 与 `signed` 服务端响应；
- Product Release 未知、更新权益不足、暂停、吊销和 Activation 吊销；
- Trial 重复领取、错误 Token、设备不匹配、到期和吊销；
- Keychain 在签名和发布后的宿主 App 环境中读写；
- 远端成功解绑后席位确实释放。

本地单元测试和构建通过不等于以上联调或生产部署已经完成。
