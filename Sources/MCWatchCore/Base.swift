// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData

// Le même stockage que `Stockage`, mais confié à SwiftData plutôt qu'à des
// fichiers JSON écrits à la main.
//
// Les deux implémentations coexistent volontairement le temps de la bascule :
// `mcwatch-verif --comparer` les fait tourner côte à côte sur les mêmes données
// et vérifie qu'elles rendent exactement la même chose. On ne bascule que
// lorsque c'est prouvé — la même méthode que pour la migration depuis Python.
//
// ⚠️ Les types du domaine (`Serveur`, `Cible`, `Verdict`…) restent des
// **structures**. Les transformer en `@Model` ferait d'eux des références et
// changerait la sémantique dans `Selection`, `Tour.fusionner`, le tri de la
// table, `Transferable` — bien au-delà de la persistance. La base a donc ses
// propres entités, et cette couche traduit entre les deux.

// MARK: - Ce que l'app attend d'un dépôt

/// La surface commune aux deux implémentations, pour que la bascule soit une
/// seule ligne à changer et que le harnais puisse les faire tourner côte à côte.
public protocol Depot: Sendable {
    func slugActif() -> String?
    func listerSlugs() -> [String]
    func texte(_ slug: String, _ fichier: String) -> String
    func historique(_ slug: String) -> Historique
    func cibles(_ slug: String) -> [Cible]
    func dateHistorique(_ slug: String) -> Date?
    func profil(_ slug: String) -> Profil
    func filtres() -> Filtres
    func verdicts() -> [String: Verdict]
    func credits() -> Credits
    func ecrireHistorique(_ slug: String, _ h: Historique) throws
    func ecrireFiltres(_ f: Filtres) throws
    func reglagesSurveillance() -> ReglagesSurveillance
    func ecrireReglagesSurveillance(_ r: ReglagesSurveillance) throws
    func prochainReveil() -> Int
    func ecrireVerdicts(_ v: [String: Verdict]) throws
    func ecrireCredits(_ c: Credits) throws
    func ecrireTexte(_ slug: String, _ fichier: String, _ contenu: String) throws
    func ecrireCibles(_ slug: String, _ cibles: [Cible]) throws
    func definirActif(_ slug: String) throws
    func supprimerProfil(_ slug: String) throws

    /// Retire un serveur de l'historique d'une liste.
    ///
    /// Cesser de surveiller une adresse ne suffisait pas à la faire disparaître :
    /// `ecrireCibles` réécrit la liste des adresses à interroger, mais
    /// l'historique — ce qu'on a VU — n'était pas touché. Or c'est lui que
    /// l'app lit pour épingler les serveurs surveillés au tableau. Le serveur
    /// retiré y restait donc épinglé, pour toujours, sans plus aucune ligne
    /// dans les réglages pour le retirer une seconde fois.
    ///
    /// Sans effet si l'adresse n'y est pas — retirer deux fois n'est pas une
    /// erreur.
    func oublierServeur(_ slug: String, _ adresse: String) throws
    func journal(_ message: String, horodatage: String)
    /// Ce qu'il faut surveiller pour savoir que l'autre processus a écrit.
    var cibleDeVeille: [URL] { get }

    /// Les serveurs d'une liste **déjà dégrossis** par les critères que le
    /// dépôt sait appliquer lui-même.
    ///
    /// Ne couvre que les critères chiffrés et booléens : ils portent sur des
    /// colonnes, donc une base peut les traiter sans rien charger. Les verdicts
    /// (une autre table), la recherche texte et l'ordre restent au-dessus, en
    /// Swift, pour que le comportement soit identique au caractère près.
    ///
    /// Sur les données réelles : 2052 serveurs chargés puis filtrés en mémoire
    /// deviennent ~514 lus depuis la base. C'est la conversion qui rétrécit.
    func serveursFiltres(_ slug: String, _ f: Filtres) -> [Serveur]

    /// Les compteurs de l'en-tête, sans charger la liste pour autant.
    /// Un comptage en base coûte 0,1 ms là où charger 2052 serveurs pour les
    /// dénombrer en coûtait 231.
    func meta(_ slug: String) -> MetaHistorique
    func compterCibles(_ slug: String) -> Int
    /// Ceux qui ont répondu **au dernier tour**, pas tout l'historique.
    func compterRepondants(_ slug: String) -> Int
}

extension Stockage: Depot {
    /// Les dossiers : l'écriture est atomique, donc l'inode change et c'est la
    /// **création d'entrée** dans le dossier qui réveille.
    public var cibleDeVeille: [URL] {
        [dossierProfil(slugActif() ?? ""), racine]
    }
}

// MARK: - Les entités persistées

@Model public final class DProfil {
    @Attribute(.unique) public var slug: String
    public var recherche: String
    public var requete: String
    public var tours: Int
    public var debut: String?
    public var dernier: String?
    public var actif: Bool
    /// Remplace la date de modification du fichier, dont l'app se sert pour
    /// savoir si l'agent a travaillé depuis sa dernière lecture.
    public var modifie: Date
    @Relationship(deleteRule: .cascade, inverse: \DServeur.profil)
    public var serveurs: [DServeur] = []
    @Relationship(deleteRule: .cascade, inverse: \DCible.profil)
    public var cibles: [DCible] = []

    public init(slug: String, recherche: String = "", requete: String = "", tours: Int = 0,
                debut: String? = nil, dernier: String? = nil, actif: Bool = false,
                modifie: Date = Date()) {
        self.slug = slug; self.recherche = recherche; self.requete = requete
        self.tours = tours; self.debut = debut; self.dernier = dernier
        self.actif = actif; self.modifie = modifie
    }
}

@Model public final class DServeur {
    public var adresse: String
    public var ip: String; public var port: Int
    public var maxVu: Int; public var picAt: String?
    public var toursVus: Int; public var toursPeuples: Int
    public var dernierOnline: Int; public var dernierVu: String?
    public var slots: Int; public var version: String; public var motd: String
    public var hebergeur: String; public var pays: String
    public var whitelistAnnoncee: Bool; public var proxy: Bool
    public var motdPromotionnel: Bool; public var motdParDefaut: Bool
    public var profil: DProfil?

    public init(_ s: Serveur) {
        adresse = s.adresse; ip = s.ip; port = s.port; maxVu = s.maxVu; picAt = s.picAt
        toursVus = s.toursVus; toursPeuples = s.toursPeuples
        dernierOnline = s.dernierOnline; dernierVu = s.dernierVu; slots = s.slots
        version = s.version; motd = s.motd; hebergeur = s.hebergeur; pays = s.pays
        whitelistAnnoncee = s.whitelistAnnoncee; proxy = s.proxy
        motdPromotionnel = s.motdPromotionnel; motdParDefaut = s.motdParDefaut
    }

    public var valeur: Serveur {
        Serveur(ip: ip, port: port, maxVu: maxVu, picAt: picAt, toursVus: toursVus,
                toursPeuples: toursPeuples, dernierOnline: dernierOnline, dernierVu: dernierVu,
                slots: slots, version: version, motd: motd, hebergeur: hebergeur, pays: pays,
                whitelistAnnoncee: whitelistAnnoncee, proxy: proxy,
                motdPromotionnel: motdPromotionnel, motdParDefaut: motdParDefaut)
    }
}

@Model public final class DCible {
    public var ip: String; public var port: Int
    public var hebergeur: String; public var pays: String
    /// L'ordre du `liste.tsv` : il vient de Shodan et n'est pas arbitraire.
    public var rang: Int
    public var profil: DProfil?

    public init(_ c: Cible, rang: Int) {
        ip = c.ip; port = c.port; hebergeur = c.hebergeur; pays = c.pays; self.rang = rang
    }
    public var valeur: Cible { Cible(ip: ip, port: port, hebergeur: hebergeur, pays: pays) }
}

/// À la racine, hors profil : un serveur reste le même d'une recherche à l'autre.
@Model public final class DVerdict {
    @Attribute(.unique) public var adresse: String
    public var marque: String
    public var date: String
    public init(adresse: String, marque: String, date: String) {
        self.adresse = adresse; self.marque = marque; self.date = date
    }
}

@Model public final class DCredits {
    public var solde: Int?; public var vu: String?; public var jourReinit: Int?
    public var reinits: [String]; public var plafond: Int
    public var plan: String
    public init(_ c: Credits) {
        solde = c.solde; vu = c.vu; jourReinit = c.jourReinit; reinits = c.reinits
        plafond = c.plafond; plan = c.plan
    }
    public var valeur: Credits {
        var c = Credits()
        c.solde = solde; c.vu = vu; c.jourReinit = jourReinit; c.reinits = reinits
        c.plafond = plafond; c.plan = plan
        return c
    }
}

// MARK: - La version du schéma

/// **Le point d'ancrage du schéma, posé avant la première publication.**
///
/// SwiftData reconnaît un magasin à la forme de ses entités et à un numéro de
/// version. Tant que l'app n'est pas distribuée, ce numéro ne sert à rien : le
/// seul magasin qui existe est celui de l'auteur, et rien n'empêche de le
/// refaire. Le jour où quelqu'un l'installe, la propriété s'inverse — tout
/// changement d'entité doit être décrit comme une étape de migration, et une
/// étape se décrit **d'une version vers une autre**. Sans version de départ
/// déclarée, il n'y a pas de « depuis » à nommer, et il ne reste qu'à effacer
/// la base de l'utilisateur : son historique, ses pics et ses verdicts d'essai,
/// c'est-à-dire tout ce que cette app existe pour ne pas reperdre.
///
/// C'est la seule chose de ce fichier qu'on ne pourra pas rattraper après coup,
/// et les suites envisagées y touchent toutes : un port UDP pour Bedrock ajoute
/// un champ, la fusion des listes supprime la notion de profil.
///
/// ⚠️ `Schema.Version(1, 0, 0)` n'est pas un choix : c'est **exactement** la
/// valeur que `Schema` prenait par défaut jusqu'ici, quand le conteneur était
/// construit à partir des types seuls. Déclarer V1 ne change donc rien au
/// magasin déjà écrit — vérifié sur une copie de la base réelle (2053 serveurs,
/// 1000 cibles, 173 verdicts, somme des pics 23530) plutôt que supposé.
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [DProfil.self, DServeur.self, DCible.self, DVerdict.self, DCredits.self]
    }
}

/// Le plan de migration : une version, aucune étape.
///
/// C'est très exactement ce qu'un plan doit contenir avant qu'une deuxième
/// version n'existe. Le déclarer maintenant n'ajoute aucun comportement — il
/// pose la ligne où la première étape viendra s'écrire, dans un fichier où la
/// construction du conteneur n'aura plus à changer.
public enum PlanDeMigration: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

// MARK: - Le dépôt

public final class Base: Depot, @unchecked Sendable {

    public let fichier: URL
    private let conteneur: ModelContainer
    /// Les préférences d'interface et le journal restent là où ils sont : le
    /// premier est déjà dans `UserDefaults`, le second est un fichier en ajout
    /// séquentiel que deux processus alimentent — SQLite n'y apporterait rien.
    private let fichiers: Stockage

    /// ⚠️ **Surveiller le `-wal`, pas le `.store`.** En mode WAL les écritures
    /// vont d'abord dans le journal ; le fichier principal n'est touché qu'au
    /// report. Mesuré : une veille sur le `.store` ou sur le dossier ne se
    /// déclenche **jamais**, une veille sur le `-wal` se déclenche à chaque fois.
    /// Elle est en revanche bavarde — 26 réveils pour 4 enregistrements — donc
    /// l'appelant doit amortir avant de recharger.
    public var cibleDeVeille: [URL] {
        [URL(fileURLWithPath: fichier.path + "-wal")]
    }

    public static var fichierParDefaut: URL {
        Stockage.dossierModerne.appendingPathComponent("mcwatch.store")
    }

    public init(fichier: URL? = nil) throws {
        self.fichier = fichier ?? Base.fichierParDefaut
        fichiers = Stockage()
        try FileManager.default.createDirectory(
            at: self.fichier.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Le schéma passe par `SchemaV1` et non plus par la liste des types :
        // c'est la même liste, mais nommée et numérotée, donc citable par une
        // future étape de migration. Voir `SchemaV1`.
        conteneur = try ModelContainer(
            for: Schema(versionedSchema: SchemaV1.self),
            migrationPlan: PlanDeMigration.self,
            configurations: ModelConfiguration(url: self.fichier))
    }

    /// Un contexte neuf par opération. Vérifié : deux processus voient les
    /// écritures l'un de l'autre immédiatement, et 300 écritures concurrentes
    /// n'en perdent aucune.
    private func ctx() -> ModelContext { ModelContext(conteneur) }

    private func profil(_ slug: String, _ c: ModelContext) -> DProfil? {
        var d = FetchDescriptor<DProfil>(predicate: #Predicate { $0.slug == slug })
        d.fetchLimit = 1
        return (try? c.fetch(d))?.first
    }

    // MARK: Lecture

    public func slugActif() -> String? {
        let c = ctx()
        var d = FetchDescriptor<DProfil>(predicate: #Predicate { $0.actif })
        d.fetchLimit = 1
        if let p = (try? c.fetch(d))?.first { return p.slug }
        return listerSlugs().first
    }

    /// Le slug réservé en est écarté, exactement comme dans `Stockage` : les
    /// deux dépôts doivent rendre la même liste, c'est ce que vérifient les
    /// tests d'intégration.
    public func listerSlugs() -> [String] {
        let d = FetchDescriptor<DProfil>(sortBy: [SortDescriptor(\.slug)])
        return ((try? ctx().fetch(d)) ?? []).map(\.slug)
            .filter { !Surveillance.estReserve($0) }
    }

    public func texte(_ slug: String, _ fichier: String) -> String {
        let c = ctx()
        guard let p = profil(slug, c) else { return "" }
        switch fichier {
        case "recherche.txt": return p.recherche
        case "requete.txt":   return p.requete
        default:              return ""
        }
    }

    public func historique(_ slug: String) -> Historique {
        let c = ctx()
        guard let p = profil(slug, c) else { return Historique() }
        var serveurs: [String: Serveur] = [:]
        serveurs.reserveCapacity(p.serveurs.count)
        for s in p.serveurs { serveurs[s.adresse] = s.valeur }
        return Historique(meta: MetaHistorique(tours: p.tours, debut: p.debut, dernier: p.dernier),
                          serveurs: serveurs)
    }

    public func cibles(_ slug: String) -> [Cible] {
        let c = ctx()
        guard let p = profil(slug, c) else { return [] }
        return p.cibles.sorted { $0.rang < $1.rang }.map(\.valeur)
    }

    public func dateHistorique(_ slug: String) -> Date? {
        let c = ctx()
        return profil(slug, c)?.modifie
    }

    public func profil(_ slug: String) -> Profil {
        Profil(slug: slug, recherche: texte(slug, "recherche.txt"),
               requete: texte(slug, "requete.txt"), cibles: cibles(slug),
               historique: historique(slug))
    }

    public func verdicts() -> [String: Verdict] {
        var sortie: [String: Verdict] = [:]
        for v in (try? ctx().fetch(FetchDescriptor<DVerdict>())) ?? [] {
            guard let m = Marque(rawValue: v.marque) else { continue }
            sortie[v.adresse] = Verdict(verdict: m, date: v.date)
        }
        return sortie
    }

    public func credits() -> Credits {
        ((try? ctx().fetch(FetchDescriptor<DCredits>()))?.first?.valeur) ?? Credits()
    }

    /// SQLite **dégrossit**, Swift **tranche**.
    ///
    /// Le prédicat ne porte que sur les critères les plus sélectifs et les plus
    /// simples : le macro `#Predicate` renonce à typer une expression qui les
    /// couvrirait tous (« unable to type-check this expression in reasonable
    /// time »), exactement comme le constructeur de colonnes plus haut dans
    /// l'app. Inutile d'insister — c'est la bonne architecture de toute façon.
    ///
    /// La règle **qui fait autorité** reste `Selection.retenuParLeDepot`,
    /// appliquée ensuite aux lignes rendues. Le prédicat n'a donc qu'une seule
    /// obligation : ne jamais écarter une ligne que la règle aurait gardée.
    /// C'est ce qui rend les deux dépôts identiques **par construction**, et
    /// non par la vigilance de celui qui les maintient.
    public func serveursFiltres(_ slug: String, _ f: Filtres) -> [Serveur] {
        let picMin = f.picMin
        let slotsMax = f.slotsMax > 0 ? f.slotsMax : Int.max
        let d = FetchDescriptor<DServeur>(predicate: #Predicate { s in
            s.profil?.slug == slug && s.maxVu >= picMin && s.slots <= slotsMax
        })
        // Construite UNE fois, hors du filtre : voir la note sur `retenuParLeDepot`.
        let h = Selection.Hebergement()
        return ((try? ctx().fetch(d)) ?? [])
            .map(\.valeur)
            .filter { Selection.retenuParLeDepot($0, f, h) }
    }

    public func meta(_ slug: String) -> MetaHistorique {
        let c = ctx()
        guard let p = profil(slug, c) else { return MetaHistorique() }
        return MetaHistorique(tours: p.tours, debut: p.debut, dernier: p.dernier)
    }

    public func compterCibles(_ slug: String) -> Int {
        (try? ctx().fetchCount(FetchDescriptor<DCible>(
            predicate: #Predicate { $0.profil?.slug == slug }))) ?? 0
    }

    public func compterRepondants(_ slug: String) -> Int {
        let dernier = meta(slug).dernier
        guard let dernier else { return 0 }
        return (try? ctx().fetchCount(FetchDescriptor<DServeur>(
            predicate: #Predicate { $0.profil?.slug == slug && $0.dernierVu == dernier }))) ?? 0
    }

    public func filtres() -> Filtres { fichiers.filtres() }
    public func ecrireFiltres(_ f: Filtres) throws { try fichiers.ecrireFiltres(f) }
    // Ces trois-là vivent dans les préférences du système, pas dans la base :
    // ce sont des réglages, et une table ne leur apporterait rien.
    public func reglagesSurveillance() -> ReglagesSurveillance { fichiers.reglagesSurveillance() }
    public func ecrireReglagesSurveillance(_ r: ReglagesSurveillance) throws {
        try fichiers.ecrireReglagesSurveillance(r)
    }
    public func prochainReveil() -> Int { fichiers.prochainReveil() }
    public func journal(_ message: String, horodatage: String) {
        fichiers.journal(message, horodatage: horodatage)
    }

    // MARK: Écriture

    public func ecrireHistorique(_ slug: String, _ h: Historique) throws {
        let c = ctx()
        let p = profil(slug, c) ?? {
            let n = DProfil(slug: slug); c.insert(n); return n
        }()
        p.tours = h.meta.tours; p.debut = h.meta.debut; p.dernier = h.meta.dernier
        p.modifie = Date()

        var existants: [String: DServeur] = [:]
        for s in p.serveurs { existants[s.adresse] = s }
        for (cle, v) in h.serveurs {
            if let d = existants.removeValue(forKey: cle) {
                d.maxVu = v.maxVu; d.picAt = v.picAt; d.toursVus = v.toursVus
                d.toursPeuples = v.toursPeuples; d.dernierOnline = v.dernierOnline
                d.dernierVu = v.dernierVu; d.slots = v.slots; d.version = v.version
                d.motd = v.motd; d.hebergeur = v.hebergeur; d.pays = v.pays
                d.whitelistAnnoncee = v.whitelistAnnoncee; d.proxy = v.proxy
                d.motdPromotionnel = v.motdPromotionnel; d.motdParDefaut = v.motdParDefaut
            } else {
                let d = DServeur(v); d.profil = p; c.insert(d)
            }
        }
        for orphelin in existants.values { c.delete(orphelin) }
        try c.save()
    }

    public func ecrireVerdicts(_ v: [String: Verdict]) throws {
        let c = ctx()
        var existants: [String: DVerdict] = [:]
        for d in (try? c.fetch(FetchDescriptor<DVerdict>())) ?? [] { existants[d.adresse] = d }
        for (a, verdict) in v {
            if let d = existants.removeValue(forKey: a) {
                d.marque = verdict.verdict.rawValue; d.date = verdict.date
            } else {
                c.insert(DVerdict(adresse: a, marque: verdict.verdict.rawValue, date: verdict.date))
            }
        }
        for orphelin in existants.values { c.delete(orphelin) }
        try c.save()
    }

    public func ecrireCredits(_ credits: Credits) throws {
        let c = ctx()
        for ancien in (try? c.fetch(FetchDescriptor<DCredits>())) ?? [] { c.delete(ancien) }
        c.insert(DCredits(credits))
        try c.save()
    }

    public func ecrireTexte(_ slug: String, _ fichier: String, _ contenu: String) throws {
        let c = ctx()
        let p = profil(slug, c) ?? { let n = DProfil(slug: slug); c.insert(n); return n }()
        switch fichier {
        case "recherche.txt": p.recherche = contenu
        case "requete.txt":   p.requete = contenu
        default: break
        }
        try c.save()
    }

    public func ecrireCibles(_ slug: String, _ cibles: [Cible]) throws {
        let c = ctx()
        let p = profil(slug, c) ?? { let n = DProfil(slug: slug); c.insert(n); return n }()
        for ancienne in p.cibles { c.delete(ancienne) }
        for (i, cible) in cibles.enumerated() {
            let d = DCible(cible, rang: i); d.profil = p; c.insert(d)
        }
        try c.save()
    }

    public func definirActif(_ slug: String) throws {
        let c = ctx()
        for p in (try? c.fetch(FetchDescriptor<DProfil>())) ?? [] { p.actif = (p.slug == slug) }
        try c.save()
    }

    public func supprimerProfil(_ slug: String) throws {
        let c = ctx()
        guard let p = profil(slug, c) else { return }
        c.delete(p)          // les serveurs et cibles suivent, par cascade
        try c.save()
    }

    /// Un `delete` ciblé plutôt qu'une relecture-réécriture de tout
    /// l'historique : la base sait atteindre la ligne, il n'y a aucune raison
    /// de faire remonter les autres pour les redescendre inchangées.
    public func oublierServeur(_ slug: String, _ adresse: String) throws {
        let c = ctx()
        let d = FetchDescriptor<DServeur>(
            predicate: #Predicate { $0.profil?.slug == slug && $0.adresse == adresse })
        for s in (try? c.fetch(d)) ?? [] { c.delete(s) }
        try c.save()
    }

    // MARK: - Reprise des fichiers

    /// Ouvre le dépôt, en reprenant les fichiers JSON s'il est encore vide.
    ///
    /// Les fichiers **ne sont pas supprimés** : ils restent à côté, intacts, et
    /// suffisent à revenir en arrière tant que la bascule n'a pas fait ses
    /// preuves. Ils cessent simplement d'être écrits.
    ///
    /// ⚠️ La reprise est protégée par un verrou de fichier : l'app et l'agent
    /// peuvent démarrer au même instant, et deux imports simultanés se
    /// marcheraient dessus — `ecrireCibles` efface avant de réécrire.
    /// Ouvre la base, ou retombe sur les fichiers **en le disant**.
    ///
    /// Le repli existe pour qu'une base illisible n'empêche pas l'app de
    /// démarrer. Mais depuis que les fichiers JSON ont été retirés, il rendrait
    /// un dépôt **vide** : sans cette trace, l'app afficherait une liste blanche
    /// sans que rien n'explique pourquoi. C'est exactement le mode de panne qui
    /// avait rendu l'arrêt de la surveillance si long à diagnostiquer.
    public static func ouvrirOuFichiers() -> any Depot {
        do { return try ouvrir() }
        catch {
            let f = Stockage()
            // `localizedDescription` et non l'erreur entière : Console est lisible
            // par tout le monde, et un `userInfo` de fichier y déposerait le
            // chemin du dossier personnel, donc le nom du compte.
            NSLog("MC Watch: database unreadable, falling back to files — %@",
                  error.localizedDescription)
            f.journal("⚠︎ database unreadable, falling back to files: \(error.localizedDescription)",
                      horodatage: Tour.horodatage())
            return f
        }
    }

    public static func ouvrir() throws -> Base {
        let b = try Base()
        let verrou = open(b.fichier.path + ".reprise", O_CREAT | O_RDWR, 0o644)
        defer { if verrou >= 0 { flock(verrou, LOCK_UN); close(verrou) } }
        if verrou >= 0 { flock(verrou, LOCK_EX) }

        guard b.listerSlugs().isEmpty else { return b }
        let fichiers = Stockage()
        guard !fichiers.listerSlugs().isEmpty else { return b }
        let (p, s, c) = try b.importer(depuis: fichiers)
        b.journal("imported from files: \(p) lists · \(s) servers · \(c) targets",
                  horodatage: Tour.horodatage())
        return b
    }

    /// Recopie tout ce que contient un stockage sur fichiers.
    ///
    /// Idempotent : relancer l'import met à jour au lieu de dupliquer, parce que
    /// chaque écriture rapproche l'existant de ce qu'on lui donne.
    @discardableResult
    public func importer(depuis s: Stockage) throws -> (profils: Int, serveurs: Int, cibles: Int) {
        var nS = 0, nC = 0
        let slugs = s.listerSlugs()
        for slug in slugs {
            let p = s.profil(slug)
            try ecrireTexte(slug, "recherche.txt", p.recherche)
            try ecrireTexte(slug, "requete.txt", p.requete)
            try ecrireCibles(slug, p.cibles)
            try ecrireHistorique(slug, p.historique)
            nS += p.historique.serveurs.count; nC += p.cibles.count
        }
        try ecrireVerdicts(s.verdicts())
        try ecrireCredits(s.credits())
        if let actif = s.slugActif() { try definirActif(actif) }
        return (slugs.count, nS, nC)
    }
}
