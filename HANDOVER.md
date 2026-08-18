# CalDAV alarms and recurrence: the underlying problems

This document explains the structural problems found while reviewing the `caldav-alarms-recurrence` branch. It describes the problems themselves, not the work done against them. Each section states the mechanism, why it matters, and where it shows up.

The branch's two original commits (reading VALARM reminders back from CalDAV and ICS, and including long-running and monthly recurring events in availability) are both small and locally correct. Nearly every problem below predates them. They surfaced because these two commits were the first changes to lean on the surrounding machinery hard enough to expose what it could not carry.

## 1. The provider write model assumes Tymeslot knows the whole event

### 1.1 A full replace built from a payload we assemble

The CalDAV write is a full VEVENT replace: the document is rebuilt from `event_data` via `ICalBuilder.build_simple_event/2`, and each property line is emitted only when its key is present in the map. Any key the caller omits is therefore deleted from the user's calendar server. Google's `events.update` behaves the same way.

The consequence is an invariant: an update payload must describe the complete event. That invariant is real, load-bearing, and was enforced nowhere except by hand-written map literals inside the web layer. Seven of them, in `edit_workflow/updates.ex` and `moves.ex`.

Two of those literals omitted `:attendees` and `:recurrence_rule`. Renaming an event, or toggling it to all-day, therefore deleted its attendees and its recurrence rule from the user's server. The literals that did carry those fields did so by coincidence of who wrote them, not by construction.

### 1.2 The premise itself is wrong

The deeper problem is that "the payload must be complete" is unachievable. Completeness can only ever mean complete with respect to what Tymeslot models. Everything else in the user's own VEVENT is destroyed on every write: `CATEGORIES`, `ATTACH`, `GEO`, `RELATED-TO`, `X-` properties, VALARM `REPEAT` and `DURATION`, per-attendee parameters, an embedded `VTIMEZONE`.

This produces a treadmill. Each time the loss of a property is noticed, that property is added to the model so the rebuild stops eating it. The VALARM read-back in this branch is one lap of exactly that treadmill: reminders were being destroyed by every unrelated edit, so reminders became modelled. The next unmodelled property will require the next lap, and nothing in the design converges.

The bounded alternative already existed in the codebase and was used for exactly one field. `ICalBuilder.replace_colour_property/2` patched the authoritative `raw_ical` last read from the server, rewriting one property and leaving the document otherwise untouched. The colour write-back path used it; nothing else did.

The reason it could not generalise is that the choice between patching and replacing was encoded as a magic key inside the data (`colour_only: true`), dispatched on at the provider layer. A write mode is not a property of an event. Encoding it as one means every provider has to recognise and strip the control keys before writing, and the strip lists drift: the CalDAV path dropped `[:mode, :raw_ical, :etag, :provider_event_id]` while the Google path dropped `[:mode, :calendar_id, :provider_event_id, :raw_ical, :etag]`. A domain field named `etag` would be silently swallowed as control metadata.

### 1.3 Patching against lines rather than components

iCalendar is a tree, not a list of lines. A VEVENT contains VALARMs; a VCALENDAR contains several VEVENTs when a recurring series has modified occurrences; a VTIMEZONE contains STANDARD and DAYLIGHT blocks. Nested components reuse their parents' property names. `DESCRIPTION` and `SUMMARY` are both event properties and alarm properties, and RFC 5545 §3.6.6 requires `DESCRIPTION` on a DISPLAY alarm. `DURATION` is both an event property and an alarm property.

Any edit that selects lines by property name alone therefore has to know which component a line belongs to. A patcher that treats the document as flat will, when asked to change the event's description, delete the description of every alarm in the document, and when asked to change the title, write that title into every VEVENT in the resource, including the per-occurrence overrides whose distinct titles are the only reason they exist.

This is a particularly sharp failure because the patch path exists solely to preserve properties that a full replace would destroy. A flat patcher destroys them by a different route, and does so while reporting success.

The same document tree had already been modelled once, on the read side, in this very branch: `ICalParser.split_nested_components/1` tracks nesting depth precisely so that a VALARM's `DESCRIPTION` cannot be mistaken for the event's. The write side had no equivalent.

### 1.4 The capability is declared in several places at once

"Which fields can be written without a full replace" is one policy. It was stated independently in the write-mode decision, in the iCal patcher, and in the Google patch body builder, each unaware of the others, and none of them validated against the caller.

The failure mode is silence. A patch payload carrying a field no patcher understands is not rejected: the provider writes the keys it recognises, ignores the rest, and returns success. The cache row is then updated to claim a change the server never received. Adding a patchable field requires coordinated edits in three places, and missing one drops the edit rather than raising.

## 2. The recurrence model was forked, then forked again

### 2.1 Two parsers with different vocabularies

The RRULE concept was modelled twice. `Recurrence.RRule` (`by_day: [:mo, :tu]`, no ordinals, no WKST) served the recurrence editor, the event detail summary, the iCal builder and the Outlook converter. `RecurrenceExpander.parse_rrule/1` was a second, private grammar (`by_day: [{ordinal, :monday}]`) used for availability expansion.

Teaching only the second one about ordinals, as the availability fix required, produced a system that understood `FREQ=MONTHLY;BYDAY=1MO` for the purpose of deciding whether a slot was free, and misunderstood it everywhere else. The detail modal rendered the wrong summary, the Outlook converter dropped the ordinal on conversion, and opening the rule in the editor and saving any change rewrote it into a plain day-of-month series.

Two implementations of one grammar means every future RFC fix must be applied twice, in two different weekday vocabularies, or the two answers drift further apart. There were in fact four implementations: `VTimezone` carried a third private RRULE and BYDAY parser, and `ICalBuilder` carried a fourth, legacy RRULE serialiser.

### 2.2 A lossy shared model forces the fork to persist

Consolidating on one parser is only possible if that parser's model is rich enough for every consumer. It was not. `RRule.parse/1` returned `until` as a bare `Date`, because the editor's UNTIL picker is date-only, while the expander needs the wall-clock time to compare candidate occurrences against UNTIL to the second, as RFC 5545 §3.3.10 requires.

A parser that discards what one consumer needs does not become the single authority by being declared one. The consumer simply re-parses the raw string to recover the field, and the result is worse than the original fork: one visible parser plus one invisible parser handling a single token, where a change to UNTIL handling in the shared module reaches only half the system and nothing fails.

### 2.3 The editor narrows every rule it cannot draw

Widening `by_day` to carry ordinals across the domain was correct. The recurrence editor, however, destructured a parsed rule into individual form assigns and rebuilt the RRULE from those assigns alone. Anything with no corresponding control was therefore unrecoverable by construction, not by oversight.

The user-visible result: open a `FREQ=MONTHLY;BYDAY=1MO` event, change the interval, save, and the rule now means something different. The ordinal is gone. The same applies to `WKST`, and will apply to every BYxxx part the shared parser learns in future.

The structural problem is the absence of any place to keep "the parts of this rule the editor does not own". A form that rebuilds from its own controls can only ever emit the subset it can draw.

### 2.4 A form-shaped model placed in the domain

The natural fix, folding a partial edit onto the parsed rule so unmodelled parts survive, is a genuine domain invariant and belongs in the domain. What does not belong there is the vocabulary of one HTML form: reading `params["freq"]` as a raw string, emitting `end_type: "count" | "until" | "never"` for a radio group, defaulting a count to 10 because that reads well in a number input, and exposing a predicate whose only purpose is deciding whether a modal renders its controls.

Placing that in a domain namespace shared with provider sync means the domain churns whenever the modal's markup changes, and a second surface (an API, a different editor) must either speak this modal's form vocabulary or fork the one valuable part.

## 3. Boundaries that exist in documentation but not in code

### 3.1 The context façade is routed around

`Tymeslot.Integrations.Calendar` and its sibling `Calendar.Events` are documented as the entry point to the calendar domain. Several things callers need are not on that façade, so callers reach past it into internals.

`Calendar.Operations` is documented as existing solely to implement the behaviour interface for testing and configuration compatibility, that is, as an adapter. It had become a de facto second public API. `ColourWriteBack`'s own moduledoc states that it is the enqueue mechanism behind `set_event_colour/3` and explicitly not a public entry point, and a foreign context called it directly.

The concrete cost is that calls routed through `Events` are swappable at the test seam and calls routed around it are not, so the two halves of a single write flow behave differently under test. A comment in `EventMove` admitted the crossing outright, noting that the 3-arity `delete_event/3` is not exposed on the public API. A comment explaining why a boundary is crossed is evidence that the boundary is drawn in the wrong place.

### 3.2 One vocabulary map feeding two incompatible schemas

A single `changes` map was passed both to the provider payload builder (provider vocabulary: `start_time`, `end_time`, `all_day`) and to the cache row builder (cache vocabulary: `start_at`, `end_at`, `start_date`, `end_date`, `status`, `synced_at`). It worked only because the fields in use at the time happened to be spelled identically in both.

Expressing a timing edit as a delta would therefore update the cache row and produce a provider payload carrying a key no provider reads: a silent no-op write, no error, no failing test, and a cache that disagrees with the server. The design had already collided with this: the timing edit path could not use the delta channel for the very thing it exists to change, so the web layer pre-applied its edit onto an event struct and passed an empty delta instead.

### 3.3 A test seam that covers only part of the API it fronts

The façade is only partly swappable. Most functions route through a configurable behaviour module; the two functions with no analogue on that behaviour call the runtime directly. The effect lands hardest on the delete-then-create move flow, where under test the delete reaches the real runtime while the create reaches the mock, so the most safety-critical path (source deleted, destination create failed) cannot be exercised coherently.

A third mechanism exists alongside these two: a separate configuration key used by the create path so that one test can drive the real provider. Three seams, plus a set of functions that escape all of them, is the same pressure surfacing repeatedly. As more orchestration correctly moves out of the web layer and into domain modules, more of it becomes untestable in isolation for this reason.

## 4. Grammars and limits duplicated or mis-scoped

### 4.1 The ISO 8601 duration grammar in two places

RFC 5545 §3.3.6 durations were parsed by two implementations a few hundred lines apart in the same pipeline: one for an event's own `DURATION` property, and a second, newer one for VALARM `TRIGGER` durations. TRIGGER durations and DURATION properties are the same production in the same specification.

The second implementation was written because the shared one handled neither a leading sign nor the combined form (`P1DT2H`). That is a capability gap in the shared parser, and duplicating the grammar to work around it guarantees the two copies answer differently on some input while leaving no signal as to which is authoritative.

### 4.2 A safety cap sized against one caller

The expander's cap on how many occurrences a single call may return was a fixed constant, sized against the widest window then in use and documented only by a comment warning that it must stay comfortably above the largest legitimate expansion, or it stops being a guard and becomes a correctness bug.

There are three call sites, each supplying its own window. A future caller with a wider window silently re-creates the truncation this branch set out to fix, and the failure is invisible: occurrences are simply missing, so time that is busy appears free.

## 5. What remains genuinely hard

Two items resist a surgical fix and should be treated as their own pieces of work rather than folded into a review pass.

Extending patch coverage beyond text properties is blocked on serialisation, not on structure. Patching timing means writing `DTSTART` and `DTEND` with correct TZID handling and the all-day DATE form, and patching reminders means rewriting VALARM subcomponents. Getting either wrong produces exactly the silent corruption the patch path exists to prevent, so it needs its own design and test pass against real-world documents.

Unifying the create path onto the façade is blocked on the test seam described in 3.3, not on the call itself. The create path already calls a function the façade exposes with an identical signature; it uses a separate configuration key because one test relies on that key to exercise the real provider while the global seam is mocked for the whole suite. Resolving it means giving the behaviour a per-test opt-in rather than adding a third global mechanism, and that change touches an existing test's intent, so it belongs in its own commit.
