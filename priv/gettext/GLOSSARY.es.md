# Tymeslot: Spanish (`es`) Translation Style Guide & Termbase

Authoritative. Written **before** the catalogues so that every msgstr is translated
against a fixed termbase. Where this guide and a msgstr disagree, **this guide wins**.

The variety is **Rioplatense Spanish (Argentina / Uruguay)**. The directory is `es`
because `LocalePlug` reduces every request locale to its primary subtag (see
`TRANSLATING.md`); the variant is named in the language switcher instead.

---

## 1. REGISTER

**"vos" everywhere.** Booking flow, dashboard, admin and transactional email. No
exceptions, and never mixed with "tú" or "usted" in the same product.

Voseo forms, which are the whole point of the variety:

| | ✓ vos | ✗ never |
|---|---|---|
| imperative | **Elegí** un horario · **Ingresá** tu correo · **Hacé** clic · **Poné** · **Agregá** · **Revisá** · **Confirmá** · **Probá** de nuevo | Elige · Elija · Ingresa · Haz clic |
| present | **podés** · **tenés** · **querés** · **sos** · **necesitás** · **recibís** | puedes · tienes · quieres · eres |
| negative imperative | **No cierres** esta ventana · **No compartas** | No cerrés (regional, reads as slang) |
| pronouns | **vos**, **te**, **tu / tus**, **contigo** → **con vos** | ti, tú, su (for the reader) |

`tu` (possessive, no accent) is correct with voseo: *"Tu reunión fue confirmada"*.

Tone: warm and plain, like a well-run professional office. Prefer the **pretérito
perfecto simple** (*"Se canceló la reunión"*, *"Te enviamos un correo"*) over the
compound past (*"Se ha cancelado"*), which reads Peninsular.

### Grammatical gender

Tymeslot never knows the reader's gender. In order of preference:

1. **Rewrite around it.**
   - `"Welcome!"` → **"¡Te damos la bienvenida!"** (not *¡Bienvenido!*)
   - `"You're invited"` → **"Tenés una invitación"** (not *Estás invitado*)
   - `"Are you sure?"` → **"¿Querés continuar?"** / **"¿Confirmás?"**
2. **Prefer gender-free nouns** for people: *participante*, *persona*, *cliente*.
3. **Only where 1 and 2 fail**, use the masculine as grammatical default
   (*invitado*, *anfitrión*).

**Never** use `@`, `x` or `e` as inclusive endings (*invitad@*, *invitadxs*, *invitades*).

### Spanish punctuation

- Opening marks are mandatory: **¿…?** and **¡…!**
- Months and weekdays are **lowercase**: *lunes 20 de octubre*.
- Sentence-case headings and buttons: *"Tipos de reunión"*, not *"Tipos De Reunión"*.

---

## 2. GLOSSARY

| English | es (AR) | Note |
|---|---|---|
| **meeting** (the product noun) | **reunión** | The default. |
| **meeting type** | **tipo de reunión** | Never *tipo de evento* (that is Calendly's wording). |
| **booking** (the record) | **reserva** | The thing in the list. |
| **to book** | **reservar** | *"Reservá un horario"*. **agendar** is acceptable in prose where *reservar* reads stiff (*"agendar una reunión"*). |
| **booker** | **quien reserva** | Relative clause avoids gender. |
| **booking page** | **página de reservas** | |
| **booking flow** | **proceso de reserva** | |
| **appointment** (public booking flow) | **turno** | Argentina's everyday word; kept distinct from *reunión* on purpose. |
| **event** (external calendar entry; webhook event) | **evento** | |
| **host** | **anfitrión** | §1 rule 3 applies; rewrite when possible. |
| **organizer** | **organizador** | |
| **attendee** | **participante** | Gender-free; prefer it. |
| **guest** · **invitee** | **invitado** | Same word for both. |
| **slot** / **time slot** | **horario** | *"Se liberó el horario"*. Never *espacio* or *franja*. |
| **buffer** (between meetings) | **margen** | *"Margen entre reuniones"* · *"Sin margen"*. Not *intervalo* (reserved for *interval*). |
| **interval** | **intervalo** | *"Intervalo entre horarios"*. |
| **group booking** | **reserva grupal** | |
| **seat** / **spot** (in a group slot) | **cupo** | *"3/10 cupos ocupados"*. The slot stays **horario**. |
| **participant limit** | **límite de participantes** | |
| **availability** | **disponibilidad** | |
| **available times** | **horarios disponibles** | |
| **schedule** (a named availability set) | **agenda** | Known collision with the calendar's Agenda view, same as `pt`; decide both together. |
| **reschedule** | **reprogramar** | Noun: **reprogramación**. |
| **reschedule request** | **solicitud de reprogramación** | |
| **cancel** | **cancelar** | |
| **decline** (a request) | **rechazar** | |
| **minimum notice** | **anticipación mínima** | Always with *mínima*. |
| **booking horizon** (how far ahead) | **límite de anticipación** | Never *ventana de reserva* (the *ventana* is the pop-up embed). |
| **time off** | **ausencia** | Never *margen* (that is the buffer). |
| **location** / **venue** | **ubicación** | Never *lugar*, which collides with seats in everyday speech. |
| **in person** | **presencial** | |
| **phone call** | **llamada telefónica** | |

### Extended termbase

| English | es (AR) |
|---|---|
| account | cuenta |
| dashboard | panel |
| settings | configuración |
| profile | perfil |
| user · username | usuario · nombre de usuario |
| password | contraseña |
| app password / app-specific password | contraseña de aplicación / contraseña específica de la app |
| sign in · log in | iniciar sesión (button: **Ingresar**) |
| sign up | crear cuenta |
| sign out · log out | cerrar sesión |
| email (noun) | **correo electrónico** in labels; **correo** in running text |
| link | **enlace** |
| team · member | equipo · integrante |
| workspace (Slack) | espacio de trabajo |
| calendar | calendario |
| timezone | zona horaria |
| duration | duración |
| reminder | recordatorio |
| notification | notificación |
| payment · refund · invoice · receipt | pago · reembolso · factura · comprobante |
| integration | integración |
| embed (verb / noun) | insertar / inserción (*"código para insertar"*) |
| upload | subir |
| delete · remove | eliminar · quitar |
| save | guardar |
| custom | personalizado |
| recurring | recurrente |
| required (field) | obligatorio |
| enabled / disabled | activado / desactivado |
| confirmed · pending | confirmada · pendiente (agree with *reunión* / *reserva*) |
| overview | resumen |
| analytics | estadísticas |
| plan (Pro, Free) | plan |
| lobby (Nextcloud Talk) | sala de espera |
| registration (the record or process) | registro |
| withdraw (a request) | retirar |
| attend · make it | asistir · participar |
| acknowledge (a notice) | **entendido** · *"Leí y entiendo"*; never *acepto*, which adds consent |
| Action required | Acción necesaria |
| If need be (poll answer) | Si hace falta |
| Early Morning · Late Night (0–5h · 21–24h) | Madrugada · Noche |
| fallback language | idioma predeterminado |
| busy time(s) | horarios ocupados |
| stored credentials | credenciales guardadas |
| decrypt | descifrar |
| reset (a link, a password) | restablecer |
| linked (account) | vinculada |
| upcoming | **Próximas** as a label; *futuras* in an empty state |
| deployment (a self-hosted install) | instalación |
| preset (background image or video) | opción de la colección |
| guest status Going · Declined | Asiste · No asiste |
| Wk (week, abbreviated) | Sem. |
| self-hosted · self-hosting | autoalojado · autoalojamiento; *to self-host* → **alojar en tu propio servidor** |
| two-way sync | sincronización bidireccional |
| free/busy | libre/ocupado |
| payout | transferencia (Stripe: *transferencias a tu cuenta bancaria*) |
| payout schedule (Stripe) | calendario de transferencias |
| custom domain | dominio propio |
| outstanding (refund) | pendiente |
| subscription · subscribe | suscripción · suscribirse |
| trial | período de prueba |
| upgrade (to Pro) | pasarse a Pro · *"Pasate a Pro"* |
| white-label | marca blanca |
| deposit (payment) | seña |
| no-show | inasistencia |

### Settled during the first translation pass

| English | es (AR) |
|---|---|
| host (as a person, in prose) | **quien organiza** (gender-free); *anfitrión* only as a field label |
| poll · candidate time · winner | encuesta · horario propuesto · ganador |
| booking request · reschedule request | solicitud de reserva · solicitud de reprogramación (never *pedido*) |
| tentative hold | reserva provisoria |
| occurrence (of a recurring series) · series | repetición · serie |
| break (in a working day) | pausa |
| date overrides | excepciones por fecha |
| double booking | reservas superpuestas |
| buffer before / after | margen previo / margen posterior |
| popup modal (embed) | ventana emergente |
| platform fee · processing fees · charge | comisión de la plataforma · comisiones de procesamiento · cobro |
| dispute (Stripe) | disputa |
| expired (status) | vencida |
| display name | nombre visible |
| Reconnect (button) | **Reconectar** everywhere; *volver a conectar* only in running prose |
| Please try again | Volvé a intentarlo |
| invalid | no válido (never *inválido*) |
| Failed to … | No se pudo … |
| promote / demote (admin) | hacer administrador / quitar el rol de administrador |
| trigger (webhook) · delivery · logs | disparador · entrega · registros |
| meeting agenda (prep checklist) | temario (not *agenda*, which is the schedule) |
| sign up (in prose) | crear tu cuenta |

**Settings flash messages** put the name after a colon, *"Configuración activada: %{name}."*,
so the participle agrees with *configuración*, never with `%{name}`.

**Common UI labels:** Save→Guardar · Continue→Continuar · Back→Volver · Next→Siguiente ·
Submit→Enviar · Done / Finish→Listo / Finalizar · Add→Agregar · Close→Cerrar ·
Skip→Omitir · Got it→Entendido · Required fields→Campos obligatorios ·
Select→Seleccionar · Learn more→Más información · Try again→Volver a intentar ·
Copy→Copiar · Copied→Copiado · Privacy Policy→Política de privacidad ·
Terms of Service→Términos del servicio · Search→Buscar · Loading…→Cargando… ·
Optional→Opcional · Edit→Editar · Cancel→Cancelar · Confirm→Confirmar.
Done as a status (finished checklist item) → **Completado**. Buttons use the
infinitive (*Guardar*, *Elegir otro horario*, *Votar*); instructions in prose use the
voseo imperative (*"Elegí otro horario desde el enlace"*).

### Third-party UI labels: never guess

When a string tells the reader to click something inside another company's product,
the label must be what that product shows **to a Spanish-speaking user**. Where the
Spanish label is not certain, **keep the vendor's English label verbatim** and write
the surrounding sentence in Spanish: *"…generá una contraseña en Settings → Security…"*.
An invented menu name sends the reader looking for words that are not on screen.

### Sample and placeholder values

- Localise prose-shaped samples: `yourname` → `tunombre`, `e.g. Jane Smith` →
  `ej.: Ana Pérez`.
- Keep format-shaped samples verbatim: e-mail addresses, URLs and hosts, API keys,
  anything at `example.com`.

### Data protection (firm rule)

**Never claim compliance** with Argentina's Ley 25.326 or any other national law the
English does not name. *GDPR* stays *GDPR* (or *RGPD* nowhere: keep the English
acronym the product uses).

---

## 3. DO NOT TRANSLATE

**Tymeslot** (*"cuenta de Tymeslot"*, *"panel de Tymeslot"*), Stripe, Stripe Checkout,
Stripe Connect, reCAPTCHA, Google, Google Calendar, Google Meet, GitHub, Outlook,
Microsoft Teams, Zoom, CalDAV, Nextcloud, iCloud, Fastmail, Zimbra, Radicale,
mailbox.org, MiroTalk, Keycloak, Authentik, Lemonldap, JavaScript, OAuth, OIDC, SSO,
Oban, UTM, Cloudron, Jitsi, Jitsi Meet, kMeet, Infomaniak, Nextcloud Talk. Jitsi's
**App ID** and **App secret** stay verbatim.

Loanwords kept: **webhook**, **slug**, **plugin**, **app**, **feed**, **token**, **widget**.

Environment-variable and config names verbatim: `REGISTRATION_ENABLED`,
`PASSWORD_AUTH_ENABLED`, `STRIPE_SECRET_KEY`, `OAUTH_*`, and friends.

---

## 4. PLACEHOLDERS, MARKUP, TYPOGRAPHY

- `%{name}` placeholders are reproduced **byte-for-byte**; never translate, rename,
  add or drop one. **Reorder** them for Spanish syntax:
  `"%{month} %{day}, %{year}"` → `"%{day} de %{month} de %{year}"`.
- **Fragments** filled into other strings: read the call site and translate for the
  assembled sentence (`"%{hour_text} %{minute_text}"` → `"%{hour_text} y %{minute_text}"`).
- **`{{meeting_id}}`** in `integrations_video` / `dashboard_integrations` is literal text
  the reader types. Reproduce every one byte-for-byte, including the deliberately wrong
  forms the error messages quote (`{{MEETING_ID}}`, `{{meeting-id}}`, `((meeting_id))`).
- Markup and entities verbatim: `<strong>…</strong>`, literal `&`, `•`, `✓`, emoji.
- Ellipsis **`…`** (U+2026), no space before it: *Cargando…*.
- En dash **`–`** for ranges (*14:00–15:00*).
- 24-hour clock: **14:30**, never *2:30 p. m.*
- Numbers: **1.234,50** (dot for thousands, comma for decimals).

## 5. PLURALS

`nplurals=2; plural=(n != 1);` — `msgstr[0]` for n == 1, `msgstr[1]` for everything
else, including 0:

```po
msgid "%{count} hour"
msgid_plural "%{count} hours"
msgstr[0] "%{count} hora"
msgstr[1] "%{count} horas"
```
