// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Un relevé : on pingue toute la liste et on fusionne le résultat dans
/// l'historique. Aucun filtre n'est appliqué ici — l'historique enregistre tout
/// ce qui répond, et le filtrage n'agit qu'à l'affichage. C'est ce qui permet
/// de durcir ou relâcher les filtres après coup sans jamais rien perdre.
public struct Tour: Sendable {

    public struct Bilan: Sendable {
        public var cibles: Int
        public var enLigne: Int
        public var peuples: Int
        public var nouveauxPics: Int
        public var duree: TimeInterval

        /// Pour le journal : **jamais traduite**. Un fichier de diagnostic doit
        /// dire la même chose chez tout le monde, sinon un rapport de bogue
        /// devient illisible pour qui ne parle pas la langue de son auteur.
        public var ligneJournal: String {
            "\(cibles) targets · \(enLigne) online · \(peuples) populated"
            + " · \(nouveauxPics) new peaks"
        }

        /// Pour la barre d'état de l'app, donc traduite. Les nombres sont mis
        /// après le mot : quatre pluriels dans une seule ligne d'état exigeraient
        /// autant de substitutions, pour un gain nul face à cette tournure.
        public var resume: String {
            String(localized: """
                targets: \(cibles) · online: \(enLigne) · populated: \(peuples) \
                · new peaks: \(nouveauxPics)
                """)
        }
    }

    /// Le format des horodatages **écrits sur disque**, dans `historique.json`
    /// et `verdicts.json`.
    ///
    /// `Date.VerbatimFormatStyle` et non `Date.FormatStyle` : le second compose
    /// selon la locale et ne laisse pas fixer les séparateurs, il ne peut donc
    /// pas produire `2026-08-13 00:14`. Le premier est fait pour les formats
    /// figés — c'est le remplaçant moderne de `DateFormatter` à `dateFormat`.
    ///
    /// Ces chaînes sont comparées entre elles (`dernierVu == meta.dernier`) et
    /// relues par `Solde.analyser` : le moindre écart de format casserait les
    /// données. Équivalence prouvée sur 20 000 dates et 2 000 relectures, sans
    /// un seul écart.
    public static let formatFichier = Date.VerbatimFormatStyle(
        format: """
            \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
            """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .autoupdatingCurrent,
        calendar: Calendar(identifier: .gregorian))

    public static func horodatage(_ date: Date = Date()) -> String {
        date.formatted(formatFichier)
    }

    /// L'opération inverse, pour l'interface uniquement.
    ///
    /// Sur disque ces chaînes sont comparées entre elles et jamais interprétées ;
    /// mais « il y a trois minutes » demande une vraie date, et la stratégie de
    /// lecture doit alors venir du **même** style que l'écriture — deux formats
    /// tenus en parallèle finiraient par diverger.
    public static func date(_ horodatage: String) -> Date? {
        try? Date(horodatage, strategy: formatFichier.parseStrategy)
    }

    /// Fusionne des relevés dans un historique. Séparé du réseau pour être
    /// vérifiable : mêmes entrées, même sortie, à comparer avec Python.
    public static func fusionner(_ historique: Historique, _ releves: [Releve],
                                 horodatage ts: String) -> (Historique, peuples: Int, pics: Int) {
        var h = historique
        h.meta.tours += 1
        if h.meta.debut == nil || h.meta.debut?.isEmpty == true { h.meta.debut = ts }
        h.meta.dernier = ts

        var peuples = 0
        var pics = 0

        for r in releves {
            let cle = r.adresse
            var e = h.serveurs[cle] ?? Serveur.neuf(ip: r.ip, port: r.port)

            e.toursVus += 1
            e.dernierOnline = r.enLigne
            e.dernierVu = ts
            if r.enLigne >= 1 {
                e.toursPeuples += 1
                peuples += 1
            }
            if r.enLigne > e.maxVu {
                e.maxVu = r.enLigne
                e.picAt = ts
                pics += 1
            }

            // Champs rafraîchis à chaque tour : ils peuvent changer.
            e.slots = r.slots
            e.version = r.version
            e.motd = r.motd
            e.hebergeur = r.hebergeur
            // Le pays vient de la recherche Shodan, pas du ping : une liste
            // créée avant son ajout n'en a pas, et il ne faut pas l'effacer.
            if !r.pays.isEmpty { e.pays = r.pays }
            e.whitelistAnnoncee = r.whitelistAnnoncee
            e.proxy = r.proxy
            e.motdPromotionnel = r.motdPromotionnel
            e.motdParDefaut = r.motdParDefaut

            h.serveurs[cle] = e
        }

        // Les MUETS de ce tour.
        //
        // La boucle ci-dessus ne parcourt que les réponses REÇUES : un serveur
        // qui ne répond pas n'y entre jamais, et gardait donc son compteur de
        // joueurs indéfiniment. La colonne NOW annonçait « 5 joueurs » pour un
        // serveur injoignable depuis treize jours — mesuré sur 95 lignes d'une
        // liste réelle. Le tri par cette colonne était faussé de la même façon.
        //
        // C'est un cas qu'on ne voit pas dans le code : une absence de réponse
        // ne produit rien sur quoi itérer. Il faut y penser depuis l'extérieur
        // de la boucle.
        //
        // On corrige à la source plutôt qu'à l'affichage, pour que la colonne,
        // le tri et tout filtre à venir lisent la même vérité.
        //
        // `dernierVu` n'est PAS touché : il doit rester à la date de la
        // dernière réponse, c'est lui qui dit depuis quand un serveur est muet
        // et c'est sur lui que l'en-tête compte les silencieux.
        let muets = h.serveurs
            .filter { $0.value.dernierVu != ts && $0.value.dernierOnline > 0 }
            .map(\.key)
        for cle in muets { h.serveurs[cle]?.dernierOnline = 0 }

        return (h, peuples, pics)
    }

    /// Les listes qui doivent travailler à ce réveil-ci.
    ///
    /// L'agent se réveille toutes les dix minutes, toujours, et c'est lui qui
    /// décide ensuite. Une cadence de trente minutes travaille un réveil sur
    /// trois — voir `Surveillance.estLHeure`. Rien n'est jamais réglé dans le
    /// plist de l'agent, qui ne bouge donc jamais : c'est ce qui met la
    /// surveillance à l'abri d'un réenregistrement.
    ///
    /// `forcer` court-circuite les cadences. C'est « Scan Now » : un geste
    /// explicite n'a pas à attendre son tour. Il n'incrémente PAS le compteur,
    /// sinon chaque clic décalerait la cadence des listes qu'on n'a pas
    /// demandées.
    static func aFaire(_ stockage: any Depot, forcer: Bool) -> [String] {
        let reglages = stockage.reglagesSurveillance()
        let reveil = forcer ? 0 : stockage.prochainReveil()
        var listes: [String] = []

        if forcer || Surveillance.estLHeure(reveil, cadence: reglages.cadenceRecherche),
           let actif = stockage.slugActif(), !Surveillance.estReserve(actif) {
            listes.append(actif)
        }
        if forcer || Surveillance.estLHeure(reveil, cadence: reglages.cadenceSurveillance) {
            listes.append(Surveillance.slug)
        }
        return listes
    }

    /// Un tour complet sur les listes dues, ping, fusion, écriture, journal.
    ///
    /// Les listes sont parcourues l'une après l'autre plutôt qu'en un seul
    /// grand tour : elles ne se recoupent quasiment jamais — mille adresses
    /// venues de Shodan contre une poignée choisies à la main — et les fondre
    /// obligerait à redistribuer les relevés ensuite. Elles partagent déjà ce
    /// qui compte : le même réveil de l'agent, donc un seul retour de veille
    /// pour la machine.
    @discardableResult
    public static func executer(_ stockage: any Depot, delai: Double = 3,
                                parallele: Int = 128, forcer: Bool = false) async -> Bilan? {
        var total: Bilan?
        for slug in aFaire(stockage, forcer: forcer) {
            guard let b = await tourner(stockage, slug, delai: delai,
                                        parallele: parallele) else { continue }
            total = total.map {
                Bilan(cibles: $0.cibles + b.cibles, enLigne: $0.enLigne + b.enLigne,
                      peuples: $0.peuples + b.peuples,
                      nouveauxPics: $0.nouveauxPics + b.nouveauxPics,
                      duree: $0.duree + b.duree)
            } ?? b
        }
        return total
    }

    /// Le tour d'UNE liste. Inchangé : c'est le code qui tournait déjà, à ceci
    /// près qu'il reçoit son slug au lieu d'aller chercher le profil actif.
    /// Publique pour un seul usage : relever la liste surveillée juste après
    /// qu'on y a ajouté une adresse. Sans cela, le serveur n'apparaîtrait dans
    /// le tableau qu'au prochain réveil de l'agent — jusqu'à dix minutes d'un
    /// écran qui ne montre rien, après une adresse dont on vient pourtant de
    /// vérifier qu'elle répond.
    public static func tourner(_ stockage: any Depot, _ slug: String, delai: Double = 3,
                               parallele: Int = 128) async -> Bilan? {
        let cibles = stockage.cibles(slug)
        guard !cibles.isEmpty else {
            // Une liste de RECHERCHE vide est une anomalie : on l'a créée en
            // dépensant des crédits, elle devrait contenir des adresses. La
            // liste surveillée, elle, est vide tant que l'utilisateur n'y a
            // rien mis — c'est l'état normal au départ, et le journaliser à
            // chaque réveil noierait le journal sous une ligne toutes les dix
            // minutes, indéfiniment.
            if !Surveillance.estReserve(slug) {
                stockage.journal("[\(slug)] empty list, scan skipped", horodatage: horodatage())
            }
            return nil
        }

        let debut = Date()
        let releves = await Ping.tour(cibles, delai: delai, parallele: parallele)
        let ts = horodatage()

        let (h, peuples, pics) = fusionner(stockage.historique(slug), releves, horodatage: ts)
        do {
            try stockage.ecrireHistorique(slug, h)
        } catch {
            stockage.journal("[\(slug)] write failed: \(error)", horodatage: ts)
            return nil
        }

        let bilan = Bilan(cibles: cibles.count, enLigne: releves.count, peuples: peuples,
                          nouveauxPics: pics, duree: Date().timeIntervalSince(debut))
        stockage.journal("[\(slug)] scan \(h.meta.tours) · \(bilan.ligneJournal)", horodatage: ts)
        return bilan
    }
}

extension Serveur {
    /// Entrée neuve, telle que la crée le moteur Python au premier relevé.
    static func neuf(ip: String, port: Int) -> Serveur {
        let vide = """
        {"ip":"\(ip)","port":\(port),"max_vu":0,"tours_vus":0,"tours_peuples":0}
        """
        // Passer par le décodeur garantit que tout champ ajouté plus tard
        // reçoit exactement le même repli qu'à la lecture d'un ancien fichier.
        return (try? JSONDecoder().decode(Serveur.self, from: Data(vide.utf8)))
            ?? Serveur.vraimentVide(ip: ip, port: port)
    }

    static func vraimentVide(ip: String, port: Int) -> Serveur {
        var s = try! JSONDecoder().decode(
            Serveur.self, from: Data(#"{"ip":"","port":25565}"#.utf8))
        s.ip = ip
        s.port = port
        return s
    }
}
