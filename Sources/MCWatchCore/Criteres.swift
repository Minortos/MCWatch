// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// La version de Minecraft qu'un serveur fait tourner, tirée de ce qu'il
/// annonce.
///
/// Shodan rend le champ `version` tel que le serveur l'écrit, et ce n'est
/// presque jamais une version nue : `Paper 26.2`, `Spigot 26.2`,
/// `Velocity 1.7.2-26.2`, `§e§lNOX§f§LCRAFT.PL §F 1.16.4-26.2`. Or le logiciel
/// employé n'intéresse personne ici : ce qui compte est la version que le
/// joueur doit lancer pour entrer.
///
/// Mesuré sur l'index de Shodan : **1000 chaînes distinctes se réduisent à 103
/// versions**. Sans ce regroupement, un menu de versions serait inutilisable.
/// Instancié plutôt que statique, et construit UNE fois par regroupement :
/// un `Regex` n'est pas `Sendable`, et surtout le rebâtir à chaque chaîne
/// coûterait 1,4 s pour les mille entrées d'une facette. Mesuré ailleurs dans
/// ce projet : 2053 constructions = 2,9 s, contre 1,5 ms en réutilisant.
public struct VersionMC {

    /// `x` est accepté comme joker. Les proxies écrivent des plages du genre
    /// `1.8.x-26.x`, et sans lui `26.x` n'était pas reconnu : le serveur
    /// atterrissait sous 1.8, soit dix-huit versions majeures trop bas.
    let motif = #/(\d+)\.(\d+|[xX])(?:\.(\d+|[xX]))?/#

    public init() {}

    /// La **plus haute** version citée, ou `nil` si la chaîne n'en contient
    /// aucune.
    ///
    /// La plus haute, et non la première, à cause des plages : un proxy qui
    /// annonce `1.7.2-26.2` accepte les clients jusqu'à 26.2, et c'est cette
    /// borne-là que le joueur lance.
    ///
    /// Le `nil` n'est pas un échec d'analyse mais une catégorie réelle : 3 120
    /// serveurs de l'index n'annoncent aucune version — boucliers anti-DDoS
    /// (`COSMIC GUARD`, `TCPShield.com`), états transitoires (`Maintenance`,
    /// `Offline`) ou noms fantaisistes.
    public func reelle(_ annonce: String) -> String? {
        var haute: (Int, Int, Int)?
        var texte: String?
        for m in annonce.matches(of: motif) {
            let n = { (t: Substring?) -> Int in t.flatMap { Int($0) } ?? 0 }
            let v = (Int(m.1) ?? 0, n(m.2), n(m.3))
            if haute == nil || v > haute! { haute = v; texte = String(m.0) }
        }
        return texte
    }

    /// Regroupe une facette Shodan par version réelle, en additionnant.
    public static func regrouper(_ facette: [(valeur: String, nombre: Int)])
        -> [(version: String?, nombre: Int)] {
        let lecteur = VersionMC()
        var sommes: [String: Int] = [:]
        var sansVersion = 0
        for e in facette {
            if let v = lecteur.reelle(e.valeur) { sommes[v, default: 0] += e.nombre }
            else { sansVersion += e.nombre }
        }
        var sortie = sommes.map { (version: Optional($0.key), nombre: $0.value) }
        sortie.sort { $0.nombre > $1.nombre }
        if sansVersion > 0 { sortie.append((version: nil, nombre: sansVersion)) }
        return sortie
    }
}

/// Ce que l'utilisateur choisit pour bâtir une liste.
///
/// Remplace le champ de texte libre, qui devinait le type de chaque mot selon
/// des règles invisibles et ordonnées — un entier y était toujours une taille,
/// jamais une version, si bien que taper `26` demandait 26 serveurs sans le
/// dire. Ici chaque valeur a son champ, donc plus rien à deviner.
public struct Criteres: Codable, Equatable, Sendable {
    public var versions: [String] = []
    public var pays: [String] = []
    public var hebergeurs: [String] = []
    /// Le seul champ resté libre : une recherche de texte dans la bannière,
    /// qui ne peut pas se ramener à une liste de choix.
    public var motd: String = ""
    public var taille: Int = Requete.limiteParDefaut

    public init() {}

    /// Ce qu'aucun choix ne peut retirer : Minecraft, et le port Java.
    ///
    /// Le port est figé parce que le ping parle le Server List Ping de Java
    /// Edition en TCP. Bedrock répond en RakNet sur l'UDP 19132 : ces
    /// serveurs entreraient dans la liste sans jamais répondre.
    ///
    /// ⚠️ En PIÈCES, et non en une chaîne d'un bloc. L'onglet Recherche annonce
    /// ce socle à l'utilisateur : tant qu'il était écrit d'un seul tenant, la
    /// vue ne pouvait que le recopier en clair, et sa phrase serait restée
    /// inchangée si l'on avait touché à la requête. Les deux se construisent
    /// désormais des mêmes morceaux.
    public static let produit = "Minecraft"
    public static let port = 25565

    /// Le port tel qu'il s'ÉCRIT, et pas seulement tel qu'il vaut.
    ///
    /// ⚠️ Interpolé comme `Int` dans un `Text`, SwiftUI le passe par les
    /// réglages de la session : 25565 s'affiche « 25 565 » en français, avec
    /// une espace insécable au milieu d'un numéro de port. Le convertir ici
    /// coupe court, et documente pourquoi.
    public static let portTexte = String(port)

    public static let socle = "product:\"\(produit)\" port:\(port)"

    /// Les champs qu'on peut retirer de la requête pour calculer un menu.
    public enum Champ: Sendable { case version, pays, hebergeur }

    /// Assemble la requête Shodan.
    ///
    /// `sans` sert aux menus, et c'est indispensable : le menu d'un champ doit
    /// être calculé sur la requête PRIVÉE de ce champ. Sinon, choisir 26.2
    /// restreignait la requête à 26.2, et la facette des versions ne rendait
    /// plus que 26.2 — le menu se vidait de ses propres options, et l'on ne
    /// pouvait plus passer à une autre version sans tout effacer d'abord.
    ///
    /// Le MOTD n'est jamais retiré : il n'a pas de menu à alimenter.
    ///
    /// Les valeurs multiples se séparent par une virgule, entre guillemets —
    /// syntaxe vérifiée contre l'API : `org:"OVH SAS","Hetzner Online GmbH"`
    /// rend exactement la somme des deux pris séparément, et le mot-clé `OR`
    /// est refusé avec une erreur 400.
    public func requete(sans exclu: Champ? = nil) -> String {
        var parties = [Criteres.socle]
        func ajouter(_ champ: String, _ valeurs: [String]) {
            let propres = valeurs.filter { !$0.isEmpty }
            guard !propres.isEmpty else { return }
            parties.append("\(champ):" + propres.map { "\"\($0)\"" }.joined(separator: ","))
        }
        if exclu != .version   { ajouter("version", versions) }
        if exclu != .pays      { ajouter("country", pays) }
        if exclu != .hebergeur { ajouter("org", hebergeurs) }
        let texte = motd.trimmingCharacters(in: .whitespaces)
        if !texte.isEmpty { parties.append("\"\(texte)\"") }
        return parties.joined(separator: " ")
    }

    /// L'étiquette lisible de la liste, celle qui s'affiche dans le sélecteur.
    public var etiquette: String {
        var bouts: [String] = []
        if !versions.isEmpty { bouts.append(versions.joined(separator: "/")) }
        if !pays.isEmpty { bouts.append(pays.joined(separator: "/")) }
        if !hebergeurs.isEmpty { bouts.append(hebergeurs.joined(separator: "/")) }
        let texte = motd.trimmingCharacters(in: .whitespaces)
        if !texte.isEmpty { bouts.append("“\(texte)”") }
        bouts.append("\(taille)")
        return bouts.joined(separator: " · ")
    }

    /// Un crédit par tranche de cent serveurs récupérés.
    public var credits: Int { max(1, (taille + 99) / 100) }
}
