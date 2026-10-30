import Foundation

/// Un processus reconnu par son pid **et** son heure de démarrage : un pid réutilisé par un autre programme n'est pas
/// le même processus.
public struct ProcessIdentity: Equatable, Sendable {
    public var pid: pid_t
    var startSeconds: Int64
    var startMicroseconds: Int64
    var groupID: pid_t
    var name: String

    /// Ce qui fait le processus : son pid et son heure de démarrage (le groupe et le nom peuvent changer).
    public struct Key: Hashable, Sendable {
        var pid: pid_t
        var startSeconds: Int64
        var startMicroseconds: Int64
    }

    public var key: Key {
        Key(pid: pid, startSeconds: startSeconds, startMicroseconds: startMicroseconds)
    }
}

/// Ce que le gardien lit de la table des processus (libproc).
public enum ProcessTable {
    /// Le processus `pid`, s'il existe ; nil sinon.
    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return ProcessIdentity(
            pid: pid, startSeconds: Int64(info.pbi_start_tvsec), startMicroseconds: Int64(info.pbi_start_tvusec),
            groupID: pid_t(info.pbi_pgid), name: withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        )
    }

    /// Les enfants directs de `pid`, tels qu'ils sont à cet instant.
    public static func children(of pid: pid_t) -> [ProcessIdentity] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, min(count, pids.count))).filter { $0 > 0 }.compactMap { identity(of: $0) }
    }

    /// Les membres du groupe de processus `group` qui ne sont pas des zombies (un zombie est déjà mort : il attend
    /// seulement d'être lu par son parent).
    public static func liveMembers(ofGroup group: pid_t) -> [ProcessIdentity] {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = Int(proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let count = max(0, min(bytes / MemoryLayout<pid_t>.size, pids.count))
        return pids.prefix(count).filter { $0 > 0 }.compactMap { pid in
            guard let info = bsdInfo(of: pid), info.pbi_status != UInt32(SZOMB) else { return nil }
            return identity(of: pid)
        }
    }

    /// Ce processus-là vit-il encore ? Même pid, même heure de démarrage, et pas zombie.
    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let info = bsdInfo(of: identity.pid), info.pbi_status != UInt32(SZOMB) else { return false }
        return Int64(info.pbi_start_tvsec) == identity.startSeconds && Int64(info.pbi_start_tvusec) == identity.startMicroseconds
    }

    /// Le parent de `pid` ; nil si le processus n'existe pas.
    public static func parentID(of pid: pid_t) -> pid_t? {
        bsdInfo(of: pid).map { pid_t($0.pbi_ppid) }
    }

    /// Le propriétaire de `pid` ; nil si le processus n'existe pas.
    public static func userID(of pid: pid_t) -> uid_t? {
        bsdInfo(of: pid).map(\.pbi_uid)
    }

    /// Les processus dont le parent est `parent`, sans limite de nombre (launchd en a des centaines).
    public static func pids(withParent parent: pid_t) -> [pid_t] {
        let estimate = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard estimate > 0 else { return [] }
        // De la marge : des processus peuvent naître entre les deux appels.
        var pids = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.size + 64)
        let bytes = Int(proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let count = max(0, min(bytes / MemoryLayout<pid_t>.size, pids.count))
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// Les arguments de `pid`, `argv[0]` compris (`sysctl` `KERN_PROCARGS2` : `argc`, le chemin de l'exécutable, des
    /// zéros, puis les arguments, chacun terminé par un zéro). nil si illisibles (processus sorti, ou d'un autre
    /// utilisateur).
    public static func arguments(of pid: pid_t) -> [String]? {
        var limit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var limitName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitName, 2, &limit, &limitSize, nil, 0) == 0, limit > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        var size = buffer.count
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    /// La connexion de `pid` au serveur RTSP de go2rtc, lue par libproc (jamais `lsof`) : la liste de ses descripteurs
    /// (`PROC_PIDLISTFDS`), puis chaque socket (`PROC_PIDFDSOCKETINFO`). Connecté : une socket TCP `ESTABLISHED` dont le
    /// port distant (`insi_fport`, en ordre réseau) est `port`. Une liste ou une socket illisible (EPERM, descripteur
    /// fermé entre les deux lectures…), sans socket établie par ailleurs : rien n'est conclu.
    public static func rtspLink(of pid: pid_t, port: UInt16) -> Capture.Link {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return .unreadable }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 16)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard bytes > 0 else { return .unreadable }
        var unreadable = false
        for descriptor in descriptors.prefix(min(Int(bytes) / stride, descriptors.count)) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else {
                unreadable = true
                continue
            }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport))
            if tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED), remote == port {
                return .connected
            }
        }
        return unreadable ? .unreadable : .detached
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
