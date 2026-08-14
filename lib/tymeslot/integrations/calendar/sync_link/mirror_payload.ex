defmodule Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload do
  @moduledoc """
  Builds the event payload for a placeholder: when the source event is, under
  whatever the link's privacy tier permits to be said about what it is.

  ## Why this is a module rather than a map literal in the engine

  Everything omitted here is omitted on purpose, and each omission is a privacy
  decision rather than an oversight. Keeping them in one place means the list
  can be read as a list — description, location, attendees, conferencing,
  reminders, colour, all absent — instead of being inferred from the absence of
  keys in a map built inline. `busy_only` is the tier the organiser gets by
  default, so a field that leaks here leaks for everyone.

  Attendees are the sharpest of those. Copying an attendee list onto a second
  calendar does not merely disclose it: Google and Outlook both send invitations
  for attendees on an event they receive, so a placeholder carrying them would
  email the organiser's colleagues from a calendar they have never heard of. No
  privacy tier ever copies attendees, and `busy_only` copies nothing at all.

  ## The three tiers

  The tier decides how much of the source's *content* travels; it never decides
  the timing, the opacity or the UID, which are what make the placeholder a
  placeholder and are identical at all three.

  | Tier | Content |
  | --- | --- |
  | `busy_only` (default) | the title "Busy", and nothing else |
  | `generic_label` | the link's `generic_label` as the title, and nothing else |
  | `full_passthrough` | title, description and location |

  Attendees and conferencing details are absent from all three, including
  `full_passthrough`, for the reason above: on Google and Outlook they are not
  data but an instruction to send mail. "Full" names the tier's position on the
  privacy ladder, not a promise to copy every field, and the two are worth
  keeping apart — the tier is chosen in a settings form by an organiser reading
  its label, who would not expect the option they picked for their own
  convenience to mail their colleagues.

  A `generic_label` tier whose label is blank or missing renders as `busy_only`
  rather than as an empty title. An empty summary is not a neutral placeholder:
  Google and Outlook both substitute their own wording for a titleless event
  ("(No title)"), so a link half-configured through the form would silently
  produce a *different* placeholder than either tier describes.

  ## The two overrides, and why they live here

  Two properties of the *source* beat the link's tier:

  - `visibility` of `private` or `confidential` degrades any tier to the
    `busy_only` rendering. The organiser marked the event private on the
    calendar it lives on, and that marking is about the event, not about any one
    link; a per-link setting must not be able to overrule it. It is applied by
    rewriting the tier before the payload is built rather than by stripping
    fields afterwards, so there is one place a title can be chosen and no path
    where a real summary is put into a map and then hopefully removed.
  - `transparency` of `transparent` produces no mirror at all — but that
    decision is *not* made here, because a payload builder can only answer
    "what would this look like", never "should this exist". It belongs to
    `SyncLink.Eligibility.mirror_source?/3`, which already refuses transparent
    events, and to the write-back worker, which withdraws a placeholder whose
    source has stopped being eligible rather than discarding the job. Repeating
    the rule here would give it two homes that can disagree, and the one here
    would be the one nobody remembers to update.

  ## Why the recurrence rule arrives as an option

  A recurring source is mirrored as one recurring placeholder the target expands
  itself, so the payload has to carry an RRULE — and the one field it must *not*
  read for that is the source's own `recurrence_rule`.

  Under `singleEvents=true` the cached row for a series is an expanded instance,
  and `upsert_batch/1` keeps the last of them. Its rule is whatever that final
  occurrence carried, and its times are the final occurrence's times. Building
  from it produces one busy block in December for a series that has been running
  since March. The trustworthy rule comes from the series master, which
  `SyncLink.RecurringSeries` fetches, and it reaches this module as an option
  because a payload builder cannot make a provider call — it answers "what would
  this look like", and fetching would make it answer "what is true right now",
  which is the engine's question.

  Reading `source.recurrence_rule` here would be a one-word change that silently
  reintroduces the bug, which is exactly why the field this module reads is not
  that one.

  The rule does not vary by tier. A series is a property of the *timing*, like
  the start and the opacity, and every tier mirrors the timing faithfully — a
  `busy_only` placeholder that blocked one Tuesday instead of all of them would
  be wrong rather than private.

  ## The exception lines, and why they are not `recurrence_exceptions`

  The master's `EXDATE` lines arrive the same way and for the same reason, and
  they are what stops a *cancelled* occurrence from blocking time: a placeholder
  built from the rule alone keeps blocking every Tuesday the rule names,
  including the ones the organiser has already called off.

  They are carried under `:recurrence_exception_lines` rather than the obvious
  `:recurrence_exceptions` because that name is already taken, by a field of a
  different type. `CalendarEvent` and `ProviderCalendarEventSchema` both carry
  `recurrence_exceptions` as a `[Date.t()]`, and `ICalBuilder.Properties`
  `build_exdate/1` consumes that form — matching on `%Date{}` and `%DateTime{}`
  to emit a value type matching DTSTART. What travels here is a `[String.t()]`
  of whole iCalendar property lines, kept verbatim from the master because
  `RecurringSeries` reads them off the raw provider body. Putting a list of
  strings under the name that means a list of dates would reach `build_exdate/1`
  as a `FunctionClauseError` on the first CalDAV target — so the two shapes get
  two names, and the name says which one it is.

  Like the rule, they do not vary by tier: a cancelled occurrence is a fact
  about the timing, and `busy_only` mirrors the timing exactly.

  ## Why the all-day branch exists

  All-day rows carry `start_date`/`end_date` and leave `start_at`/`end_at` NULL
  — the 20260408110831 migration dropped those columns' NOT NULL constraints for
  precisely that reason, and `Caldav.OfflineQueue` reads the date pair for the
  same reason. Reading `start_at` unconditionally therefore yields `nil` for
  every all-day source.

  The branch also decides the *kind* of event written. Every outbound mapper
  keys off the value's type rather than a flag: `ICalBuilder.Properties`
  pattern-matches `%Date{}` in `start_time` to emit a `VALUE=DATE` DTSTART,
  `EventTimeFormatter` turns one into Google's `%{"date" => ...}`, and Outlook's
  `all_day_event?/1` is literally `match?(%Date{}, start_time)`. Handing a
  `DateTime` for an all-day source would produce a timed placeholder on all
  three, and `nil` would raise in `build_dtstart/1` — a `FunctionClauseError`
  inside a sync job rather than an error tuple.

  `end_time` is passed through as the source holds it. The exclusive-DTEND
  convention for DATE values is `ICalBuilder.Properties.build_dtend/1`'s
  business, and it already guards the single-day case; adding a day here would
  double the correction.

  The source `timezone` travels with the payload so the target renders the block
  in the same wall-clock hours the organiser sees on the source, rather than in
  whatever the target's own default happens to be.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  # Not a translated string. This is written into an external calendar through a
  # provider API, read by whatever client the organiser or their colleagues use,
  # and stored on that provider indefinitely — it is not rendered by Tymeslot in
  # a request whose locale is known. A later tier may make the label
  # configurable per link (`generic_label` already exists on the schema for
  # that); a gettext call keyed on the enqueuing process's locale would only
  # produce placeholders whose language varies with who happened to trigger the
  # sync.
  @busy_title "Busy"

  # The visibilities that force the `busy_only` rendering whatever the link's
  # tier says. Both spellings of each: `CalendarEvent` carries atoms and the
  # cache row carries the provider's own strings, and the two shapes reach this
  # module from different callers (see the `source` typedoc).
  @private_visibilities [:private, :confidential, "private", "confidential"]

  @typedoc "Either shape a cached source event reaches this module in."
  @type source :: CalendarEvent.t() | ProviderCalendarEventSchema.t()

  @typedoc "The privacy tiers `CalendarSyncLinkSchema` validates against."
  @type tier :: String.t()

  @typedoc """
  `:recurrence_rule` is the series master's RRULE, supplied by the caller rather
  than read off the source — see the moduledoc for why the source's own is not
  trustworthy. Absent or `nil` builds a one-off placeholder, which is what every
  non-recurring source wants.

  `:recurrence_exception_lines` are the master's `EXDATE` lines verbatim, whole
  iCalendar property lines rather than dates. Absent or empty builds a
  placeholder with no exceptions, which is both the non-recurring case and the
  recurring one whose occurrences are all still on.
  """
  @type opts :: [
          recurrence_rule: String.t() | nil,
          recurrence_exception_lines: [String.t()] | nil,
          timing: map() | nil
        ]

  @doc """
  The `busy_only` payload for one source event, addressed to `target_uid`.

  `target_uid` is the placeholder's own UID on the target — deterministic in the
  link and the source UID, so a CalDAV PUT converges rather than duplicating.
  The source's UID never appears in the payload.

  The map is deliberately not a `CalendarEvent`: this is outbound event *data*
  in the shape `Calendar.Events.create_event/2` takes, which uses
  `start_time`/`end_time` rather than the cache's split timing fields.
  """
  @spec build(source(), String.t()) :: map()
  def build(source, target_uid) when is_binary(target_uid) do
    %{
      uid: target_uid,
      # Opaque is what makes the placeholder do its job: a transparent block
      # would appear on the target and still leave the slot bookable.
      transparency: :opaque,
      status: :confirmed
    }
    |> Map.merge(content(source, "busy_only", nil))
    |> Map.merge(timing(source))
    |> Map.put(:timezone, Map.get(source, :timezone))
  end

  @doc """
  The payload for one source event on one link, at that link's privacy tier.

  The link supplies the tier and, on `generic_label`, the label itself. The
  source can still override both: a private or confidential event is rendered
  `busy_only` whatever the link asks for — see the moduledoc.

  Timing, opacity and the target UID are identical at every tier. Only the
  content differs, and no tier carries attendees or conferencing details.
  """
  @spec build(source(), String.t(), CalendarSyncLinkSchema.t(), opts()) :: map()
  def build(source, target_uid, %CalendarSyncLinkSchema{} = link, opts \\ [])
      when is_binary(target_uid) and is_list(opts) do
    %{
      uid: target_uid,
      transparency: :opaque,
      status: :confirmed
    }
    |> Map.merge(content(source, effective_tier(source, link), link.generic_label))
    |> Map.merge(timing(timing_source(source, Keyword.get(opts, :timing))))
    |> Map.put(:timezone, Map.get(source, :timezone))
    |> put_present(:recurrence_rule, Keyword.get(opts, :recurrence_rule))
    |> put_present(:recurrence_exception_lines, Keyword.get(opts, :recurrence_exception_lines))
  end

  # A recurring placeholder is timed by its series, not by the row that happened
  # to be cached for it. A rule says "and then every week" and nothing about
  # when the first occurrence falls; that is DTSTART's job, and taking it from
  # the cached row pairs the master's rule with an arbitrary instance's start.
  # Under `singleEvents=true` that instance is the *last* one, so the
  # placeholder would describe a series beginning where the real one ends.
  #
  # It is also what makes the EXDATE lines carried alongside mean anything:
  # RFC 5545 matches them against the occurrences DTSTART generates, so a
  # cancellation only lands when both come from the same event.
  #
  # A one-off event passes `nil` here and keeps the source's own timing, which
  # is the only timing it has.
  defp timing_source(source, nil), do: source

  defp timing_source(source, %{all_day: nil}), do: source

  defp timing_source(_source, series_timing), do: series_timing

  @doc "The title every `busy_only` placeholder carries."
  @spec busy_title() :: String.t()
  def busy_title, do: @busy_title

  @doc """
  The tier a source event is actually rendered at on this link.

  The link's own tier, unless the source overrides it. Exposed because the
  override is the part worth being able to see from outside — a caller
  explaining to an organiser why a `full_passthrough` link produced a bare
  "Busy" block needs the answer this function gives.
  """
  @spec effective_tier(source(), CalendarSyncLinkSchema.t()) :: tier()
  def effective_tier(source, %CalendarSyncLinkSchema{} = link) do
    if private?(source), do: "busy_only", else: link.privacy_tier
  end

  # The organiser's own marking on the source calendar, which no per-link
  # setting may overrule.
  defp private?(%{visibility: visibility}), do: visibility in @private_visibilities
  defp private?(_source), do: false

  # --- Content, per tier ---
  #
  # Each clause returns the *whole* content contribution for its tier, so the
  # difference between the tiers is one readable expression rather than a
  # sequence of conditional puts. Nothing here reads attendees, conferencing,
  # reminders or colour from the source at all: the guarantee is that the code
  # never touches those fields, not that it removes them afterwards.

  defp content(_source, "busy_only", _label), do: %{summary: @busy_title}

  defp content(source, "full_passthrough", _label) do
    %{summary: title(Map.get(source, :summary))}
    |> put_present(:description, Map.get(source, :description))
    |> put_present(:location, Map.get(source, :location))
  end

  defp content(_source, "generic_label", label), do: %{summary: title(label)}

  # A tier the schema does not validate can only arrive from a row written
  # before this module knew the tier, or from a caller bypassing the changeset.
  # `busy_only` is the safe answer to "what does this unknown tier mean": it is
  # the one rendering that cannot leak, and the link's owner sees a placeholder
  # that is too private rather than one that is not private enough.
  defp content(_source, _unknown_tier, _label), do: %{summary: @busy_title}

  # A blank title is not a neutral one — providers substitute their own wording
  # for it — so anything empty falls back to the placeholder. See the moduledoc.
  defp title(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @busy_title
      trimmed -> trimmed
    end
  end

  defp title(_value), do: @busy_title

  # Absent rather than present-and-empty: a `nil` description sent to a provider
  # is a write of an empty string over whatever is there, which on the update
  # path would clear a field the organiser edited on the target. The empty list
  # is the same case for the exception lines — a series with nothing cancelled
  # and a non-recurring event should reach the mapper identically, so that the
  # shared outbound mapper has one shape to answer rather than two.
  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, _key, ""), do: payload
  defp put_present(payload, _key, []), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  # `%Date{}` values are the all-day signal every provider mapper reads; see the
  # moduledoc. Matching on the dates themselves rather than only on the
  # `all_day` flag means a row flagged all-day but missing its dates falls
  # through to the timed clause and fails visibly, instead of emitting
  # `start_time: nil` for a mapper to raise on much further down.
  defp timing(%{all_day: true, start_date: %Date{} = start_date, end_date: %Date{} = end_date}),
    do: %{all_day: true, start_time: start_date, end_time: end_date}

  defp timing(%{all_day: true, start_date: %Date{} = start_date}),
    do: %{all_day: true, start_time: start_date, end_time: start_date}

  defp timing(source),
    do: %{all_day: false, start_time: source.start_at, end_time: source.end_at}
end
