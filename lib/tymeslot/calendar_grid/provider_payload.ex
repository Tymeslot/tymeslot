defmodule Tymeslot.CalendarGrid.ProviderPayload do
  @moduledoc """
  Translates a whole calendar-grid event from the cache's vocabulary into the
  payload the calendar adapters write.

  ## Why the whole event

  Provider writes replace the event. CalDAV rebuilds the VEVENT from the
  payload and Google's `events.update` is a `PUT`, so any field a payload
  leaves out is deleted from the organiser's calendar. Every grid write
  (an edit, or the create half of a move) therefore starts from the complete
  event, never from the part that changed.

  Complete means complete with respect to what the cache models. Properties
  Tymeslot never reads (categories, custom `X-` properties, alarm repeats)
  are still lost on a Google write. CalDAV keeps them: the caller sends the
  event's cached `raw_ical` alongside the payload and the adapter patches
  that document rather than rebuilding it.

  ## Vocabularies

  The event speaks the cache's vocabulary (`start_at`, `start_date`, ...);
  the payload speaks the adapters' (`start_time`, `end_time`). The two are
  translated here in one direction only, so a key cannot silently mean
  something to one side and nothing to the other.
  """

  # Only provider statuses every adapter accepts on a write. A cached
  # `declined` describes the organiser's response, not the event, and Google
  # rejects it as an event status.
  @writable_statuses ~w(confirmed tentative cancelled)

  @doc """
  Builds the provider payload for `event`, addressed at the calendar in its
  `provider_calendar_id`.

  Timing follows the event's `all_day` flag: an all-day event is written with
  its `Date` boundaries, a timed event with its `DateTime` instants. Returns
  `{:error, :invalid_timing}` when the event lacks the timing its flag calls
  for, since such a write either crashes the CalDAV builder or reaches the
  provider as an event with no start.
  """
  @spec from_event(map()) :: {:ok, map()} | {:error, :invalid_timing}
  def from_event(event) do
    with {:ok, {start_time, end_time}} <- timing(event) do
      {:ok,
       %{
         summary: event.summary || "",
         description: event.description || "",
         location: event.location || "",
         start_time: start_time,
         end_time: end_time,
         all_day: event.all_day,
         attendees: event.attendees || [],
         reminders: event.reminders || [],
         recurrence_rule: event.recurrence_rule,
         recurrence_exceptions: event.recurrence_exceptions || [],
         colour: event.colour,
         transparency: event.transparency,
         visibility: event.visibility,
         status: writable_status(event.status),
         provider_event_id: event.provider_event_id,
         calendar_id: calendar_id(event.provider_calendar_id)
       }}
    end
  end

  # Adapters read a `Date` as an all-day boundary and a `DateTime` as an
  # instant, so the type itself carries the distinction.
  defp timing(%{all_day: true, start_date: %Date{} = start_date, end_date: %Date{} = end_date}),
    do: {:ok, {start_date, end_date}}

  defp timing(%{all_day: false, start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}),
    do: {:ok, {start_at, end_at}}

  defp timing(_event), do: {:error, :invalid_timing}

  defp writable_status(status) when status in @writable_statuses, do: status
  defp writable_status(_status), do: nil

  # "primary" is the placeholder the Outlook sync writes when it does not know
  # which calendar an event is on, and Microsoft Graph has no calendar by that
  # id. Leaving it out lets each provider fall back to its own default, which
  # for Google is that same "primary" alias.
  defp calendar_id("primary"), do: nil
  defp calendar_id(calendar_id), do: calendar_id
end
