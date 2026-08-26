// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MCWatchCore

// Harnais de non-régression : chaque phase doit produire exactement ce que
// produit le moteur Python, sinon on n'avance pas. Trois modes exclusifs.
//
//   (aucun)      relevé des profils, filtres, verdicts, crédits
//   --selection  la chaîne de filtrage et le diagnostic
//   --ping       lit des cibles sur l'entrée standard et les interroge

let s = Stockage()
let mode = CommandLine.arguments.dropFirst().first ?? ""

func oui(_ b: Bool) -> String { b ? "true" : "false" }

switch mode {

case "--comparer":
    // Fait tourner les deux dépôts côte à côte et vérifie qu'ils rendent
    // exactement la même chose. Aucune écriture dans les données réelles : le
    // magasin de comparaison est jetable.
    let bac = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mcwatch-comparaison-\(getpid()).store")
    defer { for suf in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: bac.path + suf)) } }

    let base = try Base(fichier: bac)
    let t0 = Date()
    let (np, ns, nc) = try base.importer(depuis: s)
    print("IMPORT\t\(np) profils\t\(ns) serveurs\t\(nc) cibles\t"
        + String(format: "%.0f ms", Date().timeIntervalSince(t0) * 1000))

    var ecarts: [String] = []
    func exige(_ ok: Bool, _ quoi: @autoclosure () -> String) {
        if !ok && ecarts.count < 15 { ecarts.append(quoi()) }
    }
    exige(s.listerSlugs() == base.listerSlugs(), "listerSlugs")
    exige(s.slugActif() == base.slugActif(), "slugActif \(s.slugActif() ?? "-") ≠ \(base.slugActif() ?? "-")")

    var champs = 0
    for slug in s.listerSlugs() {
        exige(s.texte(slug, "recherche.txt") == base.texte(slug, "recherche.txt"), "\(slug) recherche")
        exige(s.texte(slug, "requete.txt") == base.texte(slug, "requete.txt"), "\(slug) requete")

        let a = s.cibles(slug), b = base.cibles(slug)
        exige(a.count == b.count, "\(slug) cibles \(a.count) ≠ \(b.count)")
        for (x, y) in zip(a, b) { exige(x == y, "\(slug) cible \(x.adresse)"); champs += 1 }

        let ha = s.historique(slug), hb = base.historique(slug)
        exige(ha.meta.tours == hb.meta.tours, "\(slug) tours")
        exige(ha.meta.debut == hb.meta.debut, "\(slug) debut")
        exige(ha.meta.dernier == hb.meta.dernier, "\(slug) dernier")
        exige(ha.serveurs.count == hb.serveurs.count, "\(slug) serveurs \(ha.serveurs.count) ≠ \(hb.serveurs.count)")
        for (cle, x) in ha.serveurs {
            guard let y = hb.serveurs[cle] else { exige(false, "\(slug) \(cle) manquant"); continue }
            let v: [(String, Bool)] = [
                ("ip", x.ip == y.ip), ("port", x.port == y.port), ("maxVu", x.maxVu == y.maxVu),
                ("picAt", x.picAt == y.picAt), ("toursVus", x.toursVus == y.toursVus),
                ("toursPeuples", x.toursPeuples == y.toursPeuples),
                ("dernierOnline", x.dernierOnline == y.dernierOnline),
                ("dernierVu", x.dernierVu == y.dernierVu), ("slots", x.slots == y.slots),
                ("version", x.version == y.version), ("motd", x.motd == y.motd),
                ("hebergeur", x.hebergeur == y.hebergeur), ("pays", x.pays == y.pays),
                ("whitelist", x.whitelistAnnoncee == y.whitelistAnnoncee),
                ("proxy", x.proxy == y.proxy),
                ("promo", x.motdPromotionnel == y.motdPromotionnel),
                ("defaut", x.motdParDefaut == y.motdParDefaut)]
            champs += v.count
            for (nom, ok) in v where !ok { exige(false, "\(slug) \(cle) \(nom)") }
        }
    }
    let va = s.verdicts(), vb = base.verdicts()
    exige(va.count == vb.count, "verdicts \(va.count) ≠ \(vb.count)")
    for (a, x) in va {
        guard let y = vb[a] else { exige(false, "verdict \(a) manquant"); continue }
        exige(x.verdict == y.verdict && x.date == y.date, "verdict \(a)")
        champs += 2
    }
    let ca = s.credits(), cb = base.credits()
    exige(ca.solde == cb.solde && ca.plan == cb.plan && ca.plafond == cb.plafond
          && ca.reinits == cb.reinits, "crédits")

    // la sélection, calculée sur les deux, doit rendre le même classement
    if let slug = s.slugActif() {
        let sel = Selection(filtres: s.filtres(), verdicts: s.verdicts())
        let ra = sel.appliquer(Array(s.historique(slug).serveurs.values)).map(\.adresse).sorted()
        let rb = sel.appliquer(Array(base.historique(slug).serveurs.values)).map(\.adresse).sorted()
        exige(ra == rb, "sélection \(ra.count) ≠ \(rb.count)")
    }
    print("CHAMPS\t\(champs)")
    print(ecarts.isEmpty ? "RESULTAT\tIDENTIQUE"
                         : "RESULTAT\t\(ecarts.count) ECART(S)\n  " + ecarts.joined(separator: "\n  "))

case "--selection":
    guard let slug = s.slugActif() else { exit(0) }
    let p = s.profil(slug)
    let sel = Selection(filtres: s.filtres(), verdicts: s.verdicts())
    let tous = Array(p.historique.serveurs.values)
    let retenus = sel.appliquer(tous)

    // Le tri à égalité n'est pas comparable : l'ordre d'insertion d'un
    // dictionnaire Python n'a pas d'équivalent Swift. On compare l'ENSEMBLE des
    // adresses, puis la SUITE des clés de tri.
    print("SELECTION total=\(retenus.count)")
    for a in retenus.map(\.adresse).sorted() { print("  \(a)") }
    print("CLES")
    for x in retenus { print("  \(x.maxVu) \(x.toursPeuples) \(x.slots)") }
    print("COUPABLES")
    for c in sel.coupables(tous) { print("  \(c.cle) \(c.ecarte)") }

case "--tour":
    // Relevé complet dans une racine indiquée : sert au bac à sable.
    let racine = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "")
    let st = Stockage(racine: racine)
    if let b = await Tour.executer(st, delai: 3, parallele: 16) {
        FileHandle.standardError.write(Data("\(b.ligneJournal)\n".utf8))
    } else {
        FileHandle.standardError.write(Data("tour ignoré\n".utf8))
    }

case "--emplacement":
    // Classement d'un chemin de paquet, sans avoir à relancer l'app depuis
    // quatre endroits. Le chemin de translocation à éprouver est un chemin
    // RÉEL, relevé sur une app réellement translocalisée par macOS.
    for chemin in CommandLine.arguments.dropFirst(2) {
        let etat = Emplacement.etat(pour: URL(fileURLWithPath: chemin))
        let nom: String
        switch etat {
        case .correct:              nom = "correct"
        case .translocalise:        nom = "translocalise"
        case .volumeLectureSeule:   nom = "volumeLectureSeule"
        case .horsApplications:     nom = "horsApplications"
        }
        print("\(nom)\t\(chemin)")
    }

case "--slug":
    for a in CommandLine.arguments.dropFirst(2) { print(SlugTest.depuis(a)) }

case "--requete":
    // Traduction des filtres en requête Shodan, à comparer au moteur Python.
    for ligne in CommandLine.arguments.dropFirst(2) {
        let (q, n) = Requete.construire(ligne)
        print("\(q)\t[limite \(n)]")
    }

case "--shodan":
    // N'appelle que des points gratuits : compter, facettes, solde.
    guard let cle = Cle.lire() else { print("clé introuvable dans le trousseau"); exit(1) }
    let api = Shodan(cle: cle)
    let sujets = Array(CommandLine.arguments.dropFirst(2))
    for filtres in sujets {
        let (q, _) = Requete.construire(filtres)
        do {
            let total = try await api.compter(q)
            print("COUNT\t\(filtres)\t\(total)")
        } catch { print("COUNT\t\(filtres)\tERREUR \(error)") }
    }
    if let premier = sujets.first {
        let (q, _) = Requete.construire(premier)
        for champ in ["port", "country", "version"] {
            do {
                let f = try await api.facette(q, champ, 5)
                for (v, n) in f { print("FACETTE\t\(champ)\t\(v)\t\(n)") }
            } catch { print("FACETTE\t\(champ)\tERREUR \(error)") }
        }
    }
    do {
        let i = try await api.infos()
        print("INFOS\t\(i.creditsRecherche)\t\(i.plafondRecherche)\t\(i.creditsScan)\t\(i.plafondScan)\t\(i.plan)")
    } catch { print("INFOS\tERREUR \(error)") }

case "--chercher":
    // PAYANT : une page entamée = un crédit.
    guard let cle = Cle.lire() else { print("clé introuvable dans le trousseau"); exit(1) }
    let api = Shodan(cle: cle)
    let filtres = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    let (q, limite) = Requete.construire(filtres)
    do {
        let avant = try await api.infos().creditsRecherche
        let cibles = try await api.chercher(q, limite: limite)
        let apres = try await api.infos().creditsRecherche
        for c in cibles.sorted(by: { $0.ip < $1.ip }) {
            print("\(c.ip)\t\(c.port)\t\(c.hebergeur)\t\(c.pays)")
        }
        FileHandle.standardError.write(Data(
            "\(cibles.count) adresses · crédits \(avant) → \(apres)\n".utf8))
    } catch {
        print("ÉCHEC \(error)")
    }

case "--diag":
    // Déroule le protocole moderne pas à pas sur une seule cible, pour voir où
    // il échoue quand un serveur bascule en repli.
    Ping.trace = true
    let cible = CommandLine.arguments.dropFirst(2).first ?? ""
    let bouts = cible.components(separatedBy: ":")
    let t = await Ping.diagnostic(hote: bouts[0],
                                  port: Int(bouts.count > 1 ? bouts[1] : "25565") ?? 25565)
    print("  connexion    \(t.connecte ? "OK" : "ÉCHEC — rien n'écoute")")
    if let r = t.reponse {
        print("  moderne      OK · \(r.version) · \(r.enLigne)/\(r.slots) · \(r.motd.prefix(40))")
    } else if t.connecte {
        print("  moderne      ÉCHEC — voir la trace ci-dessus")
    }

case "--ping":
    var cibles: [Cible] = []
    while let ligne = readLine(strippingNewline: true) {
        let col = ligne.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let ip = col.first, !ip.isEmpty else { continue }
        cibles.append(Cible(ip: ip,
                            port: col.count > 1 ? (Int(col[1]) ?? 25565) : 25565,
                            hebergeur: col.count > 2 ? col[2] : "",
                            pays: col.count > 3 ? String(col[3].prefix(2)).uppercased() : ""))
    }
    let debut = Date()
    let n = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 64
    let releves = await Ping.tour(cibles, delai: 3, parallele: n)
    let duree = Date().timeIntervalSince(debut)

    for r in releves.sorted(by: { $0.adresse < $1.adresse }) {
        print("\(r.adresse)\t\(r.enLigne)/\(r.slots)\t\(r.version)\t\(r.motd)"
            + "\twl=\(oui(r.whitelistAnnoncee)) px=\(oui(r.proxy))"
            + " pub=\(oui(r.motdPromotionnel)) def=\(oui(r.motdParDefaut))"
            + "\tancien=\(oui(r.protocoleAncien))")
    }
    FileHandle.standardError.write(Data(
        "\(releves.count)/\(cibles.count) en ligne en \(String(format: "%.1f", duree)) s\n".utf8))

default:
    for slug in s.listerSlugs() {
        let p = s.profil(slug)
        let serveurs = p.historique.serveurs.values
        print("PROFIL \(slug)")
        print("  recherche=\(p.recherche)")
        print("  requete=\(p.requete)")
        print("  cibles=\(p.cibles.count)")
        print("  tours=\(p.historique.meta.tours) debut=\(p.historique.meta.debut ?? "-")"
            + " dernier=\(p.historique.meta.dernier ?? "-")")
        print("  serveurs=\(serveurs.count) vivants=\(serveurs.filter { $0.maxVu >= 1 }.count)"
            + " picmax=\(serveurs.map(\.maxVu).max() ?? 0)"
            + " avecpays=\(serveurs.filter { !$0.pays.isEmpty }.count)")
    }

    let f = s.filtres()
    print("FILTRES min=\(f.picMin) max=\(f.picMax) slots=\(f.slotsMax) regulier=\(f.regularite)"
        + " sans_proxy=\(oui(f.sansProxy)) sans_pub=\(oui(f.sansPub))"
        + " masquer_whitelist=\(oui(f.masquerWhitelist)) motd_defaut=\(oui(f.motdParDefautSeulement))"
        + " masquer_non=\(oui(f.masquerRates)) masquer_ok=\(oui(f.masquerReussis)) limit=\(f.lignes)")

    let v = s.verdicts()
    print("VERDICTS total=\(v.count) ok=\(v.values.filter { $0.verdict == .reussi }.count)"
        + " non=\(v.values.filter { $0.verdict == .rate }.count)")

    let c = s.credits()
    print("CREDITS solde=\(c.solde.map(String.init) ?? "-") plafond=\(c.plafond)"
        + " plan=\(c.plan) jour=\(c.jourReinit.map(String.init) ?? "-")")

    print("ACTIF \(s.slugActif() ?? "-")")
    print("RACINE \(s.racine.path)")
    print("CLE \(Cle.lire() != nil ? "trousseau" : "aucune")")
}


/// Copie de la règle de nommage, pour la comparer à Python.
enum SlugTest {
    static func depuis(_ filtres: String) -> String {
        var sortie = ""
        var tiret = false
        for c in filtres.lowercased() {
            if c.isASCII && (c.isLetter || c.isNumber) {
                sortie.append(c); tiret = false
            } else if !tiret && !sortie.isEmpty {
                sortie.append("-"); tiret = true
            }
        }
        while sortie.hasSuffix("-") { sortie.removeLast() }
        return sortie.isEmpty ? "sans-filtre" : sortie
    }
}
