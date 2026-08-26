#!/bin/zsh
# MC Watch — Search, watch and join home Minecraft servers with players from other countries.
# Copyright (C) 2026 Minortos
# SPDX-License-Identifier: GPL-3.0-or-later

# Prépare une version pour publication : le .dmg, sa signature, et l'entrée
# d'appcast qui la fera parvenir aux installations déjà en service.
#
# Ce script ne PUBLIE rien. Il fabrique et il vérifie ; le téléversement reste
# un geste humain, fait sur github.com. C'est délibéré : publier est le seul
# acte irréversible de tout le projet, et il mérite qu'on le pose soi-même.
set -e

# `--remplacer` refait l'entrée d'une version DÉJÀ décrite dans l'appcast.
#
# Il sert pendant la mise au point, où l'on recompile plusieurs fois la même
# version : chaque compilation incrémente le numéro de build et produit un
# nouveau .dmg, donc une nouvelle signature — et l'entrée précédente ne décrit
# alors plus rien qui existe.
#
# ⚠️ À n'employer que sur une version PAS ENCORE publiée. Remplacer l'entrée
#    d'une version déjà en ligne changerait la signature attendue sous les pieds
#    de ceux qui l'ont déjà : leur téléchargement échouerait à la vérification,
#    et ils n'auraient aucun moyen de comprendre pourquoi.
REMPLACER=0
for ARG in "$@"; do
  case "$ARG" in
    --remplacer) REMPLACER=1 ;;
    -h|--aide)   echo "usage: ${0:t} [--remplacer]"; exit 0 ;;
    *) echo "❌  option inconnue : $ARG"
       echo "    usage: ${0:t} [--remplacer]"; exit 2 ;;
  esac
done

SRC="${0:A:h}"
APP="/Applications/MC Watch.app"
DEPOT="Minortos/MCWatch"
ARCHIVES="$HOME/Developer/MCWatch-versions"   # hors du dépôt, délibérément
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

SIGN_UPDATE="$SRC/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "❌  outils Sparkle absents → swift package resolve"; exit 1; }
[[ -d "$APP" ]] || { echo "❌  $APP introuvable → ./construire.sh"; exit 1; }

# ─── 1 · Ce qu'on s'apprête à diffuser est-il diffusable ? ───────────────────
#
# Ces contrôles ne font pas double emploi avec ceux de `construire.sh`. Là-bas
# ils protègent la compilation ; ici ils protègent des UTILISATEURS. Un paquet
# ad-hoc ou non horodaté fonctionne parfaitement sur cette machine et casse
# chez tout le monde — c'est exactement le genre de faute qu'on ne voit qu'une
# fois publiée.
echo "1/5  vérification du paquet…"
EQUIPE=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$EQUIPE" == "CT2VKA6A5C" ]] || { echo "❌  équipe inattendue : ${EQUIPE:-aucune}"; exit 1; }
codesign -dvv "$APP" 2>&1 | grep -q "^Timestamp=" \
  || { echo "❌  signature NON horodatée — elle mourrait avec le certificat"; exit 1; }
codesign --verify --deep --strict "$APP" 2> /dev/null \
  || { echo "❌  signature imbriquée invalide"; exit 1; }
# Sans cette clé, l'app publiée serait incapable de vérifier ses propres mises
# à jour — et les accepterait donc de n'importe qui.
plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" > /dev/null 2>&1 \
  || { echo "❌  SUPublicEDKey absente de l'Info.plist du paquet"; exit 1; }
echo "     ✔︎ équipe $EQUIPE · horodatée · imbrication vérifiée"

COURTE=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
MINIMUM=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
TAG="v$COURTE"
NOM="MC-Watch-$COURTE.dmg"
echo "     version $COURTE (build $BUILD) · macOS $MINIMUM minimum"

# ─── 2 · Le disque ──────────────────────────────────────────────────────────
#
# Un lien vers /Applications à côté de l'app : c'est la mise en page que tout
# le monde reconnaît, et elle dit ce qu'il faut faire sans une ligne de texte.
echo "2/5  fabrication du disque…"
mkdir -p "$TMP/disque" "$ARCHIVES"
ditto "$APP" "$TMP/disque/MC Watch.app"
ln -s /Applications "$TMP/disque/Applications"
DMG="$ARCHIVES/$NOM"
rm -f "$DMG"
hdiutil create -volname "MC Watch" -srcfolder "$TMP/disque" \
               -ov -format UDZO -quiet "$DMG"
echo "     $DMG  ·  $(du -h "$DMG" | cut -f1)"

# ─── 3 · La signature EdDSA ─────────────────────────────────────────────────
#
# C'est ELLE qui fait toute la sûreté du dispositif, et non HTTPS. L'appcast et
# le .dmg voyagent par GitHub : un compte compromis suffirait à y substituer un
# fichier. Mais la clé privée qui produit cette signature n'est pas sur GitHub —
# elle est dans le trousseau de cette machine. Une archive substituée serait
# téléchargée, puis refusée avant d'être ouverte.
echo "3/5  signature de l'archive…"
SIGNATURE=$("$SIGN_UPDATE" "$DMG")
[[ "$SIGNATURE" == *edSignature* ]] || { echo "❌  signature impossible : $SIGNATURE"; exit 1; }
echo "     ✔︎ signée avec la clé du trousseau"

# ─── 4 · L'entrée d'appcast ─────────────────────────────────────────────────
echo "4/5  entrée d'appcast…"
APPCAST="$SRC/appcast.xml"
if [[ ! -f "$APPCAST" ]]; then
  cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!--
  Le fil des versions de MC Watch, lu par Sparkle à chaque vérification.

  Il est servi en brut depuis la branche principale du dépôt, et non par une
  page GitHub : une branche existe déjà, une page serait un service de plus à
  maintenir et à laisser expirer. Les archives, elles, vivent dans les
  « releases » — GitHub sert mal les gros fichiers depuis un dépôt.

  Rien ici n'a besoin d'être secret. Chaque entrée porte une signature EdDSA
  que l'app vérifie avec la clé publique gravée dans son Info.plist : ce fichier
  peut être lu, copié, republié — il ne peut pas être falsifié utilement.

  ⚠️ Écrit par publier.sh. Les entrées s'ajoutent, ne se retirent jamais : une
     version supprimée d'ici cesse d'exister pour qui voudrait y revenir.
-->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MC Watch</title>
    <link>https://raw.githubusercontent.com/$DEPOT/main/appcast.xml</link>
    <description>Updates for MC Watch.</description>
    <language>en</language>
  </channel>
</rss>
XML
  echo "     appcast.xml créé"
fi

if grep -q "sparkle:shortVersionString=\"$COURTE\"" "$APPCAST"; then
  if (( ! REMPLACER )); then
    echo "❌  la version $COURTE figure déjà dans l'appcast."
    echo "    → publiée ? monte CFBundleShortVersionString, recompile, recommence ;"
    echo "    → pas encore publiée ? ${0:t} --remplacer"
    exit 1
  fi
  # L'entrée entière disparaît, de <item> à </item>. On s'appuie sur la mise en
  # page produite par ce script — c'est lui seul qui écrit ce fichier.
  awk -v v="sparkle:shortVersionString=\"$COURTE\"" '
    /<item>/ { bloc = $0 "\n"; dedans = 1; next }
    dedans   { bloc = bloc $0 "\n"
               if ($0 ~ /<\/item>/) { if (bloc !~ v) printf "%s", bloc; dedans = 0 }
               next }
             { print }' "$APPCAST" > "$TMP/sans.xml"
  mv "$TMP/sans.xml" "$APPCAST"
  echo "     ancienne entrée $COURTE retirée"
fi

DATE=$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")
URL="https://github.com/$DEPOT/releases/download/$TAG/$NOM"

# La taille n'est PAS reprise ici : `sign_update` rend déjà `length` à côté de
# la signature, et c'est sa mesure qui fait foi — Sparkle refuse une archive
# dont la taille ne correspond pas à ce qui est annoncé. L'écrire une seconde
# fois produisait un attribut en double, donc un XML invalide.
cat > "$TMP/item.xml" <<XML
    <item>
      <title>$COURTE</title>
      <pubDate>$DATE</pubDate>
      <link>https://github.com/$DEPOT/releases/tag/$TAG</link>
      <sparkle:releaseNotesLink>https://github.com/$DEPOT/releases/tag/$TAG</sparkle:releaseNotesLink>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <enclosure url="$URL"
                 sparkle:version="$BUILD"
                 sparkle:shortVersionString="$COURTE"
                 type="application/x-apple-diskimage"
                 $SIGNATURE />
    </item>
XML

# L'entrée s'insère AVANT </channel>. L'ordre n'a aucune importance pour
# Sparkle — il choisit la version la plus haute, pas la première venue — mais
# il en a une pour l'œil humain qui relira ce fichier dans deux ans.
#
# Le bloc passe par un FICHIER, et non par `awk -v` : une variable passée à awk
# ne peut pas contenir de saut de ligne, et awk s'arrête sur « newline in
# string » — sans rien écrire, mais après avoir créé l'appcast.
awk -v f="$TMP/item.xml" '/<\/channel>/ && !fait { while ((getline l < f) > 0) print l; fait = 1 } { print }' \
  "$APPCAST" > "$TMP/appcast.xml"
mv "$TMP/appcast.xml" "$APPCAST"
xmllint --noout "$APPCAST" || { echo "❌  appcast.xml malformé"; exit 1; }
echo "     ✔︎ entrée $COURTE ajoutée · XML valide"

# ─── 5 · Ce qui reste à faire, et qui ne s'automatise pas ───────────────────
cat <<FIN
5/5  prêt.

     Il reste trois gestes, et ils sont à toi :

     1 · créer la release $TAG sur github.com/$DEPOT/releases/new
         et y joindre :
            $DMG

     2 · commiter l'appcast — c'est LUI que les apps interrogent :
            git add appcast.xml && git commit -m "Release $COURTE"
            git push

     3 · vérifier que l'app la voit :
            Menu MC Watch › Check for Updates…

     ⚠️ Dans cet ordre, jamais l'inverse. L'appcast ANNONCE une adresse de
        téléchargement ; la release est ce qui la SERT. Poussé le premier, il
        envoie toute installation qui vérifie dans l'intervalle sur un fichier
        qui n'existe pas encore — et Sparkle montre alors une erreur de
        téléchargement, pas une absence de mise à jour.
FIN
