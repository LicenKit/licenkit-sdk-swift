import Foundation

/// 与 LicenKit 服务端边缘引擎交互的网络客户端
public struct LicenKitAPIClient: Sendable {
    
    public let serverUrl: String
    public let timeoutInterval: TimeInterval
    private let urlSession: URLSession
    
    public init(
        serverUrl: String,
        timeoutInterval: TimeInterval = 15.0,
        urlSession: URLSession? = nil
    ) {
        self.serverUrl = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.timeoutInterval = timeoutInterval
        
        if let session = urlSession {
            self.urlSession = session
        } else {
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = timeoutInterval
            sessionConfig.timeoutIntervalForResource = timeoutInterval
            self.urlSession = URLSession(configuration: sessionConfig)
        }
    }
    
    // MARK: - API Calls
    
    /// 向服务端请求试用认领
    public func requestTrial(request: ApiTrialRequest) async throws -> ApiTrialResponse {
        return try await sendRequest(
            path: "/api/v1/client/trial",
            method: "POST",
            body: request
        )
    }
    
    /// 向服务端发起设备激活
    public func activate(request: ApiActivateRequest) async throws -> ApiActivateResponse {
        return try await sendRequest(
            path: "/api/v1/client/activate",
            method: "POST",
            body: request
        )
    }
    
    /// 向服务端发起心跳探活
    public func validate(request: ApiValidateRequest) async throws -> ApiValidateResponse {
        return try await sendRequest(
            path: "/api/v1/client/validate",
            method: "POST",
            body: request
        )
    }
    
    /// 向服务端发起席位解绑
    public func deactivate(request: ApiDeactivateRequest) async throws -> ApiDeactivateResponse {
        return try await sendRequest(
            path: "/api/v1/client/deactivate",
            method: "POST",
            body: request
        )
    }
    
    /// 查询产品活跃公钥
    public func fetchProductPublicKey(productId: String, accountId: String) async throws -> ApiProductPublicKeyResponse {
        var components = URLComponents(string: "\(serverUrl)/api/v1/client/products/\(productId)/pubkey")
        components?.queryItems = [
            URLQueryItem(name: "accountId", value: accountId)
        ]
        
        guard let url = components?.url else {
            throw LicenKitError.networkError("Failed to build product public key URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LicenKit-Swift-SDK/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        
        return try await executeRequest(request)
    }
    
    // MARK: - Private Helpers
    
    private func sendRequest<Req: Encodable, Resp: Decodable & Sendable>(
        path: String,
        method: String,
        body: Req
    ) async throws -> Resp {
        guard let url = URL(string: "\(serverUrl)\(path)") else {
            throw LicenKitError.networkError("Invalid URL: \(serverUrl)\(path)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LicenKit-Swift-SDK/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw LicenKitError.networkError("Failed to encode request body: \(error.localizedDescription)")
        }
        
        return try await executeRequest(request)
    }
    
    private func executeRequest<Resp: Decodable & Sendable>(_ request: URLRequest) async throws -> Resp {
        let data: Data
        let response: URLResponse
        
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LicenKitError.networkError(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenKitError.networkError("Invalid HTTP response")
        }
        
        // 席位超限特殊错误码
        if httpResponse.statusCode == 409 {
            throw LicenKitError.maxMachinesReached
        }
        
        let decoder = JSONDecoder()
        let apiResponse: LicenKitApiResponse<Resp>
        do {
            apiResponse = try decoder.decode(LicenKitApiResponse<Resp>.self, from: data)
        } catch {
            // 如果返回非 JSON，或者 HTTP 非 200
            if !(200...299).contains(httpResponse.statusCode) {
                throw LicenKitError.apiError(
                    code: "HTTP_\(httpResponse.statusCode)",
                    message: "Server responded with status code \(httpResponse.statusCode)"
                )
            }
            throw LicenKitError.networkError("Failed to parse server response JSON: \(error.localizedDescription)")
        }
        
        if !apiResponse.success || apiResponse.data == nil {
            let serverCode = apiResponse.error?.code
            let message = apiResponse.error?.message ?? "Server rejected request"
            if serverCode == "MAX_MACHINES_REACHED" || httpResponse.statusCode == 409 {
                throw LicenKitError.maxMachinesReached
            }
            
            let code: String
            if httpResponse.statusCode >= 500 {
                code = "HTTP_\(httpResponse.statusCode)"
            } else if httpResponse.statusCode == 429 {
                code = "HTTP_429"
            } else {
                code = serverCode ?? "HTTP_\(httpResponse.statusCode)"
            }
            
            throw LicenKitError.apiError(code: code, message: message)
        }
        
        guard let responseData = apiResponse.data else {
            throw LicenKitError.networkError("Missing response payload data")
        }
        
        return responseData
    }
}
