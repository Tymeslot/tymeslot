# Tymeslot — Brazilian Portuguese (pt_BR) Translation Style Guide & Termbase

Authoritative. Written **before** the catalogues, not mined from them, so that every one
of the 3,438 msgstrs could be translated against a fixed termbase instead of drifting
across 28 domains. Where this guide and a msgstr disagree, **this guide wins**.

Brazilian Portuguese only. See §8 for why this is `pt_BR` and not `pt`, and why that
choice changes runtime behaviour rather than just a label.

---

## 1. REGISTER

**"você" everywhere.** Booking flow, dashboard, admin, marketing, transactional email.
No exceptions.

Portuguese has three ways to address a reader and only one of them fits a product:

- **"você"** — the Brazilian default. Neither familiar nor distant. This is what every
  Brazilian software product uses, and it is what we use.
- **"tu"** — regional (South, parts of the North) and almost always conjugated
  informally. Wrong register and wrong reach. Never.
- **"o senhor" / "a senhora"** — genuinely deferential, and it *genders the reader*.
  A booking page cannot know. Never.

Unlike German, pt-BR needs no Sie/du decision: "você" carries no coldness, so the warmth
of the English comes through without softening anything.

### Grammatical gender — the rule that matters most here

Portuguese inflects adjectives and participles for gender, and **Tymeslot never knows
the reader's**. Three rules, in order of preference:

1. **Rewrite around it.** This is almost always possible and always better.
   - `"You're invited"` → **"Você foi convidado"** ❌ → **"Convite para você"** ✓
   - `"Welcome!"` → **"Bem-vindo!"** ❌ → **"Boas-vindas!"** ✓ (gender-free, and now
     standard in Brazilian products)
   - `"Are you sure?"` → **"Tem certeza?"** ✓ (already gender-free — prefer these)
2. **Prefer gender-free nouns** when naming a person. `participante`, `cliente`,
   `pessoa`, `responsável` inflect only in the article, which can often be dropped.
3. **Only where 1 and 2 fail**, use the masculine as the grammatical default
   (`convidado`, `anfitrião`). This is standard Brazilian usage.

**Never use `@`, `x`, or `e` as an inclusive ending** (`convidad@`, `convidadx`,
`convidade`). They are not standard orthography, screen readers mangle them, and they
would be the single most conspicuous thing about the translation.

---

## 2. GLOSSARY

The core distinctions. English overloads these words; Portuguese must not follow it
into the overload, because the same English word is a different thing in the booking
flow and in the dashboard.

| English | pt-BR | Note |
|---|---|---|
| **meeting** (the booked thing, the product noun) | **reunião** | The default. 313 occurrences. |
| **meeting type** | **tipo de reunião** | Never "tipo de evento". |
| **booking** (the record / the act) | **agendamento** | The thing in the list. |
| **to book** | **agendar** | |
| **booker** (the one who books) | **quem agenda** | No good noun exists; the relative clause is natural Portuguese and avoids gender. |
| **booking flow** | **fluxo de agendamento** | |
| **appointment** | **compromisso** | Public booking flow only, and kept distinct from *reunião* on purpose: "Crie tipos de reunião para oferecer diferentes opções de compromisso" needs both words to say anything. |
| **event** (entry in an external calendar) | **evento** | Google Calendar's own pt-BR word. |
| **event** (webhook / subscription sense) | **evento** | Same word, different domain; no collision in practice. |
| **host** | **anfitrião** | §1 rule 3 applies. |
| **attendee** | **participante** | Gender-free in both forms — prefer it wherever the English allows. |
| **guest** | **convidado** | |
| **invitee** | **convidado** | Same word as *guest*. English distinguishes them in 2 strings out of 3,438; Portuguese gains nothing by inventing a second term. |
| **slot** / **time slot** | **horário** | "the slot is released" → "o horário é liberado". Never "espaço" or "vaga". |
| **buffer** (between meetings) | **folga** | **[DECIDED]** Not "intervalo", which is already needed for *interval* ("Booking slot interval" → "Intervalo entre horários"). "Folga entre reuniões" / "Sem folga" is natural Brazilian and keeps the two apart. |
| **availability** | **disponibilidade** | |
| **available times** | **horários disponíveis** | |
| **reschedule** | **remarcar** | Not "reagendar" — both exist, "remarcar" is the one Brazilians say. |
| **cancel** | **cancelar** | |
| **decline** (a request) | **recusar** | |

### Extended termbase

| English | pt-BR |
|---|---|
| account | conta |
| dashboard | painel |
| settings | configurações |
| profile | perfil |
| user | usuário |
| username | nome de usuário |
| password | senha |
| app password / app-specific password | senha de app / senha específica do app (see §3) |
| sign in · log in | entrar |
| sign up | criar conta |
| sign out · log out | sair |
| email (noun) | e-mail |
| link | link |
| team | equipe |
| workspace (Slack) | espaço de trabalho (Slack's own pt-BR term) |
| member | membro |
| calendar | calendário |
| timezone | fuso horário |
| duration | duração |
| reminder | lembrete |
| notification | notificação |
| payment | pagamento |
| refund | reembolso |
| invoice | fatura |
| integration | integração |
| webhook | webhook |
| embed (verb / noun) | incorporar / incorporação |
| upload (verb) | enviar |
| delete | excluir |
| remove | remover |
| save | salvar |
| custom | personalizado |
| recurring | recorrente |
| required (field) | obrigatório |
| enabled / disabled | ativado / desativado |
| confirmed | confirmado |
| pending | pendente |
| overview | visão geral |
| analytics | análises |
| plan (Pro, Free) | plano |

### Third-party UI labels — never guess

When a setup instruction tells the reader to click something inside another company's
product, the label must be what that product actually shows **to a Brazilian user**.
Invent one and they hunt for a menu that does not exist.

| Vendor | English | pt-BR | Source |
|---|---|---|---|
| Apple, **web** (`account.apple.com`) | Sign-In and Security | **Início de sessão e segurança** | `support.apple.com/pt-br/102654` |
| Apple, menu label | App-Specific Passwords | **Senhas específicas de apps** | *ibid.* |
| Apple, running prose | app-specific password | **senha específica do app** | *ibid.* — note the singular shifts to `do app` |
| Apple | *Generate* a password | **gerar** | Apple's own verb; not "criar" |
| mailbox.org | Settings → Security | **keep English: `Settings → Security`** | see below |

**mailbox.org stays in English, and that is the careful answer, not the lazy one.**
mailbox.org's interface is offered in German, English, Spanish, French, Italian and
Dutch — **not Portuguese**. A Brazilian user is looking at an English (or German) menu.
Translating the label to "Configurações → Segurança" would send them looking for words
that are not on their screen. Write the surrounding sentence in Portuguese and leave the
label alone: *"…gere uma senha específica de aplicativo em Settings → Security…"*

Re-check this if mailbox.org ever ships a Portuguese UI.

### Sample and placeholder values

- **Localise prose-shaped samples**: `yourname` → `seunome`, `your-username` →
  `seu-usuario`, `e.g. Jane Smith` → a Brazilian name (`ex.: Ana Souza`).
- **Keep format-shaped samples verbatim**: e-mail addresses
  (`your.email@example.com`, `guest@example.com`), URLs and hosts
  (`https://caldav.example.com`, `https://radicale.example.com:5232`), API keys
  (`your-api-key-here`), and anything at `example.com`. These are formats, not words.

**Common UI labels:** Save→Salvar · Continue→Continuar · Back→Voltar · Next→Avançar ·
Submit→Enviar · Done/Finish→Concluir · Add→Adicionar · Close→Fechar · Skip→Pular ·
Got it→Entendi · Required fields→Campos obrigatórios · Select→Selecionar ·
Learn more→Saiba mais · Try again→Tentar novamente · Copy→Copiar · Copied→Copiado ·
Privacy Policy→Política de Privacidade · Terms of Service→Termos de Serviço ·
Search→Buscar · Loading…→Carregando… · Optional→Opcional.

---

## 3. DO NOT TRANSLATE — keep verbatim

**Tymeslot** (no hyphenated compounds — Portuguese uses "conta do Tymeslot", "painel do
Tymeslot"), Stripe, Stripe Checkout, Stripe Connect, reCAPTCHA, Google, Google Calendar,
Google Meet, GitHub, Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail,
Zimbra, Radicale, mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript,
OAuth, OIDC, SSO, Oban, UTM, Cloudron.

Loanwords kept as-is: **link**, **webhook**, **slug**, **e-mail**, **upgrade**, **plugin**,
**check-in**, **app**. All are current Brazilian technical usage; translating them
("hiperligação", "correio eletrónico") reads as European Portuguese or as 1998.

**Environment-variable and config names verbatim**, always: `REGISTRATION_ENABLED`,
`PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`,
`OAUTH_*`, and friends.

---

## 4. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` — the hard rule:**
- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr has exactly those three.
- You **may and should reorder** them to fit Portuguese syntax:
  - `"%{month} %{day}, %{year}"` → `"%{day} de %{month} de %{year}"`
  - `"You're booking a %{duration} meeting with %{name}"` →
    `"Você está agendando uma reunião de %{duration} com %{name}"`
- A dropped or invented placeholder is a runtime crash, not a typo.

**Markup / entities:** verbatim inside the msgstr.
- `"<strong>removed from your external calendar</strong>"` →
  `"<strong>removido do seu calendário externo</strong>"`
- `&` stays literal (not `&amp;`). Bullets `•`, checkmarks `✓`, emoji preserved.

**Typography — use these characters:**
- Ellipsis **`…`** (U+2026), never `...`, and **no space before it** — `Carregando…`,
  `Selecionar…`. Project convention across every domain.
- En dash **`–`** for ranges (`14h–15h`) and subject-line separators.
- Em dash **`—`**, space-padded, for parenthetical asides, mirroring the English.
- Brazilian quotes are the **curly double** `“…”` (U+201C / U+201D). **Not** the
  guillemets `«…»`, which are European Portuguese and would mark the translation as
  foreign on sight.
- **Decimal comma**: `"0.0 and 1.0"` → `"0,0 e 1,0"`. Thousands separator is `.`
  (`1.500`), and currency is `R$ 1.234,56` — with a space after `R$`.
- `ex.:` for "e.g."; `p. ex.` is European. `etc.` keeps its period.
- **24-hour clock.** Brazil does not use AM/PM. `"3:00 PM"` → `"15:00"`, and in running
  prose `15h`.
- Dates are **day-first**: `15/09/2026`, and in prose `15 de setembro de 2026`.
  Month names are **lowercase** in Portuguese — `setembro`, never `Setembro`.
- Weekday names are lowercase too: `segunda-feira`, `terça-feira`, `sábado`, `domingo`.

---

## 5. PLURALS

pt_BR is `nplurals=2; plural=(n > 1);`.

**This is not the same split as German, and it is the trap in this language.**

```
msgstr[0]  →  n == 0 AND n == 1
msgstr[1]  →  n > 1
```

Zero takes the **singular** form, because gettext's pt_BR rule is `n > 1`, not `n != 1`.
So `msgstr[0]` has to read correctly for both "0" and "1", and the naive singular
sometimes does not:

```po
msgid "%{count} booking"
msgid_plural "%{count} bookings"
msgstr[0] "%{count} agendamento"     # "0 agendamento" — awkward but correct per the rule
msgstr[1] "%{count} agendamentos"
```

Where a zero case is genuinely reachable in the UI and "0 <singular>" would look broken,
**rephrase the msgstr[0] so it survives both** — e.g. prefer a form without the bare
noun-count juxtaposition. Where zero is unreachable (durations, "%{count} minutes"),
translate naturally and move on.

Both forms must be filled. Placeholders present in a form must appear in that form.

---

## 6. TONE BY REGISTER

- **Marketing** — warm, direct, confident. Brazilian marketing Portuguese is *less*
  formal than the English, not more; resist the pull toward bureaucratic Portuguese
  ("realizar", "efetuar", "possuir" — say "fazer", "ter"). Rephrase idioms instead of
  calquing: `"stop the back-and-forth and start booking"` → **"Chega de e-mail vai,
  e-mail vem. Agende de uma vez."** Headlines must land as headlines.
- **Dashboard / admin UI** — terse, functional. Buttons are imperative verbs (Salvar,
  Excluir, Remarcar) or bare nouns. Toggle states are adjectives (Ativado/Desativado).
  System feedback is clean declarative: **"Não foi possível atualizar a configuração."**
  — this impersonal construction is the Brazilian product idiom for failure and avoids
  both blame and gender. No filler, no exclamation marks except genuine success.
- **Transactional email** — polite, clear, human. Greeting **"Olá %{name},"**.
  **Unlike German, Portuguese capitalises the sentence after the comma** — `"Olá Ana,"`
  then `"Sua reunião foi confirmada."` Keep the capital; the msgid's capital is right.
  Sign-off `"Best,"` → **"Abraço,"** for warm mail, **"Atenciosamente,"** where the
  English is neutral-formal. Apologies plain: **"Desculpe pelo transtorno."**
- **Booking flow (public)** — friendly and guiding; this reader has never heard of
  Tymeslot. `"Please pick a date to see available times"` → **"Escolha uma data para
  ver os horários disponíveis"**. Success is upbeat: **"Reunião confirmada!"**

---

## 7. FALSE FRIENDS AND EUROPEAN PORTUGUESE

Every word in the left column is correct Portuguese and wrong here. These are the
markers a Brazilian reader notices in the first three seconds.

| European / wrong | Brazilian |
|---|---|
| utilizador | **usuário** |
| ficheiro | **arquivo** |
| guardar (a file) | **salvar** |
| apagar (a record) | **excluir** |
| palavra-passe | **senha** |
| ecrã | **tela** |
| equipa | **equipe** |
| telemóvel | **celular** |
| correio eletrónico | **e-mail** |
| hiperligação | **link** |
| autenticação de dois fatores | fine, but prefer **verificação em duas etapas** (Google's pt-BR) |
| registar | **cadastrar** / **registrar** |
| definições | **configurações** |
| separador (tab) | **aba** |
| carregar (a button) | **clicar** |
| a gestão | **o gerenciamento** |
| endereço eletrónico | **endereço de e-mail** |

Spelling: post-1990 orthographic agreement, Brazilian variant — `ação`, `direção`,
`econômico` (circumflex, not `económico`), `fato` (not `facto`), `registro` (not
`registo`).

---

## 8. WHY `pt_BR` AND NOT `pt`

Two reasons, and the second is not cosmetic.

**1. The vocabulary above.** §7 is not a list of preferences; it is a list of words that
make the other readership feel the product was not built for them. One catalogue cannot
serve both.

**2. The locale name changes runtime pluralisation.** Expo's plural-forms table, which
Elixir's `Gettext.Plural` delegates to, gives the two tags different rules:

| locale | rule | `msgstr[0]` serves |
|---|---|---|
| `pt` | `nplurals=2; plural=(n != 1);` | n == 1 only |
| `pt_BR` | `nplurals=2; plural=(n > 1);` | **n == 0 and n == 1** |

Naming the directory `pt` and filling it with Brazilian text would silently change which
form 63 plural entries render at zero. The tag is a behaviour switch, not a label.

---

## 9. ONE-LINE SUMMARY

Informal **você**, never *tu* or *o senhor*; rewrite around grammatical gender rather
than picking one. **reunião** (the booked meeting) · **agendamento** (booking) ·
**tipo de reunião** · **horário** (slot) · **folga** (buffer) · **anfitrião** (host) ·
**participante** (attendee) · **convidado** (guest/invitee) · **compromisso**
(appointment). Keep **Tymeslot / brand names / env vars / `%{…}`** verbatim. Use `“…”`,
`–`, `—`, `…`, decimal comma, 24-hour clock, day-first dates, lowercase month names.
`msgstr[0]` covers **zero and one**. Never drop or invent a placeholder.
