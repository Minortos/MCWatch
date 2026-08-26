// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import Synchronization

/// Ce qu'un serveur répond quand on l'interroge.
public struct Releve: Sendable {
    public var ip: String
    public var port: Int
    public var hebergeur: String
    public var pays: String
    public var enLigne: Int
    public var slots: Int
    public var version: String
    public var motd: String
    public var whitelistAnnoncee: Bool
    public var proxy: Bool
    public var motdPromotionnel: Bool
    public var motdParDefaut: Bool
    /// Vrai si c'est l'ancien protocole qui a répondu. Un repli inattendu
    /// trahirait un défaut de l'implémentation moderne.
    public var protocoleAncien: Bool

    public var adresse: String { "\(ip):\(port)" }
}

// MARK: - Erreurs internes

enum ErreurPing: Error {
    case echeance              // le port écoute mais l'échange n'aboutit pas
    case protocoleInattendu    // le port répond, mais pas comme prévu
}

// MARK: - Le canal

/// TCP nu, piloté par l'API Swift de Network (macOS 26+).
///
/// Il n'y a plus d'enveloppe maison autour de `NWConnection` : plus de file
/// `Dispatch` par connexion, plus de continuations à reprendre une seule fois,
/// plus de drapeau verrouillé pour ne couper qu'une fois. Ce que cette classe
/// faisait à la main, `NetworkConnection` le fait nativement — et sans le
/// `cancel()` manuel qui était la source du bruit dans Console (voir `essai`).
public typealias Canal = NetworkConnection<TCP>

/// Borne stricte autour d'un échange complet.
///
/// `connectionTimeout` ne couvre que l'établissement. Un serveur qui accepte la
/// connexion puis se tait laisserait la lecture pendante sans fin ; c'est cette
/// course qui l'interrompt. L'annulation structurée démonte la connexion en
/// remontant la pile — rien à couper soi-même.
func avecEcheance<T: Sendable>(_ delai: Duration,
                               _ corps: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { groupe in
        groupe.addTask { try await corps() }
        groupe.addTask { try await Task.sleep(for: delai); throw ErreurPing.echeance }
        let premier = try await groupe.next()!
        groupe.cancelAll()
        return premier
    }
}

// MARK: - Le protocole Minecraft

public enum Ping {

    /// Trace le déroulé du protocole moderne, pour diagnostic.
    nonisolated(unsafe) public static var trace = false
    static func tr(_ m: String) { if trace { print("     · \(m)") } }

    // --- varints ---

    static func varint(_ valeur: Int) -> Data {
        var n = UInt32(bitPattern: Int32(valeur))
        var sortie = Data()
        repeat {
            var octet = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { octet |= 0x80 }
            sortie.append(octet)
        } while n != 0
        return sortie
    }

    static func chaine(_ s: String) -> Data {
        let d = Data(s.utf8)
        return varint(d.count) + d
    }

    /// Lit exactement `combien` octets, ou échoue.
    ///
    /// À n'utiliser qu'ainsi, jamais `receive` directement : `receive(exactly:)`
    /// ne tient pas sa promesse quand le pair ferme — elle rend un message vide
    /// marqué `endOfStream`, sans rien jeter. Et `receive(as:)` charge l'entier
    /// sans vérifier la taille du tampon : sur cette même fermeture elle plante
    /// (« UnsafeRawBufferPointer.load out of bounds »). Or c'est précisément là
    /// qu'un serveur d'avant 1.7 ferme, face à la poignée de main moderne :
    /// c'est le cas courant du scanner, pas un cas limite.
    static func lire(_ c: Canal, _ combien: Int) async throws -> Data {
        let message = try await c.receive(exactly: combien)
        guard message.content.count == combien else { throw ErreurPing.protocoleInattendu }
        return message.content
    }

    static func lireVarint(_ c: Canal) async throws -> Int {
        var n = 0, decalage = 0
        for _ in 0..<5 {
            let octet = try await lire(c, 1).first!   // `lire` a garanti la taille

            n |= Int(octet & 0x7F) << decalage
            if octet & 0x80 == 0 { return n }
            decalage += 7
        }
        throw ErreurPing.protocoleInattendu
    }

    /// Un varint Minecraft fait **au plus cinq octets**. Sans cette borne, une
    /// réponse malveillante enchaînant les octets de continuation accumulait des
    /// décalages jusqu'à 63 bits et produisait une longueur proche de `Int.max`.
    static func lireVarint(_ tampon: Data, _ i: inout Int) throws -> Int {
        var n = 0, decalage = 0
        for _ in 0..<5 {
            guard i < tampon.count else { throw ErreurPing.protocoleInattendu }
            let octet = tampon[tampon.startIndex + i]
            i += 1
            n |= Int(octet & 0x7F) << decalage
            if octet & 0x80 == 0 { return n }
            decalage += 7
        }
        throw ErreurPing.protocoleInattendu
    }

    // --- protocole moderne, 1.7 et au-delà ---

    public struct Reponse: Sendable {
        public var version: String
        public var motd: String
        public var enLigne: Int
        public var slots: Int
    }

    /// Poignée de main **et** demande de statut en une seule écriture : le
    /// protocole est un flux d'octets, rien n'oblige à les séparer. Un segment,
    /// un réveil et un aller-retour de moins par cible — sur mille cibles, c'est
    /// mille échanges épargnés.
    static func demandeStatut(hote: String, port: Int) -> Data {
        let poignee = Data([0x00]) + varint(767) + chaine(hote)
            + Data([UInt8(port >> 8), UInt8(port & 0xFF)]) + varint(1)
        return varint(poignee.count) + poignee + varint(1) + Data([0x00])
    }

    /// La demande est déjà partie quand on arrive ici : `essai` l'a écrite au
    /// moment d'ouvrir, il ne reste qu'à lire.
    public static func moderne(_ c: Canal) async throws -> Reponse {
        let taille = try await lireVarint(c)
        tr("announced packet size: \(taille)")
        guard taille > 0, taille < (1 << 21) else { throw ErreurPing.protocoleInattendu }
        let corps = try await lire(c, taille)
        tr("body received: \(corps.count) bytes")

        var i = 0
        let paquet = try lireVarint(corps, &i)
        tr("identifiant de paquet : \(paquet)")
        let longueur = try lireVarint(corps, &i)      // longueur de la chaîne JSON
        tr("announced JSON length: \(longueur), remaining: \(corps.count - i)")
        // Comparer à ce qu'il RESTE, jamais `debut + longueur` : cette addition
        // débordait sur une longueur hostile et faisait planter le scanner
        // (« Swift runtime failure: arithmetic overflow »). Prouvé avec un faux
        // serveur local renvoyant un varint de neuf octets.
        guard longueur >= 0, longueur <= corps.count - i else {
            throw ErreurPing.protocoleInattendu
        }
        let debut = corps.startIndex + i
        let brut = Data(corps[debut..<(debut + longueur)])   // copie : évite le piège du startIndex

        guard let objet = try? JSONSerialization.jsonObject(with: brut) as? [String: Any] else {
            tr("unreadable JSON · start = \(String(decoding: brut.prefix(60), as: UTF8.self))")
            throw ErreurPing.protocoleInattendu
        }
        let joueurs = objet["players"] as? [String: Any] ?? [:]
        return Reponse(
            version: ((objet["version"] as? [String: Any])?["name"] as? String) ?? "?",
            motd: aplatir(objet["description"]),
            enLigne: joueurs["online"] as? Int ?? 0,
            slots: joueurs["max"] as? Int ?? 0)
    }

    /// La description peut être une chaîne, un objet `{text, extra}`, ou un
    /// tableau — et ces formes s'imbriquent. La profondeur est bornée : le JSON
    /// vient d'un serveur inconnu, et rien n'empêche d'y enfiler des milliers de
    /// niveaux, ce qui ferait déborder la pile d'appels.
    static func aplatir(_ valeur: Any?, profondeur: Int = 0) -> String {
        guard profondeur < 24 else { return "" }
        if let s = valeur as? String { return s }
        if let tableau = valeur as? [Any] {
            return tableau.map { aplatir($0, profondeur: profondeur + 1) }.joined()
        }
        if let o = valeur as? [String: Any] {
            let texte = o["text"] as? String ?? ""
            let extra = (o["extra"] as? [Any])?
                .map { aplatir($0, profondeur: profondeur + 1) }.joined() ?? ""
            return texte + extra
        }
        return ""
    }

    // --- protocole ancien : Beta 1.8 à 1.6 ---

    /// Deux sondes existent, `0xFE 0x01` (1.4 et plus) et `0xFE` seul ; c'est
    /// `interroger` qui choisit laquelle écrire. Ici encore, on ne fait que lire.
    static func ancien(_ c: Canal) async throws -> Reponse {
        let entete = try await lire(c, 3)
        guard entete[entete.startIndex] == 0xFF else { throw ErreurPing.protocoleInattendu }
        let nb = Int(entete[entete.startIndex + 1]) << 8 | Int(entete[entete.startIndex + 2])
        guard nb > 0, nb < 4096 else { throw ErreurPing.protocoleInattendu }
        let charge = try await lire(c, nb * 2)

        var unites: [UInt16] = []
        unites.reserveCapacity(nb)
        for k in stride(from: 0, to: nb * 2, by: 2) {
            unites.append(UInt16(charge[charge.startIndex + k]) << 8
                          | UInt16(charge[charge.startIndex + k + 1]))
        }
        let texte = String(decoding: unites, as: UTF16.self)

        if texte.hasPrefix("§1") {
            // 1.4 à 1.6 : §1 \0 protocole \0 version \0 motd \0 en ligne \0 max
            let p = texte.components(separatedBy: "\u{0}")
            guard p.count >= 6 else { throw ErreurPing.protocoleInattendu }
            return Reponse(version: p[2], motd: p[3],
                           enLigne: Int(p[4]) ?? 0, slots: Int(p[5]) ?? 0)
        }
        // Beta jusqu'à 1.3 : motd § en ligne § max, sans numéro de version
        let p = texte.components(separatedBy: "§")
        guard p.count >= 3 else { throw ErreurPing.protocoleInattendu }
        return Reponse(version: "ancien (<=1.3)", motd: p[0],
                       enLigne: Int(p[1]) ?? 0, slots: Int(p[2]) ?? 0)
    }

    // --- lecture du MOTD, à l'identique du moteur Python ---

    // Motifs en littéraux `Regex` : vérifiés à la compilation, sans `try!` ni
    // chaîne à échapper deux fois.
    //
    // ⚠️ **`.matchingSemantics(.unicodeScalar)` n'est pas décoratif.** Swift
    // fait correspondre des `Character` (grappes de graphèmes) là où
    // `NSRegularExpression` travaillait sur des unités UTF-16 : sans ce
    // réglage, `\s` avalait un espace **et le signe combinant qui le suit**,
    // et trois MOTD réels sur 2051 changeaient de contenu. De même,
    // `.wordBoundaryKind(.simple)` reproduit les frontières de mot d'ICU,
    // sans quoi neuf serveurs changeaient de drapeau « promotionnel ».
    // Migration validée par comparaison des deux moteurs sur les 2051 MOTD
    // de l'historique : **0 écart** sur le nettoyage et sur les trois drapeaux.
    /// Les cinq motifs, construits **une seule fois** puis réutilisés.
    ///
    /// Une valeur, et non des propriétés statiques : `Regex` n'est pas
    /// `Sendable`, donc impossible à partager entre les sondes concurrentes.
    /// Ce jeu est créé au début de l'interprétation, en série, et sert les
    /// centaines de réponses d'un tour — cinq constructions au lieu de quatre
    /// mille.
    struct Motifs {
        let couleur = #/§./#.matchingSemantics(.unicodeScalar)
        let whitelist = #/white\s*-?\s*list|liste\s*blanche/#
            .ignoresCase().matchingSemantics(.unicodeScalar)
        let proxy = #/velocity|bungee|waterfall|proxy/#
            .ignoresCase().matchingSemantics(.unicodeScalar)
        let promo = #/\b[\w-]+\.(net|com|org|fr|io|gg|xyz|eu)\b|discord|store|vote|rank/#
            .ignoresCase().matchingSemantics(.unicodeScalar).wordBoundaryKind(.simple)
        let espaces = #/\s+/#.matchingSemantics(.unicodeScalar)
    }

    static func trouve(_ r: some RegexComponent, _ s: String) -> Bool {
        s.firstMatch(of: r) != nil
    }

    static func nettoyerMotd(_ brut: String, _ motifs: Motifs = Motifs()) -> String {
        var m = brut.replacing(motifs.couleur, with: "")
        m = m.replacingOccurrences(of: "\n", with: " ")
        m = m.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.replacing(motifs.espaces, with: " ")
    }

    // --- une tentative sur une cible ---

    /// Ce qu'a donné une tentative.
    public struct Tentative: Sendable {
        public var reponse: Reponse?
        /// Faux si rien n'écoute. Inutile alors de réessayer en ancien
        /// protocole : un hôte mort ne coûte qu'une seule connexion.
        public var connecte: Bool
    }

    /// Ouvre, écrit, lit, referme — la connexion ne survit pas à cette portée.
    ///
    /// La connexion n'a **pas** de `cancel()` public : ARC la démonte, une seule
    /// fois, à la sortie. C'est le point clé. L'ancienne version appelait
    /// `cancel()` depuis son garde-temps, souvent sur une connexion qui n'avait
    /// jamais abouti ; Network.framework collecte alors un rapport
    /// d'établissement inexistant et journalise cinq lignes d'erreur par
    /// connexion (« Client called … on unconnected nw_connection »). Mesuré :
    /// dix hôtes muets donnaient cinquante lignes, ici zéro.
    ///
    /// ⚠️ **Ne pas « simplifier » avec `withNetworkConnection`.** Ce raccourci
    /// coupe la connexion **deux fois** à la sortie du bloc, et le système
    /// journalise « is already cancelled, ignoring cancel » à chaque appel —
    /// une ligne par cible, soit ~1000 par tour. Vérifié comme inconditionnel :
    /// la ligne sort même avec un corps vide, sans la moindre entrée-sortie.
    /// La connexion nue, elle, ne produit rien : 30 échanges et 30 hôtes muets,
    /// zéro ligne parasite et zéro descripteur fuité.
    static func essai(_ cible: Cible, delai: Double, envoi: Data,
                      _ jouer: @escaping @Sendable (Canal) async throws -> Reponse) async -> Tentative {
        // Seul témoin partagé entre le rappel d'état et la suite : un `Mutex`
        // de la bibliothèque standard, sans allocation ni file associée.
        let etabli = Mutex(false)
        // Les deux minuteries ne doivent JAMAIS être réglées à la même valeur.
        // Elles l'étaient, et couraient l'une contre l'autre : quand la course
        // structurée gagnait, elle annulait — donc démontait — une connexion qui
        // n'avait jamais abouti, ce qui fait précisément réapparaître les lignes
        // « unconnected nw_connection ». Mesuré sur un vrai tour : 28 connexions
        // sur 54 expirations, soit un tirage à pile ou face. TCP garde donc le
        // budget d'établissement, et la course ne sert plus que de filet pour la
        // phase d'échange — sur une connexion établie, donc silencieuse.
        //
        // Marge de deux secondes plutôt qu'une, par précaution : la connexion
        // peut enchaîner plusieurs points de terminaison (nom d'hôte résolvant
        // en plusieurs adresses, IPv4 puis IPv6), chacun avec son propre
        // `connectionTimeout`, si bien qu'une seconde d'écart ne suffit pas à
        // garantir que TCP renonce le premier.
        //
        // ⚠️ CE QUI SUIT CORRIGE UNE MESURE FAUSSE. Il était écrit ici qu'il
        // restait « environ une cible sur mille » à produire ses cinq lignes
        // « unconnected ». C'était vrai là où la mesure avait été prise, et
        // faux ailleurs — le chiffre dépend entièrement du PROCESSUS qui ping :
        //
        //   · le scanner, sur la liste entière     ·    0 ligne
        //   · un binaire nu, hors bac à sable      ·    0 ligne
        //   · l'APP, même code et mêmes cibles     ·  855 lignes,
        //                                    soit 171 connexions sur 1000 — 17 %
        //
        // La course n'y est pour rien, contrairement à ce qu'on pouvait croire
        // : la marge a été portée de 2 s à 12 s — six fois — et le bruit n'a pas
        // diminué. La cause reste inconnue ; elle tient à ce que l'app fait
        // autour du ping (interface, base, minuteries), et non à cet arbitrage.
        //
        // Ne pas « réparer » ceci sans mesurer DANS L'APP : c'est le seul
        // endroit où le phénomène existe, et deux mesures prises ailleurs ont
        // déjà conclu à tort. Ce n'est du reste pas un dysfonctionnement — le
        // tour aboutit, les relevés sont justes — mais du bruit dans Console.
        //
        // Une piste a été écartée sciemment : attendre l'état `.ready` avant de
        // lire supprimerait sans doute ces lignes, mais ne ferait économiser NI
        // paquet, NI connexion, NI temps — seulement des lignes de journal, au
        // prix d'une continuation de plus par cible. On ne complique pas le
        // chemin le plus chaud du projet pour rendre Console plus joli.
        let etablissement = Swift.max(1, delai.rounded(.down))
        do {
            let reponse = try await avecEcheance(.seconds(etablissement + 2)) {
                let c = Canal(
                    to: .hostPort(host: NWEndpoint.Host(cible.ip),
                                  port: NWEndpoint.Port(integerLiteral: UInt16(cible.port))),
                    using: {
                        // L'échéance de connexion est portée par TCP lui-même :
                        // il renonce seul, sans qu'on ait à couper quoi que ce soit.
                        // `noDelay` : la demande tient dans un segment, Nagle
                        // n'aurait rien à regrouper et ne ferait qu'attendre.
                        TCP().connectionTimeout(UInt32(etablissement))
                             .noDelay(true)
                    })
                c.onStateUpdate { _, etat in
                    if case .ready = etat { etabli.withLock { $0 = true } }
                }
                // Écriture non bloquante, et c'est délibéré : sur un hôte muet,
                // `send` attend la connectivité sans fin, alors que la lecture,
                // elle, remonte l'échec. Accessoirement la demande peut voyager
                // dans le SYN quand TCP Fast Open est possible.
                c.sendIdempotent(envoi)
                return try await jouer(c)
            }
            return Tentative(reponse: reponse, connecte: true)
        } catch {
            return Tentative(reponse: nil, connecte: etabli.withLock { $0 })
        }
    }

    /// Déroule le protocole moderne sur une seule cible, pour `--diag`.
    public static func diagnostic(hote: String, port: Int, delai: Double = 5) async -> Tentative {
        await essai(Cible(ip: hote, port: port), delai: delai,
                    envoi: demandeStatut(hote: hote, port: port)) { try await moderne($0) }
    }

    /// La connexion est séparée du protocole : un hôte mort coûte une seule
    /// tentative, alors qu'un port qui répond mérite d'être interrogé autrement.
    /// Face à la poignée de main moderne, un serveur d'avant 1.7 coupe la
    /// connexion OU reste muet — les deux cas mènent à l'ancien protocole.
    public static func interroger(_ cible: Cible, delai: Double = 3) async -> Sonde? {
        // `NWEndpoint.Port` et l'écriture du port sur deux octets piègent tous
        // deux une valeur hors bornes. Une liste importée peut en contenir.
        guard (1...65535).contains(cible.port) else { return nil }

        var essaye = await essai(cible, delai: delai,
                                 envoi: demandeStatut(hote: cible.ip, port: cible.port)) {
            try await moderne($0)
        }
        guard essaye.connecte else { return nil }

        var parAncien = false
        if essaye.reponse == nil {
            parAncien = true
            for sonde in [Data([0xFE, 0x01]), Data([0xFE])] {
                essaye = await essai(cible, delai: delai, envoi: sonde) { try await ancien($0) }
                if essaye.reponse != nil { break }
            }
        }
        guard let r = essaye.reponse else { return nil }
        return Sonde(cible: cible, reponse: r, parAncien: parAncien)
    }

    /// Ce qu'un serveur a répondu, avant toute interprétation du texte.
    ///
    /// Cette étape est séparée pour une raison mesurée : `Regex` **n'est pas
    /// `Sendable`**, donc un motif ne peut pas être partagé entre les cent
    /// vingt-huit sondes concurrentes. Le reconstruire à chaque usage coûte
    /// **72 µs**, soit seize fois le coût de la correspondance elle-même et
    /// 319 ms perdues par tour. En interprétant les textes **après** le groupe
    /// de tâches, une seule série de motifs sert les 886 réponses : cinq
    /// constructions par tour au lieu de quatre mille.
    ///
    /// Le détecteur de courses ne signale rien sur un motif partagé, mais Apple
    /// a délibérément choisi de ne pas le déclarer `Sendable` : on ne passe pas
    /// outre avec un `nonisolated(unsafe)` sur la foi d'un test.
    public struct Sonde: Sendable {
        public var cible: Cible
        public var reponse: Reponse
        public var parAncien: Bool
    }

    /// Traduit une réponse brute en relevé : nettoyage du MOTD et drapeaux.
    /// Appelée en série, hors du groupe de tâches.
    static func interpreter(_ s: Sonde, _ motifs: Motifs) -> Releve {
        let motd = nettoyerMotd(s.reponse.motd, motifs)
        return Releve(
            ip: s.cible.ip, port: s.cible.port,
            hebergeur: String(s.cible.hebergeur.prefix(24)), pays: s.cible.pays,
            enLigne: s.reponse.enLigne, slots: s.reponse.slots,
            version: s.reponse.version, motd: motd,
            whitelistAnnoncee: trouve(motifs.whitelist, motd),
            proxy: trouve(motifs.proxy, s.reponse.version),
            motdPromotionnel: trouve(motifs.promo, motd),
            motdParDefaut: motd.lowercased() == "a minecraft server",
            protocoleAncien: s.parAncien)
    }

    /// Interroge toute une liste, `parallele` cibles à la fois.
    ///
    /// 128 mesuré comme le bon compromis sur 1000 cibles : 13,5 s contre 16,0 s
    /// à 64, sans perte de résultats. Au-delà (256 → 11,9 s) la contention fait
    /// expirer quelques serveurs lents, ce qui n'est pas un bon échange.
    ///
    /// `priorite` par défaut à `.utility` : un relevé est de l'attente réseau,
    /// pas du calcul. Sur Apple Silicon cette qualité de service oriente le
    /// travail vers les cœurs d'efficacité, pour une durée équivalente et une
    /// dépense bien moindre. L'app peut demander mieux pour un relevé manuel.
    public static func tour(_ cibles: [Cible], delai: Double = 3,
                            parallele: Int = 128,
                            priorite: TaskPriority = .utility) async -> [Releve] {
        await withTaskGroup(of: Sonde?.self) { groupe in
            var sondes: [Sonde] = []
            sondes.reserveCapacity(cibles.count)
            var suivante = 0

            for _ in 0..<Swift.min(parallele, cibles.count) {
                let c = cibles[suivante]; suivante += 1
                groupe.addTask(priority: priorite) { await interroger(c, delai: delai) }
            }
            while let fini = await groupe.next() {
                if let fini { sondes.append(fini) }
                if suivante < cibles.count {
                    let c = cibles[suivante]; suivante += 1
                    groupe.addTask(priority: priorite) { await interroger(c, delai: delai) }
                }
            }
            // Interprétation des textes en série, une fois le réseau terminé :
            // les motifs sont construits une seule fois pour tout le tour.
            let motifs = Motifs()
            return sondes.map { interpreter($0, motifs) }
        }
    }
}
