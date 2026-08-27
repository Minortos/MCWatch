// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Suivi du solde Shodan.
///
/// L'API ne donne **aucune** date de réinitialisation : on relève le solde
/// régulièrement et le jour où il remonte, on tient la date. Tant qu'aucune
/// remontée n'a été observée, on l'annonce comme inconnue plutôt que de
/// l'inventer.
public enum Solde {

    /// Relève le solde, au plus une fois par `intervalleMinutes`.
    @discardableResult
    public static func relever(_ stockage: any Depot, cle: String?,
                               intervalleMinutes: Double = 60) async -> Credits {
        var etat = stockage.credits()
        let maintenant = Date()

        if let vu = etat.vu, let quand = analyser(vu),
           maintenant.timeIntervalSince(quand) < intervalleMinutes * 60 {
            return etat
        }
        guard let cle, let infos = try? await Shodan(cle: cle).infos() else { return etat }

        etat = integrer(etat, solde: infos.creditsRecherche,
                        plafond: infos.plafondRecherche, plan: infos.plan,
                        maintenant: maintenant)
        // Sans trace, un solde qui ne s'enregistre pas se traduirait par une
        // interrogation de l'API à chaque tour — le bridage horaire reposant
        // justement sur `vu`, qu'on vient de ne pas écrire.
        do { try stockage.ecrireCredits(etat) }
        catch {
            stockage.journal("credit balance not saved: \(error)",
                             horodatage: Tour.horodatage(maintenant))
        }
        return etat
    }

    /// Ce qu'une mesure du solde change dans l'état, sans rien demander à personne.
    ///
    /// Extraite de `relever` parce que c'est une **décision**, pas un appel
    /// réseau : « le solde a remonté, donc le quota s'est réinitialisé
    /// aujourd'hui » est une règle, et une règle se vérifie. Tant qu'elle vivait
    /// entre un `await` et une écriture disque, aucun test ne pouvait l'atteindre
    /// sans interroger Shodan pour de vrai.
    ///
    /// ⚠️ La remontée est le **seul** signal disponible : l'API ne dit jamais
    /// quand le quota se renouvelle. Un achat de crédits produit donc la même
    /// observation qu'une réinitialisation, et sera compté comme telle — c'est
    /// assumé, faute de mieux.
    static func integrer(_ etat: Credits, solde: Int, plafond: Int, plan: String,
                         maintenant: Date) -> Credits {
        var etat = etat
        if let ancien = etat.solde, solde > ancien {
            etat.jourReinit = Calendar.current.component(.day, from: maintenant)
            etat.reinits.append(jour(maintenant))
            // Douze dates suffisent à voir une régularité sur un an, et bornent
            // un fichier qui grandirait sinon jusqu'à la fin des temps.
            etat.reinits = Array(etat.reinits.suffix(12))
        }
        etat.solde = solde
        etat.plafond = plafond
        etat.plan = plan
        etat.vu = Tour.horodatage(maintenant)
        return etat
    }

    /// Prochaine occurrence de ce jour du mois, en tenant compte des mois courts.
    public static func prochaine(_ jourDuMois: Int, depuis: Date = Date()) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let aujourdhui = cal.component(.day, from: depuis)
        var comp = cal.dateComponents([.year, .month], from: depuis)
        if aujourdhui >= jourDuMois {
            comp.month = (comp.month ?? 1) + 1
        }
        guard let debutMois = cal.date(from: comp),
              let plage = cal.range(of: .day, in: .month, for: debutMois) else { return nil }
        comp.day = Swift.min(jourDuMois, plage.count)
        return cal.date(from: comp)
    }

    /// Relecture de l'horodatage écrit par `Tour.horodatage` : même format,
    /// exprimé en `Date.ParseStrategy`, le pendant moderne de
    /// `DateFormatter.date(from:)`.
    static let strategieFichier = Date.ParseStrategy(
        format: """
            \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
            """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .autoupdatingCurrent)

    static let formatJour = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .autoupdatingCurrent,
        calendar: Calendar(identifier: .gregorian))

    static func analyser(_ s: String) -> Date? { try? Date(s, strategy: strategieFichier) }

    static func jour(_ d: Date) -> String { d.formatted(formatJour) }
}
