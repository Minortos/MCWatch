// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MCWatchCore

struct VueClassement: View {
    @Bindable var modele: Modele
    /// Les deux zones qui peuvent tenir le focus clavier.
    private enum Zone: Hashable { case tableau, recherche }

    /// **Un seul** état pour les deux, et c'est le fond du problème.
    ///
    /// Sans focus, la sélection du tableau reste GRISE — le gris est la
    /// sélection d'une vue qui n'a pas le focus — et `onKeyPress` ne voit ni
    /// Espace ni Entrée, puisqu'il ne reçoit rien sans focus.
    ///
    /// Deux `@FocusState<Bool>` séparés ne réglaient qu'une moitié : ce sont
    /// deux emplacements INDÉPENDANTS, et rien n'apprend à SwiftUI qu'activer
    /// l'un doit libérer l'autre. Le champ de recherche gardait donc le sien
    /// une fois cliqué, et le tableau ne reprenait plus jamais la main. Une
    /// valeur énumérée ne peut désigner qu'une zone à la fois : l'exclusion
    /// vient de la forme du type, pas d'un code qui pense à l'entretenir.
    @FocusState private var focus: Zone?

    /// L'état d'activation de la fenêtre qui porte cette vue.
    @Environment(\.controlActiveState) private var etatFenetre

    /// Le gestionnaire d'annulation **de la fenêtre**. C'est lui qui reçoit les
    /// marquages, pour que le menu Édition standard puisse les annuler — et
    /// pour qu'un champ de texte qui a le focus garde les siens.
    @Environment(\.undoManager) private var annulationFenetre

    /// Le tri survit à la fermeture de l'app, comme dans le Finder ou Mail.
    /// `KeyPathComparator` n'étant pas encodable, on retient une étiquette de
    /// colonne et un sens, et on reconstruit le comparateur au lancement.
    @AppStorage("tri") private var triEnregistre = "maxVu:desc"

    /// L'agencement des colonnes : ordre, visibilité, largeurs.
    ///
    /// C'est macOS qui fournit l'interaction — clic droit sur l'en-tête pour
    /// choisir les colonnes, glisser un en-tête pour le déplacer — exactement
    /// comme le Finder en mode liste. Rien de dessiné ici.
    ///
    /// Ce qui reste à notre charge : un identifiant stable par colonne
    /// (`customizationID`), sans quoi le système ne saurait pas de quelle
    /// colonne parlent les réglages relus ; et le rangement lui-même, le type
    /// étant `Codable` mais non persisté tout seul.
    /// ⚠️ **La clé change dès qu'une colonne apparaît, disparaît ou change
    /// d'identifiant**, et ce n'est pas une précaution de principe : c'est
    /// arrivé deux fois.
    ///
    /// `colonnes` avait été enregistrée alors que la colonne des marques
    /// n'avait pas d'identifiant ; la relire renvoyait le marqueur à droite,
    /// d'où `colonnes.v2`. Puis la colonne des épinglés est arrivée, et
    /// l'agencement déjà rangé sous `.v2` ne la connaissait pas — un
    /// `TableColumnCustomization` n'est qu'une liste ordonnée de colonnes
    /// identifiées, et celle qui manque est rejetée **en fin de tableau**.
    /// Relevé sur la valeur réelle : l'ordre enregistré finissait par
    /// « … hébergeur, MOTD, épinglés », alors que le code la déclare en
    /// deuxième position. Combinée à une fenêtre trop étroite, elle passait
    /// simplement hors champ.
    ///
    /// Un agencement ne survit donc pas à un changement de colonnes : on repart
    /// de l'ordre déclaré, et l'ancienne valeur est ignorée sans être effacée.
    ///
    /// `.v3` couvre les deux mouvements d'un coup — l'arrivée des épinglés,
    /// puis leur fusion avec les marques sous l'identifiant `etat` — parce
    /// qu'aucune version publiée n'a jamais écrit sous ce nom.
    @AppStorage("colonnes.v3") private var colonnesEnregistrees = ""
    @State private var colonnes = TableColumnCustomization<Serveur>()

    var body: some View {
        VStack(spacing: 0) {
            entete
            Divider()
            if modele.serveurs.isEmpty { vide } else { tableau }
            Divider()
            barreBasse
        }
        // Rien d'autre que le champ standard : pas de sélecteur de portée, donc
        // pas de barre segmentée ni de menu maison dans la barre d'outils. La
        // recherche couvre toutes les colonnes de texte.
        .searchable(text: $modele.recherche, placement: .toolbar, prompt: "Search")
        .searchFocused($focus, equals: .recherche)
        // Le trait sous la barre d'outils vient de son fond, que macOS pose
        // quand il croit du contenu défilant juste dessous — ici c'est un
        // en-tête fixe. SwiftUI n'expose pas le séparateur seul : c'est la
        // visibilité du fond qui le commande.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // ⌘F : le menu ne peut pas atteindre l'état de focus, qui vit dans la
        // vue. Il incrémente donc un compteur du modèle, que la vue observe.
        .onChange(of: modele.demandeFocusRecherche) { focus = .recherche }
        .onAppear {
            modele.tri = Tri.comparateurs(triEnregistre)
            // L'environnement n'est lisible que depuis une vue : le modèle ne
            // peut pas aller le chercher lui-même.
            modele.annulation = annulationFenetre
            if let d = colonnesEnregistrees.data(using: .utf8),
               let c = try? JSONDecoder().decode(TableColumnCustomization<Serveur>.self, from: d) {
                colonnes = c
            }
        }
        .onChange(of: colonnes) {
            if let d = try? JSONEncoder().encode(colonnes) {
                colonnesEnregistrees = String(decoding: d, as: UTF8.self)
            }
        }
        .onChange(of: modele.tri) { triEnregistre = Tri.etiquette(modele.tri) }
    }


    // MARK: - En-tête

    private var entete: some View {
        VStack(alignment: .leading) {
            // Bandeau : la surveillance est impossible d'ici, ou elle a cessé
            // de tourner. Le cas « hors Applications » n'y figure pas et est
            // signalé ailleurs (accueil, et au clic sur la surveillance) —
            // l'afficher en permanence reviendrait à harceler quelqu'un qui
            // range ses apps où il veut. Le tri est fait par `alerteEnTete`.
            if let avertissement = modele.alerteEnTete {
                Label(avertissement, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(modele.entete)
            Text("Filters: \(modele.resumeFiltres)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - Le tableau

    /// Les colonnes sont réparties en deux propriétés **typées explicitement**,
    /// et pas seulement pour la lisibilité : le constructeur n'accepte que dix
    /// colonnes par bloc, la note faisait la onzième, et surtout l'inférence de
    /// type renonçait sur une expression aussi longue (« unable to type-check
    /// this expression in reasonable time »). Annoncer le type coupe court.
    private typealias Tri1 = KeyPathComparator<Serveur>

    /// La largeur de chaque colonne, **et celle qu'il faut à la fenêtre**.
    ///
    /// ⚠️ Ce type existe à cause d'un défaut vécu : la colonne des épinglés a
    /// été ajoutée sans que le `minWidth` de la fenêtre, écrit ailleurs et en
    /// dur, ne soit réajusté. Ses vingt-deux points ont suffi à pousser le
    /// tableau au-delà du bord — une barre de défilement horizontale est
    /// apparue, la dernière colonne s'est fait couper, et la ligne
    /// sélectionnée a perdu ses coins arrondis en débordant du cadre.
    ///
    /// Le minimum est donc **calculé**, jamais recopié. Ajouter une colonne
    /// demain élargira la fenêtre du même coup, sans que personne ait à y
    /// penser — et c'est bien le fait d'avoir à y penser qui a manqué.
    enum Largeur {
        /// La colonne d'état — jumelles ou marque, jamais les deux : largeur
        /// fixe, ni triable ni redimensionnable.
        static let etat: CGFloat = 24

        // Les autres : un plancher, une largeur de départ, parfois un plafond.
        static let pays = (min: 44.0, ideal: 52.0, max: 90.0)
        static let pic = (min: 40.0, ideal: 48.0, max: 80.0)
        static let actu = (min: 52.0, ideal: 68.0, max: 96.0)
        static let slots = (min: 48.0, ideal: 56.0, max: 90.0)
        static let version = (min: 90.0, ideal: 106.0)
        static let peuple = (min: 62.0, ideal: 74.0, max: 120.0)
        static let adresse = (min: 140.0, ideal: 165.0)
        static let hebergeur = (min: 90.0, ideal: 125.0)
        static let motd = (min: 120.0, ideal: 220.0)

        /// Les largeurs de départ, **en liste**, et non additionnées à la
        /// main : c'est cette liste qu'on allonge en ajoutant une colonne, et
        /// tout ce qui suit s'ajuste — le total comme le compte.
        private static let depart: [CGFloat] = [
            etat, pays.ideal, pic.ideal, actu.ideal, slots.ideal,
            version.ideal, peuple.ideal, adresse.ideal, hebergeur.ideal, motd.ideal,
        ]

        /// Les mêmes colonnes, à leur PLANCHER.
        ///
        /// La distinction n'est pas cosmétique : `min` et `ideal` ne répondent
        /// pas à la même question. `ideal` dit la largeur qu'on souhaite —
        /// celle où une adresse et un MOTD se lisent sans se faire couper.
        /// `min` dit celle en dessous de laquelle la colonne ne peut plus
        /// descendre, et c'est **elle** qui décide jusqu'où la fenêtre peut
        /// être rétrécie.
        private static let planchers: [CGFloat] = [
            etat, pays.min, pic.min, actu.min, slots.min,
            version.min, peuple.min, adresse.min, hebergeur.min, motd.min,
        ]

        /// ⚠️ Ce que macOS ajoute AUTOUR du contenu de chaque cellule —
        /// remplissage des deux côtés, et le trait qui sépare la colonne de la
        /// suivante. `.width()` dimensionne le CONTENU, pas la colonne : la
        /// somme brute des largeurs ne dit donc pas ce que le tableau occupe.
        ///
        /// **Mesuré** quand le tableau en comptait onze : la somme donnait 960
        /// points, le tableau en demandait 1277 — vingt-neuf par colonne. Sans
        /// ce terme, la fenêtre paraissait assez large et coupait quand même la
        /// dernière colonne.
        private static let remplissage: CGFloat = 29

        /// L'ascenseur vertical, qui prend sa place à droite et que la somme
        /// des colonnes ignore elle aussi.
        private static let ascenseur: CGFloat = 16

        private static func total(_ colonnes: [CGFloat]) -> CGFloat {
            colonnes.reduce(0, +) + CGFloat(colonnes.count) * remplissage + ascenseur
        }

        /// La largeur en dessous de laquelle la fenêtre couperait une colonne.
        ///
        /// ⚠️ Elle se calculait sur les largeurs IDÉALES, et c'était trop : on
        /// ne pouvait plus rétrécir la fenêtre en dessous de la taille
        /// *confortable*, alors même que toutes les colonnes acceptaient d'être
        /// bien plus étroites. 1244 points imposés pour 1016 réellement
        /// nécessaires — deux cent vingt-huit points de fenêtre qu'on ne
        /// pouvait pas rendre.
        static let fenetre = total(planchers)

        /// Ce que la fenêtre demande **à la première ouverture**, quand aucune
        /// taille n'a encore été mémorisée : les largeurs idéales.
        ///
        /// Le minimum n'a jamais été le bon endroit pour dire ça. Un minimum
        /// contraint, une taille par défaut propose — les confondre revenait à
        /// imposer la seconde.
        static let fenetreConfortable = total(depart)
    }

    /// Un titre vide qui **n'entre pas** dans le catalogue de traduction.
    ///
    /// `TableColumn("")` prend le littéral pour une clé de localisation : le
    /// compilateur l'extrait, et le catalogue affiche une ligne « (Empty
    /// string) » à traduire dans les dix langues — une chaîne vide, dix fois.
    /// Passer une valeur **typée `String`** fait choisir l'autre initialiseur,
    /// celui qui ne localise rien. Même raison pour le sélecteur de listes des
    /// réglages, qui porte lui aussi un titre vide sous `.labelsHidden()`.
    static let sansTitre = ""

    /// La mesure derrière le pourcentage : combien de relevés peuplés sur
    /// combien de réponses. Sert au survol ET à VoiceOver — une seule phrase,
    /// donc une seule à traduire et une seule à tenir à jour.
    static func libellePeuple(_ s: Serveur) -> Text {
        Text("populated in \(s.toursPeuples) of \(s.toursVus) scans")
    }

    /// Ce que VoiceOver annonce pour la colonne des marques.
    ///
    /// Retourne une `LocalizedStringKey` et non une `String` : c'est ce qui
    /// fait entrer ces trois phrases dans le catalogue de traduction, au même
    /// titre que le reste de l'interface. Une `String` construite à la volée
    /// n'y entrerait pas, et l'app parlerait anglais à ceux qui en ont le plus
    /// besoin.
    static func libelleMarque(_ m: Marque?) -> Text {
        switch m {
        case .reussi: Text("Marked as worked")
        case .rate:   Text("Marked as failed")
        case nil:     Text("Not marked")
        }
    }

    @TableColumnBuilder<Serveur, Tri1>
    private var colonnesEtat: some TableColumnContent<Serveur, Tri1> {
        // ─── UNE seule colonne d'état, et non deux ──────────────────────────
        //
        // Les jumelles et le marquage occupaient chacune la leur, côte à côte,
        // et ne pouvaient jamais rien dire en même temps : un serveur qu'on a
        // tapé soi-même, on sait déjà s'il nous plaît — c'est bien pour ça
        // qu'on l'a ajouté. Les deux informations s'excluent, une colonne
        // suffit donc à les porter, et le tableau y gagne cinquante points de
        // largeur.
        //
        // La surveillance PRIME sur la marque, et le marquage lui est refusé
        // (voir `Modele.marquer`). Une marque déjà posée n'est pas effacée pour
        // autant : les verdicts sont rangés par adresse, pas par liste, et
        // celui-ci réapparaîtra si l'on cesse de surveiller le serveur.
        TableColumn(Self.sansTitre) { s in
                // Une seule consultation de chaque collection par ligne : ces
                // fermetures sont rebâties pour chaque cellule qui entre à
                // l'écran, c'est là que se joue la fluidité du défilement.
                let suivi = modele.epingles.contains(s.adresse)
                let m = suivi ? nil : modele.marque(s)
                Group {
                    if suivi {
                        Image(systemName: "binoculars.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Text(m?.signe ?? "")
                            .foregroundStyle(m == .reussi ? .green : .red)
                            .bold()
                    }
                }
                .accessibilityLabel(suivi ? Text("Watched") : Self.libelleMarque(m))
            }
            // Sans ceci, VoiceOver annonce « ✓ » — ou rien du tout — dans une
            // colonne qui n'a pas de titre à rappeler. Le symbole et la couleur
            // ne disent quelque chose qu'à l'œil ; c'est la seule colonne du
            // tableau dont le sens ne tient qu'à eux.
            //
            // ⚠️ `.width` AVANT `.customizationID` : le second change le type
            // rendu par le constructeur, et le premier n'y existe plus.
            //
            // Largeur fixe, et surtout **épinglée** en première position.
            //
            // ⚠️ Il ne suffit pas de lui refuser un identifiant pour qu'elle
            // reste en place — c'est l'inverse. L'agencement mémorisé n'est
            // qu'une liste ordonnée des colonnes **identifiées** ; une colonne
            // sans identifiant n'y figure pas, et se retrouve rejetée en fin de
            // tableau dès que l'utilisateur réordonne quoi que ce soit.
            // Constaté : le marqueur avait migré tout à droite.
            //
            // Il lui faut donc une identité pour tenir son rang, plus
            // l'interdiction explicite de bouger, de changer de largeur ou
            // d'être masquée — un repère visuel qui se déplace n'en est plus un.
            .width(Largeur.etat)
            .customizationID("etat")
            .disabledCustomizationBehavior(.all)

            TableColumn("COUNTRY", value: \.pays) { s in
                Text(s.pays.isEmpty ? "—" : s.pays)
                    .foregroundStyle(s.pays.isEmpty ? .tertiary : .primary)
                    .accessibilityLabel(s.pays.isEmpty ? Text("No country") : Text(s.pays))
            }
            .width(min: Largeur.pays.min, ideal: Largeur.pays.ideal, max: Largeur.pays.max)
            .customizationID("pays")

            // `Text(nombre, format:)` et non `Text("\(nombre)")` : l'interpolation
            // d'un entier dans un littéral en fait une **clé** de localisation
            // (« %lld »), qui atterrit dans le catalogue et n'y a rien à faire.
            // Le format numérique suit en prime les usages de la langue choisie.
            // `Nombre.texte` et non `format: .number` : les trois colonnes
            // chiffrées suivaient les conventions de la RÉGION là où le menu
            // des versions suivait les Réglages Système. Sur un Mac dont
            // « Format des nombres » vaut `1 234 567,89`, un pic de 1 097
            // s'écrivait donc « 1,097 » dans le tableau et « 1 097 » dans le
            // menu, à deux clics d'écart. Voir `Nombre` pour la mesure.
            TableColumn("PEAK", value: \.maxVu) { s in
                Text(verbatim: Nombre.texte(s.maxVu)).monospacedDigit()
            }
            .width(min: Largeur.pic.min, ideal: Largeur.pic.ideal, max: Largeur.pic.max)
            .customizationID("pic")

            // ⚠️ Un « 0 » disait DEUX choses opposées : personne connecté, ou
            // le serveur n'a pas répondu du tout. `Tour.fusionner` remet
            // `dernierOnline` à zéro sur tous les silencieux, si bien qu'un
            // serveur mort depuis quinze jours affichait le même chiffre qu'un
            // serveur vivant et vide.
            //
            // Le tiret est celui que l'app emploie partout ailleurs pour une
            // valeur qu'elle n'a pas — le pays inconnu, le solde jamais relevé.
            // Il ne se confond avec aucun nombre, et il dit ce qui est vrai :
            // on ne sait pas, faute de réponse.
            TableColumn("NOW", value: \.dernierOnline) { s in
                let repondu = modele.aRepondu(s)
                Text(verbatim: repondu ? Nombre.texte(s.dernierOnline) : "—")
                    .monospacedDigit()
                    .foregroundStyle(repondu && s.dernierOnline > 0 ? .primary : .tertiary)
                    .help(repondu ? Text("\(s.dernierOnline) connected at the last scan")
                                  : Text("Did not answer the last scan"))
                    .accessibilityLabel(repondu
                        ? Text("\(s.dernierOnline) connected at the last scan")
                        : Text("Did not answer the last scan"))
            }
            // Un peu plus large que les autres colonnes courtes : « ACTU » et
            // « NOW » tenaient dans 52 points, « TERAZ » et « СЕЙЧАС » non, et
            // l'en-tête se tronquait en « TER… ». La largeur reste réglable et
            // mémorisée ; ceci ne fixe que la valeur de départ.
            .width(min: Largeur.actu.min, ideal: Largeur.actu.ideal, max: Largeur.actu.max)
            .customizationID("actu")

            TableColumn("SLOTS", value: \.slots) { s in
                Text(verbatim: Nombre.texte(s.slots)).monospacedDigit()
            }
            .width(min: Largeur.slots.min, ideal: Largeur.slots.ideal, max: Largeur.slots.max)
            .customizationID("slots")

            TableColumn("VERSION", value: \.version) { s in Text(s.version) }
                .width(min: Largeur.version.min, ideal: Largeur.version.ideal)
                .customizationID("version")

            // Un rapport, pas une phrase : `verbatim` pour qu'il ne devienne pas
            // la clé « %lld/%lld » dans le catalogue.
            // ─── Le chiffre AFFICHÉ est enfin celui sur lequel on trie ───────
            //
            // La colonne montrait « 1186/1512 » et se triait sur le RATIO. Rien
            // à l'écran ne le disait : « 43/784 » pouvait passer au-dessus de
            // « 1186/1512 » sans qu'on comprenne, l'un valant 5 % et l'autre 78.
            //
            // Elle s'appelait aussi « POPULATED » — un adjectif, qui ne dit ni
            // « combien » ni « sur quoi » — pendant que le filtre agissant sur
            // cette même donnée s'appelait « Minimum regularity ». Deux mots
            // pour une notion, et rien ne reliait la colonne au filtre qui la
            // gouverne. C'est le nom du filtre qui l'emporte : il porte déjà
            // l'unité.
            //
            // La fraction n'est pas perdue pour autant : elle dit la TAILLE de
            // la mesure — 5/5 fait 100 % sans rien valoir — et passe au survol,
            // là où macOS met le détail dont la lecture ne dépend pas.
            TableColumn("REGULARITY", value: \.regularite) { s in
                Text(s.regularite, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    // La même phrase pour l'œil et pour VoiceOver. « 29/100 »
                    // se lisait d'un coup d'œil mais s'entendait mal : la barre
                    // oblique n'est pas prononcée, et il restait deux nombres
                    // sans rapport annoncé.
                    .help(Self.libellePeuple(s))
                    .accessibilityLabel(Self.libellePeuple(s))
            }
            // ⚠️ L'infobulle ne peut vivre que sur les CELLULES : `TableColumn`
            // n'accepte pas `.help`, et l'en-tête serait pourtant l'endroit où
            // le geste vient naturellement à qui se demande ce qu'est une
            // colonne. C'est une limite de SwiftUI, pas un choix.
            //
            // Raison de plus pour que le NOM porte le sens tout seul : c'est lui
            // qui relie la colonne au filtre « Minimum regularity », et une
            // infobulle ne rattraperait pas un nom obscur — personne ne survole
            // au hasard.
            .width(min: Largeur.peuple.min, ideal: Largeur.peuple.ideal, max: Largeur.peuple.max)
            .customizationID("peuple")
    }

    @TableColumnBuilder<Serveur, Tri1>
    private var colonnesTexte: some TableColumnContent<Serveur, Tri1> {
            // Pas de `.textSelection(.enabled)` ici : elle place chaque cellule
            // visible dans un conteneur de texte sélectionnable, ce qui coûte
            // cher au défilement pour un service que l'adresse rend déjà par
            // cinq autres chemins — ⌘C, double-clic, Espace, Entrée et le menu
            // contextuel.
            TableColumn("ADDRESS", value: \.adresse) { s in Text(s.adresse) }
                .width(min: Largeur.adresse.min, ideal: Largeur.adresse.ideal)
                .customizationID("adresse")

            // ⚠️ Le survol rend le texte ENTIER, et rien d'autre.
            //
            // Ces deux colonnes sont les seules dont le contenu déborde
            // couramment : « GMO Internet Group, I… », « Teleservice Bredband… »,
            // « Welcome to SpooderLex SMP! Surviv… ». La troncature est la
            // bonne réponse pour un tableau — c'est ce qui garde les colonnes
            // alignées — mais elle cache alors la seule chose que la cellule
            // avait à dire.
            //
            // Rien à ajouter pour VoiceOver : il lit le `Text` complet, la
            // troncature n'étant que visuelle. L'infobulle rend à l'œil ce que
            // l'oreille avait déjà.
            TableColumn("HOST", value: \.hebergeur) { s in
                Text(s.hebergeur)
                    .foregroundStyle(.secondary)
                    .help(s.hebergeur)
            }
            .width(min: Largeur.hebergeur.min, ideal: Largeur.hebergeur.ideal)
            .customizationID("hebergeur")

            TableColumn("MOTD", value: \.motd) { s in
                // Une alternative *dans* le `Text` produirait un `String`, donc
                // l'initialiseur verbatim, et « (no MOTD) » ne serait jamais
                // traduit. Les deux branches doivent être deux `Text` distincts.
                Group {
                    if s.motd.isEmpty { Text("(no MOTD)") } else { Text(s.motd) }
                }
                .foregroundStyle(s.motdParDefaut ? .secondary : .primary)
                // Le MOTD DÉJÀ NETTOYÉ, celui qui est à l'écran — pas la chaîne
                // brute du serveur avec ses codes de couleur. L'infobulle sert
                // à lire la fin d'un texte coupé, pas à exposer le protocole.
                //
                // Rien sur un MOTD vide : « (no MOTD) » tient dans la colonne,
                // le répéter au survol n'apprendrait rien.
                .help(s.motd)
            }
            .width(min: Largeur.motd.min, ideal: Largeur.motd.ideal)
            .customizationID("motd")
    }

    private var tableau: some View {
        Table(modele.serveurs, selection: $modele.selection, sortOrder: $modele.tri,
              columnCustomization: $colonnes) {
            colonnesEtat
            colonnesTexte
        }
        .contextMenu(forSelectionType: Serveur.ID.self) { _ in
            Button("Copy Address") { copierSelection() }
            Divider()
            Button("✓  Mark as Worked") { modele.marquer(.reussi) }
            Button("✗  Mark as Failed") { modele.marquer(.rate) }
            Button("Clear Mark") { modele.marquer(nil) }
        } primaryAction: { _ in
            copierSelection()          // double-clic
        }
        // Branche le Copier STANDARD (⌘C, Édition → Copier, glisser-déposer)
        // sur la sélection, au lieu d'un élément de menu maison.
        .copyable(modele.serveurSelectionne.map { [$0] } ?? [])
        .focused($focus, equals: .tableau)
        // Cliquer une ligne change la sélection mais NE DONNE PAS le focus au
        // tableau : le premier répondant reste le champ de recherche, donc la
        // sélection s'affiche en gris et le clavier ne répond pas. Mesuré : un
        // clic synthétisé sélectionne bien une ligne, et le premier répondant
        // reste `SearchTextView`.
        //
        // On le réclame donc explicitement. Le geste est SIMULTANÉ pour ne pas
        // consommer le clic — la sélection continue de se faire normalement.
        .simultaneousGesture(TapGesture().onEnded { focus = .tableau })
        // Le focus se donne ICI, à l'apparition du tableau, et pas sur la vue
        // parente : `recharger()` tourne dans un `.task`, donc au premier rendu
        // la liste est vide et c'est la vue « aucun serveur » qui est montée.
        // Un `defaultFocus` posé plus haut n'avait alors aucune cible, et le
        // tableau arrivait ensuite sans que personne ne lui donne le focus.
        //
        // Le report d'un tour de boucle est nécessaire : au moment du
        // `onAppear`, la vue n'est pas encore dans la chaîne de réponse, et
        // l'affectation serait perdue.
        .onAppear { rendreFocusAuTableau() }
        // La feuille de bienvenue prend le focus en s'ouvrant ; on le reprend
        // quand elle se referme, sinon la première session reste grise.
        .onChange(of: modele.montrerBienvenue) { _, montree in
            if !montree { rendreFocusAuTableau() }
        }
        // Revenir d'une autre app rend la fenêtre active mais ne redonne pas le
        // focus au tableau : la sélection restait grise et le clavier muet
        // jusqu'à ce qu'on reclique dedans.
        //
        // `controlActiveState` décrit l'état de LA fenêtre qui porte cette vue.
        // La notification `didBecomeKeyNotification`, elle, est postée par
        // n'importe quelle fenêtre : ouvrir les Réglages rappelait le focus sur
        // le tableau de la fenêtre principale, derrière.
        .onChange(of: etatFenetre) { _, etat in
            guard etat == .key else { return }
            rendreFocusAuTableau()
        }
        .onKeyPress(.space) { copierSelection(); return .handled }
        .onKeyPress(.return) { copierSelection(); return .handled }
    }

    /// Rend le focus au tableau, SAUF si le champ de recherche le tient.
    ///
    /// La garde n'est pas une précaution de principe, elle répare un vol de
    /// focus observé : le tableau est monté dans un `if`, donc filtrer jusqu'à
    /// zéro résultat le DÉMONTE, et le premier serveur qui réapparaît le
    /// remonte — ce qui rejoue `onAppear`. Effacer un caractère de trop dans la
    /// recherche arrachait ainsi le curseur du champ à l'instant même où on y
    /// tapait.
    ///
    /// Une garde de ce genre existait déjà et avait été retirée, à raison :
    /// elle interrogeait alors un `@FocusState<Bool>` séparé, qui pouvait
    /// rester à `true` après que le champ eut perdu le focus, et condamnait
    /// définitivement le retour au tableau. Sur une valeur énumérée, l'état ne
    /// peut plus mentir : une seule zone à la fois, par construction. Et un
    /// clic dans le tableau reprend le focus quoi qu'il arrive, donc aucun
    /// enfermement n'est possible.
    ///
    /// Le report d'un tour de boucle reste nécessaire : au moment du
    /// `onAppear`, la vue n'est pas encore dans la chaîne de réponse.
    private func rendreFocusAuTableau() {
        DispatchQueue.main.async {
            guard focus != .recherche else { return }
            focus = .tableau
        }
    }

    private func copierSelection() {
        if let s = modele.serveurSelectionne { modele.copier(s) }
    }

    // MARK: - Tableau vide

    private var vide: some View {
        // Le composant que macOS emploie partout ailleurs pour une vue sans
        // contenu — Finder sur un dossier vide, Mail sans message. Ici il est à
        // sa place : c'est bien la FENÊTRE entière qui n'a rien à montrer, pas
        // une ligne de formulaire. Il centre, limite la largeur du paragraphe
        // et détache le bouton lui-même ; c'était fait à la main par un
        // espacement de 6, une marge de 40 et une autre de 4.
        //
        // Le message reste d'un seul tenant, en description, et n'est pas
        // scindé en titre + explication comme ce composant y invite : ses cinq
        // variantes sont traduites en neuf langues, et les découper les aurait
        // toutes rendues à traduire.
        ContentUnavailableView {
            EmptyView()
        } description: {
            Text(modele.messageVide)
        } actions: {
            SettingsLink { Text("Open Settings") }
        }
        // ⚠️ Nécessaire, et mesuré : sans cela le composant prend sa hauteur
        // naturelle, la pile se tasse en haut et la barre du bas remonte au
        // milieu de la fenêtre. Ce n'est pas une mesure — c'est « occupe la
        // place disponible », la seule chose que le parent ne peut pas deviner.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Barre du bas

    private var barreBasse: some View {
        HStack {
            // Grisés aussi sur un serveur SUIVI, et pas seulement quand rien
            // n'est sélectionné : sa ligne montre les jumelles, une marque n'y
            // apparaîtrait pas, et un bouton qui ne produit rien de visible est
            // pire qu'un bouton éteint.
            Button { modele.marquer(.reussi) } label: { Label("Worked", systemImage: "checkmark") }
                .disabled(!modele.selectionMarquable)
            Button { modele.marquer(.rate) } label: { Label("Failed", systemImage: "xmark") }
                .disabled(!modele.selectionMarquable)
            Button("Clear Mark") { modele.marquer(nil) }
                .disabled(!modele.selectionMarquable)

            // Plus de marge à gauche : la pile en pose déjà une entre chaque
            // élément, et les six points s'y ajoutaient sans raison.
            Text(modele.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
            // Un tourniquet sans étiquette s'annonce « en cours » sans dire
            // de quoi. C'est le seul élément de la barre basse qui ne porte
            // aucun texte.
            if modele.chargement {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Scanning"))
            }
        }
        .padding()
    }
}

// MARK: - Tri conservé d'une session à l'autre

/// Traduction entre l'ordre de tri et la chaîne rangée dans les préférences.
///
/// Hors de la vue, donc hors de `@MainActor` : les `KeyPath` ne sont pas
/// `Sendable`, et les garder dans une propriété statique d'une `View` produisait
/// une volée d'avertissements en concurrence stricte.
enum Tri {
    static let defaut = "maxVu:desc"

    static func comparateurs(_ etiquette: String) -> [KeyPathComparator<Serveur>] {
        let bouts = etiquette.split(separator: ":")
        let sens: SortOrder = bouts.last == "desc" ? .reverse : .forward
        switch bouts.first.map(String.init) {
        case "pays":          return [KeyPathComparator(\.pays, order: sens)]
        case "dernierOnline": return [KeyPathComparator(\.dernierOnline, order: sens)]
        case "slots":         return [KeyPathComparator(\.slots, order: sens)]
        case "version":       return [KeyPathComparator(\.version, order: sens)]
        case "regularite":    return [KeyPathComparator(\.regularite, order: sens)]
        case "adresse":       return [KeyPathComparator(\.adresse, order: sens)]
        case "hebergeur":     return [KeyPathComparator(\.hebergeur, order: sens)]
        case "motd":          return [KeyPathComparator(\.motd, order: sens)]
        default:              return [KeyPathComparator(\.maxVu, order: sens)]
        }
    }

    static func etiquette(_ tri: [KeyPathComparator<Serveur>]) -> String {
        guard let t = tri.first else { return defaut }
        let sens = t.order == .reverse ? "desc" : "asc"
        let k = t.keyPath
        let nom: String
        if k == \Serveur.pays { nom = "pays" }
        else if k == \Serveur.dernierOnline { nom = "dernierOnline" }
        else if k == \Serveur.slots { nom = "slots" }
        else if k == \Serveur.version { nom = "version" }
        else if k == \Serveur.regularite { nom = "regularite" }
        else if k == \Serveur.adresse { nom = "adresse" }
        else if k == \Serveur.hebergeur { nom = "hebergeur" }
        else if k == \Serveur.motd { nom = "motd" }
        else { nom = "maxVu" }
        return "\(nom):\(sens)"
    }
}
