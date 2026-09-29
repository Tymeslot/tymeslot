defmodule Tymeslot.Integrations.Calendar.MeetingEventIdentityTest do
  @moduledoc """
  What each provider is sent for a new booking's calendar event.

  A meeting's `uid` authorises cancelling and rescheduling it, so it must not
  reach anything the organiser's calendar exposes: the event's UID, the
  Google event id derived from it, or the CalDAV resource. Each provider's
  outbound mapping is checked against a meeting created through the real
  create path, so the calendar identity under test is the one a booking
  actually gets.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Ecto.UUID
  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Integrations.Calendar.Exchange.Writes, as: ExchangeWrites
  alias Tymeslot.Integrations.Calendar.Google.EventMapper, as: GoogleEventMapper
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper, as: OutlookEventMapper
  alias Tymeslot.Meetings.MeetingQueries

  setup do
    user = insert(:user)

    {:ok, meeting} =
      :meeting
      |> params_for(organizer_user_id: user.id)
      |> Map.delete(:calendar_uid)
      |> MeetingQueries.create_meeting()

    %{meeting: meeting, event_data: CalendarEventBuilder.build_event_data(meeting)}
  end

  test "a new meeting's calendar uid is its own, unrelated to its uid", %{meeting: meeting} do
    assert {:ok, _uuid} = UUID.cast(meeting.calendar_uid)
    refute meeting.calendar_uid == meeting.uid
    refute leaks_uid?(meeting.calendar_uid, meeting)
  end

  test "the event data carries the calendar uid", %{meeting: meeting, event_data: event_data} do
    assert event_data.uid == meeting.calendar_uid
    refute leaks_uid?(event_data, meeting)
  end

  test "Google is sent an event id derived from the calendar uid", %{
    meeting: meeting,
    event_data: event_data
  } do
    body = GoogleEventMapper.format_event_data(event_data)

    assert body["id"] == GoogleEventMapper.uuid_to_google_event_id(meeting.calendar_uid)
    refute leaks_uid?(body, meeting)
  end

  test "Outlook is sent nothing derived from the meeting's uid", %{
    meeting: meeting,
    event_data: event_data
  } do
    body = OutlookEventMapper.format_event_data(event_data)

    refute leaks_uid?(body, meeting)
  end

  test "CalDAV writes the calendar uid as the event UID", %{
    meeting: meeting,
    event_data: event_data
  } do
    # `CalDAV.Events.create_calendar_event/4` builds the resource from
    # `event_data.uid` and names the resource after it too.
    ical = ICalBuilder.build_simple_event(event_data.uid, event_data)

    assert ical =~ "UID:#{meeting.calendar_uid}"
    refute leaks_uid?(ical, meeting)
  end

  test "Exchange is sent nothing derived from the meeting's uid", %{
    meeting: meeting,
    event_data: event_data
  } do
    refute event_data |> ExchangeWrites.from_event_data() |> leaks_uid?(meeting)
  end

  # Both spellings of the UUID: Google's event id is the uid with its hyphens
  # stripped, which would hand the capability straight back.
  defp leaks_uid?(payload, meeting) do
    text = if is_binary(payload), do: payload, else: inspect(payload, limit: :infinity)
    compact = String.replace(meeting.uid, "-", "")

    String.contains?(text, meeting.uid) or String.contains?(text, compact)
  end
end
