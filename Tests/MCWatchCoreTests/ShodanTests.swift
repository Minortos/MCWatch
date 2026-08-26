// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import MCWatchCore

/// ⚠️ Aucun test de ce fichier n'ouvre de connexion. Le réseau de Shodan se
/// paie en crédits, et une suite de tests qui en consomme est une suite qu'on
/// finit par ne plus lancer. Seul ce qui se calcule sans sortir de la machine
/// est vérifié ici — ce qui suffit, car c'est là que sont les décisions.
@Suite("Crédits et requêtes Shodan")
struct ShodanTests {

    // MARK: - Ce que la recherche va coûter

    /// Le chiffre annoncé sur le bouton avant de dépenser. S'il est faux, il
    /// l'est dans le sens qui fâche : l'utilisateur voit un prix et en paie un
    /// autre.
    @Test("un crédit par tranche de cent effectivement récupérés",
          arguments: [(total: 1000, limite: 300, attendu: 3),
                      (total: 50,   limite: 300, attendu: 1),
                      (total: 100,  limite: 100, attendu: 1),
                      (total: 101,  limite: 1000, attendu: 2),
                      (total: 1000, limite: 1000, attendu: 10),
                      (total: 250,  limite: 1000, attendu: 3)])
    func creditsAttendus(total: Int, limite: Int, attendu: Int) {
        #expect(Shodan.creditsAttendus(total: total, limite: limite) == attendu)
    }

    /// C'est le plus PETIT des deux qui compte : demander mille serveurs quand
    /// il n'en existe que cinquante n'en facture pas mille.
    @Test("on ne paie que ce qui existe")
    func creditsBornesParLeTotal() {
        #expect(Shodan.creditsAttendus(total: 50, limite: 1000) == 1)
        #expect(Shodan.creditsAttendus(total: 1000, limite: 50) == 1)
    }

    @Test("une recherche sans résultat ne coûte rien")
    func creditsZero() {
        #expect(Shodan.creditsAttendus(total: 0, limite: 300) == 0)
    }

    // MARK: - Construction de la requête

    @Test("une requête vide cherche quand même Minecraft sur le port Java")
    func requeteVide() {
        let (r, limite) = Requete.construire("")
        #expect(r.contains(#"product:"Minecraft""#))
        #expect(r.contains("port:25565"))
        #expect(limite == Requete.limiteParDefaut)
    }

    @Test("un jeton contenant un chiffre est une version")
    func versionReconnue() {
        #expect(Requete.construire("26.2").requete.contains(#"version:"26.2""#))
    }

    @Test("deux lettres sont un pays, et il est mis en majuscules")
    func paysReconnu() {
        #expect(Requete.construire("fr").requete.contains(#"country:"FR""#))
    }

    @Test("un nombre seul fixe la taille de la liste")
    func nombreEstUneTaille() {
        #expect(Requete.construire("500").limite == 500)
        #expect(!Requete.construire("500").requete.contains("500"),
                "une taille ne doit pas se retrouver dans la requête")
    }

    @Test("« tous » et « all » demandent le maximum")
    func tousEtAll() {
        #expect(Requete.construire("tous").limite == Requete.limiteMaximale)
        #expect(Requete.construire("all").limite == Requete.limiteMaximale)
        #expect(Requete.construire("TOUS").limite == Requete.limiteMaximale)
    }

    @Test("la taille demandée reste dans les bornes de l'API")
    func limitesBornees() {
        #expect(Requete.construire("999999").limite == Requete.limiteMaximale)
        #expect(Requete.construire("0").limite == 1, "zéro serveur n'a pas de sens")
    }

    /// ⚠️ Sans cette règle, `product:"Minecraft"` ramenait des serveurs Bedrock
    /// — injoignables par construction, puisque le ping parle le protocole Java
    /// en TCP. Ils entraient dans la liste, ne répondaient jamais, et
    /// gonflaient à vie le compteur des silencieux.
    @Test("le port Java est imposé dans toute requête qui n'en désigne pas un autre")
    func portJavaImpose() {
        #expect(Requete.construire("26.2 FR").requete.contains("port:25565"))
    }

    /// La contrepartie : un port explicite doit l'emporter. Un serveur Java sur
    /// un port alternatif se joint parfaitement, et forcer 25565 par-dessus
    /// rendrait la requête vide.
    @Test("un port explicite l'emporte sur le port imposé")
    func portExplicitePrioritaire() {
        let r = Requete.construire("port:25566").requete
        #expect(r.contains("port:25566"))
        #expect(!r.contains("port:25565"), "les deux ports ne peuvent pas cohabiter")
    }

    @Test("un filtre brut passe tel quel")
    func filtreBrut() {
        #expect(Requete.construire("org:OVH").requete.contains("org:OVH"))
    }

    @Test("une valeur à espaces est remise entre guillemets")
    func valeurAEspaces() {
        let r = Requete.construire(#"org:"OVH SAS""#).requete
        #expect(r.contains(#"org:"OVH SAS""#))
    }

    @Test("un mot quelconque devient une recherche de texte")
    func texteLibre() {
        #expect(Requete.construire("survie").requete.contains(#""survie""#))
    }

    // MARK: - Découpage

    @Test("le découpage sépare sur les espaces et ignore les surplus")
    func decoupageSimple() {
        #expect(Requete.decouper("a b   c") == ["a", "b", "c"])
        #expect(Requete.decouper("   ") == [])
        #expect(Requete.decouper("") == [])
    }

    @Test("les guillemets protègent les espaces, simples comme doubles")
    func decoupageGuillemets() {
        #expect(Requete.decouper(#""OVH SAS" FR"# ) == ["OVH SAS", "FR"])
        #expect(Requete.decouper("'OVH SAS'") == ["OVH SAS"])
    }

    @Test("un guillemet jamais refermé ne fait pas perdre le texte")
    func guillemetNonFerme() {
        #expect(Requete.decouper(#""jamais fermé"#) == ["jamais fermé"])
    }

    @Test("« est un entier » ne se laisse pas berner")
    func estEntier() {
        #expect(Requete.estEntier("123"))
        #expect(!Requete.estEntier(""))
        #expect(!Requete.estEntier("12a"))
        #expect(!Requete.estEntier("26.2"), "un point n'est pas un chiffre")
        #expect(!Requete.estEntier("١٢٣"), "des chiffres non-ASCII ne sont pas un nombre ici")
    }
}
