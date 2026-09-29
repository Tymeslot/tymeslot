# Polish glossary (pl)

Termbase for the Polish catalogues. Settle a term here before using a new one.

## Tone and style

- **Informal second person singular** to the signed-in user and to booking visitors:
  "twoje spotkania", "Zaloguj się", "Wybierz termin". Never "Pan/Pani", never "Państwo".
- **Lowercase pronouns**: "ty", "twój", "ci", "cię", "ciebie", capitalised only at the start
  of a sentence. The capitalised "Twój" belongs to a letter to one named person; our strings
  address an unknown reader, and Polish interfaces (Google, Apple, Microsoft) write it lowercase.
- **Drop the possessive where Polish would.** English says "your" far more often than Polish
  does: "Sesja wygasła", not "Twoja sesja wygasła"; "Wyślij gościom link", not "Wyślij gościom
  swój link". When it refers back to the subject of the sentence it must be "swój", never "twój":
  "Zmień swój adres URL".
- **Sentence case** for buttons, labels and headings: "Zapisz zmiany", not "Zapisz Zmiany".
- Imperative for actions ("Anuluj", "Zapisz"), perfective where it completes something
  ("Przetestuj połączenie", not "Testuj połączenie"); noun phrases for labels ("Nazwa użytkownika").
- **Avoid gendered forms.** We do not know the gender of the reader or of the person a
  placeholder names. Prefer, in this order: make a noun the subject ("Spotkanie zostało
  odwołane"), use the impersonal "-no/-to" form ("Podłączono Zoom", "Zapisano zmiany"), use the
  present tense ("%{name} zaprasza cię"), or a noun phrase. The bracketed "zaprosił(a)" is a
  last resort, never in a subject line or heading.
- Polish typography: „cudzysłów drukarski” where the source uses quotes; a spaced półpauza " – "
  as the dash, never an em dash; the single ellipsis character "…", never "..."; a space between
  a number and its unit ("5 MB", "1000 px"); no space before `:` `,` `.` `?` `!`.
- **Vocative comma**: "Cześć, %{name}!" / "Cześć, %{name},". No comma after a closing
  "Pozdrawiamy".
- Do not translate brand names: Tymeslot, Google, Google Calendar, Google Meet, Outlook,
  Microsoft, Microsoft Teams, Zoom, Stripe, Nextcloud, Radicale, Zimbra, Baikal, mailbox.org,
  CalDAV, iCloud, Fastmail, Slack, Telegram, MiroTalk, Jitsi, OAuth, SSO, plan names (Cloud Free,
  Cloud Pro, Self-Hosted) and theme names (Quill, Rhythm). Environment variables stay verbatim.
- "X via %{brand}" is "X · %{brand}"; "via" is not "przez".
- After "przez" or "w", give a provider or calendar placeholder a declined head noun:
  "przez konto %{provider}", "w kalendarzu %{calendar}", "Podłączono usługę %{service}".
- Example addresses use the reserved domains: "jan.kowalski@example.com", never a real
  Polish domain such as "przyklad.pl".

## Placeholders and grammatical case

A placeholder is filled with a value in the **nominative** that cannot be declined: a person's
name, a meeting type, a calendar name, a weekday, a provider. So a placeholder must never sit
where Polish needs another case, which rules out a preposition directly before it ("z %{name}",
"do %{name}", "od %{name}", "dla %{name}", "w %{calendar}") and any verb that governs the
genitive, dative or instrumental of it. Restructure instead:

- a colon, dash or parentheses: "Spotkanie potwierdzone – %{date}, %{name}",
  "Prośba wysłana (odbiorca: %{name})", "Wiadomość od uczestnika: %{name}";
- a declined head noun in front of the placeholder: "w kalendarzu %{calendar}",
  "ustawienia dnia: %{day}";
- make the placeholder the subject: "%{name} pisze:", "%{name} ma wtedy %{time}".

Numbers outside a plural entry cannot agree with a noun either, so a plain msgid with
"%{count}", "%{days}" or "%{max}" must not follow the number with an inflected noun or
adjective ("%{days} dni" breaks at 1, "%{max} terminów" at 2–4). Use an abbreviation that does not
inflect ("%{days} dn.", "%{hours} godz.", "%{minutes} min") or a label: "Maksymalna liczba
terminów: %{max}". Plural entries carry three forms: [0] for 1, [1] for 2–4 (except 12–14),
[2] for everything else; each form in the case the sentence demands (accusative after
"odśwież", genitive after "brak" and so on).

Duration strings in the `errors` domain are in the accusative, because they are only ever
inserted into "Spróbuj ponownie za %{wait}". Check every such composition before translating a
fragment: read how the code uses it.

## Dates and months

- A month **inside a date** is genitive ("5 kwietnia 2026"); that form lives in
  `LocaleFormat` and is not translated here.
- The month names in the `booking` domain ("January" … "December") are the **standalone**
  form used in calendar headings ("%{month} %{year}", month ranges): nominative and
  capitalised, "Kwiecień 2026", "Kwiecień – maj 2026".
- Weekday names are nominative; never put a preposition before a weekday placeholder.

## Core terms

| English | Polish |
|---|---|
| meeting | spotkanie |
| booking (the act/record) | rezerwacja |
| to book | zarezerwować |
| scheduling page / booking page | strona rezerwacji |
| meeting type | typ spotkania |
| slot / time slot | termin |
| availability | dostępność |
| availability schedule | harmonogram dostępności |
| working hours | godziny pracy |
| buffer | bufor |
| host / organizer | organizator |
| attendee | uczestnik |
| guest / visitor | gość |
| invitee | zaproszony |
| dashboard | panel |
| settings | ustawienia |
| profile | profil |
| username | nazwa użytkownika |
| account | konto |
| sign up | załóż konto (link/button), rejestracja (noun) |
| log in / sign in | zaloguj się |
| log out / sign out | wyloguj się |
| password | hasło |
| reset password | zresetuj hasło |
| verify / verification | potwierdź / potwierdzenie (e-mail) |
| calendar integration | integracja kalendarza |
| connect (a calendar/account) | podłącz |
| disconnect | odłącz |
| sync / synchronise | synchronizacja / synchronizuj |
| reschedule | zmień termin |
| cancel (a meeting) | odwołaj |
| cancel (an action/dialog) | anuluj |
| confirm | potwierdź |
| pending | oczekujące |
| upcoming | nadchodzące |
| past | minione |
| time zone | strefa czasowa |
| poll | ankieta |
| vote | głos / zagłosuj |
| webhook | webhook |
| embed | osadzenie / osadź |
| payment | płatność |
| payout | wypłata |
| refund | zwrot |
| price | cena |
| invoice | faktura |
| subscription | subskrypcja |
| video call | spotkanie wideo |
| meeting link | link do spotkania |
| reminder | przypomnienie |
| notification | powiadomienie |
| admin | administrator |
| owner | właściciel |
| required | wymagane |
| optional | opcjonalne |
| save | zapisz |
| delete | usuń |
| remove | usuń |
| edit | edytuj |
| reconnect | połącz ponownie |
| approve (a booking request) | zatwierdź / zatwierdzenie |
| decline (a request) | odrzuć |
| time off | nieobecność (plural "nieobecności"), never "wolne" |
| minimum notice | minimalne wyprzedzenie |
| advance booking window / how far ahead | maksymalne wyprzedzenie; "rezerwacje do %{days} dni naprzód" |
| upload | prześlij |
| delivery (webhook, message) | wysyłka |
| actions (column, menu) | akcje |
| location (of a meeting) | lokalizacja |
| localisation (language settings) | język i region |
| recommended | zalecane |
| unlisted (meeting type) | ukryty |
| permissive / strict | mniej / bardziej restrykcyjny |
| browser notification | powiadomienie w przeglądarce |
| test (a connection) | przetestuj |
| trigger (webhook) | wyzwalacz; "Last triggered" = "Ostatnie wywołanie" |
| endpoint | punkt końcowy |
| mailbox | skrzynka |
| calendar feed / free-busy feed | kanał kalendarza / kanał zajętości |
| busy times | zajęte terminy |
| conflict checking | sprawdzanie konfliktów |
| booking calendar (where bookings are written) | kalendarz rezerwacji |
| app password / app-specific password | hasło aplikacji / hasło dla aplikacji |
| occurrence (recurrence) | wystąpienie; in summaries "łącznie %{count} razy" |
| 12h / 24h clock | 12 h / 24 h |
| RSVP: going / declined / no reply | weźmie udział / nie weźmie udziału / bez odpowiedzi |
| outstanding refund | zaległy zwrot |
| payment of %{amount} | płatność w kwocie %{amount} |
| request received (booker's side) | prośba wysłana |
| security notification / alert | powiadomienie / ostrzeżenie dotyczące bezpieczeństwa |
| fingerprint (analytics) | odcisk cyfrowy |
| referrer | strona odsyłająca |
| preset (image, video) | z kolekcji |
| custom (preset value) | własna wartość |
| mark as done / not done | oznacz jako wykonane / niewykonane |
| toggle menu | otwórz lub zamknij menu |
| Slack workspace | przestrzeń robocza Slack |
| time-of-day buckets | wczesny ranek, przedpołudnie, popołudnie, wieczór, późny wieczór |
| retry / try again | spróbuj ponownie |
| loading | wczytywanie |
| failed | nie powiodło się |

## Notes

- "Cancel" a meeting or booking is "odwołaj" everywhere, the payments screens included;
  "anuluj" is only for dismissing a dialog or abandoning an action, and for a subscription.
- "Schedule" as a verb on the booking flow is "zarezerwuj", not "zaplanuj", so it matches
  "rezerwacja" everywhere else. "Zaplanuj" is reserved for automations and reminders.
- "Event" from a connected calendar is "wydarzenie"; a Tymeslot booking stays "spotkanie".
- Keep "e-mail" hyphenated (Polish spelling); "adres e-mail", not "email".
- "Link" is a Polish word now; use it rather than "odnośnik".

## Marketing and SaaS terms

| English | Polish |
|---|---|
| no-show | niestawiennictwo / niestawienie się (never "nieobecność", which is time off); no-show fee: opłata za niestawiennictwo |
| deposit / prepayment | zaliczka / przedpłata |
| discovery call / scoping call | rozmowa wstępna |
| intake form | formularz wstępny |
| self-hosting / self-host | na własnym serwerze / hostuj na własnym serwerze |
| managed cloud | zarządzana chmura |
| white-label branding | własny branding bez logo Tymeslot |
| per seat | za użytkownika |
| free plan / no card | darmowy plan / bez karty |
| Pro price | Pro (%{pro_monthly}/mies.); "/year" is "/rok" |
| trial | okres próbny |
| billing period | okres rozliczeniowy |
| upgrade to Pro | przejdź na Pro |
| cancel a subscription | anuluj subskrypcję |
| GDPR / DPA | RODO / umowa powierzenia przetwarzania danych (DPA) |
| single sign-on / identity provider | logowanie jednokrotne (SSO) / dostawca tożsamości |
| widget | widżet |

The /for profession pages price in złoty at Polish market rates, and the savings calculator's
`hourly_rate` for `pl` is a złoty figure. Tymeslot's own plan prices stay as the placeholders
give them.
