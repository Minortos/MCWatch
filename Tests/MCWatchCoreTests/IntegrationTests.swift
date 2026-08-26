// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
// La suite « Version du schéma », en fin de fichier, construit un conteneur
// SwiftData à la main pour reproduire celui d'avant la déclaration de `SchemaV1`.
import SwiftData
@testable import MCWatchCore

/// Les deux dépôts, côte à côte.
///
/// `Stockage` écrit des fichiers JSON, `Base` une base SQLite, et les deux
/// doivent rendre exactement la même chose — c'est ce qui permet de passer de
/// l'un à l'autre sans que l'utilisateur voie quoi que ce soit changer.
///
/// La règle de filtrage existe en TROIS écritures : `retenuParLeDepot` qui fait
/// autorité, la boucle de `Selection.appliquer`, et un `#Predicate` traduit en
/// SQL. Les deux dernières ont chacune leur façon de se tromper, et le premier
/// bug trouvé dans ce projet était précisément une divergence de ce genre —
/// invisible, silencieuse, et fausse seulement sur les valeurs limites.
///
/// Ces tests ne relisent pas le code : ils font tourner les deux chemins sur
/// les mêmes données et exigent le même résultat.
@Suite("Accord des deux dépôts")
struct IntegrationTests {

    let racine: URL
    let fichierBase: URL
    let s: Stockage

    init() throws {
        let id = UUID().uuidString
        racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcwatch-integ-\(id)", isDirectory: true)
        fichierBase = racine.appendingPathComponent("base.store")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        s = Stockage(racine: racine)
    }

    func nettoyer() {
        for suffixe in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: fichierBase.path + suffixe))
        }
        try? FileManager.default.removeItem(at: racine)
    }

    /// Un échantillon qui touche tous les axes de filtrage à la fois — et qui
    /// inclut nommément les régularités limites (29/100, 57/100, 58/100) sur
    /// lesquelles les deux écritures se contredisaient.
    func peupler(_ slug: String = "essai") throws {
        var h = Historique()
        h.meta.tours = 100
        h.meta.dernier = "T100"

        var n = 0
        func ajouter(_ s: Serveur) { h.serveurs[s.adresse] = s; n += 1 }

        for (peuples, vus) in [(29, 100), (57, 100), (58, 100), (29, 50), (0, 10), (10, 10)] {
            ajouter(serveur(ip: "10.1.\(peuples).\(vus)", maxVu: max(1, peuples),
                            toursVus: vus, toursPeuples: peuples, dernierVu: "T100"))
        }
        for pic in [0, 1, 5, 20, 50] {
            ajouter(serveur(ip: "10.2.0.\(pic)", maxVu: pic, toursVus: 10,
                            toursPeuples: 5, dernierVu: "T100"))
        }
        for places in [0, 1, 10, 30, 31, 100] {
            ajouter(serveur(ip: "10.3.0.\(places)", maxVu: 5, toursVus: 10,
                            toursPeuples: 5, dernierVu: "T100", slots: places))
        }
        for (i, hebergeur) in ["OVH SAS", "Comcast Cable", "Google Fiber",
                               "Google LLC", ""].enumerated() {
            ajouter(serveur(ip: "10.4.0.\(i)", maxVu: 5, toursVus: 10, toursPeuples: 5,
                            dernierVu: "T100", hebergeur: hebergeur))
        }
        ajouter(serveur(ip: "10.5.0.1", maxVu: 5, toursVus: 10, toursPeuples: 5,
                        dernierVu: "T100", proxy: true))
        ajouter(serveur(ip: "10.5.0.2", maxVu: 5, toursVus: 10, toursPeuples: 5,
                        dernierVu: "T100", motdPromotionnel: true))
        ajouter(serveur(ip: "10.5.0.3", maxVu: 5, toursVus: 10, toursPeuples: 5,
                        dernierVu: "T100", whitelistAnnoncee: true))
        ajouter(serveur(ip: "10.5.0.4", maxVu: 5, toursVus: 10, toursPeuples: 5,
                        dernierVu: "T100", motdParDefaut: true))

        try s.ecrireHistorique(slug, h)
        try s.ecrireCibles(slug, h.serveurs.values.map { Cible(ip: $0.ip, port: $0.port) })
        try s.ecrireTexte(slug, "recherche.txt", "26.2 FR")
        try s.ecrireTexte(slug, "requete.txt", Criteres.socle)
    }

    /// Toutes les combinaisons de filtres à faire tourner. Chacune isole un axe,
    /// et les dernières les mêlent — c'est en les mêlant qu'on attrape les
    /// interactions qu'aucun test unitaire ne voit.
    static func jeuxDeFiltres() -> [Filtres] {
        var jeux: [Filtres] = [filtresNeutres(), Filtres()]
        for seuil in [1, 29, 50, 57, 58, 100] {
            var f = filtresNeutres(); f.regularite = seuil; jeux.append(f)
        }
        for pic in [0, 1, 5, 20, 51] {
            var f = filtresNeutres(); f.picMin = pic; jeux.append(f)
        }
        for places in [0, 1, 30, 100] {
            var f = filtresNeutres(); f.slotsMax = places; jeux.append(f)
        }
        var residentiel = filtresNeutres(); residentiel.residentielSeulement = true
        var sansProxy = filtresNeutres(); sansProxy.sansProxy = true
        var sansPub = filtresNeutres(); sansPub.sansPub = true
        var whitelist = filtresNeutres(); whitelist.masquerWhitelist = true
        var parDefaut = filtresNeutres(); parDefaut.motdParDefautSeulement = true
        jeux += [residentiel, sansProxy, sansPub, whitelist, parDefaut]

        var tout = filtresNeutres()
        tout.picMin = 1; tout.slotsMax = 30; tout.regularite = 29
        tout.sansProxy = true; tout.sansPub = true; tout.masquerWhitelist = true
        tout.residentielSeulement = true
        jeux.append(tout)
        return jeux
    }

    /// ⚠️ LE test de cette suite : sur chaque jeu de filtres, les deux dépôts
    /// doivent rendre le MÊME ensemble de serveurs. Le prédicat SQL n'a le
    /// droit d'être qu'une pré-sélection large — jamais d'écarter une ligne que
    /// la règle aurait gardée.
    @Test("les deux dépôts filtrent identiquement, sur tous les réglages")
    func memeFiltrageDesDeuxCotes() throws {
        defer { nettoyer() }
        try peupler()
        let base = try Base(fichier: fichierBase)
        _ = try base.importer(depuis: s)

        for (i, f) in Self.jeuxDeFiltres().enumerated() {
            let parFichiers = Set(s.serveursFiltres("essai", f).map(\.adresse))
            let parSQL = Set(base.serveursFiltres("essai", f).map(\.adresse))
            let ecart = parFichiers.symmetricDifference(parSQL)
            #expect(ecart.isEmpty,
                    "jeu \(i) : \(ecart.count) désaccord(s) — \(ecart.sorted().prefix(3))")
        }
    }

    @Test("l'import transporte l'historique sans rien perdre")
    func importFidele() throws {
        defer { nettoyer() }
        try peupler()
        let base = try Base(fichier: fichierBase)
        let (profils, serveurs, _) = try base.importer(depuis: s)
        #expect(profils == 1)
        #expect(serveurs == s.historique("essai").serveurs.count)

        let avant = s.historique("essai"), apres = base.historique("essai")
        #expect(avant.serveurs.count == apres.serveurs.count)
        #expect(avant.meta.tours == apres.meta.tours)
        #expect(avant.meta.dernier == apres.meta.dernier)

        for (cle, a) in avant.serveurs {
            let b = apres.serveurs[cle]
            #expect(b != nil, "\(cle) manque après import")
            #expect(b?.maxVu == a.maxVu)
            #expect(b?.toursVus == a.toursVus)
            #expect(b?.toursPeuples == a.toursPeuples)
            #expect(b?.slots == a.slots)
            #expect(b?.hebergeur == a.hebergeur)
            #expect(b?.proxy == a.proxy)
            #expect(b?.motdParDefaut == a.motdParDefaut)
        }
    }

    @Test("les deux dépôts comptent pareil")
    func memesComptages() throws {
        defer { nettoyer() }
        try peupler()
        let base = try Base(fichier: fichierBase)
        _ = try base.importer(depuis: s)
        #expect(s.compterCibles("essai") == base.compterCibles("essai"))
        #expect(s.compterRepondants("essai") == base.compterRepondants("essai"))
        #expect(Set(s.listerSlugs()) == Set(base.listerSlugs()))
    }

    @Test("les textes de profil traversent l'import")
    func textesTransportes() throws {
        defer { nettoyer() }
        try peupler()
        let base = try Base(fichier: fichierBase)
        _ = try base.importer(depuis: s)
        #expect(base.texte("essai", "recherche.txt") == "26.2 FR")
        #expect(base.texte("essai", "requete.txt") == Criteres.socle)
    }

    @Test("plusieurs profils restent distincts après import")
    func plusieursProfils() throws {
        defer { nettoyer() }
        try peupler("alpha")
        try peupler("beta")
        let base = try Base(fichier: fichierBase)
        _ = try base.importer(depuis: s)
        #expect(Set(base.listerSlugs()) == ["alpha", "beta"])
        #expect(base.historique("alpha").serveurs.count == base.historique("beta").serveurs.count)
    }

    /// Un dépôt vide n'est pas une erreur : c'est la toute première ouverture.
    @Test("importer depuis un dépôt vide ne casse rien")
    func importVide() throws {
        defer { nettoyer() }
        let base = try Base(fichier: fichierBase)
        let (profils, serveurs, cibles) = try base.importer(depuis: s)
        #expect(profils == 0 && serveurs == 0 && cibles == 0)
        #expect(base.listerSlugs().isEmpty)
    }

    // MARK: - Cesser de surveiller

    /// Le défaut que ce test ferme : retirer une adresse surveillée réécrivait
    /// la liste des cibles, et laissait l'historique intact. Or c'est
    /// l'historique que l'app lit pour épingler les serveurs suivis au tableau
    /// — le serveur retiré y restait donc épinglé indéfiniment, et plus aucune
    /// ligne des réglages ne permettait de l'en sortir.
    ///
    /// Les DEUX dépôts sont éprouvés ensemble : l'un supprime une ligne, l'autre
    /// réécrit un fichier, et rien d'autre qu'un test ne garantit qu'ils
    /// oublient la même chose.
    @Test("oublier un serveur le retire de l'historique, dans les deux dépôts")
    func oubliDunServeur() throws {
        defer { nettoyer() }
        try peupler()
        let base = try Base(fichier: fichierBase)
        _ = try base.importer(depuis: s)

        let cible = "10.5.0.1:25565"
        #expect(s.historique("essai").serveurs[cible] != nil)
        #expect(base.historique("essai").serveurs[cible] != nil)
        let avant = s.historique("essai").serveurs.count

        try s.oublierServeur("essai", cible)
        try base.oublierServeur("essai", cible)

        #expect(s.historique("essai").serveurs[cible] == nil)
        #expect(base.historique("essai").serveurs[cible] == nil)
        // Un seul, et pas un de plus : un prédicat trop large aurait effacé la
        // liste entière sans que le test précédent s'en aperçoive.
        #expect(s.historique("essai").serveurs.count == avant - 1)
        #expect(base.historique("essai").serveurs.count == avant - 1)
        #expect(Set(s.historique("essai").serveurs.keys)
                == Set(base.historique("essai").serveurs.keys))
    }

    /// Retirer deux fois, ou retirer ce qui n'a jamais été là : l'app le fait
    /// dès qu'un clic part en double, et cela ne doit rien coûter ni rien casser.
    @Test("oublier une adresse absente ne fait rien")
    func oubliSansEffet() throws {
        defer { nettoyer() }
        try peupler()
        let base = try Base(fichier: fichierBase)
        _ = try base.importer(depuis: s)
        let avant = s.historique("essai").serveurs.count

        for _ in 0..<2 {
            try s.oublierServeur("essai", "203.0.113.1:25565")
            try base.oublierServeur("essai", "203.0.113.1:25565")
            try s.oublierServeur("liste-qui-nexiste-pas", "10.5.0.1:25565")
            try base.oublierServeur("liste-qui-nexiste-pas", "10.5.0.1:25565")
        }

        #expect(s.historique("essai").serveurs.count == avant)
        #expect(base.historique("essai").serveurs.count == avant)
    }

    /// Un profil ne doit pas oublier pour un autre : les deux dépôts rangent
    /// les serveurs par liste, et le prédicat comme le fichier doivent s'en
    /// tenir à celle qu'on leur nomme.
    @Test("oublier dans une liste ne touche pas les autres")
    func oubliCloisonne() throws {
        defer { nettoyer() }
        try peupler("alpha")
        try peupler("beta")
        let base = try Base(fichier: fichierBase)
        _ = try base.importer(depuis: s)
        let cible = "10.5.0.1:25565"

        try s.oublierServeur("alpha", cible)
        try base.oublierServeur("alpha", cible)

        #expect(s.historique("alpha").serveurs[cible] == nil)
        #expect(base.historique("alpha").serveurs[cible] == nil)
        #expect(s.historique("beta").serveurs[cible] != nil)
        #expect(base.historique("beta").serveurs[cible] != nil)
    }
}

// MARK: - La version du schéma

/// Le schéma versionné, et la seule chose qu'on lui demande : **ne rien
/// changer**.
///
/// `SchemaV1` a été déclaré juste avant la première publication, pour qu'une
/// future migration ait une version de départ à nommer. Cette déclaration ne
/// vaut que si elle est neutre : le magasin de quelqu'un qui a déjà l'app a été
/// écrit par un conteneur construit sur la simple liste des types, sans version
/// explicite, et il doit continuer de s'ouvrir sans une ligne de migration.
///
/// Ces deux tests ne relisent pas la documentation d'Apple, ils font l'aller et
/// le retour.
@Suite("Version du schéma")
struct SchemaTests {

    let racine: URL
    let fichier: URL

    init() throws {
        racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcwatch-schema-\(UUID().uuidString)", isDirectory: true)
        fichier = racine.appendingPathComponent("base.store")
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
    }

    func nettoyer() {
        for suffixe in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fichier.path + suffixe))
        }
        try? FileManager.default.removeItem(at: racine)
    }

    /// La version déclarée est celle que `Schema` prenait déjà par défaut.
    ///
    /// C'est ce qui rend la déclaration invisible pour les magasins existants.
    /// Écrit comme une comparaison entre les deux constructions plutôt que
    /// comme un littéral `1.0.0` : si Apple changeait un jour son défaut, ce
    /// test le dirait, là où un littéral continuerait de passer en silence.
    @Test("la version de SchemaV1 est celle que Schema prenait par défaut")
    func versionNeutre() {
        let implicite = Schema([DProfil.self, DServeur.self, DCible.self,
                                DVerdict.self, DCredits.self])
        let explicite = Schema(versionedSchema: SchemaV1.self)
        #expect(explicite.version == implicite.version)
        #expect(explicite.entities.count == implicite.entities.count)
        #expect(Set(explicite.entities.map(\.name)) == Set(implicite.entities.map(\.name)))
    }

    /// Le vrai contrôle : un magasin écrit PAR L'ANCIEN conteneur se relit par
    /// le nouveau, sans migration et sans rien perdre.
    ///
    /// Les cinq entités sont écrites, y compris celles qui vivent hors profil
    /// (verdicts, crédits) : c'est l'ensemble du schéma qui doit traverser, pas
    /// seulement l'historique.
    @Test("un magasin écrit sans version déclarée se relit avec")
    func ancienMagasinRelu() throws {
        defer { nettoyer() }
        // Le conteneur d'AVANT : la liste des types, aucune version, aucun plan.
        do {
            let ancien = try ModelContainer(
                for: DProfil.self, DServeur.self, DCible.self, DVerdict.self, DCredits.self,
                configurations: ModelConfiguration(url: fichier))
            let c = ModelContext(ancien)
            let p = DProfil(slug: "essai", recherche: "26.2 tous", requete: "version:26.2",
                            tours: 7, debut: "T1", dernier: "T7", actif: true)
            c.insert(p)
            let sv = DServeur(serveur(ip: "10.0.0.1", maxVu: 42, toursPeuples: 29))
            sv.profil = p
            c.insert(sv)
            let cible = DCible(Cible(ip: "10.0.0.1", port: 25565, hebergeur: "Test", pays: "DE"),
                               rang: 0)
            cible.profil = p
            c.insert(cible)
            c.insert(DVerdict(adresse: "10.0.0.1:25565", marque: "ok", date: "T7"))
            var credits = Credits()
            credits.solde = 41
            credits.plan = "dev"
            c.insert(DCredits(credits))
            try c.save()
        }

        // Le conteneur d'APRÈS, sur le même fichier.
        let base = try Base(fichier: fichier)
        let h = base.historique("essai")
        #expect(base.listerSlugs() == ["essai"])
        #expect(base.slugActif() == "essai")
        #expect(h.meta.tours == 7)
        #expect(h.serveurs["10.0.0.1:25565"]?.maxVu == 42)
        #expect(h.serveurs["10.0.0.1:25565"]?.toursPeuples == 29)
        #expect(base.compterCibles("essai") == 1)
        #expect(base.texte("essai", "requete.txt") == "version:26.2")
        #expect(base.verdicts()["10.0.0.1:25565"]?.verdict == .reussi)
        #expect(base.credits().solde == 41)
        #expect(base.credits().plan == "dev")
    }
}
