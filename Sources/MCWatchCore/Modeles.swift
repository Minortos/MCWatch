// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreTransferable

// Les formats sur disque sont ceux écrits par les moteurs Python, et ils ne
// changent pas : l'ancienne et la nouvelle implémentation doivent pouvoir lire
// et écrire les mêmes fichiers pendant toute la transition.
//
// Conséquence directe : tout champ ajouté en cours de route (« pays » par
// exemple) est absent des anciennes entrées. Le décodage synthétisé de Swift
// échouerait sur la première ligne venue, donc chaque type lit ses champs un à
// un avec une valeur de repli.

extension KeyedDecodingContainer {
    /// Valeur du champ, ou le repli s'il est absent, nul, ou d'un type inattendu.
    func valeur<T: Decodable>(_ cle: Key, _ repli: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: cle)) ?? nil) ?? repli
    }
}

// MARK: - Un serveur suivi dans le temps

public struct Serveur: Codable, Sendable, Identifiable {
    public var ip: String
    public var port: Int
    public var maxVu: Int
    public var picAt: String?
    public var toursVus: Int
    public var toursPeuples: Int
    public var dernierOnline: Int
    public var dernierVu: String?
    public var slots: Int
    public var version: String
    public var motd: String
    public var hebergeur: String
    public var pays: String
    public var whitelistAnnoncee: Bool
    public var proxy: Bool
    public var motdPromotionnel: Bool
    public var motdParDefaut: Bool

    public var id: String { "\(ip):\(port)" }
    public var adresse: String { "\(ip):\(port)" }

    /// Part des relevés où le serveur avait au moins un joueur.
    public var regularite: Double {
        toursVus > 0 ? Double(toursPeuples) / Double(toursVus) : 0
    }

    enum CodingKeys: String, CodingKey {
        case ip, port, slots, version, motd, pays, proxy
        case hebergeur = "note"
        case maxVu = "max_vu"
        case picAt = "pic_at"
        case toursVus = "tours_vus"
        case toursPeuples = "tours_peuples"
        case dernierOnline = "dernier_online"
        case dernierVu = "dernier_vu"
        case whitelistAnnoncee = "whitelist_hint"
        case motdPromotionnel = "public_vibe"
        case motdParDefaut = "default_motd"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = c.valeur(.ip, "")
        port = c.valeur(.port, 25565)
        maxVu = c.valeur(.maxVu, 0)
        picAt = try? c.decodeIfPresent(String.self, forKey: .picAt)
        toursVus = c.valeur(.toursVus, 0)
        toursPeuples = c.valeur(.toursPeuples, 0)
        dernierOnline = c.valeur(.dernierOnline, 0)
        dernierVu = try? c.decodeIfPresent(String.self, forKey: .dernierVu)
        slots = c.valeur(.slots, 0)
        version = c.valeur(.version, "?")
        motd = c.valeur(.motd, "")
        hebergeur = c.valeur(.hebergeur, "")
        pays = c.valeur(.pays, "")
        whitelistAnnoncee = c.valeur(.whitelistAnnoncee, false)
        proxy = c.valeur(.proxy, false)
        motdPromotionnel = c.valeur(.motdPromotionnel, false)
        motdParDefaut = c.valeur(.motdParDefaut, false)
    }
}

extension Serveur {
    /// Construit un serveur de toutes pièces.
    ///
    /// `Serveur` définit `init(from:)` dans son corps, ce qui supprime
    /// l'initialiseur membre à membre synthétisé ; il faut donc le redonner ici
    /// pour pouvoir reconstruire un serveur depuis autre chose que du JSON —
    /// une base, par exemple.
    public init(ip: String, port: Int, maxVu: Int, picAt: String?, toursVus: Int,
                toursPeuples: Int, dernierOnline: Int, dernierVu: String?, slots: Int,
                version: String, motd: String, hebergeur: String, pays: String,
                whitelistAnnoncee: Bool, proxy: Bool, motdPromotionnel: Bool,
                motdParDefaut: Bool) {
        self.ip = ip; self.port = port; self.maxVu = maxVu; self.picAt = picAt
        self.toursVus = toursVus; self.toursPeuples = toursPeuples
        self.dernierOnline = dernierOnline; self.dernierVu = dernierVu
        self.slots = slots; self.version = version; self.motd = motd
        self.hebergeur = hebergeur; self.pays = pays
        self.whitelistAnnoncee = whitelistAnnoncee; self.proxy = proxy
        self.motdPromotionnel = motdPromotionnel; self.motdParDefaut = motdParDefaut
    }
}

// MARK: - Historique d'un profil

public struct MetaHistorique: Codable, Sendable {
    public var tours: Int
    public var debut: String?
    public var dernier: String?

    enum CodingKeys: String, CodingKey { case tours, debut, dernier }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tours = c.valeur(.tours, 0)
        debut = try? c.decodeIfPresent(String.self, forKey: .debut)
        dernier = try? c.decodeIfPresent(String.self, forKey: .dernier)
    }

    public init(tours: Int = 0, debut: String? = nil, dernier: String? = nil) {
        self.tours = tours; self.debut = debut; self.dernier = dernier
    }
}

public struct Historique: Codable, Sendable {
    public var meta: MetaHistorique
    public var serveurs: [String: Serveur]

    enum CodingKeys: String, CodingKey { case meta, serveurs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = c.valeur(.meta, MetaHistorique())
        serveurs = c.valeur(.serveurs, [:])
    }

    public init(meta: MetaHistorique = MetaHistorique(), serveurs: [String: Serveur] = [:]) {
        self.meta = meta; self.serveurs = serveurs
    }
}

// MARK: - Réglages du classement

public struct Filtres: Codable, Sendable, Equatable {
    public var picMin: Int = 1
    public var picMax: Int = 0          // 0 = illimité
    public var slotsMax: Int = 30       // 0 = illimité
    public var regularite: Int = 0      // en pourcentage
    public var sansProxy: Bool = true
    public var sansPub: Bool = true
    public var masquerWhitelist: Bool = true
    public var motdParDefautSeulement: Bool = false
    /// Éteint par défaut : il écarte environ 60 % d'une liste, ce qui doit
    /// rester un choix explicite et non une surprise au premier lancement.
    public var residentielSeulement: Bool = false
    public var masquerRates: Bool = false
    public var masquerReussis: Bool = false

    /// Écarter les serveurs qui n'ont pas répondu au dernier passage.
    ///
    /// Éteint par défaut : un serveur qui rate un tour — coupure réseau, reboot
    /// — reparaîtrait au suivant, et le faire disparaître sans qu'on l'ait
    /// demandé serait plus déroutant qu'utile. Mais sur une liste qui tourne
    /// depuis des semaines, la proportion de morts devient écrasante : mesuré à
    /// 266 sur 636 sur la liste réelle, soit 42 %, tous figés au pourcentage du
    /// jour de leur dernière réponse.
    ///
    /// ⚠️ Ce filtre ne peut pas vivre dans `retenuParLeDepot` : il ne dépend pas
    /// du serveur seul mais de la date du dernier tour, que le dépôt ne passe
    /// pas au prédicat. Même situation que les marques, et même place — voir
    /// `Selection.appliquer`.
    public var masquerMuets: Bool = false

    public var lignes: Int = 60         // 0 = toutes

    enum CodingKeys: String, CodingKey {
        case picMin = "min"
        case picMax = "max"
        case slotsMax = "slots"
        case regularite = "regulier"
        case sansProxy = "sans_proxy"
        case residentielSeulement = "residentiel_seulement"
        case sansPub = "sans_pub"
        case masquerWhitelist = "masquer_whitelist"
        case motdParDefautSeulement = "motd_defaut"
        case masquerRates = "masquer_non"
        case masquerReussis = "masquer_ok"
        case masquerMuets = "masquer_muets"
        case lignes = "limit"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Filtres()
        picMin = c.valeur(.picMin, d.picMin)
        picMax = c.valeur(.picMax, d.picMax)
        slotsMax = c.valeur(.slotsMax, d.slotsMax)
        regularite = c.valeur(.regularite, d.regularite)
        sansProxy = c.valeur(.sansProxy, d.sansProxy)
        residentielSeulement = c.valeur(.residentielSeulement, d.residentielSeulement)
        sansPub = c.valeur(.sansPub, d.sansPub)
        masquerWhitelist = c.valeur(.masquerWhitelist, d.masquerWhitelist)
        motdParDefautSeulement = c.valeur(.motdParDefautSeulement, d.motdParDefautSeulement)
        masquerRates = c.valeur(.masquerRates, d.masquerRates)
        masquerReussis = c.valeur(.masquerReussis, d.masquerReussis)
        masquerMuets = c.valeur(.masquerMuets, d.masquerMuets)
        lignes = c.valeur(.lignes, d.lignes)
    }
}

// MARK: - Verdicts d'essai, communs à toutes les listes

public enum Marque: String, Codable, Sendable {
    case reussi = "ok"
    case rate = "non"

    public var signe: String { self == .reussi ? "✓" : "✗" }
}

/// Ce qu'on sait d'un serveur pour l'avoir essayé.
///
/// Rangé à la racine et non dans un profil : un serveur reste le même serveur
/// d'une recherche à l'autre.
public struct Verdict: Codable, Sendable {
    public var verdict: Marque
    public var date: String

    public init(verdict: Marque, date: String) {
        self.verdict = verdict; self.date = date
    }
}

// MARK: - Crédits Shodan

public struct Credits: Codable, Sendable {
    public var solde: Int?
    public var vu: String?
    public var jourReinit: Int?
    public var reinits: [String] = []
    public var plafond: Int = 0
    public var plan: String = ""

    enum CodingKeys: String, CodingKey {
        case solde, vu, reinits, plafond, plan
        case jourReinit = "jour_reinit"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        solde = try? c.decodeIfPresent(Int.self, forKey: .solde)
        vu = try? c.decodeIfPresent(String.self, forKey: .vu)
        jourReinit = try? c.decodeIfPresent(Int.self, forKey: .jourReinit)
        reinits = c.valeur(.reinits, [])
        plafond = c.valeur(.plafond, 0)
        plan = c.valeur(.plan, "")
    }
}

// MARK: - Une adresse de la liste achetée à Shodan

public struct Cible: Sendable, Hashable {
    public var ip: String
    public var port: Int
    public var hebergeur: String
    public var pays: String

    public var adresse: String { "\(ip):\(port)" }

    public init(ip: String, port: Int, hebergeur: String = "", pays: String = "") {
        self.ip = ip; self.port = port; self.hebergeur = hebergeur; self.pays = pays
    }
}

// MARK: - Un profil = une recherche

public struct Profil: Sendable {
    public var slug: String
    public var recherche: String
    public var requete: String
    public var cibles: [Cible]
    public var historique: Historique

    public var estVide: Bool { cibles.isEmpty && historique.serveurs.isEmpty }
}

/// Ce qu'un serveur donne au presse-papiers : son adresse, rien d'autre — c'est
/// ce qu'on colle dans Minecraft.
///
/// Passer par `Transferable` plutôt que d'écrire dans `NSPasteboard` à la main
/// permet à la commande **standard** Édition → Copier de fonctionner sur la
/// sélection du tableau. L'app remplaçait auparavant tout le groupe
/// presse-papiers du menu, ce qui supprimait Couper, Coller et Tout sélectionner
/// — et donc leurs raccourcis : ⌘V répondait par le bip d'erreur de macOS.
extension Serveur: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.adresse)
    }
}
