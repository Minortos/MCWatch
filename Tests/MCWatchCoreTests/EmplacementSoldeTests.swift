// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MCWatchCore

/// Où l'app est installée, et ce que ça implique pour la surveillance.
///
/// Le commentaire de `etat(pour:)` annonce « un harnais qui couvre les quatre
/// cas en une seconde ». Le paramètre a bien été isolé de `Bundle.main` pour
/// cela ; le harnais, lui, n'existait pas. Le voici.
@Suite("Emplacement de l'app")
struct EmplacementTests {

    @Test("dans /Applications, rien à signaler")
    func applicationsSysteme() {
        #expect(Emplacement.etat(pour: URL(fileURLWithPath: "/Applications/MC Watch.app"))
                == .correct)
    }

    /// Le dossier Applications personnel est tout aussi légitime : `SMAppService`
    /// y enregistre un agent qui survit.
    @Test("le dossier Applications personnel est légitime aussi")
    func applicationsPersonnel() {
        let chemin = "/Users/quelquun/Applications/MC Watch.app"
        #expect(Emplacement.etat(pour: URL(fileURLWithPath: chemin)) == .correct)
    }

    /// ⚠️ L'ordre des tests DANS la fonction est le mécanisme : une app
    /// translocalisée est aussi hors Applications et sur un volume en lecture
    /// seule. C'est la translocation qu'il faut nommer, parce que c'est la
    /// seule des trois qui explique quoi faire.
    @Test("la translocation est nommée avant tout le reste")
    func translocation() {
        let chemin = "/private/var/folders/xy/abc/T/AppTranslocation/ABCD-1234/d/MC Watch.app"
        #expect(Emplacement.etat(pour: URL(fileURLWithPath: chemin)) == .translocalise)
    }

    @Test("ailleurs, on signale le dossier sans l'interdire")
    func horsApplications() {
        let etat = Emplacement.etat(pour: URL(fileURLWithPath: "/Users/quelquun/Downloads/MC Watch.app"))
        #expect(etat == .horsApplications("/Users/quelquun/Downloads"))
    }

    /// Un dossier qui contient « Applications » sans en être un ne doit pas
    /// passer pour tel : c'est un préfixe qui décide, pas une ressemblance.
    @Test("un faux ami ne se fait pas passer pour Applications",
          arguments: ["/Users/quelquun/Mes Applications/MC Watch.app",
                      "/opt/Applications/MC Watch.app",
                      "/Users/quelquun/Documents/Applications-old/MC Watch.app"])
    func fauxAmis(chemin: String) {
        #expect(Emplacement.etat(pour: URL(fileURLWithPath: chemin)) != .correct,
                "« \(chemin) » ne devrait pas compter pour un dossier Applications")
    }

    /// `horsApplications` n'est pas bloquant : le chemin est réel et stable,
    /// l'agent y survit. Décider à la place de quelqu'un qui range ses apps
    /// ailleurs serait présomptueux — mais une copie éphémère, elle, ne peut
    /// rien enregistrer du tout.
    @Test("seul un emplacement instable empêche réellement la surveillance")
    func cequiBloque() {
        #expect(Emplacement.Etat.correct != .translocalise)
        #expect(Emplacement.Etat.horsApplications("/x") != .translocalise)
    }
}

/// Le compte à rebours des crédits Shodan.
///
/// Un mois n'a pas toujours trente et un jours, et c'est exactement là que ce
/// genre de calcul se trompe : un quota qui se réinitialise le 31 doit tomber
/// quelque part en février.
@Suite("Réinitialisation des crédits")
struct SoldeTests {

    /// Construit une date sans dépendre de l'horloge : un test qui lit l'heure
    /// réelle échoue un jour par mois, et toujours celui où l'on n'a pas le
    /// temps de comprendre pourquoi.
    func date(_ an: Int, _ mois: Int, _ jour: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: an, month: mois, day: jour))!
    }

    func composantes(_ d: Date) -> (an: Int, mois: Int, jour: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return (c.year!, c.month!, c.day!)
    }

    @Test("avant le jour dit, la réinitialisation tombe ce mois-ci")
    func ceMoisCi() throws {
        let d = try #require(Solde.prochaine(15, depuis: date(2026, 3, 10)))
        #expect(composantes(d) == (2026, 3, 15))
    }

    /// Le jour même compte comme passé : le quota d'aujourd'hui est déjà celui
    /// qu'on dépense, la prochaine remise à zéro est le mois prochain.
    @Test("le jour même renvoie au mois suivant")
    func leJourMeme() throws {
        let d = try #require(Solde.prochaine(15, depuis: date(2026, 3, 15)))
        #expect(composantes(d) == (2026, 4, 15))
    }

    @Test("après le jour dit, la réinitialisation tombe le mois prochain")
    func moisProchain() throws {
        let d = try #require(Solde.prochaine(15, depuis: date(2026, 3, 20)))
        #expect(composantes(d) == (2026, 4, 15))
    }

    /// ⚠️ Le cas des mois courts. Un quota au 31 n'a pas de 31 février : il
    /// doit se rabattre sur le dernier jour, et non disparaître.
    @Test("un quota au 31 tombe le dernier jour d'un mois court")
    func moisCourt() throws {
        let fevrier = try #require(Solde.prochaine(31, depuis: date(2026, 1, 31)))
        #expect(composantes(fevrier) == (2026, 2, 28), "2026 n'est pas bissextile")

        let avril = try #require(Solde.prochaine(31, depuis: date(2026, 3, 31)))
        #expect(composantes(avril) == (2026, 4, 30))
    }

    @Test("une année bissextile donne bien un 29 février")
    func bissextile() throws {
        let d = try #require(Solde.prochaine(31, depuis: date(2028, 1, 31)))
        #expect(composantes(d) == (2028, 2, 29))
    }

    @Test("le passage à l'année suivante se fait proprement")
    func changementDAnnee() throws {
        let d = try #require(Solde.prochaine(5, depuis: date(2026, 12, 20)))
        #expect(composantes(d) == (2027, 1, 5))
    }

    @Test("la date rendue est toujours postérieure à celle demandée",
          arguments: [1, 5, 15, 28, 29, 30, 31])
    func toujoursDansLeFutur(jour: Int) throws {
        for mois in 1...12 {
            let depuis = date(2026, mois, 15)
            let d = try #require(Solde.prochaine(jour, depuis: depuis))
            #expect(d > depuis, "jour \(jour), mois \(mois) : la date rendue est dans le passé")
        }
    }

    // MARK: - Horodatage

    /// L'horodatage écrit par `Tour` doit se relire par `Solde` : c'est le même
    /// format des deux côtés, et l'un sans l'autre ne sert à rien.
    @Test("ce que Tour écrit, Solde le relit")
    func allerRetourHorodatage() throws {
        let d = date(2026, 8, 24)
        let ecrit = Tour.horodatage(d)
        let relu = try #require(Solde.analyser(ecrit))
        #expect(composantes(relu) == (2026, 8, 24))
    }

    @Test("un horodatage abîmé ne rend rien plutôt que n'importe quoi",
          arguments: ["", "pas une date", "2026-13-45 99:99", "2026-08-24"])
    func horodatageIllisible(brut: String) {
        #expect(Solde.analyser(brut) == nil)
    }

    @Test("le jour se formate en ISO, stable quelle que soit la langue")
    func formatJour() {
        #expect(Solde.jour(date(2026, 8, 24)) == "2026-08-24")
        #expect(Solde.jour(date(2026, 1, 5)) == "2026-01-05", "les zéros de tête sont conservés")
    }
}
