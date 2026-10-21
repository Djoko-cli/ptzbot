// obsbot-ai on|off : allume (suivi d'une personne) ou coupe le suivi IA de la Tiny 2, puis se termine
// (spec § 6.9, spec app Mac § 7.5). Codes de sortie : 0 = fait, 1 = caméra introuvable, 2 = erreur du SDK,
// 3 = argument manquant ou ordre inconnu. Le mode à un coup sert de repli et de vérification de l'installeur du SDK
// (lancé sans argument, il sort avec le code 3 sans charger le SDK).
// obsbot-ai privacy-on|privacy-off : mode vie privée natif de la caméra (spec § 6.5 bis). `privacy-on` coupe le
// micro pendant le sommeil (cameraSetMicrophoneDuringSleepU(0)) puis met la caméra en vie privée (image noire,
// micro coupé, nacelle descendue vers 85°) ; `privacy-off` la réveille, et elle reprend d'elle-même sa position.
// obsbot-ai privacy-status : lit l'état réel de la caméra (cameraGetCameraStatusU, champ `tiny.dev_status` pour la
// Tiny 2) et l'inclinaison de sa nacelle (gimbalGetAttitudeInfoR, en degrés, positive vers le bas), puis les écrit
// sur la sortie : `run 69.8` ou `privacy 84.9` (spec § 6.5 bis). L'état brut 1 est `run` ; 3 et 4 sont `privacy`
// (mesuré le 19/10 : en vie privée native, la Tiny 2 rend 3, jamais 4). Toute autre valeur est une erreur du SDK
// (code 2), et la valeur brute part dans le journal : ptzd ne suppose jamais. L'inclinaison est le second témoin ;
// illisible, elle manque simplement.
// Mêmes codes de sortie que `on` et `off`.
// obsbot-ai exposure-status | exposure-set <obturation> <auto|manual> : exposition de la Tiny 2 (spec § 6.11). Pour la
// Tiny 2, seules cameraGetExposureAbsolute et cameraSetExposureAbsolute s'appliquent (essai du 20/10 ; les autres
// fonctions d'exposition du SDK sont réservées à la Tail Air). `exposure-status` écrit l'obturation et le mode lus,
// `31 manual` ou `31 auto` ; `exposure-set` applique le couple donné (en `auto`, l'obturation donnée est celle
// d'origine, la caméra l'ignore tant qu'elle reste automatique). Le gain n'est ni lu ni écrit : la caméra garde celui
// d'OBSBOT Center. Mêmes codes de sortie que `on` et `off`.
// obsbot-ai serve : garde le SDK chargé et lit les ordres `on`, `off`, `privacy on`, `privacy off`,
// `privacy status`, `exposure status` ou `exposure set <obturation> <auto|manual>` sur l'entrée, un par ligne ; répond sur la sortie par « obsbot-ai: ready », puis par ordre
// « obsbot-ai: ok » ou « obsbot-ai: err <code> », avec les codes ci-dessus : 1 (caméra introuvable), 2 (erreur du
// SDK), 3 (ordre inconnu, d'un ptzd plus récent que cet utilitaire). `privacy status` répond « obsbot-ai: ok run
// 69.8 » (l'inclinaison absente si elle ne se lit pas) ; si l'état ne se lit pas, « obsbot-ai: err 2 », suivi de
// l'inclinaison si elle se lit (« obsbot-ai: err 2 84.9 »). `exposure status` répond « obsbot-ai: ok 31 manual » (ou
// « err 2 » si la lecture est refusée) ; `exposure set` répond « ok » ou « err 2 ». Se termine quand l'entrée se ferme. Lancé par ptzd.
// En mode serve, la vraie sortie standard est réservée aux réponses : tout ce que le SDK écrit sur la
// sortie standard va vers l'erreur standard (le journal), pour ne jamais se mêler aux réponses.
// En mode serve, un fil surveille aussi le parent : si ptzd meurt pendant que le SDK bloque le fil principal,
// on sort quand même, pour ne jamais laisser un utilitaire orphelin qui garde la caméra.
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dev/devs.hpp>
#include <fcntl.h>
#include <iostream>
#include <cstdlib>
#include <string>
#include <thread>
#include <unistd.h>

// 10 s au plus (amendement A3) : quand la vidéo démarre en même temps, l'initialisation
// de la caméra par le SDK est plus lente (constaté le 2026-10-05).
static std::shared_ptr<Device> findTiny2() {
    Devices::get().setDevChangedCallback([](std::string, bool, void *) {}, nullptr);
    Devices::get().setEnableMdnsScan(false);
    for (int attempt = 0; attempt < 100; ++attempt) {
        for (auto &device : Devices::get().getDevList()) {
            if (device->productType() == ObsbotProdTiny2) {
                return device;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return nullptr;
}

static int32_t setTracking(const std::shared_ptr<Device> &tiny2, bool on) {
    return on ? tiny2->cameraSetAiModeU(Device::AiWorkModeHuman, Device::AiSubModeNormal)
              : tiny2->cameraSetAiModeU(Device::AiWorkModeNone, 0);
}

// Vie privée native (spec § 6.5 bis). Entrée : le micro d'abord (il n'est coupé que si la caméra est « endormie »
// en vie privée), puis l'état de la caméra. Si la coupure du micro échoue, on ne bascule pas : la vie privée
// sans micro coupé ne tiendrait pas sa promesse. Sortie : la caméra se réveille et reprend sa dernière position.
static int32_t setPrivacy(const std::shared_ptr<Device> &tiny2, bool on) {
    if (!on) {
        return tiny2->cameraSetDevRunStatusR(Device::DevStatusRun);
    }
    const int32_t micro = tiny2->cameraSetMicrophoneDuringSleepU(0);
    if (micro != RM_RET_OK) {
        return micro;
    }
    return tiny2->cameraSetDevRunStatusR(Device::DevStatusPrivacy);
}

// État réel de la caméra (spec § 6.5 bis) : `state` reçoit « run » ou « privacy ». La Tiny 2 porte son état dans la
// partie `tiny` de CameraStatus (dev.hpp : « tiny, tiny4k, tiny2 series… »). En vie privée native, elle rend 3
// (`DevStatusSleep`), jamais 4, bien que l'ordre soit `DevStatusPrivacy` (mesuré le 19/10) : 3 et 4 valent
// « privacy ». Une autre valeur est une erreur, avec la valeur brute dans le journal : mieux vaut un échec, que ptzd
// relit plus tard, qu'un état deviné.
static int32_t readPrivacy(const std::shared_ptr<Device> &tiny2, const char **state) {
    Device::CameraStatus status;
    std::memset(&status, 0, sizeof(status));
    const int32_t result = tiny2->cameraGetCameraStatusU(status);
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai : lecture de l'état refusée (%d)\n", result);
        return result;
    }
    switch (status.tiny.dev_status) {
    case Device::DevStatusRun: *state = "run"; return RM_RET_OK;
    case Device::DevStatusSleep:
    case Device::DevStatusPrivacy: *state = "privacy"; return RM_RET_OK;
    default:
        std::fprintf(stderr, "obsbot-ai : état brut de la caméra inattendu (%d)\n", status.tiny.dev_status);
        return RM_RET_ERR;
    }
}

// Inclinaison de la nacelle lue par le SDK (`xyz[1]`, en degrés, positive vers le bas : environ 70 à −70° UVC, 85 en
// vie privée native), sans réveiller la caméra (mesuré le 19/10). Le second témoin de l'état : faux si illisible.
static bool readPitch(const std::shared_ptr<Device> &tiny2, float *pitch) {
    float xyz[3] = {0, 0, 0};
    if (tiny2->gimbalGetAttitudeInfoR(xyz) != RM_RET_OK) {
        return false;
    }
    *pitch = xyz[1];
    return true;
}

// « run 69.8 », « privacy 84.9 », ou l'état seul si l'inclinaison ne se lit pas ; une inclinaison seule (« 84.9 »)
// accompagne un état illisible.
static std::string describe(const char *state, bool hasPitch, float pitch) {
    std::string text = state != nullptr ? state : "";
    if (hasPitch) {
        char number[32];
        std::snprintf(number, sizeof(number), "%.1f", pitch);
        text += (text.empty() ? "" : " ") + std::string(number);
    }
    return text;
}

// Un ordre du mode serve ou du mode à un coup. Les ordres du mode serve s'écrivent « privacy on » ; ceux du mode
// à un coup « privacy-on » (un seul argument).
enum class Order { TrackingOn, TrackingOff, PrivacyOn, PrivacyOff, PrivacyStatus, ExposureStatus, ExposureSet, Unknown };

// Un ordre et ses arguments : l'obturation et le mode de `ExposureSet`.
struct Command {
    Order order = Order::Unknown;
    int32_t shutter = 0;
    bool autoMode = false;
};

static Order parseOrder(const std::string &text) {
    if (text == "on") return Order::TrackingOn;
    if (text == "off") return Order::TrackingOff;
    if (text == "privacy on" || text == "privacy-on") return Order::PrivacyOn;
    if (text == "privacy off" || text == "privacy-off") return Order::PrivacyOff;
    if (text == "privacy status" || text == "privacy-status") return Order::PrivacyStatus;
    if (text == "exposure status" || text == "exposure-status") return Order::ExposureStatus;
    return Order::Unknown;
}

// Bornes de l'obturation, les mêmes des deux côtés (obsbot-ai et ptzd) : entière, de 0 à 999999999 (9 chiffres, sans
// signe). Une valeur lue hors de ces bornes est une erreur de lecture : ptzd ne saurait pas la remettre, et un `exposure
// set` bien formé ne doit jamais être refusé par « ordre inconnu » (code 3), que ptzd lirait « obsbot-ai pas à jour ».
static const int32_t kMaxShutter = 999999999;

// Les arguments de `exposure set` : une obturation entière positive ou nulle (9 chiffres au plus), puis `auto` ou `manual`.
// Autre chose : ordre inconnu (code 3), jamais un réglage deviné.
static bool parseExposureArguments(const std::string &shutter, const std::string &mode, Command *command) {
    if (shutter.empty() || shutter.size() > 9 || shutter.find_first_not_of("0123456789") != std::string::npos) {
        return false;
    }
    if (mode != "auto" && mode != "manual") {
        return false;
    }
    command->order = Order::ExposureSet;
    command->shutter = static_cast<int32_t>(std::strtol(shutter.c_str(), nullptr, 10));
    command->autoMode = mode == "auto";
    return true;
}

// Mode serve : « exposure set 31 auto » ; les ordres sans argument passent par `parseOrder`.
static Command parseServeLine(const std::string &line) {
    Command command;
    if (line.rfind("exposure set ", 0) == 0) {
        const std::string rest = line.substr(std::strlen("exposure set "));
        const std::size_t space = rest.find(' ');
        if (space != std::string::npos) {
            parseExposureArguments(rest.substr(0, space), rest.substr(space + 1), &command);
        }
        return command;
    }
    // Les ordres du mode serve n'acceptent que les formes à espace (« privacy on »).
    if (line.rfind("privacy-", 0) != 0 && line.rfind("exposure-", 0) != 0) {
        command.order = parseOrder(line);
    }
    return command;
}

// Mode à un coup : « exposure-set 31 auto » (trois arguments) ou un ordre sans argument.
static Command parseArguments(int argc, char **argv) {
    Command command;
    if (argc == 4 && std::strcmp(argv[1], "exposure-set") == 0) {
        parseExposureArguments(argv[2], argv[3], &command);
    } else if (argc == 2 && std::strchr(argv[1], ' ') == nullptr) {
        command.order = parseOrder(argv[1]);
    }
    return command;
}

// Ce que rend une lecture de l'état (`PrivacyStatus`) : l'état lu (nul sinon) et l'inclinaison, le second témoin.
struct Reading {
    const char *state = nullptr;
    bool hasPitch = false;
    float pitch = 0;
    // Lecture de l'exposition (`ExposureStatus`).
    bool hasExposure = false;
    int32_t shutter = 0;
    bool autoMode = false;
};

// Exposition de la Tiny 2 (spec § 6.11) : l'obturation et le mode. Un refus du SDK est un échec (code 2), jamais un
// réglage deviné.
static int32_t readExposure(const std::shared_ptr<Device> &tiny2, Reading *reading) {
    int32_t shutter = 0;
    bool autoMode = false;
    const int32_t result = tiny2->cameraGetExposureAbsolute(shutter, autoMode);
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai : lecture de l'exposition refusée (%d)\n", result);
        return result;
    }
    if (shutter < 0 || shutter > kMaxShutter) {
        std::fprintf(stderr, "obsbot-ai : obturation lue hors des bornes (%d)\n", shutter);
        return RM_RET_ERR;
    }
    reading->hasExposure = true;
    reading->shutter = shutter;
    reading->autoMode = autoMode;
    return RM_RET_OK;
}

// « 31 manual » ou « 31 auto » : la forme écrite par `exposure-status` et après « ok » en mode serve.
static std::string describeExposure(const Reading &reading) {
    return std::to_string(reading.shutter) + (reading.autoMode ? " auto" : " manual");
}

// Exécute l'ordre ; `reading` reçoit l'état et l'inclinaison lus pour `PrivacyStatus` (l'inclinaison est lue même si
// l'état ne se lit pas). Un ordre inconnu n'arrive pas jusqu'ici (il est refusé avant, avec le code 3) ; s'il y
// arrivait, ce serait un échec, jamais un faux succès.
static int32_t execute(const std::shared_ptr<Device> &tiny2, const Command &command, Reading *reading) {
    switch (command.order) {
    case Order::TrackingOn: return setTracking(tiny2, true);
    case Order::TrackingOff: return setTracking(tiny2, false);
    case Order::PrivacyOn: return setPrivacy(tiny2, true);
    case Order::PrivacyOff: return setPrivacy(tiny2, false);
    case Order::PrivacyStatus: {
        const int32_t result = readPrivacy(tiny2, &reading->state);
        reading->hasPitch = readPitch(tiny2, &reading->pitch);
        return result;
    }
    case Order::ExposureStatus: return readExposure(tiny2, reading);
    case Order::ExposureSet: return tiny2->cameraSetExposureAbsolute(command.shutter, command.autoMode);
    case Order::Unknown: break;
    }
    return RM_RET_ERR;
}

// Le SDK peut encore initialiser la caméra dans son propre fil : le refermer
// maintenant provoque un arrêt brutal (libc++abi). On quitte sans destructeurs ;
// le système libère l'accès USB.
// En mode serve, `replies` reçoit « obsbot-ai: err 1 » ; en mode à un coup (nullptr), seul le code de sortie parle.
[[noreturn]] static void notFound(std::FILE *replies) {
    std::fprintf(stderr, "obsbot-ai : Tiny 2 introuvable après 10 s\n");
    if (replies != nullptr) {
        std::fprintf(replies, "obsbot-ai: err 1\n");
        std::fflush(replies);
    }
    std::fflush(stderr);
    _exit(1);
}

static void reply(std::FILE *replies, const char *text) {
    std::fprintf(replies, "obsbot-ai: %s\n", text);
    std::fflush(replies);
}

static int serve() {
    // ptzd mort (même tué par SIGKILL) pendant que le SDK bloque le fil principal : on sort quand même,
    // sans destructeurs (le système libère l'accès USB), pour ne jamais laisser deux utilitaires.
    const pid_t parent = getppid();
    if (parent == 1) {
        _exit(0);
    }
    std::thread([parent] {
        while (getppid() == parent) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
        _exit(0);
    }).detach();
    // La vraie sortie standard devient le canal des réponses ; le descripteur 1 pointe désormais sur
    // l'erreur standard, où va tout le bruit du SDK. Copie en close-on-exec : un processus lancé par le SDK
    // ne doit pas garder ce tuyau ouvert.
    const int replyFd = fcntl(1, F_DUPFD_CLOEXEC, 3);
    std::FILE *replies = replyFd >= 0 ? fdopen(replyFd, "w") : nullptr;
    if (replies == nullptr || dup2(2, 1) < 0) {
        std::fprintf(stderr, "obsbot-ai : sortie des réponses indisponible\n");
        return 2;
    }
    auto tiny2 = findTiny2();
    if (!tiny2) {
        notFound(replies);
    }
    reply(replies, "ready");
    std::string line;
    while (std::getline(std::cin, line)) {
        const Command command = parseServeLine(line);
        Reading reading;
        if (command.order == Order::Unknown) {
            reply(replies, "err 3");
        } else if (execute(tiny2, command, &reading) != RM_RET_OK) {
            // Une lecture de l'état ratée garde son second témoin : « err 2 84.9 ».
            const std::string witness = describe(nullptr, reading.hasPitch, reading.pitch);
            reply(replies, witness.empty() ? "err 2" : ("err 2 " + witness).c_str());
        } else if (reading.state != nullptr) {
            reply(replies, ("ok " + describe(reading.state, reading.hasPitch, reading.pitch)).c_str());
        } else if (reading.hasExposure) {
            reply(replies, ("ok " + describeExposure(reading)).c_str());
        } else {
            reply(replies, "ok");
        }
    }
    Devices::get().close();
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && std::strcmp(argv[1], "serve") == 0) {
        return serve();
    }
    // Le mode à un coup n'accepte que les formes sans espace (« privacy-on », « exposure-set 31 auto » en trois arguments).
    const Command command = parseArguments(argc, argv);
    if (command.order == Order::Unknown) {
        std::fprintf(stderr, "usage : obsbot-ai on|off|privacy-on|privacy-off|privacy-status|exposure-status|exposure-set <obturation> <auto|manual>|serve\n");
        return 3;
    }
    auto tiny2 = findTiny2();
    if (!tiny2) {
        notFound(nullptr);
    }
    Reading reading;
    int32_t result = execute(tiny2, command, &reading);
    Devices::get().close();
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai : %s a renvoyé %d\n", argv[1], result);
        if (reading.hasPitch) {
            std::fprintf(stderr, "obsbot-ai : inclinaison %.1f\n", reading.pitch);
        }
        return 2;
    }
    switch (command.order) {
    case Order::TrackingOn: std::printf("obsbot-ai : suivi IA allumé\n"); break;
    case Order::TrackingOff: std::printf("obsbot-ai : suivi IA coupé\n"); break;
    case Order::PrivacyOn: std::printf("obsbot-ai : vie privée allumée\n"); break;
    case Order::PrivacyOff: std::printf("obsbot-ai : vie privée coupée\n"); break;
    // L'état et l'inclinaison (« privacy 84.9 »), pour un script ou un essai à la main.
    case Order::PrivacyStatus: std::printf("%s\n", describe(reading.state, reading.hasPitch, reading.pitch).c_str()); break;
    // L'obturation et le mode lus (« 31 manual »), puis une confirmation pour l'ordre.
    case Order::ExposureStatus: std::printf("%s\n", describeExposure(reading).c_str()); break;
    case Order::ExposureSet: std::printf("obsbot-ai : exposition %s\n", command.autoMode ? "automatique" : "manuelle"); break;
    case Order::Unknown: break;
    }
    return 0;
}
