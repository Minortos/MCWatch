# Contributing

## Translations

The most useful thing anyone can contribute.

All the interface text is in `Ressources/Localizable.xcstrings`. Open it in
Xcode: English on the left, the target language on the right. Edit the right
column, open a pull request — no rebuild needed.

The eight languages other than English and French are machine-translated and
marked **Needs Review**, so you can filter on that column and see exactly what
no person has checked. French is the author's own wording.

- English is the source language. Its text lives in the keys, which is why there
  is no `en.lproj` in the built app. A missing translation falls back to it.
- Some strings carry a plural, shown as a disclosure triangle. Xcode gives you
  the categories your language needs — four for Polish and Russian, two for most.
- `%@` and `%lld` are placeholders. Keep them all, in whatever order your
  language wants. Xcode complains if one goes missing.
- Three strings are marked "don't translate": the app name, the example search,
  and a URL.

**The update window is not ours.** It comes from Sparkle, which ships its own
translations; mistakes there belong
[upstream](https://github.com/sparkle-project/Sparkle). Ours: the **Check for
Updates…** menu item and the four lines under Settings → About.

## Before you open a pull request

```bash
swift test
```

198 tests, no setup, no network, no Shodan credits, under a second. They cover
`MCWatchCore` only — the ping protocol, query building, filtering, the scan
merge, both storage backends, and the attack surfaces. Views are deliberately
left out.

Two matter before you touch filtering or decoding. **`accordSurLaRegularite`**
compares both storage backends across every regularity threshold — the filtering
rule exists in three writings and they once disagreed on values sitting exactly
on it. **The fuzzers** throw hostile buffers at the varint reader, nested MOTDs
at the flattener and arbitrary strings at the cleaner, on a fixed seed.

Several bounds in `Ping.swift` were written after a real crash. If you add a
defence against malformed network data, add the test that keeps it there.

## The code is in French

Identifiers and comments are in French, and that will not change. The interface
text is English, so translations are unaffected. This glossary covers most of it:

| French | English |
| --- | --- |
| `Bilan` | summary of one scan |
| `Cible` | target (an address to ping) |
| `Classement` | the main table |
| `Coupable` | the filter responsible for hiding something |
| `Écarté` | excluded by a filter |
| `Emplacement` | where the app is installed |
| `Filtres` | filters |
| `Hébergeur` | hosting provider |
| `Marque` / `Verdict` | the ✓ / ✗ you put on a server |
| `Muet` | silent (a server that did not answer) |
| `Peuplé` | populated (at least one player) |
| `Pic` | peak player count |
| `Profil` | a saved search and its history |
| `Relevé` / `Tour` | one scan of the whole list |
| `Réglages` | settings |
| `Requête` | a Shodan query |
| `Solde` | credit balance |
| `Slug` | folder name derived from a search |
| `Stockage` / `Dépôt` | storage layer |
| `Trousseau` | keychain |
| `Veille` | file-system watch |
| `Vue…` | a SwiftUI view |

## Building

```bash
./construire.sh
```

Xcode 27 or later; see the README for signing. Write a new user-visible string
in English in the source and run the build once — it appears in the catalog,
ready to translate.

`mcwatch-verif` is a development harness. It is not shipped and its output is in
French.

## What will not be merged

Anything that gains access the app was refused is out of scope: whitelist or ban
bypass, authentication attempts, exploits, credential guessing. Same for
features that publish the addresses it finds, or raise the scan rate.

Everything else is ok — bug reports especially.

## If you fork and ship it

You are free to, and you do not need to ask. But your fork cannot update anyone
until you do three things, because two things are deliberately absent here.

**Generate your own update key.** Sparkle signs every release with an EdDSA key.
The public half of mine is in `Ressources/Info.plist` under `SUPublicEDKey`; the
private half is not in this repository and never will be. Run `generate_keys`
from `.build/artifacts/sparkle/Sparkle/bin/` and replace `SUPublicEDKey` with
what it prints. The private half goes to your keychain.

**Point the feed at your own repository.** `SUFeedURL`, same file. Left as it
is, your fork offers *my* releases to your users, then refuses to install them.

**Sign with your own certificate.** `construire.sh` looks for team
`CT2VKA6A5C` and falls back to whatever identity your keychain holds. Change the
constant.

The GPL asks for source code; a signing key is not source code.

## Licensing

MC Watch is under the GNU General Public License, version 3 or later. Anything
you contribute is published under that same licence, translations included, and
you keep the copyright on what you wrote.

A new source file carries the same three-line header as the others, with your
own name:

```swift
// MC Watch — Search, watch and join home Minecraft servers with players from other countries.
// Copyright (C) 2026 <you>
// SPDX-License-Identifier: GPL-3.0-or-later
```
