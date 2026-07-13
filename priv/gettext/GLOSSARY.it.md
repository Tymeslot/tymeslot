# Tymeslot — Italian (it) Translation Style Guide & Termbase

Authoritative. Mined from the ~3,800 already-translated Italian msgstrs and settled during the terminology unification sweep. Follow this exactly. Where this guide contradicts an existing msgstr in the repo, **this guide wins**: the existing string is drift and is being corrected.

---

## 1. REGISTER

**Informal "tu" everywhere.** Booking flow, emails, dashboard, admin, marketing. No exceptions. Never "Lei", never the impersonal infinitive.

Buttons, prompts and instructions take the **2nd-person-singular imperative**: `Salva`, `Annulla`, `Conferma`, `Aggiungi`, `Scegli`, `Riprova`, `Incolla`, `Fai clic`. Never `Salvare`, `Riprovare`, `Fare clic`.

Possessives are `tuo` / `tua` / `tuoi` / `tue`, never `proprio`.

Confirmation modals ask `Vuoi davvero …?`, not `Sei sicuro di …?` and not `Confermare l'operazione?`.

---

## 2. GLOSSARY

### The meeting family (settle this first)

Three English concepts, three Italian words. They are not interchangeable.

| English | Italian | Where |
|---|---|---|
| **meeting** (the booked entity, the live video session, any label, heading, button or subject line) | **riunione** | The head term. Default to it. `Riunione confermata`, `Dettagli della riunione`, `Partecipa alla riunione video`, `Tipo di riunione`, `Riunione annullata` |
| **meeting** in the relational sense, i.e. English *"our meeting"* / *"meeting you"* in warm first-person prose from the host | **incontro** | Emails and booking prose only: `il nostro prossimo incontro`, `Attendo con piacere il nostro incontro`, `Il nostro incontro si avvicina`. **Never** in a label, heading, button or UI string. |
| **appointment** (the English word *appointment*) | **appuntamento** | `Annulla appuntamento`, `Riprogramma appuntamento`, `Organizzatore dell'appuntamento` |

`appuntamento` is reserved for the English word *appointment*. It is never a rendering of *meeting*. The one exception is the fixed Italian idiom `fissare un appuntamento`, which may render an English verb phrase that has no noun ("How far into the future clients can schedule with you" → `… possono fissare un appuntamento con te`).

`riunione` is **feminine**. Watch agreement when you replace `appuntamento`: `il tuo appuntamento è stato riprogrammato` becomes `la tua riunione è stata riprogrammata`.

### Core termbase

| English | Italian |
|---|---|
| **meeting type** | **tipo di riunione** (never `tipo di incontro`, never `tipo di evento`) |
| **event type** | **tipo di evento** |
| booking (noun) | **prenotazione** |
| to book | **prenotare** |
| **slot / time slot** | **fascia oraria** (never `slot`, never `slot orario`, never `spazio in agenda`) |
| **organiser / organizer** | **organizzatore** |
| **host** (the person) | **organizzatore** — Italian collapses the two English roles into one; never leave `host` in the msgstr |
| host page (the page an iframe is embedded in) | **pagina host** — technical, unrelated to the role above |
| attendee | **partecipante** |
| guest | **ospite** / **ospiti** |
| invitee | **invitato** |
| availability | **disponibilità** |
| **buffer** | **margine** (never `buffer`, never `tempo di buffer`) |
| minimum notice | **preavviso minimo** |
| calendar | **calendario** |
| to schedule (verb) | **fissare** / **pianificare** |
| scheduling (noun) | **pianificazione** |
| **Schedule a Meeting** (nav CTA) | **Fissa una riunione** |
| reschedule (verb) | **riprogrammare** |
| cancel a meeting | **annullare** |
| cancel / dismiss a dialog | **Annulla** |
| confirm / confirmation | **confermare** / **conferma** |
| timezone | **fuso orario** |
| duration | **durata** |
| recurring | **ricorrente** |
| theme (Quill/Rhythm booking theme) | **tema** (Quill/Rhythm stay verbatim) |
| event (a calendar event) | **evento** |
| **booking page / scheduling page** | **pagina di prenotazione** — one term for both English phrasings; never `pagina di pianificazione` |
| **dashboard** | **Dashboard** (loanword; lowercase `dashboard` mid-sentence, matching the English msgid's case). Never `pannello di controllo` |
| settings | **impostazioni** |
| profile | **profilo** |
| account | **account** |
| log in / sign in (verb) | **accedere** — `Accedi` |
| sign up (verb) | **registrarsi** — `Registrati` |
| password | **password** |
| user | **utente** / **utenti** |
| admin / administrator | **amministratore**; `Amministrazione` for the section |
| workflow | **workflow** (loanword) |
| automation | **automazione** |
| integration | **integrazione** / **integrazioni** |
| webhook | **webhook** (loanword) |
| **Enabled / Disabled** | **Attivato / Disattivato** — verbs `attivare` / `disattivare`. Never `abilitare` / `disabilitare`, not even for `JavaScript disattivato` |
| subscription | **abbonamento** |
| plan (pricing tier) | **piano** |
| billing | **fatturazione** |
| refund | **rimborso** / **rimborsare** |
| payment | **pagamento** |
| **Meeting payments** | **Pagamenti delle riunioni** |
| video call | **videochiamata** |
| location | **luogo** |
| reminder | **promemoria** |
| **Privacy Policy** | **Informativa sulla privacy** (never `Norme sulla privacy`) |
| Terms of Service | **Termini di servizio** |

### The connect family

One verb stem across calendars, video providers, chat integrations and Stripe. The noun is a different word and that is deliberate.

| English | Italian |
|---|---|
| **connect** (verb) | **collegare** — `Collega`, `Collegane uno` |
| **reconnect** | **ricollegare** — `Ricollega` |
| **disconnect** | **scollegare** — `Scollega` |
| **connected** (adj) | **collegato** |
| **disconnected** (adj) | **scollegato** |
| connection (the noun: state, test, count) | **connessione** — `Problemi di connessione`, `Prova la connessione`, `1 connessione calendario` |

Never `Connetti` / `Riconnetti` / `Disconnetti` / `connesso`. (`Disconnessione` remains correct for **logging out**, a different concept.)

### The embed family

One term, in Core and in marketing alike. Do not fall back on the English loanword.

| English | Italian |
|---|---|
| to embed | **incorporare** |
| embedded | **incorporato** |
| **embed / embedding / embeds** (noun) | **incorporamento** / **incorporamenti** — never bare `embed` |
| **Embed & Share** | **Incorpora e condividi** (all four call sites) |
| **Floating Button** | **Pulsante fluttuante** — `flottante` is a Gallicism and is wrong |
| Inline Embed | **Incorporamento inline** |
| Website Embed | **Incorporamento nel sito web** |
| popup modal | **modale popup** |

`data-theme`, `data-primary-color`, `data-locale`, `data-embed-mode` and every other attribute name stay verbatim.

### Extended termbase

Settled while translating; reuse rather than re-coining.

| English | Italian |
|---|---|
| **Tymeslot Core** / *Tymeslot's core* / *the core* (the product) | **Core** — a product name. `Il Core di Tymeslot`, `il Core è open source`. **Never `il nucleo`.** |
| self-hosting / to self-host / self-hosted | **self-hosting** / **ospitare in autonomia** / **self-hosted** |
| open source | **open source** |
| closed SaaS | **SaaS chiuso** |
| managed cloud | **cloud gestito** |
| data residency | **residenza dei dati** |
| data ownership | **proprietà dei dati** |
| free/busy | **libero/occupato** |
| double bookings | **doppie prenotazioni** |
| two-way sync | **sincronizzazione bidirezionale** |
| first-class (provider, citizen) | **di primo livello** |
| Healthy (status badge) | **Funzionante** |
| flat pricing | **prezzo fisso** |
| per-seat | **per postazione** |
| lock-in | **lock-in** |
| **Easiest** (badge) | **Il più semplice** |
| **Live Preview** | **Anteprima in tempo reale** (never `Anteprima dal vivo`) |
| **Wk** (calendar column header) | **Sett** — no full stop |
| gradient / preset | **gradiente** / **preset** |
| booking link | **link di prenotazione** |
| advance booking window | **finestra di prenotazione** |
| analytics | **statistiche** |
| conversion / visits / unique visitors | **conversione** / **visite** / **visitatori unici** |
| **therapists** | **terapeuti** — never `terapisti`. (`fisioterapisti`, `massaggiatori` are the correct specific roles and stay.) |
| in-person (location) | **di persona** |
| unlisted | **Non elencato** |
| Pending / Declined / Cancelled | **In attesa** / **Rifiutato** / **Annullato** |

**Weekday abbreviations:** Lun · Mar · Mer · Gio · Ven · Sab · Dom

**Common UI labels:** Save→Salva · Cancel→Annulla · Continue→Continua · Back→Indietro · Next→Avanti · Close→Chiudi · Delete→Elimina · Edit→Modifica · Add→Aggiungi · Skip→Salta · Done→Fatto · Confirm→Conferma · Copy→Copia · Required→Obbligatorio · Custom→Personalizzato · Free→Gratis.

### Sample and placeholder values

- **Localise prose-shaped samples**: `Jane Smith` → an Italian name (`Mario Rossi`), `yourname` → `tuonome`.
- **Keep format-shaped samples verbatim**: email addresses, URLs, hosts and API keys. Example addresses always use **`example.com`**, the RFC-reserved domain: `tua.email@example.com`, `admin@example.com`. Never `esempio.it` or `esempio.com`.

---

## 3. DO NOT TRANSLATE — keep verbatim

**Tymeslot** and **Tymeslot Core** (and the bare product name **Core**), Stripe, Stripe Checkout, Stripe Connect, reCAPTCHA, Google, Google Calendar, Google Meet, GitHub, Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail, Zimbra, Radicale, mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript, OAuth, OIDC, SSO, Oban, UTM, Cloudron. Plan names (Cloud Free, Cloud Pro, Self-Hosted) and theme names (Quill, Rhythm) likewise.

Loanwords kept as-is: Dashboard, password, account, webhook, workflow, slug, preset, popup, inline, self-hosting, open source, cloud, lock-in, embed **only inside attribute names**.

**Environment-variable and config names verbatim**, always: `REGISTRATION_ENABLED`, `PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`, `OAUTH_*`, `ADMIN_ALERT_EMAIL`, etc.

---

## 4. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` — the hard rule:**

- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr must have exactly those three.
- You **may and should reorder** them to fit Italian syntax.
- Watch what the placeholder *interpolates*. `%{organizer}` already expands to `con Mario Rossi`, so the msgstr must not add a second `con`. `%{advance}` already expands to `90 giorni di anticipo`, so the msgstr must not prefix it with `con`.
- A build gate checks this. A dropped or invented placeholder is a runtime crash.

**Markup / entities:** keep verbatim inside the msgstr. `<strong>removed from your external calendar</strong>` → `<strong>rimossa dal tuo calendario esterno</strong>`. `&` stays literal (not `&amp;`). Bullets `•`, checkmarks `✓` and emoji are preserved.

**Typography — use these characters:**

- Italian quotes **`«…»`** (caporali), no inner spaces: `La riunione «%{title}» è stata eliminata`.
- Em dash **`—`** for parenthetical asides, mirroring the English em dash.
- Ellipsis: **mirror the source**. If the msgid ends in `...`, the msgstr ends in `...`; if it ends in `…`, use `…`.
- Decimal comma: `0.0 and 1.0` → `0,0 e 1,0`. Currency sign follows the number with a space: `0 €`.
- **Elision before a vowel**: `un'email`, `un'ora`, `l'organizzatore`, `dell'account`, `l'incorporamento`. Note `un'altra riunione` (feminine, elided) but `un altro tipo` (masculine, no apostrophe).
- **`lo` before s + consonant, z, gn, ps**: `lo share-alike`, `lo strumento`, `lo snippet`. Never `il share-alike`.
- **Euphonic `ed`** before a word starting with `e`: `ed elimina`, `ed è`.
- Email is **`email`**, never `e-mail`, in every case and position.

---

## 5. PLURALS

Italian is `nplurals=2; plural=(n != 1);`.

`msgstr[0]` = singular (n == 1). `msgstr[1]` = everything else, **including 0**. Both must be filled, and any placeholder present in a form must appear in that form.

```
msgid "hour"
msgid_plural "hours"
msgstr[0] "ora"
msgstr[1] "ore"
```

Invariable loanwords (byte, link, webhook, slug) keep the same form in both slots. That is correct, not a defect.

Do not silently change number: if the English says "the attendee is notified", the Italian says `il partecipante riceverà una notifica`, singular.

---

## 6. TONE BY REGISTER

- **Marketing** — warm, direct, confident. Rephrase idioms rather than calquing them: a "noisy neighbour" in a cloud-tenancy sentence is `il carico di un altro cliente`, not `un vicino rumoroso`. Headlines should land as headlines. Keep the `tu`, and let the sentences breathe.
- **Dashboard / admin UI** — terse and functional. Buttons are imperatives (`Salva`, `Promuovi`) or nouns. Toggle states are adjectives (`Attivato` / `Disattivato`). System feedback is clean declarative: `Impossibile aggiornare l'impostazione.` No filler, no exclamation marks except on genuine success.
- **Transactional email** — polite, clear, human. Greeting `Ciao %{name},`. Warm first-person prose from the host is where `incontro` lives. Apologies are courteous: `Mi scuso per l'eventuale disagio.`
- **Booking flow (public)** — friendly and encouraging. Prompts guide the invitee: `Scegli una data per vedere gli orari disponibili`. Success is upbeat: `Riunione confermata!`

---

## 7. ONE-LINE SUMMARY

Informal **tu** + imperative. **riunione** (the meeting) · **incontro** (only "our meeting" in warm prose) · **appuntamento** (only English *appointment*) · **tipo di riunione** vs **tipo di evento** · **fascia oraria** · **organizzatore** · **partecipante** · **ospite** · **collegare/ricollegare/scollegare** · **incorporamento** · **margine** · **pagina di prenotazione** · **Informativa sulla privacy** · **Attivato/Disattivato** · **email** (no hyphen). Keep **Tymeslot / Core / brand names / env vars / `%{…}`** verbatim. Use `«…»`, `—`, decimal comma, `example.com`. Never drop or invent a placeholder.
