import Darwin

// Le faux ffmpeg des tests du gardien (spec B3 § 10). Un exécutable, pas un script : son nom de processus est `ffmpeg`,
// comme celui du vrai. Il compte les SIGTERM dans un fichier et sort au-delà de 3, comme un ffmpeg figé dans une capture
// AVFoundation (« Received > 3 system signals, hard exiting »).
//
// Arguments : `-compte <fichier>` (le nombre de SIGTERM reçus, réécrit à chacun), `-pid <fichier>` (écrit une fois la
// connexion faite), `-connecte <port>` (facultatif : une connexion TCP vers 127.0.0.1:<port>, gardée ouverte) ; les
// autres sont ignorés, et le dernier tient lieu de sortie (`rtsp://127.0.0.1:<port>/<empreinte>`). Il sort de lui-même
// au bout de 120 s (`alarm`) : rien ne survit à un test interrompu.

func write(_ text: String, to path: String) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard descriptor >= 0 else { exit(2) }
    _ = text.withCString { Darwin.write(descriptor, $0, strlen($0)) }
    close(descriptor)
}

var countFile: String?
var pidFile: String?
var port: UInt16?
let arguments = CommandLine.arguments
var index = 1
while index < arguments.count {
    let next = index + 1 < arguments.count ? arguments[index + 1] : nil
    switch arguments[index] {
    case "-compte": countFile = next; index += 1
    case "-pid": pidFile = next; index += 1
    case "-connecte": port = next.flatMap { UInt16($0) }; index += 1
    default: break
    }
    index += 1
}
guard let countFile, let pidFile else { exit(64) }

alarm(120)
// SIGTERM bloqué, puis lu par sigwait : chaque signal est compté, aucun n'est perdu.
var terms = sigset_t()
sigemptyset(&terms)
sigaddset(&terms, SIGTERM)
pthread_sigmask(SIG_BLOCK, &terms, nil)

if let port {
    let client = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard client >= 0, connected == 0 else { exit(3) }
}
write("\(getpid())\n", to: pidFile)

var received = 0
while true {
    var number: Int32 = 0
    guard sigwait(&terms, &number) == 0 else { continue }
    received += 1
    write("\(received)\n", to: countFile)
    if received > 3 {
        exit(0)
    }
}
