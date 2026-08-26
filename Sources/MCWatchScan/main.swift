// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MCWatchCore

// Scanner sans interface, appelé par l'agent macOS toutes les dix minutes.
// Il ne fait qu'une chose : un relevé de la liste surveillée, puis un contrôle
// du solde Shodan au plus une fois par heure — c'est ce qui permet de repérer
// tout seul le jour de réinitialisation, que l'API ne donne pas.

// Pilotage de l'agent en ligne de commande, utile pour l'installation et le
// dépannage. Le module est partagé avec l'app : un seul comportement, comme
// pour le reste de `MCWatchCore`.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--agent") {
    if arguments.contains("marche") {
        Agent.demarrer()
    } else if arguments.contains("arret") {
        Agent.arreter()
    }
    print("agent: \(Agent.actif ? "active" : "inactive")")
    exit(0)
}

// Une racine passée en argument sert au bac à sable des tests : dans ce cas on
// reste sur les fichiers, le magasin partagé n'aurait pas de sens.
let racine = arguments.first.map { URL(fileURLWithPath: $0) }
let stockage: any Depot = racine.map { Stockage(racine: $0) } ?? Base.ouvrirOuFichiers()

await Tour.executer(stockage)
// La MÊME source de clé que l'app : le trousseau, avec reprise du fichier laissé
// par `shodan init` s'il traîne encore. Le scanner lisait auparavant ce fichier
// en clair directement — supprimer le fichier arrêtait donc le suivi des crédits
// en silence, alors que l'app, elle, continuait de fonctionner.
await Solde.relever(stockage, cle: Cle.courante())
