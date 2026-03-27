import Foundation
import Network
import MultipeerConnectivity
import Combine

// MARK: - WiFi 同步服务
/// 负责 iPhone 与 Mac 之间的本地 WiFi P2P 通信
///
/// 通信架构:
///   - 首选: MultipeerConnectivity (MCBrowserViewController / MCSession)
///   - 备选: Network.framework (NWListener + NWConnection TCP/Bonjour)
///
/// 数据流向: Mac → iPhone (单向，iPhone 不主动发送控制指令)
///
/// 使用方式:
///   let service = WiFiSyncService()
///   for await message in service.messageStream {
///       // 处理接收到的消息
///   }
@Observable
final class WiFiSyncService: NSObject {

    // MARK: - 发布属性（主线程更新）

    /// 当前连接状态
    private(set) var connectionStatus: ConnectionStatus = .disconnected

    /// 当前连接的 Mac 端显示名称
    private(set) var connectedPeerName: String?

    /// 最近接收到的实时翻译片段
    private(set) var latestSegment: LiveSegmentMessage?

    /// 最近接收到的会议摘要
    private(set) var latestBrief: MeetingBriefMessage?

    // MARK: - 私有属性

    /// MultipeerConnectivity 方案
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// Network.framework 方案（备选）
    private var listener: NWListener?
    private var connection: NWConnection?

    /// Bonjour 服务类型标识（需与 Mac 端一致）
    private let serviceType = "ioscompanion"

    /// 当前使用的方案
    private var activeMode: SyncMode = .multipeerConnectivity

    /// 是否正在监听
    private var isListening = false

    // MARK: - 初始化

    override init() {
        super.init()
    }

    // MARK: - 公开方法

    /// 开始监听 Mac 端的连接请求
    /// 调用此方法后，iPhone 进入监听模式，等待 Mac 端广告
    func startListening() {
        guard !isListening else { return }
        isListening = true
        connectionStatus = .listening

        // 优先尝试 MultipeerConnectivity
        setupMultipeerConnectivity()
    }

    /// 停止监听并断开所有连接
    func stopListening() {
        isListening = false
        connectionStatus = .disconnected
        connectedPeerName = nil

        // 清理 MultipeerConnectivity 资源
        session?.disconnect()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()

        session = nil
        advertiser = nil
        browser = nil

        // 清理 Network.framework 资源
        listener?.cancel()
        connection?.cancel()
        listener = nil
        connection = nil
    }

    // MARK: - MultipeerConnectivity 方案实现

    /// 配置 MultipeerConnectivity 监听模式
    /// iPhone 作为浏览者（Browser），发现并连接 Mac 端广告者
    private func setupMultipeerConnectivity() {
        let peerID = MCPeerID(displayName: UIDevice.current.name)

        // 创建会话
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session?.delegate = self

        // 创建浏览者，发现同网段的 Mac 端
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        // 同时作为广告者被 Mac 发现（双向发现）
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    /// 手动连接到指定的对等端
    /// - Parameter peerID: 目标 Mac 的 MCPeerID
    func connect(to peerID: MCPeerID) {
        guard let session = session, let browser = browser else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        connectionStatus = .connecting
    }

    // MARK: - 消息解析与分发

    /// 解析接收到的原始数据并分发到对应处理器
    /// - Parameter data: 原始 JSON 数据
    func parseAndDispatchMessage(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(SyncMessage.self, from: data)
            handleMessage(message)
        } catch {
            print("[WiFiSyncService] 消息解析失败: \(error)")
        }
    }

    /// 根据消息类型分发处理
    /// - Parameter message: 解码后的同步消息
    private func handleMessage(_ message: SyncMessage) {
        // 根据类型更新对应状态
        switch message {
        case .liveSegment(let segment):
            self.latestSegment = segment

        case .meetingBrief(let brief):
            self.latestBrief = brief

        case .sessionEnd:
            // 会议结束，触发本地存储通知
            NotificationCenter.default.post(name: .sessionDidEnd, object: nil)

        case .heartbeat:
            // 心跳消息无需特殊处理
            break
        }
    }

    // MARK: - 辅助方法

    /// 切换通信模式
    /// - Parameter mode: 要切换到的模式
    func switchMode(to mode: SyncMode) {
        guard mode != activeMode else { return }
        stopListening()
        activeMode = mode
        startListening()
    }

    /// 更新连接状态（主线程安全）
    private func updateConnectionStatus(_ status: ConnectionStatus, peerName: String? = nil) {
        Task { @MainActor in
            self.connectionStatus = status
            self.connectedPeerName = peerName
        }
    }
}

// MARK: - MCSessionDelegate

extension WiFiSyncService: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            updateConnectionStatus(.connected, peerName: peerID.displayName)
        case .connecting:
            updateConnectionStatus(.connecting)
        case .notConnected:
            updateConnectionStatus(.disconnected, peerName: nil)
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        parseAndDispatchMessage(data)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // 暂不使用流
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // 暂不使用资源接收
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // 暂不使用资源接收
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension WiFiSyncService: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // 发现对等端，自动邀请连接
        if let session = self.session {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // 对等端消失
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension WiFiSyncService: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 收到连接邀请，自动接受
        if let session = self.session {
            invitationHandler(true, session)
        } else {
            invitationHandler(false, nil)
        }
    }
}

// MARK: - 同步模式枚举

/// 通信模式
enum SyncMode: String, CaseIterable, Sendable {
    /// MultipeerConnectivity（首选）
    case multipeerConnectivity = "MultipeerConnectivity"
    /// Network.framework Bonjour + TCP（备选）
    case networkFramework = "Network.framework"

    var description: String {
        switch self {
        case .multipeerConnectivity: return "MultipeerConnectivity（推荐）"
        case .networkFramework: return "Bonjour + TCP"
        }
    }
}

// MARK: - 通知名称扩展

extension Notification.Name {
    static let sessionDidEnd = Notification.Name("sessionDidEnd")
}
