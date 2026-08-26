// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MCWatchCore

/// Le protocole de statut Minecraft, dans les deux sens.
///
/// C'est le seul endroit du projet où des octets venus d'une machine inconnue
/// sont interprétés. Tout le reste travaille sur des données déjà validées :
/// ici, un serveur hostile choisit lui-même ce qu'on va lire.
///
/// Plusieurs des bornes vérifiées plus bas ont été posées APRÈS un plantage
/// observé — débordement arithmétique sur une longueur hostile, décalages
/// accumulés jusqu'à produire une taille proche de `Int.max`. Ces tests ne les
/// découvrent donc pas : ils les EMPÊCHENT DE DISPARAÎTRE. Une simplification
/// bien intentionnée qui retirerait un `guard` doit faire rougir cette suite,
/// et non attendre qu'un serveur malveillant s'en charge.
@Suite("Protocole de ping")
struct PingTests {

    // MARK: - VarInt, l'entier à taille variable du protocole

    /// Les longueurs de référence du protocole. Un VarInt porte sept bits utiles
    /// par octet, le huitième annonçant qu'il en suit un autre.
    @Test("varint : longueurs de référence du protocole",
          arguments: [(0, 1), (1, 1), (127, 1), (128, 2), (255, 2),
                      (25565, 3), (2_097_151, 3), (2_097_152, 4),
                      (Int(Int32.max), 5)])
    func varintLongueur(valeur: Int, octets: Int) {
        #expect(Ping.varint(valeur).count == octets)
    }

    /// Un entier négatif s'encode sur cinq octets pleins : le protocole le
    /// traite en complément à deux sur 32 bits, pas comme un petit nombre.
    @Test("varint : un négatif tient sur cinq octets")
    func varintNegatif() {
        #expect(Ping.varint(-1).count == 5)
        #expect(Ping.varint(-1) == Data([0xFF, 0xFF, 0xFF, 0xFF, 0x0F]))
    }

    /// Aller-retour : ce qu'on écrit est ce qu'on relit. La propriété qui compte
    /// vraiment, car les deux sens sont écrits séparément.
    @Test("varint : aller-retour",
          arguments: [0, 1, 2, 127, 128, 300, 25565, 65535, 2_097_151, 16_777_215,
                      Int(Int32.max)])
    func varintAllerRetour(valeur: Int) throws {
        var i = 0
        #expect(try Ping.lireVarint(Ping.varint(valeur), &i) == valeur)
        #expect(i == Ping.varint(valeur).count, "l'index doit avancer d'exactement la taille lue")
    }

    /// ⚠️ La borne qui compte. Sans elle, un pair enchaînant les octets de
    /// continuation accumulait des décalages jusqu'à 63 bits et produisait une
    /// longueur proche de `Int.max` — qui servait ensuite à dimensionner une
    /// lecture.
    @Test("varint : un sixième octet de continuation est refusé")
    func varintRefuseSixOctets() {
        var i = 0
        #expect(throws: ErreurPing.self) {
            try Ping.lireVarint(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]), &i)
        }
    }

    /// Neuf octets de continuation : la forme exacte qui faisait planter le
    /// scanner, reproduite ici en dur pour qu'elle ne revienne jamais.
    @Test("varint : la séquence hostile de neuf octets est refusée")
    func varintNeufOctets() {
        var i = 0
        #expect(throws: ErreurPing.self) {
            try Ping.lireVarint(Data(repeating: 0xFF, count: 9), &i)
        }
    }

    /// Un varint tronqué — continuation annoncée, puis plus rien — ne doit pas
    /// lire au-delà du tampon.
    @Test("varint : un tampon tronqué est refusé, sans déborder")
    func varintTronque() {
        var i = 0
        #expect(throws: ErreurPing.self) { try Ping.lireVarint(Data([0x80]), &i) }
        var j = 0
        #expect(throws: ErreurPing.self) { try Ping.lireVarint(Data(), &j) }
    }

    /// Lire deux varints à la suite dans le même tampon : c'est ce que fait le
    /// décodage d'un paquet (identifiant, puis longueur du JSON).
    @Test("varint : deux lectures consécutives dans un même tampon")
    func varintConsecutifs() throws {
        let tampon = Ping.varint(0) + Ping.varint(25565)
        var i = 0
        #expect(try Ping.lireVarint(tampon, &i) == 0)
        #expect(try Ping.lireVarint(tampon, &i) == 25565)
        #expect(i == tampon.count)
    }

    // MARK: - Chaînes

    /// La longueur préfixée compte des OCTETS, pas des caractères. Un accent en
    /// vaut deux, un emoji quatre — s'y tromper décale tout le reste du paquet.
    @Test("chaine : la longueur préfixée compte les octets UTF-8",
          arguments: ["", "a", "localhost", "café", "serveur-éé", "🟩"])
    func chaineLongueurEnOctets(texte: String) throws {
        let encode = Ping.chaine(texte)
        var i = 0
        let annonce = try Ping.lireVarint(encode, &i)
        #expect(annonce == Data(texte.utf8).count)
        #expect(encode.count == i + annonce, "préfixe + charge utile, rien de plus")
    }

    // MARK: - La demande de statut

    /// Poignée de main et demande en une seule écriture. On vérifie que le
    /// paquet s'auto-décrit : sa longueur annoncée doit correspondre à ce qui
    /// suit, sans quoi le serveur attendrait indéfiniment.
    @Test("demandeStatut : la longueur annoncée décrit bien le corps")
    func demandeStatutCoherente() throws {
        let paquet = Ping.demandeStatut(hote: "mc.example.com", port: 25565)
        var i = 0
        let taille = try Ping.lireVarint(paquet, &i)
        #expect(taille > 0)
        #expect(i + taille <= paquet.count, "le corps annoncé doit tenir dans le paquet")
        // Le nom d'hôte voyage en clair dans la poignée de main.
        #expect(paquet.range(of: Data("mc.example.com".utf8)) != nil)
    }

    /// Le port part sur deux octets, en gros-boutien. 25565 = 0x63DD.
    @Test("demandeStatut : le port est en gros-boutien sur deux octets")
    func demandeStatutPort() {
        let paquet = Ping.demandeStatut(hote: "h", port: 25565)
        #expect(paquet.range(of: Data([0x63, 0xDD])) != nil)
    }

    // MARK: - Aplatissement du MOTD

    @Test("aplatir : une simple chaîne")
    func aplatirChaine() {
        #expect(Ping.aplatir("Un serveur") == "Un serveur")
    }

    @Test("aplatir : un objet { text }")
    func aplatirTexte() {
        #expect(Ping.aplatir(["text": "Bonjour"]) == "Bonjour")
    }

    @Test("aplatir : text et extra se concatènent dans l'ordre")
    func aplatirExtra() {
        let motd: [String: Any] = ["text": "A", "extra": [["text": "B"], ["text": "C"]]]
        #expect(Ping.aplatir(motd) == "ABC")
    }

    @Test("aplatir : un tableau au premier niveau")
    func aplatirTableau() {
        #expect(Ping.aplatir([["text": "X"], "Y"]) == "XY")
    }

    @Test("aplatir : ce qui n'est ni chaîne, ni tableau, ni objet rend du vide")
    func aplatirInconnu() {
        #expect(Ping.aplatir(nil) == "")
        #expect(Ping.aplatir(42) == "")
        #expect(Ping.aplatir(["autre": "ignoré"]) == "")
    }

    /// ⚠️ La borne de profondeur. Rien n'empêche un serveur d'enfiler des
    /// milliers de niveaux : sans borne, la pile d'appels déborde et le
    /// processus meurt. Mille niveaux ici — si la borne saute, ce test ne
    /// échoue pas, il PLANTE, ce qui est encore plus visible.
    @Test("aplatir : mille niveaux imbriqués ne font pas déborder la pile")
    func aplatirProfondeurHostile() {
        var nid: Any = ["text": "fond"]
        for _ in 0..<1000 { nid = ["text": "", "extra": [nid]] }
        #expect(Ping.aplatir(nid) == "", "au-delà de la borne, on rend du vide plutôt que de descendre")
    }

    /// Un tableau profondément imbriqué emprunte l'autre branche récursive :
    /// elle doit être bornée elle aussi.
    @Test("aplatir : un tableau profondément imbriqué est borné")
    func aplatirTableauProfond() {
        var nid: Any = "fond"
        for _ in 0..<1000 { nid = [nid] }
        #expect(Ping.aplatir(nid) == "")
    }

    // MARK: - Nettoyage du MOTD

    @Test("nettoyerMotd : les codes couleur disparaissent")
    func nettoyerCouleurs() {
        #expect(Ping.nettoyerMotd("§aVert §lgras") == "Vert gras")
    }

    @Test("nettoyerMotd : les sauts de ligne deviennent des espaces")
    func nettoyerSautsDeLigne() {
        #expect(Ping.nettoyerMotd("ligne un\nligne deux") == "ligne un ligne deux")
    }

    @Test("nettoyerMotd : les espaces multiples se réduisent, les bords se coupent")
    func nettoyerEspaces() {
        #expect(Ping.nettoyerMotd("  trop    d'espaces  ") == "trop d'espaces")
    }

    @Test("nettoyerMotd : une chaîne vide reste vide")
    func nettoyerVide() {
        #expect(Ping.nettoyerMotd("") == "")
        #expect(Ping.nettoyerMotd("§a§l§r") == "")
    }
}
