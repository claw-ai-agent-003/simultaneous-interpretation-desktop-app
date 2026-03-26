# Payment Integration

## Overview

P2.2 implements one-time purchase payment flow using LemonSqueezy.

## Components

### PaymentService.swift
- Handles license verification via LemonSqueezy API
- Webhook verification for purchase confirmation
- License key validation

### LicenseManager.swift
- User-facing license entry UI
- Purchase prompt dialog
- License status management

## Setup

### 1. Create LemonSqueezy Account
1. Sign up at https://lemonsqueezy.com
2. Create a product (one-time purchase)
3. Get your Store ID and API Key

### 2. Configure PaymentService
```swift
let config = PaymentConfig(
    provider: .lemonsqueezy,
    storeId: "your-store-id",
    productId: "your-product-id",
    apiKey: "your-api-key"
)
let paymentService = PaymentService(config: config)
```

### 3. Set Webhook URL
In LemonSqueezy dashboard, set webhook URL to:
```
https://yourdomain.com/api/webhooks/lemonsqueezy
```

### 4. Verify Webhook Signature
LemonSqueezy sends HMAC-SHA256 signature in `X-Signature` header.

## Security Notes

- License verification happens server-side via API
- Webhook signature verification prevents fake purchases
- License key stored in UserDefaults (for demo; use Keychain in production)

## Alternative: Paddle

To use Paddle instead:
1. Change `provider: .lemonsqueezy` to `provider: .paddle`
2. Update API credentials
3. Update webhook handler accordingly
