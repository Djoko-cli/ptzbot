// obsbot-ai on|off : allume (suivi d'une personne) ou coupe le suivi IA de la Tiny 2, puis se termine
// (spec § 6.9, spec app Mac § 7.5). Codes de sortie : 0 = fait, 1 = caméra introuvable, 2 = erreur du SDK,
// 3 = argument manquant ou inconnu. Le mode à un coup sert de repli et de vérification de l'installeur du SDK
// (lancé sans argument, il sort avec le code 3 sans charger le SDK).
// obsbot-ai privacy-on|privacy-off : mode vie privée natif de la caméra (spec § 6.5 bis). `privacy-on` coupe le
// micro pendant le sommeil (cameraSetMicrophoneDuringSleepU(0)) puis met la caméra en vie privée (image noire,
// micro coupé, objectif ramené à 90°) ; `privacy-off` la réveille, et elle reprend d'elle-même sa position.
// Mêmes codes de sortie que `on` et `off`.
// obsbot-ai serve : garde le SDK chargé et lit les ordres `on`, `off`, `privacy on` ou `privacy off` sur l'entrée,
// un par ligne ; répond sur la sortie par « obsbot-ai: ready », puis « obsbot-ai: ok » ou « obsbot-ai: err <code> »
// par ordre. Se termine quand l'entrée se ferme. Lancé par ptzd, seulement pendant qu'un client pilote.
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

// Un ordre du mode serve ou du mode à un coup. Les ordres du mode serve s'écrivent « privacy on » ; ceux du mode
// à un coup « privacy-on » (un seul argument).
enum class Order { TrackingOn, TrackingOff, PrivacyOn, PrivacyOff, Unknown };

static Order parseOrder(const std::string &text) {
    if (text == "on") return Order::TrackingOn;
    if (text == "off") return Order::TrackingOff;
    if (text == "privacy on" || text == "privacy-on") return Order::PrivacyOn;
    if (text == "privacy off" || text == "privacy-off") return Order::PrivacyOff;
    return Order::Unknown;
}

static int32_t execute(const std::shared_ptr<Device> &tiny2, Order order) {
    switch (order) {
    case Order::TrackingOn: return setTracking(tiny2, true);
    case Order::TrackingOff: return setTracking(tiny2, false);
    case Order::PrivacyOn: return setPrivacy(tiny2, true);
    case Order::PrivacyOff: return setPrivacy(tiny2, false);
    case Order::Unknown: break;
    }
    return RM_RET_OK;
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
        // Les ordres du mode serve n'acceptent que la forme « privacy on » (avec une espace).
        const Order order = line.rfind("privacy-", 0) == 0 ? Order::Unknown : parseOrder(line);
        if (order == Order::Unknown) {
            reply(replies, "err 3");
        } else if (execute(tiny2, order) == RM_RET_OK) {
            reply(replies, "ok");
        } else {
            reply(replies, "err 2");
        }
    }
    Devices::get().close();
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && std::strcmp(argv[1], "serve") == 0) {
        return serve();
    }
    const Order order = argc == 2 ? parseOrder(argv[1]) : Order::Unknown;
    // Le mode à un coup n'accepte que la forme « privacy-on » (un seul argument, sans espace).
    if (order == Order::Unknown || std::strchr(argv[1], ' ') != nullptr) {
        std::fprintf(stderr, "usage : obsbot-ai on|off|privacy-on|privacy-off|serve\n");
        return 3;
    }
    auto tiny2 = findTiny2();
    if (!tiny2) {
        notFound(nullptr);
    }
    int32_t result = execute(tiny2, order);
    Devices::get().close();
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai : %s a renvoyé %d\n", argv[1], result);
        return 2;
    }
    switch (order) {
    case Order::TrackingOn: std::printf("obsbot-ai : suivi IA allumé\n"); break;
    case Order::TrackingOff: std::printf("obsbot-ai : suivi IA coupé\n"); break;
    case Order::PrivacyOn: std::printf("obsbot-ai : vie privée allumée\n"); break;
    case Order::PrivacyOff: std::printf("obsbot-ai : vie privée coupée\n"); break;
    case Order::Unknown: break;
    }
    return 0;
}
