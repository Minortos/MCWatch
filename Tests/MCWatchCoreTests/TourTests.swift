// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MCWatchCore

/// Un relevé de test. Par défaut : un serveur qui répond, sans joueur.
func releve(ip: String = "10.0.0.1", port: Int = 25565, enLigne: Int = 0,
            slots: Int = 20, version: String = "26.2",
            motd: String = "A Minecraft Server", hebergeur: String = "",
            pays: String = "", whitelistAnnoncee: Bool = false, proxy: Bool = false,
            motdPromotionnel: Bool = false, motdParDefaut: Bool = true) -> Releve {
    Releve(ip: ip, port: port, hebergeur: hebergeur, pays: pays, enLigne: enLigne,
           slots: slots, version: version, motd: motd,
           whitelistAnnoncee: whitelistAnnoncee, proxy: proxy,
           motdPromotionnel: motdPromotionnel, motdParDefaut: motdParDefaut,
           protocoleAncien: false)
}

/// La fusion d'un relevé dans l'historique.
///
/// C'est le seul endroit où l'historique s'écrit, et tout ce que l'app affiche
/// en découle : le pic, la régularité, la colonne des joueurs, le tri. Une
/// erreur ici ne se voit pas passer — elle se dépose dans les données et y
/// reste, tour après tour.
@Suite("Fusion d'un tour")
struct TourTests {

    let ts = "2026-08-24T12:00:00"

    @Test("un serveur inconnu entre dans l'historique")
    func nouveauServeur() {
        let (h, _, _) = Tour.fusionner(Historique(), [releve(enLigne: 3)], horodatage: ts)
        let s = h.serveurs["10.0.0.1:25565"]
        #expect(s != nil)
        #expect(s?.toursVus == 1)
        #expect(s?.toursPeuples == 1)
        #expect(s?.dernierOnline == 3)
        #expect(s?.maxVu == 3)
        #expect(s?.dernierVu == ts)
    }

    @Test("un serveur vide compte comme vu, pas comme peuplé")
    func vuMaisVide() {
        let (h, peuples, _) = Tour.fusionner(Historique(), [releve(enLigne: 0)], horodatage: ts)
        let s = h.serveurs["10.0.0.1:25565"]
        #expect(s?.toursVus == 1)
        #expect(s?.toursPeuples == 0)
        #expect(peuples == 0)
    }

    @Test("le pic ne retient que les hausses, et date de la hausse")
    func pic() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve(enLigne: 5)], horodatage: "T1")
        #expect(h.serveurs["10.0.0.1:25565"]?.maxVu == 5)
        #expect(h.serveurs["10.0.0.1:25565"]?.picAt == "T1")

        // Une baisse ne touche ni au pic ni à sa date.
        (h, _, _) = Tour.fusionner(h, [releve(enLigne: 2)], horodatage: "T2")
        #expect(h.serveurs["10.0.0.1:25565"]?.maxVu == 5)
        #expect(h.serveurs["10.0.0.1:25565"]?.picAt == "T1")

        let (h3, _, pics) = Tour.fusionner(h, [releve(enLigne: 9)], horodatage: "T3")
        #expect(h3.serveurs["10.0.0.1:25565"]?.maxVu == 9)
        #expect(h3.serveurs["10.0.0.1:25565"]?.picAt == "T3")
        #expect(pics == 1)
    }

    /// ⚠️ Le cas qu'on ne voit pas dans le code : un serveur qui ne répond pas
    /// ne produit rien sur quoi itérer, et gardait donc son compteur de joueurs
    /// indéfiniment. La colonne annonçait « 5 joueurs » pour un serveur
    /// injoignable depuis treize jours — mesuré sur 95 lignes d'une liste
    /// réelle — et le tri par cette colonne était faussé d'autant.
    @Test("un serveur devenu muet retombe à zéro joueur")
    func muetRetombeAZero() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve(enLigne: 5)], horodatage: "T1")
        #expect(h.serveurs["10.0.0.1:25565"]?.dernierOnline == 5)

        // Tour suivant : ce serveur ne répond pas, un autre oui.
        (h, _, _) = Tour.fusionner(h, [releve(ip: "10.0.0.2", enLigne: 1)], horodatage: "T2")
        #expect(h.serveurs["10.0.0.1:25565"]?.dernierOnline == 0,
                "un muet ne peut pas continuer d'annoncer des joueurs")
    }

    /// La contrepartie, tout aussi importante : `dernierVu` doit RESTER à la
    /// date de la dernière réponse. C'est lui qui dit depuis quand un serveur
    /// est muet, et c'est sur lui que l'en-tête compte les silencieux.
    @Test("le muet garde la date de sa dernière réponse")
    func muetGardeSaDate() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve(enLigne: 5)], horodatage: "T1")
        (h, _, _) = Tour.fusionner(h, [releve(ip: "10.0.0.2")], horodatage: "T2")
        #expect(h.serveurs["10.0.0.1:25565"]?.dernierVu == "T1")
        #expect(h.serveurs["10.0.0.1:25565"]?.toursVus == 1, "un tour manqué n'est pas un tour vu")
    }

    /// Un serveur qui répond « zéro joueur » n'est PAS un muet : il a répondu.
    /// La distinction porte sur `dernierVu`, pas sur le nombre de joueurs.
    @Test("répondre zéro n'est pas se taire")
    func zeroNEstPasMuet() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve(enLigne: 5)], horodatage: "T1")
        (h, _, _) = Tour.fusionner(h, [releve(enLigne: 0)], horodatage: "T2")
        #expect(h.serveurs["10.0.0.1:25565"]?.dernierVu == "T2")
        #expect(h.serveurs["10.0.0.1:25565"]?.toursVus == 2)
    }

    /// Le pays vient de la recherche Shodan, pas du ping : une liste créée
    /// avant son ajout n'en a pas, et un relevé sans pays ne doit pas effacer
    /// celui qu'on connaît déjà.
    @Test("un relevé sans pays n'efface pas le pays connu")
    func paysPreserve() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve(pays: "FR")], horodatage: "T1")
        #expect(h.serveurs["10.0.0.1:25565"]?.pays == "FR")
        (h, _, _) = Tour.fusionner(h, [releve(pays: "")], horodatage: "T2")
        #expect(h.serveurs["10.0.0.1:25565"]?.pays == "FR")
    }

    @Test("les champs qui peuvent changer sont rafraîchis à chaque tour")
    func champsRafraichis() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve(slots: 20, version: "26.1", motd: "Avant")],
                                   horodatage: "T1")
        (h, _, _) = Tour.fusionner(h, [releve(slots: 50, version: "26.2", motd: "Après")],
                                   horodatage: "T2")
        let s = h.serveurs["10.0.0.1:25565"]
        #expect(s?.slots == 50)
        #expect(s?.version == "26.2")
        #expect(s?.motd == "Après")
    }

    // MARK: - Métadonnées

    @Test("le compteur de tours avance à chaque fusion, même sans relevé")
    func toursAvancent() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [], horodatage: "T1")
        (h, _, _) = Tour.fusionner(h, [], horodatage: "T2")
        #expect(h.meta.tours == 2)
    }

    @Test("la date de début est posée une fois, celle de fin suit chaque tour")
    func metaDates() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve()], horodatage: "T1")
        #expect(h.meta.debut == "T1")
        (h, _, _) = Tour.fusionner(h, [releve()], horodatage: "T2")
        #expect(h.meta.debut == "T1", "le début ne se réécrit jamais")
        #expect(h.meta.dernier == "T2")
    }

    @Test("les compteurs rendus décrivent ce tour-ci, pas le cumul")
    func compteursDuTour() {
        var h = Historique()
        (h, _, _) = Tour.fusionner(h, [releve(ip: "10.0.0.1", enLigne: 3),
                                       releve(ip: "10.0.0.2", enLigne: 1)], horodatage: "T1")
        let (_, peuples, pics) = Tour.fusionner(h, [releve(ip: "10.0.0.1", enLigne: 1),
                                                    releve(ip: "10.0.0.2", enLigne: 0)],
                                                horodatage: "T2")
        #expect(peuples == 1, "un seul des deux a des joueurs à ce tour")
        #expect(pics == 0, "aucun n'a battu son propre record")
    }

    @Test("plusieurs relevés du même tour sont tous pris")
    func plusieursServeurs() {
        let lot = (1...20).map { releve(ip: "10.0.0.\($0)", enLigne: $0) }
        let (h, peuples, pics) = Tour.fusionner(Historique(), lot, horodatage: ts)
        #expect(h.serveurs.count == 20)
        #expect(peuples == 20)
        #expect(pics == 20)
    }

    /// L'horodatage doit se relire : il sert de clé de comparaison entre tours,
    /// et c'est lui qui distingue un muet d'un répondant.
    @Test("l'horodatage produit est stable et non vide")
    func horodatageStable() {
        let d = Date(timeIntervalSince1970: 1_772_000_000)
        #expect(Tour.horodatage(d) == Tour.horodatage(d))
        #expect(!Tour.horodatage(d).isEmpty)
    }
}
