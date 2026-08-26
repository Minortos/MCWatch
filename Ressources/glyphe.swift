// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 Minortos
// SPDX-License-Identifier: GPL-3.0-or-later

// Glyphe pixel-art pour MC Watch : bloc de terre isométrique + ondes de signal.
// Rendu sur une grille 32x32, puis mis à l'échelle pour occuper ~70 % du canevas.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let N = 48                 // cellules de la grille
let U = Double(N) / 32.0   // les cotes ci-dessous sont exprimées en unités « grille 32 »
let CANEVAS = 1024.0
let OCCUPATION = 0.74      // part du canevas occupée par le glyphe

// --- palette ------------------------------------------------------------
struct Teinte { let r, v, b: Double }
let palette: [Int: Teinte] = [
    1: Teinte(r: 0.565, v: 0.784, b: 0.259),   // herbe, dessus clair
    2: Teinte(r: 0.478, v: 0.678, b: 0.208),   // herbe, dessus nuance
    3: Teinte(r: 0.435, v: 0.616, b: 0.184),   // herbe, bandeau gauche
    4: Teinte(r: 0.353, v: 0.510, b: 0.145),   // herbe, bandeau droit
    5: Teinte(r: 0.639, v: 0.478, b: 0.333),   // terre, face gauche
    6: Teinte(r: 0.494, v: 0.365, b: 0.251),   // terre, face droite
    7: Teinte(r: 0.553, v: 0.404, b: 0.271),   // terre, grain clair
    8: Teinte(r: 0.416, v: 0.302, b: 0.204),   // terre, grain sombre
    9: Teinte(r: 1.000, v: 1.000, b: 1.000),   // ondes
]

// --- géométrie du cube ---------------------------------------------------
let cx = 11.0 * U, W = 9.0 * U, H = 9.0 * U, cyTop = 13.0 * U
let ax = cx + W, ay = cyTop            // centre des ondes = sommet haut-droit

var grille = [[Int]](repeating: [Int](repeating: 0, count: N), count: N)

func grain(_ gx: Int, _ gy: Int) -> Bool {
    // Motif stable, en pavés 2x2 : une texture qui se lit encore en petit,
    // là où du bruit pixel par pixel donnerait un rendu sale.
    let p = Int(2.0 * U)
    let h = ((gx / p) &* 73 &+ (gy / p) &* 151) % 7
    return h == 0
}

for gy in 0..<N {
    for gx in 0..<N {
        let x = Double(gx) + 0.5, y = Double(gy) + 0.5

        if abs(x - cx) / W + abs(y - cyTop) / (W / 2) <= 1.0 {
            grille[gy][gx] = grain(gx, gy) ? 2 : 1          // face du dessus
        } else if x >= cx - W && x <= cx {
            let ey = cyTop + (x - (cx - W)) / 2
            if y >= ey && y <= ey + H {
                grille[gy][gx] = y < ey + 1.6 ? 3 : (grain(gx, gy) ? 7 : 5)
            }
        } else if x >= cx && x <= cx + W {
            let ey = cyTop + ((cx + W) - x) / 2
            if y >= ey && y <= ey + H {
                grille[gy][gx] = y < ey + 1.6 ? 4 : (grain(gx, gy) ? 8 : 6)
            }
        }
    }
}

// Pas d'ondes ni de badge : essayées, elles ne peuvent produire qu'une rayure
// diagonale flottante depuis un coin du cube, et elles brouillent la lecture
// aux petites tailles. Un seul objet net vaut mieux.

// La pointe basse du cube se termine sur une ou deux cellules isolées qui se
// lisent comme une bavure. On rogne les dernières rangées trop maigres.
for gy in stride(from: N - 1, through: 0, by: -1) {
    let remplies = grille[gy].filter { $0 != 0 }.count
    if remplies == 0 { continue }
    if remplies < 3 {
        for gx in 0..<N { grille[gy][gx] = 0 }
    } else {
        break
    }
}

// --- cadrage : on ajuste sur les cellules réellement remplies -------------
var minX = N, maxX = -1, minY = N, maxY = -1
for gy in 0..<N {
    for gx in 0..<N where grille[gy][gx] != 0 {
        minX = min(minX, gx); maxX = max(maxX, gx)
        minY = min(minY, gy); maxY = max(maxY, gy)
    }
}
let largeur = Double(maxX - minX + 1), hauteur = Double(maxY - minY + 1)
let echelle = CANEVAS * OCCUPATION / max(largeur, hauteur)
let decalageX = (CANEVAS - largeur * echelle) / 2
let decalageY = (CANEVAS - hauteur * echelle) / 2

// --- rendu ---------------------------------------------------------------
let espace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(CANEVAS), height: Int(CANEVAS),
                          bitsPerComponent: 8, bytesPerRow: 0, space: espace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("contexte graphique indisponible")
}
ctx.setShouldAntialias(false)
ctx.interpolationQuality = .none

// Rendu de contrôle : « --fond » pose le fond clair du système pour juger le
// glyphe dans ses conditions réelles.
//
// Cette couleur était auparavant le vert quasi noir de l'icône. Elle n'a plus
// lieu d'être : `icon.json` ne déclare **aucun** fond, c'est macOS qui le
// fournit — blanc en apparence claire, gris système en sombre, teinté par
// dérivation. Il n'y a donc plus de couleur de fond à nous quelque part.
if CommandLine.arguments.contains("--fond") {
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CANEVAS, height: CANEVAS))
}

// Les bornes sont arrondies de façon partagée entre cellules voisines :
// aucun liseré transparent entre deux pixels du glyphe.
func borne(_ i: Int, _ decalage: Double) -> Double {
    return (decalage + Double(i) * echelle).rounded()
}

for gy in 0..<N {
    for gx in 0..<N {
        let code = grille[gy][gx]
        guard code != 0, let t = palette[code] else { continue }
        let x0 = borne(gx - minX, decalageX), x1 = borne(gx - minX + 1, decalageX)
        let yb0 = borne(gy - minY, decalageY), yb1 = borne(gy - minY + 1, decalageY)
        // CoreGraphics a son origine en bas : on retourne verticalement
        let y0 = CANEVAS - yb1, y1 = CANEVAS - yb0
        ctx.setFillColor(CGColor(srgbRed: t.r, green: t.v, blue: t.b, alpha: 1))
        ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }
}

guard let image = ctx.makeImage() else { fatalError("rendu impossible") }
let sortie = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "glyphe.png"
let url = URL(fileURLWithPath: sortie) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("destination PNG impossible")
}
CGImageDestinationAddImage(dest, image, nil)
if !CGImageDestinationFinalize(dest) { fatalError("écriture PNG échouée") }
print("écrit : \(sortie)  (glyphe \(Int(largeur))x\(Int(hauteur)) cellules)")
