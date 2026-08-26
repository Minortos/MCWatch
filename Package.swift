// swift-tools-version: 6.4
// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "MCWatch",
    // Plancher volontairement bas : swiftc sans cible explicite grave « minos 28.0 »
    // dans le binaire, au-delà même du système, et LaunchServices refuse alors
    // d'ouvrir l'app (erreur -10825). SPM, lui, respecte cette déclaration.
    // Cette déclaration fait deux choses, et la seconde n'est pas évidente :
    // elle fixe la version minimale requise, ET la version de SDK inscrite dans
    // le binaire (`LC_BUILD_VERSION`). Or macOS choisit l'apparence d'une app
    // d'après ce SDK, pas d'après le système sur lequel elle tourne. Déclarée
    // en .v14, l'app héritait de l'allure de macOS 14 au milieu d'un macOS 27.
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "MCWatchCore", targets: ["MCWatchCore"]),
        .executable(name: "mcwatch-verif", targets: ["mcwatch-verif"]),
        .executable(name: "MCWatchScan", targets: ["MCWatchScan"]),
        .executable(name: "MCWatchApp", targets: ["MCWatchApp"]),
    ],
    // ─── Sparkle ────────────────────────────────────────────────────────────
    //
    // macOS n'a jamais eu de mécanisme de mise à jour hors de l'App Store :
    // Apple n'en fournit ni API, ni service, ni même une convention. Le menu
    // « Check for Updates… », la fenêtre qui annonce une nouvelle version et la
    // case « Automatically check » que l'on croit venir du système viennent en
    // réalité de ce framework, né en 2006, qui tient ce rôle dans à peu près
    // toute app distribuée directement.
    //
    // Version EXACTE, et non `from:`. Sparkle est le seul code de ce paquet
    // autorisé à remplacer l'app sur le disque — ce qu'il fait est très
    // exactement ce qu'un logiciel malveillant voudrait faire. Une plage de
    // versions laisserait `swift build` tirer un jour du code que personne n'a
    // relu, dans le composant où cela compte le plus. Monter de version devient
    // ainsi un geste délibéré, daté, visible dans l'historique du dépôt.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // Mode 6, contrôle strict de la concurrence. Il fallait auparavant s'en
        // tenir au mode 5 : les rappels de `NWConnection` sont antérieurs à
        // `Sendable` et ne sont pas annotés, si bien que l'enveloppe maison
        // autour du réseau ne passait qu'au prix de `@unchecked`. L'API Swift de
        // Network (`NetworkConnection`, macOS 26) est annotée de bout en bout ;
        // cette enveloppe a disparu, et avec elle la seule raison de reculer.
        .target(name: "MCWatchCore",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "mcwatch-verif", dependencies: ["MCWatchCore"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        // Le scanner embarque son `Info.plist` DANS son binaire, faute de paquet
        // où le poser. Sans cette identité il n'a pas de conteneur, et le bac à
        // sable le tue au lancement. Le chemin est relatif à la racine du
        // paquet, d'où SwiftPM lance l'éditeur de liens.
        //
        // `unsafeFlags` interdirait à ce paquet d'être une DÉPENDANCE d'un
        // autre ; c'est sans conséquence ici, MCWatch étant toujours compilé
        // comme paquet racine.
        .executableTarget(name: "MCWatchScan", dependencies: ["MCWatchCore"],
                          swiftSettings: [.swiftLanguageMode(.v6)],
                          linkerSettings: [.unsafeFlags([
                              "-Xlinker", "-sectcreate",
                              "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "Ressources/Scan-Info.plist"])]),
        // ⚠️ Le `rpath` n'est pas un ornement. `construire.sh` pose
        // `Sparkle.framework` dans `Contents/Frameworks`, mais dyld ne l'y
        // cherchera QUE si le binaire porte ce chemin de recherche. Sans lui
        // tout compile, tout se signe, et l'app meurt au lancement sur
        // « Library not loaded ». SwiftPM ne le pose pas de lui-même : il produit
        // des exécutables nus et ne sait rien du paquet qu'on assemble autour.
        .executableTarget(name: "MCWatchApp",
                          dependencies: ["MCWatchCore",
                                         .product(name: "Sparkle", package: "Sparkle")],
                          swiftSettings: [.swiftLanguageMode(.v6)],
                          linkerSettings: [.unsafeFlags([
                              "-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"])]),
        // La suite de non-régression. `swift test`, rien d'autre à installer :
        // quiconque clone ce dépôt peut vérifier qu'il n'a rien cassé, ce qui
        // est la moindre des choses quand on invite aux contributions.
        //
        // Elle ne couvre QUE `MCWatchCore` — la logique et le décodage réseau.
        // Les vues n'y sont pas : un test de vue SwiftUI casse au premier
        // remaniement visuel et n'attrape presque rien en échange. Le risque
        // réel est dans ce qui vient du réseau, pas dans la mise en page.
        .testTarget(name: "MCWatchCoreTests", dependencies: ["MCWatchCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
