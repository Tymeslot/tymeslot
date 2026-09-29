defmodule Tymeslot.Integrations.Calendar.Outlook.CreatableEvent do
  @moduledoc """
  An event as Graph returned it, made into a body a create
  (`POST /me/calendars/{id}/events`) makes a new event from: the series a
  split makes for the following occurrences (`Outlook.SeriesSplit`), and a
  series copied to another calendar (`Outlook.SeriesTransfer`). Pure data.

  Only the event's writable fields are copied (subject, body, location,
  attendees, categories, reminders, show-as, sensitivity, importance and
  response settings). What Graph assigns or manages itself is left out: its
  identifiers (`id`, `iCalUId`, `seriesMasterId`), its bookkeeping and its
  people apart from the attendees (the organiser is the account that
  creates the copy). An attendee is copied as who they are and how they are
  invited; their response belongs to the event they answered.

  The online meeting is left out too (`isOnlineMeeting`,
  `onlineMeetingProvider`, `onlineMeeting`): creating an event with one
  asks Teams for a new meeting rather than copying the old one, so the copy
  has no Teams meeting of its own. The join details the organiser sees in
  the body are copied with it, and lead to the original meeting.

  The timing and `recurrence` are the caller's to set: `put_timing/3`
  writes a timing on the series' own wall clock.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove

  # The fields a new event takes as they are.
  @copied ~w(subject body location locations categories importance sensitivity showAs isAllDay
             isReminderOn reminderMinutesBeforeStart responseRequested allowNewTimeProposals
             hideAttendees)

  @doc "The fields a copy takes from the event as they are."
  @spec copied_fields() :: [String.t()]
  def copied_fields, do: @copied

  @doc """
  The body a create makes a copy of `event` from, without its timing or
  recurrence. Its `body` is copied in the format it was read in, so the
  event is read with it as stored (`CalendarAPI.get_event/3`,
  `body: :stored`), or an HTML description is copied flattened to text.
  """
  @spec from_event(map()) :: map()
  def from_event(event) when is_map(event) do
    event
    |> Map.take(@copied)
    |> put_attendees(event["attendees"])
  end

  @doc """
  `body` with `start` and `end` at the wall clocks `{start, finish}`
  (whole days as dates, else naive date-times), labelled with `label`, the
  zone Graph reads them in.
  """
  @spec put_timing(map(), SeriesMove.timing(), String.t()) :: map()
  def put_timing(body, {start, finish}, label) do
    Map.merge(body, %{"start" => timing_value(start, label), "end" => timing_value(finish, label)})
  end

  defp timing_value(%Date{} = date, label),
    do: %{"dateTime" => Date.to_iso8601(date) <> "T00:00:00", "timeZone" => label}

  defp timing_value(wall, label),
    do: %{"dateTime" => NaiveDateTime.to_iso8601(wall), "timeZone" => label}

  defp put_attendees(body, attendees) when is_list(attendees),
    do: Map.put(body, "attendees", Enum.map(attendees, &Map.take(&1, ["emailAddress", "type"])))

  defp put_attendees(body, _none), do: body
end
