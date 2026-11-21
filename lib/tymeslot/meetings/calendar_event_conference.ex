defmodule Tymeslot.Meetings.CalendarEventConference do
  @moduledoc """
  Taking a booking's Meet conference off its Google event, in place.

  A room that is the booking's own calendar event is released by
  `Tymeslot.Meetings.CalendarEventSync.replace/3`. Outlook keeps a Teams
  meeting on its event for good, so an Outlook event is replaced with a new
  one. A Google event cannot be: its id is derived from the booking's
  calendar UID, so the replacement would be refused as the old event's
  duplicate. Google takes a conference off an event in place instead: the
  event is written with `conferenceDataVersion=1` and no `conferenceData`
  (`Tymeslot.Integrations.Calendar.Google.ConferenceData.remove/0`).
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Calendar.Management, as: CalendarManagement
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.CalendarEventCache

  @doc "Whether the meeting's calendar event is a Google event."
  @spec google?(map()) :: boolean()
  def google?(%{calendar_integration_id: cal_id, organizer_user_id: user_id})
      when is_integer(cal_id) and is_integer(user_id) do
    match?(
      {:ok, %{provider: "google"}},
      CalendarManagement.fetch_integration_for_user(cal_id, user_id)
    )
  end

  def google?(_meeting), do: false

  @doc """
  Writes the meeting's event as it stands, without a conference. An event
  Google no longer has carries no conference either, so it counts as done.
  """
  @spec clear(map()) :: :ok | {:error, term()}
  def clear(meeting) do
    Logger.info("Taking the Meet conference off the calendar event", meeting_id: meeting.id)

    event_data =
      meeting
      |> CalendarEventBuilder.build_event_data(
        attendees: Meetings.attendees_for_calendar(meeting)
      )
      |> Map.put(:conference_data, ConferenceData.remove())

    case CalendarEvents.update_event(meeting.provider_event_id, event_data, meeting) do
      {:error, :not_found} ->
        Logger.info("Calendar event already gone, no conference to take off",
          meeting_id: meeting.id
        )

        :ok

      {:error, _reason} = error ->
        error

      _updated ->
        CalendarEventCache.write_through_update(meeting, event_data)
    end
  end
end
