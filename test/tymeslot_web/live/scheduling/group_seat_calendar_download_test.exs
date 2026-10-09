defmodule TymeslotWeb.Live.Scheduling.GroupSeatCalendarDownloadTest do
  @moduledoc """
  Journey coverage for the "Add to calendar" link offered to a booker who
  joins a group slot somebody else already holds a spot on.

  `TymeslotWeb.Live.Scheduling.GroupSeatConfirmationTest` covers the first
  booker on a slot in each theme. This books the second seat on an occupied
  slot, follows the link the confirmation screen offers, and checks the
  download is the new seat's own event and names nobody else on the slot.
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
  test "joining an occupied slot downloads the new seat's own event", %{
    conn: conn,
    profile: profile
  } do
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

    [meeting] = Repo.all(where(MeetingSchema, [m], m.capacity > 1))
    live_seats = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert [_other, _holder] = live_seats
    seat = Enum.find(live_seats, &(&1.email == "holder@example.com"))

    path = URI.parse(href).path
    assert path == "/seat/#{seat.management_token}/calendar.ics"

    response = get(build_conn(), path)
    assert response.status == 200
    assert response |> get_resp_header("content-type") |> List.first() =~ "text/calendar"

    ics = unfold(response.resp_body)

    # The seat's own calendar identity, not the slot's.
    assert ics =~ "UID:#{seat.id}@"
    refute ics =~ "UID:#{meeting.calendar_uid}@"

    # Nothing that reaches the slot's own links, which refuse a group meeting.
    refute ics =~ meeting.uid

    # The booker as the event's attendee, and nobody else on the slot.
    assert ics =~ ~s(ATTENDEE;SCHEDULE-AGENT=CLIENT;CN="Seat Holder":mailto:holder@example.com)
    refute ics =~ "other@example.com"
    refute ics =~ "Other Participant"
  end

  # RFC 5545 folds long lines at 75 octets; a URL is only findable unfolded.
  defp unfold(ics), do: String.replace(ics, "\r\n ", "")
end
