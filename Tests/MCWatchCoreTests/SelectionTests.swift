// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import MCWatchCore

/// Fabrique un serveur de test. Tout est neutre par défaut : chaque test ne
/// renseigne que ce qui l'intéresse, et ce qu'il ne dit pas ne peut pas
/// l'influencer.
func serveur(ip: String = "10.0.0.1", port: Int = 25565,
             maxVu: Int = 5, toursVus: Int = 10, toursPeuples: Int = 5,
             dernierOnline: Int = 0, dernierVu: String? = nil, slots: Int = 20,
             version: String = "26.2", motd: String = "A Minecraft Server",
             hebergeur: String = "", pays: String = "FR",
             whitelistAnnoncee: Bool = false, proxy: Bool = false,
             motdPromotionnel: Bool = false, motdParDefaut: Bool = false) -> Serveur {
    Serveur(ip: ip, port: port, maxVu: maxVu, picAt: nil, toursVus: toursVus,
            toursPeuples: toursPeuples, dernierOnline: dernierOnline, dernierVu: dernierVu,
            slots: slots, version: version, motd: motd, hebergeur: hebergeur,
            pays: pays, whitelistAnnoncee: whitelistAnnoncee, proxy: proxy,
            motdPromotionnel: motdPromotionnel, motdParDefaut: motdParDefaut)
}

/// Des filtres qui ne filtrent RIEN. Point de départ obligé : les valeurs par
/// défaut de `Filtres` sont celles de l'app (pic ≥ 1, 30 places, pas de proxy…),
/// et un test qui partirait de là mesurerait ces réglages autant que le sien.
func filtresNeutres() -> Filtres {
    var f = Filtres()
    f.picMin = 0; f.picMax = 0; f.slotsMax = 0; f.regularite = 0
    f.sansProxy = false; f.sansPub = false; f.masquerWhitelist = false
    f.motdParDefautSeulement = false; f.residentielSeulement = false
    f.masquerRates = false; f.masquerReussis = false; f.lignes = 0
    return f
}

/// Hébergeur professionnel ou ligne d'abonné ?
///
/// La distinction est le cœur de l'app : un serveur au bout d'une ligne
/// résidentielle est presque toujours celui de quelqu'un chez lui. Elle repose
/// sur deux expressions régulières consultées DANS UN ORDRE qui est lui-même le
/// mécanisme — et un remaniement bien intentionné de ces motifs casserait la
/// classification sans rien faire échouer ailleurs.
@Suite("Hébergeur ou résidentiel")
struct HebergementTests {

    /// Le cas d'école, cité dans le code : même mot, deux natures opposées.
    /// C'est l'ordre des motifs qui tranche, le fournisseur d'accès étant
    /// consulté en premier.
    @Test("« Google Fiber » est résidentiel, « Google LLC » ne l'est pas")
    func casDEcole() {
        let h = Selection.Hebergement()
        #expect(h.estHeberge("Google Fiber") == false)
        #expect(h.estHeberge("Google LLC") == true)
    }

    @Test("les hébergeurs sont reconnus",
          arguments: ["OVH SAS", "Hetzner Online GmbH", "Oracle Corporation",
                      "DigitalOcean, LLC", "Amazon Technologies Inc.",
                      "Contabo GmbH", "Vultr Holdings", "Scaleway",
                      "GMO Internet Group", "Servers.com", "M247 Europe"])
    func hebergeursReconnus(nom: String) {
        #expect(Selection.Hebergement().estHeberge(nom) == true)
    }

    /// Ces cinq-là sont explicitement cités dans le code : ils basculaient du
    /// mauvais côté quand les suffixes de société (`Inc`, `LLC`, `Ltd`)
    /// comptaient encore comme indice d'hébergement.
    @Test("les fournisseurs d'accès restent résidentiels",
          arguments: ["Comcast Cable", "Orange", "Free SAS", "Vodafone Libertel",
                      "Virgin Media Limited", "Deutsche Telekom AG", "Telstra",
                      "Cox", "Optus", "Spectrum", "Shaw", "Chunghwa Telecom"])
    func faiResidentiels(nom: String) {
        #expect(Selection.Hebergement().estHeberge(nom) == false)
    }

    /// Sans information, on GARDE le serveur. Cacher sur une supposition serait
    /// le pire des deux comportements : l'utilisateur ne saurait même pas
    /// qu'il manque quelque chose.
    @Test("un nom vide ou inconnu n'est pas déclaré hébergeur")
    func inconnuEstGarde() {
        let h = Selection.Hebergement()
        #expect(h.estHeberge("") == false)
        #expect(h.estHeberge("Quelque Chose Sans Rapport") == false)
    }

    @Test("la reconnaissance ignore la casse")
    func casseIgnoree() {
        let h = Selection.Hebergement()
        #expect(h.estHeberge("ovh sas") == true)
        #expect(h.estHeberge("OVH SAS") == true)
    }
}

/// Le filtrage, et surtout l'ACCORD entre ses deux écritures.
@Suite("Filtrage du classement")
struct SelectionTests {

    // MARK: - Chaque filtre, isolé

    @Test("picMin écarte ce qui n'a jamais atteint le seuil")
    func picMin() {
        var f = filtresNeutres(); f.picMin = 5
        let h = Selection.Hebergement()
        #expect(Selection.retenuParLeDepot(serveur(maxVu: 5), f, h) == true)
        #expect(Selection.retenuParLeDepot(serveur(maxVu: 4), f, h) == false)
    }

    @Test("picMax à zéro veut dire « pas de plafond »")
    func picMaxZeroIllimite() {
        var f = filtresNeutres(); f.picMax = 0
        let h = Selection.Hebergement()
        #expect(Selection.retenuParLeDepot(serveur(maxVu: 100_000), f, h) == true)
        f.picMax = 10
        #expect(Selection.retenuParLeDepot(serveur(maxVu: 11), f, h) == false)
        #expect(Selection.retenuParLeDepot(serveur(maxVu: 10), f, h) == true)
    }

    /// Un serveur qui annonce zéro place est écarté par un plafond de places,
    /// et ce n'est pas un oubli : zéro signifie « inconnu », et un plafond est
    /// une exigence — on ne la satisfait pas faute d'information.
    @Test("un plafond de places écarte aussi ceux qui n'en annoncent aucune")
    func slotsMaxZeroAnnonce() {
        var f = filtresNeutres(); f.slotsMax = 30
        let h = Selection.Hebergement()
        #expect(Selection.retenuParLeDepot(serveur(slots: 20), f, h) == true)
        #expect(Selection.retenuParLeDepot(serveur(slots: 31), f, h) == false)
        #expect(Selection.retenuParLeDepot(serveur(slots: 0), f, h) == false)
    }

    @Test("les drapeaux booléens écartent ce qu'ils désignent")
    func drapeaux() {
        let h = Selection.Hebergement()
        var f = filtresNeutres(); f.sansProxy = true
        #expect(Selection.retenuParLeDepot(serveur(proxy: true), f, h) == false)
        f = filtresNeutres(); f.sansPub = true
        #expect(Selection.retenuParLeDepot(serveur(motdPromotionnel: true), f, h) == false)
        f = filtresNeutres(); f.masquerWhitelist = true
        #expect(Selection.retenuParLeDepot(serveur(whitelistAnnoncee: true), f, h) == false)
        f = filtresNeutres(); f.motdParDefautSeulement = true
        #expect(Selection.retenuParLeDepot(serveur(motdParDefaut: false), f, h) == false)
        #expect(Selection.retenuParLeDepot(serveur(motdParDefaut: true), f, h) == true)
        f = filtresNeutres(); f.residentielSeulement = true
        #expect(Selection.retenuParLeDepot(serveur(hebergeur: "OVH SAS"), f, h) == false)
        #expect(Selection.retenuParLeDepot(serveur(hebergeur: "Comcast Cable"), f, h) == true)
    }

    // MARK: - L'accord des deux chemins

    /// ⚠️ LE test de cette suite.
    ///
    /// La règle de sélection est censée être écrite une seule fois : le dépôt
    /// l'applique de son côté, le classement du sien, et le commentaire de
    /// `retenuParLeDepot` affirme qu'ils disent « exactement la même chose ».
    /// Ce n'était pas vrai. `appliquer` divisait en `Double` là où le dépôt
    /// multipliait en entiers, et les deux écritures se contredisaient sur les
    /// valeurs pile au seuil : 29 tours peuplés sur 100 donnent 0,29, dont le
    /// centuple binaire vaut 28,999999999999996.
    ///
    /// Le désaccord était invisible — un serveur retenu par la base et absent
    /// du classement, sans erreur, sans trace. On refait donc la recherche
    /// entière à chaque exécution, plutôt que de se fier à une relecture.
    @Test("dépôt et classement s'accordent sur toutes les régularités")
    func accordSurLaRegularite() {
        let h = Selection.Hebergement()
        for seuil in 1...100 {
            var f = filtresNeutres(); f.regularite = seuil

            var lot: [Serveur] = []
            for vus in 1...100 {
                for peuples in 0...vus {
                    lot.append(serveur(ip: "10.\(vus).\(peuples).1",
                                       toursVus: vus, toursPeuples: peuples))
                }
            }
            let parLeDepot = Set(lot.filter { Selection.retenuParLeDepot($0, f, h) }
                                    .map(\.adresse))
            let parLeClassement = Set(Selection(filtres: f).appliquer(lot).map(\.adresse))

            #expect(parLeDepot == parLeClassement,
                    "seuil \(seuil) % : \(parLeDepot.symmetricDifference(parLeClassement).count) désaccord(s)")
        }
    }

    /// Les quatre cas exacts qui échouaient, nommés pour que l'échec soit
    /// lisible si la divergence revenait.
    @Test("les quatre désaccords historiques restent réglés",
          arguments: [(29, 100, 29), (57, 100, 57), (58, 100, 58), (29, 50, 58)])
    func desaccordsHistoriques(peuples: Int, vus: Int, seuil: Int) {
        var f = filtresNeutres(); f.regularite = seuil
        let s = serveur(toursVus: vus, toursPeuples: peuples)
        #expect(Selection.retenuParLeDepot(s, f, Selection.Hebergement()) == true)
        #expect(Selection(filtres: f).appliquer([s]).count == 1,
                "\(peuples)/\(vus) atteint exactement \(seuil) % : il doit rester")
    }

    // MARK: - Tri

    /// L'adresse départage en dernier, et ce n'est pas cosmétique : `sorted(by:)`
    /// n'est pas stable en Swift, donc sans ce critère final deux exécutions sur
    /// les mêmes données pourraient rendre deux ordres différents.
    @Test("le tri est totalement déterministe")
    func triDeterministe() {
        let lot = (1...50).map { serveur(ip: "10.0.0.\($0)", maxVu: 5, toursVus: 10,
                                         toursPeuples: 5, slots: 20) }
        #expect(Selection.trier(lot).map(\.adresse) == Selection.trier(lot.reversed()).map(\.adresse),
                "l'ordre d'entrée ne doit pas influer sur l'ordre de sortie")
    }

    @Test("les plus peuplés d'abord, puis les plus réguliers, puis les plus petits")
    func triCriteres() {
        let peuple = serveur(ip: "10.0.0.1", maxVu: 10)
        let moins = serveur(ip: "10.0.0.2", maxVu: 5)
        #expect(Selection.trier([moins, peuple]).first?.adresse == peuple.adresse)

        let regulier = serveur(ip: "10.0.0.3", maxVu: 5, toursPeuples: 9)
        let rare = serveur(ip: "10.0.0.4", maxVu: 5, toursPeuples: 1)
        #expect(Selection.trier([rare, regulier]).first?.adresse == regulier.adresse)

        let petit = serveur(ip: "10.0.0.5", maxVu: 5, slots: 10)
        let grand = serveur(ip: "10.0.0.6", maxVu: 5, slots: 100)
        #expect(Selection.trier([grand, petit]).first?.adresse == petit.adresse)
    }

    // MARK: - Marques et troncature

    @Test("les marques ✓ et ✗ se masquent séparément")
    func masquerMarques() {
        let a = serveur(ip: "10.0.0.1"), b = serveur(ip: "10.0.0.2")
        let verdicts = ["10.0.0.1:25565": Verdict(verdict: .rate, date: "2026-01-01"),
                        "10.0.0.2:25565": Verdict(verdict: .reussi, date: "2026-01-01")]
        var f = filtresNeutres(); f.masquerRates = true
        #expect(Selection(filtres: f, verdicts: verdicts).appliquer([a, b]).map(\.adresse) == [b.adresse])
        f = filtresNeutres(); f.masquerReussis = true
        #expect(Selection(filtres: f, verdicts: verdicts).appliquer([a, b]).map(\.adresse) == [a.adresse])
    }

    /// L'échappatoire : sans elle, un ✗ posé par erreur devenait irréversible
    /// puisque le serveur disparaissait de la vue où on l'aurait corrigé.
    @Test("« ignorer les marques » ramène tout le monde")
    func ignorerMarques() {
        let a = serveur(ip: "10.0.0.1")
        let verdicts = ["10.0.0.1:25565": Verdict(verdict: .rate, date: "2026-01-01")]
        var f = filtresNeutres(); f.masquerRates = true
        #expect(Selection(filtres: f, verdicts: verdicts, ignorerMarques: true)
                    .appliquer([a]).count == 1)
    }

    @Test("le nombre de lignes tronque, et zéro veut dire « toutes »")
    func troncature() {
        let lot = (1...100).map { serveur(ip: "10.0.0.\($0)", maxVu: $0) }
        var f = filtresNeutres(); f.lignes = 10
        #expect(Selection(filtres: f).appliquer(lot).count == 10)
        f.lignes = 0
        #expect(Selection(filtres: f).appliquer(lot).count == 100)
    }

    /// La troncature garde les MEILLEURS, pas les premiers venus : c'est tout
    /// l'objet du tri appliqué avant elle.
    @Test("la troncature conserve les plus peuplés")
    func troncatureGardeLesMeilleurs() {
        let lot = (1...100).map { serveur(ip: "10.0.0.\($0)", maxVu: $0) }
        var f = filtresNeutres(); f.lignes = 3
        #expect(Selection(filtres: f).appliquer(lot).map(\.maxVu) == [100, 99, 98])
    }

    @Test("une liste vide reste vide, sans incident")
    func listeVide() {
        #expect(Selection(filtres: filtresNeutres()).appliquer([]).isEmpty)
    }

    // MARK: - Les serveurs qui n'ont pas répondu au dernier passage

    /// ⚠️ Ce que ce filtre existe pour corriger : `Tour.fusionner` remet
    /// `dernierOnline` à zéro sur tout serveur qui n'a pas répondu. Un serveur
    /// vivant et vide, et un serveur mort depuis quinze jours, affichent donc
    /// le MÊME zéro. Rien dans le serveur seul ne les sépare — d'où
    /// l'horodatage du dernier tour, passé de l'extérieur.
    @Test("un serveur muet se distingue d'un serveur vide")
    func aReponduDistingueMuetEtVide() {
        let vivant = serveur(ip: "10.0.0.1", maxVu: 5, toursVus: 100,
                             toursPeuples: 50, dernierVu: "T100")
        let mort = serveur(ip: "10.0.0.2", maxVu: 5, toursVus: 3,
                           toursPeuples: 3, dernierVu: "T007")

        let s = Selection(filtres: filtresNeutres(), derniersTours: ["T100"])
        #expect(s.aRepondu(vivant))
        #expect(!s.aRepondu(mort), "vu pour la dernière fois au tour 7, on en est à 100")
    }

    /// Ne rien savoir ne doit pas tout faire disparaître : une liste jamais
    /// relevée n'a aucun horodatage de référence, et le tableau doit rester
    /// lisible.
    @Test("sans horodatage de référence, personne n'est déclaré muet")
    func aReponduSansReference() {
        let s = Selection(filtres: filtresNeutres(), derniersTours: [])
        #expect(s.aRepondu(serveur(ip: "10.0.0.1", maxVu: 1, dernierVu: "T001")))
        #expect(s.aRepondu(serveur(ip: "10.0.0.2", maxVu: 1, dernierVu: nil)))
    }

    @Test("le filtre écarte les muets, et seulement eux")
    func masquerMuets() {
        let vivant = serveur(ip: "10.0.0.1", maxVu: 5, toursVus: 100,
                             toursPeuples: 50, dernierVu: "T100")
        let vide = serveur(ip: "10.0.0.2", maxVu: 5, toursVus: 100,
                           toursPeuples: 0, dernierVu: "T100")
        let mort = serveur(ip: "10.0.0.3", maxVu: 5, toursVus: 3,
                           toursPeuples: 3, dernierVu: "T007")
        let tous = [vivant, vide, mort]

        var f = filtresNeutres()
        f.masquerMuets = true
        let retenus = Selection(filtres: f, derniersTours: ["T100"]).appliquer(tous)

        #expect(Set(retenus.map(\.adresse)) == Set([vivant.adresse, vide.adresse]),
                "le serveur VIDE reste : il a répondu, il n'a simplement personne")
        #expect(!retenus.contains { $0.adresse == mort.adresse })
    }

    @Test("éteint, le filtre ne retire rien")
    func masquerMuetsEteint() {
        let tous = [serveur(ip: "10.0.0.1", maxVu: 5, dernierVu: "T100"),
                    serveur(ip: "10.0.0.2", maxVu: 5, dernierVu: "T007")]
        var f = filtresNeutres()
        f.masquerMuets = false
        #expect(Selection(filtres: f, derniersTours: ["T100"]).appliquer(tous).count == 2)
    }

    /// Le filtre doit figurer dans la table qui explique un tableau vide, sans
    /// quoi le plus tranchant d'entre eux serait le seul à ne jamais être
    /// nommé.
    @Test("le diagnostic connaît le filtre des muets")
    func muetsDansLeDiagnostic() {
        #expect(Selection.criteres.contains { $0.0 == "masquer_muets" })
    }

}
