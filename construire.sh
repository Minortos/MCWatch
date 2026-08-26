#!/bin/zsh
# MC Watch — Search, watch and join home Minecraft servers with players from other countries.
# Copyright (C) 2026 Minortos
# SPDX-License-Identifier: GPL-3.0-or-later

# Assemble /Applications/MC Watch.app à partir du paquet Swift.
#
# Le scanner est copié DANS le paquet : l'agent launchd pointe sur un exécutable
# du bundle, pour ne dépendre d'aucun binaire extérieur.
set -e
SRC="${0:A:h}"
APP="/Applications/MC Watch.app"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Une signature NON HORODATÉE est un échec, pas un désagrément.
#
# L'horodatage est ce qui fait survivre une signature à l'expiration de son
# certificat : un serveur d'Apple atteste que la signature a été produite
# pendant que le certificat était valide, et macOS pose ensuite la question
# « l'était-il alors ? » plutôt que « l'est-il aujourd'hui ? ». Sans lui, la
# signature meurt AVEC le certificat — qui est annuel.
#
# Le mode de panne est particulièrement vicieux : le paquet s'installe et
# fonctionne parfaitement pendant des mois, puis devient « endommagé » chez ses
# utilisateurs le jour de l'expiration, **sans que rien n'ait bougé chez eux**
# et sans qu'un nouveau téléchargement n'y change quoi que ce soit.
#
# L'horodatage exigeant le réseau, `--sans-horodatage` permet de compiler hors
# ligne en connaissance de cause. Le paquet produit reste utilisable ici, mais
# il n'est PAS distribuable.
HORODATAGE_FACULTATIF=0
for ARG in "$@"; do
  case "$ARG" in
    --sans-horodatage) HORODATAGE_FACULTATIF=1 ;;
    -h|--aide)         echo "usage: ${0:t} [--sans-horodatage]"; exit 0 ;;
    *) echo "❌  option inconnue : $ARG"
       echo "    usage: ${0:t} [--sans-horodatage]"; exit 2 ;;
  esac
done

# Chaque Xcode embarque sa propre chaîne complète : compilateur, SPM, SDK,
# actool. Il faut celle dont le SDK correspond au système, car macOS applique à
# une app l'apparence du SDK gravé dans son binaire — pas la sienne. Sur un
# macOS 27, compiler avec le SDK 26 donne une app à l'allure de macOS 26.
#
# Le choix se fait sur la version, jamais sur le nom : l'Xcode stable est
# essayé d'abord et l'emporte dès qu'il convient. Le jour où macOS 27 sortira,
# Xcode 27 deviendra le stable et sera pris automatiquement ; et une préversion
# d'un macOS *futur* ne sera pas retenue, puisque son SDK ne correspondra plus.
# La version se lit dans le SDK lui-même, pas via `xcrun` : sur cette machine
# l'`xcrun` d'un Xcode trop ancien pour le système retombe sur le SDK des
# Command Line Tools et échoue. Et sous `set -e`, une affectation
# `V=$(commande qui échoue)` interrompt le script — d'où la lecture directe,
# suivie d'un `|| true` explicite.
MAJEURE=$(sw_vers -productVersion); MAJEURE=${MAJEURE%%.*}
for X in /Applications/Xcode.app /Applications/Xcode-beta.app; do
  [[ -d $X ]] || continue
  V=$(plutil -extract Version raw \
        "$X/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist" \
        2> /dev/null) || V=""
  if [[ -n $V && ${V%%.*} == "$MAJEURE" ]]; then
    export DEVELOPER_DIR="$X/Contents/Developer"
    XCODE="$(basename "$X" .app) $V"
    SDK=$V
    break
  fi
done
: ${SDK:=$(xcrun --show-sdk-version 2> /dev/null || echo "$MAJEURE.0")}
CIBLE=${SDK%%.*}.0

echo "1/5  compilation Swift…  (${XCODE:-Xcode par défaut} · SDK macOS $SDK)"
cd "$SRC"
# `-emit-localized-strings` fait relever les clés de traduction PAR LE
# COMPILATEUR, pendant qu'il vérifie les types. C'est la même passe que celle
# d'Xcode, et la seule fiable : un extracteur qui relit la source à la main se
# trompe d'un espace tôt ou tard, et surtout il ne sait pas si un littéral est
# une clé ou une simple chaîne — cela dépend du type attendu à cet endroit.
#
# ⚠️ Le `touch` n'est pas superflu. SwiftPM ne recompile que ce qui a changé,
# donc une compilation incrémentale ne produit de `.stringsdata` que pour les
# fichiers retouchés : la synchronisation croirait alors les autres clés
# disparues. Mesuré — 63 clés manquantes sur 180 après une petite retouche.
STRINGSDATA="$TMP/stringsdata"
mkdir -p "$STRINGSDATA"
find Sources -name '*.swift' -exec touch {} +
# ⚠️ `-file-prefix-map` : SANS LUI, LE PAQUET PUBLIÉ PORTE LE CHEMIN DE
# COMPILATION, DONC LE NOM DU DOSSIER PERSONNEL.
#
# Mesuré sur le binaire distribué : les tables de débogage contenaient
# « /Users/<prénom><nom>/Developer/MCWatch/Sources/… » à plusieurs centaines
# d'occurrences, dans les DEUX exécutables. Le dépôt était propre, les commits
# signés du pseudonyme, la signature au nom d'une adresse jetable — et le
# `.dmg` téléchargé depuis GitHub aurait suffi à retrouver le vrai nom avec un
# simple `strings`.
#
# La bascule remplace ce préfixe par un chemin neutre partout où le compilateur
# l'écrit : infos de débogage, couverture, et les macros `#file` / `#filePath`.
# Elle est plus large que `-debug-prefix-map`, qui ne couvre que les premières.
swift build -c release \
  -Xswiftc -file-prefix-map -Xswiftc "$SRC=/MCWatch" \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGSDATA" > /dev/null

# Numéro de build qui avance à chaque compilation : LaunchServices et le Dock se
# fient à ce couple identifiant/version pour rafraîchir leurs caches.
VERSION=$(( $(plutil -extract CFBundleVersion raw Ressources/Info.plist) + 1 ))
plutil -replace CFBundleVersion -string "$VERSION" Ressources/Info.plist
echo "2/5  version du paquet : $VERSION"

echo "3/5  icône…"
swift "$SRC/Ressources/glyphe.swift" "$TMP/glyphe.png" > /dev/null
mkdir -p "$TMP/MCWatch.icon/Assets" "$TMP/out"
cp "$TMP/glyphe.png" "$TMP/MCWatch.icon/Assets/bloc-glyph.png"
cp "$SRC/Ressources/icon.json" "$TMP/MCWatch.icon/icon.json"
xcrun actool "$TMP/MCWatch.icon" --compile "$TMP/out" --app-icon MCWatch \
  --output-partial-info-plist "$TMP/p.plist" --platform macosx \
  --minimum-deployment-target "$CIBLE" > /dev/null

echo "4/5  assemblage du paquet…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp .build/release/MCWatchApp  "$APP/Contents/MacOS/MCWatch"
cp .build/release/MCWatchScan "$APP/Contents/MacOS/MCWatchScan"

# ⚠️ SECONDE MOITIÉ de l'anonymat du paquet, et elle est indispensable.
#
# `-file-prefix-map` neutralise les chemins que le COMPILATEUR écrit ; il ne
# touche pas à ceux que l'ÉDITEUR DE LIENS grave dans la table des objets de
# débogage (les entrées `N_OSO`), qui pointent le dossier `.build`. Mesuré
# après la seule bascule : vingt-deux occurrences restaient dans un binaire,
# quinze dans l'autre, toutes de la forme
# « /Users/<prénom><nom>/Developer/MCWatch/.build/… ».
#
# Un binaire distribué n'a de toute façon rien à faire de ses symboles de
# débogage : les retirer règle la fuite ET allège le paquet de trois cents
# kilo-octets. Vérifié : zéro occurrence après.
#
# ⚠️ AVANT la signature, jamais après — `strip` modifie le fichier et
# invaliderait le sceau. C'est la raison de sa place ici et non plus bas.
for BINAIRE in "$APP/Contents/MacOS/MCWatch" "$APP/Contents/MacOS/MCWatchScan"; do
  strip -S "$BINAIRE" 2> /dev/null
done

# Le filet, et il est volontairement BRUTAL : mieux vaut une compilation qui
# échoue qu'une identité publiée sur GitHub. Les hooks git ne gardaient que le
# dépôt — or le dépôt était propre et le paquet, lui, ne l'était pas.
#
# ⚠️ AUCUN NOM N'EST ÉCRIT ICI, et ce n'est pas de la coquetterie : ce fichier
# est versionné et publié. Un garde-fou qui contiendrait le nom qu'il protège
# le publierait lui-même — la première version de ce contrôle faisait très
# exactement cela. Les motifs sont donc DEMANDÉS AU SYSTÈME à chaque
# compilation, ce qui a deux vertus : rien à tenir à jour ici, et quiconque
# recompile le projet se voit protégé de SON propre nom, pas du nôtre.
IDENTIFIANTS=("$(id -un)")                       # le nom de compte : /Users/<compte>
for MOT in ${(z)$(id -F 2> /dev/null)}; do       # prénom et nom, mot à mot
  (( ${#MOT} >= 4 )) && IDENTIFIANTS+=("$MOT")
done
for NOM_MACHINE in "$(scutil --get ComputerName 2> /dev/null)" \
                   "$(scutil --get LocalHostName 2> /dev/null)"; do
  # En entier, jamais mot à mot : « MacBook Pro de X » découpé donnerait « Pro »
  # et « de », qui matchent la moitié du monde.
  [[ -n "$NOM_MACHINE" ]] && IDENTIFIANTS+=("$NOM_MACHINE")
done

# Un mot qui figure déjà dans les SOURCES publiques ne peut pas servir de
# signal : il est public par construction, et le laisser déclencherait un échec
# permanent chez quelqu'un qui s'appellerait « Swift » ou dont le Mac
# s'appellerait « MC Watch ». On l'écarte en le disant.
MOTIFS=()
for MOT in "${IDENTIFIANTS[@]}"; do
  if grep -rqiF -- "$MOT" Sources Ressources README.md CONTRIBUTING.md 2> /dev/null; then
    echo "     ⚠︎ « $MOT » figure dans les sources publiques : écarté du contrôle."
  else
    MOTIFS+=("$MOT")
  fi
done

# `-a` : les binaires sont traités comme du texte, c'est là que la fuite se
# trouvait. `(f)` découpe par ligne ; `${...:#}` jette la ligne vide que rend
# une substitution sans résultat. Le `|| true` est indispensable sous `set -e` :
# un grep qui ne trouve rien sort en 1, et c'est ici le cas NORMAL.
FUITES=()
for MOT in "${MOTIFS[@]}"; do
  TROUVE=$(grep -raliF -- "$MOT" "$APP" 2> /dev/null) || true
  if [[ -n "$TROUVE" ]]; then FUITES+=(${(f)TROUVE}); fi
done
if (( ${#FUITES} )); then
  echo "❌  le paquet porte l'identité de la machine qui l'a compilé :"
  printf '        %s\n' ${(u)FUITES}
  echo "    → un binaire non dépouillé, ou un chemin de compilation non neutralisé."
  exit 1
fi
cp Ressources/Info.plist      "$APP/Contents/Info.plist"
# La version minimale suit le SDK réellement utilisé : annoncer 14.0 alors que le
# binaire exige macOS 27 laisserait LaunchServices ouvrir une app que dyld refuse.
plutil -replace LSMinimumSystemVersion -string "$CIBLE" "$APP/Contents/Info.plist"
# Le nom du fichier doit être exactement « <Label>.plist » : SMAppService le
# désigne par son nom, et launchd exige que le Label du contenu concorde. On le
# lit donc DANS le plist plutôt que de le réécrire ici — deux endroits à tenir
# en phase, c'est un endroit de trop.
ETIQUETTE=$(plutil -extract Label raw Ressources/agent.plist)
cp Ressources/agent.plist     "$APP/Contents/Library/LaunchAgents/$ETIQUETTE.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Seuls `Assets.car` et `.icns` servent à l'exécution. Le dossier `.icon` est la
# SOURCE que compile actool : l'embarquer n'ajoutait que du poids. Vérifié en
# comparant l'icône rendue par le système avec et sans — identique.
cp "$TMP/out/Assets.car" "$TMP/out/MCWatch.icns" "$APP/Contents/Resources/"
# La GPL demande que toute copie transmise soit accompagnée du texte de la
# licence (§4 et §5c). Le dépôt le porte, mais ce qu'on distribue est un .dmg
# qui ne contient QUE le paquet : sans cette copie, le binaire circulerait sans
# sa licence. L'onglet « About » de l'app pointe sur ce fichier.
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# ─── Sparkle ────────────────────────────────────────────────────────────────
#
# Le framework est pris dans les artefacts de SwiftPM, là où la résolution du
# paquet l'a déposé. Il n'est pas versionné : c'est une dépendance, elle se
# retélécharge, et son empreinte est épinglée dans Package.resolved.
#
# `ditto` plutôt que `cp -R` : un framework est une arborescence à liens
# symboliques (`Versions/Current`, et les alias qui pendent à la racine). ditto
# est l'outil d'Apple pour recopier un paquet à l'identique ; il conserve les
# liens, les drapeaux et les attributs étendus. Un `cp` qui déréférencerait un
# seul de ces liens produirait un framework deux fois plus lourd, et surtout une
# signature qui ne se vérifierait plus.
SPARKLE=(.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework(N))
if (( ! ${#SPARKLE} )); then
  echo "❌  Sparkle introuvable dans .build/artifacts."
  echo "    → swift package resolve"
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "${SPARKLE[1]}" "$APP/Contents/Frameworks/Sparkle.framework"

# Le service de TÉLÉCHARGEMENT est retiré. Sparkle ne l'embarque que pour les
# apps privées du droit `network.client`, qui ne peuvent pas aller chercher le
# fichier elles-mêmes ; celle-ci l'a. Le garder aurait ajouté au paquet un
# exécutable de plus à signer, à charger et à défendre — et il s'appuie sur une
# WebKit dépréciée. Ce qu'on n'embarque pas n'a pas de faille.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"

# Sparkle est sous licence MIT, qui exige que son avis de copyright accompagne
# toute redistribution — y compris sous forme binaire. La GPL de MC Watch ne
# dispense de rien : elle couvre notre code, pas celui des autres. Le .dmg ne
# contient que le paquet, donc l'avis voyage DANS le paquet, à côté du nôtre.
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/LICENSE-Sparkle.txt"
# ─── Traductions ───────────────────────────────────────────────────────────
#
# La langue source est l'ANGLAIS, et le texte anglais EST la clé : les vues
# n'ont rien de spécial à faire, SwiftUI transforme tout littéral unique en clé
# de localisation, et `String(localized:)` fait de même hors des vues.
#
# Le catalogue n'émet donc **aucun `en.lproj/Localizable.strings`** — l'anglais
# vit dans les clés. C'est ce qui referme les trois cas sans le moindre
# réglage : le Français reçoit `fr.lproj`, l'Allemand `de.lproj`, et quiconque
# n'a aucune de ces langues — comme toute chaîne pas encore traduite — retombe
# sur la clé, c'est-à-dire l'anglais. Vérifié : le repli d'une clé absente ne
# passe JAMAIS par `CFBundleDevelopmentRegion`, il rend la clé telle quelle.
#
# `sync` réconcilie le catalogue avec ce que le compilateur a réellement vu :
# une clé nouvelle y entre, une clé disparue de la source est marquée périmée.
# `compile` produit les `.strings` et les `.stringsdict` (les pluriels), très
# exactement comme le fait Xcode.
echo "     traductions…"
xcrun xcstringstool sync Ressources/Localizable.xcstrings \
  --stringsdata "$STRINGSDATA"/*.stringsdata
xcrun xcstringstool compile Ressources/Localizable.xcstrings \
  -o "$APP/Contents/Resources" --serialization-format binary
LANGUES=$(cd "$APP/Contents/Resources" && ls -d *.lproj | sed 's/\.lproj//' | tr '\n' ' ')
echo "     langues embarquées : $LANGUES"

echo "5/5  signature…"
# Identité réelle si elle est disponible, ad-hoc sinon : un certificat expiré,
# révoqué ou absent ne doit jamais empêcher de compiler. Trois niveaux, du plus
# complet au plus dégradé, et on annonce lequel a été retenu.
# ─── Choix du certificat ───────────────────────────────────────────────────
#
# ⚠️ Le trousseau peut contenir PLUSIEURS identités — un compte personnel et un
# compte de publication, par exemple. `security find-identity` les rend dans un
# ordre arbitraire : sans choix explicite, une compilation signait avec la
# première venue. Le risque n'est pas théorique — c'est publier une app portant
# une identité qu'on avait justement pris soin de ne pas exposer.
#
# La sélection se fait sur l'IDENTIFIANT D'ÉQUIPE et non sur le nom du
# certificat : l'équipe appartient au compte et ne bouge pas au renouvellement
# annuel, alors que le nom du certificat, lui, change.
#
# Si cette équipe est absente — quelqu'un qui clone ce dépôt et compile avec son
# propre certificat — on retombe sur la première identité disponible, mais en le
# DISANT. Un repli silencieux serait exactement le problème qu'on corrige ici.
EQUIPE="CT2VKA6A5C"

identite_de_lequipe() {   # $1 = identifiant d'équipe ; écrit le nom sur stdout
  security find-identity -v -p codesigning 2> /dev/null \
    | sed -n 's/.*"\(.*\)"/\1/p' \
    | while read -r NOM; do
        OU=$(security find-certificate -c "$NOM" -p 2> /dev/null \
             | openssl x509 -noout -subject 2> /dev/null \
             | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
        [[ "$OU" == "$1" ]] && { print -r -- "$NOM"; break; }
      done
}

IDENTITE=$(identite_de_lequipe "$EQUIPE")
EQUIPE_ATTENDUE=1
if [[ -z "$IDENTITE" ]]; then
  # Repli : on ne peut plus exiger l'équipe, puisqu'on vient de constater
  # qu'elle n'est pas là. Le drapeau désarme le contrôle final.
  EQUIPE_ATTENDUE=0
  IDENTITE=$(security find-identity -v -p codesigning 2> /dev/null \
             | sed -n 's/.*"\(.*\)"/\1/p' | head -1)
  [[ -n "$IDENTITE" ]] \
    && echo "     ⚠️  équipe $EQUIPE absente — repli sur « $IDENTITE »"
fi

# Les droits — DEUX fichiers, et non plus un.
#
# L'app porte l'exception mach-lookup dont Sparkle a besoin pour joindre son
# installateur ; le scanner ne la porte pas, n'ayant rien à mettre à jour. Ils
# ont été séparés pour cette seule raison, et chacun documente la sienne.
# Sans ces fichiers, les binaires ne seraient pas confinés du tout — on refuse
# donc de produire un paquet silencieusement non sandboxé.
DROITS_APP="$SRC/Ressources/MCWatch.entitlements"
DROITS_SCAN="$SRC/Ressources/MCWatchScan.entitlements"
for D in "$DROITS_APP" "$DROITS_SCAN"; do
  [[ -f "$D" ]] || { echo "❌  droits introuvables : $D"; exit 1; }
done

# $1 = cible ; $2 = fichier de droits, VIDE pour n'en donner aucun.
#
# « Aucun droit » n'est pas un oubli, c'est le réglage juste pour les morceaux
# de Sparkle. L'installateur doit remplacer le paquet dans /Applications :
# lui coller `app-sandbox` l'enfermerait justement là où il n'a plus le droit
# d'écrire, et la mise à jour échouerait au tout dernier moment — après le
# téléchargement, après la vérification de signature. Ces composants arrivent
# d'ailleurs signés ad-hoc et sans le moindre droit ; on ne fait que remplacer
# la signature par la nôtre.
signer() {
  local CIBLE=$1 DROITS=$2
  local -a ARGS
  ARGS=("${BASE[@]}")
  [[ -n "$DROITS" ]] && ARGS+=(--entitlements "$DROITS")
  codesign --force "${ARGS[@]}" "$CIBLE" 2> /dev/null
}

# Les morceaux de Sparkle, du plus profond au plus extérieur. L'ordre n'est pas
# négociable : la signature d'un conteneur scelle celle de son contenu, donc
# tout ce qui est imbriqué doit être signé AVANT lui.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
MORCEAUX=("$FW/XPCServices/Installer.xpc" "$FW/Updater.app" "$FW/Autoupdate" "$FW")

if [[ -n "$IDENTITE" ]]; then
  # `--options runtime` = runtime durci : ni injection de code non signé, ni
  # surcharge de DYLD_*, ni débogueur. `--timestamp` horodate la signature pour
  # qu'elle reste vérifiable après l'expiration du certificat (annuel).
  BASE=(--sign "$IDENTITE" --options runtime --timestamp)
  if ! signer "$APP/Contents/MacOS/MCWatchScan" "$DROITS_SCAN"; then
    # L'horodatage a échoué : réseau coupé, ou serveur d'Apple injoignable.
    if (( HORODATAGE_FACULTATIF )); then
      BASE=(--sign "$IDENTITE" --options runtime --timestamp=none)
      echo "     ⚠️  SANS HORODATAGE — paquet de développement, NON distribuable."
    else
      # La date d'expiration est lue sur le certificat lui-même : dire « ça
      # cassera un jour » est vague, donner le jour l'est beaucoup moins.
      EXPIRE=$(security find-certificate -c "$IDENTITE" -p 2> /dev/null \
               | openssl x509 -noout -enddate 2> /dev/null | cut -d= -f2) || EXPIRE=""
      echo "❌  horodatage impossible — signature refusée."
      echo "    Sans horodatage, cette signature expirerait avec le certificat${EXPIRE:+, le $EXPIRE}."
      echo "    Une app déjà distribuée deviendrait alors « endommagée » chez ses"
      echo "    utilisateurs, sans recours."
      echo
      echo "    → vérifie la connexion réseau, puis relance ;"
      echo "    → ou, pour un paquet de développement à ne PAS publier :"
      echo "         ${0:t} --sans-horodatage"
      exit 1
    fi
  fi
fi
if [[ -z "$IDENTITE" ]] || ! signer "$APP/Contents/MacOS/MCWatchScan" "$DROITS_SCAN"; then
  # ⚠️ Repli ad-hoc : le paquet se construit, mais la SURVEILLANCE NE MARCHERA
  # PAS. Sans identité stable, launchd ne peut dériver aucune exigence de code
  # du paquet et enregistre une liste d'empreintes vide, que rien ne satisfait :
  # le scanner est tué au démarrage (OS_REASON_CODESIGNING). C'est le bug qui
  # avait fait abandonner SMAppService. Le bac à sable, lui, fonctionne.
  BASE=(--sign -)
  signer "$APP/Contents/MacOS/MCWatchScan" "$DROITS_SCAN"
  echo "     ⚠️  ad-hoc : l'app fonctionnera, mais la surveillance automatique NON."
fi

# Sparkle, maintenant que le mode de signature est arrêté.
for M in "${MORCEAUX[@]}"; do
  signer "$M" "" || { echo "❌  signature impossible : ${M:t}"; exit 1; }
done
echo "     ✔︎ Sparkle signé · ${#MORCEAUX} morceaux, aucun droit"
# De l'intérieur vers l'extérieur : le scanner d'abord, puis le paquet, dont la
# signature scelle celle du scanner. (`--deep` fait la même chose mais Apple le
# déconseille : il signe à l'aveugle ce qu'il trouve.)
signer "$APP" "$DROITS_APP"
echo "     ${IDENTITE:-ad-hoc}${BASE[(r)--options]:+ · runtime durci}"
# Le confinement se VÉRIFIE, il ne se suppose pas : une faute de frappe dans le
# fichier de droits produirait une app parfaitement fonctionnelle et pas
# confinée du tout, sans que rien ne le signale.
for CIBLE in "$APP" "$APP/Contents/MacOS/MCWatchScan"; do
  if codesign -d --entitlements - "$CIBLE" 2>&1 | grep -q "app-sandbox"; then
    echo "     ✔︎ bac à sable actif · $(basename "$CIBLE")"
  else
    echo "     ❌ BAC À SABLE ABSENT de $(basename "$CIBLE")"; exit 1
  fi
done

# Et la vérification INVERSE, tout aussi nécessaire : l'installateur de Sparkle
# ne doit surtout PAS être confiné. Confiné, il ne pourrait pas remplacer le
# paquet dans /Applications — et l'échec arriverait au pire endroit possible :
# tout à la fin, après le téléchargement et après la vérification de signature,
# quand l'utilisateur croit la mise à jour faite.
if codesign -d --entitlements - "$FW/XPCServices/Installer.xpc" 2>&1 | grep -q "app-sandbox"; then
  echo "     ❌ INSTALLATEUR CONFINÉ — aucune mise à jour ne pourrait s'installer"; exit 1
fi
echo "     ✔︎ installateur Sparkle non confiné · il pourra remplacer le paquet"

# La signature imbriquée se relit ENTIÈREMENT. Ici `--deep` est à sa place :
# Apple le déconseille pour SIGNER — il signe à l'aveugle ce qu'il trouve — mais
# c'est exactement ce qu'on veut pour VÉRIFIER. C'est le seul contrôle qui
# verrait un morceau de Sparkle oublié, ou scellé après coup.
if ! codesign --verify --deep --strict "$APP" 2> /dev/null; then
  echo "     ❌ SIGNATURE IMBRIQUÉE INVALIDE :"
  codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/        /'
  exit 1
fi
echo "     ✔︎ signature imbriquée vérifiée de bout en bout"

# L'horodatage se vérifie sur le paquet FINI, et pas seulement au moment de le
# demander : `codesign` peut rendre la main sans erreur tout en ayant produit
# une signature sans horodatage. On regarde donc ce qui est réellement scellé.
#
# Rien à vérifier en ad-hoc : cette signature n'a aucun certificat — donc rien
# qui puisse expirer. L'horodatage n'aurait pas de sens.
# L'équipe se vérifie sur le paquet FINI. Le choix plus haut porte sur ce que le
# trousseau annonce ; ceci porte sur ce qui est réellement scellé — c'est la
# seule chose qui compte pour qui téléchargera l'app.
if (( EQUIPE_ATTENDUE )) && [[ -n "$IDENTITE" ]]; then
  SCELLEE=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [[ "$SCELLEE" == "$EQUIPE" ]]; then
    echo "     ✔︎ signée par l'équipe $EQUIPE"
  else
    echo "     ❌ ÉQUIPE INATTENDUE : $SCELLEE au lieu de $EQUIPE"; exit 1
  fi
fi

if [[ -n "$IDENTITE" ]]; then
  if codesign -dvv "$APP" 2>&1 | grep -q "^Timestamp="; then
    echo "     ✔︎ signature horodatée · survit à l'expiration du certificat"
  elif (( HORODATAGE_FACULTATIF )); then
    echo "     ⚠️  signature NON horodatée · développement uniquement, ne pas publier"
  else
    echo "     ❌ SIGNATURE NON HORODATÉE — elle expirerait avec le certificat"; exit 1
  fi
fi
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2> /dev/null || true

# L'agent est enregistré par SMAppService et pointe le scanner par
# `BundleProgram`, chemin relatif au paquet : le prochain déclenchement exécute
# le binaire qu'on vient de poser, sans rien réenregistrer. On ne touche donc
# pas à la surveillance — l'arrêter puis la relancer ne ferait qu'ouvrir une
# fenêtre où elle serait coupée.
#
# ⚠️ L'incrémentation de CFBundleVersion plus haut est PORTEUSE, pas cosmétique :
# BTM ne rafraîchit l'empreinte enregistrée que s'il voit une nouvelle version
# de paquet. Sans elle, une recompilation ferait tuer l'agent au démarrage.
echo "✅  $APP  ·  $("$APP/Contents/MacOS/MCWatchScan" --agent etat)"
