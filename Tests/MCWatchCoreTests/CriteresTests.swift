// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import MCWatchCore

/// La lecture des versions annoncées par les serveurs.
///
/// Shodan rend le champ tel que le serveur l'écrit, et presque aucun ne se
/// contente d'une version nue. Ce qui est testé ici n'est donc pas un format
/// mais une extraction : retrouver, dans une chaîne écrite par n'importe qui,
/// la version que le joueur doit lancer pour entrer.
@Suite("Versions annoncées")
struct VersionMCTests {

    @Test("une version nue se lit telle quelle")
    func nue() {
        #expect(VersionMC().reelle("26.2") == "26.2")
    }

    @Test("le nom du logiciel est ignoré",
          arguments: ["Paper 26.2", "Spigot 26.2", "Purpur 26.2", "CraftBukkit 26.2"])
    func logicielIgnore(annonce: String) {
        #expect(VersionMC().reelle(annonce) == "26.2")
    }

    /// ⚠️ La règle qui compte : la PLUS HAUTE, pas la première. Un proxy qui
    /// annonce une plage accepte les clients jusqu'à sa borne supérieure, et
    /// c'est celle-là que le joueur lance. Prendre la première rangerait ces
    /// serveurs dix-huit versions majeures trop bas.
    @Test("d'une plage, on retient la borne haute",
          arguments: ["1.7.2-26.2", "Velocity 1.7.2-26.2", "26.2-1.7.2"])
    func plageBorneHaute(annonce: String) {
        #expect(VersionMC().reelle(annonce) == "26.2")
    }

    /// Le joker `x` des proxies. Sans lui, `26.x` n'était pas reconnu du tout
    /// et le serveur retombait sous la première version citée.
    @Test("le joker x est reconnu")
    func joker() {
        #expect(VersionMC().reelle("26.x") == "26.x")
        #expect(VersionMC().reelle("1.8.x-26.x") == "26.x")
    }

    @Test("les codes couleur n'empêchent pas la lecture")
    func codesCouleur() {
        #expect(VersionMC().reelle("§e§lNOX§f§LCRAFT.PL §F 1.16.4-26.2") == "26.2")
    }

    /// `nil` n'est pas un échec d'analyse : c'est une catégorie réelle, celle
    /// des milliers de serveurs qui n'annoncent aucune version.
    @Test("l'absence de version est une réponse, pas une erreur",
          arguments: ["COSMIC GUARD", "TCPShield.com", "Maintenance", "Offline", "", "???"])
    func aucuneVersion(annonce: String) {
        #expect(VersionMC().reelle(annonce) == nil)
    }

    @Test("regrouper additionne les occurrences d'une même version réelle")
    func regrouperAdditionne() {
        let facette = [(valeur: "Paper 26.2", nombre: 10),
                       (valeur: "Spigot 26.2", nombre: 5),
                       (valeur: "26.1", nombre: 3)]
        let sortie = VersionMC.regrouper(facette)
        #expect(sortie.first?.version == "26.2")
        #expect(sortie.first?.nombre == 15, "10 + 5, regroupés sous la même version")
        #expect(sortie.count == 2)
    }

    @Test("regrouper trie par nombre décroissant")
    func regrouperTrie() {
        let sortie = VersionMC.regrouper([(valeur: "26.1", nombre: 1),
                                          (valeur: "26.2", nombre: 99)])
        #expect(sortie.map(\.nombre) == [99, 1])
    }

    /// Les sans-version forment une entrée à part, et elle passe en DERNIER —
    /// c'est une catégorie fourre-tout, elle n'a pas à occuper le haut du menu
    /// même quand elle est nombreuse.
    @Test("les sans-version ferment la marche")
    func regrouperSansVersion() {
        let sortie = VersionMC.regrouper([(valeur: "26.2", nombre: 1),
                                          (valeur: "COSMIC GUARD", nombre: 500)])
        #expect(sortie.last?.version == nil)
        #expect(sortie.last?.nombre == 500)
    }

    @Test("une facette vide ne rend rien")
    func regrouperVide() {
        #expect(VersionMC.regrouper([]).isEmpty)
    }
}

/// L'assemblage de la requête Shodan.
///
/// Une erreur ici ne se voit pas : elle produit une requête syntaxiquement
/// valide qui interroge autre chose que ce que l'utilisateur a demandé — et
/// elle lui coûte des crédits pour ce résultat-là.
@Suite("Critères de recherche")
struct CriteresTests {

    @Test("le socle est toujours là, même sans aucun critère")
    func socleToujours() {
        #expect(Criteres().requete() == Criteres.socle)
        #expect(Criteres.socle.contains("port:25565"), "Bedrock répondrait jamais")
        #expect(Criteres.socle.contains("Minecraft"))
    }

    @Test("les champs vides n'entrent pas dans la requête")
    func champsVides() {
        var c = Criteres()
        c.versions = ["", ""]
        c.pays = []
        #expect(c.requete() == Criteres.socle)
    }

    @Test("un champ rempli s'ajoute, entre guillemets")
    func champRempli() {
        var c = Criteres()
        c.versions = ["26.2"]
        #expect(c.requete().contains(#"version:"26.2""#))
    }

    /// Syntaxe vérifiée contre l'API : la virgule fait la somme, et le mot-clé
    /// `OR` est refusé avec une erreur 400.
    @Test("les valeurs multiples se séparent par une virgule")
    func valeursMultiples() {
        var c = Criteres()
        c.hebergeurs = ["OVH SAS", "Hetzner Online GmbH"]
        #expect(c.requete().contains(#"org:"OVH SAS","Hetzner Online GmbH""#))
        #expect(!c.requete().contains(" OR "), "OR est refusé par l'API")
    }

    /// ⚠️ Le mécanisme des menus. Le menu d'un champ se calcule sur la requête
    /// PRIVÉE de ce champ, sans quoi choisir 26.2 restreint la facette à 26.2 :
    /// le menu se vide de ses propres options et l'on ne peut plus changer de
    /// version sans tout effacer.
    @Test("« sans » retire exactement le champ demandé")
    func sansRetireLeChamp() {
        var c = Criteres()
        c.versions = ["26.2"]; c.pays = ["FR"]; c.hebergeurs = ["OVH SAS"]

        let sansVersion = c.requete(sans: .version)
        #expect(!sansVersion.contains("version:"))
        #expect(sansVersion.contains("country:"), "les autres champs restent")
        #expect(sansVersion.contains("org:"))

        #expect(!c.requete(sans: .pays).contains("country:"))
        #expect(!c.requete(sans: .hebergeur).contains("org:"))
    }

    /// Le MOTD n'a pas de menu à alimenter : il ne doit jamais être retiré.
    @Test("le MOTD survit à toutes les exclusions")
    func motdJamaisRetire() {
        var c = Criteres()
        c.motd = "survie"
        for champ: Criteres.Champ in [.version, .pays, .hebergeur] {
            #expect(c.requete(sans: champ).contains("survie"))
        }
    }

    @Test("le MOTD est débarrassé de ses espaces de bord")
    func motdEspaces() {
        var c = Criteres()
        c.motd = "   survie   "
        #expect(c.requete().contains(#""survie""#))
        c.motd = "     "
        #expect(c.requete() == Criteres.socle, "un MOTD tout en espaces ne compte pas")
    }

    /// Ce test CONSTATE le comportement actuel, il ne l'approuve pas : un
    /// guillemet tapé dans le champ MOTD se retrouve tel quel dans la requête,
    /// et referme la chaîne plus tôt que prévu. L'utilisateur ne peut nuire
    /// qu'à lui-même — c'est sa propre clé et ses propres crédits — mais la
    /// requête envoyée cesse alors de correspondre à celle que l'étiquette
    /// affiche. Si le comportement change, ce test doit changer avec lui,
    /// sciemment.
    @Test("un guillemet dans le MOTD ressort tel quel dans la requête")
    func motdGuillemet() {
        var c = Criteres()
        c.motd = #"tes"t"#
        #expect(c.requete().hasSuffix(#""tes"t""#))
    }

    // MARK: - Crédits

    /// Un crédit par tranche de cent serveurs entamée.
    @Test("le coût suit les tranches de cent",
          arguments: [(1, 1), (99, 1), (100, 1), (101, 2), (200, 2), (201, 3), (1000, 10)])
    func creditsParTranche(taille: Int, attendu: Int) {
        var c = Criteres()
        c.taille = taille
        #expect(c.credits == attendu)
    }

    /// Le plancher : une recherche coûte au moins un crédit, jamais zéro.
    @Test("une taille nulle coûte quand même un crédit")
    func creditsPlancher() {
        var c = Criteres()
        c.taille = 0
        #expect(c.credits == 1)
    }

    // MARK: - Étiquette

    @Test("l'étiquette porte tous les critères choisis, et la taille en dernier")
    func etiquetteComplete() {
        var c = Criteres()
        c.versions = ["26.2"]; c.pays = ["FR"]; c.hebergeurs = ["OVH SAS"]
        c.motd = "survie"; c.taille = 500
        let e = c.etiquette
        for bout in ["26.2", "FR", "OVH SAS", "survie", "500"] {
            #expect(e.contains(bout), "« \(bout) » manque à l'étiquette")
        }
        #expect(e.hasSuffix("500"))
    }

    @Test("sans aucun critère, l'étiquette se réduit à la taille")
    func etiquetteNue() {
        var c = Criteres()
        c.taille = 250
        #expect(c.etiquette == "250")
    }

    @Test("des critères identiques donnent des requêtes identiques")
    func egalite() {
        var a = Criteres(); a.versions = ["26.2"]
        var b = Criteres(); b.versions = ["26.2"]
        #expect(a == b)
        #expect(a.requete() == b.requete())
    }
}
