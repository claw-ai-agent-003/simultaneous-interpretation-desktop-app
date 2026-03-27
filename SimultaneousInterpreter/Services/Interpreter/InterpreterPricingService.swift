import Foundation

// MARK: - InterpreterPricingService

/// Handles per-minute billing for human interpreter sessions.
///
/// Pricing model (pilot):
/// - Rate: ~¥10/minute
/// - Minimum charge: ¥100/session
/// - Minimum billable duration: 10 minutes
///
/// Integration:
/// - Reuses the existing LemonSqueezy PaymentService (P2.2) for checkout
/// - Generates cost summaries after session ends
/// - Supports pilot discount codes
@MainActor
final class InterpreterPricingService: ObservableObject {

    // MARK: - Configuration

    private let config: InterpreterPricingConfig

    // MARK: - Published State

    @Published private(set) var currentCostCNY: Decimal = 0
    @Published private(set) var currentDurationMinutes: Int = 0

    // MARK: - Session Tracking

    private var sessionStartDate: Date?
    private var billingTimer: Timer?
    private var isBilling = false

    // MARK: - Payment Integration

    /// Reference to the app's PaymentService for checkout flow.
    /// Set during app initialization; nil means payment is not configured.
    private weak var paymentService: PaymentService?

    // MARK: - Init

    init(config: InterpreterPricingConfig = InterpreterPricingConfig()) {
        self.config = config
    }

    /// Set the payment service for checkout integration.
    func setPaymentService(_ service: PaymentService) {
        self.paymentService = service
    }

    // MARK: - Billing Control

    /// Start billing for a new interpreter session.
    func startBilling() {
        guard !isBilling else { return }
        isBilling = true
        sessionStartDate = Date()
        currentCostCNY = config.minimumCharge
        currentDurationMinutes = 0

        // Update billing every minute
        billingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateBilling()
            }
        }
    }

    /// Stop billing and return the final summary.
    /// - Parameter interpreterName: Name of the interpreter for the summary
    /// - Returns: The session summary with cost breakdown
    func stopBilling(
        sessionId: String,
        interpreterId: String,
        interpreterName: String,
        rating: Int? = nil
    ) -> InterpreterSessionSummary {
        billingTimer?.invalidate()
        billingTimer = nil

        let endDate = Date()
        let duration = sessionStartDate.map { Int(endDate.timeIntervalSince($0) / 60) } ?? 0
        let cost = calculateCost(durationMinutes: duration)

        isBilling = false
        currentDurationMinutes = duration
        currentCostCNY = cost

        let startDate = sessionStartDate ?? endDate

        let summary = InterpreterSessionSummary(
            sessionId: sessionId,
            interpreterId: interpreterId,
            interpreterName: interpreterName,
            startTime: startDate,
            endTime: endDate,
            durationMinutes: duration,
            costCNY: cost,
            currency: "CNY",
            rating: rating
        )

        sessionStartDate = nil
        return summary
    }

    /// Cancel billing without generating a summary (e.g., connection failed).
    func cancelBilling() {
        billingTimer?.invalidate()
        billingTimer = nil
        isBilling = false
        sessionStartDate = nil
        currentCostCNY = 0
        currentDurationMinutes = 0
    }

    // MARK: - Cost Calculation

    /// Calculate the cost for a given duration.
    func calculateCost(durationMinutes: Int) -> Decimal {
        config.calculateCost(durationMinutes: durationMinutes)
    }

    /// Get a real-time cost estimate for the current session.
    func getCurrentEstimate() -> (minutes: Int, costCNY: Decimal) {
        guard let startDate = sessionStartDate else {
            return (0, config.minimumCharge)
        }
        let elapsed = Int(Date().timeIntervalSince(startDate) / 60)
        let cost = calculateCost(durationMinutes: elapsed)
        return (elapsed, cost)
    }

    /// Get the formatted minimum charge string.
    var formattedMinimumCharge: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: config.minimumCharge as NSDecimalNumber) ?? "¥\(config.minimumCharge)"
    }

    /// Get the formatted rate per minute string.
    var formattedRatePerMinute: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: config.ratePerMinute as NSDecimalNumber) ?? "¥\(config.ratePerMinute)"
    }

    // MARK: - Payment Flow

    /// Open the payment checkout for a completed session.
    /// Uses LemonSqueezy via the existing PaymentService.
    /// - Parameter summary: The session to charge for
    /// - Returns: The checkout URL, or nil if payment is not configured
    func openCheckout(for summary: InterpreterSessionSummary) -> URL? {
        // TODO: Integrate with LemonSqueezy for interpreter session payments.
        // The existing PaymentService (P2.2) handles one-time license purchases.
        // Interpreter billing needs a separate product/metered billing flow.
        //
        // Options:
        // 1. Create a separate LemonSqueezy product for interpreter sessions
        // 2. Use LemonSqueezy's metered billing API
        // 3. Pre-purchase interpreter credits (e.g., 10-min blocks)
        //
        // For pilot: sessions are free / logged for later invoicing.
        print("[InterpreterPricingService] Checkout not configured for pilot mode")

        // Return a placeholder URL
        return URL(string: "https://interpretation.example.com/billing?session=\(summary.sessionId)")
    }

    /// Record a completed payment for a session.
    /// In pilot mode, this just logs the payment.
    /// - Parameters:
    ///   - summary: The session summary
    ///   - transactionId: External transaction ID
    func recordPayment(summary: InterpreterSessionSummary, transactionId: String) {
        // TODO: Store payment record locally
        // In production, verify with LemonSqueezy API
        print("[InterpreterPricingService] Payment recorded: ¥\(summary.costCNY) for session \(summary.sessionId) (tx: \(transactionId))")
    }

    // MARK: - Cost Breakdown (UI)

    /// Generate a detailed cost breakdown string for the summary view.
    func costBreakdown(for summary: InterpreterSessionSummary) -> [String] {
        var lines: [String] = []

        let billableMinutes = max(summary.durationMinutes, config.minimumMinutes)
        let rawCost = Decimal(billableMinutes) * config.ratePerMinute

        lines.append("通话时长: \(summary.formattedDuration)")
        lines.append("计费时长: \(billableMinutes) 分钟")
        lines.append("费率: \(formattedRatePerMinute)/分钟")
        lines.append("小计: ¥\(rawCost)")

        if summary.durationMinutes < config.minimumMinutes {
            lines.append("最低计费: \(config.minimumMinutes) 分钟")
        }

        if config.pilotDiscountPercent > 0 {
            let discount = rawCost * Decimal(config.pilotDiscountPercent) / 100
            lines.append("试点优惠: -¥\(discount)")
        }

        lines.append("─────────────")
        lines.append("合计: \(summary.formattedCost)")

        if summary.durationMinutes < config.minimumMinutes {
            lines.append("")
            lines.append("💡 提示: 不足\(config.minimumMinutes)分钟按\(config.minimumMinutes)分钟计费")
        }

        return lines
    }

    // MARK: - Private

    private func updateBilling() {
        guard isBilling, let startDate = sessionStartDate else { return }
        let elapsed = Int(Date().timeIntervalSince(startDate) / 60)
        currentDurationMinutes = elapsed
        currentCostCNY = calculateCost(durationMinutes: elapsed)
    }
}

// MARK: - Session History (Local Storage)

/// Manages local storage of interpreter session history.
struct InterpreterSessionHistory {

    private let userDefaults = UserDefaults.standard
    private let historyKey = "interpreter.session.history"
    private let maxHistoryEntries = 100

    /// Save a session summary to history.
    func save(_ summary: InterpreterSessionSummary) {
        var history = loadAll()
        history.append(summary)

        // Keep only the most recent entries
        if history.count > maxHistoryEntries {
            history = Array(history.suffix(maxHistoryEntries))
        }

        if let data = try? JSONEncoder().encode(history) {
            userDefaults.set(data, forKey: historyKey)
        }
    }

    /// Load all session summaries from history.
    func loadAll() -> [InterpreterSessionSummary] {
        guard let data = userDefaults.data(forKey: historyKey) else {
            return []
        }
        return (try? JSONDecoder().decode([InterpreterSessionSummary].self, from: data)) ?? []
    }

    /// Get the total spending across all sessions.
    func totalSpending() -> Decimal {
        loadAll().reduce(Decimal(0)) { $0 + $1.costCNY }
    }

    /// Get the total session count.
    func totalSessionCount() -> Int {
        loadAll().count
    }

    /// Clear all history.
    func clearAll() {
        userDefaults.removeObject(forKey: historyKey)
    }
}
