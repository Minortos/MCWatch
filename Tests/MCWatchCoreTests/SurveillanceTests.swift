// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MCWatchCore

/// La lecture d'une adresse tapée à la main.
///
/// C'est la seule entrée de l'app où l'utilisateur écrit librement quelque
/// chose qui deviendra une connexion réseau. Ce qu'il colle vient d'un chat,
/// d'un forum, d'une page de liste de serveurs — rarement d'un formulaire bien
/// tenu. Refuser trop est aussi mauvais qu'accepter n'importe quoi : dans un
/// cas on l'empêche de surveiller un serveur qui existe, dans l'autre on lui
/// promet une surveillance qui ne pourra jamais aboutir.
@Suite("Adresses surveillées")
struct SurveillanceTests {

    func adresse(_ saisie: String) -> Surveillance.Adresse? {
        try? Surveillance.lire(saisie).get()
    }

    func refus(_ saisie: String) -> Surveillance.Refus? {
        if case .failure(let r) = Surveillance.lire(saisie) { return r }
        return nil
    }

    // MARK: - Ce qui doit passer

    @Test("une IP nue prend le port de Java Edition")
    func ipNue() {
        let a = adresse("1.2.3.4")
        #expect(a?.hote == "1.2.3.4")
        #expect(a?.port == 25565)
    }

    @Test("un port explicite est retenu")
    func portExplicite() {
        #expect(adresse("1.2.3.4:25566")?.port == 25566)
        #expect(adresse("1.2.3.4:1")?.port == 1)
        #expect(adresse("1.2.3.4:65535")?.port == 65535)
    }

    @Test("un nom de domaine est accepté au même titre qu'une IP",
          arguments: ["mc.exemple.com", "exemple.com", "jeu.mc.exemple.co.uk",
                      "serveur-1.exemple.com", "localhost"])
    func nomDeDomaine(nom: String) {
        #expect(adresse(nom)?.hote == nom, "« \(nom) » devrait passer")
    }

    @Test("un nom avec port est correctement séparé")
    func nomAvecPort() {
        let a = adresse("mc.exemple.com:25566")
        #expect(a?.hote == "mc.exemple.com")
        #expect(a?.port == 25566)
    }

    /// Ce que les gens collent réellement : une adresse recopiée d'un
    /// navigateur, d'un message, avec ce qui traîne autour.
    @Test("les scories du copier-coller sont retirées",
          arguments: ["  1.2.3.4  ", "http://1.2.3.4", "https://1.2.3.4",
                      "minecraft://1.2.3.4", "1.2.3.4/", "https://1.2.3.4/"])
    func scoriesDuCollage(saisie: String) {
        #expect(adresse(saisie)?.hote == "1.2.3.4", "« \(saisie) » devrait donner 1.2.3.4")
    }

    /// Le texte de retour est ce qu'on affichera dans la liste : le port
    /// disparaît quand il est celui par défaut, comme partout ailleurs dans
    /// l'app.
    @Test("le port par défaut ne s'affiche pas")
    func texteAffiche() {
        #expect(adresse("1.2.3.4")?.texte == "1.2.3.4")
        #expect(adresse("1.2.3.4:25566")?.texte == "1.2.3.4:25566")
    }

    // MARK: - Ce qui doit être refusé

    @Test("une saisie vide est refusée",
          arguments: ["", "   ", "\n", "http://", "/"])
    func vide(saisie: String) {
        #expect(refus(saisie) == .vide, "« \(saisie) » devrait être vide")
    }

    @Test("un port hors bornes est refusé, et le dit",
          arguments: ["1.2.3.4:0", "1.2.3.4:65536", "1.2.3.4:99999"])
    func portHorsBornes(saisie: String) {
        #expect(refus(saisie) == .portInvalide)
    }

    /// ⚠️ « 1.2.3.999 » ressemble à une adresse et n'en est pas. Sans ce
    /// contrôle, le ping échouerait plus tard sans jamais expliquer pourquoi,
    /// et l'utilisateur croirait son serveur hors ligne.
    @Test("ce qui ressemble à une IP sans en être une est refusé",
          arguments: ["1.2.3.999", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-1"])
    func fausseIP(saisie: String) {
        #expect(refus(saisie) == .hoteInvalide, "« \(saisie) » devrait être refusé")
    }

    @Test("un hôte impossible est refusé",
          arguments: ["-exemple.com", "exemple-.com", "ex..emple.com",
                      "exemple .com", "ex_emple.com", "exemple.com:port"])
    func hoteImpossible(saisie: String) {
        #expect(refus(saisie) == .hoteInvalide, "« \(saisie) » devrait être refusé")
    }

    @Test("chaque refus porte une explication non vide")
    func explicationsPresentes() {
        for r: Surveillance.Refus in [.vide, .portInvalide, .hoteInvalide] {
            #expect(!r.explication.isEmpty)
        }
    }

    // MARK: - IPv4, cas limites

    @Test("les IPv4 valides sont reconnues",
          arguments: ["0.0.0.0", "255.255.255.255", "1.2.3.4", "192.168.1.1", "10.0.0.1"])
    func ipv4Valides(s: String) { #expect(Surveillance.estIPv4(s)) }

    /// Les zéros en tête sont refusés à dessein : « 010.1.1.1 » est lu en octal
    /// par certaines piles réseau et en décimal par d'autres. Une adresse qui
    /// ne désigne pas le même hôte partout n'est pas une adresse.
    @Test("les formes ambiguës ou fausses sont écartées",
          arguments: ["01.2.3.4", "1.2.3.4.5", "1.2.3", "256.0.0.1", "1.2.3.4:5", "", "....."])
    func ipv4Invalides(s: String) { #expect(!Surveillance.estIPv4(s)) }

    // MARK: - Cadence

    /// L'agent se réveille toutes les dix minutes et rien d'autre ne bouge :
    /// c'est le compteur de réveils qui décide qui travaille.
    @Test("une cadence de dix minutes travaille à chaque réveil")
    func cadenceDix() {
        for r in 0..<10 { #expect(Surveillance.estLHeure(r, cadence: 10)) }
    }

    @Test("une cadence de trente minutes travaille un réveil sur trois")
    func cadenceTrente() {
        #expect(Surveillance.estLHeure(0, cadence: 30))
        #expect(!Surveillance.estLHeure(1, cadence: 30))
        #expect(!Surveillance.estLHeure(2, cadence: 30))
        #expect(Surveillance.estLHeure(3, cadence: 30))
        #expect(Surveillance.estLHeure(6, cadence: 30))
    }

    @Test("une cadence d'une heure travaille un réveil sur six")
    func cadenceSoixante() {
        #expect(Surveillance.estLHeure(0, cadence: 60))
        #expect(!Surveillance.estLHeure(5, cadence: 60))
        #expect(Surveillance.estLHeure(6, cadence: 60))
        #expect(Surveillance.estLHeure(12, cadence: 60))
    }

    /// ⚠️ La propriété qui rend la synchronisation gratuite : deux listes de
    /// même cadence tombent forcément sur les mêmes réveils, donc sur un seul
    /// passage réseau. Il n'y a rien à synchroniser, seulement des nombres
    /// égaux.
    @Test("deux cadences égales tombent toujours ensemble",
          arguments: Surveillance.cadences)
    func cadencesEgalesCoincident(minutes: Int) {
        for r in 0..<60 {
            #expect(Surveillance.estLHeure(r, cadence: minutes)
                    == Surveillance.estLHeure(r, cadence: minutes))
        }
    }

    /// Et celle qui évite un piège : une cadence plus longue ne doit jamais
    /// travailler quand la plus courte se repose, sinon on paierait deux
    /// passages réseau là où un suffit.
    @Test("une cadence longue tombe toujours en même temps qu'une courte")
    func cadenceLongueInclusDansCourte() {
        for r in 0..<120 where Surveillance.estLHeure(r, cadence: 60) {
            #expect(Surveillance.estLHeure(r, cadence: 10), "réveil \(r)")
            #expect(Surveillance.estLHeure(r, cadence: 20), "réveil \(r)")
        }
    }

    @Test("une cadence absurde ne fait pas diviser par zéro")
    func cadenceAbsurde() {
        #expect(Surveillance.estLHeure(0, cadence: 0))
        #expect(Surveillance.estLHeure(7, cadence: 1))
    }

    // MARK: - Le slug réservé

    @Test("le slug réservé est un slug valide, et reconnu comme réservé")
    func slugReserve() {
        #expect(Stockage.slugSur(Surveillance.slug) == Surveillance.slug)
        #expect(Surveillance.estReserve(Surveillance.slug))
        #expect(!Surveillance.estReserve("26-2-fr"))
    }
}

/// Le parcours complet d'une liste surveillée, à travers un vrai dépôt.
///
/// Ce que les tests de `lire` ne peuvent pas voir : que la liste reste hors du
/// sélecteur de recherches, que sa cadence décide vraiment de ce qui travaille,
/// et qu'un relevé s'y dépose comme dans n'importe quel autre profil.
@Suite("Surveillance de bout en bout")
struct SurveillanceIntegrationTests {

    let racine: URL
    let s: Stockage

    init() throws {
        racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcwatch-surv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        s = Stockage(racine: racine)
    }

    func nettoyer() { try? FileManager.default.removeItem(at: racine) }

    /// ⚠️ Ce qui distingue cette liste de toutes les autres, et la seule chose
    /// qui l'en distingue : elle n'est pas une recherche, donc elle n'apparaît
    /// pas parmi les recherches.
    @Test("la liste surveillée reste hors du sélecteur de recherches")
    func horsDuSelecteur() throws {
        defer { nettoyer() }
        try s.ecrireCibles(Surveillance.slug, [Cible(ip: "1.2.3.4", port: 25565)])
        try s.ecrireHistorique("une-recherche", Historique())

        #expect(s.listerSlugs() == ["une-recherche"])
        // Mais elle existe bel et bien, et se lit comme n'importe quel profil.
        #expect(s.cibles(Surveillance.slug).count == 1)
        #expect(s.compterCibles(Surveillance.slug) == 1)
    }

    @Test("les adresses surveillées se relisent dans l'ordre où on les a mises")
    func adressesPersistees() throws {
        defer { nettoyer() }
        let cibles = ["10.0.0.1", "10.0.0.2", "mc.exemple.com"]
            .map { Cible(ip: $0, port: 25565) }
        try s.ecrireCibles(Surveillance.slug, cibles)
        #expect(s.cibles(Surveillance.slug).map(\.ip) == cibles.map(\.ip))
    }

    @Test("un relevé se dépose dans la liste surveillée comme ailleurs")
    func releveDepose() throws {
        defer { nettoyer() }
        try s.ecrireCibles(Surveillance.slug, [Cible(ip: "10.0.0.1", port: 25565)])
        let (h, _, _) = Tour.fusionner(s.historique(Surveillance.slug),
                                       [releve(ip: "10.0.0.1", enLigne: 4)],
                                       horodatage: "T1")
        try s.ecrireHistorique(Surveillance.slug, h)

        let relu = s.historique(Surveillance.slug)
        #expect(relu.serveurs["10.0.0.1:25565"]?.dernierOnline == 4)
        #expect(relu.serveurs["10.0.0.1:25565"]?.maxVu == 4)
    }

    // MARK: - Réglages

    @Test("les réglages se relisent, et les cadences absurdes sont corrigées")
    func reglagesPersistes() throws {
        defer { nettoyer() }
        var r = ReglagesSurveillance()
        r.cadenceSurveillance = 30
        r.filtrerSurveillance = true
        try s.ecrireReglagesSurveillance(r)

        let relu = s.reglagesSurveillance()
        #expect(relu.cadenceSurveillance == 30)
        #expect(relu.filtrerSurveillance == true)

        // Une valeur qui n'est plus proposée — fichier abîmé, ou version
        // antérieure — retombe sur le défaut plutôt que de produire un agent
        // qui ne travaillerait jamais.
        var absurde = ReglagesSurveillance()
        absurde.cadenceSurveillance = 7
        #expect(absurde.valides.cadenceSurveillance == Surveillance.cadenceSurveillanceParDefaut)
    }

    /// ⚠️ Porte sur la STRUCTURE et non sur une lecture du dépôt, et ce n'est
    /// pas un raccourci. Les réglages vivent dans `UserDefaults.standard`, qui
    /// est global : la racine jetable de cette suite ne les isole pas, et les
    /// tests de Swift Testing s'exécutent en parallèle. Lire le dépôt ici
    /// reviendrait à lire ce qu'un autre test vient d'y écrire — le test
    /// échouait effectivement, pour cette raison exactement.
    ///
    /// Ce qu'on veut vérifier est de toute façon là : les valeurs par défaut
    /// sont celles de la structure, et c'est elle que rend `reglagesSurveillance`
    /// quand rien n'a été enregistré.
    @Test("les valeurs par défaut sont celles qu'on attend")
    func reglagesParDefaut() {
        let r = ReglagesSurveillance()
        #expect(r.cadenceRecherche == 10, "la recherche Shodan travaille à chaque réveil")
        #expect(r.cadenceSurveillance == 30, "les serveurs choisis, un réveil sur trois")
        #expect(r.filtrerSurveillance == false, "un serveur choisi ne disparaît pas quand il se vide")
        // Et un objet vide se relit sur ces mêmes valeurs.
        let vide = try? JSONDecoder().decode(ReglagesSurveillance.self, from: Data("{}".utf8))
        #expect(vide == r)
    }

    /// Les deux défauts sont dans la liste proposée, et le plus lent est un
    /// multiple du plus rapide — sans quoi les deux listes tomberaient sur des
    /// réveils différents et l'écart coûterait un passage réseau de plus.
    @Test("les deux cadences par défaut retombent sur les mêmes réveils")
    func defautsSynchronises() {
        let r = ReglagesSurveillance()
        #expect(Surveillance.cadences.contains(r.cadenceRecherche))
        #expect(Surveillance.cadences.contains(r.cadenceSurveillance))
        #expect(r.cadenceSurveillance % r.cadenceRecherche == 0)
        // Tout réveil qui concerne les serveurs suivis concerne aussi la
        // recherche : jamais un réveil pour les seuls serveurs suivis.
        for reveil in 0..<60 where Surveillance.estLHeure(reveil, cadence: r.cadenceSurveillance) {
            #expect(Surveillance.estLHeure(reveil, cadence: r.cadenceRecherche), "réveil \(reveil)")
        }
    }

    /// Le pas est celui du plist, et toute cadence proposée en est un multiple.
    /// Une cadence qui ne le serait pas dériverait : `estLHeure` la ramènerait
    /// silencieusement au multiple inférieur.
    @Test("le pas de l'agent divise chaque cadence proposée")
    func pasDivise() {
        #expect(Surveillance.pas == 10, "c'est le StartInterval du plist de l'agent")
        for m in Surveillance.cadences { #expect(m % Surveillance.pas == 0, "\(m)") }
    }

    // MARK: - Qui travaille à ce réveil

    /// La cadence décide, et « Scan Now » passe devant tout le monde.
    @Test("un scan forcé prend les deux listes sans consommer de réveil")
    func scanForce() throws {
        defer { nettoyer() }
        try s.ecrireHistorique("recherche", Historique())
        try s.definirActif("recherche")

        let avant = UserDefaults.standard.integer(forKey: Stockage.cleReveils)
        let listes = Tour.aFaire(s, forcer: true)
        #expect(listes.contains("recherche"))
        #expect(listes.contains(Surveillance.slug))
        #expect(UserDefaults.standard.integer(forKey: Stockage.cleReveils) == avant,
                "un geste explicite ne doit pas décaler la cadence des autres listes")
    }

    // MARK: - Quand l'app a le droit de réinstaller l'agent

    /// Le garde qui décide si l'app réenregistre l'agent à son lancement.
    ///
    /// Écrit après un incident réel : `sfltool resetbtm` suivi d'un redémarrage
    /// laisse le système sans aucun service à ce nom, alors que le plist est
    /// toujours dans le paquet. L'app ne rattrapait que « jamais enregistré »
    /// et restait donc morte à chaque lancement.
    ///
    /// ⚠️ L'autre moitié compte autant : « en attente d'autorisation » est un
    /// refus posé par l'utilisateur dans Réglages Système. Le rattraper
    /// reposerait la question de macOS à chaque ouverture de l'app.
    @Test("l'app réinstalle l'agent absent, jamais celui qu'on a refusé")
    func etatsRattrapables() {
        #expect(Agent.etatsRattrapables.contains(.arretee),
                "jamais enregistré : c'est le premier lancement")
        #expect(Agent.etatsRattrapables.contains(.introuvable),
                "le système ne connaît plus le service — après un reset des éléments d'ouverture")

        #expect(!Agent.etatsRattrapables.contains(.attenteAutorisation),
                "un refus de l'utilisateur ne se rattrape pas")
        #expect(!Agent.etatsRattrapables.contains(.active),
                "déjà en marche, rien à faire")
        #expect(!Agent.etatsRattrapables.contains(.impossible),
                "aucun agent ne survivrait à cet emplacement")
        #expect(!Agent.etatsRattrapables.contains(.inconnu),
                "un état qu'on ne comprend pas ne se force pas")
    }

    /// Chaque état porte une phrase, et deux états n'en partagent jamais une :
    /// la ligne d'état du volet est la seule chose qui dit à l'utilisateur
    /// pourquoi rien ne tourne.
    @Test("chaque état de l'agent se nomme, et se nomme distinctement")
    func libellesDistincts() {
        let tous: [Agent.Etat] = [.active, .arretee, .attenteAutorisation,
                                  .introuvable, .impossible, .inconnu]
        let libelles = tous.map(\.libelle)
        #expect(libelles.allSatisfy { !$0.isEmpty })
        #expect(Set(libelles).count == tous.count)
    }

}
