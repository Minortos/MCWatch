// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Accès aux fichiers de MC Watch.
///
/// L'emplacement n'est plus construit à la main depuis le dossier de départ :
/// il est **demandé au système**. C'est ce qui rend le même code correct des
/// deux côtés du bac à sable — `.applicationSupportDirectory` rend
/// `~/Library/Application Support` hors bac à sable, et le conteneur de l'app
/// dedans, sans que rien ici ait à savoir lequel des deux s'applique.
///
/// C'est aussi la réponse à « où se rangent les fichiers chez quelqu'un qui
/// installe l'app » : nulle part où l'app décide. macOS lui assigne
/// `~/Library/Containers/com.minortos.mcwatch.app/Data` et l'y enferme.
/// Rien à créer, rien à nettoyer, aucun installeur.
public struct Stockage: Sendable {

    public let racine: URL

    /// Le dossier de données, créé à la demande.
    ///
    /// Le repli sur un chemin construit à la main ne sert qu'à ne jamais rendre
    /// d'URL invalide : en pratique `url(for:)` n'échoue pas pour ce domaine.
    public static var dossierModerne: URL {
        let f = FileManager.default
        let base = (try? f.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? f.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MC Watch", isDirectory: true)
    }

    public static var racineParDefaut: URL { dossierModerne }

    public init(racine: URL? = nil) {
        self.racine = racine ?? Stockage.racineParDefaut
    }

    var dossierProfils: URL { racine.appendingPathComponent("profils", isDirectory: true) }

    /// Dossier d'un profil, pour poser une veille dessus.
    public func dossierProfil(_ slug: String) -> URL {
        dossierProfils.appendingPathComponent(slug, isDirectory: true)
    }

    // MARK: - Lecture

    /// Un nom de profil sûr, ou `nil`.
    ///
    /// Un slug ne sert pas qu'à nommer : il DEVIENT un chemin de fichier, à
    /// onze endroits de ce fichier, dont un `removeItem`. Or `appendingPathComponent`
    /// ne protège rien — il compose ce qu'on lui donne, et « ../.. » remonte
    /// hors du dossier des profils. Vérifié : `profils/../..` se résout en
    /// grand-parent, et `a/../../b` sort tout autant.
    ///
    /// Les slugs que l'app fabrique elle-même sont inoffensifs : `Slug.depuis`
    /// ne rend que des minuscules ASCII, des chiffres et des tirets. Le danger
    /// vient de ceux qu'elle LIT — le fichier « actif » est du texte ordinaire
    /// dans le conteneur, et rien ne garantit qui l'a écrit.
    ///
    /// Le bac à sable borne déjà les dégâts au conteneur, et poser ce fichier
    /// suppose d'y avoir accès : ce n'est donc pas une brèche ouverte sur le
    /// réseau. Mais faire du confinement la SEULE barrière devant un effacement
    /// récursif, c'est se reposer sur une couche qu'on ne contrôle pas. Elle
    /// n'est plus la seule.
    static func slugSur(_ brut: String) -> String? {
        guard !brut.isEmpty, brut.count <= 128 else { return nil }
        let permis = brut.allSatisfy { c in
            (c.isASCII && (c.isLowercase || c.isNumber)) || c == "-"
        }
        return permis ? brut : nil
    }

    public func slugActif() -> String? {
        let f = racine.appendingPathComponent("actif")
        guard let brut = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let nettoye = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        // Un nom refusé n'est pas une erreur à remonter : on retombe sur le
        // premier profil réellement présent, comme pour un fichier absent.
        guard let slug = Stockage.slugSur(nettoye) else { return listerSlugs().first }
        guard !slug.isEmpty,
              FileManager.default.fileExists(atPath: dossierProfils
                  .appendingPathComponent(slug).path) else { return listerSlugs().first }
        return slug
    }

    public func listerSlugs() -> [String] {
        let contenu = (try? FileManager.default.contentsOfDirectory(
            atPath: dossierProfils.path)) ?? []
        return contenu.filter { nom in
            // La liste surveillée est un profil comme les autres sur le disque,
            // mais ce n'est pas une RECHERCHE : elle n'a rien à faire dans le
            // sélecteur des recherches enregistrées. C'est la seule différence
            // entre elle et les autres, et elle tient en cette ligne.
            guard !Surveillance.estReserve(nom) else { return false }
            var dossier: ObjCBool = false
            let existe = FileManager.default.fileExists(
                atPath: dossierProfils.appendingPathComponent(nom).path,
                isDirectory: &dossier)
            return existe && dossier.boolValue
        }.sorted()
    }

    public func texte(_ slug: String, _ fichier: String) -> String {
        let f = dossierProfils.appendingPathComponent(slug).appendingPathComponent(fichier)
        return (try? String(contentsOf: f, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func historique(_ slug: String) -> Historique {
        let f = dossierProfils.appendingPathComponent(slug)
            .appendingPathComponent("historique.json")
        guard let d = try? Data(contentsOf: f),
              let h = try? JSONDecoder().decode(Historique.self, from: d)
        else { return Historique() }
        return h
    }

    /// Lit `liste.tsv` : ip, port, hébergeur, pays. Les champs vides ne sont
    /// pas retirés — ce sont des positions, et un hébergeur inconnu ferait
    /// sinon glisser le pays dans sa colonne.
    public func cibles(_ slug: String) -> [Cible] {
        let f = dossierProfils.appendingPathComponent(slug)
            .appendingPathComponent("liste.tsv")
        guard let brut = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        return brut.split(separator: "\n", omittingEmptySubsequences: true).compactMap { ligne in
            let colonnes = ligne.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let ip = colonnes.first, !ip.isEmpty else { return nil }
            return Cible(
                ip: ip,
                port: colonnes.count > 1 ? (Int(colonnes[1]) ?? 25565) : 25565,
                hebergeur: colonnes.count > 2 ? colonnes[2] : "",
                pays: colonnes.count > 3 ? String(colonnes[3].prefix(2)).uppercased() : "")
        }
    }

    /// Date du dernier relevé écrit, sans rien décoder. Permet à l'app de savoir
    /// si l'agent a travaillé depuis sa dernière lecture, et d'éviter de
    /// redécoder un historique inchangé.
    public func dateHistorique(_ slug: String) -> Date? {
        let f = dossierProfils.appendingPathComponent(slug)
            .appendingPathComponent("historique.json")
        return (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate]
            as? Date
    }

    public func profil(_ slug: String) -> Profil {
        Profil(slug: slug,
               recherche: texte(slug, "recherche.txt"),
               requete: texte(slug, "requete.txt"),
               cibles: cibles(slug),
               historique: historique(slug))
    }

    static let cleFiltres = "filtres"
    static let cleSurveillance = "surveillance"
    /// Le compteur de réveils de l'agent. Dans `UserDefaults` et non dans un
    /// fichier : il change à chaque déclenchement, et c'est exactement ce que
    /// les préférences savent faire sans qu'on écrive une ligne d'entrée-sortie.
    static let cleReveils = "reveils"

    /// Les filtres du classement sont des **préférences d'interface** : leur
    /// place est `UserDefaults`, pas un fichier JSON écrit à la main. Celui-ci
    /// était un héritage du moteur Python, qui devait pouvoir les relire depuis
    /// le terminal — raison disparue avec Python.
    ///
    /// Reprise unique de l'ancien fichier, qui est ensuite renommé pour ne plus
    /// passer pour la source de vérité, tout en restant récupérable.
    public func filtres() -> Filtres {
        if let d = UserDefaults.standard.data(forKey: Stockage.cleFiltres),
           let v = try? JSONDecoder().decode(Filtres.self, from: d) { return v }

        let ancien = racine.appendingPathComponent("filtres.json")
        guard let d = try? Data(contentsOf: ancien),
              let v = try? JSONDecoder().decode(Filtres.self, from: d)
        else { return Filtres() }
        // Ne renommer l'ancien fichier que si la reprise a réellement abouti.
        // Dans l'autre ordre, une écriture ratée suivie d'un renommage réussi
        // perdait les filtres pour de bon : plus rien nulle part.
        guard (try? ecrireFiltres(v)) != nil else { return v }
        try? FileManager.default.moveItem(
            at: ancien, to: racine.appendingPathComponent("filtres.json.repris"))
        return v
    }

    public func verdicts() -> [String: Verdict] {
        let f = racine.appendingPathComponent("verdicts.json")
        guard let d = try? Data(contentsOf: f),
              let v = try? JSONDecoder().decode([String: Verdict].self, from: d)
        else { return [:] }
        return v
    }

    /// Le dépôt sur fichiers n'a pas de moteur de requête : il charge et
    /// filtre, en appliquant **exactement la même règle** que la base.
    public func serveursFiltres(_ slug: String, _ f: Filtres) -> [Serveur] {
        {
            let h = Selection.Hebergement()
            return historique(slug).serveurs.values.filter {
                Selection.retenuParLeDepot($0, f, h)
            }
        }()
    }

    public func meta(_ slug: String) -> MetaHistorique { historique(slug).meta }
    public func compterCibles(_ slug: String) -> Int { cibles(slug).count }
    public func compterRepondants(_ slug: String) -> Int {
        let h = historique(slug)
        return h.serveurs.values.count { $0.dernierVu != nil && $0.dernierVu == h.meta.dernier }
    }

    public func credits() -> Credits {
        let f = racine.appendingPathComponent("credits.json")
        guard let d = try? Data(contentsOf: f),
              let v = try? JSONDecoder().decode(Credits.self, from: d)
        else { return Credits() }
        return v
    }
}

// MARK: - Écriture

extension Stockage {

    /// Écrit par fichier temporaire puis renommage : une coupure ne peut pas
    /// laisser un historique à moitié écrit. C'est ce que fait déjà Python.
    func poser(_ donnees: Data, _ destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let tmp = destination.appendingPathExtension("tmp")
        try donnees.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
    }

    func encoder<T: Encodable>(_ valeur: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return try e.encode(valeur)
    }

    public func ecrireHistorique(_ slug: String, _ h: Historique) throws {
        try poser(try encoder(h), dossierProfils.appendingPathComponent(slug)
            .appendingPathComponent("historique.json"))
    }

    /// Ici le fichier est un tout : il faut le relire, en retirer la clé, le
    /// réécrire. La base, elle, atteint la ligne directement — c'est la même
    /// opération, au prix près.
    public func oublierServeur(_ slug: String, _ adresse: String) throws {
        var h = historique(slug)
        guard h.serveurs.removeValue(forKey: adresse) != nil else { return }
        try ecrireHistorique(slug, h)
    }

    public func reglagesSurveillance() -> ReglagesSurveillance {
        guard let d = UserDefaults.standard.data(forKey: Stockage.cleSurveillance),
              let r = try? JSONDecoder().decode(ReglagesSurveillance.self, from: d)
        else { return ReglagesSurveillance() }
        return r.valides
    }

    public func ecrireReglagesSurveillance(_ r: ReglagesSurveillance) throws {
        UserDefaults.standard.set(try encoder(r), forKey: Stockage.cleSurveillance)
    }

    /// Le nombre de réveils de l'agent depuis toujours, incrémenté puis rendu.
    ///
    /// C'est ce compteur, et non une horloge, qui décide quelle liste travaille
    /// à ce réveil-ci. Une horloge dériverait, se décalerait au réveil du Mac,
    /// et ferait manquer des tours ; un compteur ne peut que suivre les
    /// déclenchements réels de launchd.
    public func prochainReveil() -> Int {
        let n = UserDefaults.standard.integer(forKey: Stockage.cleReveils) &+ 1
        UserDefaults.standard.set(n, forKey: Stockage.cleReveils)
        return n
    }

    public func ecrireFiltres(_ f: Filtres) throws {
        UserDefaults.standard.set(try encoder(f), forKey: Stockage.cleFiltres)
    }

    public func ecrireVerdicts(_ v: [String: Verdict]) throws {
        try poser(try encoder(v), racine.appendingPathComponent("verdicts.json"))
    }

    public func ecrireCredits(_ c: Credits) throws {
        try poser(try encoder(c), racine.appendingPathComponent("credits.json"))
    }

    public func ecrireTexte(_ slug: String, _ fichier: String, _ contenu: String) throws {
        try poser(Data(contenu.utf8), dossierProfils.appendingPathComponent(slug)
            .appendingPathComponent(fichier))
    }

    /// `liste.tsv` : ip, port, hébergeur, pays — le format que lit déjà mcping.
    public func ecrireCibles(_ slug: String, _ cibles: [Cible]) throws {
        let lignes = cibles.map { "\($0.ip)\t\($0.port)\t\($0.hebergeur)\t\($0.pays)" }
        try poser(Data((lignes.joined(separator: "\n") + "\n").utf8),
                  dossierProfils.appendingPathComponent(slug)
                      .appendingPathComponent("liste.tsv"))
    }

    public func definirActif(_ slug: String) throws {
        try poser(Data((slug + "\n").utf8), racine.appendingPathComponent("actif"))
    }

    /// ⚠️ La seule opération de ce fichier qui EFFACE, et récursivement. Elle
    /// refuse tout nom qui ne soit pas un slug — voir `slugSur`.
    public func supprimerProfil(_ slug: String) throws {
        guard Stockage.slugSur(slug) != nil else { return }
        try FileManager.default.removeItem(at: dossierProfils.appendingPathComponent(slug))
    }

    /// Journal des relevés, avec la même rotation que Python : au-delà de
    /// 400 Ko on ne garde que les 500 dernières lignes.
    ///
    /// Deux processus y écrivent — l'app et le scanner — et rien ne les
    /// empêche de tomber en même temps : un relevé manuel peut coïncider avec
    /// un déclenchement de l'agent. D'où les deux précautions ci-dessous, qui
    /// étaient les seules écritures du projet à échapper à la règle atomique.
    /// Efface le chemin du dossier personnel de ce qui va être écrit.
    ///
    /// Une erreur de fichier ne se contente pas de dire ce qui a échoué : son
    /// `userInfo` porte le chemin complet, et ce chemin commence par
    /// `/Users/<compte>`. Interpolée dans le journal, elle y dépose donc le nom
    /// du compte macOS de l'utilisateur — durablement, dans un fichier que le
    /// menu Aide invite justement à ouvrir.
    ///
    /// Ce fichier est exactement celui qu'on joint à un rapport de bogue. Pour
    /// un projet publié sous pseudonyme, c'est l'endroit le plus dangereux où
    /// laisser traîner un nom réel — et ce serait d'abord celui de l'auteur.
    ///
    /// On assainit ICI plutôt qu'à chaque appel : il y a cinq endroits qui
    /// journalisent une erreur, il y en aura six, et celui qui écrira le
    /// sixième n'y pensera pas. Un point de passage unique n'a pas besoin qu'on
    /// y pense.
    static func sansCheminPersonnel(_ message: String) -> String {
        var sortie = message
        // Le plus long d'abord : en bac à sable, le « dossier personnel » est
        // le conteneur, dont le chemin CONTIENT déjà /Users/<compte>.
        for prefixe in [NSHomeDirectory(), "/Users/" + NSUserName()] where !prefixe.isEmpty {
            sortie = sortie.replacingOccurrences(of: prefixe, with: "~")
        }
        return sortie
    }

    public func journal(_ brut: String, horodatage: String) {
        let message = Stockage.sansCheminPersonnel(brut)
        let f = racine.appendingPathComponent("journal.log")
        try? FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)

        // Rotation par temporaire + renommage, comme tout le reste : une
        // coupure au mauvais moment ne peut pas laisser un journal tronqué.
        if let taille = try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int,
           taille > 400_000,
           let contenu = try? String(contentsOf: f, encoding: .utf8) {
            let fin = contenu.split(separator: "\n", omittingEmptySubsequences: false).suffix(500)
            try? poser(Data(fin.joined(separator: "\n").utf8), f)
        }

        // `O_APPEND` : le noyau se place en fin de fichier et écrit sans qu'un
        // autre processus puisse s'intercaler. `seekToEnd()` suivi d'un `write`
        // laissait au contraire deux journaux concurrents calculer la même
        // position et s'écraser l'un l'autre.
        let ligne = Data("\(horodatage)  \(message)\n".utf8)
        let fd = open(f.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        ligne.withUnsafeBytes { tampon in
            _ = write(fd, tampon.baseAddress, tampon.count)
        }
    }
}
