# Tymeslot — Czech (cs) Translation Style Guide & Termbase

Authoritative. Written ahead of the first Czech catalogue, from the ~4,000 source msgids across Core and the SaaS overlay, and modelled on the settled German and Ukrainian termbases. Follow this exactly. Where a translator's instinct contradicts this guide, **this guide wins** — consistency across twenty translators is worth more than any individual improvement.

The guiding principle behind every call below: **prefer standard Czech over a transliterated Anglicism.** A loanword is kept only where it is genuinely naturalised and declines like a Czech noun (`webhook`, `widget`, `tarif`, `integrace`), never merely because the English word was convenient to respell.

---

## 1. REGISTER

**Formal `vy` / `váš` everywhere.** Booking flow, e-mails, dashboard, admin, marketing. No exceptions. Never `ty`.

Write the polite pronoun **lowercase** — `vy`, `váš`, `vám`, `vás` — not `Vy`. Capitalised `Vy` belongs to personal correspondence addressed to one named individual; our strings address an unknown reader. This applies to transactional e-mail too, even though e-mail is where translators most often reach for the capital.

### Gender agreement is the hardest problem in this catalogue

Czech past participles and predicate adjectives agree with the subject in gender and number. The subject of most of our strings is *the user*, whose gender we do not know. `Byl jste přihlášen` is masculine and wrong for half our users; `Byl(a) jste přihlášen(a)` is unreadable. **Restructure instead.** Three sanctioned constructions, in order of preference:

1. **Make the object the subject.** The object's gender is known because it is one of our own terms: `Meeting cancelled successfully` → **`Schůzka byla zrušena.`** (schůzka is feminine, so `zrušena` is determinate).
2. **Use the verbal noun or the impersonal `nepodařilo se`.** `Failed to save meeting to database` → **`Schůzku se nepodařilo uložit do databáze.`** `Upload failed` → **`Nahrání se nezdařilo.`** Nothing agrees with the user here.
3. **Stay in the present tense or the infinitive**, which carry no gender: `You don't have any cancelled appointments to show.` → **`Nemáte žádné zrušené schůzky.`**

Never address one user with a masculine plural predicate. `Are you sure you want to…?` is **`Opravdu chcete…?`**, never `Jste si jisti, že…` — `jisti` forces a gender and a number that the string cannot know.

**Escape hatch, last resort:** the bracketed form `přihlášen(a)`. Permitted only in dense admin or legal text where no restructuring works. Never in marketing, the booking flow, or e-mail. Never the slash form `přihlášen/a`.

### Imperatives vs infinitives

**Buttons, menu commands, and link labels take the infinitive:** `Uložit`, `Zrušit`, `Smazat`, `Odeslat`, `Pokračovat`, `Zavřít`, `Odpojit`. This is the Czech convention in every major localised product (Microsoft, Apple, Google), it is the shortest form, and — decisively for us — the infinitive carries no gender or number, so it never collides with §1's agreement problem.

**Instructions, prompts, and helper text take the 2nd-person-plural imperative:** `Vyberte datum`, `Zadejte e-mailovou adresu`, `Připojte kalendář`, `Potvrďte svou účast`. The dividing line is whether the string *is* the control (infinitive) or *tells the user to operate* a control (imperative).

---

## 2. GLOSSARY

Genitive singular and genitive plural are given wherever a translator will need them — after numerals, after prepositions, and inside compounds. `m.a.` = masculine animate, `m.i.` = masculine inanimate, `f.` = feminine, `n.` = neuter.

### Core nouns

| English | Czech | Gender | Gen. sg. | Nom. pl. | Gen. pl. |
|---|---|---|---|---|---|
| booking (noun) | **rezervace** | f. | rezervace | rezervace | rezervací |
| meeting | **schůzka** | f. | schůzky | schůzky | schůzek |
| appointment | **schůzka** — the same word; Czech does not split them | f. | schůzky | schůzky | schůzek |
| event (calendar event) | **událost** — never conflate with *schůzka* | f. | události | události | událostí |
| slot / time slot | **termín** **[DECIDED]** — the bookable unit of time | m.i. | termínu | termíny | termínů |
| availability | **dostupnost** | f. | dostupnosti | — | — |
| schedule (the weekly availability) | **rozvrh** | m.i. | rozvrhu | rozvrhy | rozvrhů |
| scheduling (the activity) | **plánování** | n. | plánování | — | — |
| calendar | **kalendář** | m.i. | kalendáře | kalendáře | kalendářů |
| time zone | **časové pásmo** **[DECIDED]** — never *časová zóna* | n. | časového pásma | časová pásma | časových pásem |
| host (the person being booked) | **hostitel** | m.a. | hostitele | hostitelé | hostitelů |
| organiser | **organizátor** — a distinct role from *hostitel*; keep them distinct | m.a. | organizátora | organizátoři | organizátorů |
| attendee | **účastník** | m.a. | účastníka | účastníci | účastníků |
| guest | **host** — note the trap: English *host* is Czech **hostitel**, English *guest* is Czech **host** | m.a. | hosta | hosté | hostů |
| invitee | **pozvaný** where it means an invited person, **host** where it means guest | m.a. (adj. decl.) | pozvaného | pozvaní | pozvaných |
| buffer | **časová rezerva** **[DECIDED]** — always both words, so it can never be misread as *rezervace* | f. | časové rezervy | časové rezervy | časových rezerv |
| minimum notice | **minimální předstih** | m.i. | předstihu | — | — |
| advance booking window | **období pro rezervace** | n. | období | — | — |
| reminder | **připomínka** | f. | připomínky | připomínky | připomínek |
| confirmation | **potvrzení** | n. | potvrzení | potvrzení | potvrzení |
| cancellation | **zrušení** | n. | zrušení | — | — |
| reschedule (noun) | **přesunutí**; *reschedule request* → **žádost o přesunutí** | n. | přesunutí | — | — |
| no-show | **neúčast** | f. | neúčasti | — | — |
| deposit | **záloha** | f. | zálohy | zálohy | záloh |
| payment | **platba** | f. | platby | platby | plateb |
| refund | **vrácení platby**; *Refunded* → **Vráceno** | n. | vrácení | — | — |
| subscription | **předplatné** — adjectival declension: gen. **předplatného**, dat. předplatnému | n. | předplatného | — | — |
| plan (pricing tier) | **tarif** | m.i. | tarifu | tarify | tarifů |
| trial | **zkušební období** | n. | zkušebního období | — | — |
| workspace | **pracovní prostor** | m.i. | pracovního prostoru | — | — |
| profile | **profil** | m.i. | profilu | profily | profilů |
| dashboard | **nástěnka** **[DECIDED]** — never Latin *dashboard*; *Overview* is **Přehled**, a separate nav item | f. | nástěnky | nástěnky | nástěnek |
| settings | **nastavení** | n. | nastavení | nastavení | nastavení |
| integration | **integrace** | f. | integrace | integrace | integrací |
| embed (the artefact) | **widget**; *to embed* → **vložit**, *embedding* → **vkládání** | m.i. | widgetu | widgety | widgetů |
| webhook | **webhook** — naturalised, declines | m.i. | webhooku | webhooky | webhooků |
| theme (Quill/Rhythm) | **motiv** **[DECIDED]** — never *téma*, never *theme*; Quill/Rhythm stay verbatim | m.i. | motivu | motivy | motivů |
| custom field | **vlastní pole** | n. | vlastního pole | vlastní pole | vlastních polí |
| custom question | **vlastní otázka** | f. | vlastní otázky | vlastní otázky | vlastních otázek |
| meeting type | **typ schůzky**; the nav label is **Typy schůzek** — note the genitive plural, `Typy schůzky` is the commonest error in this file | m.i. | typu schůzky | typy schůzek | typů schůzek |
| recurring | **opakující se** (adj., agrees: *opakující se schůzka / událost*) | — | — | — | — |
| one-off | **jednorázový** (adj.) | — | — | — | — |

### Extended termbase

| English | Czech |
|---|---|
| account | **účet** (m.i., gen. účtu) — never *akaunt* |
| user | **uživatel** (m.a., gen. uživatele, pl. uživatelé, gen. pl. uživatelů) |
| admin / administrator | **správce** (m.a., gen. správce) — *Admin Settings* → **Nastavení správce** |
| password | **heslo** (n., gen. hesla, gen. pl. hesel) |
| e-mail (the medium and the message) | **e-mail** — hyphenated, lowercase mid-sentence; *Email Address* → **E-mailová adresa** |
| sign in / log in | **přihlásit se**; noun **přihlášení** |
| sign up / register | **zaregistrovat se**; noun **registrace** |
| sign out / log out | **odhlásit se**; noun **odhlášení** |
| authentication | **ověření** — *two-factor authentication* → **dvoufázové ověření** |
| provider (calendar / video / OAuth) | **poskytovatel** (m.a.) — never *provider* |
| video call | **videohovor** (m.i., one word) |
| video meeting | **videoschůzka** (f., one word) |
| location | **místo** (n.); *In-person* → **Osobně** |
| duration | **délka** (f.) — never bare *trvání* |
| break (in the availability grid) | **přestávka** (f., gen. pl. přestávek) — kept distinct from *časová rezerva* |
| booking page / link / flow | **rezervační stránka** / **rezervační odkaz** / **průběh rezervace** |
| available times | **Volné termíny** |
| Available / Unavailable (a day or slot badge) | **K dispozici** / **Není k dispozici** — gender-neutral, so it is safe on *den*, *termín* and *schůzka* alike |
| Unlisted | **Neveřejné** |
| Default (badge / option label) | **Výchozí** |
| by default (adverbial) | **ve výchozím nastavení** |
| Custom (a user-defined value) | **vlastní** — never *kastomizovaný*, never Latin *custom* |
| Pending | **Čeká na vyřízení**; *Pending Stripe review* → **Čeká na kontrolu Stripe** |
| Failed (a status) | **Chyba** |
| Declined (a guest) | **Odmítnuto** — distinct from **Zrušeno** (a cancelled meeting) |
| logs / read-only | **protokoly** (never *logy*) / **jen pro čtení** |
| self-hosting / self-hosted | **provoz na vlastním serveru** / **na vlastním serveru** — never *self-hosted* inside a Czech sentence, never *selfhosting* |
| open source | **otevřený zdrojový kód** (noun) · **open-source** (attributive, hyphenated) |
| Free (as a price value or tier label) | **Zdarma**; *Everything in Free* → **Vše z tarifu Zdarma** |
| `+%{count} more` | **`+%{count} dalších`** in all three plural forms — the elided noun differs per surface (událost f., účastník m., kalendář m.), so no agreeing form is right everywhere; the invariant genitive plural is the convention |

### Verbs — always give the aspect the string needs

Czech verbs come in perfective/imperfective pairs. **Buttons and completed-action messages take the perfective; ongoing states and in-flight statuses take the imperfective or the verbal noun.** This is where Czech translators drift most.

| English | Perfective | Imperfective | In-flight status |
|---|---|---|---|
| to book | **zarezervovat** | rezervovat | Rezervuji… → use **Rezervace…** |
| to schedule | **naplánovat** | plánovat | Plánování… |
| to reschedule | **přesunout** | přesouvat | Přesouvání… |
| to cancel | **zrušit** | rušit | **Rušení…** (`Cancelling...`) |
| to confirm | **potvrdit** | potvrzovat | **Potvrzování…** (`Confirming your payment…`) |
| to save | **uložit** | ukládat | **Ukládání…** (`Saving...`) |
| to delete | **smazat** | mazat | Mazání… |
| to remove | **odebrat** — kept distinct from *smazat* | odebírat | — |
| to invite | **pozvat** | zvát | — |
| to connect | **připojit** | připojovat | **Připojování…** (`Connecting…`) |
| to disconnect | **odpojit** | odpojovat | — |
| to reconnect | **připojit znovu** — never *reconnectovat*, never *znovupřipojit* | — | — |
| to sync | **synchronizovat** (biaspectual) | — | **Synchronizace…** |
| to enable / disable | **zapnout** / **vypnout** | zapínat / vypínat | states are **Zapnuto** / **Vypnuto** (neuter, gender-neutral) |
| to upgrade (tier) | **přejít na vyšší tarif**; *Upgrade to Pro* → **Přejít na Pro** | — | — |
| to downgrade | **přejít na nižší tarif** | — | — |
| to upgrade (permissions) | **rozšířit oprávnění** — never *aktualizovat*, which is *update* | — | — |
| to refresh | **obnovit** | obnovovat | — |
| to update | **aktualizovat** (biaspectual) | — | **Aktualizace…** |
| to submit | **odeslat** | odesílat | **Odesílání…** (`Sending...`) |
| to process | **zpracovat** | zpracovávat | **Zpracování…** (`Processing...`) |
| to test | **otestovat** | testovat | **Testování…** (`Testing...`) |

### Weekdays and months

Weekday and month names are **lowercase in running prose** and capitalised only as standalone column headers or list labels.

- Weekdays: pondělí · úterý · středa · čtvrtek · pátek · sobota · neděle
- Abbreviations (grid headers): **Po · Út · St · Čt · Pá · So · Ne**; the all-caps source variants (`MON`) become **PO · ÚT · ST · ČT · PÁ · SO · NE**
- Months, nominative: leden · únor · březen · duben · květen · červen · červenec · srpen · září · říjen · listopad · prosinec
- Months **in a date, always genitive**: ledna · února · března · dubna · května · června · července · srpna · září · října · listopadu · prosince
- Month abbreviations: led · úno · bře · dub · kvě · čvn · čvc · srp · zář · říj · lis · pro

---

## 3. ANGLICISMS — BANNED

Each of these is the form a Czech developer reaches for first. None of them ships.

| Banned | Use instead |
|---|---|
| `meeting` | **schůzka** |
| `event` (Latin) | **událost** |
| `slot`, `časový slot` | **termín** |
| `buffer` | **časová rezerva** |
| `dashboard` | **nástěnka** |
| `časová zóna` | **časové pásmo** |
| `provider` | **poskytovatel** |
| `logy` | **protokoly** |
| `akaunt` | **účet** |
| `kastomizovat`, `customizovat` | **přizpůsobit** / **vlastní** |
| `upgradovat`, `downgradovat` | **přejít na vyšší / nižší tarif** |
| `updatovat` | **aktualizovat** |
| `nalinkovat`, `linkněte` | **propojit**, **odkaz** |
| `supportovat` | **podporovat** |
| `selfhosting`, Latin `self-hosted` mid-sentence | **provoz na vlastním serveru** |
| `zabookovat` | **zarezervovat** |
| `cancelnout` | **zrušit** |
| `téma` (as UI theme) | **motiv** — *téma* is a *topic* |

**Diacritics are mandatory** in every msgstr: `ě š č ř ž ý á í é ú ů ó ď ť ň`. The only exception is a sample value that is a URL slug (§5).

---

## 4. UI MICRO-COPY CONVENTIONS

**Headings and page titles are sentence case, not title case.** English source strings capitalise every word; Czech capitalises the first word and proper nouns only. This is the single most frequent Czech localisation defect, and it applies to nav items, buttons, tab labels, table headers, and modal titles alike.

| Surface | Convention | Worked example |
|---|---|---|
| Button label | Infinitive, sentence case, no full stop | `Cancel Meeting` → **`Zrušit schůzku`** · `Keep Meeting` → **`Ponechat schůzku`** · `Send Reschedule Request` → **`Odeslat žádost o přesunutí`** |
| Page / section title | Sentence-case noun phrase, no full stop | `Meeting Management` → **`Správa schůzek`** · `Account Settings` → **`Nastavení účtu`** · `Weekly Schedule` → **`Týdenní rozvrh`** |
| Form label | Bare sentence-case noun, no colon unless the msgid has one | `Email Address` → **`E-mailová adresa`** · `Start Time` → **`Začátek`** · `Display Name` → **`Zobrazované jméno`** |
| Placeholder text | Prose-shaped samples localised, format-shaped ones verbatim (§5) | `e.g. Lunch` → **`např. oběd`** · `e.g. John Doe` → **`např. Jan Novák`** · `your.email@example.com` → unchanged |
| Empty state | Full clause, plain declarative, no exclamation mark | `No upcoming meetings` → **`Žádné nadcházející schůzky`** · `You don't have any cancelled appointments to show.` → **`Nemáte žádné zrušené schůzky.`** |
| Error message | Impersonal `nepodařilo se`, full stop, no blame | `Failed to load meetings` → **`Schůzky se nepodařilo načíst.`** · `Something went wrong. Please try again.` → **`Došlo k chybě. Zkuste to prosím znovu.`** |
| Toast / flash | Passive with the object as subject, or a bare verbal noun | `Meeting cancelled successfully` → **`Schůzka byla zrušena.`** · `Booking link copied!` → **`Rezervační odkaz byl zkopírován.`** |
| Confirmation dialog | `Opravdu chcete…?` — the fixed rendering, never `Jste si jisti` | `Are you sure you want to cancel this appointment?` → **`Opravdu chcete tuto schůzku zrušit?`** |

**`Cancel` is two different words in one string set.** As a dialog dismiss it is **`Zrušit`**; as the destructive action on a meeting it is **`Zrušit schůzku`** — never a bare `Zrušit`, because the two appear side by side in the cancellation modal and would read identically. Check the msgid's `#:` reference before choosing. Where a bare dismiss sits next to `Keep Meeting`, use **`Zpět`**.

Ecto field errors are lowercase fragments appended to a field label of arbitrary gender, so **the predicate must not agree with anything**. Use verb-only or predicate-noun constructions:

| msgid | msgstr | why |
|---|---|---|
| `can't be blank` | **`je povinná položka`** | *položka* carries the agreement, not the field name |
| `is invalid` | **`má neplatnou hodnotu`** | the adjective agrees with *hodnota* |
| `has already been taken` | **`již existuje`** | verb only, no agreement |
| `does not match confirmation` | **`se neshoduje s potvrzením`** | verb only |
| `is reserved` | **`je vyhrazená hodnota`** | predicate noun |

---

## 5. DO NOT TRANSLATE — keep verbatim

**Tymeslot**, Stripe, Stripe Checkout, Stripe Connect, reCAPTCHA, Google, Google Calendar, Google Meet, GitHub, Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail, Zimbra, Radicale, mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript, OAuth, OIDC, SSO, Oban, UTM, Cloudron.

Also verbatim, established by the other termbases and applying equally here: Quill, Rhythm, Baikal, Docker, PostgreSQL, Railway, AGPLv3, WordPress, Apple Pay, Google Pay.

**Environment-variable and config names, always verbatim:** `REGISTRATION_ENABLED`, `PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`, `OAUTH_*`, and friends. Likewise embed attributes: `data-theme`, `data-primary-color`, `data-locale`.

**Czech-specific additions:**

- Tier names are proper nouns: `Pro`, `Cloud Free`, `Cloud Pro`, `Enterprise`, `Self-Hosted` as a pricing-card title. Bare `Free` as a price or tier value is translated → **`Zdarma`**.
- **Tymeslot never inflects and never takes a Czech ending.** Write `účet Tymeslot`, `nástěnka Tymeslot`, `ve službě Tymeslot` — never `Tymeslotu`, `Tymeslotem`, `Tymeslotový`. Where a case is unavoidable, front it with a declinable noun (`služba`, `účet`, `aplikace`).
- Unit symbols do not decline and are separated from the number by a non-breaking space: `30 min`, `24 h`, `10 MB`, `%{count} s`.

**Sample and placeholder values:** localise prose-shaped samples — `yourname` → **`vasejmeno`** (no diacritics; it is a URL slug), `John Doe` → **`Jan Novák`**, `e.g. Lunch` → **`např. oběd`**. Keep format-shaped ones verbatim: e-mail addresses (`your.email@example.com`, `guest@example.com`), URLs and hosts (`https://caldav.example.com`), API keys, and anything containing `example.com`. A Czech-diacritic API key or hostname is a bug.

### Third-party UI labels — never guess

When a setup instruction tells the user to click something inside another company's product, the label must match what that product actually shows in Czech. Invent one and the user hunts for a menu item that does not exist.

> **Open items — verify before shipping.** `dashboard_calendar_providers` references Apple's `Sign-In and Security → App-Specific Passwords` and mailbox.org's `Settings → Security`. The plausible Czech renderings are **`Přihlášení a zabezpečení → Hesla pro aplikace`** and **`Nastavení → Zabezpečení`**, but neither has been checked against the vendor's own Czech surface. Apple's web (`account.apple.com`) and its iOS/macOS Settings wording differ from each other, as the German termbase records. Confirm on Apple's Czech support pages before treating these as settled; mailbox.org has no Czech UI at all, so keep its English label and add a Czech gloss in parentheses.

---

## 6. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` — the hard rule:**

- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr must have exactly those three.
- You **may and should reorder** them to fit Czech syntax: `"%{month} %{day}, %{year}"` → `"%{day}. %{month} %{year}"`.
- A dropped or invented placeholder is a runtime crash, not a typo. A build gate checks this.

**Beware composition.** Several strings interpolate a *pre-formatted* fragment — `%{organizer}` already reads `with Jane`, `%{time_until}` already reads `in 30 minutes`, `%{advance}` already reads `90 days in advance`. Check what the call site produces before wrapping a preposition around `%{…}`; Czech case government makes stacked prepositions and case mismatches very easy to ship.

**Markup and entities pass through verbatim:** `<strong>…</strong>`, `&` (literal, not `&amp;`), bullets `•`, checkmarks `✓`, arrows `→`, emoji, `\n` paragraph separators.

**Typography — the defects reviewers will look for first:**

- **Quotation marks `„…“`** — low-9 opening `„` (U+201E), high-6 closing `“` (U+201C). Nested quotes use `‚…‘` (U+201A / U+2018). Never `"…"`.
- **Non-breaking space (U+00A0) after every single-letter preposition or conjunction** — `k`, `s`, `v`, `z`, `o`, `u`, `a`, `i`, and the vocalised forms `ke`, `se`, `ve`, `ze`, `ku`. `v kalendáři`, `s hostitelem`, `k dispozici` all carry a U+00A0. Also before a unit and inside a thousands group.
- **Numbers: `1 234,56`** — non-breaking (or narrow non-breaking) space as the thousands separator, **comma** as the decimal separator. Never `1,234.56`. `"0.0 and 1.0"` → `„0,0 a 1,0“`.
- **Dates: `15. 3. 2026`** — no leading zeros, a full stop after each number, and a non-breaking space after each full stop. The long form puts the month in the genitive and lowercase: `15. března 2026`.
- **Ordinals take a full stop:** `1.`, `2.`, `15.` A cardinal does not — `Step %{current} of %{total}` → `Krok %{current} z %{total}`.
- **24-hour clock: `14:30`.** Never `2:30 PM`. Time ranges use an unspaced en dash: `9:00–17:00`.
- **Currency is postfixed**, separated by a non-breaking space: `120 €`, `1 200 Kč`, `29 $`. Never `€120`. `/month` → `/měsíc`.
- **Percent:** a space when it is a standalone quantity (`50 %`, `Nahrávání… %{percent} %`), no space when it is attributive (`50% sleva`).
- **Dashes:** use the en dash **`–`** (U+2013) for numeric ranges (unspaced) and for parenthetical asides (space-padded). **Czech typography does not use the em dash** — where the English source has `—`, render it as a space-padded `–`. This is a deliberate divergence from the German and Ukrainian termbases, which mirror the em dash.
- **Ellipsis `…`** (U+2026), never `...`, and **no space before it**: `Načítání…`, `Ukládání…`.
- **No serial comma.** Czech never puts a comma before `a`, `i`, or `nebo` in a simple enumeration: `rezervace, platby a kalendáře`. (A comma *is* required before `a` when it joins clauses in an adversative or consecutive relation — `a proto`, `a to` — but never in a list.)
- **Abbreviations keep their full stops:** `např.`, `tj.`, `atd.`, `hod.`, `min.`, `mj.`

---

## 7. PLURALS — CZECH HAS THREE FORMS

```
nplurals=3; plural=(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2;
```

This line is written into every `cs/LC_MESSAGES/*.po` header by gettext. **Do not edit the header.** Every plural entry carries exactly `msgstr[0]`, `msgstr[1]`, `msgstr[2]`. Never collapse them, never leave one empty.

| Index | Covers | Czech case |
|---|---|---|
| `msgstr[0]` | exactly **1** | nominative singular |
| `msgstr[1]` | **2, 3, 4** | nominative plural |
| `msgstr[2]` | **0** and **5 and above** — everything else | **genitive plural** |

**Index `[2]` covers zero.** `0` takes the genitive plural, the same form as `100`: `0 schůzek`, never `0 schůzka`. Translators coming from German or English get this wrong on the first pass, every time.

```po
msgid "minute"
msgid_plural "minutes"
msgstr[0] "minuta"    # 1 minuta
msgstr[1] "minuty"    # 2, 3, 4 minuty
msgstr[2] "minut"     # 0 minut, 5 minut, 27 minut

msgid "%{count} hour"
msgid_plural "%{count} hours"
msgstr[0] "%{count} hodina"
msgstr[1] "%{count} hodiny"
msgstr[2] "%{count} hodin"
```

`schůzka / schůzky / schůzek` · `rezervace / rezervace / rezervací` · `den / dny / dní` · `událost / události / událostí` · `kalendář / kalendáře / kalendářů` · `host / hosté / hostů`.

**Identical forms are sometimes correct.** Unit symbols do not decline, so `Resend available in %{count}s` is `Znovu odeslat lze za %{count} s` in all three forms. Fill all three anyway; an empty form is a build failure, not a shortcut.

**A hard-coded genitive plural is a latent bug.** `%{duration} minut` is right for 15, 30 and 45 and wrong for 22. If a count can vary freely and the source uses plain `dgettext`, flag it for the developers rather than picking a form and hoping.

---

## 8. DECLENSION AROUND NUMERALS AND PLACEHOLDERS

**Everything agreeing with `%{count}` must follow the plural index, including adjectives and the verb.** The verb is the trap: with index `[2]` it goes to the **3rd person singular neuter**.

```po
msgid "Stripe account disconnected. %{count} pending booking cancelled."
msgid_plural "Stripe account disconnected. %{count} pending bookings cancelled."
msgstr[0] "Účet Stripe byl odpojen. %{count} čekající rezervace byla zrušena."
msgstr[1] "Účet Stripe byl odpojen. %{count} čekající rezervace byly zrušeny."
msgstr[2] "Účet Stripe byl odpojen. %{count} čekajících rezervací bylo zrušeno."
```

Note all three axes moving together: the adjective (`čekající` → `čekajících`), the noun (`rezervace` → `rezervací`), and the verb (`byla zrušena` → `byly zrušeny` → `bylo zrušeno`).

**Names in placeholders are never inflected.** `%{name}` arrives in the nominative and stays there. Never append a Czech ending (`s %{name}em`), and never place the placeholder directly after a preposition that governs a case. Three sanctioned patterns:

1. **Verb-first nominative** — the cleanest. `Hosted by %{name}` → **`Pořádá %{name}`**. `%{name} has scheduled a meeting with you.` → **`%{name} s vámi naplánoval schůzku.`** — careful, that participle agrees with the *name*; prefer **`Máte novou schůzku od: %{name}`** or restructure.
2. **A declinable noun absorbs the case** — the primary escape hatch. `Meeting with %{name}` → **`Schůzka s uživatelem %{name}`**; `Refund %{attendee} for %{meeting_type}.` → **`Vrátit platbu účastníkovi %{attendee} za typ schůzky %{meeting_type}.`** The Czech noun carries the ending; the placeholder stays untouched.
3. **A colon or dash frame** where brevity matters: **`Hostitel: %{name}`**, **`Schůzka – %{name}`**.

**English possessives must be restructured, not calqued.** A msgid like `"%{name}'s booking"` has no Czech equivalent: the possessive suffix `-ův/-ova/-ovo` would have to agree with the gender of the possessor *and* of the possessed noun, and would have to inflect the name itself. Write **`rezervace uživatele %{name}`** or **`rezervace – %{name}`** instead.

**Prepositions inside pre-formatted fragments.** `Bookings available up to %{advance}` interpolates a whole phrase (`90 days in advance`). Translate the fragment so it stands alone in the nominative — `90 dní dopředu` — and frame the host string without a preposition: **`Rezervace až %{advance}`**.

---

## 9. TONE BY REGISTER

- **Marketing** — warm, direct, confident. Not stiff corporate Czech, and not calqued English. Rephrase idioms rather than translating them word for word; `stop the back-and-forth and start booking` becomes a Czech sentence, not a Czech-shaped English one. Keep `vy`, but let the sentences breathe. Headlines should land as headlines.
- **Dashboard / admin UI** — terse, functional. Buttons are infinitives, toggle states are neuter participles (`Zapnuto` / `Vypnuto`), system feedback is clean declarative: `Nastavení se nepodařilo aktualizovat.` No filler, no exclamation marks except on genuine success.
- **Transactional e-mail** — polite, clear, human. Greeting **`Dobrý den, %{name},`** — never `Ahoj`, which is the `ty` register and clashes with everything else. Sign-off `Best,` → **`S pozdravem`**, standing alone on its line with no comma. Apologies stay courteous and in the present tense, which is gender-free: `Omlouvám se za případné komplikace.` Much of `emails.pot` is written in the host's first-person voice; keep it first person, and avoid past-tense first-person forms, which would force a gender on the host.
- **Booking flow (public)** — friendly, encouraging, and free of product jargon. The guest is not an operator: `Please select a date to see available times` → **`Vyberte prosím datum, abyste viděli volné termíny.`** Success is upbeat but not shouty: `You're All Set!` → **`Máte hotovo!`**

---

## 10. ONE-LINE SUMMARY

Formal lowercase **vy**; buttons take the **infinitive**, prompts the 2nd-person-plural imperative; restructure away from gendered participles. **schůzka** (meeting and appointment) · **rezervace** (booking) · **termín** (slot) · **událost** (calendar event) · **typ schůzky** / **Typy schůzek** · **hostitel** (host) vs **host** (guest) vs **organizátor** · **časová rezerva** (buffer) · **časové pásmo** · **nástěnka** (dashboard) · **motiv** (theme) · **poskytovatel** · **předplatné** / **tarif** · **vlastní** (custom). Three plural forms, `[2]` covering **zero** and 5+. Keep **Tymeslot** (uninflected), brand names, env vars and `%{…}` verbatim. Use `„…“`, `–` (never `—`), `…`, `15. 3. 2026`, `14:30`, `1 234,56`, `1 200 Kč`, sentence-case headings, and a non-breaking space after every single-letter preposition.
