# Tymeslot: Spanish (`es`) Translation Style Guide & Termbase

Authoritative. Written before the catalogues, so the msgids are translated against a fixed
termbase rather than drifting term by term. Where this guide contradicts a later msgstr,
**this guide wins**: the string is drift and gets corrected.

Decisions marked **[DECIDED]** were settled deliberately and are not open for per-string
reinterpretation. Decisions marked **[OPEN]** still need the maintainer's call; they are
listed in section 9 and nowhere else, so they cannot hide in the middle of a table.

---

## 1. REGISTER

**Informal `tú` everywhere.** Booking flow, emails, dashboard, admin, marketing. No
exceptions. Never `usted`. **[DECIDED]**

Plural is **`ustedes`**, never `vosotros`: `vosotros` is Spain-only and marks the text as
European the moment a Latin American reads it. No voseo (`vos`, `elegí`, `tenés`) either:
it is regional to the River Plate and Central America.

Verb agreement follows throughout: `tu reunión`, `confirma`, `elige`, `inicia sesión`,
`inténtalo de nuevo`, `te invitó`, `te avisaremos`, `para ti`, `contigo`. Never mix in a
`usted`, a `su` that means the reader, or a `-e`/`-a` usted imperative (`elija`, `revise`,
`cancélela`); a single leak betrays the whole catalogue. `su`/`sus` stay where they mean a
third party (`el asistente y su respuesta`).

In the `tú` register an imperative looks exactly like the third-person present (`elige`,
`muestra`, `permite`). A help text that **describes** what an option does therefore names
its subject: `Esta opción muestra…`, `Con esta opción, Tymeslot envía…`, `Se reserva la
franja…`, never a bare `Muestra…` that reads as an order.

---

## 2. GLOSSARY

Spanish does **not** capitalise months, weekdays, or languages. `enero`, `lunes`,
`español`: lowercase, always, including mid-sentence and in date formats. English
capitalises all three and the msgid always will.

Sentence case for headings and buttons: `Confirmar la reserva`, not `Confirmar La Reserva`.

| English | Spanish |
|---|---|
| meeting (the booked entity, **default**) | **reunión** |
| meeting (the live video session / room) | **reunión** (`sala de reunión` for the room) |
| appointment | **cita** |
| booking (noun) | **reserva** **[DECIDED]** (never `booking`, never `agendamiento`) |
| to book | **reservar** |
| to book / arrange (marketing register) | **agendar** is Latin-American only → use **reservar** or **programar** |
| **meeting type / event type** | **tipo de reunión** **[DECIDED]** (never `tipo de evento`) |
| slot / time slot | **franja horaria** in the dashboard; **tiempo de horario** in texts guests read (booking page, guest and organiser emails) **[DECIDED]** (never `espacio`, never `slot`) |
| end time / ends at | **la hora en que termina** **[DECIDED]**, also in field labels (`Hora en que termina`); never `hora de fin` |
| (a meeting) takes place / is held | **realizarse** **[DECIDED]** (`si la reunión ya no se realiza`); never `celebrarse`, which also reads as "celebrate" |
| **organiser / organizer** | **organizador** **[DECIDED]** |
| **host** (noun) | **anfitrión**, a distinct role from `organizador`; keep them distinct |
| hosted by | **organizado por** |
| attendee | **asistente** |
| guest | **invitado** / **invitados** |
| invitee | **invitado** where it means guest, else **persona invitada** |
| availability | **disponibilidad** |
| available times | **horarios disponibles** |
| buffer | **margen** / **tiempo de margen** |
| calendar | **calendario** |
| schedule (verb) | **programar** **[DECIDED]** (not `agendar`, which is Latin-American only) |
| scheduling (noun) | **programación de reuniones** |
| reschedule (verb) | **reprogramar** |
| reschedule (noun) | **reprogramación** |
| cancel a meeting / booking | **cancelar**, *always with its object*: `cancelar la reunión` |
| cancel an action / dialog button | **Cancelar**, *bare, no object* |
| user | **usuario** |
| sign in / log in | **iniciar sesión** |
| sign out / log out | **cerrar sesión** |
| sign up / register | **registrarse** |
| password | **contraseña** |
| email (the address) | **correo electrónico**; **correo** in running prose |
| email (the message) | **correo** |
| link | **enlace** **[DECIDED]** (never `link`, never `vínculo`) |
| time zone | **zona horaria** |
| date | **fecha** |
| duration | **duración** |
| notes | **notas** |
| reminder | **recordatorio** |
| confirmation | **confirmación** |
| pending approval | **pendiente de aprobación** |
| declined | **rechazada** (a booking) |
| settings (our own UI) | **configuración** **[DECIDED]** (see section 7 on `ajustes`) |
| **poll** (the group time-finding feature) | **votación** **[DECIDED]**; never `encuesta`, which is an opinion survey, and never `sondeo` |
| to vote | **votar** |
| vote (noun) | **voto** |
| to cast a vote | **emitir el voto** |
| voting closes | **la votación cierra** |
| deadline | **plazo** |
| respondent / participant in a poll | **participante** |

### Grammatical gender in validation fragments

The `errors` catalogue holds sentence fragments that the framework appends to a field
name: `"can't be blank"` renders as *Email can't be blank*. English needs no agreement,
German gets away with `ist ungültig`, Spanish does not: an adjective has to pick a
gender, and the field it attaches to is unknown at translation time.

**The rule, in this order:**

1. **Prefer a phrasing that carries no gender.** This is almost always possible and is
   the better string regardless:
   - `has already been taken` → **`ya está en uso`**, not `ya está tomado`
   - `must be accepted` → **`se debe aceptar`**, not `debe ser aceptado`
   - `is reserved` → **`es un valor reservado`**, not `está reservado`
   - `can't be blank` → **`no puede estar en blanco`** (already neutral)
   - `does not exist` → **`no existe`** (already neutral)
2. **Where that would twist the sentence, use the masculine** as the unmarked form:
   `is invalid` → **`no es válido`**. Spanish treats it as the default for an unknown
   referent, and it is what established Spanish Ecto catalogues ship.
3. **Never write `válido/a` or `válid@`.** A slash or an at-sign inside a validation
   message reads as a defect, not as inclusiveness.

### The `cancelar` collision: read this before translating any button

German separates the two senses (`absagen` a meeting vs `abbrechen` a dialog). Spanish has
one verb for both, and getting it wrong means a user clicks "discard my edits" believing it
calls off the meeting, or the reverse.

The rule is **the object, not the verb**:

- Dialog button that discards what you were doing → **`Cancelar`**, bare.
- Anything that calls off a real meeting → the object is mandatory:
  **`Cancelar la reunión`**, `Cancelar la reserva`, `Cancelar esta cita`.
- A past-tense status never stands alone either: `Reunión cancelada`, not `Cancelada`.
  The noun names what was cancelled: `Votación cancelada` on a poll, `Evento cancelado` on
  a calendar event, `Reserva cancelada` on a booking. **[DECIDED]**

Where the msgid is a bare `"Cancel"`, the domain decides: in `booking` and `emails_booking`
it is the meeting; in dashboard dialogs it is the action. If a bare `"Cancel"` appears in a
domain where both readings are live, translate the meeting sense and leave a translator
comment, so the ambiguity is visible rather than silently resolved.

### Extended termbase

| English | Spanish |
|---|---|
| booking page | **página de reservas** |
| booking link | **enlace de reservas** |
| upcoming | **próximas** |
| past | **anteriores** |
| recurring | **periódica** |
| one-off / single | **única** |
| all day | **todo el día** |
| busy | **ocupado** |
| free | **libre** |
| working hours | **horario laboral** |
| weekly hours | **horario semanal** |
| date override | **excepción de fecha** |
| minimum notice | **antelación mínima** **[DECIDED]** (never `aviso mínimo`, which reads as "minimum notification") |
| booking window / advance booking (how far ahead) | **antelación máxima** **[DECIDED]** (never `periodo de reserva`, which reads as the length of a booking) |
| lead time | **antelación** |
| per day / per week | **al día** / **a la semana** |
| no-show | **ausencia** |
| waiting room / lobby | **sala de espera** |
| join (a meeting) | **unirse a** |
| copy link | **copiar enlace** |
| share | **compartir** |
| embed | **insertar** |
| webhook | **webhook** (kept) |
| two-factor authentication | **autenticación de dos factores** |
| app password | **contraseña de aplicación** |
| connect / disconnect (an integration) | **conectar** / **desconectar** |
| sync (verb / noun) | **sincronizar** / **sincronización** |
| failed | **falló** (event) / **fallida** (state) |
| retry | **reintentar** |
| required | **obligatorio** **[DECIDED]** (never `requerido`, an English calque) |
| optional | **opcional** |
| save changes | **guardar los cambios** |
| unsaved changes | **cambios sin guardar** |
| delete / remove | **eliminar** / **quitar** |
| default | **predeterminado** **[DECIDED]** (never `por defecto` in UI labels) |
| custom | **personalizado** |
| preview | **vista previa** |
| upgrade (plan) | **mejorar el plan** |
| subscription | **suscripción** |
| invoice | **factura** |
| free trial | **prueba gratuita** |
| double booking | **dos reservas a la misma hora** (never `reserva duplicada`, which means the same booking twice) |
| health check (of an integration) | **revisión automática** (never `comprobación de estado`) |
| transactional email | **correo automático** |
| approve (a booking request) | **aprobar** (never `aceptar`, which is the guest's own yes) |
| reCAPTCHA score | **puntuación** **[DECIDED]**, as in Google's own Spanish reCAPTCHA documentation (`developers.google.com/recaptcha/docs/v3?hl=es-419`, «Interpreta la puntuación») |

**Month names (lowercase):** enero · febrero · marzo · abril · mayo · junio · julio ·
agosto · septiembre · octubre · noviembre · diciembre

**Weekdays (lowercase):** lunes · martes · miércoles · jueves · viernes · sábado · domingo

**Weekday abbreviations:** lun · mar · mié · jue · vie · sáb · dom

### Third-party UI labels: never guess

When a setup instruction tells the user to click something in another company's product, the
label must match what that product actually shows in Spanish. Invent one and the user hunts
for a menu item that does not exist. Every entry below was read off the vendor's own Spanish
surface, not translated.

| Context | English | Spanish | Source |
|---|---|---|---|
| Apple, web (`account.apple.com`) | Sign-In and Security | **Inicio de sesión y seguridad** | `support.apple.com/es-es/102654` |
| Apple | App-Specific Passwords (menu label) | **Contraseñas específicas para apps** | same |
| Apple | app-specific password (running prose) | **contraseña específica para la app** | same |
| Apple | *Generate* an app-specific password | **Generar** (Apple's own verb) | same |
| Nextcloud | Personal settings | **Ajustes personales** | Nextcloud `settings/l10n/es.json` |
| Nextcloud | Security | **Seguridad** | same |
| Nextcloud | Settings | **Ajustes** | Nextcloud `core/l10n/es.json` |
| Nextcloud | App password | **Contraseña de aplicación** | same |
| Nextcloud | Administration settings | **Configuraciones de administración** | Nextcloud `apps/settings/l10n/es.json` |
| Nextcloud | Login (sign-in field) | **Nombre de usuario** | Nextcloud `core/l10n/es.json` |
| Nextcloud Talk | Lobby | **Sala de espera** | Nextcloud Talk `l10n/es.json` |
| Nextcloud Talk | Conversation · Public conversation · Moderator | **Conversación** · **Conversación pública** · **Moderador** | same |

Note the deliberate inconsistency: Nextcloud's own Spanish says **Ajustes**, while our UI
says **configuración**. Inside a Nextcloud navigation path we use Nextcloud's word, because
the user is reading Nextcloud's screen, not ours. Do not harmonise these.

Apple has renamed "Apple ID" to "Apple Account" and its Spanish page now says
**cuenta de Apple**, never "Apple ID". Our source strings still say "Apple ID", so the
Spanish keeps **Apple ID** until the English is updated, as the German catalogue does.

mailbox.org: **[OPEN]**, see section 9.

### Sample and placeholder values

- **Localise prose-shaped samples:** `yourname` → `tunombre`, `your-username` →
  `tu-usuario`, `e.g. Jane Smith` → a Spanish name (`p. ej. Ana García`).
- **Keep format-shaped samples verbatim:** email addresses (`your.email@example.com`), URLs
  and hosts (`https://caldav.example.com`), API keys (`your-api-key-here`), anything
  `example.com`. These are formats, not words.

**Common UI labels:** Save→Guardar · Continue→Continuar · Back→Atrás · Next→Siguiente ·
Submit→Enviar · Done/Finish→Listo · Add→Agregar · Close→Cerrar · Skip→Omitir ·
Got it→Entendido · Welcome→Te damos la bienvenida (never `Bienvenido`, which assumes a
gender) · Required fields→Campos obligatorios · Select→Seleccionar ·
Privacy Policy→Política de privacidad · Terms of Service→Términos del servicio ·
Enabled/Disabled→Activado/Desactivado · Analytics→Analítica · Loading…→Cargando… ·
Search→Buscar · Edit→Editar · Copy→Copiar.

---

## 3. DO NOT TRANSLATE: keep verbatim

**Tymeslot** (no hyphenated compounds in Spanish: write `cuenta de Tymeslot`, not
`Tymeslot-cuenta`), Stripe, Stripe Checkout, Stripe Connect, reCAPTCHA, Google,
**Google Calendar**, Google Meet, GitHub, Outlook, Microsoft Teams, Zoom, CalDAV, Nextcloud,
Nextcloud Talk, iCloud, Fastmail, Zimbra, Radicale, mailbox.org, MiroTalk, Keycloak,
Authentik, Lemonldap, JavaScript, OAuth, OIDC, SSO, Oban, UTM, Cloudron.

**Google Calendar stays "Google Calendar" in Spanish.** Unlike Brazilian Portuguese, where
Google ships the product as "Google Agenda", Google's Spanish surfaces keep the English
name. Do not write `Google Calendario` or `Google Agenda`.

Loanwords kept as-is: webhook, slug. Lowercase in running prose, since Spanish does not
capitalise common nouns. The dashboard is **panel** in running text. The reCAPTCHA value
is **puntuación** (section 2), not `score`.

**Environment-variable and config names verbatim**, always: `REGISTRATION_ENABLED`,
`PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `RECAPTCHA_SITE_KEY`, `GITHUB_CLIENT_ID`,
`OAUTH_*`, and the rest.

---

## 4. PLACEHOLDERS, MARKUP, TYPOGRAPHY

**Placeholders `%{name}` (the hard rule):**
- Reproduce **byte-for-byte**. Never translate, rename, add, or drop one.
- If the msgid has three placeholders, the msgstr has exactly those three.
- You **may and should reorder** them to fit Spanish syntax:
  - `"%{month} %{day}, %{year}"` → `"%{day} de %{month} de %{year}"`
  - `"You're booking a %{duration} meeting with %{name}"` →
    `"Vas a reservar una reunión de %{duration} con %{name}"`
- Spanish date idiom: **`%{day} de %{month} de %{year}`**, month lowercase, both `de`
  present. Never `%{day} %{month} %{year}`.
- **No article in front of an interpolated time.** Spanish needs `a la 1:00` but
  `a las 2:00`, and the translation cannot know which hour arrives. Write
  **`%{date}, %{time}`** for "%{date} at %{time}", and rephrase sentences so the time
  follows a colon or a comma: `"Horario anterior: %{time}."`, not
  `"Antes estaba prevista para las %{time}."` **[DECIDED]**
- A build gate checks this. A dropped placeholder silently loses its value; an invented one
  is a runtime crash in this locale only.

**Markup / entities:** keep verbatim inside the msgstr.
- `"<strong>removed from your external calendar</strong>"` →
  `"<strong>se quitó de tu calendario externo</strong>"`
- `&` stays literal (not `&amp;`). Bullets `•`, checkmarks `✓`, emoji are preserved.

**Typography (use these characters):**
- **Opening `¿` and `¡` are mandatory.** Every question takes `¿…?`, every exclamation
  `¡…!`. Omitting them is the single most visible mark of a machine-translated Spanish
  catalogue. `"Cancel this meeting?"` → `"¿Cancelar esta reunión?"`
- Ellipsis **`…`** (U+2026), never `...`. **No space before it**: `Cargando…`,
  `Seleccionar…`. Project convention across every domain.
- En dash **`–`** for ranges and subject-line separators.
- **No em dash `—`.** The English source has five, and an introduced one reads as
  machine-made. Use a comma, a colon, parentheses or a full stop instead. The
  catalogues contain none.
- Spanish quotes **`«…»`** (U+00AB / U+00BB), the RAE's first level. Not `"…"`, not `“…”`.
- Decimal comma: `"0.0 and 1.0"` → `"0,0 y 1,0"`.
- Thousands are grouped with a **non-breaking space** (`12 500`), as the RAE recommends.
  Spain groups with `.` and Mexico with `,`, so either mark reads as one country, and a
  space reads as neither. The RAE leaves four-digit numbers ungrouped; the code groups
  them (`1 500`), as it does for French, Czech and Polish.
- The currency symbol follows the amount after a non-breaking space: `45,00 €`,
  `1 234,50 $` (RAE).
- **24-hour clock**: `15:00`, not `3:00 p. m.` Spanish uses both, but the 12-hour
  path in the code prints English `AM`/`PM`.
- Dates are day-first: `25/11` in compact form, `25 de noviembre de 2026` in prose,
  `noviembre de 2026` for a month heading.
- `p. ej.` (with the space) for "e.g."; `n.º` for "no."; `1.º`/`1.ª` for ordinals.
- Percent sign takes a space in Spanish: `50 %`, not `50%`. Where the msgid interpolates
  (`%{percent}%`) keep the format as the code emits it and do not add a space inside the
  placeholder.

---

## 5. PLURALS

Spanish is `nplurals=2; plural=(n != 1);`.
`msgstr[0]` = singular (n == 1). `msgstr[1]` = everything else, **including 0**.
Both must be filled. Placeholders present in a form must appear in that form.

```
msgid "hour"
msgid_plural "hours"
msgstr[0] "hora"
msgstr[1] "horas"
```

Zero takes the plural: `0 reuniones`, never `0 reunión`.

---

## 6. TONE BY REGISTER

- **Marketing**: warm, direct, plain. Not corporate Spanish, and not the inflated register
  that Spanish marketing copy falls into by default. Rephrase idioms instead of calquing
  them. Headlines must land as headlines. No tricolons, no `no solo… sino también`, no
  promises about how much better the reader's life will be. State the thing.
- **Dashboard / admin UI**: terse, functional. Buttons are infinitives or nouns
  (`Guardar`, `Agregar`). Toggle states are adjectives (`Activado`/`Desactivado`). System
  feedback is clean declarative: `"No se pudo actualizar la configuración."`
  No filler, no exclamation marks.
- **Transactional email**: polite, clear, human. Greeting `"Hola %{name}:"`.
  **Spanish salutations take a colon, not a comma**, and the following sentence therefore
  starts with a capital. That is the opposite of the German rule, and worth stating because
  the two catalogues sit side by side. `"Hola Luka:"` / `"Tu reunión se confirmó."`
  Sign-off `"Best,"` → `"Un saludo"` (no comma when it stands alone above a name).
  Apologies stay short: `"Disculpa las molestias."`, once, where it is warranted, never as
  a reflex on every error string.
- **Booking flow (public)**: friendly, guiding, unhurried. Prompts help the invitee:
  `"Elige una fecha para ver los horarios disponibles"`. Success may carry one exclamation:
  `"¡Reserva confirmada!"`. That is the only register where an exclamation mark earns
  its place.

---

## 7. NEUTRAL SPANISH: what a reader notices first

The catalogue serves Spain and Latin America from one locale (section 8), so it must not
read as either. The markers that give a text away are mostly grammatical, not lexical.

**Never, anywhere:**

| Avoid | Why | Use |
|---|---|---|
| `vosotros`, `os`, `vuestro` | Spain only | `ustedes`, `les`, `su` |
| `coger` | vulgar in much of South America | `tomar`, `seleccionar`, `elegir` |
| `ordenador` (Spain) / `computadora` (LatAm) | each marks a region | `dispositivo`, `equipo`, or rephrase |
| `móvil` (Spain) / `celular` (LatAm) | same | `teléfono` |
| `fichero` (Spain) | regional | `archivo` |
| `vale` (Spain) | regional | `de acuerdo`, `entendido` |
| `agendar` (LatAm) | regional | `programar`, `reservar` |
| `platicar` (Mexico), `charlar` (Spain) | regional | `hablar` |
| `ahorita` | regional and vague | `ahora`, `en breve` |

**Tense:** prefer the simple past (`se confirmó la reunión`) over the compound
(`se ha confirmado la reunión`). The compound perfect is the Peninsular default and sounds
foreign across most of Latin America; the simple past is unremarkable in both.

**`ajustes` vs `configuración`:** both are correct; `ajustes` is the Spain-leaning choice
(it is what Apple and Nextcloud ship there), `configuración` the broader neutral. Our UI
uses **configuración** throughout. The exception is a navigation path inside another
product, which keeps that product's word.

**Diminutives, interjections and regional warmth** stay out entirely. They read as charming
in one country and as sloppy in the next.

---

## 8. WHY `es`, AND WHY ONE VARIANT IS ENOUGH

`LocalePlug.normalize_locale/1` cannot see a region tag. It ends:

```elixir
|> String.split(["-", "_"], parts: 2)
|> hd()
```

So `Accept-Language: es-CO`, `?locale=es-MX`, `es_ES` and `es-419` all normalise to `"es"`.
Registering `es_ES` or `es_419` would produce a locale that appears in the switcher and can
never be selected by a visitor's browser: the same trap the `pt_BR` proposal hit.

One neutral `es` is therefore not a compromise forced by effort; it is the only shape the
router can actually serve. Section 7 is what makes that single variant defensible.

---

## 9. OPEN QUESTIONS

1. **mailbox.org menu path.** Four strings send the user to `Settings → Security` in
   mailbox.org. mailbox.org ships a German and an English interface; whether a Spanish one
   exists has not been verified. The catalogue keeps the English labels (`Settings →
   Security`) rather than invent a Spanish path that leads nowhere. If the maintainer
   prefers otherwise, it is four strings in `dashboard_calendar_providers`.
2. **`¡…!` in the booking flow.** Section 6 allows exactly one exclamation, on booking
   success, matching the English `"Booking confirmed!"`. If the project would rather have
   none at all, that is a one-line change here and three strings in the catalogues.

---

## 10. ONE-LINE SUMMARY

Informal **tú**, plural **ustedes**, never `vosotros` or `vos`. **reunión** (booked meeting) ·
**reserva** · **tipo de reunión** · **franja horaria** (panel) / **tiempo de horario** (guest
texts) · **la hora en que termina** · **realizarse** · **organizador** (organiser) vs
**anfitrión** (host) · **asistente** · **invitado** · **configuración**. `cancelar` always
carries its object when a meeting is meant. Months and weekdays lowercase. Opening `¿` and
`¡` are mandatory. Keep **Tymeslot / brand names / env vars / `%{…}`** verbatim. Use
`«…»`, `–` for ranges, no `—`, `…`, decimal comma, 24-hour clock,
`%{day} de %{month} de %{year}`. Simple past over compound perfect. Never drop or invent a placeholder.
