# Booking page fonts

Self-hosted web fonts for the booking themes, declared in `assets/css/scheduling/shared/fonts.css`, which also defines the font stacks the themes and the font option group use. Each family is a variable font (weight axis only) in the Latin and Latin Extended subsets and, where the typeface has one, the Cyrillic subset (every family but Fraunces, which has no Cyrillic glyphs); characters outside them fall back to the system fonts at the end of each stack. Every family is under the SIL Open Font License 1.1; its licence text, with the family's copyright line, is the `OFL-<family>.txt` beside its files.

## Where the files come from

The font files are from the Fontsource variable packages on npm, all at version 5.3.0, fetched through jsDelivr:

```
https://cdn.jsdelivr.net/npm/@fontsource-variable/<family>@5.3.0/files/<family>-<subset>-wght-normal.woff2
```

The licence texts are from the `google/fonts` repository at commit `23e54b51ddffbc7713c583748e3bd86f62b1fa4a`, because the Fontsource `LICENSE` files of the two Source families carry a placeholder copyright line:

```
https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/<dir>/OFL.txt
```

| Family | npm package | Weights | Files | Licence (`google/fonts` dir) |
|---|---|---|---|---|
| Inter | `@fontsource-variable/inter@5.3.0` | 100 to 900 | `inter-latin-wght-normal.woff2`, `inter-latin-ext-wght-normal.woff2`, `inter-cyrillic-wght-normal.woff2` | `OFL-inter.txt` (`ofl/inter`) |
| IBM Plex Sans | `@fontsource-variable/ibm-plex-sans@5.3.0` | 100 to 700 | `ibm-plex-sans-latin-wght-normal.woff2`, `ibm-plex-sans-latin-ext-wght-normal.woff2`, `ibm-plex-sans-cyrillic-wght-normal.woff2` | `OFL-ibm-plex-sans.txt` (`ofl/ibmplexsans`) |
| Source Serif 4 | `@fontsource-variable/source-serif-4@5.3.0` | 200 to 900 | `source-serif-4-latin-wght-normal.woff2`, `source-serif-4-latin-ext-wght-normal.woff2`, `source-serif-4-cyrillic-wght-normal.woff2` | `OFL-source-serif-4.txt` (`ofl/sourceserif4`) |
| Source Sans 3 | `@fontsource-variable/source-sans-3@5.3.0` | 200 to 900 | `source-sans-3-latin-wght-normal.woff2`, `source-sans-3-latin-ext-wght-normal.woff2`, `source-sans-3-cyrillic-wght-normal.woff2` | `OFL-source-sans-3.txt` (`ofl/sourcesans3`) |
| Lora | `@fontsource-variable/lora@5.3.0` | 400 to 700 | `lora-latin-wght-normal.woff2`, `lora-latin-ext-wght-normal.woff2`, `lora-cyrillic-wght-normal.woff2` | `OFL-lora.txt` (`ofl/lora`) |
| Fraunces | `@fontsource-variable/fraunces@5.3.0` | 100 to 900 | `fraunces-latin-wght-normal.woff2`, `fraunces-latin-ext-wght-normal.woff2` | `OFL-fraunces.txt` (`ofl/fraunces`) |

The `unicode-range` and `font-weight` of each `@font-face` rule are copied from the package's `wght.css`.

## Checksums (SHA-256)

Check with `sha256sum -c` from this directory, feeding it the block below.

```
34b9c504cab7a73e37b746343a449132e56cf7b5481af2cb81dc74dcff25c956  inter-latin-ext-wght-normal.woff2
3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62  inter-latin-wght-normal.woff2
71d5ee93cc1e9f1d520a3a8b66456de18c7879d8df09d57fcd2eaff75fef0075  inter-cyrillic-wght-normal.woff2
d160e20920ae4d6556518d352d3af27a74e9b0de3d8fe17b1c1044fc75aa2f81  ibm-plex-sans-latin-ext-wght-normal.woff2
e2291e842cf5af167122a22881a740c7f2dda7716f1e8cd76680264f4a859470  ibm-plex-sans-latin-wght-normal.woff2
9409ee21811f0f5272b7e1d828fe8838005b0573481ef906e7e55b63f6610ab0  ibm-plex-sans-cyrillic-wght-normal.woff2
41529a5b38008d9ea01e28ec18693a714a3216669ee477d83a5b9db999369625  source-serif-4-latin-ext-wght-normal.woff2
c1df4596be5029233ed2afbb8b2f6ea20784b3fb1aa5d6b5c6519ccd85eb3dfb  source-serif-4-latin-wght-normal.woff2
25e85aef8acff54f91ea7e85c9c2c260caf97101fdef194ed6b8b58bc34ce3eb  source-serif-4-cyrillic-wght-normal.woff2
a85a7459bdb3cdc1136751e151a506bae653fc29ada3ca86237477df6f1b59e6  source-sans-3-latin-ext-wght-normal.woff2
7a19a7027e125257d310c6dbd78ae3a30b5ea1e3794d60b12bb28227a003bfda  source-sans-3-latin-wght-normal.woff2
b6b721e08d0324b9e743858e8260463085d4c5e1e684f036f9d4a8ca6c62996f  source-sans-3-cyrillic-wght-normal.woff2
2a2d9c22c9863086a23f5013fede1428585321812b25f2662542c39d02967c5e  lora-latin-ext-wght-normal.woff2
ddb8c66035104e233fc024669183aad3738b6daa16deee2ebb1241bd0f98ace1  lora-latin-wght-normal.woff2
c57d9ca3bd42e6bc093badc7744dd2059a78f66a3a4dc6ca40574480c870f553  lora-cyrillic-wght-normal.woff2
a21ecfbf41fbc393e24ef9b7e38532a27e8da5e0a074aa7d66802d1b5ccec2f0  fraunces-latin-ext-wght-normal.woff2
7f9d191d999336d3b9790afa72e1358e50a13b06d4f289341e92a311967a80f9  fraunces-latin-wght-normal.woff2
5b9321a4298cfeb6b34354164a1c3afc3db114569984c502b9b35d988fd58c57  OFL-inter.txt
7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da  OFL-ibm-plex-sans.txt
5f94c3fd3a23131a417ab5a0c8452de57e70c3cfb9f604d88241f7065ebf9fd9  OFL-source-serif-4.txt
09746787287a289323b0ec3cff4d1a4a801331b82b7207c1e186f5d26619a392  OFL-source-sans-3.txt
1d9a970809ac804b582a6ce7f0ebc4e7fefcbfd7ff6299cad35ee656a21be716  OFL-lora.txt
bdf4c22802eaf804f998195871c6b8938aac2ac14b2d78a8bd66a6f1eced833b  OFL-fraunces.txt
```

## Updating

Change the version in the URLs above, fetch again, replace the checksums, and compare each package's `wght.css` (`unicode-range`, `font-weight`) with `fonts.css`. A new family also needs its `@font-face` pair and stacks in `fonts.css`, its row here and its licence; `TymeslotWeb.Themes.SharedFontsTest` fails until the files, the rules and the licences agree.
