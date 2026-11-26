# Tymeslot: Italian (it) Translation Style Guide & Termbase

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
| **host** (the person) | **organizzatore**: Italian collapses the two English roles into one; never leave `host` in the msgstr |
| host page (the page an iframe is embedded in) | **pagina host**: technical, unrelated to the role above |
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
| **booking page / scheduling page** | **pagina di prenotazione**: one term for both English phrasings; never `pagina di pianificazione` |
| **dashboard** | **Dashboard** (loanword; lowercase `dashboard` mid-sentence, matching the English msgid's case). Never `pannello di controllo` |
| settings | **impostazioni** |
| profile | **profilo** |
| account | **account** |
| log in / sign in (verb) | **accedere**: `Accedi` |
| sign up (verb) | **registrarsi**: `Registrati` |
| password | **password** |
| user | **utente** / **utenti** |
| admin / administrator | **amministratore**; `Amministrazione` for the section |
| workflow | **workflow** (loanword) |
| automation | **automazione** |
| integration | **integrazione** / **integrazioni** |
| webhook | **webhook** (loanword) |
| **Enabled / Disabled** | **Attivato / Disattivato**: verbs `attivare` / `disattivare`. Never `abilitare` / `disabilitare`, not even for `JavaScript disattivato` |
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
| **connect** (verb) | **collegare**: `Collega`, `Collegane uno` |
| **reconnect** | **ricollegare**: `Ricollega` |
| **disconnect** | **scollegare**: `Scollega` |
| **connected** (adj) | **collegato** |
| **disconnected** (adj) | **scollegato** |
| connection (the noun: state, test, count) | **connessione**: `Problemi di connessione`, `Prova la connessione`, `1 connessione calendario` |

Never `Connetti` / `Riconnetti` / `Disconnetti` / `connesso`. (`Disconnessione` remains correct for **logging out**, a different concept.)

### The embed family

One term, in Core and in marketing alike. Do not fall back on the English loanword.

| English | Italian |
|---|---|
| to embed | **incorporare** |
| embedded | **incorporato** |
| **embed / embedding / embeds** (noun) | **incorporamento** / **incorporamenti**: never bare `embed` |
| **Embed & Share** | **Incorpora e condividi** (all four call sites) |
| **Floating Button** | **Pulsante fluttuante**: `flottante` is a Gallicism and is wrong |
| Inline Embed | **Incorporamento inline** |
| Website Embed | **Incorporamento nel sito web** |
| popup modal | **modale popup** |

`data-theme`, `data-primary-color`, `data-locale`, `data-embed-mode` and every other attribute name stay verbatim.

### Booking series

A **series** is several sessions of one meeting type that a booker books with a host in one go; each **session** is one meeting of that series. The terms below are the ones `emails_booking_series` uses; keep them in every series string.

| English | Italian |
|---|---|
| session (one meeting within a booking series) | **sessione** (`Sessione %{position} di %{count}`, `Gestisci tutte le sessioni`); feminine, so eyebrows agree: `Confermate`, `Annullate`. Not `riunione` for one session of a series |
| series (a booking series) | **serie** (`Nuova serie`) |

### Extended termbase

Settled while translating; reuse rather than re-coining.

| English | Italian |
|---|---|
| **Tymeslot Core** / *Tymeslot's core* / *the core* (the product) | **Core**: a product name. `Il Core di Tymeslot`, `il Core è open source`. **Never `il nucleo`.** |
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
| **schedule** (an availability schedule: hours, buffer, notice, booking window) | **pianificazione**, matching the dashboard. Feminine: `una pianificazione propria`, `nella tua pianificazione`, `pianificazioni separate`. Never `programma di disponibilità`. The dashboard label `Weekly Schedule` (the weekly hours grid) stays `Programma settimanale` |
| **custom booking questions / intake questions** (the Pro feature) | **domande di raccolta dati**; `Custom booking questions` → `Domande di raccolta dati personalizzate`. When naming the feature, never `domande di prenotazione`, `domande di accoglienza`, `domande iniziali` or bare `domande personalizzate`. Plain wording is fine where the sentence is not naming the feature (an FAQ question, a competitor's own feature) |
| managed service (Tymeslot Cloud) | **servizio gestito** |
| payout (money reaching the organiser) | `l'incasso arriva sul tuo account Stripe` |
| platform fee | **commissione della piattaforma** |
| deposit | **acconto** |
| payments at booking | **pagamenti alla prenotazione** |
| group bookings | **prenotazioni di gruppo** |
| discovery call | **chiamata conoscitiva** |
| time off | **periodi di assenza** |
| daily / weekly limits | **limiti giornalieri** / **limiti settimanali** |
| slot interval ("15-minute intervals") | phrase it as start times: `fasce orarie ogni 15 minuti` |
| approval request expires (left unanswered) | **decadere**: `le richieste senza risposta decadono` |
| approval email buttons (Approve / Decline) | **Conferma** / **Rifiuta** |
| **Wk** (calendar column header) | **Sett**: no full stop |
| gradient / preset | **gradiente** / **preset** |
| booking link | **link di prenotazione** |
| **link** (the username field in the setup wizard: the part of the booking URL the host chooses) | **link** (masculine, invariable): `Il tuo link`, `Questo link è già di qualcun altro` |
| **keep** (your link: save it somewhere you'll find it again) | **salvare**: `Oppure salvalo per dopo`, `Prima invia o salva il tuo link`. Never `tenere` |
| **app-specific password** (Apple's term) | Apple's own Italian UI: **password specifica per l'app**, the Apple Account menu item **Password specifiche per le app**, the section **Accesso e sicurezza**, and **Account Apple** (capital A, as Apple writes it). `Apple ID` stays **ID Apple** where the source says Apple ID |
| **Live** (the setup step name and the page-status badge) / *goes live* | **Online** / **andare online**: `Quasi online`, `La tua pagina non è ancora online`. Not `Live`, not `Attivo` |
| **Book a time with me** / *pick a time with me* (the host's own share and signature line) | **Fissa un appuntamento con me** (the `fissare un appuntamento` idiom) |
| **booking horizon / advance booking window** | **finestra di prenotazione**: the dashboard term, used on every marketing and profession page too |
| **analytics** (our booking analytics feature) | **statistiche** (`statistiche sulle prenotazioni`); never `analytics` for our own feature |
| third-party analytics / tracking | **strumenti di analisi di terze parti** (product names such as Google Analytics stay verbatim) |
| conversion / visits / unique visitors | **conversione** / **visite** / **visitatori unici** |
| **therapists** | **terapeuti**: never `terapisti`. (`fisioterapisti`, `massaggiatori` are the correct specific roles and stay.) |
| in-person (location) | **di persona** |
| unlisted | **Non elencato** |
| Pending / Declined / Cancelled | **In attesa** / **Rifiutato** / **Annullato** |
| **bookable times** / **bookable** (the hatched layer on the organiser's calendar) | **orari prenotabili** / **prenotabile**: never `disponibile` or `libero` |
| **Layers** (calendar rail heading) | **Livelli** |
| **Open for booking** (opening extra time for a meeting type) | **Apri alle prenotazioni**; the resulting state and toasts: `Prenotazioni aperte per %{name} …` |
| Just this once / Every week (open-for-booking repeat) | **Solo questa volta** / **Ogni settimana** |
| **Treat as** Busy / Free (local override on a read-only all-day event) | **Considera come** Occupato / Libero; `Considerato occupato per le prenotazioni` |
| **Block this time** / Blocked | **Blocca questo orario** / **Bloccato**; `Orario sbloccato` for Unblocked |
| **Copy free times** | **Copia gli orari liberi** |
| put back (bookable times, undo) | **ripristinare** |
| booking request (calendar pill) / Expired (pill) | **Richiesta** / **Scaduta**; `decaduta senza risposta` for "expired without an answer" |
| Accept (a booking request) | **Accetta**, matching `dashboard_bookings` |
| **tell guests** (notify guests of a change to an event) | **avvisare gli ospiti**: `Avvisa gli ospiti`, `Elimina e avvisa gli ospiti`, `Impossibile avvisare gli ospiti. Le modifiche sono salvate.` The message they get is **un aggiornamento** (`Gli ospiti riceveranno un aggiornamento.`); a held update that can still be cancelled is **in attesa di invio**. Never `informare` or `notificare` for this action |
| **Tymeslot meeting** (a booked meeting sent from the calendar, with guests) | **riunione Tymeslot** (no article between, no hyphen): `Invia come riunione Tymeslot`, `inviare una riunione Tymeslot`. A plain calendar entry stays **evento**; never call a Tymeslot meeting an `evento`, nor a plain event a `riunione` |
| **Syncing** (a calendar write the provider has not confirmed yet) | **Sincronizzazione in corso**; in a sentence `Sincronizzazione con il tuo calendario in corso`. Never `In sincronizzazione` or `Sincronizzando` |
| **Preview** (plain, the pair of Live Preview) | **Anteprima**; compounds take `di`/`del`: `Anteprima del tema`, `Anteprima della prenotazione`, `Modalità anteprima`. **Live Preview** is `Anteprima in tempo reale` (see above) |
| translation (noun; booking-page languages) | **traduzione** (f., pl. **traduzioni**); *%{language} translations* → **Traduzioni: %{language}**, *Your %{language} translations* → **Le tue traduzioni (%{language})**: `%{language}` is filled with the language's own name, so it goes after a colon or in brackets, never after an article or *in* |
| translate | **tradurre**; the participle agrees with *testi* (*%{translated}/%{total} tradotti*) |
| original language (the language the host writes their texts in) | **lingua originale**; *in %{language}* → **nella lingua originale (%{language})**; the original text is **l'originale** (*nella versione originale*), and the badge beside that language reads **originale** |
| translation language (a language the host translates into) | **lingua di traduzione** (pl. **lingue di traduzione**) |
| language switcher (the visitor-facing control on the booking page) | **selettore della lingua** |
| Outdated (a translation whose original changed) | **Da aggiornare** (invariable: *%{count} da aggiornare*, *sono da aggiornare*) |
| Missing (a text not translated yet) | **Mancante** (pl. **mancanti**) |
| Translated (status) | **Tradotto** |
| Review (the link to a language's review page) | **Controlla** |

**Weekday abbreviations:** Lun · Mar · Mer · Gio · Ven · Sab · Dom

**Common UI labels:** Save→Salva · Cancel→Annulla · Continue→Continua · Back→Indietro · Next→Avanti · Close→Chiudi · Delete→Elimina · Edit→Modifica · Add→Aggiungi · Skip→Salta · Done→Fatto · Confirm→Conferma · Copy→Copia · Required→Obbligatorio · Custom→Personalizzato · Free→Gratis.

### Sample and placeholder values

- **Localise prose-shaped samples**: `Jane Smith` → an Italian name (`Mario Rossi`), `yourname` → `tuonome`.
- **Keep format-shaped samples verbatim**: email addresses, URLs, hosts and API keys. Example addresses always use **`example.com`**, the RFC-reserved domain: `tua.email@example.com`, `admin@example.com`. Never `esempio.it` or `esempio.com`.

---

## 3. DO NOT TRANSLATE: keep verbatim

**Tymeslot** and **Tymeslot Core** (and the bare product name **Core**), Stripe, Stripe Checkout, Stripe Connect, reCAPTCHA, Google, Google Calendar, Google Meet, GitHub, Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail, Zimbra, Radicale, mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript, OAuth, OIDC, SSO, Oban, UTM, Cloudron. Plan names (Cloud Free, Cloud Pro, Self-Hosted) and theme names (Quill, Rhythm) likewise.

Loanwords kept as-is: Dashboard, password, account, webhook, workflow, slug, preset, popup, inline, self-hosting, open source, cloud, lock-in, embed **only inside attribute names**.

**Environment-variable and config names verbatim**, always: `REGISTRATION_ENABLED`, `PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`, `OAUTH_*`, `ADMIN_ALERT_EMAIL`, etc.

---

## 4. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` (the hard rule):**

- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr must have exactly those three.
- You **may and should reorder** them to fit Italian syntax.
- Watch what the placeholder *interpolates*. `%{organizer}` already expands to `con Mario Rossi`, so the msgstr must not add a second `con`. `%{advance}` already expands to `90 giorni di anticipo`, so the msgstr must not prefix it with `con`.
- A build gate checks this. A dropped or invented placeholder is a runtime crash.
- **`%{profession_in_text}`** (profession pages) expands to a lowercase plural with no article: `dentisti`, `consulenti IT`, `istruttori di Pilates`, `coach`. Build the sentence so a bare plural works, typically after `per`: `Tutto il necessario per %{profession_in_text}.`, `Privacy e conformità per %{profession_in_text}`. Avoid structures that need an article or an articulated preposition (`ai`, `agli`, `alle`), and do not fall back on `%{profession}: …` colon headings. `%{profession}` is the capitalised form for titles and labels.
- **A date placeholder named for its preposition** already starts with the article, which the code chooses by the day ("il 9 ottobre" but "l'8 ottobre", "dal 9" but "dall'11"), so the msgstr writes no article before it. `%{on_date}`, `%{for_date}`, `%{by_deadline}`, `%{on_deadline}` receive `il`/`l'`: `Si rinnova %{on_date}`, `entro %{by_deadline}`, `programmata per %{for_date}`. `%{until_date}`, `%{until_datetime}`, `%{to_date}` and the import dialogue's `%{before_date}` receive `al`/`all'`: `fino %{until_date}`, `precedente %{before_date}`. `%{from_date}` receives `dal`/`dall'`: `%{from_date} in poi`. The SaaS trial email's `%{before_date}` and the booking page's "Moving your spot on %{on_datetime}" and the comparison page's "Tested on %{on_date}" receive `del`/`dell'`: `prima %{before_date}`, `il tuo posto %{on_datetime}`, `Test %{on_date}`. Build the sentence around the article you receive; if it needs a different one, the code has to change, so flag it rather than rewording around it. The value is lowercase, so it may start a msgstr only in "From %{from_date}", "%{from_date} onwards" and "On %{on_date}.", whose result the code capitalises.
- A link label interpolated mid-sentence (`%{docker_guide}`, `%{embed_guide}`) is lowercase, because it is translated as its own msgid: `la %{docker_guide}` → `la guida alla configurazione Docker`.

**Markup / entities:** keep verbatim inside the msgstr. `<strong>removed from your external calendar</strong>` → `<strong>rimossa dal tuo calendario esterno</strong>`. `&` stays literal (not `&amp;`). Bullets `•`, checkmarks `✓` and emoji are preserved.

**Typography (use these characters):**

- Italian quotes **`«…»`** (caporali), no inner spaces: `La riunione «%{title}» è stata eliminata`.
- **No em dashes.** Where the English has an em dash, use a comma, a colon, parentheses or a full stop instead, whichever reads most naturally in Italian.
- Ellipsis: **mirror the source**. If the msgid ends in `...`, the msgstr ends in `...`; if it ends in `…`, use `…`.
- Decimal comma: `0.0 and 1.0` → `0,0 e 1,0`. Currency sign follows the number with a space: `0 €`, and dollar prices the same way: `16 $`, `16 $/mese`. Percentages take the decimal comma and no space: `0,5%`.
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

- **Marketing**: warm, direct, confident. Rephrase idioms rather than calquing them: a "noisy neighbour" in a cloud-tenancy sentence is `il carico di un altro cliente`, not `un vicino rumoroso`. Headlines should land as headlines. Keep the `tu`, and let the sentences breathe.
- **Dashboard / admin UI**: terse and functional. Buttons are imperatives (`Salva`, `Promuovi`) or nouns. Toggle states are adjectives (`Attivato` / `Disattivato`). System feedback is clean declarative: `Impossibile aggiornare l'impostazione.` No filler, no exclamation marks except on genuine success.
- **Transactional email**: polite, clear, human. Greeting `Ciao %{name},`. Warm first-person prose from the host is where `incontro` lives. Apologies are courteous: `Mi scuso per l'eventuale disagio.`
- **Booking flow (public)**: friendly and encouraging. Prompts guide the invitee: `Scegli una data per vedere gli orari disponibili`. Success is upbeat: `Riunione confermata!`

---

## 7. ONE-LINE SUMMARY

Informal **tu** + imperative. **riunione** (the meeting) · **incontro** (only "our meeting" in warm prose) · **appuntamento** (only English *appointment*) · **tipo di riunione** vs **tipo di evento** · **fascia oraria** · **organizzatore** · **partecipante** · **ospite** · **collegare/ricollegare/scollegare** · **incorporamento** · **margine** · **pagina di prenotazione** · **Informativa sulla privacy** · **Attivato/Disattivato** · **email** (no hyphen). Keep **Tymeslot / Core / brand names / env vars / `%{…}`** verbatim. Use `«…»`, decimal comma, `16 $`, `example.com`, and no em dashes. Never drop or invent a placeholder.
