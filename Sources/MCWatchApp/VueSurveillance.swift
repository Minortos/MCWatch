// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MCWatchCore

/// La surveillance : ce qui tourne en fond, à quelle cadence, et sur quoi.
///
/// ─── Pourquoi l'onglet porte enfin son nom ──────────────────────────────────
///
/// Il s'appelait « Monitoring » et ne pouvait ni la démarrer, ni l'arrêter, ni
/// dire si elle tournait. L'interrupteur vivait dans le menu, seul, et l'onglet
/// réglait pendant ce temps des cadences qui ne s'appliquaient à rien quand
/// l'agent était éteint — sans jamais le dire. Trois API de `Agent` écrites
/// pour cette page (`etat`, l'attente d'autorisation, l'ouverture des Réglages
/// Système) n'étaient appelées de nulle part.
///
/// L'ordre des sections suit la question qu'on se pose en arrivant : est-ce que
/// ça tourne, sur quoi, à quel rythme, et selon quelles règles.
///
/// ─── Ce que cette page n'affiche pas ────────────────────────────────────────
///
/// L'état des serveurs suivis. Ils sont épinglés au tableau principal, avec les
/// mêmes colonnes que tout le reste — pays, pic, joueurs, version, MOTD. Le
/// redire ici, en plus petit et en moins bien, ne ferait qu'un second endroit à
/// tenir à jour. Les réglages désignent des serveurs ; le tableau les montre.
struct VueSurveillance: View {
    @Bindable var modele: Modele

    @State private var saisie = ""
    @State private var occupe = false
    @State private var message = ""
    @State private var echec = false
    /// L'adresse valide qui n'a pas répondu, en attente de confirmation.
    @State private var muette: Surveillance.Adresse?

    /// L'activation de CETTE fenêtre, et non de n'importe laquelle — même
    /// distinction que dans le volet À propos, qui s'en sert pour relire
    /// l'icône du système.
    @Environment(\.controlActiveState) private var etatFenetre

    var body: some View {
        Form {
            sectionEtat
            sectionServeurs
            sectionCadence
            sectionPortee
        }
        .formStyle(.grouped)
        // L'état de l'agent est relu à l'ouverture du volet et à chaque retour
        // au premier plan : ce sont les deux instants où l'utilisateur revient
        // d'un aller-retour dans Réglages Système, donc les deux seuls où la
        // réponse a pu changer sans que l'app le sache.
        .onAppear { modele.relireEtatAgent() }
        .onChange(of: etatFenetre) { _, etat in
            if etat == .key { modele.relireEtatAgent() }
        }
        .confirmationDialog("That server did not answer.",
                            isPresented: Binding(get: { muette != nil },
                                                 set: { if !$0 { muette = nil } })) {
            Button("Watch It Anyway") {
                if let a = muette { Task { await valider(a.texte, malgreLeSilence: true) } }
                muette = nil
            }
        } message: {
            Text("""
                The address is well formed, but nothing replied. That is expected \
                if the server is simply switched off — and knowing when it comes \
                back is exactly what watching it is for.
                """)
        }
    }

    // MARK: - Ce qui tourne en fond

    /// L'état de l'agent, ce qu'il a produit, et le seul cas où macOS attend
    /// quelque chose de l'utilisateur.
    private var sectionEtat: some View {
        Section {
            // ─── Un ÉTAT, et non plus un interrupteur ────────────────────────
            //
            // Il y avait ici une case « Scan in the background », doublée d'une
            // entrée de menu. Toutes deux enregistraient ou retiraient l'agent
            // — c'est-à-dire qu'elles éteignaient le produit : surveiller des
            // adresses est ce que fait cette app, pas une option qu'on lui
            // ajoute. L'agent s'installe donc au premier lancement, et la seule
            // façon de l'arrêter est celle que macOS offre pour TOUTES les apps,
            // dans Réglages Système ▸ Ouverture et extensions.
            //
            // Ce qui reste ici en dit plus que la case n'en disait : la case
            // affirmait ce que l'app avait demandé, cette ligne montre ce que
            // le système répond.
            LabeledContent("Status") {
                Label(modele.etatAgent.libelle, systemImage: symboleEtat)
                    .foregroundStyle(teinteEtat)
            }

            // Le seul état sur lequel on puisse agir, et le chemin pour le
            // faire. Les autres se contentent de se nommer dans la ligne
            // ci-dessus.
            if modele.etatAgent == .attenteAutorisation {
                // Une PILE, comme la ligne du dernier relevé juste en dessous,
                // et non un `LabeledContent`.
                //
                // Cette ligne n'est pas une paire libellé/valeur : c'est une
                // phrase et l'action qui va avec. Posée en `label:`, elle
                // recevait le style d'un libellé — celui de « Status » — qu'il
                // fallait ensuite annuler d'un `.secondary`. La teinte ne
                // servait qu'à défaire ce que le mauvais conteneur imposait ;
                // dans une pile, elle dit simplement que la phrase est
                // secondaire, comme partout ailleurs dans l'app.
                HStack {
                    Text("macOS is waiting for your approval.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…") { Agent.ouvrirReglagesOuverture() }
                        .buttonStyle(.link)
                }
            }

            // Même disposition que « Dernière vérification / Vérifier
            // maintenant » dans À propos : la date de ce qui s'est produit tout
            // seul, et le bouton pour le provoquer à la main.
            HStack {
                // `.secondary` suffit à dire « secondaire » ; le
                // `.callout` qui l'accompagnait le disait une seconde fois, en
                // rapetissant une ligne que le formulaire dimensionne déjà.
                Text(dernierReleve)
                    .foregroundStyle(.secondary)
                Spacer()
                if modele.chargement { ProgressView().controlSize(.small) }
                Button("Scan Now") { Task { await modele.releverMaintenant() } }
                    .disabled(modele.chargement)
            }
        } header: {
            Text("Background monitoring")
        } footer: {
            Text(explicationEtat)
        }
    }

    /// Pastille pleine pour les états stables, triangle pour ce qui réclame un
    /// geste : ce sont les deux symboles que macOS emploie pour cette
    /// distinction, et non une signalétique inventée ici.
    private var symboleEtat: String {
        switch modele.etatAgent {
        case .active, .arretee:                        "circle.fill"
        case .attenteAutorisation, .impossible:        "exclamationmark.triangle.fill"
        case .introuvable, .inconnu:                   "questionmark.circle.fill"
        }
    }

    /// Teintes SÉMANTIQUES et non choisies : elles suivent le contraste, le
    /// thème et les réglages d'accessibilité. Aucune valeur n'est décidée ici.
    private var teinteEtat: Color {
        switch modele.etatAgent {
        case .active:                                  .green
        case .attenteAutorisation, .impossible:        .orange
        case .arretee, .introuvable, .inconnu:         .secondary
        }
    }

    /// Le pied dit ce que l'état ne dit pas : où aller, ou ce qu'il en coûte.
    private var explicationEtat: String {
        switch modele.etatAgent {
        case .impossible:
            modele.avertissementEmplacement ?? modele.etatAgent.libelle
        case .attenteAutorisation, .arretee, .introuvable, .inconnu:
            String(localized: """
                Monitoring is switched off in System Settings ▸ General ▸ \
                Login Items & Extensions.
                """)
        case .active:
            String(localized: """
                The agent automatically updates the list selected in the \
                Search tab - Uses TCP - Spends no Shodan credit.
                """)
        }
    }

    private var dernierReleve: String {
        guard let quand = modele.dernierReleve else {
            return String(localized: "No scan yet")
        }
        // `.relative` plutôt qu'une date : ce qu'on veut savoir est « est-ce
        // récent ? », et le système compose la phrase dans la langue et les
        // usages de la session.
        return String(localized: "Last scan \(quand.formatted(.relative(presentation: .named)))")
    }

    // MARK: - Les serveurs suivis

    /// La liste, et le champ qui l'allonge.
    ///
    /// Chaque adresse est une LIGNE du formulaire, et non une liste imbriquée
    /// dans une boîte. Une `List` posée là demandait une hauteur — inventée,
    /// forcément — et un fond dessiné pour ne pas flotter. Le formulaire sait
    /// déjà encadrer ses lignes, les espacer et les séparer.
    private var sectionServeurs: some View {
        Section {
            if modele.adressesSurveillees.isEmpty {
                // Une ligne, pas une vue pleine page. `ContentUnavailableView`
                // était posé ici : c'est le composant que macOS réserve à une
                // FENÊTRE vide — Finder sur un dossier vide, Mail sans message —
                // et il se dimensionne pour ça. Dans une section de formulaire
                // il ouvrait un vide de deux cents points au-dessus du champ,
                // pour dire ce qu'une phrase dit sur une ligne.
                Text("No server watched yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(modele.adressesSurveillees, id: \.adresse) { cible in
                    // L'adresse est une donnée, pas un libellé : cet
                    // initialiseur-ci prend un `String` et ne passe donc pas par
                    // le catalogue de traduction.
                    LabeledContent(cible.adresse) {
                        Button("Stop Watching", systemImage: "minus.circle.fill") {
                            retirer(cible.adresse)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Stop watching this server")
                    }
                }
            }

            HStack {
                // Aucun style imposé, et un exemple en guise d'invite.
                //
                // Le champ portait `.roundedBorder`, posé pour qu'on le voie :
                // vide et sans cadre, on ne devinait pas qu'on pouvait y taper.
                // Mais un champ de formulaire, macOS le dessine SANS bordure —
                // vérifié dans Réglages Système, où « Nom » de l'ordinateur est
                // éditable et n'en a aucune. L'invite règle le même problème
                // sans rien imposer : la ligne n'est plus vide, et le rendu
                // reste celui que le système choisira demain.
                TextField("Address or host name", text: $saisie,
                          prompt: Text(verbatim: "mc.example.com"))
                    .onSubmit { Task { await valider(saisie) } }
                    .disabled(occupe)
                Button("Add") { Task { await valider(saisie) } }
                    .disabled(occupe || saisie.trimmingCharacters(in: .whitespaces).isEmpty)
                if occupe { ProgressView().controlSize(.small) }
            }

            if !message.isEmpty {
                // Un retour d'action se lit ; il portait une taille réduite
                // en plus de sa teinte, ce qui l'effaçait au moment précis où
                // l'on attend une réponse.
                Label(message, systemImage: echec ? "exclamationmark.triangle"
                                                  : "checkmark.circle")
                    .foregroundStyle(echec ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Custom list")
        } footer: {
            // Le pied de section porte le style des textes explicatifs — plus
            // petit, atténué, replié sur la largeur. Écrit à la main en
            // `.font(.caption)` et `.fixedSize`, il faudrait le réécrire le jour
            // où macOS en change ; là, non.
            Text("""
                Add your own servers to the watch list.
                """)
        }
    }

    // MARK: - Cadence

    private var sectionCadence: some View {
        Section {
            // La recherche d'abord : c'est elle qui tourne le plus vite, et
            // c'est pour elle que l'app existe. Les serveurs choisis à la main
            // sont l'exception, et une exception se lit après la règle.
            cadence("Shodan list", \.cadenceRecherche)
            cadence("Custom list", \.cadenceSurveillance)
        } header: {
            Text("How often")
        } footer: {
            Text(explicationCadence)
        }
        // Grisée avec la surveillance, pour la même raison que « télécharger
        // automatiquement » l'est sans « vérifier automatiquement » : régler la
        // cadence de ce qui ne tourne pas ne veut rien dire. Le réglage est
        // gardé, il reprendra tel quel au rallumage.
        .disabled(!modele.surveillanceActive)
    }

    private func cadence(_ titre: LocalizedStringKey,
                         _ champ: WritableKeyPath<ReglagesSurveillance, Int>) -> some View {
        Picker(titre, selection: Binding(
            get: { modele.reglagesSurveillance[keyPath: champ] },
            // Un seul champ change, et le modèle part du disque pour le reste.
            // Recomposer la valeur entière ici réécrivait l'autre cadence avec
            // ce que la vue avait en mémoire — la valeur d'usine, tant que la
            // fenêtre principale n'avait pas encore rechargé.
            set: { nouveau in
                modele.modifierReglagesSurveillance { $0[keyPath: champ] = nouveau }
            })) {
                ForEach(Surveillance.cadences, id: \.self) { m in
                    Text(libelleCadence(m)).tag(m)
                }
            }
    }

    /// Le libellé porte la conséquence, pas seulement la valeur — comme le
    /// sélecteur de taille de liste annonce son coût en crédits. Dix minutes,
    /// c'est six passages par heure : autant le dire.
    private func libelleCadence(_ minutes: Int) -> String {
        let parHeure = 60 / minutes
        return parHeure == 1
            ? String(localized: "Every \(minutes) minutes — once an hour")
            : String(localized: "Every \(minutes) minutes — \(parHeure) times an hour")
    }

    /// ⚠️ Ce texte disait le contraire de ce que le code fait, dans ses deux
    /// versions : « le Mac se réveille une fois, pas deux » quand les cadences
    /// étaient égales, « il se réveille pour chacune à son tour » sinon.
    ///
    /// L'agent n'a qu'UN intervalle, `StartInterval`, fixé à dix minutes dans
    /// son plist et jamais modifié — c'est même la raison pour laquelle les
    /// cadences sont toutes des multiples de dix (voir `Surveillance.pas`). Le
    /// Mac se réveille donc à ce rythme quoi qu'on choisisse ici, et le scanner
    /// décide à chaque réveil ce qu'il y a lieu de pinger. Aucun réglage de
    /// cette page ne peut ajouter ni retirer un réveil.
    private var explicationCadence: String {
        String(localized: """
            The agent ALWAYS wakes every ten minutes and decides what to ping \
            — a thirty-minute list works one wake in three.
            """)
    }

    // MARK: - Portée des filtres

    private var sectionPortee: some View {
        Section {
            Toggle("Apply the ranking filters to these servers too",
                   isOn: Binding(get: { modele.reglagesSurveillance.filtrerSurveillance },
                                 set: { nouveau in
                                     modele.modifierReglagesSurveillance {
                                         $0.filtrerSurveillance = nouveau
                                     }
                                 }))
        }
        // Plus de note sous cette section : « Désactivé par défaut » ne disait
        // rien que l'interrupteur ne montre déjà, éteint.
    }

    // MARK: - Ajouter, retirer

    /// Le message dit toujours la DERNIÈRE chose qui s'est produite.
    ///
    /// Il ne s'effaçait jamais : « Now watching mc.exemple.com. » restait à
    /// l'écran après qu'on avait retiré ce même serveur, sous une liste vide
    /// qui le démentait.
    private func retirer(_ adresse: String) {
        echec = !modele.retirerSurveillance(adresse)
        message = echec ? String(localized: "That server could not be removed.") : ""
    }


    private func valider(_ texte: String, malgreLeSilence: Bool = false) async {
        occupe = true
        defer { occupe = false }
        switch await modele.ajouterSurveillance(texte, malgreLeSilence: malgreLeSilence) {
        case .ajoute(let a):
            saisie = ""; echec = false
            message = String(localized: "Now watching \(a).")
        case .deja(let a):
            echec = true
            message = String(localized: "\(a) is already watched.")
        case .refuse(let r):
            echec = true
            message = r.explication
        case .muet(let a):
            message = ""; echec = false
            muette = a
        case .echec:
            echec = true
            // Le détail est déjà dans le message de la fenêtre principale, posé
            // par `enregistrer` avec l'erreur du système. Ici on dit ce qui
            // compte : l'adresse n'est PAS surveillée, contrairement à ce que
            // « Now watching … » annonçait avant.
            message = String(localized: "That address could not be saved.")
        }
    }
}
