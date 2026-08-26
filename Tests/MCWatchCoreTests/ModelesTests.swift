// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MCWatchCore

/// Le format sur disque, et sa tolérance.
///
/// Ces données sont écrites par une version de l'app et relues par une autre.
/// Deux exigences en découlent, et les deux se cassent en silence :
///
/// · les NOMS des champs ne peuvent pas bouger — un champ renommé rend
///   illisible tout l'historique déjà accumulé, sans erreur, en repartant
///   simplement de zéro ;
/// · un champ absent ou abîmé ne doit jamais faire échouer la lecture — le
///   décodage synthétisé de Swift, lui, abandonne toute l'entrée.
@Suite("Format des données")
struct ModelesTests {

    /// Le contrat avec le disque. Ces noms viennent des moteurs d'origine et
    /// figurent dans les fichiers déjà écrits chez les utilisateurs : les
    /// changer perdrait leur historique.
    @Test("les noms de champs sur disque ne bougent pas")
    func nomsDeChamps() throws {
        let s = serveur(ip: "1.2.3.4", maxVu: 7, toursVus: 3, toursPeuples: 2,
                        hebergeur: "OVH", motdPromotionnel: true)
        let json = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(s)) as? [String: Any])

        for champ in ["max_vu", "tours_vus", "tours_peuples", "dernier_online",
                      "note", "whitelist_hint", "public_vibe", "default_motd"] {
            #expect(json[champ] != nil, "le champ « \(champ) » a disparu du format")
        }
        #expect(json["note"] as? String == "OVH", "« note » porte bien l'hébergeur")
    }

    @Test("un objet vide se lit entièrement en valeurs de repli")
    func objetVide() throws {
        let s = try JSONDecoder().decode(Serveur.self, from: Data("{}".utf8))
        #expect(s.port == 25565, "le port par défaut est celui de Java Edition")
        #expect(s.maxVu == 0)
        #expect(s.version == "?")
        #expect(s.ip.isEmpty)
        #expect(s.picAt == nil)
    }

    /// Un champ du mauvais type ne doit pas emporter toute l'entrée : on prend
    /// le repli pour celui-là et on garde le reste.
    @Test("un champ abîmé ne fait pas perdre les autres")
    func champAbime() throws {
        let json = #"{"ip": "1.2.3.4", "port": "pas un nombre", "max_vu": 9}"#
        let s = try JSONDecoder().decode(Serveur.self, from: Data(json.utf8))
        #expect(s.ip == "1.2.3.4")
        #expect(s.port == 25565, "repli, faute de type utilisable")
        #expect(s.maxVu == 9, "le champ voisin, lui, est intact")
    }

    @Test("un champ nul vaut un champ absent")
    func champNul() throws {
        let s = try JSONDecoder().decode(Serveur.self,
                                         from: Data(#"{"max_vu": null}"#.utf8))
        #expect(s.maxVu == 0)
    }

    @Test("aller-retour : ce qu'on écrit est ce qu'on relit")
    func allerRetour() throws {
        let avant = serveur(ip: "9.9.9.9", port: 25566, maxVu: 42, toursVus: 100,
                            toursPeuples: 29, dernierOnline: 3, slots: 64,
                            version: "26.2", motd: "Chez moi", hebergeur: "Free SAS",
                            pays: "FR", whitelistAnnoncee: true, proxy: true,
                            motdPromotionnel: true, motdParDefaut: true)
        let apres = try JSONDecoder().decode(Serveur.self,
                                             from: JSONEncoder().encode(avant))
        #expect(apres.adresse == avant.adresse)
        #expect(apres.maxVu == avant.maxVu)
        #expect(apres.toursPeuples == avant.toursPeuples)
        #expect(apres.hebergeur == avant.hebergeur)
        #expect(apres.pays == avant.pays)
        #expect(apres.whitelistAnnoncee == avant.whitelistAnnoncee)
        #expect(apres.proxy == avant.proxy)
        #expect(apres.motdParDefaut == avant.motdParDefaut)
    }

    @Test("un historique vide ou abîmé se lit sans échouer")
    func historiqueTolerant() throws {
        let vide = try JSONDecoder().decode(Historique.self, from: Data("{}".utf8))
        #expect(vide.serveurs.isEmpty)
        #expect(vide.meta.tours == 0)

        let abime = try JSONDecoder().decode(Historique.self,
                                             from: Data(#"{"meta": "pas un objet"}"#.utf8))
        #expect(abime.meta.tours == 0, "un méta illisible repart à neuf plutôt que d'échouer")
    }

    @Test("des filtres partiels gardent les valeurs par défaut de l'app")
    func filtresPartiels() throws {
        let f = try JSONDecoder().decode(Filtres.self, from: Data(#"{"min": 3}"#.utf8))
        #expect(f.slotsMax == 30, "ce que le fichier ne dit pas garde sa valeur d'origine")
        #expect(f.lignes == 60)
    }

    // MARK: - Identité

    /// L'adresse sert de clé dans l'historique : elle doit se composer
    /// exactement pareil des deux côtés, sinon un même serveur se dédouble.
    @Test("l'identité d'un serveur est son adresse, port compris")
    func identite() {
        #expect(serveur(ip: "1.2.3.4", port: 25565).adresse == "1.2.3.4:25565")
        #expect(serveur(ip: "1.2.3.4", port: 25566).adresse == "1.2.3.4:25566")
        #expect(serveur(ip: "1.2.3.4").id == serveur(ip: "1.2.3.4").adresse,
                "l'identifiant et l'adresse ne peuvent pas diverger")
    }

    @Test("la régularité est une part, et vaut zéro sans aucun tour")
    func regularite() {
        #expect(serveur(toursVus: 10, toursPeuples: 5).regularite == 0.5)
        #expect(serveur(toursVus: 0, toursPeuples: 0).regularite == 0,
                "aucune division par zéro")
        #expect(serveur(toursVus: 3, toursPeuples: 3).regularite == 1.0)
    }

    @Test("les deux marques ont des signes distincts")
    func marques() {
        #expect(Marque.reussi.signe == "✓")
        #expect(Marque.rate.signe == "✗")
        #expect(Marque.reussi.rawValue == "ok", "valeur écrite sur disque")
        #expect(Marque.rate.rawValue == "non")
    }

    @Test("une cible est identifiée par son couple adresse-port")
    func ciblesHashables() {
        let a = Cible(ip: "1.2.3.4", port: 25565)
        let b = Cible(ip: "1.2.3.4", port: 25565, hebergeur: "OVH", pays: "FR")
        #expect(Set([a, b]).count == 2 || a == b,
                "l'égalité doit être décidée, pas accidentelle")
    }

    /// Un filtre ajouté APRÈS coup ne doit pas s'allumer tout seul chez qui met
    /// à jour : personne n'a demandé que 42 % de sa liste disparaisse.
    @Test("un filtre absent d'une ancienne préférence se relit à sa valeur d'usine")
    func filtreAjouteResteEteint() throws {
        let ancien = Data(#"{"min":1,"slots":20,"masquer_non":true}"#.utf8)
        let f = try JSONDecoder().decode(Filtres.self, from: ancien)
        #expect(f.masquerMuets == false, "le filtre neuf reste éteint")
        #expect(f.masquerRates == true, "et le reste du fichier est bien relu")
        #expect(f.slotsMax == 20)
    }

}
