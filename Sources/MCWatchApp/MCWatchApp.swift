// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import MCWatchCore

@main
struct MCWatchApp: App {
    @State private var modele = Modele()
    // Créé ici, et nulle part ailleurs : cet objet démarre le minuteur de la
    // vérification planifiée, et doit donc vivre aussi longtemps que l'app.
    @State private var maj = MiseAJour()

    var body: some Scene {
        Window("MC Watch", id: "principale") {
            VueClassement(modele: modele)
                // La largeur vient du TABLEAU, pas d'un chiffre choisi.
                // Elle valait 900 en dur, et la colonne des épinglés — ajoutée
                // plus tard — l'a rendue trop étroite sans que rien ne le
                // signale : défilement horizontal, dernière colonne coupée,
                // coins arrondis de la sélection perdus. Voir
                // `VueClassement.Largeur`, qui la calcule et la tiendra à jour
                // toute seule à la prochaine colonne.
                .frame(minWidth: VueClassement.Largeur.fenetre, minHeight: 480)
                // ⚠️ `Table` REDIMENSIONNE ses colonnes avec la fenêtre : les
                // rétrécir toutes au plancher est un geste que macOS fait tout
                // seul, et le minimum n'a donc pas à réserver la place
                // confortable. Il la PROPOSE ici, à la première ouverture
                // seulement — ensuite c'est la taille mémorisée qui gagne.
                .sheet(isPresented: $modele.montrerBienvenue) { VueBienvenue(modele: modele) }
                .task {
                    // ─── L'agent s'installe tout seul, au premier lancement ──
                    //
                    // Surveiller des adresses EST le métier de l'app : sans
                    // agent elle ne fait rien entre deux ouvertures, et lui
                    // demander de l'allumer revenait à lui demander d'allumer
                    // le produit. Le seul interrupteur qui reste est celui du
                    // système, dans Réglages Système ▸ Ouverture et extensions.
                    //
                    // ⚠️ **Uniquement depuis `.arretee`**, et c'est toute la
                    // sûreté du geste. Cet état est celui d'un agent jamais
                    // enregistré ; une autorisation retirée par l'utilisateur
                    // donne `.attenteAutorisation`, jamais `.arretee`. On ne
                    // repasse donc jamais par-dessus son choix.
                    //
                    // Le rattraper serait de toute façon impossible : mesuré,
                    // `register()` sur un service interdit échoue par
                    // « Operation not permitted ». Mais sans ce test, l'app
                    // réessaierait à CHAQUE lancement, et macOS reposerait sa
                    // question à chaque fois.
                    modele.installerAgentSiJamaisFait()
                    modele.recharger()
                    // Décidé une seule fois, au démarrage : une session neuve
                    // (autre compte du Mac) n'a ni clé ni liste, et se
                    // retrouverait devant un tableau vide sans explication.
                    modele.montrerBienvenue = modele.premiereOuverture
                    modele.surveillerRelevés()
                    // Filet de sécurité, pas mécanisme principal : la veille
                    // sur le dossier fait le travail: si un événement se perdait
                    // — dossier recréé, volume remonté — cinq minutes suffisent
                    // à rattraper sans que l'app ait sondé pour rien entre-temps.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(300))
                        modele.surveillerRelevés()
                        modele.recharger()
                    }
                }
        }
        .defaultSize(width: VueClassement.Largeur.fenetreConfortable, height: 700)
        .commands { Menus(modele: modele, maj: maj) }

        Settings { VueReglages(modele: modele, maj: maj) }
    }
}

/// Ouvre le Finder sur le dossier de données de l'app.
///
/// Le dossier s'OUVRE plutôt qu'il ne se révèle : on veut voir ce qu'il
/// contient — la base, et les deux journaux — et non le désigner depuis son
/// parent. Le libellé ne dit pas « in Finder » : ouvrir un dossier ne peut
/// se faire nulle part ailleurs.
enum Reveler {
    static func dossier() {
        NSWorkspace.shared.open(Stockage.dossierModerne)
    }
}

struct Menus: Commands {
    let modele: Modele
    let maj: MiseAJour

    var body: some Commands {
        // « Check for Updates… » se place JUSTE SOUS « About MC Watch », avant
        // les Réglages. Ce n'est pas un goût : c'est la place que cette entrée
        // occupe dans à peu près toute app macOS distribuée hors de l'App
        // Store, et l'utilisateur qui la cherche la cherche là. `.appInfo` est
        // le groupe qui contient « À propos » ; s'ancrer dessus survit aux
        // réorganisations du menu par le système.
        //
        // Le libellé porte des points de suspension parce qu'il OUVRE quelque
        // chose — une fenêtre s'affiche, qu'il y ait du neuf ou non. C'est la
        // règle des menus macOS, et Sparkle la respecte des deux côtés : la
        // vérification demandée à la main annonce aussi qu'il n'y a rien.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { maj.verifier() }
                .disabled(!maj.peutVerifier)
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started") { modele.montrerBienvenue = true }
            Divider()
            // Le dossier de données et le journal, dans la barre des menus.
            //
            // Deux destinations, donc pas de menu « Folders » à la Prism : leur
            // menu a dix entrées parce qu'ils gèrent des instances, des mods,
            // des skins et des thèmes. Ici tout tient dans UN dossier, et une
            // entrée unique ne fait pas un menu.
            //
            // Une seule entrée : le journal est DANS ce dossier, une seconde
            // ligne pour l'atteindre ne dirait rien de plus.
            Button("Reveal Data Folder") { Reveler.dossier() }
        }
        // Annuler / Rétablir : **le groupe système est laissé en place**, et
        // c'est tout l'intérêt. Il envoie `undo:` dans la chaîne des
        // répondeurs, où AppKit choisit le bon destinataire : l'éditeur de
        // texte quand un champ a le focus, le gestionnaire de la fenêtre
        // sinon — celui sur lequel `Modele` enregistre les marquages.
        //
        // Le remplacer par nos propres boutons câblait ⌘Z en dur, et un
        // raccourci de menu est consulté AVANT la chaîne des répondeurs : on
        // tapait dans le champ de recherche, ⌘Z annulait un marquage. Même
        // famille exactement que le remplacement de `.pasteboard`, qui avait
        // supprimé Couper/Coller. Les intitulés « Annuler le marquage » et
        // « Rétablir le marquage » viennent du `setActionName` du modèle et
        // restent localisés par le système.
        // Le groupe presse-papiers standard est CONSERVÉ : le remplacer supprimait
        // Couper, Coller et Tout sélectionner, donc leurs raccourcis — ⌘V
        // répondait par le bip d'erreur de macOS, y compris dans les champs de
        // texte des réglages. La copie de l'adresse passe désormais par
        // `.copyable` sur le tableau, qui branche le Copier standard.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") { modele.demandeFocusRecherche += 1 }
                .keyboardShortcut("f")
        }
        // Même règle que la barre du bas : un serveur surveillé ne se marque
        // pas, et le menu doit le montrer plutôt que d'accepter un geste sans
        // effet visible.
        // « Scan Now » vit dans Présentation, et non dans un menu à lui.
        //
        // Il y avait un menu « Monitoring » portant deux entrées : celle-ci, et
        // un Démarrer/Arrêter qui faisait exactement ce que fait la case des
        // Réglages — le même réglage à deux endroits, et un réglage persistant
        // déguisé en action. macOS range les réglages dans les Réglages et les
        // actions dans les menus ; la case est donc restée, l'entrée de menu
        // est partie, et le menu qui n'aurait plus porté qu'une ligne avec
        // elle.
        //
        // ⌘R, et non plus ⌘Y : c'est le raccourci que macOS réserve à
        // « rafraîchir » à peu près partout, et il était pris par le
        // Démarrer/Arrêter qui vient de disparaître.
        //
        // ⚠️ Ceci ne retire AUCUN moyen d'arrêter la surveillance. Il en reste
        // deux, et ils ne font pas la même chose : la case des Réglages
        // enregistre ou retire l'agent (le bit `enabled` de la base BTM), et
        // Réglages Système ▸ Ouverture et extensions autorise ou interdit
        // l'app à travailler en fond (le bit `allowed`). Vérifié : désenregistrer
        // depuis l'app laisse l'interrupteur du système sur « activé » — c'est
        // un droit de veto, pas un interrupteur, et lui seul ne pourrait jamais
        // ALLUMER la surveillance.
        CommandGroup(after: .toolbar) {
            Button("Scan Now") { Task { await modele.releverMaintenant() } }
                .keyboardShortcut("r")
                .disabled(modele.chargement)
        }
        CommandMenu("Server") {
            Button("✓  Mark as Worked") { modele.marquer(.reussi) }
                .keyboardShortcut("1")
                .disabled(!modele.selectionMarquable)
            Button("✗  Mark as Failed") { modele.marquer(.rate) }
                .keyboardShortcut("2")
                .disabled(!modele.selectionMarquable)
            Button("Clear Mark") { modele.marquer(nil) }
                .keyboardShortcut("0")
                .disabled(!modele.selectionMarquable)
        }
    }
}
