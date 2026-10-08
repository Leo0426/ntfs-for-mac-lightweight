import Foundation
import NTFSLiteDiagnostics

private func summarySetup(
    issues: [DiagnosticSetupIssueCode] = [],
    conflictingDriverCount: UInt32 = 0
) -> DiagnosticInput {
    .setup(DiagnosticSetupEvent(
        applicationVersion: DiagnosticVersion(major: 0, minor: 1, patch: 0),
        applicationBuild: 1,
        macOSVersion: DiagnosticVersion(major: 27, minor: 0, patch: 0),
        architecture: .appleSilicon,
        macFUSEVersion: DiagnosticVersion(major: 5, minor: 4, patch: 0),
        ntfs3GVersion: DiagnosticVersion(major: 2026, minor: 7, patch: 7),
        fileSystemExtensionEnabled: true,
        selectedBackend: .fsKit,
        issueCodes: issues,
        conflictingDriverCount: conflictingDriverCount
    ))
}

func diagnosticSummaryExplainsLatestFactsAndNextSteps() async {
    let diagnostics = Diagnostics(clock: { Date(timeIntervalSince1970: 123) })
    do {
        try await diagnostics.record(summarySetup(issues: [.macFUSEMissing]))
        try await diagnostics.record(summarySetup(
            issues: [.conflictScanIncomplete, .conflictingDrivers],
            conflictingDriverCount: 2
        ))
        try await diagnostics.record(.inventory(DiagnosticInventoryEvent(
            isComplete: true, physicalDiskCount: 1, volumeCount: 1, issueCodes: []
        )))
        try await diagnostics.record(.inventory(DiagnosticInventoryEvent(
            isComplete: false, physicalDiskCount: 2, volumeCount: 3,
            issueCodes: [.missingVolumeUUID, .mountPointMismatch]
        )))
        let snapshot = await diagnostics.snapshot()
        let text = try snapshot.copyText()
        expect(text.contains("状态概览"), "a copied summary must lead with a human-readable overview")
        expect(text.contains("处理建议") && text.contains("运行环境") && text.contains("磁盘识别"),
               "a summary must separate guidance, environment and disk observations")
        let latestFacts = String(text.components(separatedBy: "最近记录")[0])
        expect(latestFacts.contains("运行环境：需要处理（2 项）"),
               "the latest setup event must replace an earlier setup failure")
        expect(!latestFacts.contains("未确认 macFUSE"), "resolved setup issues must not remain current")
        expect(latestFacts.contains("磁盘识别：信息不完整"),
               "a newer incomplete observation must supersede an earlier complete one")
        expect(latestFacts.contains("已观察到：2 块物理盘，3 个卷"),
               "counts must describe the latest observed disks and volumes")
        expect(latestFacts.contains("冲突扫描未完成") && latestFacts.contains("2 个已知冲突驱动"),
               "incomplete scans must still explain positive conflict evidence")
        expect(latestFacts.contains("卷身份缺失") && latestFacts.contains("挂载位置不一致"),
               "inventory failures must be translated without losing their meaning")
        expect(text.contains("重新读取") && text.contains("停用"),
               "the report must provide actionable follow-up for observed failures")
        expect(text.contains("macOS：27.0.0") && text.contains("macFUSE：5.4.0"),
               "version facts must remain readable")
        expect(!text.contains("schemaVersion") && !text.contains("issueCodes")
               && !text.contains(snapshot.runID.uuidString),
               "human output must not expose serialization fields or session identifiers")
    } catch {
        fatalError("CHECK FAILED: readable diagnostic fixture failed: \(error)")
    }
}

func diagnosticSummaryDoesNotInventMissingEvidence() async {
    let diagnostics = Diagnostics(clock: { Date(timeIntervalSince1970: 123) })
    do {
        let empty = try await diagnostics.snapshot().copyText()
        expect(empty.contains("暂无诊断记录"), "an empty report must explicitly describe its empty state")
        expect(empty.contains("运行环境：尚未记录") && empty.contains("磁盘识别：尚未记录"),
               "missing event categories must not be presented as passing checks")
        try await diagnostics.record(.inventory(DiagnosticInventoryEvent(
            isComplete: false, physicalDiskCount: 0, volumeCount: 0, issueCodes: []
        )))
        let incomplete = try await diagnostics.snapshot().copyText()
        expect(incomplete.contains("磁盘识别：信息不完整"),
               "incomplete evidence without issue codes must still fail closed")
        expect(!incomplete.contains("未连接磁盘"),
               "an incomplete zero count must not be interpreted as verified absence")
        expect(incomplete.contains("不能判断磁盘是否可写或可以拔出"),
               "diagnostic observations must not grant write or removal permission")
    } catch {
        fatalError("CHECK FAILED: missing-evidence diagnostic fixture failed: \(error)")
    }
}

func diagnosticSummaryExplainsUnconfirmedSetupWithoutIssueCodes() async {
    let diagnostics = Diagnostics(clock: { Date(timeIntervalSince1970: 123) })
    do {
        try await diagnostics.record(.setup(DiagnosticSetupEvent(
            applicationVersion: DiagnosticVersion(major: 0, minor: 1, patch: 0),
            applicationBuild: 1,
            macOSVersion: DiagnosticVersion(major: 27, minor: 0, patch: 0),
            architecture: .unknown, macFUSEVersion: nil, ntfs3GVersion: nil,
            fileSystemExtensionEnabled: false, selectedBackend: .unknown,
            issueCodes: [], conflictingDriverCount: 0
        )))
        try await diagnostics.record(.inventory(DiagnosticInventoryEvent(
            isComplete: true, physicalDiskCount: 1, volumeCount: 1, issueCodes: []
        )))
        let text = try await diagnostics.snapshot().copyText()
        expect(text.contains("运行环境：部分事实未确认") && text.contains("处理器：未知"),
               "empty issue codes cannot upgrade unknown setup facts to readiness")
        let guidance = text.components(separatedBy: "【处理建议】")[1]
            .components(separatedBy: "【运行环境】")[0]
        expect(guidance.contains("重新读取") && !guidance.contains("检查未报告问题"),
               "guidance must request fresh checks when setup facts remain unknown")
    } catch {
        fatalError("CHECK FAILED: unconfirmed-setup diagnostic fixture failed: \(error)")
    }
}

func diagnosticSummaryMarksHistoryAndFormatsLocalTime() async {
    let diagnostics = Diagnostics(clock: { Date(timeIntervalSince1970: 123) })
    do {
        try await diagnostics.record(summarySetup())
        try await diagnostics.record(.inventory(DiagnosticInventoryEvent(
            isComplete: true, physicalDiskCount: 1, volumeCount: 2, issueCodes: []
        )))
        let snapshot = await diagnostics.snapshot()
        let chinaTime = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let history = try snapshot.copyText(source: .previousRun, timeZone: chinaTime)
        expect(history.contains("上次运行（历史记录）") && history.contains("不代表当前状态"),
               "restored diagnostics must explicitly warn that their evidence is historical")
        expect(history.contains("1970-01-01 08:02:03 +08:00"),
               "milliseconds must be formatted as a local calendar timestamp with its UTC offset")
        let utc = try snapshot.copyText(timeZone: TimeZone(secondsFromGMT: 0)!)
        expect(utc.contains("1970-01-01 00:02:03 Z") && utc.contains("记录来源：本次运行"),
               "formatting must respect the caller's time zone and default record source")
        expect(history.contains("统计包含本机磁盘与其他文件系统"),
               "inventory totals must not be represented as external NTFS target counts")
    } catch {
        fatalError("CHECK FAILED: historical diagnostic fixture failed: \(error)")
    }
}

func diagnosticSummaryBoundsRecentHistoryAndUsesAnonymousTargets() async {
    let diagnostics = Diagnostics(clock: { Date(timeIntervalSince1970: 123) })
    do {
        for count in 1...12 {
            try await diagnostics.record(.inventory(DiagnosticInventoryEvent(
                isComplete: true, physicalDiskCount: UInt32(count), volumeCount: 0, issueCodes: []
            )))
        }
        let disk = try await diagnostics.registerDisk(mediaGeneration: 7)
        let volume = try await diagnostics.registerVolume(on: disk)
        try await diagnostics.record(.volume(DiagnosticVolumeEvent(
            target: volume, fileSystem: .ntfs, location: .external, role: .unknown,
            health: .unknown, mountAccess: .readOnly, backend: .unknown,
            state: .writeMutationQuiescencePending, reason: .timedOut,
            observationComplete: false, isCanonicalMountPoint: false,
            isSymbolicLinkMountPoint: false
        )))
        try await diagnostics.record(.operation(DiagnosticOperationEvent(
            target: disk, kind: .safeEject, stage: .ejectPhysicalDisk, result: .succeeded,
            exitStatus: .exited(code: 0), elapsedMilliseconds: 42
        )))
        let snapshot = await diagnostics.snapshot()
        let text = try snapshot.copyText()
        let history = text.components(separatedBy: "【最近记录")[1]
            .components(separatedBy: "【隐私说明】")[0]
        expect(history.contains("显示 10 / 14 条，最新在前"),
               "history must disclose when only the latest subset is displayed")
        expect(history.components(separatedBy: "\n• ").count - 1 == 10,
               "readable history must stay bounded even while the archive retains more entries")
        expect(!history.contains("；1 块物理盘，0 个卷") && history.contains("；5 块物理盘，0 个卷"),
               "the oldest records must be omitted before more recent records")
        let firstRecord = history.components(separatedBy: "\n• ")[1]
        expect(firstRecord.contains("安全推出") && firstRecord.contains("耗时：42 毫秒"),
               "the newest operation must lead the history with readable stage and timing")
        expect(firstRecord.contains("阶段完成不代表已确认可写或可以拔出"),
               "a successful operation stage must not become a removal authorization")
        expect(text.contains("磁盘 1 / 卷 1（连接编号 7）")
               && text.contains("写入操作尚未确认停止") && text.contains("不能据此确认操作已停止"),
               "anonymous targets and timed-out mutation uncertainty must remain understandable")
        expect(!text.contains(snapshot.runID.uuidString) && !text.contains("writeMutationQuiescencePending"),
               "the report must use numeric aliases and translated states instead of identifiers")
    } catch {
        fatalError("CHECK FAILED: bounded diagnostic fixture failed: \(error)")
    }
}

func diagnosticSummaryTranslatesEveryObservedIssueCode() async {
    let diagnostics = Diagnostics(clock: { Date(timeIntervalSince1970: 123) })
    do {
        try await diagnostics.record(summarySetup(issues: DiagnosticSetupIssueCode.allCases))
        try await diagnostics.record(.inventory(DiagnosticInventoryEvent(
            isComplete: false, physicalDiskCount: 1, volumeCount: 2,
            issueCodes: DiagnosticInventoryIssueCode.allCases
        )))
        let text = try await diagnostics.snapshot().copyText()
        for issue in DiagnosticSetupIssueCode.allCases {
            expect(!text.contains(issue.rawValue), "setup issue \(issue.rawValue) must have human-readable output")
        }
        for issue in DiagnosticInventoryIssueCode.allCases {
            expect(!text.contains(issue.rawValue), "inventory issue \(issue.rawValue) must have human-readable output")
        }
        expect(text.contains("卷用途未确认") && text.contains("普通数据卷且不是 Windows 系统卷"),
               "unknown purposes must be explained as requiring a human declaration")
    } catch {
        fatalError("CHECK FAILED: translated diagnostic fixture failed: \(error)")
    }
}
