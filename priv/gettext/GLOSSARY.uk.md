# Tymeslot — Ukrainian (uk) Translation Style Guide & Termbase

Authoritative. Mined from the ~3,800 already-translated Ukrainian msgstrs and settled during
the terminology unification sweep. Follow this exactly. Where this guide contradicts an
existing msgstr in the repo, **this guide wins** — the existing string is drift and is being
corrected.

The guiding principle behind every call below: **prefer standard Ukrainian over a
transliterated Anglicism, and over a Russian calque.** A loanword is kept only where it is
genuinely naturalised in Ukrainian (`слот`, `провайдер`, `вебхук`), never merely because the
English word was convenient to respell in Cyrillic.

---

## 1. REGISTER

**Formal «ви» / «ваш» everywhere.** Booking flow, emails, dashboard, admin, marketing.
No exceptions. Never «ти».

Write the polite pronoun **lowercase** — `ви`, `ваш`, `вам` — not `Ви`. This is the modern
Ukrainian convention for addressing an unknown reader, and it is already consistent across all
40 catalogues. Do not "upgrade" it to the capitalised form.

Buttons take the **infinitive** (`Скасувати`, `Зберегти`, `Видалити`, `Від'єднати`).
Instructions and prompts take the **2nd-person-plural imperative** (`Виберіть`, `Підключіть`,
`Введіть`, `Підтвердьте`).

---

## 2. GLOSSARY

| English | Ukrainian |
|---|---|
| meeting | **зустріч** |
| appointment | **зустріч** |
| booking (noun) | **бронювання** |
| to book | **забронювати** / **бронювати** |
| booking page / link / flow | **сторінка бронювання** / **посилання для бронювання** / **процес бронювання** |
| meeting type / event type | **тип зустрічі** / **тип події** |
| **slot / time slot** | **слот** **[DECIDED]** — `часовий слот` where the bare noun would be ambiguous. Never `вікно` (that is a UI window), never bare `час` |
| event (calendar event) | **подія** — distinct from **зустріч** (a booked Tymeslot meeting). Do not conflate them |
| attendee | **учасник** |
| guest | **гість** / **гості** |
| invitee | **запрошений** / **запрошені** |
| host / organiser | **організатор** |
| availability | **доступність** |
| buffer | **буферний час** |
| calendar | **календар** |
| schedule (verb) | **планувати** |
| scheduling (noun) | **планування** |
| reschedule | **перенести** |
| cancel | **скасувати** |
| confirm / confirmation | **підтвердити** / **підтвердження** |
| timezone | **часовий пояс** |
| duration | **тривалість** |
| reminder | **нагадування** |
| **account** | **обліковий запис** **[DECIDED]** — never `акаунт`, in any catalogue, including emails and marketing |
| sign in / log in | **увійти** |
| sign up / register | **зареєструватися** |
| password | **пароль** |
| authentication | **автентифікація** |
| user | **користувач** |
| admin / administrator | **адміністратор** |
| **dashboard** | **панель керування** — never `дашборд`, never Latin `dashboard` |
| settings | **налаштування** |
| profile | **профіль** |
| **application / app** | **застосунок** **[DECIDED]** — **never `додаток`**, which means *appendix/attachment* and is a calque of Russian «приложение». `додатковий` (*additional*) is a different word and is fine |
| **provider** (calendar / OAuth / video / login) | **провайдер** **[DECIDED]** — see the note below |
| **vendor** (the company selling a competing product) | **постачальник** — deliberately kept distinct from *provider* |
| integration | **інтеграція** |
| automation | **автоматизація** |
| workflow | **робочий процес** |
| webhook | **вебхук** |
| embed / embedding | **вбудовування**; the artefact is a **віджет** |
| **logs** | **журнали** **[DECIDED]** — never `логи` |
| **test / testing** (verb / gerund) | **перевірити** / **перевірка** **[DECIDED]** — never `тестувати`/`тестування` for UI actions |
| **disconnect** | **від'єднати** / **від'єднано** **[DECIDED]** — never `відключити` (which reads as *switch off*; `вимкнути` is the word for *disable*) |
| **invalid** (a malformed value, ID, format, request) | **некоректний** **[DECIDED]** |
| **invalid** (a link or token with no force) | **недійсний** — reserved for exactly this sense |
| — never | `неправильний` for *invalid*. Eliminated |
| **valid** | **коректний** — never `дійсне число` (that is *a real number* in maths) |
| `is invalid` (Ecto field error) | **має некоректне значення** — a gender-neutral construction; Ecto appends it to field labels of arbitrary gender, so no adjective can agree |
| subscription | **підписка** |
| plan (pricing tier) | **тариф** |
| billing | **оплата** / **виставлення рахунків** |
| upgrade (the action) | **розширити** — e.g. `Розширити дозволи`. Never `Оновити`, which collides head-on with *Refresh* |
| refresh | **оновити** |
| payment | **платіж** / **оплата** |
| payment receipt | **квитанція про оплату** |
| refund | **повернення коштів** |
| video call / video meeting | **відеозустріч** |
| Video Integration | **Інтеграція відеозв'язку** (not `Інтеграція відео`) |
| location | **місце** |
| question (a custom booking question) | **запитання** — never `питання`, which means *issue/matter* |
| **lifetime** (a one-off perpetual licence) | **довічний** / **довічно** **[DECIDED]** — never `пожиттєво` |
| forever (free forever) | **назавжди** — a different idea from *lifetime*; keep both |
| **Live Preview** | **Перегляд наживо** **[DECIDED]** — distinct from plain *Preview* → **Попередній перегляд** |
| **Unlisted** | **Прихований** |
| Default (a badge / option label) | **Стандартний** |
| by default (adverbial) | **за замовчуванням** — see §4 |
| Failed (a status) | **Помилка** |
| staff | **працівники** |
| Agenda (calendar view) | **Розклад** |
| Weekly Schedule (availability) | **Тижневий розклад** |

### A note on `провайдер` vs `постачальник`

Both are correct Ukrainian; `провайдер` is a dictionary-attested naturalised loan, not a
Russianism. The split is by **sense**, and it is load-bearing:

- **`провайдер`** = a *service provider* the product integrates with — Google Calendar, a
  CalDAV server, an OAuth identity provider, a video provider. This is the dominant existing
  usage and reads naturally to a Ukrainian IT user.
- **`постачальник`** = a *vendor* — the company selling a competing product ("check the
  vendor's page", "no vendor to depend on"). This sense appears throughout
  `marketing_compare.po`.

Collapsing the two would make `постачальник` carry both meanings in the same file. Keep them
apart.

### Self-hosting — the highest-value term in the catalogue

`marketing_compare.po` is the page whose entire argument turns on this word. Five renderings
existed, including the raw transliteration `селф-хостинг`. It is now one system:

| English | Ukrainian |
|---|---|
| self-hosting (noun) | **самостійний хостинг** **[DECIDED]** |
| of self-hosting (gen.) | **самостійного хостингу** |
| to self-host / when self-hosting | **розгорнути на власному сервері** / **у разі самостійного хостингу** |
| self-hosted (adj., of a deployment) | **на власному сервері** |
| the self-hosted version/build | **версія для власного сервера** |
| `Self-Hosted` (the pricing-card title) | **На власному сервері** |

**Never** `селф-хостинг`. **Never** Latin `self-hosted` inside a Ukrainian sentence.

### Email

Latin-script `email` never appears inside a Ukrainian sentence, label, or subject line.

| English | Ukrainian |
|---|---|
| email (the medium / channel) | **електронна пошта** |
| email address | **адреса електронної пошти** (or **електронна адреса** where brevity matters) |
| by email (adverbial) | **електронною поштою** |
| emails (the messages) | **листи** |
| `Email` (a bare form-field or column label) | **Електронна пошта** |

`%{email}` placeholders are of course untouched — the *variable* is not the *word*.

### Plan and tier names

- Compound tier names are **proper nouns and stay verbatim**: `Cloud Free`, `Cloud Pro`, `Pro`,
  `Enterprise`.
- Bare **`Free`** is translated, and the sense decides the form:
  - as a **tier label** on a pricing card → **`Безкоштовний`** (agreeing with *тариф*), and
    "Everything in Free" → **`Усе, що є в безкоштовному тарифі`**;
  - as a **price value** (the big number slot on a card) → **`Безкоштовно`**.
- `Self-Hosted` as a card title is descriptive, not a brand: **`На власному сервері`**.

### Calendar views

`view` (a calendar display mode) → **подання**. One word, no synonyms.

| English | Ukrainian |
|---|---|
| Views | **Подання** |
| Day view | **Денне подання** |
| Week view | **Тижневе подання** |
| Month view | **Місячне подання** |
| Agenda view | **Подання «Розклад»** |
| in month view / in week view | **у місячному поданні** / **у тижневому поданні** |

Never `режим` for a calendar view (it means *mode* and is used for other things).

### `+%{count} more`

**`ще %{count}`** — in all four catalogues that carry it (`dashboard_home`,
`dashboard_calendar`, `dashboard_calendar_events`, `marketing_home`). `ще` already means
"more"; the leading `+` was English-idiom noise.

---

## 3. RUSSIAN CALQUES AND TRANSLITERATIONS — BANNED

Each of these shipped in the catalogue at least once. All are now eliminated. Do not
reintroduce them.

| Banned | Use instead |
|---|---|
| `додаток` (as *app*) | **застосунок** |
| `акаунт` | **обліковий запис** |
| `Описання` (not a word) | **опис** |
| `селф-хостинг` | **самостійний хостинг** |
| `з коробки` («из коробки») | **одразу після встановлення**, or rephrase — `Profession-tuned out of the box` → **Готові налаштування під кожну професію** |
| `інстанс` | **екземпляр** |
| `кастомний` | **власний** |
| `Фолоап` | **Подальші дії** |
| `аптайм` | **безперебійна робота** |
| `чекліст` | **контрольний список** |
| `онбординг` | **початкове налаштування** |
| `безлімітний` | **необмежена кількість …** |
| `дашборд` | **панель керування** |
| `логи` | **журнали** |
| `паритетність` | **паритет** |
| `продакшн` / `не для продакшену` | **промислова експлуатація** / **не для промислового використання** |
| Latin `staging` | **тестове середовище** |
| Latin `self-hosted`, `email`, `dashboard`, `Free` mid-sentence | see the tables above |

**Character-level:** never `ы`, `э`, `ъ`, `ё`. Use `і`, `ї`, `є`, `ґ` correctly. The apostrophe
is `'` (as in `зв'язок`, `від'єднати`, `пам'ятайте`).

---

## 4. THE ONE DELIBERATE COMPROMISE — `за замовчуванням`

`за замовчуванням` is, strictly, a calque of Russian «по умолчанию»; the prescriptive forms are
`за умовчанням` and `типово`.

**We keep `за замовчуванням` for the adverbial sense ("by default").** It is the form Ukrainian
users actually meet in Microsoft's and Google's products, it is gender-neutral (so it is safe in
badges where the referent's gender is unknown), and it is unambiguous. This is a considered
house decision, not an oversight.

For the **adjectival** sense — `Default` as an option name or badge — use **`Стандартний`**.

---

## 5. DO NOT TRANSLATE — keep verbatim

**Tymeslot**, Stripe, Stripe Checkout, Stripe Connect, reCAPTCHA, Google, Google Calendar,
Google Meet, GitHub, Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail,
Zimbra, Radicale, mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript, OAuth,
OIDC, SSO, Oban, UTM, Cloudron, Quill, Rhythm, Docker, PostgreSQL, Railway, AGPLv3.

**Environment-variable and config names, always verbatim:** `REGISTRATION_ENABLED`,
`PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`,
`OAUTH_*`. Likewise embed attributes: `data-theme`, `data-primary-color`, `data-locale`.

**Sample and placeholder values:** localise prose-shaped samples (`yourname` →
`vashe_imya`), but keep format-shaped ones verbatim — email addresses
(`your.email@example.com`), URLs, hosts, and API keys (`your-api-key-here`). An API key can
never contain Cyrillic, so a Cyrillic API-key placeholder is a bug.

### Third-party UI labels — never guess

When an instruction tells the user to click something inside another company's product, the
label must match what that product actually shows in Ukrainian. Invent one and the user hunts
for a menu item that does not exist.

> **Open item.** `dashboard_calendar_providers.po` renders Apple's `Sign-In and Security →
> App-Specific Passwords` as `Вхід і безпека → Паролі застосунків`. This follows *our* termbase
> (`застосунок`), but it has **not** been verified against Apple's own Ukrainian surface on
> `account.apple.com`, which may say `програма`. Check it against Apple's Ukrainian help pages
> before treating it as settled.

---

## 6. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` — the hard rule:**
- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr must have exactly those three.
- You **may and should reorder** them to fit Ukrainian syntax.
- A dropped or invented placeholder is a runtime crash, not a typo.

**Beware composition.** Several strings interpolate a *pre-formatted* fragment. Check what the
call site actually produces before adding a preposition around `%{…}` — Ukrainian case
government makes stacked prepositions (`до за 90 днів`) and case mismatches (`через 1 година`)
very easy to ship.

**Markup and entities** pass through verbatim: `<strong>…</strong>`, `&` (literal), bullets `•`,
checkmarks `✓`, emoji, `\n` paragraph separators.

**Typography:**
- Quotation marks: Ukrainian guillemets **`«…»`**
- Em dash **`—`** (space-padded) for parenthetical asides and subject-line separators
- Ellipsis `…`
- Decimal **comma**: `0.0 and 1.0` → `від 0,0 до 1,0`
- Currency **postfix**, per Ukrainian convention: `29 $`, `10 $/користувача/міс.`, `0 €` —
  not `$29`
- Abbreviate months as `/міс.` (with the full stop), consistently

---

## 7. PLURALS — UKRAINIAN HAS THREE FORMS

`nplurals=3`. Every plural entry carries exactly `msgstr[0]`, `msgstr[1]`, `msgstr[2]`. Never
collapse them, never leave one empty.

```po
msgid "hour"
msgid_plural "hours"
msgstr[0] "година"   # n mod 10 == 1 and n mod 100 != 11  → nominative singular
msgstr[1] "години"   # n mod 10 in 2..4                   → genitive singular
msgstr[2] "годин"    # everything else, including 0       → genitive plural
```

**Watch the case the label lands in.** `msgstr[0]` is nominative by default, but if the label is
interpolated after a preposition that governs the accusative (`за %{label}`, `через %{label}`),
form [0] must be **accusative**: `хвилину`, `годину`. Forms [1] and [2] happen to coincide with
the accusative already.

**A hard-coded genitive plural is a latent bug.** `%{duration} хвилин` is right for 15/30/45 and
wrong for 22. If the count can vary freely, the source needs `dngettext`, not a fixed form.

---

## 8. TONE BY REGISTER

- **Marketing** — warm, direct, confident. Rephrase idioms rather than calquing them. Headlines
  should land as headlines. Long comparison prose should read as though written in Ukrainian,
  not translated into it.
- **Dashboard / admin UI** — terse, functional. Buttons are infinitives. Toggle states are
  adjectives. System feedback is clean declarative: `Не вдалося оновити налаштування.`
  No filler, no exclamation marks except on genuine success.
- **Transactional email** — polite, clear, human. Greeting **`Вітаю, %{name},`** for host-voice
  mail (the platform writing on the host's behalf). Never `Привіт` — it is the informal
  «ти»-register and clashes with the formal register used everywhere else.
- **Booking flow (public)** — friendly, encouraging. The guest is not an operator: prefer plain
  language over product jargon where the two compete.

---

## 9. ONE-LINE SUMMARY

Formal lowercase **ви**. **обліковий запис** (never акаунт) · **застосунок** (never додаток) ·
**самостійний хостинг** (never селф-хостинг) · **провайдер** (integration) vs **постачальник**
(vendor) · **подання** (calendar view) · **від'єднати** · **слот** · **некоректний** (bad value)
vs **недійсний** (dead link) · **журнали** · **перевірка** · **електронна пошта** (never Latin
`email`). Three plural forms, always. Keep **Tymeslot / brand names / env vars / `%{…}`**
verbatim. Use `«…»`, `—`, `…`, decimal comma, postfix currency.
