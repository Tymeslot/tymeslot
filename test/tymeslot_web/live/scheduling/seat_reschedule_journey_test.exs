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

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.RescheduleTestSetup
  alias Tymeslot.Security.Token
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

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
    # `Offer` leaves the seat's own meeting out of the busy times when the
    # seat is its last (see `Tymeslot.Availability.OfferSeatMoveTest`), which
    # it can only do if the page hands it the token.
    @tag :capture_log
    test "the page asks for the times the seat's own move can take", %{
      conn: conn,
      profile: profile,
      seat: seat
    } do
      token = seat.management_token

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/group-session?reschedule_seat_token=#{token}&timezone=UTC"
        )

      %{socket: socket} = :sys.get_state(view.pid)

      assert AvailabilityHelpers.request(socket).reschedule_seat_token == token
    end

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

      # "Add to calendar" downloads the moved seat's own entry.
      assert html =~ ~s(/seat/#{moved.management_token}/calendar.ics")

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
      # reload or a shared link is a fresh booking too. The link named the
      # meeting type, so the fresh booking starts on that type's own
      # schedule step rather than the overview.
      assert_patch(view, "/#{profile.username}/group-session?timezone=UTC")
      refute has_element?(view, "[data-testid='seat-move-notice']")

      view = walk_from_schedule_to_booking_form(view, "UTC")

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

    # The page loads the seat when it applies its URL and keeps it between
    # steps; applying the URL again (a patch, back and forward in the
    # browser) loads it afresh, so a seat given up meanwhile is caught as on
    # arrival.
    @tag :capture_log
    test "used while the page is open, is caught when the page applies its URL again", %{
      conn: conn,
      profile: profile,
      seat: seat
    } do
      path =
        "/#{profile.username}/group-session?timezone=UTC&reschedule_seat_token=#{seat.management_token}"

      {:ok, view, _html} = live(conn, path)
      {:ok, _cancelled} = ParticipantQueries.cancel(seat)

      assert {:error, {:live_redirect, %{to: to}}} = render_patch(view, path)
      assert to == "/#{profile.username}?timezone=UTC"
      assert assert_redirect(view, to)["info"] =~ "already been used"
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

  describe "a seat link" do
    # A seat whose type has been deleted, or no longer takes group bookings,
    # cannot move at all (`RescheduleSeat`). The page says so on arrival, as
    # the email link's own landing page does, rather than offering times the
    # move refuses, or (with the type's slug gone) turning the visitor away as
    # an invalid meeting type without their token, to book a second seat.
    for {change, label} <- [delete: "deleted", solo: "no longer taking group bookings"] do
      @tag :capture_log
      test "whose type is #{label} is refused on arrival, saying it cannot move", %{
        conn: conn,
        profile: profile,
        group_type: group_type,
        seat: seat
      } do
        case unquote(change) do
          :delete -> Repo.delete!(group_type)
          :solo -> group_type |> Changeset.change(%{max_participants: 1}) |> Repo.update!()
        end

        assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
                 live(
                   conn,
                   "/#{profile.username}/group-session?timezone=UTC&reschedule_seat_token=#{seat.management_token}"
                 )

        assert to == "/#{profile.username}?timezone=UTC"
        assert flash["error"] =~ "This spot can no longer be moved"
        assert {:ok, %{cancelled_at: nil}} = ParticipantQueries.get(seat.id)
      end
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

    # The connected mount enters the first step before `handle_params` runs,
    # so the seat has to be loaded and pinned by then too. Without it that
    # entry fell back on the slug, and a slug naming no type (one renamed
    # since the email went out) sent the participant on to the host's page
    # without the token, to book a second seat beside the one they meant to
    # move.
    @tag :capture_log
    test "a slug naming no type keeps the seat move", %{
      conn: conn,
      profile: profile,
      group_type: group_type,
      seat: seat
    } do
      token = seat.management_token

      assert {:ok, view, _html} =
               live(
                 conn,
                 "/#{profile.username}/renamed-since?timezone=UTC&reschedule_seat_token=#{token}"
               )

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.reschedule_seat_token == token
      assert assigns.meeting_type.id == group_type.id
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

  describe "the seat a move is loaded from" do
    # Loaded once each time the page applies its URL (the static render, the
    # connected one), and read from there by the pin, the date step's notice,
    # the form and the times offered. Counted at the lookup by this seat's
    # token, which filters on the token's hash.
    @tag :capture_log
    test "is looked up once per render, however far the move goes", %{
      conn: conn,
      profile: profile,
      seat: seat
    } do
      ref = count_seat_lookups(seat.management_token)

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/group-session?reschedule_seat_token=#{seat.management_token}&timezone=UTC"
        )

      assert has_element?(view, "[data-testid='seat-move-notice']")
      view = walk_from_schedule_to_booking_form(view, "UTC")

      assert render(view) =~ ~s(value="Moving Participant")
      assert seat_lookups(ref) == 2
    end
  end

  # The lookup by token filters on the token's hash, so this seat's own
  # lookups are the participant queries carrying its hash.
  defp count_seat_lookups(token) do
    parent = self()
    ref = make_ref()
    handler_id = "seat-lookup-#{inspect(ref)}"
    hash = Token.hash_token(token)

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source, params: params}, _config ->
        if source == "meeting_participants" and hash in params,
          do: send(parent, {:seat_lookup, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp seat_lookups(ref, count \\ 0) do
    receive do
      {:seat_lookup, ^ref} -> seat_lookups(ref, count + 1)
    after
      0 -> count
    end
  end
end
