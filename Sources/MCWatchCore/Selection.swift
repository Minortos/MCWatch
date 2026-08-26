// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Filtrage, tri et diagnostic du classement.
///
/// L'ordre des critères reproduit celui du moteur Python : il n'a pas d'effet
/// sur le résultat, chaque filtre étant indépendant, mais le garder identique
/// rend les deux implémentations comparables ligne à ligne.
public struct Selection: Sendable {

    public let filtres: Filtres
    public let verdicts: [String: Verdict]
    /// Ignore « masquer les ✗ / ✓ » — utile pour revenir sur un verdict posé par erreur.
    public let ignorerMarques: Bool

    /// Les horodatages du dernier passage de chaque liste affichée.
    ///
    /// Un serveur a répondu au dernier tour si son `dernierVu` y figure. C'est
    /// la seule façon de le savoir : `dernierOnline` est remis à zéro sur les
    /// muets (voir `Tour.fusionner`), donc « personne connecté » et « n'a pas
    /// répondu » y sont indiscernables.
    ///
    /// Un ENSEMBLE et non une seule date : le tableau mêle la liste de recherche
    /// et les serveurs suivis, qui ont chacun leur cadence et donc leur dernier
    /// tour.
    public let derniersTours: Set<String>

    public init(filtres: Filtres, verdicts: [String: Verdict] = [:],
                ignorerMarques: Bool = false,
                derniersTours: Set<String> = []) {
        self.filtres = filtres
        self.verdicts = verdicts
        self.ignorerMarques = ignorerMarques
        self.derniersTours = derniersTours
    }

    /// Ce serveur a-t-il répondu au dernier passage ?
    ///
    /// Sans horodatage de référence — liste jamais relevée — on répond OUI : ne
    /// rien savoir ne doit pas faire disparaître la liste entière.
    public func aRepondu(_ s: Serveur) -> Bool {
        guard !derniersTours.isEmpty, let vu = s.dernierVu else { return true }
        return derniersTours.contains(vu)
    }

    public func marque(_ s: Serveur) -> Marque? { verdicts[s.adresse]?.verdict }

    /// **La définition unique** des critères qu'un dépôt peut appliquer seul.
    ///
    /// Écrite ici et nulle part ailleurs : `Base` en fait un `#Predicate` pour
    /// SQLite, `Stockage` l'applique en mémoire, et un test compare les deux
    /// ensembles sur les données réelles. Si cette règle change, elle change
    /// pour tout le monde — c'est ce qui empêche les deux chemins de diverger.
    ///
    /// La régularité s'écrit en produit et non en division : une base entière
    /// tronquerait le quotient, et `toursPeuples × 100 ≥ seuil × toursVus` dit
    /// exactement la même chose sans jamais diviser.
    /// Sépare l'hébergeur professionnel du fournisseur d'accès résidentiel.
    ///
    /// Un serveur au bout d'une ligne d'abonné est presque toujours celui de
    /// quelqu'un chez lui — précisément ce que cette app cherche. Sur une ligne
    /// de datacenter, c'est un projet, souvent une communauté déjà constituée.
    ///
    /// Deux motifs, dans cet ordre, et l'ordre EST le mécanisme : certains
    /// fournisseurs d'accès portent un nom qui ressemble à un hébergeur, et
    /// « Google Fiber » est le cas d'école — résidentiel, alors que
    /// « Google LLC » est un datacenter. Le premier motif les met à l'abri.
    ///
    /// Les suffixes de société — `Inc`, `LLC`, `Ltd` — ont été écartés après
    /// mesure : ils faisaient basculer côté hébergeur cinq FAI sur sept parmi
    /// ceux qui ne figurent pas dans la liste d'exceptions (Cox, Optus,
    /// Spectrum, Shaw, Chunghwa). Sans eux, les hébergeurs restent tous
    /// reconnus par leur nom propre ou par un mot du métier.
    ///
    /// Construit localement plutôt qu'en global, comme `Ping.Motifs` : un
    /// littéral `Regex` est vérifié à la compilation, et une instance par
    /// passage de filtre coûte moins qu'une globale à protéger.
    public struct Hebergement {
        let fournisseurAcces = #/google\s*fiber|verizon|at&t|comcast|charter|frontier|telus|virgin|vodafone|deutsche\s*telekom|softbank|korea\s*telecom|free\s*sas|superloop|kpn|bell\s*canada|centurylink|orange|telia|telefonica|claro|telstra|elisa|netia|fastweb|sky\s*uk|rogers|a1\s*telekom|proximus|swisscom|bouygues|sfr|kddi|ntt|chunghwa|iliad|cox|optus|spectrum|shaw/#
            .ignoresCase().matchingSemantics(.unicodeScalar)
        let hebergeur = #/ovh|hetzner|oracle|contabo|digitalocean|vultr|constant\s*company|linode|akamai|ionos|netcup|aurologic|gmo|xserver|sakura|servers\.com|hostpapa|dataforest|wiit|amazon|aws|google|microsoft|azure|scaleway|leaseweb|choopa|m247|hostinger|namecheap|nitrado|marbis|falix|aternos|shockbyte|hosting|host|cloud|datacenter|data\s*center|colo|server|internet\s*group|networks?\b/#
            .ignoresCase().matchingSemantics(.unicodeScalar)

        public init() {}

        /// Un nom vide rend `false` : sans information, on garde le serveur
        /// plutôt que de le cacher sur une supposition.
        public func estHeberge(_ nom: String) -> Bool {
            guard !nom.isEmpty else { return false }
            if nom.firstMatch(of: fournisseurAcces) != nil { return false }
            return nom.firstMatch(of: hebergeur) != nil
        }
    }

    /// `h` est EXIGÉ, sans valeur par défaut, et ce n'est pas un détail de
    /// style. Avec un défaut, chaque appelant en construisait une par serveur
    /// sans le voir : deux `Regex` bâtis 2053 fois. Mesuré — **2,91 s** contre
    /// **1,5 ms** en réutilisant une seule instance, soit 1880 fois plus lent,
    /// et ce coût était payé même quand le filtre résidentiel était ÉTEINT,
    /// puisqu'un paramètre par défaut s'évalue à chaque appel. Le rendre
    /// obligatoire force l'appelant à le hisser hors de sa boucle.
    public static func retenuParLeDepot(_ s: Serveur, _ f: Filtres,
                                        _ h: Hebergement) -> Bool {
        if s.maxVu < f.picMin { return false }
        if f.picMax > 0, s.maxVu > f.picMax { return false }
        if f.slotsMax > 0, !(s.slots > 0 && s.slots <= f.slotsMax) { return false }
        if f.sansProxy, s.proxy { return false }
        if f.sansPub, s.motdPromotionnel { return false }
        if f.masquerWhitelist, s.whitelistAnnoncee { return false }
        if f.motdParDefautSeulement, !s.motdParDefaut { return false }
        if f.residentielSeulement, h.estHeberge(s.hebergeur) { return false }
        if f.regularite > 0, s.toursPeuples * 100 < f.regularite * s.toursVus { return false }
        return true
    }

    /// Serveurs retenus, triés, puis tronqués au nombre de lignes demandé.
    public func appliquer(_ serveurs: [Serveur]) -> [Serveur] {
        var reste = serveurs

        if !ignorerMarques {
            if filtres.masquerRates { reste = reste.filter { marque($0) != .rate } }
            if filtres.masquerReussis { reste = reste.filter { marque($0) != .reussi } }
        }
        // Comme les marques : hors de `retenuParLeDepot`, parce que la réponse
        // ne se lit pas dans le serveur seul.
        if filtres.masquerMuets { reste = reste.filter(aRepondu) }
        if filtres.masquerWhitelist { reste = reste.filter { !$0.whitelistAnnoncee } }
        if filtres.sansProxy { reste = reste.filter { !$0.proxy } }
        if filtres.sansPub { reste = reste.filter { !$0.motdPromotionnel } }
        if filtres.motdParDefautSeulement { reste = reste.filter { $0.motdParDefaut } }
        if filtres.residentielSeulement {
            let h = Hebergement()
            reste = reste.filter { !h.estHeberge($0.hebergeur) }
        }
        if filtres.slotsMax > 0 {
            reste = reste.filter { $0.slots > 0 && $0.slots <= filtres.slotsMax }
        }
        reste = reste.filter { $0.maxVu >= filtres.picMin }
        if filtres.picMax > 0 { reste = reste.filter { $0.maxVu <= filtres.picMax } }
        // ⚠️ En PRODUIT D'ENTIERS, exactement comme `retenuParLeDepot`, et pour
        // une raison qui va au-delà de la troncature annoncée là-haut : la
        // division en `Double` qui était écrite ici DIVERGEAIT du dépôt sur les
        // valeurs pile au seuil. 29 tours peuplés sur 100 font 0,29, et
        // 0,29 × 100 vaut 28,999999999999996 en binaire — donc « inférieur à
        // 29 ». La base gardait le serveur, le classement le cachait, et le
        // diagnostic des filtres désignait un coupable qui n'en était pas un.
        //
        // Cherché exhaustivement sur les combinaisons de (peuplés, vus, seuil)
        // jusqu'à cent : quatre désaccords, tous de cette forme — 29/100 à 29 %,
        // 57/100 à 57 %, 58/100 à 58 %, 29/50 à 58 %. `SelectionTests` refait
        // cette recherche à chaque exécution et échoue au premier désaccord.
        if filtres.regularite > 0 {
            reste = reste.filter { $0.toursPeuples * 100 >= filtres.regularite * $0.toursVus }
        }

        // Le tri ne sert qu'à choisir QUELS serveurs survivent à la troncature :
        // la table applique ensuite son propre ordre. Sans limite de lignes, il
        // était donc calculé sur tout l'historique puis jeté.
        guard filtres.lignes > 0 else { return reste }
        return Array(Selection.trier(reste).prefix(filtres.lignes))
    }

    /// Les plus peuplés d'abord, puis les plus réguliers, puis les plus petits.
    /// L'adresse départage en dernier : `sorted(by:)` n'est pas stable en Swift,
    /// et sans ce dernier critère deux exécutions pourraient différer.
    public static func trier(_ serveurs: [Serveur]) -> [Serveur] {
        serveurs.sorted { a, b in
            if a.maxVu != b.maxVu { return a.maxVu > b.maxVu }
            if a.toursPeuples != b.toursPeuples { return a.toursPeuples > b.toursPeuples }
            if a.slots != b.slots { return a.slots < b.slots }
            return a.adresse < b.adresse
        }
    }

    // MARK: - Diagnostic

    public struct Coupable: Sendable {
        public let cle: String
        /// Le nom montré à l'utilisateur, donc traduit. `cle` reste un
        /// identifiant technique et ne se traduit jamais.
        public let libelle: LocalizedStringResource
        public let ecarte: Int
    }

    /// Quels filtres vident le classement, et combien chacun écarte.
    ///
    /// Chaque filtre est mesuré **seul contre l'ensemble**. Neutraliser un
    /// filtre à la fois ne marche pas : si deux filtres écartent tout chacun de
    /// leur côté, en retirer un ne débloque rien et le diagnostic n'accuse
    /// personne.
    public func coupables(_ serveurs: [Serveur]) -> [Coupable] {
        let total = serveurs.count
        guard total > 0 else { return [] }

        var neutre = Filtres()
        neutre.picMin = 0; neutre.picMax = 0; neutre.slotsMax = 0; neutre.regularite = 0
        neutre.sansProxy = false; neutre.sansPub = false; neutre.residentielSeulement = false
        neutre.masquerWhitelist = false; neutre.motdParDefautSeulement = false
        neutre.masquerRates = false; neutre.masquerReussis = false; neutre.lignes = 0
        neutre.masquerMuets = false

        var trouves: [Coupable] = []
        for (cle, libelle, actif, poser) in Selection.criteres {
            guard actif(filtres) else { continue }
            var seul = neutre
            poser(&seul, filtres)
            let restants = Selection(filtres: seul, verdicts: verdicts).appliquer(serveurs).count
            if total - restants > 0 {
                trouves.append(Coupable(cle: cle, libelle: libelle, ecarte: total - restants))
            }
        }
        return trouves.sorted { $0.ecarte > $1.ecarte }
    }

    /// Les critères, dans l'ordre où ils s'affichent dans les réglages.
    static let criteres: [(String, LocalizedStringResource, @Sendable (Filtres) -> Bool,
                           @Sendable (inout Filtres, Filtres) -> Void)] = [
        ("min", "Minimum player peak",
         { $0.picMin > 0 }, { $0.picMin = $1.picMin }),
        ("max", "Maximum player peak",
         { $0.picMax > 0 }, { $0.picMax = $1.picMax }),
        ("slots", "Maximum slots (server size)",
         { $0.slotsMax > 0 }, { $0.slotsMax = $1.slotsMax }),
        ("regulier", "Minimum regularity",
         { $0.regularite > 0 }, { $0.regularite = $1.regularite }),
        ("sans_proxy", "Exclude networks (Velocity/Bungee proxy)",
         { $0.sansProxy }, { a, _ in a.sansProxy = true }),
        ("sans_pub", "Exclude promotional MOTDs",
         { $0.sansPub }, { a, _ in a.sansPub = true }),
        ("masquer_whitelist", "Hide advertised whitelists",
         { $0.masquerWhitelist }, { a, _ in a.masquerWhitelist = true }),
        ("motd_defaut", "Only never-configured MOTDs",
         { $0.motdParDefautSeulement }, { a, _ in a.motdParDefautSeulement = true }),
        ("residentiel", "Home connections only",
         { $0.residentielSeulement }, { a, _ in a.residentielSeulement = true }),
        ("masquer_non", "Hide servers marked ✗ (already tried)",
         { $0.masquerRates }, { a, _ in a.masquerRates = true }),
        ("masquer_ok", "Hide servers marked ✓ (where you already play)",
         { $0.masquerReussis }, { a, _ in a.masquerReussis = true }),
        // Sans cette entrée, le diagnostic du tableau vide passerait à côté du
        // filtre le plus tranchant de la liste : il écarte 42 % des serveurs sur
        // une liste qui tourne depuis des semaines.
        ("masquer_muets", "Hide servers that did not answer the last scan",
         { $0.masquerMuets }, { a, _ in a.masquerMuets = true }),
    ]
}
