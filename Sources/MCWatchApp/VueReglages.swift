// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MCWatchCore

struct VueReglages: View {
    @Bindable var modele: Modele
    let maj: MiseAJour

    var body: some View {
        TabView {
            VueCompte(modele: modele)
                .tabItem { Label("Account", systemImage: "key") }
            VueRecherche(modele: modele)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            VueFiltres(modele: modele)
                .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease") }
            VueSurveillance(modele: modele)
                .tabItem { Label("Monitoring", systemImage: "binoculars") }
            VueAPropos(maj: maj)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // ⚠️ MESURÉ, et l'essai inverse a été fait : sans cette ligne, la
        // scène `Settings` ne se dimensionne PAS sur son contenu. Elle prend
        // une hauteur minimale — environ 290 points — et les cinq onglets
        // défilent dans une lucarne, licence coupée en plein milieu de phrase.
        // Une fenêtre de réglages annonce sa taille ; macOS ne la devine pas.
        .frame(width: 640, height: 560)
    }
}

// MARK: - Compte Shodan : la clé et le solde

/// Tout ce qui touche au compte au même endroit. La clé vit dans le trousseau
/// de la session — elle n'est donc ni dans le paquet de l'app, ni visible par
/// les autres utilisateurs du Mac, et chacun gère la sienne ici.
struct VueCompte: View {
    @Bindable var modele: Modele

    @State private var saisie = ""
    @State private var enregistree: String?
    @State private var enClair = false
    @State private var occupe = false
    @State private var message = ""
    @State private var echec = false
    @State private var confirmerRetrait = false

    var body: some View {
        Form {
            Section {
                if let cle = enregistree {
                    LabeledContent("Saved key") {
                        // Sans espacement imposé : la pile pose le sien.
                        // `Spacer(minLength: 0)` reste, mais ce n'en est pas
                        // une — c'est le contraire, une longueur qu'on autorise
                        // à devenir nulle pour que la clé se pousse à droite
                        // sans jamais réclamer de place.
                        HStack {
                            Spacer(minLength: 0)
                            if !enClair {
                                Text(Cle.masquer(cle))
                                    .font(.system(.body, design: .monospaced))
                            }
                            // Largeur **minimale**, pas fixe, et `fixedSize`
                            // par-dessus. La largeur fixe de 64 points avait
                            // été calée sur « Afficher » : en allemand,
                            // « Einblenden » ne tenait pas et le bouton passait
                            // à la ligne au milieu du mot. Un gabarit taillé
                            // pour une seule langue casse dans les neuf autres —
                            // c'est le défaut d'internationalisation le plus
                            // courant, et il ne se voit qu'à l'écran.
                            Button(enClair ? "Hide" : "Show") { enClair.toggle() }
                                .buttonStyle(.link)
                                .fixedSize()
                        }
                    }
                    if enClair {
                        // Sur sa propre ligne, pleine largeur : une clé Shodan
                        // fait 32 caractères et se faisait tronquer dans la
                        // colonne de droite. Sélectionnable pour la copier.
                        Text(cle)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No key saved for this macOS account.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    // Sans style imposé, comme les champs des onglets
                    // Recherche et Surveillance : dans un formulaire, macOS ne
                    // dessine pas de cadre — vérifié sur « Nom » de
                    // l'ordinateur dans Réglages Système, qui est éditable et
                    // n'en a aucun. L'invite dit déjà quoi faire de la ligne.
                    SecureField(enregistree == nil ? "Paste your key here"
                                                   : "Paste another key", text: $saisie)
                        .onSubmit { Task { await valider() } }
                    Button(enregistree == nil ? "Verify and Save" : "Replace") {
                        Task { await valider() }
                    }
                    .disabled(occupe || saisie.trimmingCharacters(in: .whitespaces).isEmpty)
                    if occupe { ProgressView().controlSize(.small) }
                }

                HStack {
                    // Aucune taille imposée : les trois liens de cette ligne
                    // prennent celle du formulaire.
                    //
                    // Les deux premiers portaient `.font(.caption)`, le
                    // troisième non — « Remove Key… », sur la MÊME ligne, en
                    // restait au corps normal. Le résultat se voyait : deux
                    // liens minuscules à gauche, un lisible à droite. `.caption`
                    // suit bien le thème et l'accessibilité, ce n'est pas une
                    // valeur en dur ; mais c'est une taille CHOISIE, et rien ne
                    // la justifiait ici.
                    Link("account.shodan.io", destination: URL(string: "https://account.shodan.io")!)
                    // Le sélecteur système ouvert sur le dossier du CLI. C'est
                    // le geste de l'utilisateur qui accorde l'accès au fichier ;
                    // l'app n'a rien le droit d'y lire avant.
                    Button("Import from the Shodan CLI…") { Task { await importer() } }
                        .buttonStyle(.link)
                        .disabled(occupe)
                    Spacer()
                    if enregistree != nil {
                        // Points de suspension : ce bouton n'efface rien, il DEMANDE.
                        // Même règle que « Delete This List… », qui ouvre la
                        // même sorte de dialogue juste en dessous.
                        Button("Remove Key…", role: .destructive) { confirmerRetrait = true }
                            .buttonStyle(.link)
                    }
                }

                if !message.isEmpty {
                    // Même raison que dans le volet Surveillance : la teinte
                    // suffit, la taille réduite effaçait la réponse.
                    Label(message, systemImage: echec ? "exclamationmark.triangle"
                                                      : "checkmark.circle")
                        .foregroundStyle(echec ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }

            } header: {
                Text("Shodan API Key")
            } footer: {
                // ─── Les explications vont au PIED, pas dans la boîte ─────────
                //
                // Une note posée parmi les lignes de la section demande trois
                // modificateurs pour ressembler à une note : `.font(.caption)`,
                // `.foregroundStyle(.secondary)`, `.fixedSize`. Le pied n'en
                // demande aucun — macOS choisit la taille, la teinte et le
                // repli, et les rechoisira le jour où il en changera d'avis.
                // C'est aussi ce qui la sort du cadre gris, là où les autres
                // onglets la mettaient déjà.
                //
                // (Elle disait « Stored in · Your macOS login keychain » sur une
                // ligne d'affichage, plus haut. C'était un littéral, pas une
                // lecture — la seule ligne de l'app dont la valeur ne venait de
                // nulle part, et qui aurait continué de dire la même chose si la
                // classe de stockage changeait.)
                Text("""
                    The key is kept in your macOS login keychain, it is not \
                    visible to the other accounts on this Mac - An invalid key \
                    is never saved.
                    """)
            }

            Section {
                LabeledContent("Search") {
                    // Un seul littéral, pas une concaténation : `"a" + "b"`
                    // produit un `String`, donc l'initialiseur verbatim, et la
                    // ligne n'était traduite dans aucune langue.
                    // ─── Aucune teinte sur ces trois valeurs ─────────────
                    //
                    // `LabeledContent` grise DÉJÀ ce qu'on lui donne à droite :
                    // c'est le rendu macOS, libellé en avant, valeur en retrait.
                    // Les trois lignes le contredisaient chacune à leur façon —
                    // deux le redisaient en `.secondary`, et « Plan » forçait
                    // `.primary`, ce qui ANNULAIT la règle : « dev » ressortait
                    // en noir entre deux voisines grises, sans que rien ne le
                    // justifie.
                    if rienDeRelevé { Text(verbatim: "—") }
                    else {
                        Text("\(modele.credits.solde.map(String.init) ?? "—") of \(modele.credits.plafond)")
                            .monospacedDigit()
                    }
                }
                // Pas de ligne « Scan ». Shodan tient bien un quota de scans à
                // la demande, et un troisième pour son service de surveillance
                // (`monitored_ips`, 16 chez le plan dev) — mais cette app
                // n'appelle ni l'un ni l'autre : seulement `host/count`, gratuit,
                // et `host/search`, qui ne prend que des crédits de requête.
                //
                // Les afficher trompait, et d'autant plus que le vocabulaire de
                // l'app les appelle : la surveillance s'annonce en « relevés »,
                // le menu propose « Scan Now ». On lisait « Scan · 100 sur 100 »
                // et l'on en concluait que la surveillance s'arrêterait à zéro,
                // alors que ce compteur ne bouge jamais.
                LabeledContent("Plan") {
                    Text(modele.credits.plan.isEmpty ? "—" : modele.credits.plan)
                }
                LabeledContent("Resets") {
                    Text(rienDeRelevé ? "—" : dateReinit)
                }
            } header: {
                Text("Credits")
            } footer: {
                Text("""
                    Shodan publishes no reset date: it is inferred on the day \
                    the balance goes back up. Credits are spent when a list is \
                    created. Shodan resets them every month.
                    """)
            }
        }
        .formStyle(.grouped)
        .onAppear { enregistree = Cle.courante() }
        .confirmationDialog("Remove the key from this account?", isPresented: $confirmerRetrait) {
            Button("Remove Key", role: .destructive) {
                Task {
                    await modele.oublierCle()
                    enregistree = nil
                    enClair = false
                    message = String(localized: "Key removed from the keychain.")
                    echec = false
                }
            }
        } message: {
            Text("""
                Your lists and history are kept, and monitoring continues. \
                Only creating new lists will become impossible.
                """)
        }
    }

    /// L'API ne donne aucune date : elle est déduite d'une remontée de solde
    /// déjà observée, ou annoncée « en attente ».
    /// Aucun solde n'a jamais été relevé : pas de clé, ou clé tout juste
    /// saisie et API pas encore interrogée.
    ///
    /// Sans ce test, les trois lignes mentaient chacune à leur façon devant un
    /// utilisateur qui n'a pas encore de clé : « — of 0 » pour le solde, la
    /// formule qui disparaît, et « en attente d'observation » pour la
    /// réinitialisation — laquelle laissait croire qu'une observation était en
    /// cours alors que rien n'est même interrogé. Un tiret dans les trois dit
    /// la même chose, et dit vrai.
    private var rienDeRelevé: Bool { modele.credits.solde == nil }

    private var dateReinit: String {
        guard let jour = modele.credits.jourReinit,
              let quand = Solde.prochaine(jour) else {
            return String(localized: "waiting to be observed")
        }
        // Affichage, donc `Date.FormatStyle` : la date se présente selon les
        // usages de la session — l'inverse du format figé qu'on écrit sur
        // disque. Un `dateFormat` en dur imposait le jour avant le mois à tout
        // le monde.
        let jours = Calendar.current.dateComponents([.day], from: Date(), to: quand).day ?? 0
        let date = quand.formatted(date: .numeric, time: .omitted)
        return String(localized: "\(date)  (in \(jours) days)")
    }

    private func valider(_ cle: String? = nil) async {
        occupe = true; defer { occupe = false }
        do {
            let infos = try await Cle.verifierEtEnregistrer(cle ?? saisie)
            enregistree = Cle.courante()
            modele.relireEtatCle()
            enClair = false
            saisie = ""
            echec = false
            message = String(localized: "Key is valid, account “\(infos.plan)”.")
            await modele.rafraichirCredits()
        } catch {
            echec = true
            message = error.localizedDescription
        }
    }

    /// La clé importée subit **la même vérification** que celle tapée à la main :
    /// venir du CLI ne prouve pas qu'elle est encore valable.
    private func importer() async {
        guard let cle = ImportCLI.choisirFichierCle() else { return }
        await valider(cle)
    }
}

// MARK: - Recherche Shodan et exploration

/// Une entrée de menu, telle que Shodan la rapporte.
private struct Choix: Identifiable, Hashable {
    let id: String
    let libelle: String
    let nombre: Int
}

struct VueRecherche: View {
    @Bindable var modele: Modele

    @State private var criteres = Criteres()
    @State private var profils: [(slug: String, libelle: String, actif: Bool)] = []
    @State private var slugChoisi = ""
    @State private var confirmerSuppression = false

    @State private var total: Int?
    @State private var occupe = false
    @State private var message = ""

    /// Lu pour la seule raison d'en dépendre : sans cela, changer le format des
    /// nombres dans les Réglages Système ne redessinerait pas les menus, et
    /// l'ancien formatage resterait affiché jusqu'au prochain redessin fortuit.
    @Environment(\.locale) private var locale

    /// Le contenu des menus. **Rien n'est codé en dur** : tout vient des
    /// facettes de Shodan, calculées sur son index du moment. Une version
    /// nouvelle apparaît le jour où il en voit une ; un pays disparaît quand
    /// plus personne n'y héberge. Aucune liste à tenir à jour.
    @State private var versions: [Choix] = []
    @State private var pays: [Choix] = []
    @State private var hebergeurs: [Choix] = []

    private let tailles = [100, 300, 500, 1000]

    var body: some View {
        // ─── Un `Form`, et non plus une pile montée à la main ───────────────
        //
        // C'était le dernier onglet à ne pas en être un, et cela se voyait à
        // l'écran : ses menus portaient le cadre du bouton pop-up classique
        // quand les quatre autres onglets, eux, prenaient le rendu des Réglages
        // Système. Aucun des deux n'était « faux » — SwiftUI choisit d'après le
        // conteneur — mais un seul est celui d'une page de réglages.
        //
        // Ce que la conversion a SUPPRIMÉ, et qui ne reviendra pas : quatre
        // largeurs de 110 points pour aligner les libellés — le gabarit taillé
        // sur l'anglais que le commentaire de l'onglet Compte décrit déjà, et
        // que « MOTD contains » en allemand aurait fait déborder — six valeurs
        // d'espacement, une marge de 20, trois `Divider()` posés pour imiter
        // des séparations de sections, et quatre `Text().font(.headline)` qui
        // en imitaient les titres. Le formulaire fait les quatre, et les refera
        // à sa façon le jour où macOS en changera.
        Form {
            sectionListes
            sectionSocle
            sectionCriteres
            sectionDevis
        }
        .formStyle(.grouped)
        .onAppear {
            profils = modele.chargerProfils()
            slugChoisi = profils.first(where: \.actif)?.slug ?? ""
        }
        // `task(id:)` annule la tâche en cours dès que les critères changent,
        // et la pause initiale sert d'anti-rebond : taper dans le champ MOTD
        // ne déclenche qu'un aller-retour, pas un par caractère.
        .task(id: criteres) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await rafraichir()
        }
        .onChange(of: modele.nombreRelevés) { profils = modele.chargerProfils() }
        .confirmationDialog("Delete “\(modele.nomListe)”?",
                            isPresented: $confirmerSuppression) {
            Button("Delete This List", role: .destructive) {
                modele.supprimerProfil(slugChoisi)
                profils = modele.chargerProfils()
                slugChoisi = profils.first(where: \.actif)?.slug ?? ""
            }
        } message: {
            Text("""
                Its address list and its history will be deleted. The ✓ and ✗ \
                are kept.
                """)
        }
    }

    // --- listes enregistrées ---

    private var sectionListes: some View {
        Section {
            // Le titre de la section EST le libellé du menu : le formulaire
            // pose l'un à gauche et l'autre à droite, il n'y a rien à aligner.
            Picker("Saved lists", selection: $slugChoisi) {
                ForEach(profils, id: \.slug) { p in Text(p.libelle).tag(p.slug) }
            }
            .onChange(of: slugChoisi) { _, nouveau in
                guard !nouveau.isEmpty, nouveau != modele.stockage.slugActif() else { return }
                guard modele.activerProfil(nouveau) else {
                    slugChoisi = modele.stockage.slugActif() ?? ""
                    return
                }
                profils = modele.chargerProfils()
            }
            // Sur sa propre ligne, comme « Reset Filters » dans l'onglet
            // Filtres : une action n'a pas à se serrer contre le réglage
            // qu'elle détruit.
            Button("Delete This List…", role: .destructive) {
                confirmerSuppression = true
            }
            .disabled(slugChoisi.isEmpty)
        } footer: {
            Text("Each list keeps its own address list and its own history.")
        }
    }

    // --- ce qu'aucun choix ne retire ---

    private var sectionSocle: some View {
        Section {
            // ─── La phrase pour tout le monde, la requête au survol ──────────
            //
            // Deux publics, une ligne. Qui installe l'app veut lire « Minecraft,
            // Java Edition · port 25565 » ; qui la modifie veut savoir ce qui
            // part vraiment chez Shodan. `.help` est le mécanisme que macOS
            // réserve exactement à ça — le détail technique disponible au
            // survol, absent le reste du temps.
            //
            // ⚠️ Et la phrase est CONSTRUITE des mêmes morceaux que la requête
            // (`Criteres.produit`, `Criteres.portTexte`). Écrite en dur, elle
            // aurait continué d'annoncer le port 25565 après qu'on en ait changé
            // — dans l'onglet dont le rôle est d'annoncer ce qui est cherché.
            // Seul « Java Edition » reste une phrase : l'édition ne figure pas
            // dans la requête, c'est le port qui la détermine, et le pied de
            // section l'explique.
            Label("\(Criteres.produit), Java Edition · port \(Criteres.portTexte)",
                  systemImage: "lock")
                .help(Criteres.socle)
                // Atténué parce que rien ici ne se règle : c'est un constat, pas
                // un choix. La taille, elle, est celle du formulaire.
                .foregroundStyle(.secondary)
        } header: {
            Text("Always searched")
        } footer: {
            Text("""
                TCP only. MC Watch does not support the UDP protocol (Bedrock) \
                yet.
                """)
        }
    }

    // --- les critères ---

    private var sectionCriteres: some View {
        Section {
            menu("Version", versions, $criteres.versions)
            menu("Country", pays, $criteres.pays)
            menu("Host", hebergeurs, $criteres.hebergeurs)
            // `prompt:` sépare les deux rôles que le champ confondait : le
            // titre devient le libellé de la ligne, que le formulaire aligne
            // avec les autres, et « text » reste dans le champ pour dire
            // que le laisser vide ne filtre rien.
            TextField("MOTD contains", text: $criteres.motd,
                      prompt: Text("text"))
            Picker("How many", selection: $criteres.taille) {
                ForEach(tailles, id: \.self) { t in
                    Text("\(t) servers — \(max(1, (t + 99) / 100)) credits").tag(t)
                }
            }
        } header: {
            Text("Narrow it down")
        }
    }

    /// Un menu à choix multiple. Shodan accepte la virgule entre valeurs —
    /// vérifié : `org:"OVH SAS","Hetzner Online GmbH"` rend exactement la somme
    /// des deux séparément, tandis que le mot-clé `OR` est refusé.
    ///
    /// Un `Menu` et non un `Picker` : SwiftUI n'a pas de sélecteur à choix
    /// multiple sur macOS, et cocher plusieurs valeurs est bien ce qu'on veut
    /// ici. `LabeledContent` lui donne la même colonne qu'aux autres lignes.
    private func menu(_ titre: LocalizedStringKey, _ choix: [Choix],
                      _ selection: Binding<[String]>) -> some View {
        LabeledContent(titre) {
            Menu {
                if selection.wrappedValue.isEmpty == false {
                    Button("Clear") { selection.wrappedValue = [] }
                    Divider()
                }
                ForEach(choix) { c in
                    Toggle(isOn: Binding(
                        get: { selection.wrappedValue.contains(c.id) },
                        set: { oui in
                            if oui { selection.wrappedValue.append(c.id) }
                            else { selection.wrappedValue.removeAll { $0 == c.id } }
                        })) {
                        Text(verbatim: "\(c.libelle)   \(Nombre.texte(c.nombre))")
                            .id(locale)
                    }
                }
            } label: {
                Text(selection.wrappedValue.isEmpty ? String(localized: "any")
                                                    : selection.wrappedValue.joined(separator: ", "))
            }
            .disabled(choix.isEmpty)
        }
    }

    // --- le devis, et l'achat ---

    private var sectionDevis: some View {
        Section {
            if let total {
                Text("Matching servers: \(total). The search will fetch \(min(total, criteres.taille)).")
            } else if occupe {
                // `ProgressView` porte son propre libellé : la pile horizontale
                // montée à la main autour d'un `Text` séparé faisait le même
                // travail, en moins bien aligné.
                ProgressView("Counting…").controlSize(.small)
            }
            Button("Create This List (\(criteres.credits) credits)") {
                Task { await creer() }
            }
            .disabled(occupe || total == nil || total == 0)
            if !message.isEmpty {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Credits are only spent when the list is created.")
        }
    }

    // MARK: - Réseau

    private func api() -> Shodan? {
        guard let cle = Cle.courante() else { return nil }
        return Shodan(cle: cle)
    }

    /// Un compte et trois facettes, tous gratuits, tous sur la requête courante.
    ///
    /// Les facettes portent sur la requête DÉJÀ restreinte : après avoir choisi
    /// le Japon, le menu des versions montre les versions japonaises avec leurs
    /// comptes. Explorer et choisir deviennent le même geste.
    private func rafraichir() async {
        guard let api = api() else { message = String(localized: "No Shodan API key saved."); return }
        occupe = true; defer { occupe = false }
        message = ""
        do {
            total = try await api.compter(criteres.requete())
            // La facette est plafonnée à 1000 par l'abonnement ; à ce niveau
            // elle couvre 99,2 % du total, mesuré.
            let brutes = try await api.facette(criteres.requete(sans: .version), "version", 1000)
            versions = VersionMC.regrouper(brutes).prefix(40).map {
                Choix(id: $0.version ?? "",
                      libelle: $0.version ?? String(localized: "no version announced"),
                      nombre: $0.nombre)
            }.filter { !$0.id.isEmpty }
            pays = try await api.facette(criteres.requete(sans: .pays), "country", 40)
                .map { Choix(id: $0.valeur, libelle: $0.valeur, nombre: $0.nombre) }
            hebergeurs = try await api.facette(criteres.requete(sans: .hebergeur), "org", 40)
                .map { Choix(id: $0.valeur, libelle: $0.valeur, nombre: $0.nombre) }
        } catch {
            message = error.localizedDescription
            total = nil
        }
    }

    private func creer() async {
        guard let api = api() else { return }
        occupe = true; defer { occupe = false }
        message = String(localized: "Searching…")

        let requete = criteres.requete()
        let etiquette = criteres.etiquette
        let slug = Slug.depuis(etiquette)
        do {
            let cibles = try await api.chercher(requete, limite: criteres.taille)
            guard !cibles.isEmpty else {
                message = String(localized: "The search returned nothing.")
                return
            }
            let neuf = !modele.stockage.listerSlugs().contains(slug)
            try modele.stockage.ecrireCibles(slug, cibles)
            try modele.stockage.ecrireTexte(slug, "recherche.txt", etiquette)
            try modele.stockage.ecrireTexte(slug, "requete.txt", requete)
            if neuf { try modele.stockage.ecrireHistorique(slug, Historique()) }
            try modele.stockage.definirActif(slug)

            message = String(localized: "List “\(etiquette)” created: \(cibles.count) servers. First scan…")
            // Forcé : relancer la MÊME recherche réécrit `liste.tsv` sans
            // toucher à l'historique, dont la date sert de garde.
            modele.recharger(force: true)
            modele.surveillerRelevés()
            await modele.releverMaintenant()
            message = String(localized: "List “\(etiquette)” created: \(cibles.count) servers.")
            profils = modele.chargerProfils()
            slugChoisi = slug
            // Le seul geste de l'app qui dépense. Sans ce relevé forcé, le
            // panneau Compte gardait l'ancien solde jusqu'au passage horaire du
            // scanner — soit près d'une heure d'affichage faux, précisément à
            // l'instant où l'on vient de payer et où l'on regarde le compteur.
            await modele.rafraichirCredits()
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Filtres du classement

struct VueFiltres: View {
    @Bindable var modele: Modele

    var body: some View {
        Form {
            Section("How many players") {
                nombre("Minimum player peak", $modele.filtres.picMin)
                nombre("Maximum player peak", $modele.filtres.picMax)
                nombre("Minimum regularity (%)", $modele.filtres.regularite)
            }
            Section("What kind of server") {
                nombre("Maximum slots", $modele.filtres.slotsMax)
                Toggle("Exclude networks (Velocity/Bungee proxy)",
                       isOn: $modele.filtres.sansProxy)
                Toggle("Exclude promotional MOTDs",
                       isOn: $modele.filtres.sansPub)
                Toggle("Hide advertised whitelists",
                       isOn: $modele.filtres.masquerWhitelist)
                Toggle("Only never-configured MOTDs",
                       isOn: $modele.filtres.motdParDefautSeulement)
                Toggle("Home connections only",
                       isOn: $modele.filtres.residentielSeulement)
            }
            Section("Servers already tried") {
                // Rangé avec les autres « ne me montre plus ça », et non parmi
                // les critères de qualité : ce n'est pas une propriété du
                // serveur, c'est ce qu'on accepte de voir.
                Toggle("Hide servers that did not answer the last scan",
                       isOn: $modele.filtres.masquerMuets)
                Toggle("Hide servers marked ✗", isOn: $modele.filtres.masquerRates)
                Toggle("Hide servers marked ✓", isOn: $modele.filtres.masquerReussis)
            }
            // Pas de note sous cette section : elle disait « 0 = pas de limite,
            // sauf pour le pic minimum » et « les changements s'appliquent tout
            // de suite ». Le premier point est déjà dans le libellé du champ,
            // « (0 = toutes) » ; le second décrit un comportement qui va de soi
            // dans une fenêtre de réglages, et qu'aucune autre section n'annonce.
            Section {
                nombre("Number of rows (0 = all)", $modele.filtres.lignes)
            } header: {
                Text("Display")
            }
            Section {
                Button("Reset Filters") { modele.reinitialiserFiltres() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: modele.filtres) { _, _ in modele.enregistrerFiltres() }
    }

    /// `LocalizedStringKey` : typé `String`, ce paramètre faisait prendre à
    /// `TextField` son initialiseur verbatim, et ces quatre libellés étaient
    /// **intraduisibles** — quelle que soit la table fournie.
    private func nombre(_ titre: LocalizedStringKey, _ valeur: Binding<Int>) -> some View {
        TextField(titre, value: valeur, format: .number)
            .multilineTextAlignment(.trailing)
    }
}

// MARK: - Mentions légales

/// Les « Appropriate Legal Notices » que la GPL v3 définit en §0 : le
/// copyright, l'absence de garantie, le droit de redistribuer, et un chemin
/// visible vers le texte de la licence. Elles n'ont leur sens que si la copie
/// existe dans le paquet — `construire.sh` y dépose `LICENSE.txt`.
///
/// Le lien vers les sources n'est pas décoratif non plus : distribuer un binaire
/// oblige à en proposer le source (§6), et un dépôt public est la façon la plus
/// simple de le faire.
struct VueAPropos: View {
    let maj: MiseAJour

    private static let depot = "https://github.com/Minortos/MCWatch"
    /// Les versions publiées, telles qu'un humain peut les lire. C'est la même
    /// liste que celle où l'app va chercher son `appcast.xml`, mais en page —
    /// pour qui veut vérifier de ses yeux ce que la mise à jour lui propose.
    private static let versions = "https://github.com/Minortos/MCWatch/releases"

    private var version: String {
        let court = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return [court, build.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
    }

    @State private var licenceAffichee = false
    @Environment(\.colorScheme) private var schema
    @Environment(\.controlActiveState) private var etatFenetre

    @State private var icone = VueAPropos.iconeSysteme()

    /// La taille de l'icône, accordée à celle du texte qu'elle accompagne.
    ///
    /// ⚠️ **Mesuré, et le résultat déçoit** : porter « Taille du texte » de
    /// Réglages Système ▸ Accessibilité ▸ Moniteur de 15 à 17 pt ne change
    /// RIEN ici, ni à chaud ni après relance. Ce réglage ne touche que les apps
    /// qui adoptent la taille de lecture — celles que le panneau énumère, toutes
    /// d'Apple — et une app SwiftUI ordinaire n'en fait pas partie.
    ///
    /// Gardé quand même, et sans prétendre qu'il sert aujourd'hui : c'est l'API
    /// prévue pour cette question, elle ne coûte rien, et elle répondra le jour
    /// où le mécanisme s'étendra — ou si un conteneur pose un
    /// `dynamicTypeSize`. Ce qui est acquis en attendant : la taille n'est plus
    /// écrite au milieu de la mise en page, elle est nommée.
    @ScaledMetric(relativeTo: .title2) private var tailleIcone: CGFloat = 72

    /// L'icône **telle que le système la compose**, pas le fichier du paquet.
    ///
    /// `NSImage(named: .applicationIconName)` est l'image nommée que macOS
    /// réserve à l'icône de l'app : le système la résout lui-même, donc elle
    /// porte le style choisi dans Réglages → Apparence — clair, sombre, teinté,
    /// translucide — exactement comme la vignette du Dock.
    ///
    /// La difficulté n'était pas l'API mais la FRAÎCHEUR, et le coupable était
    /// `NSImage(named:)` : les images nommées vivent dans une table de noms, et
    /// le MÊME objet revient à chaque appel — vérifié par identité. Relire ne
    /// servait donc à rien, et le seul rafraîchissement qu'on obtenait était le
    /// vidage de cette table au lancement : une mise à jour par démarrage, puis
    /// plus rien. `NSWorkspace.icon(forFile:)` interroge IconServices et rend un
    /// objet neuf à chaque appel, donc l'état courant du système.
    static func iconeSysteme() -> NSImage {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    /// La licence s'affiche DANS l'app, pas dans TextEdit.
    ///
    /// Un `Link` vers l'URL `file://` du paquet ne faisait rien : ouvrir un
    /// fichier chez un tiers passe par LaunchServices, qui doit délivrer au
    /// destinataire une autorisation sur un fichier enfermé dans notre bac à
    /// sable. Le bouton restait donc muet, ce qui est la pire réponse possible
    /// pour la seule mention que la GPL exige d'être atteignable (§0).
    ///
    /// Lire notre propre paquet, en revanche, est toujours permis.
    private var texteLicence: String {
        guard let u = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
              let t = try? String(contentsOf: u, encoding: .utf8)
        else {
            return String(localized: """
                The copy of the licence that ships with this app could not be \
                found. GNU General Public License, version 3: \
                https://www.gnu.org/licenses/gpl-3.0.html
                """)
        }
        return t
    }

    var body: some View {
        Form {
            Section {
                // Trois valeurs sont parties d'ici : l'écart entre l'icône et
                // le texte, celui entre les trois lignes, et la marge du bloc.
                // Le formulaire et la pile posent les leurs, et les reposeront
                // à leur façon le jour où macOS en changera d'avis.
                HStack {
                    Image(nsImage: icone)
                        .resizable()
                        // La quatrième, elle, RESTE — et elle doit rester.
                        // Une image bitmap n'a pas de taille naturelle à
                        // l'écran : sans cette ligne, `resizable` la laisse
                        // remplir tout ce qu'on lui donne. Apple en écrit une
                        // aussi dans son propre « À propos » de Réglages
                        // Système, sous la photo du Mac.
                        //
                        // Ce qui pouvait être rendu au système, c'est son
                        // ÉCHELLE : figée à 72 points, l'icône gardait sa
                        // taille pendant que le nom et la version grossissaient
                        // à côté d'elle, chez qui a agrandi le texte dans
                        // Réglages Système ▸ Affichage. `@ScaledMetric` accorde
                        // les deux, et 72 n'est plus une taille mais une base.
                        .frame(width: tailleIcone, height: tailleIcone)
                    VStack(alignment: .leading) {
                        Text("MC Watch").font(.title2).bold()
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Copyright © 2026 Minortos").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            // Placée sous l'identité de l'app, et pas dans un onglet à elle.
            // Un onglet « Updates » n'aurait porté que deux cases, et il aurait
            // séparé le numéro de version — juste au-dessus — de la seule chose
            // qu'on veuille en faire : savoir s'il en existe un plus grand.
            Section("Updates") {
                Toggle("Check for updates automatically",
                       isOn: Binding(get: { maj.verificationAutomatique },
                                     set: { maj.definirVerificationAutomatique($0) }))
                // Grisée quand rien ne cherche : installer automatiquement ce
                // qu'on ne cherche jamais ne veut rien dire. Sparkle applique
                // déjà cette règle de son côté ; la case le MONTRE, au lieu de
                // laisser cocher une option sans effet.
                Toggle("Download and install them automatically",
                       isOn: Binding(get: { maj.installationAutomatique },
                                     set: { maj.definirInstallationAutomatique($0) }))
                    .disabled(!maj.verificationAutomatique)

                HStack {
                    if let date = maj.derniereVerification {
                        Text("Last checked \(date.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never checked yet")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Même cas que les liens de l'onglet Compte : rapetissé
                    // alors que le bouton juste à côté ne l'est pas.
                    Link("All Versions", destination: URL(string: Self.versions)!)
                    Button("Check Now") { maj.verifier() }
                        .disabled(!maj.peutVerifier)
                }
            }

            Section {
                Text("""
                    MC Watch is free software: you can redistribute it and/or modify it \
                    under the terms of the GNU General Public License as published by the \
                    Free Software Foundation, either version 3 of the License, or (at your \
                    option) any later version.

                    This program is distributed in the hope that it will be useful, but \
                    WITHOUT ANY WARRANTY; without even the implied warranty of \
                    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU \
                    General Public License for more details.
                    """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("View the License") { licenceAffichee = true }
                        .buttonStyle(.link)
                    Spacer()
                    Link("Source Code", destination: URL(string: Self.depot)!)
                }
            } header: {
                Text("License")
            } footer: {
                // La mention Mojang occupait une SECTION à elle, sans titre :
                // une boîte grise pour une seule phrase que personne ne règle.
                // Elle appartient aux mentions légales, et le pied de la
                // licence est l'endroit exact où macOS met ce genre de ligne.
                Text("""
                    NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED \
                    WITH MOJANG OR MICROSOFT.
                    """)
            }


        }
        .formStyle(.grouped)
        .onChange(of: schema) { icone = Self.iconeSysteme() }
        // Même raison qu'ailleurs : on veut l'activation de CETTE fenêtre, pas
        // celle de n'importe laquelle.
        .onChange(of: etatFenetre) { _, etat in
            if etat == .key { icone = Self.iconeSysteme() }
        }
        .sheet(isPresented: $licenceAffichee) {
            VueLicence(texte: texteLicence)
        }
    }
}

/// Le texte de la GPL tel quel : chasse fixe et retours d'origine, parce qu'il
/// est mis en page à 72 colonnes et que le reflouer le rendrait illisible.
private struct VueLicence: View {
    let texte: String
    @Environment(\.dismiss) private var fermer

    /// Corps du texte, fixé plutôt qu'hérité d'un style dynamique : on mesure
    /// une largeur à partir de lui, les deux doivent donc parler de la même
    /// police.
    private static let corps: CGFloat = 11

    /// La ligne la plus longue de la GPL fait 78 caractères.
    private static let colonnes = 78

    /// Largeur du bloc, mesurée sur l'avance réelle de la police.
    ///
    /// Centrer le bloc ne suffisait pas : il se dimensionne sur sa ligne la plus
    /// longue, or celle-ci est perdue au milieu du document. À l'écran, on ne
    /// voyait que des lignes plus courtes (68 caractères de médiane), alignées à
    /// gauche dans un bloc plus large qu'elles — donc un texte qui semble
    /// décalé alors qu'il est centré. En taillant la feuille sur les 78
    /// colonnes, le bloc remplit la fenêtre et le décalage disparaît.
    private static let largeur: CGFloat = {
        let police = NSFont.monospacedSystemFont(ofSize: corps, weight: .regular)
        let avance = ("M" as NSString).size(withAttributes: [.font: police]).width
        return ceil(avance * CGFloat(colonnes))
    }()

    private static let marge: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(texte)
                    .font(.system(size: Self.corps, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(width: Self.largeur, alignment: .leading)
                    .padding(Self.marge)
            }
            // 35 000 caractères : sans ancrage explicite, la feuille peut
            // s'ouvrir ailleurs qu'au début du document.
            .defaultScrollAnchor(.top)
            Divider()
            HStack {
                Spacer()
                Button("Done") { fermer() }
                    .keyboardShortcut(.defaultAction)
            }
            // Marge du système : une barre de boutons de feuille en a une
            // d'usage, et 12 n'était qu'une approximation de celle-là.
            .padding()
        }
        .frame(width: Self.largeur + Self.marge * 2, height: 520)
    }
}

// MARK: -

enum Slug {
    /// Le nom de dossier d'une recherche, identique à celui du moteur Python
    /// pour que les listes existantes soient retrouvées et non dupliquées.
    static func depuis(_ filtres: String) -> String {
        var sortie = ""
        var tiret = false
        // ASCII uniquement, comme le `[^A-Za-z0-9]+` de Python : « é » doit
        // devenir un tiret des deux côtés, sinon les deux implémentations
        // fabriqueraient deux dossiers différents pour la même recherche.
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
