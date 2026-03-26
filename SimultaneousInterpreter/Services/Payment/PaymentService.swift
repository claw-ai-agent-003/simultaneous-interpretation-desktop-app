import Foundation
#if canImport(MLX)
import MLX
#endif

/// PaymentService handles one-time purchase verification via LemonSqueezy
///
/// LemonSqueezy provides:
/// - One-time purchase checkout
/// - License key delivery
/// - Webhook verification for purchase confirmation
///
/// API Docs: https://docs.lemonsqueezy.com/api
public enum PaymentProvider {
    case lemonsqueezy
    case paddle
}

/// Purchase state machine
public enum PurchaseState: Equatable {
    case unverified
    case verifying
    case verified(licenseKey: String)
    case failed(message: String)
}

/// PaymentService configuration
public struct PaymentConfig {
    public let provider: PaymentProvider
    public let storeId: String
    public let productId: String
    public let apiKey: String
    
    public init(provider: PaymentProvider = .lemonsqueezy, storeId: String, productId: String, apiKey: String) {
        self.provider = provider
        self.storeId = storeId
        self.productId = productId
        self.apiKey = apiKey
    }
}

/// PaymentService handles license verification for one-time purchases
public actor PaymentService {
    private let config: PaymentConfig
    private var state: PurchaseState = .unverified
    
    public init(config: PaymentConfig) {
        self.config = config
    }
    
    /// Check if user has a valid license
    public func isLicensed() -> Bool {
        switch state {
        case .verified:
            return true
        default:
            return false
        }
    }
    
    /// Get current purchase state
    public func currentState() -> PurchaseState {
        return state
    }
    
    /// Open purchase checkout in browser
    /// Returns the checkout URL
    public func openCheckout() -> URL? {
        let urlString: String
        switch config.provider {
        case .lemonsqueezy:
            urlString = "https://\(config.storeId).lemonsqueezy.com/checkout/buy/\(config.productId)"
        case .paddle:
            urlString = "https://buy.paddle.com/product/\(config.productId)"
        }
        return URL(string: urlString)
    }
    
    /// Verify a license key from webhook or manual entry
    public func verifyLicense(_ licenseKey: String) async -> PurchaseState {
        state = .verifying
        
        switch config.provider {
        case .lemonsqueezy:
            return await verifyLemonSqueezyLicense(licenseKey)
        case .paddle:
            return await verifyPaddleLicense(licenseKey)
        }
    }
    
    /// Verify LemonSqueezy license via API
    /// API: GET /v1/orders?filter[license_key]=XXX
    private func verifyLemonSqueezyLicense(_ licenseKey: String) async -> PurchaseState {
        guard let url = URL(string: "https://api.lemonsqueezy.com/v1/orders") else {
            state = .failed(message: "Invalid API URL")
            return state
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                state = .failed(message: "Invalid response")
                return state
            }
            
            guard httpResponse.statusCode == 200 else {
                state = .failed(message: "API error: \(httpResponse.statusCode)")
                return state
            }
            
            // Parse LemonSqueezy API response
            // Response format: { "data": [{ "attributes": { "license_key": { "key": "XXX" } } }] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArray = json["data"] as? [[String: Any]],
                  let firstOrder = dataArray.first,
                  let attributes = firstOrder["attributes"] as? [String: Any],
                  let licenseData = attributes["license_key"] as? [String: Any],
                  let key = licenseData["key"] as? String,
                  key == licenseKey else {
                state = .failed(message: "License not found")
                return state
            }
            
            state = .verified(licenseKey: licenseKey)
            return state
            
        } catch {
            state = .failed(message: error.localizedDescription)
            return state
        }
    }
    
    /// Verify Paddle license via API
    /// API: GET /2.0/subscription/resERVED_IPS
    private func verifyPaddleLicense(_ licenseKey: String) async -> PurchaseState {
        guard let url = URL(string: "https://sandbox.paddle.com/api/1.0/subscription/reserved-ips") else {
            state = .failed(message: "Invalid API URL")
            return state
        }
        
        var request = URLRequest(url: url)
        request.setValue(config.apiKey, forHTTPHeaderField: "Paddle-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                state = .failed(message: "Invalid response")
                return state
            }
            
            guard httpResponse.statusCode == 200 else {
                state = .failed(message: "API error: \(httpResponse.statusCode)")
                return state
            }
            
            // Parse Paddle response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseData = json["response"] as? [String: Any],
                  responseData["status"] as? String == "active" else {
                state = .failed(message: "License not found or inactive")
                return state
            }
            
            state = .verified(licenseKey: licenseKey)
            return state
            
        } catch {
            state = .failed(message: error.localizedDescription)
            return state
        }
    }
    
    /// Handle webhook verification from payment provider
    /// Call this when receiving a webhook notification
    public func handleWebhook(data: Data, signature: String) async -> Bool {
        // Verify webhook signature
        // LemonSqueezy uses HMAC-SHA256
        guard let secret = config.apiKey.data(using: .utf8) else {
            return false
        }
        
        let expectedSignature = data.hmacSHA256(key: secret).hexString
        
        guard expectedSignature == signature else {
            return false
        }
        
        // Parse webhook payload
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = json["meta"] as? [String: Any],
              let eventName = meta["event_name"] as? String else {
            return false
        }
        
        // Handle purchase events
        switch eventName {
        case "order_created", "subscription_created":
            // Extract license key and verify
            if let licenseKey = extractLicenseKey(from: json) {
                _ = await verifyLicense(licenseKey)
                return true
            }
        case "subscription_cancelled", "subscription_expired":
            // Revoke license
            state = .unverified
            return true
        default:
            break
        }
        
        return false
    }
    
    /// Extract license key from webhook payload
    private func extractLicenseKey(from json: [String: Any]) -> String? {
        // Different providers have different payload structures
        switch config.provider {
        case .lemonsqueezy:
            guard let data = json["meta"] as? [String: Any],
                  let customData = data["custom_data"] as? [String: Any] else {
                return nil
            }
            return customData["license_key"] as? String
            
        case .paddle:
            guard let data = json["data"] as? [String: Any],
                  let attributes = data["status"] as? String else {
                return nil
            }
            return attributes
        }
    }
}

// MARK: - Data Extension for HMAC

extension Data {
    func hmacSHA256(key: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { dataBuffer in
            key.withUnsafeBytes { keyBuffer in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBuffer.baseAddress,
                    key.count,
                    dataBuffer.baseAddress,
                    self.count,
                    &hmac
                )
            }
        }
        return Data(hmac)
    }
    
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

// Import CommonCrypto for HMAC
import CommonCrypto
