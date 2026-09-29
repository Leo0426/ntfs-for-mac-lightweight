import Foundation
import NTFSLiteCore
import NTFSLiteHelperProtocol
import NTFSLitePresentation
import NTFSLiteWriteSession
import ServiceManagement
import SwiftUI

/// XPC transport to the privileged helper (ADR 0010/0011). A connection that cannot be
/// established means nothing was delivered; an interruption after sending is an unknown outcome.
struct HelperXPCTransport: HelperTransport {
    static let replyTimeout: TimeInterval = 180

    func send(_ request: Data) async -> HelperTransportResult {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperServiceIdentity.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: NTFSLiteHelperXPC.self)
            connection.setCodeSigningRequirement(HelperServiceIdentity.helperRequirement)
            let once = ResumeOnce(continuation, connection: connection)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume((error as NSError).code == NSXPCConnectionInvalid ? .unavailable : .timedOut)
            } as? NTFSLiteHelperXPC
            guard let proxy else {
                once.resume(.unavailable)
                return
            }
            proxy.submit(request) { reply in once.resume(.reply(reply)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.replyTimeout) { once.resume(.timedOut) }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperTransportResult, Never>?
    private let connection: NSXPCConnection

    init(_ continuation: CheckedContinuation<HelperTransportResult, Never>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(_ result: HelperTransportResult) {
        let pending = lock.withLock { () -> CheckedContinuation<HelperTransportResult, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.invalidate()
        pending.resume(returning: result)
    }
}

enum HelperServiceState: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case unavailable

    var text: String {
        switch self {
        case .enabled: "帮助程序已启用。"
        case .requiresApproval: "帮助程序等待批准：请在“系统设置 → 通用 → 登录项与扩展”中允许。"
        case .notRegistered: "帮助程序尚未安装。启用写入需要它以管理员权限执行固定的挂载与推出操作。"
        case .unavailable: "当前构建不包含帮助程序，无法启用写入。"
        }
    }
}

struct WriteVolumeRecord: Equatable, Identifiable {
    let id: VolumeInstanceID
    let title: String
}

@MainActor
final class WriteController: ObservableObject {
    @Published private(set) var helperState: HelperServiceState = .notRegistered
    @Published private(set) var busyDisks: Set<PhysicalDiskID> = []
    @Published private(set) var writableVolumes: [WriteVolumeRecord] = []
    @Published private(set) var lastMessage: String?

    private let session = WriteSession(transport: HelperXPCTransport())
    private let service = SMAppService.daemon(plistName: HelperServiceIdentity.daemonPlistName)
    private let refreshObservation: @MainActor () -> Void

    init(refreshObservation: @escaping @MainActor () -> Void) {
        self.refreshObservation = refreshObservation
        refreshHelperState()
    }

    func refreshHelperState() {
        helperState = switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        default: .unavailable
        }
    }

    func installHelper() {
        do {
            try service.register()
        } catch {
            // requiresApproval is reported through status; any other failure keeps the state as read.
        }
        refreshHelperState()
        if helperState == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func isBusy(_ disk: DiskInstanceID) -> Bool { busyDisks.contains(disk.physicalDiskID) }

    func isWritable(_ volume: VolumeInstanceID) -> Bool { writableVolumes.contains { $0.id == volume } }

    func enableWriting(_ volume: VolumeInstanceID, title: String) {
        run(volume.diskInstanceID) { session in
            let outcome = await session.enableWriting(volume, confirmedAsDataVolume: true)
            if outcome == .writingEnabled, !self.isWritable(volume) {
                self.writableVolumes.append(WriteVolumeRecord(id: volume, title: title))
            }
            return outcome
        }
    }

    func safeEject(_ disk: DiskInstanceID) {
        run(disk) { session in
            let outcome = await session.safeEject(disk)
            if outcome == .ejected {
                self.writableVolumes.removeAll { $0.id.diskInstanceID.physicalDiskID == disk.physicalDiskID }
            }
            return outcome
        }
    }

    private func run(_ disk: DiskInstanceID, _ operation: @escaping @MainActor (WriteSession) async -> WriteOutcome) {
        guard busyDisks.insert(disk.physicalDiskID).inserted else { return }
        lastMessage = "正在处理，请稍候…"
        Task { @MainActor in
            let outcome = await operation(session)
            busyDisks.remove(disk.physicalDiskID)
            lastMessage = WriteOutcomeText.text(outcome)
            refreshHelperState()
            refreshObservation()
        }
    }
}

/// Write actions for one volume: install helper, confirm data volume, enable writing, safe eject.
struct VolumeWriteActions: View {
    @ObservedObject var controller: WriteController
    let volume: ReadOnlyVolumePresentation
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.helperState != .enabled {
                Text(controller.helperState.text)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.helperState == .notRegistered || controller.helperState == .requiresApproval {
                    Button("安装帮助程序") { controller.installHelper() }
                }
            } else {
                let busy = controller.isBusy(volume.id.diskInstanceID)
                let writable = controller.isWritable(volume.id)
                HStack {
                    Button("启用写入") { isConfirming = true }
                        .disabled(busy || writable)
                    Button("安全推出") { controller.safeEject(volume.id.diskInstanceID) }
                        .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(writable ? "此卷已在本次会话中启用写入。" : "启用写入会卸载系统只读挂载，并以可写方式重新挂载。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = controller.lastMessage {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("确认这是数据卷？", isPresented: $isConfirming) {
            Button("取消", role: .cancel) {}
            Button("确认并启用写入") { controller.enableWriting(volume.id, title: volume.title) }
        } message: {
            Text("仅对存放普通文件的外置 NTFS 卷启用写入，不要用于 Windows 系统盘或启动盘。写入能力仅在有限的实物测试中验证过，尚未完成 Windows 端复核，请先备份重要数据。用完请点“安全推出”后再拔出。")
        }
        .onAppear { controller.refreshHelperState() }
    }
}

/// Volumes made writable in this session, shown independently of the read-only observation.
struct WritableVolumesSummary: View {
    @ObservedObject var controller: WriteController

    var body: some View {
        if !controller.writableVolumes.isEmpty || controller.lastMessage != nil {
            GroupBox("写入中的磁盘") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.writableVolumes) { record in
                        HStack {
                            Text(record.title).fontWeight(.semibold)
                            Spacer()
                            Button("安全推出") { controller.safeEject(record.id.diskInstanceID) }
                                .disabled(controller.isBusy(record.id.diskInstanceID))
                        }
                    }
                    if let message = controller.lastMessage {
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
