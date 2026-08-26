// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Sparkle

/// Tout ce que l'app sait de ses propres mises à jour, en un seul objet.
///
/// Sparkle fait l'essentiel tout seul — il interroge l'appcast, compare les
/// versions, montre la fenêtre, télécharge, vérifie la signature, installe et
/// relance. Ce qui reste à écrire ici tient en deux choses : de quoi lui parler
/// depuis SwiftUI, et de quoi rendre son état visible dans l'interface.
///
/// L'objet est créé UNE fois, au lancement, et vit aussi longtemps que l'app.
/// Ce n'est pas un détail : `SPUStandardUpdaterController` démarre en même
/// temps le minuteur de la vérification planifiée. Le recréer à la demande —
/// dans une vue, par exemple — redémarrerait ce minuteur à chaque apparition,
/// et l'app finirait par sonder le dépôt bien plus souvent que la journée
/// annoncée par `SUScheduledCheckInterval`.
@Observable @MainActor
final class MiseAJour {
    /// Le contrôleur « clé en main » : l'updater et son interface standard.
    ///
    /// C'est cette interface-là qu'on veut, précisément parce qu'elle n'est pas
    /// la nôtre. La fenêtre de Sparkle est celle que ses utilisateurs ont déjà
    /// vue dans des dizaines d'apps, et elle est traduite en trente-cinq
    /// langues par des humains — dont le français et l'allemand, les deux
    /// langues que ce projet relit lui-même. Une fenêtre maison aurait été à
    /// écrire, à traduire, et surtout à faire reconnaître.
    @ObservationIgnored
    let controleur = SPUStandardUpdaterController(startingUpdater: true,
                                                 updaterDelegate: nil,
                                                 userDriverDelegate: nil)

    // ─── Le reflet des réglages de Sparkle ──────────────────────────────────
    //
    // Ces trois valeurs ne sont PAS une copie : Sparkle reste la seule source,
    // il les lit dans ses propres préférences à chaque décision qu'il prend, et
    // rien ici ne les enregistre. Ce sont des reflets, tenus à jour par KVO,
    // parce que `@Observable` ne voit pas les propriétés d'Objective-C et que
    // SwiftUI a besoin de savoir quand redessiner.
    //
    // Le reflet a un vrai travail à faire : ces réglages changent aussi SANS
    // nous. Au deuxième lancement, Sparkle demande lui-même à l'utilisateur
    // s'il doit vérifier automatiquement, et écrit la réponse. Une case qui
    // n'aurait été lue qu'à l'ouverture des réglages afficherait alors le
    // contraire de ce qui est vrai.

    /// Vrai quand une vérification est possible : ni déjà en cours, ni
    /// suspendue par une installation en attente.
    ///
    /// Sans cela, le menu resterait cliquable pendant qu'une vérification
    /// tourne, et les clics suivants ne feraient rien du tout — un bouton qui
    /// ne répond pas est pire qu'un bouton grisé, qui dit au moins pourquoi.
    private(set) var peutVerifier = false

    /// Chercher une mise à jour tout seul, une fois par jour.
    private(set) var verificationAutomatique = false

    /// Installer sans demander, plutôt que prévenir et attendre.
    private(set) var installationAutomatique = false

    /// Les observations KVO qui alimentent les reflets ci-dessus. Rangées
    /// ensemble : elles ont la même durée de vie que l'objet, et se libèrent
    /// avec lui.
    @ObservationIgnored
    private var ponts: [NSKeyValueObservation] = []

    init() {
        let updater = controleur.updater
        // `assumeIsolated` plutôt qu'un saut par `Task { @MainActor }` : depuis
        // la 2.9, `SPUUpdater` est annoté pour la concurrence et ses propriétés
        // sont isolées à l'acteur principal — le compilateur le dit lui-même si
        // l'on tente de les lire ailleurs. La notification arrive donc DÉJÀ sur
        // le bon acteur : on l'affirme, au lieu de repasser par une tâche qui
        // n'aurait fait que retarder d'un tour de boucle l'activation d'une
        // entrée de menu.
        //
        // `[weak self]` est porté par le rappel lui-même, et non par un bloc
        // intérieur : c'est le rappel qui capture `self`, et lui seul.
        ponts = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                MainActor.assumeIsolated { self?.peutVerifier = u.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                MainActor.assumeIsolated { self?.verificationAutomatique = u.automaticallyChecksForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] u, _ in
                MainActor.assumeIsolated { self?.installationAutomatique = u.automaticallyDownloadsUpdates }
            },
        ]
    }

    /// La vérification MANUELLE, celle du menu.
    ///
    /// Elle diffère de la vérification planifiée sur un point qui se voit :
    /// quand il n'y a rien de neuf, celle-ci le DIT. Une vérification demandée
    /// et restée sans réponse laisserait croire à une panne.
    func verifier() {
        controleur.updater.checkForUpdates()
    }

    // Les deux réglages s'écrivent par une méthode, et non par une propriété
    // que l'on pourrait affecter. C'est délibéré : écrire chez Sparkle et
    // relire ce qu'il a réellement retenu sont deux gestes, et le second n'est
    // pas une politesse. Sparkle peut refuser ou corriger une valeur — couper
    // la vérification automatique éteint aussi l'installation automatique, qui
    // n'aurait plus rien à installer. On relit donc les DEUX reflets après
    // chaque écriture, plutôt que d'afficher ce qu'on croyait avoir demandé.

    func definirVerificationAutomatique(_ actif: Bool) {
        controleur.updater.automaticallyChecksForUpdates = actif
        relireReflets()
    }

    func definirInstallationAutomatique(_ actif: Bool) {
        controleur.updater.automaticallyDownloadsUpdates = actif
        relireReflets()
    }

    private func relireReflets() {
        verificationAutomatique = controleur.updater.automaticallyChecksForUpdates
        installationAutomatique = controleur.updater.automaticallyDownloadsUpdates
    }

    /// La date de la dernière vérification, pour la dire dans les réglages.
    /// `nil` tant qu'aucune n'a eu lieu — l'app vient d'être installée.
    var derniereVerification: Date? {
        controleur.updater.lastUpdateCheckDate
    }
}
