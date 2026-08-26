// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Client Shodan en appels HTTPS directs. Remplace le CLI installé par Homebrew,
/// qui ne faisait rien d'autre que ces mêmes requêtes.
///
/// Seule `chercher` consomme des crédits, à raison d'un par page de 100
/// résultats. `compter`, `facette` et `infos` sont gratuits.
public struct Shodan: Sendable {

    public enum Erreur: Error, LocalizedError {
        case cleAbsente
        case reseau(String)
        case reponseIllisible
        case refus(Int, String)

        public var errorDescription: String? {
            switch self {
            case .cleAbsente:
                return String(localized: "No Shodan API key configured.")
            case .reseau(let m):
                return String(localized: "Shodan unreachable: \(m)")
            case .reponseIllisible:
                return String(localized: "Unreadable Shodan response.")
            case .refus(let c, let m):
                return String(localized: "Shodan refused the request (\(c)): \(m)")
            }
        }
    }

    public let cle: String
    let session: URLSession

    /// Session **sans cache disque**. L'API Shodan n'accepte la clé qu'en
    /// paramètre d'URL : la laisser passer par le cache partagé de `URLSession`
    /// reviendrait à en déposer une copie en clair dans `~/Library/Caches`,
    /// alors qu'on a justement pris soin de la ranger dans le trousseau.
    static let sessionSansTrace: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    public init(cle: String, session: URLSession? = nil) {
        self.cle = cle
        self.session = session ?? Shodan.sessionSansTrace
    }

    /// Où le CLI Shodan range la clé de l'utilisateur.
    ///
    /// L'app ne lit plus ce fichier d'elle-même : elle **propose** de l'importer
    /// et ouvre le sélecteur système dessus. C'est l'utilisateur qui désigne le
    /// fichier, et c'est ce geste qui donne l'accès — l'ancienne lecture
    /// silencieuse revenait à s'approprier la clé d'un autre logiciel.
    public static let cheminCleDuCLI = "~/.config/shodan/api_key"

    /// Le dossier du CLI, en chemin **réel**, pour y pointer le sélecteur.
    ///
    /// ⚠️ Ni `~` ni `homeDirectoryForCurrentUser` ne conviennent : en bac à
    /// sable, tous deux désignent le CONTENEUR de l'app, où il n'y a évidemment
    /// aucun fichier du CLI. `getpwuid` rend le vrai dossier de départ, celui
    /// que le sélecteur — qui tourne hors du bac à sable — saura afficher.
    public static var dossierCleDuCLI: URL {
        let foyer = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: foyer).appendingPathComponent(".config/shodan",
                                                                 isDirectory: true)
    }

    // MARK: - Appel générique

    /// Le corps que renvoie l'API quand elle refuse, quel que soit le point
    /// d'entrée. Décodé à part, avant la réponse attendue.
    struct Refus: Decodable { let error: String }

    func appeler<T: Decodable>(_ chemin: String, _ parametres: [String: String],
                               _ type: T.Type) async throws -> T {
        var comp = URLComponents(string: "https://api.shodan.io" + chemin)!
        comp.queryItems = ([("key", cle)] + parametres.sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }).map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comp.url else { throw Erreur.reponseIllisible }

        var requete = URLRequest(url: url)
        requete.timeoutInterval = 30

        let donnees: Data, reponse: URLResponse
        do { (donnees, reponse) = try await session.data(for: requete) }
        // ⚠️ `localizedDescription`, et JAMAIS l'erreur brute.
        //
        // L'API de Shodan exige la clé en paramètre d'URL : elle est donc dans
        // l'adresse de chaque appel. Or une erreur d'URLSession range cette
        // adresse dans son `userInfo`, sous `NSURLErrorFailingURLStringErrorKey`
        // — clé comprise. `localizedDescription` n'en montre rien (vérifié :
        // « A server with the specified hostname could not be found. »), mais
        // `"\(error)"` ou `String(describing:)` déballent tout `userInfo`.
        //
        // Ce texte remonte jusqu'à l'écran des réglages. Interpoler l'erreur
        // entière afficherait la clé à quiconque regarde — et la publierait
        // pour de bon le jour où quelqu'un joint une capture à un rapport de
        // bogue. Ne pas « améliorer » cette ligne en montrant plus.
        catch { throw Erreur.reseau(error.localizedDescription) }

        let decodeur = JSONDecoder()
        let refus = try? decodeur.decode(Refus.self, from: donnees)
        if let http = reponse as? HTTPURLResponse, http.statusCode != 200 {
            throw Erreur.refus(http.statusCode, refus?.error ?? "")
        }
        // Shodan répond parfois 200 avec un corps d'erreur.
        if let refus { throw Erreur.refus(200, refus.error) }
        do { return try decodeur.decode(T.self, from: donnees) }
        catch { throw Erreur.reponseIllisible }
    }

    // MARK: - Gratuit

    /// La valeur d'une facette est tantôt un texte (`version`), tantôt un
    /// nombre (`port`). Un décodage à essais successifs remplace le
    /// `String(describing:)` sur `Any` d'avant, qui masquait le problème.
    enum ValeurFacette: Decodable {
        case texte(String), nombre(Int)
        var chaine: String {
            switch self {
            case .texte(let s):  return s
            case .nombre(let n): return String(n)
            }
        }
        init(from decodeur: Decoder) throws {
            let c = try decodeur.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .texte(s) }
            else { self = .nombre(try c.decode(Int.self)) }
        }
    }

    struct ReponseComptage: Decodable {
        let total: Int
        let facets: [String: [Facette]]?
        struct Facette: Decodable {
            let count: Int
            let value: ValeurFacette
        }
    }

    /// Nombre de résultats, sans en récupérer aucun.
    public func compter(_ requete: String) async throws -> Int {
        try await appeler("/shodan/host/count", ["query": requete],
                          ReponseComptage.self).total
    }

    /// Répartition d'un champ — le même point d'API que `compter`, donc gratuit.
    public func facette(_ requete: String, _ champ: String,
                        _ combien: Int = 10) async throws -> [(valeur: String, nombre: Int)] {
        let o = try await appeler("/shodan/host/count",
                                  ["query": requete, "facets": "\(champ):\(combien)"],
                                  ReponseComptage.self)
        return (o.facets?[champ] ?? []).map { ($0.value.chaine, $0.count) }
    }

    public struct Infos: Sendable {
        public var creditsRecherche: Int
        public var creditsScan: Int
        public var plafondRecherche: Int
        public var plafondScan: Int
        public var plan: String
    }

    struct ReponseInfos: Decodable {
        let queryCredits: Int?
        let scanCredits: Int?
        let plan: String?
        let usageLimits: Limites?
        struct Limites: Decodable {
            let queryCredits: Int?
            let scanCredits: Int?
            enum CodingKeys: String, CodingKey {
                case queryCredits = "query_credits", scanCredits = "scan_credits"
            }
        }
        enum CodingKeys: String, CodingKey {
            case queryCredits = "query_credits", scanCredits = "scan_credits"
            case plan, usageLimits = "usage_limits"
        }
    }

    public func infos() async throws -> Infos {
        let o = try await appeler("/api-info", [:], ReponseInfos.self)
        return Infos(
            creditsRecherche: o.queryCredits ?? 0,
            creditsScan: o.scanCredits ?? 0,
            plafondRecherche: o.usageLimits?.queryCredits ?? 0,
            plafondScan: o.usageLimits?.scanCredits ?? 0,
            plan: o.plan ?? "")
    }

    // MARK: - Payant

    /// Récupère jusqu'à `limite` adresses, par pages de 100.
    ///
    /// ⚠️ La règle de facturation exacte n'est **pas** établie. « Une page
    /// entamée = un crédit » était écrit ici et c'est faux : une recherche
    /// rendant 8 résultats n'a rien débité (44 → 44, vérifié par l'API puis par
    /// le CLI). `creditsAttendus` est donc un **plafond annoncé**, pas un prix.
    /// Ne pas réinventer la règle sans la mesurer.
    struct ReponseRecherche: Decodable {
        let matches: [Resultat]
        struct Resultat: Decodable {
            let ipStr: String?
            let port: Int?
            let isp: String?
            let location: Lieu?
            struct Lieu: Decodable {
                let countryCode: String?
                enum CodingKeys: String, CodingKey { case countryCode = "country_code" }
            }
            enum CodingKeys: String, CodingKey {
                case ipStr = "ip_str", port, isp, location
            }
        }
    }

    public func chercher(_ requete: String, limite: Int) async throws -> [Cible] {
        var cibles: [Cible] = []
        let pages = max(1, Int(ceil(Double(min(limite, 1000)) / 100.0)))

        for page in 1...pages {
            let o = try await appeler("/shodan/host/search",
                                      ["query": requete, "page": String(page)],
                                      ReponseRecherche.self)
            if o.matches.isEmpty { break }

            for r in o.matches {
                guard let ip = r.ipStr else { continue }
                cibles.append(Cible(
                    ip: ip,
                    port: r.port ?? 25565,
                    hebergeur: r.isp ?? "",
                    pays: (r.location?.countryCode ?? "").uppercased()))
                if cibles.count >= limite { return cibles }
            }
            if o.matches.count < 100 { break }
        }
        return cibles
    }

    /// Coût annoncé avant de lancer la recherche.
    public static func creditsAttendus(total: Int, limite: Int) -> Int {
        let recuperes = min(total, limite)
        return max(0, (recuperes + 99) / 100)
    }
}

// MARK: - Construction de la requête

/// Traduit les filtres tapés par l'utilisateur en requête Shodan.
///
/// Reprend exactement les règles du moteur Python : un jeton contenant un
/// chiffre est une version, deux lettres un pays, un nombre seul la taille de
/// la liste, `tous` le maximum, et tout ce qui contient « : » passe tel quel.
public enum Requete {

    public static let limiteParDefaut = 300
    public static let limiteMaximale = 1000

    public static func construire(_ filtres: String) -> (requete: String, limite: Int) {
        var parties = ["product:\"Minecraft\""]
        var limite = limiteParDefaut
        // Un port explicite tapé par l'utilisateur l'emporte sur celui qu'on
        // force plus bas : `port:25566` est un serveur Java sur un port
        // alternatif, que le ping joint parfaitement, et l'écraser rendrait la
        // requête vide.
        var portImpose = true

        for jeton in decouper(filtres) {
            let bas = jeton.lowercased()
            if bas == "tous" || bas == "all" {
                limite = limiteMaximale
            } else if estEntier(jeton) {
                limite = Swift.max(1, Swift.min(limiteMaximale, Int(jeton) ?? limiteParDefaut))
            } else if let sep = jeton.firstIndex(of: ":") {
                let cle = String(jeton[jeton.startIndex..<sep])
                let val = String(jeton[jeton.index(after: sep)...])
                if cle.lowercased() == "port" { portImpose = false }
                parties.append(val.contains(" ") ? "\(cle):\"\(val)\"" : jeton)
            } else if jeton.count == 2 && jeton.allSatisfy({ $0.isLetter }) {
                parties.append("country:\"\(jeton.uppercased())\"")
            } else if jeton.contains(where: { $0.isNumber }) {
                parties.append("version:\"\(jeton)\"")
            } else {
                parties.append("\"\(jeton)\"")
            }
        }
        // Le port Java, dans TOUTE requête qui n'en désigne pas un autre.
        //
        // Le ping parle le Server List Ping de Java Edition, en TCP. Bedrock
        // répond en RakNet sur l'UDP 19132 : rien dans cette app ne sait lui
        // parler, et rien ne le saura tant qu'il n'y aura pas d'UDP ici. Sans
        // ce filtre, `product:"Minecraft"` ramenait des serveurs injoignables
        // par construction, qui entraient dans la liste, ne répondaient jamais,
        // et gonflaient à vie le compteur « silencieux » de l'en-tête — où plus
        // rien ne les distinguait d'un serveur Java hors ligne.
        if portImpose { parties.append("port:25565") }
        return (parties.joined(separator: " "), limite)
    }

    static func estEntier(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Découpage à la `shlex` : les guillemets permettent d'écrire une valeur
    /// à espaces, comme `version:"26.3 Snapshot 3"`.
    static func decouper(_ texte: String) -> [String] {
        var jetons: [String] = []
        var courant = ""
        var guillemet: Character? = nil
        var commence = false

        for c in texte {
            if let g = guillemet {
                if c == g { guillemet = nil } else { courant.append(c) }
            } else if c == "\"" || c == "'" {
                guillemet = c
                commence = true
            } else if c.isWhitespace {
                if commence { jetons.append(courant); courant = ""; commence = false }
            } else {
                courant.append(c)
                commence = true
            }
        }
        if commence { jetons.append(courant) }
        return jetons
    }
}
