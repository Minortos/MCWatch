// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import MCWatchCore

/// Accueil de première ouverture.
///
/// L'app vit dans `/Applications`, donc partagée par tous les comptes du Mac,
/// mais le trousseau **et** `Application Support` sont propres à chaque session :
/// un autre utilisateur qui la lance n'hérite ni de la clé ni des listes du
/// voisin, et se retrouverait sinon devant un tableau vide sans explication.
struct VueBienvenue: View {
    @Bindable var modele: Modele
    @Environment(\.dismiss) private var fermer
    @Environment(\.openSettings) private var ouvrirReglages

    @State private var saisie = ""
    @State private var occupe = false
    @State private var message = ""
    @State private var echec = false
    @State private var cleOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            entete
            // Bandeau d'emplacement, en tête et hors du défilement : chez
            // quelqu'un qui vient de télécharger l'app, c'est LA chose à lire
            // avant tout le reste — la surveillance ne marchera pas tant que
            // l'app n'aura pas été déplacée. Ici on montre aussi le cas non
            // bloquant (« hors Applications »), parce que le premier lancement
            // est le bon moment pour ranger l'app, et le seul.
            if let avertissement = modele.avertissementEmplacement {
                Label(avertissement,
                      systemImage: modele.emplacementBloquant
                          ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(modele.emplacementBloquant ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            Divider()
            // Le corps est un FORMULAIRE, comme les cinq onglets des réglages.
            //
            // Il défile de lui-même, sépare ses deux étapes, encadre leurs
            // lignes et style leurs en-têtes et leurs notes de bas de section.
            // Trois `Divider()`, une marge de 22, deux espacements et deux faux
            // titres en `font(.headline)` faisaient ce travail à la main.
            //
            // L'ENVELOPPE reste composée, elle : macOS ne fournit aucune
            // fenêtre de bienvenue — Xcode, Pages et Keynote assemblent chacune
            // la leur — et une feuille porte son en-tête et sa barre d'action
            // hors du contenu qui défile.
            Form {
                sectionCle
                sectionListe
            }
            .formStyle(.grouped)
            Divider()
            barreBasse
        }
        .frame(width: 560, height: 480)
        .onAppear { cleOK = modele.cleConfiguree }
    }

    // MARK: - En-tête

    /// Même raison que l'icône d'À propos : une image bitmap n'a pas de taille
    /// à l'écran, et sans celle-ci `resizable` la laisse tout remplir. Nommée
    /// et mise à l'échelle plutôt qu'écrite au milieu de la mise en page.
    @ScaledMetric(relativeTo: .title2) private var tailleIcone: CGFloat = 54

    private var entete: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: tailleIcone, height: tailleIcone)
            VStack(alignment: .leading) {
                Text("Welcome to MC Watch").font(.title2).bold()
                Text("Search, watch and join home Minecraft servers with players from other countries!")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Étape 1 : la clé

    private var sectionCle: some View {
        Section {
            if cleOK {
                Text("""
                    A key is already saved.
                    """)
            } else {
                // Littéral d'un seul tenant, et c'est nécessaire : SwiftUI
                // n'interprète le markdown que pour un littéral. Une
                // concaténation produit un `String`, l'autre initialiseur est
                // choisi, et les astérisques s'affichent telles quelles.
                // Le prolongement de ligne par `\` garde un seul paragraphe.
                Text("""
                    MC Watch needs a Shodan API key to work. Every user of \
                    this Mac has to supply their own.
                    """)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    // Sans cadre imposé, comme dans l'onglet Compte : le champ
                    // est maintenant dans un formulaire, et macOS n'en dessine
                    // pas. L'invite tient lieu de libellé.
                    SecureField("Paste your key here", text: $saisie)
                        .onSubmit { Task { await valider() } }
                    Button("Verify") { Task { await valider() } }
                        .disabled(occupe || saisie.trimmingCharacters(in: .whitespaces).isEmpty)
                    if occupe { ProgressView().controlSize(.small) }
                }

                HStack {
                    Link("Where to find my key — account.shodan.io",
                         destination: URL(string: "https://account.shodan.io")!)
                    Spacer()
                    // Pour qui utilise déjà le CLI Shodan. C'est l'utilisateur
                    // qui désigne le fichier dans le sélecteur système : l'app
                    // n'a aucun droit dessus avant ce geste.
                    Button("Import from the Shodan CLI…") {
                        Task { await importer() }
                    }
                    .buttonStyle(.link)
                    .disabled(occupe)
                }
                .font(.caption)
            }

            if !message.isEmpty {
                Label(message, systemImage: echec ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(echec ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            titre(1, "Your Shodan API key", fait: cleOK)
        } footer: {
            // Ce que la section explique passe en pied : c'est là que le
            // formulaire met les notes, et il les style lui-même.
            if !cleOK {
                Text("""
                    Verifying is free, it spends no Shodan credit.
                    """)
            }
        }
    }

    // MARK: - Étape 2 : la première liste

    private var sectionListe: some View {
        Section {
            if modele.nombreListes > 0 {
                Text(listesDeja)
            } else {
                Text("""
                    A search such as “26.2 FR all” becomes a monitored list. \
                    MC Watch first counts **for free** how many servers match \
                    and announces the cost; a credit is spent only once you \
                    confirm.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                Text("""
                    MC Watch scans the state of the watched servers \
                    automatically, every 10 minutes by default.
                    """)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Create the First List…") {
                    fermer()
                    ouvrirReglages()
                }
                .disabled(!cleOK)
            }
        } header: {
            titre(2, "First search", fait: modele.nombreListes > 0)
        } footer: {
            // Grisé, le bouton ne dit pas POURQUOI. Le pied le dit, et il
            // disparaît dès que la clé est là.
            if !cleOK && modele.nombreListes == 0 {
                Text("Requires the Shodan key")
            }
        }
    }

    // MARK: - Bas de feuille

    private var barreBasse: some View {
        HStack {
            Text("Settings (⌘,).")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(cleOK ? "Done" : "Later") { fermer() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: -

    /// Le pluriel n'est plus bricolé par un « s » conditionnel : c'est le
    /// catalogue qui porte les variations, ce qui est la seule façon correcte
    /// pour le polonais ou le russe, qui en ont trois et quatre.
    private var listesDeja: String {
        String(localized: "\(modele.nombreListes) lists are already saved.")
    }

    /// `LocalizedStringKey` et non `String` : un paramètre typé `String` fait
    /// choisir à SwiftUI l'initialiseur verbatim, et le titre traversait la
    /// traduction sans jamais être cherché dans le catalogue.
    private func titre(_ numero: Int, _ texte: LocalizedStringKey, fait: Bool) -> some View {
        // Plus de `font(.headline)` ni d'espacement : posé en en-tête de
        // section, c'est le formulaire qui décide de sa graisse et de sa place.
        // La pastille reste — elle porte l'avancement, que le titre seul ne dit
        // pas — et ses deux teintes sont sémantiques.
        Label {
            Text(texte)
        } icon: {
            Image(systemName: fait ? "checkmark.circle.fill" : "\(numero).circle.fill")
                .foregroundStyle(fait ? .green : .accentColor)
        }
    }

    private func valider(_ cle: String? = nil) async {
        occupe = true; defer { occupe = false }
        do {
            let infos = try await Cle.verifierEtEnregistrer(cle ?? saisie)
            cleOK = true
            echec = false
            saisie = ""
            message = String(localized: """
                Key saved. Account “\(infos.plan)”: \(infos.creditsRecherche) \
                search credits out of \(infos.plafondRecherche).
                """)
            await modele.rafraichirCredits()
        } catch {
            echec = true
            message = error.localizedDescription
        }
    }

    /// La clé importée passe par **exactement** la même vérification que celle
    /// tapée à la main : un fichier `api_key` périmé ne doit pas être enregistré
    /// sous prétexte qu'il vient du CLI.
    private func importer() async {
        guard let cle = ImportCLI.choisirFichierCle() else { return }
        await valider(cle)
    }
}
