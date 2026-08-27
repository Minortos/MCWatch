// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import MCWatchCore

/// Tout l'état de l'application. Aucune logique métier ici : le modèle appelle
/// `MCWatchCore`, exactement comme le scanner sans interface. Une seule source
/// de vérité, un seul comportement.
@MainActor
@Observable
public final class Modele {

    /// Le dépôt. SwiftData depuis la bascule ; les fichiers JSON restent sur le
    /// disque, intacts mais plus écrits, le temps que ça fasse ses preuves.
    /// Revenir en arrière = remplacer cette seule expression par `Stockage()`.
    let stockage: any Depot = Base.ouvrirOuFichiers()

    // Données
    var tousServeurs: [Serveur] = []
    var verdicts: [String: Verdict] = [:]
    var filtres = Filtres()
    var credits = Credits()

    // En-tête
    var recherche = "" { didSet { if recherche != oldValue { recalculer() } } }
    var nomListe = ""
    var nombreCibles = 0
    var nombreSuivis = 0
    var nombreRelevés = 0
    var nombreListes = 0

    // ─── La surveillance, telle que l'interface la lit ──────────────────────
    //
    // Les trois sont STOCKÉES, pour la raison qui a déjà valu sa correction au
    // trousseau juste en dessous : le corps d'une vue SwiftUI est réévalué à
    // chaque redessin, et tout ce qu'il appelle est payé autant de fois.
    // `etatAgent` interrogeait launchd, `adressesSurveillees` lisait la base et
    // `reglagesSurveillance` décodait du JSON — cinq fois par passe, la vue en
    // lisant trois champs. Elles sont désormais relues là où quelque chose peut
    // les avoir changées : dans `recharger`, et après nos propres écritures.

    /// Où en est l'agent de relevé. Un appel système par lecture, donc un seul.
    private(set) var etatAgent: Agent.Etat = .arretee

    /// Raccourci de lecture, pour le menu et pour la case des réglages.
    var surveillanceActive: Bool { etatAgent == .active }

    /// Les adresses suivies, dans l'ordre où elles ont été ajoutées.
    private(set) var adressesSurveillees: [Cible] = []

    /// Les horodatages du dernier passage de chaque liste affichée.
    ///
    /// Sert à deux choses qui n'en font qu'une : distinguer « personne dessus »
    /// de « n'a pas répondu » dans la colonne du moment, et alimenter le filtre
    /// qui masque les muets. `dernierOnline` vaut zéro dans les DEUX cas — voir
    /// `Tour.fusionner`, qui le remet à zéro sur les silencieux — donc rien
    /// dans le serveur seul ne permet de les séparer.
    private(set) var derniersTours: Set<String> = []

    /// Ce serveur a-t-il répondu au dernier passage de sa liste ?
    func aRepondu(_ s: Serveur) -> Bool {
        Selection(filtres: filtres, derniersTours: derniersTours).aRepondu(s)
    }

    /// Quand un relevé a été écrit pour la dernière fois, toutes listes
    /// confondues. C'est la seule preuve visible qu'un agent travaille — un
    /// interrupteur sur « actif » n'en est pas une, il dit ce que launchd a
    /// accepté, pas ce qui s'est produit depuis.
    private(set) var dernierReleve: Date?

    /// Cadences et portée des filtres. L'agent les lit de son côté : rien ne
    /// garantit que l'app soit seule à les avoir écrites, d'où la relecture à
    /// chaque tour plutôt qu'une valeur tenue pour acquise.
    ///
    /// ⚠️ Lue **dès la construction**, et non laissée aux valeurs par défaut du
    /// type en attendant le premier `recharger`. La scène `Settings` est bâtie
    /// au lancement, avant que la fenêtre principale n'ait rechargé quoi que ce
    /// soit : ses menus s'affichaient alors sur « toutes les dix minutes » —
    /// et le premier accrochage du `Picker` réécrivait cette valeur par-dessus
    /// le réglage réel de l'utilisateur. Une cadence de trente minutes se
    /// retrouvait à dix sans que personne n'y ait touché.
    private(set) var reglagesSurveillance: ReglagesSurveillance

    /// Les adresses que l'utilisateur suit délibérément. Sert à la colonne du
    /// tableau, et à rien d'autre : c'est un ensemble pour que la question
    /// « celui-ci est-il épinglé ? » se pose une fois par cellule sans coûter.
    private(set) var epingles: Set<String> = []

    /// Vrai si une clé est rangée dans le trousseau.
    ///
    /// ⚠️ STOCKÉE, et surtout pas calculée — elle l'a été, et c'était un défaut
    /// mesurable. Lire le trousseau passe par `SecItemCopyMatching`, un
    /// aller-retour SYNCHRONE vers `securityd` ; macOS le signale comme faute
    /// sur le fil principal (« This method should not be called on the main
    /// thread as it may lead to UI unresponsiveness », sous-système
    /// `com.apple.runtime-issues`, catégorie Security).
    ///
    /// Or les vues la lisent — `messageVide` et `premiereOuverture` en
    /// dépendent — et une vue SwiftUI se réévalue à chaque redessin. Chaque
    /// redessin allait donc interroger le trousseau. Retirer la clé, qui
    /// reconstruit tout ce qui en dépend, produisait DOUZE de ces fautes en
    /// sept millisecondes. Relevé dans Console, reproduit deux fois.
    ///
    /// Le trousseau n'est plus lu qu'aux trois moments où la réponse peut
    /// changer : au démarrage, après un enregistrement, après un retrait.
    private(set) var cleConfiguree = Cle.courante() != nil
    /// Accueil de première ouverture : posé une seule fois au démarrage, jamais
    /// recalculé ensuite — sinon la feuille se rouvrirait toute seule au premier
    /// rafraîchissement, exactement le comportement que le user rejette.
    var montrerBienvenue = false

    // Interface
    var selection: Serveur.ID? { didSet { majSelection() } }
    var message = String(localized: "Space, Return or double-click to copy the address")
    var chargement = false
    /// Incrémenté par ⌘F : la vue observe ce compteur pour porter le curseur
    /// dans le champ de recherche. Un compteur plutôt qu'un booléen, sinon deux
    /// ⌘F d'affilée ne produiraient qu'un seul changement observable.
    var demandeFocusRecherche = 0

    public init() {
        reglagesSurveillance = stockage.reglagesSurveillance()
    }

    // MARK: - Ce qui s'affiche

    /// Ce que la table affiche, **mémorisé**. C'était auparavant une propriété
    /// calculée, donc refiltrée à chaque lecture : l'en-tête l'appelait deux fois
    /// et la table une, soit trois passes sur tout l'historique par rendu. Le
    /// recalcul est maintenant déclenché par ce qui le rend caduc — les données,
    /// les filtres, la recherche, la portée — et par rien d'autre.
    private(set) var serveurs: [Serveur] = []

    /// L'ordre de tri, et **le tri lui-même**, qui appartiennent au modèle.
    ///
    /// La vue en faisait une propriété calculée, donc retriée à chaque lecture
    /// du corps — mesuré à **8,6 ms** pour 357 lignes, soit plus qu'une image
    /// entière à 120 Hz. C'est ce qui rendait le défilement et surtout le
    /// redimensionnement de la fenêtre pâteux : on repayait le tri en continu.
    var tri: [KeyPathComparator<Serveur>] = [KeyPathComparator(\Serveur.maxVu, order: .reverse)] {
        didSet { recalculer() }
    }

    /// Le comparateur de référence, celui de Foundation.
    ///
    /// J'ai essayé de le remplacer par une comparaison écrite à la main, mesurée
    /// onze fois plus rapide — puis vérifiée : **18 tris sur 18 divergeaient**.
    /// `KeyPathComparator` compare les chaînes en **standard localisé**
    /// (`String.StandardComparator.localizedStandard`), pas avec `<` : c'est ce
    /// qui range « 9. » avant « 10. » dans les adresses. En reproduisant cette
    /// sémantique, l'écart tombait à zéro mais le gain aussi — 6,0 ms contre
    /// 8,6. Trente pour cent ne valent pas un `switch` à tenir en phase avec les
    /// colonnes, et que je venais de rater. Le vrai correctif était ailleurs :
    /// ne plus trier à chaque lecture du corps de la vue.
    ///
    /// L'adresse départage toujours en dernier : la source est un dictionnaire,
    /// dont l'ordre varie d'une lecture à l'autre, et un tri n'est pas stable.
    private func trier(_ liste: [Serveur]) -> [Serveur] {
        let ordonnes = liste.sorted(using: tri + [KeyPathComparator(\Serveur.adresse)])
        // Les serveurs épinglés remontent en tête, quel que soit le tri demandé
        // — c'est ce que veut dire épingler. L'ordre choisi continue de régner
        // À L'INTÉRIEUR de chaque groupe : trier par pic ordonne les épinglés
        // entre eux, puis les autres entre eux.
        //
        // Fait ici plutôt que par une colonne triable : « épinglé » n'est pas
        // une propriété du serveur mais une décision de l'utilisateur, et lui
        // donner un champ dans `Serveur` la ferait écrire sur disque, migrer,
        // et traverser les deux dépôts pour rien.
        guard !epingles.isEmpty else { return ordonnes }
        return ordonnes.filter { epingles.contains($0.adresse) }
             + ordonnes.filter { !epingles.contains($0.adresse) }
    }

    /// Filtres, recherche textuelle, puis tri — une seule fois, ici.
    func recalculer() {
        let retenus = Selection(filtres: filtres, verdicts: verdicts,
                                derniersTours: derniersTours).appliquer(tousServeurs)
        let q = recherche.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { serveurs = trier(retenus); return }
        // Un seul champ, aucune portée à choisir : le champ de recherche fait ce
        // qu'on attend de lui sans qu'on ait à le régler. Les colonnes
        // **numériques** en sont exclues volontairement — chercher « 20 »
        // remonterait les slots à 20, les pics à 20, la version 1.20 et tout
        // MOTD contenant « 20 », soit plus de bruit que de résultats.
        serveurs = trier(retenus.filter { s in
            s.adresse.lowercased().contains(q)
                || s.hebergeur.lowercased().contains(q)
                || s.motd.lowercased().contains(q)
                || s.pays.lowercased().contains(q)
                || s.version.lowercased().contains(q)
        })
    }

    func marque(_ s: Serveur) -> Marque? { verdicts[s.adresse]?.verdict }

    /// **Mémorisé**, et non recalculé à la lecture. C'était une propriété
    /// calculée qui parcourait tout l'historique — 2051 serveurs — et la vue
    /// l'interrogeait quatre fois par rendu (le presse-papiers, plus les trois
    /// boutons du bas). Huit mille comparaisons de chaînes à chaque passe, dont
    /// une pendant le défilement. Recalculé seulement quand la sélection change
    /// ou quand les données sont relues.
    private(set) var serveurSelectionne: Serveur?

    private func majSelection() {
        serveurSelectionne = selection.flatMap { id in tousServeurs.first { $0.id == id } }
    }

    /// L'entonnoir : combien d'adresses dans la liste, combien répondent,
    /// combien survivent aux filtres. Sans ces trois chiffres, un tableau court
    /// paraît inexplicable.
    var entete: String {
        let muets = max(0, nombreCibles - nombreSuivis)
        let repondent = muets > 0
            ? String(localized: "\(nombreSuivis) answer the ping (\(muets) silent)")
            : String(localized: "\(nombreSuivis) answer the ping")
        let notes = serveurs.filter { marque($0) != nil }.count
        return String(localized: """
            Monitored search: \(nomListe)   ·   \(nombreCibles) in the list  ·  \
            \(repondent)  ·  \(serveurs.count) shown, \(notes) rated
            """)
    }

    var resumeFiltres: String { Resume.filtres(filtres) }

    // MARK: - Chargement

    /// Relit ce qui a changé. L'app se rafraîchit toutes les trente secondes
    /// alors que l'agent n'écrit que toutes les dix minutes : redécoder à chaque
    /// fois un historique de plusieurs milliers de serveurs, plus une liste de
    /// mille cibles, était du travail pur perte dix-neuf fois sur vingt. La date
    /// de modification du fichier suffit à le savoir, sans rien décoder.
    ///
    /// `force` sert après une écriture faite par l'app elle-même, quand la date
    /// pourrait ne pas avoir changé de façon perceptible.
    func recharger(force: Bool = false) {
        let slug = stockage.slugActif() ?? ""
        // La liste surveillée a son propre historique, donc sa propre date :
        // ajouter une adresse ne modifie pas celui de la recherche affichée, et
        // sans ce second témoin le tableau ne se rafraîchirait pas.
        let date = [stockage.dateHistorique(slug),
                    stockage.dateHistorique(Surveillance.slug)]
            .compactMap(\.self).max()
        // Relus d'abord : la requête au dépôt s'en sert pour dégrossir.
        filtres = stockage.filtres()
        // De même : c'est lui qui décide si les serveurs suivis passent par les
        // filtres, donc il doit être à jour avant qu'on les demande.
        reglagesSurveillance = stockage.reglagesSurveillance()
        if force || slug != slugCharge || date != dateChargee {
            // Lectures **ciblées**, et non un chargement complet : le dépôt
            // applique lui-même les critères chiffrés et booléens, et compte
            // sans rien charger. Mesuré sur la liste réelle — charger les 2052
            // serveurs pour les filtrer en mémoire coûtait **231 ms** à chaque
            // rechargement, la requête en coûte **15**.
            tousServeurs = stockage.serveursFiltres(slug, filtres)

            // ─── Les serveurs surveillés, quelle que soit la liste affichée ──
            //
            // Ils sont ÉPINGLÉS : on les a désignés à la main, ils n'ont pas à
            // disparaître parce qu'on regarde une autre recherche. Et par
            // défaut ils échappent aux filtres — un serveur qu'on suit et qui
            // se vide s'effacerait du tableau au moment précis où l'on veut
            // savoir qu'il est vide. Le réglage permet l'inverse à qui le veut.
            let surveilles = reglagesSurveillance.filtrerSurveillance
                ? stockage.serveursFiltres(Surveillance.slug, filtres)
                : Array(stockage.historique(Surveillance.slug).serveurs.values)
            epingles = Set(surveilles.map(\.adresse))
            // Un même serveur peut être dans la recherche ET surveillé : il ne
            // doit apparaître qu'une fois, et c'est `epingles` qui le signale.
            let deja = Set(tousServeurs.map(\.adresse))
            tousServeurs += surveilles.filter { !deja.contains($0.adresse) }

            let recherche = stockage.texte(slug, "recherche.txt")
            nomListe = recherche.isEmpty ? slug : recherche
            nombreCibles = stockage.compterCibles(slug)
            // Ceux qui ont répondu **au dernier tour**, et non tout l'historique.
            // L'historique accumule tout ce qui a jamais répondu, y compris les
            // adresses des versions précédentes de la liste : il annonçait
            // « 1000 dans la liste · 2051 répondent au ping », soit deux fois
            // plus de répondants que d'adresses interrogées. Et comme la
            // soustraction devenait négative, le nombre de muets restait à zéro.
            nombreSuivis = stockage.compterRepondants(slug)
            nombreRelevés = stockage.meta(slug).tours
            // Le plus récent des deux : la liste affichée et la liste suivie
            // ont chacune leur cadence, et rien ne dit laquelle a tourné en
            // dernier.
            let bornes = [stockage.meta(slug).dernier,
                          stockage.meta(Surveillance.slug).dernier]
            dernierReleve = bornes.compactMap { $0.flatMap(Tour.date) }.max()
            derniersTours = Set(bornes.compactMap(\.self))
            slugCharge = slug
            dateChargee = date
        }
        // Ces quelques-uns sont minuscules et l'app les écrit elle-même :
        // toujours relus. Les adresses suivies en font partie — elles se
        // comptent sur les doigts, et les tenir hors de la garde évite d'avoir
        // à prévoir chaque écriture qui pourrait les changer.
        verdicts = stockage.verdicts()
        credits = stockage.credits()
        nombreListes = stockage.listerSlugs().count
        adressesSurveillees = stockage.cibles(Surveillance.slug)
        etatAgent = Agent.etat(dernierReleve: dernierReleve)
        recalculer()
        majSelection()   // les serveurs ont pu être remplacés sous la sélection
    }

    private var slugCharge: String?
    private var dateChargee: Date?

    // MARK: - Veille sur les écritures de l'agent

    private var veilles: [DispatchSourceFileSystemObject] = []
    private var slugVeille: String?
    private var rechargementDiffere: Task<Void, Never>?

    /// Un seul rechargement par rafale d'événements.
    ///
    /// Une écriture ne produit pas un réveil mais plusieurs : mesuré à **26
    /// réveils pour 4 enregistrements** sur le journal WAL de SQLite. Sans cet
    /// amortissement, l'app relirait tout six fois par tour. Un quart de seconde
    /// suffit à regrouper la rafale sans que le délai se remarque.
    private func rechargerBientot() {
        rechargementDiffere?.cancel()
        rechargementDiffere = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.recharger()
        }
    }

    /// Réagit aux écritures de l'agent au lieu de sonder toutes les trente
    /// secondes.
    ///
    /// **C'est le dépôt qui dit quoi surveiller** (`cibleDeVeille`), parce que
    /// la réponse dépend de la façon dont il écrit :
    ///
    /// - sur fichiers : **deux dossiers**, celui du profil pour l'historique et
    ///   la liste, la racine pour les crédits et les verdicts — le scanner
    ///   relève le solde *après* le tour, sans quoi il resterait figé. Des
    ///   dossiers et non des fichiers : l'écriture étant atomique, l'inode
    ///   change à chaque tour et une veille sur le fichier deviendrait aveugle.
    /// - sur base : le fichier **`-wal`**. Mesuré sur deux processus réels —
    ///   une veille sur le `.store` ou sur le dossier ne se déclenche *jamais*,
    ///   les écritures allant d'abord dans le journal.
    func surveillerRelevés() {
        let slug = stockage.slugActif() ?? ""
        guard slug != slugVeille || veilles.isEmpty else { return }
        veilles.forEach { $0.cancel() }
        veilles = stockage.cibleDeVeille.compactMap(veiller)
        slugVeille = slug
    }

    private func veiller(_ dossier: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(dossier.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rechargerBientot() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Rien de configuré : ni clé, ni liste. C'est l'état d'une session neuve —
    /// un autre utilisateur du Mac qui ouvre l'app partagée pour la première
    /// fois. Le trousseau et `Application Support` étant propres à chaque
    /// session, il ne récupère rien de celle d'à côté.
    var premiereOuverture: Bool { !cleConfiguree || nombreListes == 0 }

    // MARK: - Actions

    func copier(_ s: Serveur) {
        Presse.copier(s.adresse)
        message = String(localized: "Copied: \(s.adresse)")
    }

    /// Écrit, et **dit** si ça a échoué.
    ///
    /// Une écriture perdue en silence est le pire des cas : l'app continue
    /// d'afficher ce qu'elle croit avoir enregistré, et l'utilisateur ne
    /// découvre la perte qu'au lancement suivant. Le cœur traite déjà ses
    /// échecs (voir `Tour.executer`) ; l'app, elle, les avalait tous — six
    /// `try?` dont les verdicts d'essai, c'est-à-dire précisément ce que cette
    /// app existe pour ne jamais reperdre.
    /// `quoi` est une `LocalizedStringResource` et non un `String` : le
    /// compilateur reconnaît alors le littéral comme une clé et l'extrait, ce
    /// qu'un paramètre `String` empêchait — le nom de la chose écrite serait
    /// resté en français au milieu d'un message traduit.
    ///
    /// Le journal, lui, n'est **pas** traduit : un fichier de diagnostic doit
    /// dire la même chose chez tout le monde, sinon un rapport de bogue devient
    /// illisible pour qui ne parle pas la langue de son auteur.
    @discardableResult
    private func enregistrer(_ quoi: LocalizedStringResource, _ ecrire: () throws -> Void) -> Bool {
        do {
            try ecrire()
            return true
        } catch {
            let nom = String(localized: quoi)
            message = String(localized: "⚠︎ \(nom): could not be saved — \(error.localizedDescription)")
            stockage.journal("[app] \(quoi.key): write failed — \(error)",
                             horodatage: Tour.horodatage())
            return false
        }
    }

    // MARK: Annuler / rétablir
    //
    // Deux piles, comme partout ailleurs sur macOS : ⌘Z remonte le fil marquage
    // par marquage, ⇧⌘Z redescend. Un seul cran d'annulation, ce que faisait la
    // version précédente, n'est le standard nulle part.

    /// **Celui de la fenêtre**, fourni par `@Environment(\.undoManager)` et posé
    /// ici par `VueClassement`. Surtout pas un exemplaire à nous.
    ///
    /// L'app en possédait un, et le menu Édition était remplacé pour le
    /// piloter. Conséquence : ⌘Z étant un raccourci de menu, il était consulté
    /// **avant** la chaîne des répondeurs — donc taper dans un champ de texte
    /// puis ⌘Z annulait un marquage au lieu de la frappe. En passant par le
    /// gestionnaire de la fenêtre et en laissant le menu système en place,
    /// c'est AppKit qui arbitre : au champ de texte quand il a le focus, à
    /// nous sinon. C'est ça, le mécanisme standard — pas le remplacement du
    /// groupe de menu, qui n'en est que l'outil de dernier recours.
    var annulation: UndoManager?

    /// Un serveur qu'on surveille ne se marque pas.
    ///
    /// Les deux informations partagent désormais une colonne, et la
    /// surveillance y prime : marquer un serveur suivi poserait un verdict que
    /// rien n'afficherait. Surtout, la question ne se pose pas — une adresse
    /// qu'on a tapée soi-même, on sait déjà ce qu'on en pense, c'est pour ça
    /// qu'on l'a ajoutée.
    ///
    /// Le verdict n'est pas EFFACÉ pour autant, seulement inaccessible : les
    /// marques sont rangées par adresse et non par liste, donc celle d'un
    /// serveur déjà noté avant sa mise sous surveillance revient telle quelle
    /// dès qu'on cesse de le suivre.
    var selectionMarquable: Bool {
        guard let s = serveurSelectionne else { return false }
        return !epingles.contains(s.adresse)
    }

    func marquer(_ verdict: Marque?) {
        guard let s = serveurSelectionne else { return }
        // Le garde vaut pour tous les chemins : la barre du bas, le menu
        // Serveur et ses raccourcis grisent déjà le geste, mais un raccourci
        // système peut arriver sans être passé par eux.
        guard !epingles.contains(s.adresse) else {
            message = String(localized: "\(s.adresse) is a watched server — it is not marked.")
            return
        }
        // En cas d'échec, le message d'erreur est déjà posé : ne pas le
        // recouvrir par une confirmation qui serait un mensonge.
        guard changerMarque(s.adresse, verdict) else { return }
        let mot = Modele.motPour(verdict)
        message = String(localized: "\(s.adresse) — \(mot)   ·   ⌘Z to undo")
    }

    /// Les trois états d'un serveur essayé, en un seul endroit : ils servent au
    /// message de marquage **et** à celui de l'annulation, qui divergeaient.
    private static func motPour(_ verdict: Marque?) -> String {
        switch verdict {
        case .reussi: return String(localized: "✓ worked")
        case .rate:   return String(localized: "✗ failed")
        case nil:     return String(localized: "mark cleared")
        }
    }

    @discardableResult
    private func changerMarque(_ adresse: String, _ nouveau: Marque?) -> Bool {
        let precedent = verdicts[adresse]?.verdict
        annulation?.registerUndo(withTarget: self) { modele in
            guard modele.changerMarque(adresse, precedent) else { return }
            modele.selection = adresse
            let retour = precedent.map(Modele.motPour) ?? String(localized: "no mark")
            modele.message = String(localized: "\(adresse) — back to \(retour)")
        }
        // macOS compose « Annuler … » / « Rétablir … » autour de ce nom, et
        // traduit lui-même les deux verbes : seul le complément est à nous.
        annulation?.setActionName(String(localized: "marking"))
        return appliquerMarque(adresse, nouveau)
    }

    @discardableResult
    private func appliquerMarque(_ adresse: String, _ verdict: Marque?) -> Bool {
        if let verdict {
            verdicts[adresse] = Verdict(verdict: verdict, date: Tour.horodatage())
        } else {
            verdicts.removeValue(forKey: adresse)
        }
        let ecrit = enregistrer("the mark") { try stockage.ecrireVerdicts(verdicts) }
        // `recharger` relit le disque : si l'écriture a échoué, l'affichage
        // revient de lui-même à l'état réel plutôt que de montrer une marque
        // qui n'existe nulle part.
        recharger()
        return ecrit
    }

    func enregistrerFiltres() {
        enregistrer("the filters") { try stockage.ecrireFiltres(filtres) }
        // `force`, et c'est indispensable : la relecture de `recharger` est
        // gardée par « le slug ou la date ont-ils changé », et un basculement
        // de filtre ne touche ni l'un ni l'autre. Sans forcer, `tousServeurs`
        // restait donc l'ensemble déjà RESTREINT par les filtres précédents.
        //
        // Le symptôme était asymétrique, ce qui le rendait difficile à lire :
        // allumer un filtre marchait — restreindre un ensemble déjà en mémoire
        // ne demande rien de plus — mais l'éteindre ne faisait rien, puisque
        // les serveurs à réadmettre n'avaient jamais été chargés. L'en-tête
        // affichait le même compte dans les deux états.
        //
        // Le surcoût est celui que le commentaire de `recharger` chiffre déjà :
        // 15 ms de requête, contre 231 ms si l'on chargeait tout pour filtrer
        // en mémoire.
        recharger(force: true)
    }

    func reinitialiserFiltres() {
        filtres = Filtres()
        enregistrerFiltres()
    }

    /// Redemande à launchd où en est l'agent.
    ///
    /// ⚠️ Indispensable, et découvert à l'usage : l'état n'était relu que dans
    /// `recharger`, donc au réveil de la boucle — cinq minutes — ou quand
    /// l'agent écrivait un relevé. Or le cas où l'état change SANS que l'app y
    /// soit pour rien est précisément celui où l'agent s'arrête : l'utilisateur
    /// retire l'autorisation dans Réglages Système ▸ Ouverture et extensions,
    /// et plus rien n'écrit. Les deux témoins se taisaient donc en même temps,
    /// et la case des réglages restait allumée devant une surveillance morte.
    ///
    /// C'est un appel système : à demander sur un geste — l'ouverture du volet,
    /// le retour au premier plan — et jamais depuis le corps d'une vue.
    func relireEtatAgent() { etatAgent = Agent.etat(dernierReleve: dernierReleve) }

    /// Enregistre l'agent s'il ne l'a jamais été, et se tait sinon.
    ///
    /// Remplace la bascule que portaient la case des réglages et une entrée de
    /// menu. Les deux disaient la même chose, et aucune n'était le bon endroit :
    /// arrêter la surveillance d'une app qui ne fait que ça n'est pas un
    /// réglage d'app, c'est une permission — et macOS a déjà le volet qui les
    /// tient toutes.
    ///
    /// Le refus est MONTRÉ, comme il l'était : `Agent.demarrer()` avalait
    /// l'échec dans un `NSLog` que personne ne lit. Le cas courant est l'app
    /// lancée depuis un `.dmg`, où aucun agent ne survivrait.
    func installerAgentSiJamaisFait() {
        // ⚠️ `.introuvable` compte AUSSI, et ce n'est pas de la générosité :
        // c'est l'état constaté après un `sfltool resetbtm`, qui vide la base
        // des éléments d'ouverture. Le plist est toujours dans le paquet, mais
        // le système ne connaît plus aucun service à ce nom — et l'app, qui ne
        // rattrapait que `.arretee`, restait sur « agent introuvable » à chaque
        // relance. Il fallait le réenregistrer en ligne de commande.
        //
        // Réessayer ne coûte rien dans le cas où le plist manque vraiment d'un
        // paquet mal construit : `register()` échoue, l'état ne bouge pas, et
        // rien n'est demandé à l'utilisateur. Ce qu'on ne veut surtout pas
        // rattraper, c'est `.attenteAutorisation` — là, macOS reposerait sa
        // question à chaque lancement, par-dessus un refus explicite.
        //
        // `.enPanne` n'est pas rattrapable non plus, et c'est délibéré : on a
        // mesuré que réenregistrer depuis l'app ne relance pas un service que
        // launchd a abandonné. Le seul geste qui marche est celui que
        // `Etat.remede` demande à l'utilisateur.
        let etat = Agent.etat(dernierReleve: dernierReleve)
        guard Agent.etatsRattrapables.contains(etat) else {
            etatAgent = etat
            return
        }
        if let probleme = Agent.demarrer() { message = "⚠︎ " + probleme }
        etatAgent = Agent.etat(dernierReleve: dernierReleve)
    }

    /// L'app tourne-t-elle d'un endroit où la surveillance survivra ?
    ///
    /// Le cas courant chez quelqu'un qui vient de télécharger l'app : macOS
    /// l'exécute depuis une copie éphémère, et tout agent enregistré depuis là
    /// mourrait à la fermeture. Voir `Emplacement`.
    var avertissementEmplacement: String? { Emplacement.explication }
    var emplacementBloquant: Bool { Emplacement.estBloquant }

    /// L'avertissement à porter en tête du classement, ou `nil` si tout va bien.
    ///
    /// Deux situations seulement méritent d'interrompre la lecture : l'app
    /// tourne d'un endroit d'où la surveillance ne survivrait pas, et la
    /// surveillance ne tourne plus du tout. Les autres états s'expliquent très
    /// bien dans les réglages, là où l'on va quand on se pose la question ;
    /// celui-ci doit trouver quelqu'un qui, précisément, ne se la pose pas.
    var alerteEnTete: String? {
        if emplacementBloquant { return avertissementEmplacement }
        return etatAgent.remede
    }

    /// Relevé immédiat, sans attendre l'agent.
    func releverMaintenant() async {
        guard !chargement else { return }
        chargement = true
        message = String(localized: "Scanning…")
        let st = stockage
        let bilan = await Task.detached { await Tour.executer(st) }.value
        chargement = false
        message = bilan.map { String(localized: "Scan finished: \($0.resume)") }
            ?? String(localized: "Scan failed.")
        recharger()
    }

    /// Explication affichée quand le tableau est vide : nomme les filtres fautifs.
    var messageVide: String {
        if nombreListes == 0 {
            // Deux phrases très courtes : le bouton « Ouvrir les réglages »
            // est juste dessous, dans le même composant, et dit déjà le geste.
            return cleConfiguree
                ? String(localized: "No server list yet.")
                : String(localized: "Shodan API key missing")
        }
        if !recherche.trimmingCharacters(in: .whitespaces).isEmpty && !tousServeurs.isEmpty {
            return String(localized: "No server matches this search.")
        }
        if tousServeurs.isEmpty {
            return String(localized: """
                None of the \(nombreCibles) servers in the list answered the ping.
                They were online the last time Shodan passed by, but no longer — \
                or they are not reachable Java servers (port 25565).
                """)
        }
        // Ici, et seulement ici, il faut l'ensemble complet : dire quel filtre
        // écarte quoi n'a aucun sens sur une liste déjà filtrée. C'est le seul
        // chargement intégral qui reste, et il n'a lieu que sur un tableau vide.
        let tous = Array(stockage.historique(stockage.slugActif() ?? "").serveurs.values)
        let coupables = Selection(filtres: filtres, verdicts: verdicts,
                                  derniersTours: derniersTours).coupables(tous)
        guard !coupables.isEmpty else {
            return String(localized: "No server to show, although \(tousServeurs.count) answer.")
        }
        let noms = coupables
            .map { String(localized: "\(String(localized: $0.libelle)) — \($0.ecarte) excluded") }
            .joined(separator: "   ;   ")
        return String(localized: """
            No server passes the filters (out of \(tous.count) answering).
            Filters responsible:   \(noms)
            """)
    }
}

// MARK: - Petits services

enum Presse {
    static func copier(_ texte: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texte, forType: .string)
        #endif
    }
}

/// Import de la clé laissée par le CLI Shodan, **à la demande de l'utilisateur**.
///
/// C'est le remplaçant de la lecture automatique de `~/.config/shodan/api_key`,
/// et la différence n'est pas cosmétique. En bac à sable, l'app n'a aucun droit
/// sur ce fichier ; c'est le **sélecteur système** — qui tourne dans un autre
/// processus, hors du bac à sable — qui le lui accorde, et seulement sur le
/// fichier désigné. L'app ne peut donc rien lire que l'utilisateur n'ait montré
/// du doigt. Même service qu'avant, sans le prélèvement silencieux.
///
/// `showsHiddenFiles` est indispensable : `.config` commence par un point, et
/// sans ce réglage le dossier s'ouvrirait vide, ce qui donnerait l'impression
/// que la clé n'existe pas.
enum ImportCLI {

    /// Rend le contenu du fichier choisi, ou `nil` si l'utilisateur renonce.
    @MainActor
    static func choisirFichierCle() -> String? {
        #if canImport(AppKit)
        let panneau = NSOpenPanel()
        panneau.message = String(localized: "Choose the “api_key” file left by “shodan init”.")
        panneau.prompt = String(localized: "Import")
        panneau.canChooseFiles = true
        panneau.canChooseDirectories = false
        panneau.allowsMultipleSelection = false
        panneau.showsHiddenFiles = true
        panneau.directoryURL = Shodan.dossierCleDuCLI

        guard panneau.runModal() == .OK, let url = panneau.url,
              let brut = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let cle = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        return cle.isEmpty ? nil : cle
        #else
        return nil
        #endif
    }
}

enum Resume {
    /// Résumé lisible des filtres actifs, pour l'en-tête.
    static func filtres(_ c: Filtres) -> String {
        var bouts = [String(localized: "peak ≥ \(c.picMin)")]
        if c.picMax > 0 { bouts.append(String(localized: "peak ≤ \(c.picMax)")) }
        bouts.append(c.slotsMax > 0 ? String(localized: "≤ \(c.slotsMax) slots")
                                    : String(localized: "any size"))
        if c.regularite > 0 {
            bouts.append(String(localized: "populated ≥ \(c.regularite) % of the time"))
        }
        if c.sansProxy { bouts.append(String(localized: "no networks")) }
        if c.sansPub { bouts.append(String(localized: "no ads")) }
        if c.masquerWhitelist { bouts.append(String(localized: "no whitelists")) }
        if c.motdParDefautSeulement { bouts.append(String(localized: "default MOTD")) }
        if c.residentielSeulement { bouts.append(String(localized: "home connections")) }
        if c.masquerMuets { bouts.append(String(localized: "answered last scan")) }
        if c.masquerRates { bouts.append(String(localized: "without ✗")) }
        if c.masquerReussis { bouts.append(String(localized: "without ✓")) }
        return bouts.joined(separator: " · ")
    }
}

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Recherche Shodan et exploration

extension Modele {

    /// À appeler après avoir écrit une clé. Le retrait, lui, met la valeur à
    /// jour tout seul — c'est `oublierCle` qui l'efface.
    func relireEtatCle() { cleConfiguree = Cle.courante() != nil }

    /// Force un relevé du solde — l'intervalle normal est d'une heure. Après un
    /// changement de clé, le compte affiché doit être le nouveau immédiatement,
    /// sinon on montre celui de l'ancienne pendant une heure.
    func rafraichirCredits() async {
        credits = await Solde.relever(stockage, cle: Cle.courante(), intervalleMinutes: 0)
    }

    func oublierCle() async {
        await Cle.effacer()
        cleConfiguree = false
        credits = Credits()
        // Sans ça, le solde de l'ancienne clé resterait sur le disque et
        // reviendrait au prochain lancement, alors que la clé est partie.
        enregistrer("the credit balance reset") { try stockage.ecrireCredits(credits) }
    }

    /// Trois valeurs par liste : un nom, un nombre de cibles, un nombre de
    /// tours. Passer par `profil()` les obtenait en matérialisant TOUS les
    /// serveurs et TOUTES les cibles de chaque liste — le sélecteur figeait
    /// l'onglet Search une seconde, et d'autant plus longtemps que
    /// l'historique grossissait. Le dépôt sait compter sans charger : c'est
    /// exactement à ça que servent `compterCibles` et `meta`.
    func chargerProfils() -> [(slug: String, libelle: String, actif: Bool)] {
        let courant = stockage.slugActif()
        return stockage.listerSlugs().map { slug in
            let recherche = stockage.texte(slug, "recherche.txt")
            let nom = recherche.isEmpty ? slug : recherche
            let libelle = String(localized: """
                \(nom) · \(stockage.compterCibles(slug)) servers · \
                \(stockage.meta(slug).tours) scans
                """)
            return (slug, libelle, slug == courant)
        }
    }

    /// Rend `false` si le changement n'a pas pu être enregistré — à l'appelant
    /// de remettre son sélecteur sur la liste réellement active, sans quoi
    /// l'interface annoncerait une bascule qui n'a pas eu lieu.
    /// Supprime une liste, et ne laisse jamais l'app sans liste active.
    ///
    /// Ce que la suppression emporte est décidé par le schéma, pas ici : les
    /// serveurs et les cibles du profil partent en cascade, les verdicts NON —
    /// ils sont rangés à la racine, par adresse, parce qu'un serveur reste le
    /// même d'une recherche à l'autre. On ne rejugera donc pas une porte déjà
    /// trouvée fermée sous prétexte qu'on a jeté la liste où on l'avait vue.
    ///
    /// Rend le slug devenu actif, ou `nil` si le dépôt a refusé l'écriture.
    @discardableResult
    func supprimerProfil(_ slug: String) -> String? {
        guard enregistrer("the list deletion", { try stockage.supprimerProfil(slug) })
        else { return nil }
        // Supprimer la liste active laisserait l'app pointer sur un slug qui
        // n'existe plus : le classement se viderait sans explication et la
        // veille écouterait un dossier disparu. On bascule donc sur la première
        // liste restante, s'il en reste une.
        let restantes = stockage.listerSlugs()
        if stockage.slugActif() == nil || !restantes.contains(stockage.slugActif() ?? "") {
            if let reprise = restantes.first {
                _ = enregistrer("the list change", { try stockage.definirActif(reprise) })
            }
        }
        recharger()
        surveillerRelevés()
        return stockage.slugActif()
    }

    @discardableResult
    func activerProfil(_ slug: String) -> Bool {
        // C'était le pire des six : `recharger()` relit le slug depuis le
        // disque, donc une écriture ratée faisait réafficher l'ANCIENNE liste,
        // sans un mot. On cliquait, et rien ne se passait.
        guard enregistrer("the list change", { try stockage.definirActif(slug) })
        else { return false }
        recharger()
        // La veille suit la liste active : sans ça, l'app continuerait d'écouter
        // le dossier de l'ancienne.
        surveillerRelevés()
        return true
    }
}

// MARK: - Les serveurs qu'on a choisis soi-même

extension Modele {

    /// Ce qu'a donné une tentative d'ajout.
    ///
    /// Quatre issues, et la distinction entre les deux dernières est tout
    /// l'intérêt : « ça ne peut désigner aucun hôte » et « ça n'a pas répondu »
    /// ne demandent pas la même réponse à l'utilisateur. La première est une
    /// faute de frappe, la seconde est peut-être le serveur d'un ami, éteint —
    /// et c'est justement celui qu'on veut surveiller pour savoir quand il
    /// revient.
    enum Ajout: Equatable {
        case ajoute(String)
        case deja(String)
        case refuse(Surveillance.Refus)
        case muet(Surveillance.Adresse)
        /// L'adresse était bonne, le serveur a répondu, et l'enregistrement a
        /// échoué quand même. Annoncer « Now watching … » dans ce cas était un
        /// mensonge : rien n'avait été écrit, et rien ne serait interrogé.
        case echec
    }

    /// Lit une saisie, vérifie qu'un serveur répond, et l'ajoute.
    ///
    /// La vérification est un vrai ping : rien ne prouve mieux qu'une adresse
    /// désigne un serveur Minecraft que sa réponse au Server List Ping. Aucune
    /// liste blanche, aucune heuristique sur le nom — et aucun crédit dépensé,
    /// puisque c'est du TCP direct.
    func ajouterSurveillance(_ saisie: String, malgreLeSilence: Bool = false) async -> Ajout {
        let adresse: Surveillance.Adresse
        switch Surveillance.lire(saisie) {
        case .failure(let r): return .refuse(r)
        case .success(let a): adresse = a
        }

        let existantes = adressesSurveillees
        guard !existantes.contains(where: { $0.adresse == adresse.cible.adresse }) else {
            return .deja(adresse.texte)
        }

        if !malgreLeSilence {
            // Un délai plus long qu'à l'ordinaire : ici l'utilisateur ATTEND
            // la réponse devant son écran, et une seule adresse est en jeu. Le
            // tour de mille cibles, lui, ne peut pas se le permettre.
            let sonde = await Ping.interroger(adresse.cible, delai: 5)
            guard sonde != nil else { return .muet(adresse) }
        }

        guard enregistrer("the watched servers", {
            try stockage.ecrireCibles(Surveillance.slug, existantes + [adresse.cible])
        }) else { return .echec }
        // Relevé immédiat de la liste surveillée — elle seule, jamais la
        // recherche : celle-ci compte mille adresses et n'a rien demandé.
        //
        // Il redemande à l'instant ce que la vérification vient d'obtenir, et
        // c'est voulu : c'est `Tour` qui sait fusionner un relevé dans un
        // historique, en tenir les pics et la régularité. Un second ping sur
        // une seule adresse coûte moins que de redire ce travail ici, et
        // n'arrive qu'au clic sur « Add ».
        let depot = stockage
        _ = await Task.detached { await Tour.tourner(depot, Surveillance.slug) }.value
        recharger(force: true)
        return .ajoute(adresse.texte)
    }

    /// Une adresse à la fois : chaque ligne du formulaire porte son propre
    /// bouton, il n'y a plus de sélection à retirer en bloc.
    ///
    /// **Deux écritures, et les deux sont nécessaires.** Retirer l'adresse de
    /// la liste suffit à ne plus l'interroger, mais pas à la faire disparaître :
    /// c'est l'HISTORIQUE que `recharger` lit pour épingler les serveurs suivis
    /// au tableau. Sans l'oubli qui suit, le serveur y restait épinglé
    /// définitivement, et plus aucune ligne des réglages ne permettait de l'en
    /// sortir.
    @discardableResult
    func retirerSurveillance(_ adresse: String) -> Bool {
        let reste = adressesSurveillees.filter { $0.adresse != adresse }
        guard enregistrer("the watched servers", {
            try stockage.ecrireCibles(Surveillance.slug, reste)
            try stockage.oublierServeur(Surveillance.slug, adresse)
        }) else { return false }
        recharger(force: true)
        return true
    }

    // MARK: Réglages

    /// Change UN réglage, et ne recharge que si l'affichage en dépend.
    ///
    /// **La mutation part de ce qui est sur le disque**, jamais de ce que
    /// l'appelant croit savoir. Une vue qui recomposait la valeur entière —
    /// « prends les réglages, change la cadence, réécris le tout » — réécrivait
    /// aussi les champs qu'elle n'avait pas voulu toucher, avec l'état qu'elle
    /// avait en main. C'est le mode de panne classique du lire-modifier-écrire,
    /// et il ne se voit qu'après coup, sur un réglage revenu tout seul à sa
    /// valeur d'usine.
    ///
    /// Les deux cadences ne disent qu'à l'agent quand se réveiller : rien de ce
    /// qui est à l'écran n'en dépend. Elles déclenchaient pourtant un
    /// `recharger(force:)` complet — relecture de la liste, refiltrage,
    /// recalcul du classement, révision de la sélection — à chaque cran du
    /// menu. Seule la portée des filtres change ce que le tableau montre.
    @discardableResult
    func modifierReglagesSurveillance(_ changer: (inout ReglagesSurveillance) -> Void) -> Bool {
        let avant = stockage.reglagesSurveillance()
        var apres = avant
        changer(&apres)
        guard apres != avant else { return true }
        guard enregistrer("the monitoring settings", {
            try stockage.ecrireReglagesSurveillance(apres)
        }) else { return false }
        reglagesSurveillance = apres
        if apres.filtrerSurveillance != avant.filtrerSurveillance { recharger(force: true) }
        return true
    }
}
