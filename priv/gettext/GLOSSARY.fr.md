# Tymeslot — French (fr) Translation Style Guide & Termbase

Authoritative. Mined from the ~3,800 already-translated French msgstrs, with the drifting
terms resolved in a single terminology pass (marked **[SETTLED]**). Follow this exactly.
Where this guide contradicts an existing msgstr in the repo, **this guide wins** — the
existing string is drift and is being corrected.

French decisions are made on French grounds. Do not port a choice across from
[`GLOSSARY.de.md`](GLOSSARY.de.md); the two languages resolve the same ambiguity differently
(German keeps *Dashboard* as a loanword, French translates it).

---

## 1. REGISTER

**Formal *vous* / *votre* everywhere.** Booking flow, emails, dashboard, admin, marketing.
No exceptions. Never *tu*.

The catalogue is currently clean on this: 969 occurrences of *vous / votre / vos*, zero of
*tu / ton / ta / toi*. Keep it that way.

**Imperative vs infinitive** follows the standard French-UI split, and it is consistent
across the catalogue:

- **Infinitive for buttons and actions**: `Annuler`, `Enregistrer`, `Ajouter`, `Supprimer`,
  `Modifier`, `Reporter`, `Réserver la réunion`, `Sélectionner une date`.
- **Imperative for instructional prose and help text**: `Choisissez votre style`,
  `Saisissez votre mot de passe`, `Connectez au moins un calendrier`.

**Confirmation dialogs** open with `Voulez-vous vraiment …` — not `Êtes-vous sûr(e) de
vouloir …`. The first is the house form and the majority.

---

## 2. GLOSSARY

The core domain terms. The left column is the **English source word**, and the mapping is
one-way and strict: the same English word gets the same French word everywhere.

| English | French |
|---|---|
| **meeting** | **réunion** **[SETTLED]** — never *rendez-vous* |
| **appointment** | **rendez-vous** **[SETTLED]** — never *réunion* |
| booking (noun) | **réservation** |
| to book | **réserver** |
| meeting type | **type de réunion** |
| event type | **type d’événement** (the English source distinguishes the two; so does the French) |
| **slot / time slot** | **créneau** **[SETTLED]** — never *plage horaire* for a single bookable slot |
| **host** (the person) | **organisateur** **[SETTLED]** — never *hôte* |
| **organiser / organizer** | **organisateur** — the same person as *host*; French uses one word for both |
| hosted by | **organisé par** |
| host page (embed target) | **page hôte** — the *only* surviving use of *hôte*, and a different sense (a machine, not a person) |
| attendee | **participant** |
| guest | **invité** / **invités** |
| **availability** | **disponibilités** (plural) for the nav item and the page title **[SETTLED]**; *disponibilité* (singular) only for the abstract concept ("la disponibilité est calculée en direct") |
| available times | **créneaux disponibles** |
| **buffer / buffer time** | **marge** / **temps de marge** **[SETTLED]** — never *tampon* |
| calendar | **calendrier** |
| schedule (verb) | **planifier** |
| scheduling (noun) | **planification** |
| **reschedule** (verb) | **reporter** **[SETTLED]** — never *reprogrammer* |
| reschedule (noun) | **report** |
| cancel a meeting | **annuler** |
| cancel an action / dialog button | **Annuler** |
| cancelled | **annulé** / **annulée** |
| confirm / confirmation | **confirmer** / **confirmation** |
| **going** (guest RSVP) | **présent** **[SETTLED]** — never *confirmé* (which is what a *booking* is) |
| declined (a guest) | **refusé** — distinct from **annulé** (a cancelled meeting) |
| timezone | **fuseau horaire** |
| duration | **durée** |
| theme (Quill/Rhythm booking theme) | **thème** (Quill/Rhythm stay verbatim) |
| event (calendar event) | **événement** |
| **dashboard** | **tableau de bord** **[SETTLED]** — never left as *Dashboard*, including *tableau de bord Stripe* |
| settings | **paramètres** |
| profile | **profil** |
| account | **compte** |
| log in / sign in (verb) | **se connecter** |
| sign up (verb) | **s’inscrire** |
| password | **mot de passe** |
| user | **utilisateur** |
| admin / administrator | **administrateur** |
| automation | **automatisation** |
| integration | **intégration** / **intégrations** |
| webhook | **webhook** (loanword) |
| subscription | **abonnement** |
| **plan** (pricing tier) | **forfait** **[SETTLED]** — never *offre* |
| **tier** (a rung of a pricing ladder) | **palier** **[SETTLED]** — "higher tiers" → *paliers supérieurs*, "per-seat tiers" → *paliers par siège* |
| free plan / free tier | **forfait gratuit** — the same product object; do not split it into two French words |
| billing | **facturation** |
| upgrade | **mettre à niveau** |
| payment | **paiement** |
| **refund** | **remboursement** — full → **remboursement intégral** **[SETTLED]** (never *total*); partial → **remboursement partiel** |
| video call | **appel vidéo** |
| location | **lieu** |
| reminder | **rappel** |
| **invalid** | **invalide** **[SETTLED]** — never *non valide* |

### Extended termbase

Settled while translating; reuse rather than re-coining.

| English | French |
|---|---|
| **tracker** | **traceur** **[SETTLED]** — never *traqueur*. This is the CNIL's own term ("cookies et autres traceurs"), so it is the register a French reader meets in privacy law and cookie banners. *Traqueur* is an anglicism-driven coinage. "tracker-free booking pages" → **pages de réservation sans traceurs** |
| **Privacy Policy** | **Politique de confidentialité** **[SETTLED]** — never *Règles de confidentialité* |
| Terms of Service | **Conditions d’utilisation** |
| privacy | **confidentialité** |
| privacy-first | **la confidentialité avant tout** |
| GDPR | **RGPD** |
| self-hosting / to self-host / self-hosted | **auto-hébergement** / **auto-héberger** / **auto-hébergé** |
| open source | **open source** (invariable, no hyphen) |
| closed-source | **code fermé** |
| managed cloud | **cloud géré** |
| data residency | **résidence des données** |
| data ownership | **maîtrise des données** |
| lock-in | **verrouillage propriétaire** |
| flat pricing | **tarification forfaitaire** |
| per-seat / per-user | **par siège** / **par utilisateur** |
| "Free" as a price value | **Gratuit** (but tier *names* — Cloud Free, Cloud Pro, Pro, Enterprise — stay verbatim) |
| two-way sync | **synchronisation bidirectionnelle** |
| free/busy | **libre/occupé** |
| double bookings | **doubles réservations** |
| minimum notice | **préavis minimum** |
| booking window | **fenêtre de réservation** |
| interface language | **langue de l’interface** |
| Custom (a user-defined value) | **Personnalisé** |
| in-person (location) | **En personne** |
| unlisted | **Non répertorié** |
| Healthy (status badge) | **Opérationnel** |
| gradient | **dégradé** |
| week number / Wk | **semaine** / **Sem.** |
| **inline embed** | **Intégration en ligne** **[SETTLED]** — Core's dashboard wording wins over marketing's *Embed inline* |
| **popup modal** | **Fenêtre modale** **[SETTLED]** — over marketing's *Modale popup* |
| Close modal | **Fermer la fenêtre modale** **[SETTLED]** — distinct from *Close dialogs* → **Fermer les boîtes de dialogue**; the English keeps modal and dialog apart, so French does too |

**Weekday abbreviations:** `Lun.` · `Mar.` · `Mer.` · `Jeu.` · `Ven.` · `Sam.` · `Dim.`
**[SETTLED]** — with the full stop. French abbreviation by truncation takes a point, and
`Sem.` (Wk) already does.

> The **all-caps** msgids (`MON`, `TUE`, …) are a *separate* string used in the compact
> calendar strip, and they stay periodless: `LUN`, `MAR`, … Do not "fix" them to match.

### Third-party UI labels — never guess

When a setup instruction tells the user to click something in another company's product, the
label must match what that product actually shows **in French**. Invent one and the user hunts
for a menu item that does not exist. Look it up on the vendor's own French-language page, and
note the surface: the web app and the mobile app often differ.

| Context | English | French |
|---|---|---|
| Apple (`account.apple.com`) | Sign-In and Security | **Connexion et sécurité** |
| Apple | App-Specific Passwords (menu label) | **Mots de passe spécifiques aux applications** |
| Apple | app-specific password (running prose) | **mot de passe spécifique à l’application** |

> ⚠️ The Apple labels above are what the catalogue currently ships. Apple periodically renames
> these screens (and has renamed "Apple ID" to "Apple Account"). **Re-verify against
> `support.apple.com/fr-fr` before editing them** — do not treat this table as a licence to
> stop checking.

### Sample and placeholder values

Illustrative values inside input placeholders follow one rule:

- **Localise prose-shaped samples**: `e.g. John Doe` → `p. ex. Jean Dupont`,
  `e.g. Jane Smith` → `p. ex. Jeanne Dupont`, `e.g. Lunch` → `p. ex. Déjeuner`.
- **Keep format-shaped samples verbatim**: URLs and hosts (`https://caldav.example.com`),
  API keys, and — **[SETTLED]** — the domain `example.com` in every e-mail sample. It is
  reserved by RFC 2606 for documentation; `exemple.com` and `exemple.fr` are real,
  registrable domains and must not be used. Localise only the **local part**:
  `john@example.com` → `jean.dupont@example.com`, `your.email@example.com` →
  `votre.email@example.com`.

**e.g.** → **`p. ex.`** **[SETTLED]** — never bare `ex.`, and **no comma after it**, even
where the English writes "e.g.,".

**Common UI labels:** Save→Enregistrer · Cancel→Annuler · Continue→Continuer · Back→Retour ·
Next→Suivant · Done→Terminé · Add→Ajouter · Close→Fermer · Skip→Passer · Got it→Compris ·
Delete→Supprimer · Edit→Modifier · Confirm→Confirmer · Copy→Copier · Today→Aujourd’hui ·
Enabled/Disabled→Activé/Désactivé · Required→Obligatoire · Pending→En attente ·
Analytics→Statistiques.

---

## 3. DO NOT TRANSLATE — keep verbatim

**Tymeslot**, Stripe, Stripe Checkout, Stripe Connect, reCAPTCHA, Google, Google Calendar,
Google Meet, GitHub, Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail,
Zimbra, Radicale, mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript, OAuth,
OIDC, SSO, Oban, UTM, Cloudron.

Plan names stay verbatim: **Pro**, **Enterprise**, **Cloud Free**, **Cloud Pro**,
**Self-Hosted**.

Loanwords kept as-is: **webhook**, **slug**, **open source**, **cloud**, **SaaS**.

**Environment-variable and config names verbatim**, always: `REGISTRATION_ENABLED`,
`PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`,
`OAUTH_*`, and friends. Same for HTML data attributes quoted in marketing copy
(`data-theme`, `data-primary-color`, `data-locale`).

---

## 4. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` — the hard rule:**

- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr must have exactly those three.
- You **may and should reorder** them to fit French syntax.
- A build gate checks this. A dropped or invented placeholder is a runtime crash.

> **`%{organizer}` is not a bare name.** In `booking.po` it already expands to a *translated*
> string — `"avec Jean Dupont"` — because `get_organizer_text/1` renders
> `dgettext("booking", "with %{name}")` before interpolating. So the French msgstr must **not**
> add its own *avec*, or the page reads "votre réunion **avec avec** Jean Dupont". The English
> msgids deliberately omit the preposition for this reason. (In `emails.po`, by contrast,
> `%{organizer}` *is* a bare name and the "avec" belongs in the msgstr. Check the call site.)

**Markup / entities:** keep verbatim inside the msgstr. `<strong>…</strong>`, `&` (literal,
not `&amp;`), bullets `•`, checkmarks `✓`, arrows `→` and emoji are preserved. When French
grammar forces an agreement inside a tag, change the *text*, never the tag:
`<strong>supprimé …</strong>` → `<strong>supprimée …</strong>`.

**Typography — use these characters:**

- **Apostrophe `’` (U+2019), always.** Never the ASCII `'`. The whole French catalogue is
  normalised to `’` and there is a check for it. `l’organisateur`, `n’est`, `d’origine`.
- Quotes: **guillemets `« … »`**, with a space inside each guillemet — `« %{title} »`.
  Never `"…"`.
- **A space before `? ! : ;`** — `Voulez-vous vraiment continuer ?`, `Réunion : %{title}`.
  This is applied in ~450 strings and is not optional.
- Ellipsis `…` or the source's own `...` — follow the msgid.
- Em dash **`—`** (space-padded) for parenthetical asides, mirroring the English.
- Decimal comma: `0.5%` → `0,5 %`, with a space before the `%`.
- Currency symbol **after** the number: `29 $`, `12 €`, `99 $/an`.

---

## 5. PLURALS

French is `nplurals=2; plural=(n>1);`.

`msgstr[0]` = n is 0 or 1. `msgstr[1]` = everything else. **Note this differs from German** —
in French, **zero takes the singular form**.

Both forms must be filled. Placeholders present in a form must appear in that form.

```po
msgid "hour"
msgid_plural "hours"
msgstr[0] "heure"
msgstr[1] "heures"
```

Invariant nouns keep the same string in both forms (`mois` → `mois`). Do not invent a
spurious "(s)".

---

## 6. TONE BY REGISTER

- **Marketing** — warm, direct, confident. Not stiff corporate French. Rephrase idioms rather
  than calquing them; a headline must land as a headline, not as a translated headline.
  Keep *vous*, but let the sentences breathe.
- **Dashboard / admin UI** — terse, functional. Buttons are infinitives (`Enregistrer`,
  `Reporter`) or nouns. Toggle states are adjectives (`Activé` / `Désactivé`). System feedback
  is clean declarative: `Le paramètre n’a pas pu être mis à jour.` No filler, no exclamation
  marks except on genuine success.
- **Transactional email** — polite, clear, human. Greeting `Bonjour %{name},`. Apologies
  courteous: `Je vous présente mes excuses pour ce désagrément.`
- **Booking flow (public)** — friendly, encouraging. Prompts guide the invitee:
  `Veuillez sélectionner une date pour voir les créneaux disponibles`. Success is upbeat:
  `Réservation confirmée !`

---

## 7. OPEN QUESTIONS

Not settled — flagged rather than decided unilaterally, because each needs a product call.

- **"embed" in SaaS marketing prose.** `marketing_features.po` keeps the bare English noun
  throughout running text (`l’embed`, `les embeds`, `un style d’embed`, `Thème par embed`),
  while Core's dashboard translates the concept (`Intégration en ligne`, `Fenêtre modale`).
  The two *identical msgids* (`Inline Embed`, `Popup Modal`) have been aligned on Core, but the
  ~25 prose occurrences have not been touched. Translating them to *intégration* collides with
  *integration* (Google Calendar **intégrations**), which is why this needs a decision rather
  than a find-and-replace. Options: (a) accept the anglicism and use *embed* consistently in
  both apps, (b) go to *intégration* everywhere and live with the collision, (c) coin a
  distinct term (*widget d’intégration*, *code d’intégration*).
- **`Indisponible` is doing double duty** for both `Unavailable` and the toggle state `Off`.
  Two English strings, one French word.

---

## 8. ONE-LINE SUMMARY

Formal **vous**. **réunion** (meeting) vs **rendez-vous** (appointment) · **réservation** ·
**créneau** · **organisateur** (host *and* organiser) · **participant** · **invité** ·
**tableau de bord** · **forfait** (plan) vs **palier** (tier) · **marge** (buffer) ·
**reporter** (reschedule) · **traceur** (tracker) · **invalide**. Keep **Tymeslot / brand
names / plan names / env vars / `example.com` / `%{…}`** verbatim. Typographic apostrophe
**`’`** always, **« … »**, space before **`? ! : ;`**, currency after the number. Never drop
or invent a placeholder — and never add "avec" to `%{organizer}` in `booking.po`.
