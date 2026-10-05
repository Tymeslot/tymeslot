defmodule TymeslotWeb.Live.Scheduling.GroupSeatCalendarDownloadTest do
  @moduledoc """
  Journey coverage for the "Add to calendar" link a group booker is offered on
  the confirmation screen.

  Each seat of a group meeting is its own event in its participant's calendar,
  with its own UID and SEQUENCE and its participant as the attendee, and that
  is the event the seat's confirmation email attaches. The confirmation
  screen used to link to the shared slot's download instead: the slot's UID,
  no attendee, and a page reached through the slot's capability. This books a seat on the public page, follows the link the
  confirmation screen offers, and checks the download is the seat's, and that
  it names nobody else on the slot.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  import Ecto.Query, only: [where: 3]
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.RescheduleTestSetup
  alias Tymeslot.Security.RateLimiter

  setup tags do
    RateLimiter.clear_all()
    context = RescheduleTestSetup.reschedule_journey(tags)
    user = Keyword.fetch!(context, :user)

    venue = insert(:venue, user: user, name: "Main Hall", description: "1 Market Square")

    group_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Group Session",
        is_active: true,
        max_participants: 3,
        locations: [in_person_location([venue])]
      )

    # Somebody else already holds a spot on the slot the walk below picks
    # (tomorrow's first time), so the download has another participant it
    # must not mention.
    {:ok, _meeting} =
      Create.execute(
        %{
          date: Date.add(Date.utc_today(), 1),
          time: "09:00",
          duration: "30min",
          user_timezone: "UTC",
          organizer_user_id: user.id,
          meeting_type_id: group_type.id
        },
        %{"name" => "Other Participant", "email" => "other@example.com"}
      )

    Keyword.put(context, :group_type, group_type)
  end

  @tag :capture_log
  test "a group booker's download is their own seat's event", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}/group-session?timezone=UTC")
    view = walk_from_schedule_to_booking_form(view, "UTC")

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Seat Holder", "email" => "Holder@Example.com", "message" => ""}
    })
    |> render_submit()

    wait_until(fn -> has_element?(view, "[data-testid='add-to-calendar']") end)

    [href] =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("[data-testid='add-to-calendar']", "href")

    {:ok, seat} = holder_seat()
    meeting = Repo.get!(MeetingSchema, seat.meeting_id)
    assert [_other, _holder] = ParticipantQueries.list_live_for_meeting(meeting.id)

    assert href == "/seat/#{seat.management_token}/calendar.ics"

    response = get(build_conn(), href)
    assert response.status == 200
    assert response |> get_resp_header("content-type") |> List.first() =~ "text/calendar"

    ics = unfold(response.resp_body)

    # The seat's own calendar identity, not the slot's.
    assert ics =~ "UID:#{seat.id}@"
    refute ics =~ "UID:#{meeting.calendar_uid}@"
    assert ics =~ ~r/^SEQUENCE:#{seat.ical_sequence}$/m

    # Nothing that reaches the slot's own links, which refuse a group meeting.
    refute ics =~ meeting.uid

    # The booker as the event's attendee, and nobody else on the slot.
    assert ics =~ ~s(ATTENDEE;SCHEDULE-AGENT=CLIENT;CN="Seat Holder":mailto:holder@example.com)
    refute ics =~ "other@example.com"
    refute ics =~ "Other Participant"
  end

  @tag :capture_log
  test "the shared slot itself is not downloadable", %{conn: conn, profile: profile} do
    [meeting] = Repo.all(where_group(MeetingSchema))

    response = get(conn, "/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

    assert response.status == 404
  end

  defp holder_seat do
    MeetingSchema
    |> where_group()
    |> Repo.all()
    |> Enum.find_value({:error, :not_found}, fn meeting ->
      case ParticipantQueries.get_live_by_email(meeting.id, "holder@example.com") do
        {:ok, seat} -> {:ok, seat}
        {:error, :not_found} -> nil
      end
    end)
  end

  defp where_group(query), do: where(query, [m], m.capacity > 1)

  # RFC 5545 folds long lines at 75 octets; a URL is only findable unfolded.
  defp unfold(ics), do: String.replace(ics, "\r\n ", "")
end
