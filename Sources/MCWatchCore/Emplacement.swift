// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// D'où l'app s'exécute, et si la surveillance peut y survivre.
///
/// **Pourquoi ce fichier existe.** L'agent est enregistré auprès de launchd avec
/// un `BundleProgram`, c'est-à-dire un chemin relatif **au paquet**. Tant que le
/// paquet est à un endroit stable, l'agent le suit. Mais une app téléchargée
/// porte le bit de quarantaine, et macOS l'exécute alors depuis une **copie
/// éphémère** en lecture seule (« app translocation », un dossier
/// `…/AppTranslocation/<UUID>/d/…` créé à la volée). Enregistrer l'agent depuis
/// cette copie revient à le faire pointer vers un chemin qui n'existera plus
/// après la fermeture : la surveillance s'arrêterait sans un mot — exactement le
/// mode de panne silencieux que ce projet a déjà payé deux fois.
///
/// C'est le cas NORMAL d'un premier lancement depuis un `.dmg` ou depuis le
/// dossier Téléchargements, donc le chemin que suivra la plupart des gens qui
/// installent l'app. Déplacer l'app vers `/Applications` retire la quarantaine
/// et la translocation avec elle.
///
/// ⚠️ La détection se fait sur le chemin, faute de mieux :
/// `SecTranslocateIsTranslocatedURL` **n'est pas dans le SDK public** (vérifié
/// sur le SDK macOS 27 — ni en-tête, ni symbole exposé à Swift). Le motif
/// `/AppTranslocation/` est en revanche stable et documenté.
public enum Emplacement {

    public enum Etat: Equatable, Sendable {
        /// Dans un dossier Applications : rien à signaler.
        case correct
        /// macOS exécute une copie éphémère : tout enregistrement d'agent serait perdu.
        case translocalise
        /// Volume en lecture seule — typiquement l'image disque elle-même.
        case volumeLectureSeule
        /// Chemin réel et stable, mais hors d'un dossier Applications.
        case horsApplications(String)
    }

    public static var etat: Etat { etat(pour: Bundle.main.bundleURL) }

    /// La règle, isolée de `Bundle.main` pour être **vérifiable**.
    ///
    /// Sans ce paramètre, la seule façon d'éprouver le classement serait de
    /// relancer l'app depuis quatre emplacements différents. Là, un harnais
    /// couvre les quatre cas en une seconde — et le motif de translocation est
    /// confronté à un chemin réel, relevé sur une vraie app translocalisée.
    public static func etat(pour paquet: URL) -> Etat {
        let url = paquet.resolvingSymlinksInPath()
        let chemin = url.path

        // L'ordre compte : une app translocalisée est AUSSI hors /Applications
        // et sur un volume en lecture seule. C'est la translocation qu'il faut
        // nommer, parce que c'est elle qui explique quoi faire.
        if chemin.contains("/AppTranslocation/") { return .translocalise }

        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly == true { return .volumeLectureSeule }

        // `/Applications` et le dossier Applications personnel sont tous deux
        // légitimes. On compare des chemins RÉSOLUS, sans quoi un lien
        // symbolique ferait échouer la comparaison.
        if chemin.hasPrefix("/Applications/") { return .correct }
        if chemin.range(of: "^/Users/[^/]+/Applications/",
                        options: .regularExpression) != nil { return .correct }

        return .horsApplications(url.deletingLastPathComponent().path)
    }

    /// Faux quand enregistrer l'agent produirait une surveillance morte.
    ///
    /// `horsApplications` n'est **pas** bloquant : le chemin est réel et stable,
    /// l'agent y survivrait. On le signale sans l'interdire — décider à la place
    /// de quelqu'un qui range ses apps ailleurs serait présomptueux.
    public static var peutSurveiller: Bool {
        switch etat {
        case .translocalise, .volumeLectureSeule: return false
        case .correct, .horsApplications:         return true
        }
    }

    /// Ce qu'il faut dire à l'utilisateur, ou `nil` si tout va bien.
    ///
    /// Chaque message nomme **le geste** à faire, pas seulement le problème :
    /// « déplace l'app vers Applications » est actionnable, « translocation
    /// détectée » ne l'est pas.
    public static var explication: String? {
        switch etat {
        case .correct:
            return nil
        case .translocalise:
            return ouLancer(String(localized: "Monitoring unavailable - Temporary copy"))
        case .volumeLectureSeule:
            return ouLancer(String(localized: "Monitoring unavailable - Read-only volume"))
        case .horsApplications(let dossier):
            return ouLancer(String(localized: """
                MC Watch is running from “\(dossier)”. If it is moved, automatic \
                monitoring will stop
                """))
        }
    }

    /// La phrase que les trois cas répétaient mot pour mot, écrite une fois.
    ///
    /// Les trois messages disaient déjà « il faut lancer MC Watch depuis le
    /// dossier Applications », chacun à sa façon. Elle était donc à écrire trois
    /// fois, à tenir en phase trois fois, et surtout **à traduire trois fois
    /// dans les neuf langues** — vingt-sept traductions pour une seule phrase.
    ///
    /// ⚠️ Un TROU dans un motif, et surtout pas une concaténation.
    /// `String(localized: a + b)` ne cherche aucune clé : c'est le littéral
    /// entier qui en est une, et une somme de deux `String` n'en est pas un.
    /// C'est le même piège que `Text("a" + "b")`, qui n'affiche pas le markdown.
    /// Ici le motif porte `%@`, la raison passe dedans, et chaque langue reste
    /// libre de mettre le trou où sa grammaire le veut.
    private static func ouLancer(_ raison: String) -> String {
        String(localized: "\(raison) - MC Watch has to be run from the Applications folder to work properly.",
               comment: "%@ est la raison du refus, elle-même déjà traduite")
    }

    /// Vrai quand le message mérite d'être présenté comme un blocage et non
    /// comme une remarque : la surveillance est réellement impossible.
    public static var estBloquant: Bool { !peutSurveiller }
}
