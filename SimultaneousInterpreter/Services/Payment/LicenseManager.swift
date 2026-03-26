import Foundation
import AppKit

/// LicenseManager handles user-facing license verification UI and logic
public class LicenseManager: NSObject {
    private let paymentService: PaymentService
    private var licenseKeyWindow: NSWindow?
    private var onLicenseVerified: ((Bool) -> Void)?
    
    public init(paymentService: PaymentService) {
        self.paymentService = paymentService
        super.init()
    }
    
    /// Check if app is licensed
    public func isLicensed() async -> Bool {
        return await paymentService.isLicensed()
    }
    
    /// Show purchase prompt
    public func showPurchasePrompt(onLicenseVerified: @escaping (Bool) -> Void) {
        self.onLicenseVerified = onLicenseVerified
        
        let alert = NSAlert()
        alert.messageText = "Unlock SimultaneousInterpreter"
        alert.informativeText = "Enter your license key to unlock all features, or purchase a license to support development."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enter License Key")
        alert.addButton(withTitle: "Purchase License")
        alert.addButton(withTitle: "Continue Trial")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            showLicenseKeyEntry()
        case .alertSecondButtonReturn:
            openPurchasePage()
        default:
            onLicenseVerified?(false)
        }
    }
    
    /// Show license key entry dialog
    private func showLicenseKeyEntry() {
        let alert = NSAlert()
        alert.messageText = "Enter License Key"
        alert.informativeText = "Enter your LemonSqueezy license key:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Verify")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "XXXX-XXXX-XXXX-XXXX"
        alert.accessoryView = input
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let licenseKey = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !licenseKey.isEmpty {
                Task {
                    let state = await paymentService.verifyLicense(licenseKey)
                    await MainActor.run {
                        switch state {
                        case .verified:
                            showSuccessMessage()
                            onLicenseVerified?(true)
                        case .failed(let message):
                            showErrorMessage(message)
                            onLicenseVerified?(false)
                        default:
                            break
                        }
                    }
                }
            }
        } else {
            onLicenseVerified?(false)
        }
    }
    
    /// Open purchase page in browser
    private func openPurchasePage() {
        Task {
            if let url = await paymentService.openCheckout() {
                await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    /// Show success message
    private func showSuccessMessage() {
        let alert = NSAlert()
        alert.messageText = "License Verified!"
        alert.informativeText = "Thank you for your support. Enjoy SimultaneousInterpreter."
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    /// Show error message
    private func showErrorMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "License Verification Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
