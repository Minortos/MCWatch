// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MCWatchCore

/// Un générateur à GRAINE, et non le hasard du système.
///
/// Un fuzzer qui tire au sort différemment à chaque exécution trouve un défaut
/// une fois sur cent et ne sait plus le refaire. Avec une graine fixe, la même
/// séquence revient toujours : un échec est reproductible, et l'ajout d'un cas
/// ne fait pas disparaître les précédents.
struct Graine: RandomNumberGenerator {
    var etat: UInt64
    init(_ graine: UInt64) { etat = graine &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        etat ^= etat << 13; etat ^= etat >> 7; etat ^= etat << 17
        return etat
    }
}

/// Les surfaces exposées, et ce qui les borne.
///
/// Trois entrées de cette app ne sont pas dignes de confiance :
///
/// · le RÉSEAU — un serveur Minecraft inconnu choisit lui-même les octets
///   qu'on va décoder, et rien ne l'oblige à respecter le protocole ;
/// · le DISQUE — les fichiers du conteneur sont du texte ordinaire, qu'un
///   autre processus, une sauvegarde restaurée ou une main humaine peut avoir
///   modifiés ;
/// · l'UTILISATEUR — ce qu'il tape finit dans une requête et dans des noms.
///
/// Ce fichier s'occupe de ce qu'elles peuvent faire de mal, pas de ce qu'elles
/// font quand tout va bien.
@Suite("Surfaces d'attaque")
struct SecuriteTests {

    // MARK: - Le disque : un nom de profil devient un chemin

    /// ⚠️ Un slug ne nomme pas, il DEVIENT un chemin — jusque dans un
    /// effacement récursif. `appendingPathComponent` ne protège rien : vérifié,
    /// `profils/../..` se résout en grand-parent.
    @Test("un nom de profil qui remonte l'arborescence est refusé",
          arguments: ["../..", "../../../../etc", "a/../../b", "/etc/passwd",
                      "..", ".", "/", "profils/../autre", "a/b"])
    func slugTraversant(hostile: String) {
        #expect(Stockage.slugSur(hostile) == nil, "« \(hostile) » ne doit pas passer")
    }

    @Test("les noms que l'app fabrique elle-même passent",
          arguments: ["essai", "26-2-fr", "sans-filtre", "a", "ovh-sas-500"])
    func slugLegitime(bon: String) {
        #expect(Stockage.slugSur(bon) == bon)
    }

    @Test("un nom vide, trop long, ou porteur de caractères de contrôle est refusé")
    func slugAutresRefus() {
        #expect(Stockage.slugSur("") == nil)
        #expect(Stockage.slugSur(String(repeating: "a", count: 129)) == nil)
        #expect(Stockage.slugSur("a\u{0}b") == nil, "un octet nul tronque un chemin en C")
        #expect(Stockage.slugSur("a\nb") == nil)
        #expect(Stockage.slugSur("MAJUSCULE") == nil, "Slug.depuis n'en produit jamais")
        #expect(Stockage.slugSur("é") == nil)
    }

    /// La démonstration, et non la relecture : on pose un dossier témoin en
    /// dehors du dossier des profils et on demande son effacement par
    /// traversée. Il doit être encore là ensuite.
    @Test("une suppression par traversée n'efface rien hors des profils")
    func suppressionTraversanteInoffensive() throws {
        let racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcwatch-secu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: racine) }
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)

        let temoin = racine.appendingPathComponent("NE-PAS-EFFACER", isDirectory: true)
        try FileManager.default.createDirectory(at: temoin, withIntermediateDirectories: true)
        try Data("témoin".utf8).write(to: temoin.appendingPathComponent("preuve.txt"))

        let s = Stockage(racine: racine)
        try s.ecrireHistorique("legitime", Historique())
        for hostile in ["../NE-PAS-EFFACER", "..", "../.."] {
            try s.supprimerProfil(hostile)
        }
        #expect(FileManager.default.fileExists(atPath: temoin.appendingPathComponent("preuve.txt").path),
                "le témoin a été effacé — la traversée est ouverte")
        #expect(s.listerSlugs() == ["legitime"], "et le profil légitime est intact")
    }

    /// Le fichier « actif » est du texte ordinaire dans le conteneur : rien ne
    /// dit qui l'a écrit. Un nom hostile doit être ignoré, pas suivi.
    @Test("un fichier « actif » hostile ne désigne pas un chemin hors des profils")
    func actifHostileIgnore() throws {
        let racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcwatch-actif-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: racine) }
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)

        let s = Stockage(racine: racine)
        try s.ecrireHistorique("vrai", Historique())
        try Data("../../..".utf8).write(to: racine.appendingPathComponent("actif"))
        #expect(s.slugActif() == "vrai", "on retombe sur un profil réel, jamais sur un chemin")
    }

    // MARK: - Le disque : ce que le journal emporte

    /// ⚠️ Une erreur de fichier porte le chemin complet dans son `userInfo`,
    /// donc `/Users/<compte>`. Le journal est précisément le fichier qu'on joint
    /// à un rapport de bogue — et ce projet est publié sous pseudonyme.
    @Test("le journal n'emporte jamais le chemin du dossier personnel")
    func journalSansNomDeCompte() throws {
        let racine = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcwatch-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: racine) }
        try FileManager.default.createDirectory(at: racine, withIntermediateDirectories: true)

        // Une vraie erreur de fichier, avec son userInfo complet.
        let inexistant = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/mcwatch-inexistant-xyz/f.json")
        var brut = ""
        do { try Data("x".utf8).write(to: inexistant) }
        catch { brut = "write failed: \(error)" }
        #expect(brut.contains(NSUserName()), "le cas de test lui-même doit contenir le nom")

        let s = Stockage(racine: racine)
        s.journal(brut, horodatage: "T1")

        let ecrit = try String(contentsOf: racine.appendingPathComponent("journal.log"),
                               encoding: .utf8)
        #expect(!ecrit.contains(NSUserName()), "le nom du compte a fui dans le journal")
        #expect(!ecrit.contains("/Users/"), "aucun chemin personnel ne doit y figurer")
        #expect(ecrit.contains("~"), "le chemin doit être remplacé, pas supprimé")
    }

    // MARK: - Le réseau : fuzzing du décodeur

    /// ⚠️ Le cœur de la surface d'attaque. Ces octets viennent d'une machine
    /// que personne ne contrôle, et le décodeur doit s'en sortir SANS jamais
    /// planter : ni débordement arithmétique, ni lecture hors tampon, ni
    /// allocation démesurée, ni boucle sans fin. Une exception est une réponse
    /// acceptable ; un arrêt du processus n'en est pas une.
    ///
    /// Vingt mille tampons, longueurs et contenus tirés au sort. Un plantage
    /// ici ne fait pas échouer le test, il ARRÊTE la suite — ce qui est encore
    /// plus difficile à ignorer.
    @Test("vingt mille tampons hostiles ne font pas tomber la lecture de varint")
    func fuzzVarint() {
        var g = Graine(0x5EED_1)
        var lus = 0, refuses = 0
        for _ in 0..<20_000 {
            let taille = Int.random(in: 0...64, using: &g)
            let octets = (0..<taille).map { _ in UInt8.random(in: 0...255, using: &g) }
            var i = 0
            do {
                let n = try Ping.lireVarint(Data(octets), &i)
                lus += 1
                // Cinq octets, sept bits utiles chacun : rien ne peut dépasser.
                #expect(n >= 0 && n < (1 << 35), "valeur hors bornes : \(n)")
                #expect(i <= max(taille, 5), "l'index a dépassé le tampon")
            } catch {
                refuses += 1
            }
        }
        #expect(lus + refuses == 20_000)
        #expect(lus > 0 && refuses > 0, "le tirage doit produire les deux issues")
    }

    /// Le même exercice sur l'aplatissement du MOTD, qui est récursif — donc
    /// le seul endroit du décodage où la pile d'appels peut déborder.
    @Test("des structures de MOTD tirées au sort ne font pas déborder la pile")
    func fuzzAplatir() {
        var g = Graine(0x5EED_12)
        func batir(_ profondeur: Int, _ g: inout Graine) -> Any {
            if profondeur > 60 { return "fond" }
            switch Int.random(in: 0...4, using: &g) {
            case 0: return String(repeating: "é", count: Int.random(in: 0...40, using: &g))
            case 1: return [batir(profondeur + 1, &g), batir(profondeur + 1, &g)]
            case 2: return ["text": "t", "extra": [batir(profondeur + 1, &g)]]
            case 3: return ["extra": batir(profondeur + 1, &g)]
            default: return Int.random(in: -1000...1000, using: &g)
            }
        }
        for _ in 0..<400 {
            let sortie = Ping.aplatir(batir(0, &g))
            #expect(sortie.count < 1_000_000, "aplatissement démesuré : \(sortie.count)")
        }
    }

    /// Le nettoyage du MOTD travaille sur du texte venu du réseau : Unicode
    /// arbitraire, très long, ou vide.
    @Test("le nettoyage du MOTD encaisse n'importe quel texte")
    func fuzzNettoyage() {
        var g = Graine(0x5EED_13)
        let alphabet = Array("§abc \n\t\u{0}é🟩\u{202E}\u{FEFF}<>&\"'\\")
        for _ in 0..<2_000 {
            let n = Int.random(in: 0...200, using: &g)
            let texte = String((0..<n).map { _ in alphabet.randomElement(using: &g)! })
            let propre = Ping.nettoyerMotd(texte)
            #expect(!propre.contains("\n"), "un saut de ligne casserait l'affichage du tableau")
            #expect(propre.count <= texte.count, "le nettoyage ne peut qu'enlever")
        }
    }

    // MARK: - L'utilisateur : ce qu'il tape

    /// Un texte de recherche quelconque ne doit produire ni plantage, ni
    /// requête vide : le socle est toujours là.
    @Test("n'importe quelle saisie produit une requête utilisable")
    func fuzzRequete() {
        var g = Graine(0x5EED_14)
        let alphabet = Array(#"abc 26.2 FR : " ' \ / . - 1000 tous org port:"#)
        for _ in 0..<2_000 {
            let n = Int.random(in: 0...60, using: &g)
            let saisie = String((0..<n).map { _ in alphabet.randomElement(using: &g)! })
            let (requete, limite) = Requete.construire(saisie)
            #expect(requete.contains(#"product:"Minecraft""#), "le socle a disparu : « \(saisie) »")
            #expect(limite >= 1 && limite <= Requete.limiteMaximale,
                    "taille hors bornes (\(limite)) pour « \(saisie) »")
        }
    }
}
