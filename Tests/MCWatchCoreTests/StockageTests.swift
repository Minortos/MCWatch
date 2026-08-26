// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MCWatchCore

/// La persistance sur disque.
///
/// ⚠️ Chaque test travaille dans une racine JETABLE, tirée au sort et effacée
/// à la sortie. Les données réelles de l'utilisateur — historiques, verdicts,
/// listes — ne sont jamais ouvertes, encore moins écrites. Un test qui échoue
/// ne doit pas coûter treize jours d'historique.
///
/// Réserve connue : les FILTRES échappent à cette racine, `Stockage` les
/// rangeant dans `UserDefaults.standard`. En test, ce sont ceux du processus
/// de test et non ceux de l'app, mais la suite les laisse tranquilles.
@Suite("Persistance")
struct StockageTests {

    let racine: URL
    let s: Stockage

    init() throws {
        racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcwatch-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)
        s = Stockage(racine: racine)
    }

    /// Swift Testing construit une instance par test : ce nettoyage suit donc
    /// chaque cas, y compris ceux qui échouent.
    func nettoyer() { try? FileManager.default.removeItem(at: racine) }

    // MARK: - Aller-retour

    @Test("un historique écrit se relit à l'identique")
    func historiqueAllerRetour() throws {
        defer { nettoyer() }
        var h = Historique()
        h.meta.tours = 7
        h.meta.debut = "T1"
        h.serveurs["1.2.3.4:25565"] = serveur(ip: "1.2.3.4", maxVu: 42, toursPeuples: 29)

        try s.ecrireHistorique("essai", h)
        let relu = s.historique("essai")
        #expect(relu.meta.tours == 7)
        #expect(relu.meta.debut == "T1")
        #expect(relu.serveurs["1.2.3.4:25565"]?.maxVu == 42)
        #expect(relu.serveurs["1.2.3.4:25565"]?.toursPeuples == 29)
    }

    @Test("des cibles écrites se relisent dans le même ordre")
    func ciblesAllerRetour() throws {
        defer { nettoyer() }
        let cibles = (1...5).map { Cible(ip: "10.0.0.\($0)", port: 25565,
                                         hebergeur: "OVH", pays: "FR") }
        try s.ecrireCibles("essai", cibles)
        let relues = s.cibles("essai")
        #expect(relues.count == 5)
        #expect(relues.map(\.adresse) == cibles.map(\.adresse))
        #expect(relues.first?.pays == "FR")
    }

    @Test("des verdicts écrits se relisent")
    func verdictsAllerRetour() throws {
        defer { nettoyer() }
        try s.ecrireVerdicts(["1.2.3.4:25565": Verdict(verdict: .reussi, date: "2026-01-01")])
        #expect(s.verdicts()["1.2.3.4:25565"]?.verdict == .reussi)
    }

    @Test("un texte de profil se relit")
    func texteAllerRetour() throws {
        defer { nettoyer() }
        try s.ecrireTexte("essai", "recherche.txt", "26.2 FR")
        #expect(s.texte("essai", "recherche.txt") == "26.2 FR")
    }

    // MARK: - Absence

    /// Rien n'existe encore : c'est l'état de la toute première ouverture, pas
    /// une anomalie. Chaque lecture doit rendre un vide utilisable.
    @Test("un profil inexistant se lit en valeurs vides, sans erreur")
    func profilAbsent() {
        defer { nettoyer() }
        #expect(s.historique("jamais-vu").serveurs.isEmpty)
        #expect(s.cibles("jamais-vu").isEmpty)
        #expect(s.texte("jamais-vu", "recherche.txt").isEmpty)
        #expect(s.listerSlugs().isEmpty)
        #expect(s.slugActif() == nil)
        #expect(s.verdicts().isEmpty)
    }

    // MARK: - Corruption

    /// ⚠️ Le cas qui compte vraiment. Un disque plein, une coupure au mauvais
    /// moment, un fichier tripoté à la main : l'app doit repartir d'un état
    /// vide plutôt que refuser de s'ouvrir. Un plantage au lancement, sans
    /// recours pour l'utilisateur, serait la pire réponse possible.
    @Test("un historique illisible ne fait pas échouer la lecture")
    func historiqueCorrompu() throws {
        defer { nettoyer() }
        let dossier = racine.appendingPathComponent("profils/essai", isDirectory: true)
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        try Data("{ ceci n'est pas du JSON".utf8)
            .write(to: dossier.appendingPathComponent("historique.json"))
        #expect(s.historique("essai").serveurs.isEmpty)
    }

    @Test("des cibles illisibles rendent une liste vide")
    func ciblesCorrompues() throws {
        defer { nettoyer() }
        let dossier = racine.appendingPathComponent("profils/essai", isDirectory: true)
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        try Data("\u{0}\u{1}\u{2} octets au hasard".utf8)
            .write(to: dossier.appendingPathComponent("cibles.json"))
        #expect(s.cibles("essai").isEmpty)
    }

    /// Un fichier vide n'est pas du JSON valide non plus — c'est exactement ce
    /// que laisse une écriture interrompue avant son premier octet.
    @Test("un fichier vide se lit comme une absence")
    func fichierVide() throws {
        defer { nettoyer() }
        let dossier = racine.appendingPathComponent("profils/essai", isDirectory: true)
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        try Data().write(to: dossier.appendingPathComponent("historique.json"))
        #expect(s.historique("essai").meta.tours == 0)
    }

    // MARK: - Écriture atomique

    /// L'écriture passe par un fichier temporaire puis un renommage, pour
    /// qu'une coupure ne laisse jamais un historique à moitié écrit. On vérifie
    /// qu'aucun `.tmp` ne survit : un résidu signalerait un renommage manqué,
    /// donc un fichier de travail exposé comme s'il était le bon.
    @Test("l'écriture ne laisse aucun fichier temporaire derrière elle")
    func ecritureAtomique() throws {
        defer { nettoyer() }
        try s.ecrireHistorique("essai", Historique())
        try s.ecrireCibles("essai", [Cible(ip: "1.2.3.4", port: 25565)])
        let restes = try FileManager.default
            .contentsOfDirectory(atPath: racine.appendingPathComponent("profils/essai").path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(restes.isEmpty, "résidus : \(restes)")
    }

    /// Réécrire remplace, et n'ajoute pas : sans quoi l'historique enflerait
    /// à chaque tour.
    @Test("réécrire un historique le remplace entièrement")
    func reecritureRemplace() throws {
        defer { nettoyer() }
        var h = Historique()
        h.serveurs["1.2.3.4:25565"] = serveur(ip: "1.2.3.4")
        try s.ecrireHistorique("essai", h)

        var neuf = Historique()
        neuf.serveurs["9.9.9.9:25565"] = serveur(ip: "9.9.9.9")
        try s.ecrireHistorique("essai", neuf)

        let relu = s.historique("essai")
        #expect(relu.serveurs.count == 1)
        #expect(relu.serveurs["9.9.9.9:25565"] != nil)
        #expect(relu.serveurs["1.2.3.4:25565"] == nil, "l'ancien contenu ne doit pas survivre")
    }

    // MARK: - Profils

    @Test("les profils écrits se listent")
    func listerProfils() throws {
        defer { nettoyer() }
        for slug in ["alpha", "beta", "gamma"] {
            try s.ecrireHistorique(slug, Historique())
        }
        #expect(Set(s.listerSlugs()) == ["alpha", "beta", "gamma"])
    }

    @Test("le profil actif se pose et se relit")
    func profilActif() throws {
        defer { nettoyer() }
        try s.ecrireHistorique("alpha", Historique())
        try s.definirActif("alpha")
        #expect(s.slugActif() == "alpha")
    }

    @Test("supprimer un profil l'efface vraiment, et lui seul")
    func supprimerProfil() throws {
        defer { nettoyer() }
        try s.ecrireHistorique("alpha", Historique())
        try s.ecrireHistorique("beta", Historique())
        try s.supprimerProfil("alpha")
        #expect(s.listerSlugs() == ["beta"])
        #expect(s.historique("alpha").serveurs.isEmpty)
    }

    /// Les verdicts sont rangés par ADRESSE, pas par liste : un serveur qu'on a
    /// déjà écarté doit le rester quand il reparaît dans une autre recherche.
    /// C'est ce que promet la fenêtre de suppression.
    @Test("les verdicts survivent à la suppression d'un profil")
    func verdictsSurviventALaSuppression() throws {
        defer { nettoyer() }
        try s.ecrireHistorique("alpha", Historique())
        try s.ecrireVerdicts(["1.2.3.4:25565": Verdict(verdict: .rate, date: "2026-01-01")])
        try s.supprimerProfil("alpha")
        #expect(s.verdicts()["1.2.3.4:25565"]?.verdict == .rate)
    }

    // MARK: - Comptages

    /// « Répondants » veut dire au DERNIER tour, et non « présents dans
    /// l'historique ». La nuance est tout l'intérêt du compteur : l'en-tête
    /// annonce combien de serveurs ont répondu à l'instant, pas combien ont
    /// répondu un jour. Un serveur muet depuis treize jours figure encore dans
    /// l'historique et ne doit pas être compté.
    @Test("les répondants sont ceux du dernier tour, pas ceux de l'historique")
    func comptages() throws {
        defer { nettoyer() }
        try s.ecrireCibles("essai", (1...7).map { Cible(ip: "10.0.0.\($0)", port: 25565) })

        var h = Historique()
        h.meta.dernier = "T2"
        for i in 1...3 {                     // ont répondu au dernier tour
            h.serveurs["10.0.0.\(i):25565"] = serveur(ip: "10.0.0.\(i)", dernierVu: "T2")
        }
        for i in 4...5 {                     // muets depuis le tour d'avant
            h.serveurs["10.0.0.\(i):25565"] = serveur(ip: "10.0.0.\(i)", dernierVu: "T1")
        }
        h.serveurs["10.0.0.6:25565"] = serveur(ip: "10.0.0.6", dernierVu: nil)  // jamais vu
        try s.ecrireHistorique("essai", h)

        #expect(s.compterCibles("essai") == 7, "les cibles comptent la liste, pas les réponses")
        #expect(s.compterRepondants("essai") == 3)
    }
}
