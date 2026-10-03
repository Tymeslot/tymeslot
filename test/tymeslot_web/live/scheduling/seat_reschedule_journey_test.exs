defmodule TymeslotWeb.Live.Scheduling.SeatRescheduleJourneyTest do
  @moduledoc """
  Journey coverage for a group-booking participant moving their own seat:
  from the reschedule link in their email, through the public booking page,
  to the moved seat, and on to a fresh booking from the confirmation screen.

  The seat move travels as `reschedule_seat_token` rather than a meeting uid,
  so it has its own half of the reschedule context: `ReschedulePin` pins the
  page to the seat's meeting type from the token, and `ReschedulePin.abandon/1`
  has to drop the token when the participant asks to schedule another
  meeting, or every later submit is routed back through the spent seat move.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [from: 2]
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.RescheduleTestSetup
  alias Tymeslot.Workers.EmailWorker

  setup tags do
    context = RescheduleTestSetup.reschedule_journey(tags)
    user = Keyword.fetch!(context, :user)

    # A group type's location is fixed in advance: one venue.
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

    # Three days out, clear of the setup's own solo meeting a week away.
    {:ok, meeting} =
      Create.execute(
        %{
          date: Date.add(Date.utc_today(), 3),
          time: "14:00",
          duration: "30min",
          user_timezone: "UTC",
          organizer_user_id: user.id,
          meeting_type_id: group_type.id
        },
        %{"name" => "Moving Participant", "email" => "mover@example.com"}
      )

    [seat] = ParticipantQueries.list_live_for_meeting(meeting.id)

    Keyword.merge(context, group_type: group_type, seat: seat, old_meeting: meeting)
  end

  defp live_participants(email) do
    Repo.all(from(p in ParticipantSchema, where: p.email == ^email and is_nil(p.cancelled_at)))
  end

  defp submit_booking(view, name, email) do
    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => name, "email" => email, "message" => ""}
    })
    |> render_submit()
  end

  describe "a participant moving their seat from the email link" do
    @tag :capture_log
    test "moves the seat, and \"Schedule another meeting\" then books afresh", %{
      conn: conn,
      profile: profile,
      seat: seat
    } do
      token = seat.management_token

      target = conn |> get(~p"/seat/#{token}/reschedule") |> redirected_to()
      assert target == "/#{profile.username}/group-session?reschedule_seat_token=#{token}"

      {:ok, view, _html} = live(conn, target <> "&timezone=UTC")

      # The date step says which spot is moving.
      assert has_element?(view, "[data-testid='seat-move-notice']", "Moving your spot on")

      view = walk_from_schedule_to_booking_form(view, "UTC")

      # The details step states where the spot is, as a new booking's does.
      assert render(view) =~ "Main Hall"

      submit_booking(view, "Moving Participant", "mover@example.com")

      # So does the "rescheduled" screen, which also says the booking is one
      # spot of a group session.
      wait_until(fn -> has_element?(view, "[data-testid='confirmation-location']") end)
      html = render(view)
      assert html =~ "Main Hall"
      assert html =~ "Group session: you have one of 3 spots."

      wait_until(fn ->
        match?({:ok, %{cancelled_at: %DateTime{}}}, ParticipantQueries.get(seat.id))
      end)

      assert [moved] = live_participants("mover@example.com")
      assert moved.id != seat.id
      assert moved.meeting_id != seat.meeting_id
      assert moved.management_token != token

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_seat_reschedule_emails",
          "participant_id" => moved.id,
          "old_participant_id" => seat.id
        }
      )

      # The confirmation screen's way back to a fresh booking. Left on the
      # socket, the spent token routed this booking through the seat move,
      # which refused it as "already cancelled or moved".
      view |> element("[data-testid='schedule-another']") |> render_click()

      # The spent token leaves the address bar with the reschedule, so a
      # reload or a shared link is a fresh booking too.
      assert_patch(view, "/#{profile.username}?timezone=UTC")

      view = walk_to_booking_form(view, "UTC", "group-session")

      html = submit_booking(view, "Second Booker", "second@example.com")
      refute html =~ "already been cancelled or moved"

      wait_until(fn -> live_participants("second@example.com") != [] end)

      assert [_new_booking] = live_participants("second@example.com")

      assert [%{id: still_moved_id}] = live_participants("mover@example.com")
      assert still_moved_id == moved.id
    end
  end

  describe "a seat link already used" do
    @tag :capture_log
    test "is sent on to a fresh booking from the start, with a word on why", %{
      conn: conn,
      profile: profile,
      seat: seat
    } do
      {:ok, _cancelled} = ParticipantQueries.cancel(seat)

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(
                 conn,
                 "/#{profile.username}/group-session?timezone=UTC&reschedule_seat_token=#{seat.management_token}"
               )

      assert to == "/#{profile.username}?timezone=UTC"
      assert flash["info"] =~ "already been used"

      {:ok, view, _html} = live(conn, to)

      view
      |> element("[data-testid='duration-option'][phx-value-duration='group-session']")
      |> render_click()

      view |> element("[data-testid='next-step']") |> render_click()

      # The normal flow, with its way back to the meeting types.
      assert has_element?(view, "[data-testid='back-step']")
      refute has_element?(view, "[data-testid='seat-move-notice']")
    end

    @tag :capture_log
    test "picking the spot's own time says it is the current time", %{
      conn: conn,
      profile: profile,
      seat: seat,
      old_meeting: old_meeting
    } do
      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/group-session?timezone=UTC&reschedule_seat_token=#{seat.management_token}"
        )

      date = DateTime.to_date(old_meeting.start_time)
      day = "button.calendar-day[phx-value-date='#{date}']"

      unless has_element?(view, "#{day}:not(.calendar-day--other-month)"),
        do: show_month(view, date)

      wait_until(fn -> has_element?(view, "#{day}:not([disabled])") end)
      view |> element(day) |> render_click()
      wait_until(fn -> has_element?(view, "button[data-testid='time-slot']") end)

      own_time =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("button[data-testid='time-slot']", "phx-value-time")
        |> Enum.find(&(&1 =~ ~r/^(14:00|0?2:00 PM)/)) ||
          flunk("expected the spot's own time to be offered")

      view
      |> element("button[data-testid='time-slot'][phx-value-time='#{own_time}']")
      |> render_click()

      view |> element("[data-testid='next-step']") |> render_click()

      submit_booking(view, "Moving Participant", "mover@example.com")

      wait_until(fn -> render(view) =~ "This is your current time" end)
      refute render(view) =~ "already have a spot"
      assert {:ok, %{cancelled_at: nil}} = ParticipantQueries.get(seat.id)
    end
  end

  describe "the page a seat move opens on" do
    @tag :capture_log
    test "a hand-edited slug does not move the page off the seat's own type", %{
      conn: conn,
      profile: profile,
      group_type: group_type,
      seat: seat
    } do
      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/quick-chat?timezone=UTC&reschedule_seat_token=#{seat.management_token}"
        )

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.meeting_type.id == group_type.id
      assert assigns.selected_duration == "group-session"
      assert Enum.map(assigns.meeting_types, & &1.id) == [group_type.id]
    end

    @tag :capture_log
    test "the overview offers only the seat's own type", %{
      conn: conn,
      profile: profile,
      seat: seat
    } do
      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}?timezone=UTC&reschedule_seat_token=#{seat.management_token}"
        )

      cards =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='duration-option']")

      assert Floki.attribute(cards, "phx-value-duration") == ["group-session"]
    end
  end
end
