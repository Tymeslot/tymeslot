defmodule Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload do
  @moduledoc """
  Builds the event payload for a `busy_only` placeholder: when the source event
  is, under a title that says nothing about what it is.

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
  privacy tier ever copies attendees, and this one copies nothing at all.

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

  @typedoc "Either shape a cached source event reaches this module in."
  @type source :: CalendarEvent.t() | ProviderCalendarEventSchema.t()

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
      summary: @busy_title,
      # Opaque is what makes the placeholder do its job: a transparent block
      # would appear on the target and still leave the slot bookable.
      transparency: :opaque,
      status: :confirmed
    }
    |> Map.merge(timing(source))
    |> Map.put(:timezone, Map.get(source, :timezone))
  end

  @doc "The title every `busy_only` placeholder carries."
  @spec busy_title() :: String.t()
  def busy_title, do: @busy_title

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
