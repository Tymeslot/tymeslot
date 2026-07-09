# Tymeslot — German (de) Translation Style Guide & Termbase

Authoritative. Mined from the ~1,700 already-translated German msgstrs, with four
ambiguities resolved by the project owner (marked **[DECIDED]**). Follow this exactly.
Where this guide contradicts an existing msgstr in the repo, **this guide wins** — the
existing string is drift and is being corrected.

---

## 1. REGISTER

**Formal "Sie" / "Ihr" everywhere.** Booking flow, emails, dashboard, admin, marketing.
No exceptions. Never "du".

Three informal leaks exist in `emails.po` and are BUGS being fixed separately — do not
copy them as precedent.

---

## 2. GLOSSARY

Capitalisation matters. `E-Mail` is always hyphenated, capital E and M.

| English | German |
|---|---|
| meeting (the booked entity — **default**) | **Termin** |
| meeting (warm email prose, "our meeting") | **Treffen** |
| meeting (the live video session / room) | **Meeting** ("Meeting beitreten", "Meetingraum") |
| appointment | **Termin** |
| booking (noun) | **Buchung** |
| to book | **buchen** |
| to book / arrange (marketing register) | **vereinbaren** |
| **meeting type / event type** | **Termintyp** **[DECIDED]** (never Terminart, never Besprechungstyp) |
| slot / time slot | **Zeitfenster** **[DECIDED]** (never Zeitblock) |
| **organiser / organizer** | **Organisator** **[DECIDED]** (never Veranstalter) |
| **host** (noun) | **Gastgeber** — a distinct role from Organisator; keep them distinct |
| hosted by | **veranstaltet von** |
| attendee | **Teilnehmer** |
| guest | **Gast** / **Gäste** |
| invitee | **Gast** where it means guest, else **eingeladene Person** |
| availability | **Verfügbarkeit** |
| available times | **Verfügbare Zeiten** |
| buffer | **Puffer** / **Pufferzeit** |
| calendar | **Kalender** |
| schedule (verb) | **vereinbaren** / **planen** |
| scheduling (noun) | **Terminplanung** |
| reschedule (verb) | **verschieben** |
| reschedule (noun) | **Terminverschiebung** |
| cancel a meeting/appointment | **absagen** |
| cancel an action / dialog button | **abbrechen** |
| cancelled (a meeting) | **abgesagt** |
| confirm / confirmation | **bestätigen** / **Bestätigung** |
| timezone | **Zeitzone** |
| duration | **Dauer** |
| recurring | **wiederkehrend** |
| **theme** (Quill/Rhythm booking theme) | **Design** **[DECIDED]** (never "Theme"; Quill/Rhythm stay verbatim) |
| event (generic calendar event) | **Ereignis** |
| event (a booked meeting) | **Termin** |
| workspace | **Arbeitsbereich** |
| dashboard | **Dashboard** (loanword) |
| settings | **Einstellungen** |
| profile | **Profil** |
| account | **Konto** |
| sign in / log in (verb) | **anmelden** |
| login / sign-in (noun) | **Anmeldung** |
| sign up (verb) | **registrieren** |
| signup / registration (noun) | **Registrierung** |
| password | **Passwort** |
| authentication | **Authentifizierung** |
| user | **Nutzer** (never Benutzer) |
| admin / administrator | **Administrator** (noun); **Admin-** in compounds |
| workflow | **Workflow** (loanword) |
| automation | **Automatisierung** |
| integration | **Integration** / **Integrationen** |
| webhook | **Webhook** (loanword) |
| embed / embedded | **einbetten** / **eingebettet** |
| subscription | **Abonnement** |
| plan (pricing tier) | **Tarif** |
| billing | **Abrechnung** |
| invoice | **Rechnung** |
| upgrade | **Upgrade** (loanword) |
| trial | **Testphase** |
| payment | **Zahlung** |
| payment receipt | **Zahlungsbeleg** |
| refund | **Rückerstattung** / **erstatten** |
| video call | **Videoanruf** |
| video meeting | **Video-Meeting** |
| location | **Ort** |
| reminder | **Erinnerung** |

### Extended termbase

Settled while translating; reuse rather than re-coining.

| English | German |
|---|---|
| GDPR | **DSGVO** |
| DPA / Data Processing Agreement | **Auftragsverarbeitungsvertrag (AVV)** **[DECIDED]** — short form "AVV"; "SLA" stays verbatim |
| self-hosting (noun) / to self-host / self-hosted | **Self-Hosting** / **selbst hosten** / **selbst gehostet** |
| open source | **Open Source** (noun) · **Open-Source-** (compound) · **quelloffen** (adj) |
| closed-source | **closed-source** (loanword) |
| managed cloud | **Managed Cloud** |
| data residency | **Datenresidenz** · EU data residency → **EU-Datenstandort** |
| data ownership | **Datenhoheit** |
| identity provider | **Identity Provider** |
| multi-tenant / tenant boundary | **mandantenfähig** / **Mandantengrenze** |
| compliance | **Compliance** |
| priority support | **Priority-Support** |
| lock-in | **Lock-in** |
| flat pricing | **Pauschalpreis** / **pauschal** |
| per-seat / per-user | **pro Platz** / **pro Nutzer** |
| free tier vs free plan | **kostenlose Stufe** vs **kostenloser Tarif** (keep distinct where English does) |
| "Free" as a *price value* | **Kostenlos** (but tier names "Cloud Free", "Cloud Pro", "Self-Hosted" stay verbatim) |
| two-way sync | **beidseitige Synchronisierung** |
| conflict checking | **Konfliktprüfung** |
| double bookings | **Doppelbuchungen** |
| free/busy | **Frei/Gebucht** (matches Outlook DE) |
| Healthy (status badge) | **Fehlerfrei** (vs "Connection issues" → Verbindungsprobleme) |
| read-only | **schreibgeschützt** |
| "Upgrade <X> permissions" | **„<X>-Berechtigungen erweitern"** (the bare button "Upgrade" stays a loanword) |
| week number / Wk | **Kalenderwoche** / **KW** |
| gradient / solid colour / hue / preset | **Farbverlauf** / **Volltonfarbe** / **Farbton** / **Voreinstellung** |
| booking flow / booking page / booking link | **Buchungsablauf** / **Buchungsseite** / **Buchungslink** |
| interface language | **Oberflächensprache** (avoids the banned "Benutzer") |
| Custom (a user-defined value) | **Benutzerdefiniert** — the only sanctioned use of "Benutzer-", a different sense from *user* |
| in-person (location) | **Vor Ort** |
| unlisted | **Nicht gelistet** |
| minimum notice | **Mindestvorlaufzeit** |
| advance booking window | **Vorausbuchungszeitraum** |
| conversion (analytics) | **Conversion** (loanword) · est. → **(gesch.)** |
| visit / unique visitors / traffic | **Besuch** / **Eindeutige Besucher** / **Zugriffe** |
| occurrence (recurrence) | **Vorkommen** |
| declined (a guest) | **abgelehnt** — distinct from **abgesagt** (a cancelled meeting) |
| avatar | **Avatar** |

**Weekday abbreviations:** Mo · Di · Mi · Do · Fr · Sa · So

### Third-party UI labels — never guess

When a setup instruction tells the user to click something in another company's product, the label
must match what that product actually shows in German. Invent one and the user hunts for a menu item
that does not exist. Look it up on the vendor's own German-language page, and note the surface: the
web app and the mobile app often differ.

| Context | English | German |
|---|---|---|
| Apple, **web** (`appleid.apple.com`, now `account.apple.com`) | Sign-In and Security | **Anmelden und Sicherheit** |
| Apple, **iOS/macOS Settings** | Sign-In and Security | **Anmeldung & Sicherheit** — *different wording, note the ampersand* |
| Apple | App-Specific Passwords (menu label) | **App-spezifische Passwörter** |
| Apple | app-specific password (running prose) | **App-spezifisches Passwort** |
| Apple | *Generate* an app-specific password | **Erstellen** (Apple's own verb; not "generieren") |
| mailbox.org | Settings → Security | **Einstellungen → Sicherheit** |

Source for the Apple labels: `support.apple.com/de-de/102654`. Our string links to the web page, so
it uses **"Anmelden und Sicherheit"**. Apple has renamed "Apple ID" to "Apple Account" (untranslated
in German), and `appleid.apple.com` now redirects to `account.apple.com`; our source string still
says "Apple ID", so the German keeps **Apple-ID** until the English is updated.

### Sample and placeholder values

Illustrative values inside input placeholders follow one rule:

- **Localise prose-shaped samples**: `yourname` → `ihrname`, `your-username` → `ihr-nutzername`,
  `e.g. Jane Smith` → a German name.
- **Keep format-shaped samples verbatim**: e-mail addresses (`your.email@example.com`), URLs and
  hosts (`https://caldav.example.com`), API keys (`your-api-key-here`), and any `example.com`.
  These are formats, not words, and `.com` is universal.

**Common UI labels:** Save→Speichern · Continue→Fortfahren · Back→Zurück · Next→Weiter ·
Submit→Absenden · Done/Finish→Fertig · Add→Hinzufügen · Close→Schließen ·
Skip→Überspringen · Got it→Verstanden · Required fields→Pflichtfelder ·
Select→wählen/auswählen · Privacy Policy→Datenschutzerklärung ·
Terms of Service→Nutzungsbedingungen · Enabled/Disabled→Aktiviert/Deaktiviert ·
Analytics→Analyse.

---

## 3. DO NOT TRANSLATE — keep verbatim

**Tymeslot** (compounds hyphenate: "Tymeslot-Konto", "Tymeslot-Dashboard"), Stripe,
Stripe Checkout, Stripe Connect, reCAPTCHA, Google, Google Calendar, Google Meet, GitHub,
Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail, Zimbra, Radicale,
mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript, OAuth, OIDC, SSO,
Oban, UTM, Cloudron.

Loanwords kept as-is: Dashboard, Meeting (the live session), Webhook, Slug, Score,
Upgrade, Workflow.

**Environment-variable and config names verbatim**, always: `REGISTRATION_ENABLED`,
`PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`,
`OAUTH_*`, etc.

---

## 4. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` — the hard rule:**
- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr must have exactly those three.
- You **may and should reorder** them to fit German syntax:
  - `"%{month} %{day}, %{year}"` → `"%{day}. %{month} %{year}"`
  - `"You're booking a %{duration} meeting with %{name}"` → `"Sie buchen einen Termin (%{duration}) mit %{name}"`
- German date idiom: a `.` follows the day number — `"%{day}. %{month} %{year}"`.
- A build gate checks this. A dropped or invented placeholder is a runtime crash.

**Markup / entities:** keep verbatim inside the msgstr.
- `"<strong>removed from your external calendar</strong>"` → `"<strong>aus Ihrem externen Kalender entfernt</strong>"`
- `&` stays literal (not `&amp;`). Bullets `•`, checkmarks `✓`, emoji are preserved.

**Typography — use these characters:**
- Ellipsis **`…`** (U+2026), never `...`
- En dash **`–`** for ranges and subject-line separators
- Em dash **`—`** (space-padded) for parenthetical asides, mirroring the English em dash
- German quotes **`„…“`** — low-9 opening `„` (U+201E), high-6 closing `“` (U+201C)
- Decimal comma: `"0.0 and 1.0"` → `"0,0 und 1,0"`
- `z. B.` (with space) for "e.g."

---

## 5. PLURALS

German is `nplurals=2; plural=(n != 1);`.
`msgstr[0]` = singular (n == 1). `msgstr[1]` = everything else, **including 0**.
Both must be filled. Placeholders present in a form must appear in that form.

```
msgid "hour"
msgid_plural "hours"
msgstr[0] "Stunde"
msgstr[1] "Stunden"
```

---

## 6. TONE BY REGISTER

- **Marketing** — warm, direct, confident. Not stiff corporate German. Rephrase idioms
  rather than calquing them. `"stop the back-and-forth and start booking"` →
  `"Schluss mit dem ewigen Hin und Her, ab jetzt wird direkt gebucht."` Keep Sie, but let
  sentences breathe. Headlines should land as headlines, not as translated headlines.
- **Dashboard / admin UI** — terse, functional. Buttons are imperatives or nouns
  (Speichern, Befördern). Toggle states are adjectives (Aktiviert/Deaktiviert). System
  feedback is clean declarative: `"Einstellung konnte nicht aktualisiert werden."`
  No filler, no exclamation marks except genuine success.
- **Transactional email** — polite, clear, human. Greeting `"Hallo %{name},"`.
  Sign-off `"Best,"` → `"Beste Grüße,"` (no comma after the valediction if it stands
  alone on its line before a name). Apologies courteous: `"Bitte entschuldigen Sie die
  Unannehmlichkeiten."`
- **Booking flow (public)** — friendly, encouraging. Prompts guide the invitee:
  `"Bitte wählen Sie ein Datum, um verfügbare Zeiten zu sehen"`. Success is upbeat:
  `"Termin bestätigt!"`

---

## 7. ONE-LINE SUMMARY

Formal **Sie**. **Termin** (booked meeting) · **Buchung** · **Termintyp** ·
**Zeitfenster** · **Organisator** (organiser) vs **Gastgeber** (host) · **Teilnehmer** ·
**Gast** · **Nutzer** (not Benutzer). Keep **Tymeslot / brand names / env vars / `%{…}`**
verbatim. Use `„…“`, `–`, `—`, `…`, decimal comma. Never drop or invent a placeholder.
