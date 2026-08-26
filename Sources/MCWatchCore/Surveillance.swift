// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

/// Les serveurs que l'utilisateur a désignés lui-même.
///
/// Tout le reste de l'app part d'une recherche Shodan : on demande mille
/// adresses, on les suit, on les trie. Ici c'est l'inverse — on connaît déjà le
/// serveur, on veut seulement savoir ce qu'il devient. Le ping étant du TCP
/// direct, **rien de tout cela ne coûte de crédit**, ni même ne suppose une clé.
///
/// ─── Pourquoi un profil, et non un magasin à part ────────────────────────
///
/// Ces adresses sont rangées dans un profil ordinaire, sous un slug réservé.
/// Elles héritent alors de tout ce qui existe déjà : l'écriture atomique, le
/// tour de ping, la fusion, l'historique, les pics, la régularité, les marques,
/// le tableau et ses colonnes. Un magasin parallèle aurait tout redemandé —
/// deux dépôts à faire évoluer, deux formats à migrer, deux chemins de code à
/// tester — pour ranger une liste d'adresses.
///
/// Le prix est d'une ligne : ce slug est écarté du sélecteur de listes. Il ne
/// s'agit pas d'une recherche, et il n'a rien à faire parmi les recherches.
public enum Surveillance {

    /// Le slug réservé. Bref et sans tiret, donc reconnaissable d'un coup d'œil
    /// dans le dossier de données.
    ///
    /// ⚠️ `Slug.depuis` peut produire ce même mot si quelqu'un nomme sa
    /// recherche « surveillance ». La collision est improbable et sans gravité
    /// — les deux listes fusionneraient — mais `estReserve` permet de la
    /// refuser à la création plutôt que de la découvrir après.
    public static let slug = "surveillance"

    public static func estReserve(_ s: String) -> Bool { s == slug }

    // MARK: - Analyse d'une saisie

    /// Ce qu'on a compris d'une adresse tapée à la main.
    public struct Adresse: Sendable, Equatable {
        /// L'hôte tel qu'il sera joint : une IP littérale ou un nom.
        public let hote: String
        public let port: Int
        public var texte: String { port == 25565 ? hote : "\(hote):\(port)" }
        public var cible: Cible { Cible(ip: hote, port: port) }
    }

    public enum Refus: Error, Equatable, Sendable {
        case vide
        case portInvalide
        case hoteInvalide

        public var explication: String {
            switch self {
            case .vide:         String(localized: "Enter an address.")
            case .portInvalide: String(localized: "The port must be between 1 and 65535.")
            case .hoteInvalide: String(localized: "This does not look like an address or a host name.")
            }
        }
    }

    /// Lit une saisie et en tire une adresse joignable, ou dit pourquoi non.
    ///
    /// Accepte `1.2.3.4`, `1.2.3.4:25566`, `mc.exemple.com`, `mc.exemple.com:25566`,
    /// et tolère ce que les gens collent réellement : espaces autour, `http://`
    /// en tête, barre oblique finale.
    ///
    /// ⚠️ Cette fonction ne dit PAS qu'un serveur Minecraft existe là — elle ne
    /// touche pas au réseau. Elle écarte seulement ce qui ne peut désigner
    /// aucun hôte. La seule preuve qu'un serveur réponde est le ping, et c'est
    /// l'appelant qui le fait : voir `Ping.interroger`.
    public static func lire(_ saisie: String) -> Result<Adresse, Refus> {
        var t = saisie.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collé depuis un navigateur ou une page de liste de serveurs.
        for prefixe in ["http://", "https://", "minecraft://"] where t.lowercased().hasPrefix(prefixe) {
            t = String(t.dropFirst(prefixe.count))
        }
        while t.hasSuffix("/") { t.removeLast() }
        guard !t.isEmpty else { return .failure(.vide) }

        // ─── La séparation hôte / port est faite par le système ──────────
        //
        // `URLComponents` sait découper une autorité — c'est son métier, il est
        // éprouvé, et il traite au passage des formes qu'une analyse maison
        // oublierait : l'IPv6 entre crochets, les caractères encodés, un port
        // vide. Le schéma factice est indispensable : sans lui,
        // « mc.exemple.com:25566 » se lit comme un SCHÉMA suivi d'un chemin, et
        // l'hôte reste nul. Mesuré.
        //
        // ⚠️ Il sépare, il ne juge pas : il rend « 99999 » comme port et
        // « 1.2.3.999 » comme hôte sans broncher. Les bornes et la
        // vraisemblance restent donc à nous — c'est la même répartition que
        // pour `IPv4Address` : le système analyse, nous ajoutons ce qu'il ne
        // peut pas savoir.
        guard let parties = URLComponents(string: "mcwatch://" + t),
              let hote = parties.host, !hote.isEmpty
        else { return .failure(.hoteInvalide) }

        var port = 25565
        if let annonce = parties.port {
            guard (1...65535).contains(annonce) else { return .failure(.portInvalide) }
            port = annonce
        }

        guard estHoteVraisemblable(hote) else { return .failure(.hoteInvalide) }
        return .success(Adresse(hote: hote, port: port))
    }

    /// Ce qui peut désigner un hôte : une IPv4 littérale, ou un nom de domaine.
    ///
    /// Volontairement PERMISSIF sur les noms. On ne cherche pas à deviner si le
    /// domaine existe — le DNS et le ping le diront, et ils le diront mieux.
    /// On écarte seulement ce qui ne peut être ni l'un ni l'autre.
    static func estHoteVraisemblable(_ hote: String) -> Bool {
        guard !hote.isEmpty, hote.count <= 253 else { return false }
        if estIPv4(hote) { return true }
        // ⚠️ Ce qui n'est fait que de chiffres et de points PRÉTEND être une
        // adresse numérique, jamais un nom : aucun domaine ne se termine par
        // une étiquette entièrement numérique (RFC 3696 §2). Sans cette
        // coupure, « 1.2.3.999 » passait pour un nom d'hôte parfaitement
        // formé — chaque segment n'étant fait que de caractères permis — et
        // l'utilisateur découvrait plus tard un serveur qui ne répond jamais.
        if hote.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." } ) { return false }

        // Un nom de domaine : des étiquettes séparées par des points, chacune
        // faite de lettres, chiffres et tirets, sans commencer ni finir par un
        // tiret. Un nom sans point reste accepté — « localhost » en est un, et
        // un serveur sur le réseau local aussi.
        let etiquettes = hote.split(separator: ".", omittingEmptySubsequences: false)
        guard !etiquettes.isEmpty else { return false }
        return etiquettes.allSatisfy { e in
            !e.isEmpty && e.count <= 63
                && !e.hasPrefix("-") && !e.hasSuffix("-")
                && e.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Une IPv4 sous sa forme canonique.
    ///
    /// La validité numérique est déléguée à `IPv4Address` — c'est la pile
    /// réseau du système qui décide, pas nous. Elle refuse d'elle-même
    /// « 1.2.3.999 », « 256.1.1.1 » et « 1.2.3.4.5 », mesuré.
    ///
    /// ⚠️ Deux formes qu'elle accepte sont pourtant écartées ici, et ce ne sont
    /// pas des caprices : `IPv4Address` implémente les formes historiques
    /// d'`inet_aton`. « 1.2.3 » y vaut 1.2.0.3 — trois segments désignent un
    /// hôte que personne n'a voulu taper — et « 01.2.3.4 » se lit en octal chez
    /// certaines piles, en décimal chez d'autres. Une adresse qui ne désigne
    /// pas le même hôte partout n'est pas une adresse qu'on veut surveiller,
    /// et l'utilisateur qui l'a tapée s'est presque sûrement trompé.
    static func estIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") })
        else { return false }
        return IPv4Address(s) != nil
    }

    // MARK: - Cadence

    /// Les intervalles proposés, en minutes.
    ///
    /// ⚠️ Tous MULTIPLES de dix, et ce n'est pas un choix esthétique. L'agent
    /// launchd n'a qu'un seul `StartInterval`, lu dans le plist du paquet au
    /// moment de l'enregistrement : changer la cadence voudrait dire modifier
    /// ce plist, donc désenregistrer puis réenregistrer l'agent — très
    /// exactement le geste qui a déjà causé deux arrêts silencieux de la
    /// surveillance (voir `Agent`).
    ///
    /// On garde donc l'agent à son réveil de dix minutes, et c'est le SCANNER
    /// qui décide, à chaque réveil, ce qu'il a lieu de pinger. Une cadence de
    /// trente minutes travaille un réveil sur trois. Aucun plist n'est touché,
    /// aucun réenregistrement, aucun risque.
    ///
    /// Conséquence assumée : rien sous dix minutes. Pour savoir qu'un serveur
    /// s'est rempli, c'est amplement suffisant.
    public static let cadences = [10, 20, 30, 60]

    /// Le PAS du réveil, en minutes : c'est le `StartInterval` du plist, et il
    /// ne bouge jamais. Toute cadence proposée en est un multiple.
    ///
    /// ⚠️ À ne pas confondre avec les deux valeurs par défaut ci-dessous, qui
    /// se trouvaient valoir la même chose et partageaient donc la même
    /// constante. Les mélanger rendait impossible de changer un défaut sans
    /// changer aussi le rythme de l'agent — deux choses qui n'ont rien à voir.
    public static let pas = 10

    /// La liste Shodan à chaque réveil : elle est la raison d'être de l'app, et
    /// c'est là qu'on veut voir un serveur se remplir au plus tôt.
    public static let cadenceRechercheParDefaut = 10

    /// Les serveurs choisis à la main, un réveil sur trois. On sait déjà qu'ils
    /// existent : ce qu'on attend d'eux est une tendance, pas une alerte à la
    /// minute — et les interroger six fois par heure pour cela n'apprendrait
    /// rien de plus.
    public static let cadenceSurveillanceParDefaut = 30

    /// Ce réveil-ci concerne-t-il une liste cadencée à `minutes` ?
    ///
    /// `reveils` compte les réveils depuis toujours ; l'agent l'incrémente une
    /// fois par déclenchement. Le modulo suffit, et il a une propriété qu'un
    /// minuteur n'aurait pas : deux listes de même cadence tombent forcément
    /// sur le même réveil, donc sur un seul passage réseau. La synchronisation
    /// que l'utilisateur demande est ainsi gratuite — il n'y a rien à
    /// synchroniser, seulement des nombres égaux.
    public static func estLHeure(_ reveils: Int, cadence minutes: Int) -> Bool {
        let tous = max(1, minutes / pas)
        return reveils % tous == 0
    }
}

/// Ce que l'utilisateur règle pour la surveillance.
///
/// Rangé dans `UserDefaults` comme les filtres, et pour la même raison : c'est
/// une préférence, pas une donnée. Le système la sauvegarde, la synchronise
/// avec le compte s'il le faut, la purge à la désinstallation — trois choses
/// qu'un fichier maison aurait fallu réécrire.
///
/// Le décodage est TOLÉRANT, comme partout ailleurs dans ce projet : une
/// version qui ajoute un champ doit pouvoir relire ce qu'une version
/// précédente a écrit, sans repartir de zéro.
public struct ReglagesSurveillance: Codable, Sendable, Equatable {

    /// Cadence de la liste surveillée, en minutes.
    public var cadenceSurveillance = Surveillance.cadenceSurveillanceParDefaut

    /// Cadence de la liste de recherche Shodan, en minutes.
    ///
    /// Plus rapide que celle des serveurs choisis, et les deux restent
    /// synchronisés : trente est un multiple de dix, donc le tour des serveurs
    /// suivis tombe toujours sur un réveil où la recherche travaille déjà.
    /// Aucun passage réseau n'est ajouté par cet écart.
    public var cadenceRecherche = Surveillance.cadenceRechercheParDefaut

    /// Les filtres du classement s'appliquent-ils aussi aux serveurs
    /// surveillés ?
    ///
    /// FAUX par défaut, et c'est le réglage qui compte. Un serveur qu'on a
    /// désigné à la main et qui se vide disparaîtrait du tableau au moment
    /// précis où l'on veut savoir qu'il est vide. Le choix explicite de
    /// l'utilisateur prime sur n'importe quel critère automatique — mais il
    /// reste libre de demander l'inverse.
    public var filtrerSurveillance = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case cadenceSurveillance = "cadence_surveillance"
        case cadenceRecherche = "cadence_recherche"
        case filtrerSurveillance = "filtrer_surveillance"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReglagesSurveillance()
        cadenceSurveillance = c.valeur(.cadenceSurveillance, d.cadenceSurveillance)
        cadenceRecherche = c.valeur(.cadenceRecherche, d.cadenceRecherche)
        filtrerSurveillance = c.valeur(.filtrerSurveillance, d.filtrerSurveillance)
    }

    /// Une cadence relue doit figurer parmi celles qu'on propose : un fichier
    /// abîmé, ou écrit par une version qui offrait d'autres valeurs, ne doit
    /// pas produire un agent qui ne travaille jamais.
    public var valides: ReglagesSurveillance {
        var r = self
        if !Surveillance.cadences.contains(r.cadenceSurveillance) {
            r.cadenceSurveillance = Surveillance.cadenceSurveillanceParDefaut
        }
        if !Surveillance.cadences.contains(r.cadenceRecherche) {
            r.cadenceRecherche = Surveillance.cadenceRechercheParDefaut
        }
        return r
    }
}
