// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

/// Met en forme un nombre selon les Réglages Système, **surcharges comprises**.
///
/// `NumberFormatter` et non `.formatted(.number)`, et la différence n'est pas
/// théorique : sur un Mac dont « Format des nombres » vaut `1 234 567,89`,
/// `Locale.current` porte bien l'espace comme séparateur de milliers, mais le
/// style moderne l'ignore et retombe sur les conventions de la région. Mesuré
/// dans le paquet signé : `42 247` avec `NumberFormatter`, `42,247` avec
/// `.formatted(.number)`.
///
/// Rangé au grand acteur : `NumberFormatter` n'est pas `Sendable`, et le
/// construire à chaque ligne de menu coûterait cher — la leçon du classement
/// des hébergeurs, où deux `Regex` par serveur faisaient 2,9 s.
@MainActor
enum Nombre {
    private static var formateur = fabriquer()
    private static var ecoute = false

    private static func fabriquer() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        return f
    }

    /// Le formateur fige les réglages à sa construction. On écoute donc
    /// l'annonce que macOS diffuse quand ils changent — `NSLocale
    /// .currentLocaleDidChangeNotification`, prévue pour ça depuis 10.5 — et
    /// on le refabrique.
    ///
    /// Cela ne suffit pourtant pas à rafraîchir l'écran : un formateur remplacé
    /// n'est pas un état observé, donc SwiftUI ne redessine rien. C'est la vue
    /// qui lit `\.locale` dans son environnement qui déclenche le redessin ;
    /// les deux ensemble font le travail.
    static func texte(_ n: Int) -> String {
        if !ecoute {
            ecoute = true
            NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { formateur = fabriquer() }
            }
        }
        return formateur.string(from: n as NSNumber) ?? String(n)
    }
}
