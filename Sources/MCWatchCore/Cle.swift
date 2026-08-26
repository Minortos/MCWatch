// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

/// La clé API Shodan, rangée dans le trousseau plutôt qu'en clair.
///
/// Trousseau **classique** obligatoire, et la raison n'est pas celle qu'on
/// croit. Ce n'est plus l'identifiant d'équipe qui manque — l'app est signée
/// et en possède un. C'est que le trousseau moderne (« data protection »)
/// exige l'entitlement `keychain-access-groups`, lequel est **restreint** :
/// sans profil d'approvisionnement — donc sans compte développeur payant —
/// AMFI tue le processus au lancement. Mesuré : SIGKILL immédiat avec cet
/// entitlement, `errSecMissingEntitlement` (-34018) sans lui.
///
/// Le trousseau classique, lui, fonctionne parfaitement en bac à sable
/// (écriture et relecture vérifiées dans un conteneur). Conséquence connue :
/// après chaque recompilation la signature change, et macOS redemande
/// l'autorisation une fois. L'app ne doit donc jamais traiter un échec de
/// lecture comme fatal.
public enum Cle {

    static let service = "MC Watch — Shodan"
    static let compte = "api"

    static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: compte]
    }

    public static func lire() -> String? {
        var requete = base()
        requete[kSecReturnData as String] = true
        var sortie: CFTypeRef?
        guard SecItemCopyMatching(requete as CFDictionary, &sortie) == errSecSuccess,
              let d = sortie as? Data, let s = String(data: d, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    public static func enregistrer(_ cle: String) -> Bool {
        SecItemDelete(base() as CFDictionary)
        var ajout = base()
        ajout[kSecValueData as String] = Data(cle.utf8)
        return SecItemAdd(ajout as CFDictionary, nil) == errSecSuccess
    }

    /// Retire la clé du trousseau, **hors du fil principal**.
    ///
    /// ⚠️ `async` pour une seule raison, et elle est mesurée. `SecItemDelete`
    /// n'est pas une écriture isolée : il enchaîne plusieurs opérations
    /// internes, et chacune vérifie sur quel fil elle tourne. Appelé depuis
    /// l'interface, ce seul appel faisait émettre à Security.framework DOUZE
    /// fautes en quatre millisecondes — « This method should not be called on
    /// the main thread as it may lead to UI unresponsiveness », relevées dans
    /// Console sous `com.apple.runtime-issues`, catégorie Security, toutes au
    /// même point d'émission du framework.
    ///
    /// Réduire le nombre d'appels ne pouvait donc rien y faire : il n'y en
    /// avait qu'un. C'est l'endroit d'où on l'appelle qui compte.
    ///
    /// Les autres accès au trousseau restent synchrones à dessein : la lecture
    /// n'a lieu qu'au démarrage et après une écriture, et l'écriture suit déjà
    /// un aller-retour réseau vers Shodan — elle est de toute façon dans un
    /// contexte asynchrone.
    public static func effacer() async {
        await Task.detached(priority: .userInitiated) {
            // Le code de retour est ignoré à dessein : `errSecItemNotFound`
            // veut dire qu'il n'y avait rien à retirer, ce qui est exactement
            // l'état voulu. Il n'y a pas d'échec possible dont l'utilisateur
            // pourrait faire quoi que ce soit.
            _ = SecItemDelete(base() as CFDictionary)
        }.value
    }

    /// Clé utilisable : le trousseau, et rien d'autre.
    ///
    /// Cette fonction reprenait auparavant, en silence, le fichier laissé par
    /// `shodan init` (`~/.config/shodan/api_key`) et le recopiait dans le
    /// trousseau. Retiré pour deux raisons, dont la seconde est la vraie :
    ///
    /// 1. Le bac à sable rend ce chemin illisible, la reprise ne pouvait donc
    ///    plus aboutir de toute façon.
    /// 2. Surtout : livrée à des inconnus, cette commodité devenait une app qui
    ///    **aspire sans prévenir la clé API du CLI Shodan de l'utilisateur**.
    ///    Et comme `Modele.premiereOuverture` s'appuie sur cette fonction, elle
    ///    escamotait du même coup l'écran d'accueil — précisément chez les gens
    ///    qui connaissent Shodan, c'est-à-dire le public de l'app.
    ///
    /// Rien n'est perdu pour eux : l'accueil dit où trouver leur clé existante.
    public static func courante() -> String? { lire() }

    public enum Erreur: LocalizedError {
        case vide
        case trousseau

        public var errorDescription: String? {
            switch self {
            case .vide:      return String(localized: "No key entered.")
            case .trousseau: return String(localized: "The keychain refused to save the key.")
            }
        }
    }

    /// Vérifie une clé auprès de Shodan **avant** de l'enregistrer, puis rend le
    /// compte associé. `/api-info` est gratuit : rien n'est dépensé, et on ne
    /// range jamais une clé fausse que l'utilisateur croirait valide.
    @discardableResult
    public static func verifierEtEnregistrer(_ saisie: String) async throws -> Shodan.Infos {
        let cle = saisie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cle.isEmpty else { throw Erreur.vide }
        let infos = try await Shodan(cle: cle).infos()
        guard enregistrer(cle) else { throw Erreur.trousseau }
        return infos
    }

    /// Pour l'affichage : les extrémités suffisent à reconnaître sa clé, sans
    /// l'exposer à quelqu'un qui regarde l'écran.
    public static func masquer(_ cle: String) -> String {
        guard cle.count > 8 else { return String(repeating: "•", count: max(cle.count, 4)) }
        return cle.prefix(4) + String(repeating: "•", count: 12) + cle.suffix(4)
    }
}
