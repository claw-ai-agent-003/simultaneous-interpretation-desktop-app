import Foundation
import Network
import MultipeerConnectivity

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
actor WiFiSyncService: ObservableObject {

    // MARK: - 发布属性（主线程更新）

    /// 当前连接状态
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected

    /// 当前连接的 Mac 端显示名称
    @Published private(set) var connectedPeerName: String?

    /// 最近接收到的实时翻译片段
    @Published private(set) var latestSegment: LiveSegmentMessage?

    /// 最近接收到的会议摘要
    @Published private(set) var latestBrief: MeetingBriefMessage?

    // MARK: - 私有属性

    /// MultipeerConnectivity 方案
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// Network.framework 方案（备选）
    private var listener: NWListener?
    private var connection: NWConnection?

    /// 消息流 AsyncStream 续延器
    private var messageStreamContinuation: AsyncStream<SyncMessage>.Continuation?

    /// 当前使用的方案
    private var activeMode: SyncMode = .multipeerConnectivity

    /// 是否正在监听
    private var isListening = false

    /// Bonjour 服务类型标识（需与 Mac 端一致）
    private let serviceType = "ioscompanion"

    // MARK: - 初始化

    init() {}

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

        // 关闭消息流
        messageStreamContinuation?.finish()
    }

    /// 获取消息流（供 View 层消费）
    /// - Returns: AsyncStream<SyncMessage> 可迭代消息流
    func getMessageStream() -> AsyncStream<SyncMessage> {
        AsyncStream { continuation in
            self.messageStreamContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // 流终止时的清理逻辑
            }
        }
    }

    // MARK: - MultipeerConnectivity 方案实现

    /// 配置 MultipeerConnectivity 监听模式
    /// iPhone 作为浏览者（Browser），发现并连接 Mac 端广告者
    private func setupMultipeerConnectivity() {
        let peerID = MCPeerID(displayName: UIDevice.current.name)

        // 创建会话
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session?.delegate = MultipeerDelegateHandler.shared

        // 创建浏览者，发现同网段的 Mac 端
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser?.delegate = MultipeerDelegateHandler.shared
        browser?.startBrowsingForPeers()

        // 同时作为广告者被 Mac 发现（双向发现）
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = MultipeerDelegateHandler.shared
        advertiser?.startAdvertisingPeer()

        // 设置委托处理
        MultipeerDelegateHandler.shared.setSession(session!, service: self)
    }

    /// 手动连接到指定的对等端
    /// - Parameter peerID: 目标 Mac 的 MCPeerID
    func connect(to peerID: MCPeerID) {
        guard let session = session, let browser = browser else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        connectionStatus = .connecting
    }

    // MARK: - Network.framework (Bonjour + TCP) 备选方案

    /// 配置 Network.framework Bonjour + TCP 监听
    /// 使用 NWListener 在本地端口监听，Mac 端通过 Bonjour 发现并 TCP 连接
    private func setupNetworkFramework() {
        do {
            // 创建 TCP 参数
            let tcpParams = NWParameters.tcp
            tcpParams.allowLocalEndpointReuse = true

            // 添加 Bonjour 服务广播
            let bonjourParams = NWParameters()
            bonjourParams.includePeerToPeer = true

            // 创建监听器
            listener = try NWListener(using: tcpParams)

            // 设置 Bonjour 服务类型
            listener?.service = NWListener.Service(name: "IOSCompanion-\(UUID().uuidString.prefix(8))", type: "_\(serviceType)._tcp")

            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.connectionStatus = .listening
                    case .failed, .cancelled:
                        self?.connectionStatus = .disconnected
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleNewConnection(newConnection)
            }

            listener?.start(queue: .main)
        } catch {
            print("[WiFiSyncService] NWListener 创建失败: \(error)")
            connectionStatus = .disconnected
        }
    }

    /// 处理新的 TCP 连接
    /// - Parameter connection: NWConnection 实例
    private func handleNewConnection(_ connection: NWConnection) {
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    self?.connectionStatus = .connected
                    self?.connectedPeerName = connection.endpoint.debugDescription
                }
                self?.receiveMessages(on: connection)
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.connectionStatus = .disconnected
                    self?.connectedPeerName = nil
                }
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    /// 从连接接收消息
    /// - Parameter connection: NWConnection 实例
    private func receiveMessages(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.parseAndDispatchMessage(data)
            }

            if let error = error {
                print("[WiFiSyncService] 接收消息错误: \(error)")
                return
            }

            if isComplete {
                Task { @MainActor in
                    self?.connectionStatus = .disconnected
                }
            } else {
                // 继续接收下一条消息
                self?.receiveMessages(on: connection)
            }
        }
    }

    // MARK: - 消息解析与分发

    /// 解析接收到的原始数据并分发到对应处理器
    /// - Parameter data: 原始 JSON 数据
    private func parseAndDispatchMessage(_ data: Data) {
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
        // 更新消息流
        messageStreamContinuation?.yield(message)

        // 根据类型更新对应状态
        switch message {
        case .liveSegment(let segment):
            Task { @MainActor in
                self.latestSegment = segment
            }

        case .meetingBrief(let brief):
            Task { @MainActor in
                self.latestBrief = brief
            }

        case .sessionEnd:
            // 会议结束，触发本地存储
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

// MARK: - MultipeerConnectivity 委托处理

/// MultipeerConnectivity 委托处理器
/// 单独处理以避免循环引用
final class MultipeerDelegateHandler: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {

    static let shared = MultipeerDelegateHandler()

    private weak var session: MCSession?
    private weak var service: WiFiSyncService?

    private override init() {
        super.init()
    }

    func setSession(_ session: MCSession, service: WiFiSyncService) {
        self.session = session
        self.service = service
    }

    // MARK: - MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.service?.connectionStatus = .connected
                self.service?.connectedPeerName = peerID.displayName
            case .connecting:
                self.service?.connectionStatus = .connecting
            case .notConnected:
                self.service?.connectionStatus = .disconnected
                self.service?.connectedPeerName = nil
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task {
            await self.service?.parseAndDispatchMessage(data)
        }
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

    // MARK: - MCNearbyServiceBrowserDelegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // 发现对等端，自动邀请连接
        if let session = self.session {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // 对等端消失
    }

    // MARK: - MCNearbyServiceAdvertiserDelegate

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 收到连接邀请，自动接受
        if let session = self.session {
            invitationHandler(true, session)
        } else {
            invitationHandler(false, nil)
        }
    }
}

// MARK: - 通知名称扩展

extension Notification.Name {
    static let sessionDidEnd = Notification.Name("sessionDidEnd")
}
