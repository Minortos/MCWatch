// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ServiceManagement

/// Le relevé automatique, confié à `SMAppService`.
///
/// **Pourquoi ce retour à l'API officielle.** `SMAppService` avait été
/// abandonnée le 2026-08-11 après deux arrêts silencieux de la surveillance :
/// launchd épingle une « Lightweight Code Requirement » sur le paquet, et une
/// app signée **ad-hoc** n'a pas d'identité stable dont dériver cette exigence.
/// launchd enregistrait alors une liste d'empreintes vide
/// (`"cdhash" => {"$in" => [0 = ]}`), que rien ne pouvait satisfaire : le
/// processus était tué au démarrage (`OS_REASON_CODESIGNING`).
///
/// Depuis, l'app est signée avec un vrai certificat de développement, et son
/// exigence désignée porte sur le **certificat**, non sur l'empreinte :
///
///     identifier "com.minortos.mcwatch.app" and anchor apple generic
///       and certificate leaf[subject.CN] = "Apple Development: …"
///
/// Elle est donc **stable d'une recompilation à l'autre**, et la cause du
/// blocage a disparu.
///
/// ⚠️⚠️ **L'ÉTIQUETTE CI-DESSOUS NE DOIT PLUS JAMAIS CHANGER APRÈS PUBLICATION.**
///
/// Mesuré le 2026-08-13, en changeant l'identifiant de signature du scanner :
/// BTM conserve un enregistrement **persistant, indexé par l'étiquette**, dans
/// lequel il fige l'identité de code observée à la PREMIÈRE inscription — ici
/// `"signing-identifier" => "MCWatchScan"`. Il ne la redérive jamais ensuite.
/// Ni `unregister()`, ni `launchctl bootout`, ni l'incrémentation de
/// `CFBundleVersion` ne le font oublier : `sfltool dumpbtm` montrait toujours
/// la même entrée (même UUID, génération 329). L'exigence épinglée ne
/// correspondait donc plus au binaire, et launchd le tuait au lancement —
/// `OS_REASON_CODESIGNING`, `job state = spawn failed`.
///
/// Sur une machine neuve le problème n'existe pas : l'identité est dérivée
/// correctement du premier coup. C'est donc un piège de MISE À JOUR, et le seul
/// remède connu est une étiquette neuve — ce qui, chez un utilisateur qui a déjà
/// l'app, laisse l'ancien enregistrement orphelin.
///
/// Conséquence pratique : l'identifiant de signature du scanner et cette
/// étiquette forment un couple figé. Les toucher casse la surveillance de tous
/// ceux qui ont déjà installé l'app.
///
/// (L'incrémentation de `CFBundleVersion` par `construire.sh` reste utile —
/// BTM met bien à jour `parent bundle version` — mais elle ne suffit PAS à
/// rafraîchir l'exigence de code. L'avertissement précédent la disait porteuse
/// pour cette raison ; c'est faux, et ça a coûté un agent mort.)
///
/// Le plist vit dans le paquet (`Contents/Library/LaunchAgents/`) et pointe le
/// scanner par `BundleProgram`, chemin relatif au paquet : l'agent ne dépend
/// d'aucun binaire extérieur, et il suit l'app si elle est déplacée.
public enum Agent {

    public static let etiquette = "com.minortos.mcwatch.surveillance"

    static var service: SMAppService { SMAppService.agent(plistName: "\(etiquette).plist") }

    // MARK: - État

    /// Où en est la surveillance, en **une** valeur.
    ///
    /// Une chaîne était rendue ici auparavant, et l'interface ne pouvait donc
    /// rien en faire d'autre que l'afficher : impossible de griser une cadence
    /// parce que rien ne tourne, ou de proposer les Réglages Système parce que
    /// macOS attend une autorisation. Un cas énuméré se teste ; une phrase, non.
    ///
    /// Le libellé reste ici, à côté de l'état qu'il nomme, et ce sont les mêmes
    /// phrases qu'avant — donc les mêmes clés, donc les traductions déjà faites.
    public enum Etat: Sendable, Equatable, Hashable {
        case active
        case arretee
        /// macOS attend que l'utilisateur autorise l'ouverture au démarrage.
        case attenteAutorisation
        /// Le plist n'est pas dans le paquet — build incomplet.
        case introuvable
        /// L'app s'exécute d'un endroit d'où aucun agent ne survivrait.
        case impossible
        /// Enregistré, mais plus rien ne tourne depuis la date portée.
        ///
        /// Le seul état que `SMAppService` ne sait pas rendre : il répond sur
        /// l'ENREGISTREMENT, jamais sur l'exécution. Voir `enPanne(…)`.
        case enPanne(depuis: Date)
        case inconnu

        public var libelle: String {
            switch self {
            case .active:              String(localized: "Monitoring active")
            case .arretee:             String(localized: "Monitoring stopped")
            case .attenteAutorisation: String(localized: "Monitoring awaiting approval")
            case .introuvable:         String(localized: "Agent not found in the bundle")
            case .impossible:          String(localized: "Monitoring impossible from here")
            case .enPanne:             String(localized: "Monitoring not responding")
            case .inconnu:             String(localized: "Monitoring in an unknown state")
            }
        }

        /// Le geste qui répare, quand il y en a un — et il n'y en a qu'un ici.
        ///
        /// Ce texte vit avec l'état plutôt que dans une vue parce que **deux**
        /// vues le montrent : le classement, où l'utilisateur passe, et les
        /// réglages, où il ne va que s'il a un doute. Les autres cas gardent
        /// leur phrase dans `VueSurveillance` — ils n'ont qu'un lieu d'affichage.
        ///
        /// ⚠️ Couper puis rallumer l'interrupteur des Réglages Système est la
        /// seule manœuvre mesurée qui remette la surveillance en marche : elle
        /// recrée le service launchd sans toucher à l'enregistrement BTM ni à
        /// l'exigence de code qui y est figée. Ni `lsregister`, ni
        /// `launchctl kickstart` n'y parviennent, et réenregistrer depuis l'app
        /// ne suffit pas non plus.
        public var remede: String? {
            guard case .enPanne(let depuis) = self else { return nil }
            let quand = depuis.formatted(date: .abbreviated, time: .shortened)
            return String(localized: """
                No scan since \(quand). In System Settings ▸ General ▸ Login \
                Items & Extensions, switch MC Watch off and back on.
                """)
        }
    }

    /// Les états depuis lesquels l'app a le droit de (ré)enregistrer l'agent.
    ///
    /// ⚠️ `.attenteAutorisation` n'en fait PAS partie, et c'est tout l'enjeu :
    /// cet état est un refus de l'utilisateur, posé dans Réglages Système.
    /// Le rattraper reposerait la question de macOS à chaque lancement, et
    /// `register()` échouerait de toute façon — mesuré, « Operation not
    /// permitted ».
    ///
    /// `.introuvable` en fait partie, et il y est entré à la dure : après un
    /// `sfltool resetbtm` suivi d'un REDÉMARRAGE, le système ne connaît plus
    /// aucun service à ce nom alors que le plist est toujours dans le paquet.
    /// L'app affichait « agent introuvable » à chaque lancement sans jamais
    /// se réparer ; il fallait la ligne de commande.
    public static let etatsRattrapables: Set<Etat> = [.arretee, .introuvable]

    /// Combien de réveils manqués avant de déclarer la surveillance en panne.
    ///
    /// Deux décriraient déjà la panne mesurée — launchd renonce après deux
    /// échecs — mais un relevé peut sauter son tour pour des raisons bénignes.
    /// Trois laissent une demi-heure de marge.
    static let reveilsAvantPanne = 3

    /// Plus rien ne tourne, quoi qu'en dise l'enregistrement.
    ///
    /// `SMAppService.status` répond sur l'ENREGISTREMENT, jamais sur
    /// l'exécution. Mesuré le 2026-08-27 : il rendait `.enabled` pendant que
    /// launchd avait renoncé à lancer le scanner — `EX_CONFIG`, `spawn failed`,
    /// puis plus une seule tentative en une heure. La seule preuve qu'une
    /// surveillance vit, c'est un relevé récent.
    ///
    /// ⚠️ `eveilDepuis` n'est pas une précaution décorative. Un Mac qui a dormi
    /// huit heures rouvre avec un dernier relevé vieux de huit heures sans que
    /// rien ne soit cassé, et launchd rattrape son retard dans la minute qui
    /// suit. `ProcessInfo.systemUptime` ne compte QUE le temps éveillé : au
    /// réveil il vaut moins que le seuil, donc aucune panne n'est déclarée.
    ///
    /// Sans aucun relevé, on ne conclut rien : une app fraîchement installée
    /// n'a pas encore de liste, et accuser une surveillance qui n'a jamais eu
    /// l'occasion de tourner serait faux.
    public static func estEnPanne(dernierReleve: Date?,
                                  maintenant: Date = Date(),
                                  eveilDepuis: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                  pas: Int = Surveillance.pas) -> Bool {
        guard let dernierReleve else { return false }
        let seuil = Double(pas * reveilsAvantPanne) * 60
        guard maintenant.timeIntervalSince(dernierReleve) > seuil else { return false }
        return eveilDepuis > seuil
    }

    /// ⚠️ Interroge launchd : c'est un **appel système**, pas la lecture d'un
    /// champ. À demander une fois et à retenir, jamais depuis le corps d'une
    /// vue SwiftUI — qui le rappellerait à chaque redessin.
    ///
    /// `dernierReleve` vient de la base et non de launchd, parce que le système
    /// ne sait pas répondre à la question qui compte. Omis, l'état rendu est
    /// celui de l'enregistrement seul — c'est ce que veulent les appelants qui
    /// n'ont pas encore chargé la base.
    public static func etat(dernierReleve: Date? = nil,
                            maintenant: Date = Date(),
                            eveilDepuis: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Etat {
        // L'emplacement passe AVANT le statut : une app translocalisée rendrait
        // « Surveillance arrêtée », ce qui est exact mais n'explique rien et
        // laisse croire qu'un clic suffirait à la relancer.
        if Emplacement.estBloquant { return .impossible }
        switch service.status {
        case .enabled:
            if let dernierReleve,
               estEnPanne(dernierReleve: dernierReleve, maintenant: maintenant,
                          eveilDepuis: eveilDepuis) {
                return .enPanne(depuis: dernierReleve)
            }
            return .active
        case .requiresApproval: return .attenteAutorisation
        case .notRegistered:    return .arretee
        case .notFound:         return .introuvable
        @unknown default:       return .inconnu
        }
    }

    public static var actif: Bool { service.status == .enabled }

    /// Ouvre le volet où macOS attend l'autorisation d'ouverture au démarrage.
    ///
    /// Sans ce chemin, l'état `.attenteAutorisation` serait un constat sans
    /// suite : la surveillance paraîtrait arrêtée, et rien ne dirait où aller
    /// la débloquer.
    public static func ouvrirReglagesOuverture() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Marche / arrêt

    /// Rend `nil` si tout s'est bien passé, sinon la raison **à montrer**.
    ///
    /// L'échec était auparavant avalé dans un `NSLog` que personne ne lit :
    /// on cliquait « Démarrer la surveillance », rien ne se passait, et aucune
    /// explication n'apparaissait nulle part.
    ///
    /// (Une `basculer()` vivait ici, appelée par une case et une entrée de menu
    /// qui ont disparu : l'app installe l'agent au premier lancement et ne
    /// l'éteint plus jamais elle-même. `arreter()` reste, pour le pilotage en
    /// ligne de commande — c'est un outil de dépannage, pas une interface.)
    @discardableResult
    public static func demarrer() -> String? {
        // Refus AVANT d'appeler `register()`. Enregistrer un agent qui pointe
        // vers une copie éphémère « réussit » — puis la surveillance meurt à la
        // fermeture de l'app, sans erreur et sans trace.
        if Emplacement.estBloquant, let probleme = Emplacement.explication {
            NSLog("MC Watch: monitoring refused — \(probleme)")
            return probleme
        }
        do { try service.register(); return nil }
        catch {
            NSLog("MC Watch: agent registration refused — \(error.localizedDescription)")
            return String(localized: """
                The agent could not be registered: \(error.localizedDescription)
                """)
        }
    }

    public static func arreter() {
        do { try service.unregister() }
        catch { NSLog("MC Watch: agent removal refused — \(error.localizedDescription)") }
    }
}

// L'app ne lance plus aucun processus externe.
//
// Il subsistait ici un `launchctl bootout` pour déloger l'agent que la version
// précédente écrivait elle-même dans `~/Library/LaunchAgents` — `SMAppService`
// ne sait pas retirer un enregistrement qu'elle n'a pas fait, et laisser les
// deux aurait fait tourner deux scanners. La migration ayant eu lieu et ce Mac
// n'ayant qu'une session, ce code n'avait plus rien à déloger.
//
// Rien non plus ne « reprend » l'agent au lancement : l'enregistrement persiste
// de lui-même, et le plist désigne le scanner par un chemin **relatif au
// paquet**, donc déplacer l'app ne le casse pas. Réenregistrer au démarrage
// rallumerait une surveillance que l'utilisateur a peut-être arrêtée exprès.
