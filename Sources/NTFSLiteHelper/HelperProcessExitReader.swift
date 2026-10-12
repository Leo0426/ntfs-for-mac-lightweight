import Darwin

/// Quiescence is independent of driver credentials: failed / partial reads are unknown.
enum HelperProcessExitFact: Equatable {
    case alive, exited, unknown
}

enum HelperProcessExitReader {
    static func interpret(pid: pid_t, signalResult: Int32, signalError: Int32,
                          infoBytes: Int32, info: proc_bsdinfo) -> HelperProcessExitFact {
        guard pid > 0 else { return .unknown }
        if signalResult == -1 && signalError == ESRCH { return .exited }
        guard signalResult == 0,
              infoBytes == Int32(MemoryLayout<proc_bsdinfo>.size),
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else { return .unknown }
        if info.pbi_status == UInt32(SZOMB) { return .exited }
        guard [UInt32(SIDL), UInt32(SRUN), UInt32(SSLEEP), UInt32(SSTOP)]
            .contains(info.pbi_status) else { return .unknown }
        return .alive
    }

    static func read(pid: pid_t) -> HelperProcessExitFact {
        guard pid > 0 else { return .unknown }
        let result = kill(pid, 0)
        let code = result == 0 ? 0 : errno
        var info = proc_bsdinfo()
        // Include unreaped zombies, which cannot perform further mutations.
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, &info,
                                 Int32(MemoryLayout<proc_bsdinfo>.size))
        return interpret(pid: pid, signalResult: result, signalError: code,
                         infoBytes: bytes, info: info)
    }
}
