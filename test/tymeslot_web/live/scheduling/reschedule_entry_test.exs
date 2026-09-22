defmodule TymeslotWeb.Live.Scheduling.RescheduleEntryTest do
  @moduledoc """
  What the public scheduling page offers a booker who arrives to move an
  existing meeting: the day the schedule step opens on, and the meeting type
  the page is pinned to.

  The companion module, `RescheduleCompletionTest`, picks the journey up at
  the submit. The seam is where the booker commits, because the two halves
  fail differently: everything here is a wrong *offer*, a day with no times or
  a type the meeting is not on, and it is caught by looking at the page;
  everything there is a wrong *outcome*, and is caught by looking at the
  database.

  Both halves share `Tymeslot.RescheduleTestSetup`.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.RescheduleTestSetup

  setup :verify_on_exit!

  setup tags do
    RescheduleTestSetup.reschedule_journey(tags)
  end

  describe "the day a reschedule opens on" do
    @tag :capture_log
    test "the schedule step opens on a bookable day with its times listed", %{
      conn: conn,
      profile: profile,
      meeting: meeting
    } do
      # The auto-selection used to stand down for the whole reschedule journey:
      # it treated `is_rescheduling` as a deliberate choice of day, on the
      # belief that a reschedule link carried a date. It carries only the uid,
      # so nothing was being preserved — the rescheduler simply got the empty
      # grid, and does so against the calendar that was full enough to force
      # the move in the first place.
      #
      # This walks the real entry rather than setting the assign, because the
      # two disagree on ordering: `do_handle_schedule_entry/2` runs before
      # `handle_params/3` on the connected mount, so `is_rescheduling` is not
      # yet on the socket at the moment a synchronous fetch resolves. A unit
      # test on the assign cannot see that; this does.
      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}?timezone=#{profile.timezone}&reschedule_meeting_uid=#{meeting.uid}"
        )

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      state = :sys.get_state(view.pid).socket.assigns

      assert state.is_rescheduling,
             "the reschedule context must survive the step transition, or this proves nothing"

      assert {:ok, %Date{}} = Date.from_iso8601(state.selected_date)

      document = view |> render() |> Floki.parse_document!()

      assert Floki.find(document, "button.calendar-day--selected") != [],
             "expected the reschedule to open on a day painted as selected"

      assert Floki.attribute(document, "button.time-slot-button", "phx-value-time") != [],
             "expected that day's times to be listed"

      # The hour stays the rescheduler's decision, exactly as for a new booking.
      assert state.selected_time == nil
    end
  end

  describe "the schedule a reschedule is offered against" do
    # A second, unrelated type the organiser also offers publicly. Without one
    # the "exactly one card" assertions below pass on an empty catalogue and
    # prove nothing, since `setup` inserts a single meeting type.
    defp second_public_type(user) do
      insert(:meeting_type,
        user: user,
        duration_minutes: 45,
        name: "Deep Dive",
        is_active: true
      )
    end

    # Moves the meeting onto a type of its own, on a schedule with a window
    # nothing else uses, so "which type is this page on?" is answerable from
    # `booking_window_days` alone.
    defp pin_meeting_to_its_own_type(user, profile, meeting) do
      long_schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: false,
          name: "Long lead time",
          advance_booking_days: 180,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      pinned_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Pinned Chat",
          is_active: true,
          availability_schedule_id: long_schedule.id
        )

      {:ok, _updated} =
        meeting
        |> Changeset.change(%{meeting_type_id: pinned_type.id})
        |> Repo.update()

      pinned_type
    end

    @tag :capture_log
    test "comes from the meeting's own type, not a duration match", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      # A reschedule link carries only the meeting uid, and the type used to be
      # re-picked from the duration in the URL — which resolves against slugs,
      # so it matched nothing and the page fell back to the profile's default
      # schedule. Slots were then offered from the default while the submit was
      # validated against the meeting's own type, which is the one way left to
      # break "if it is offered, it can be booked".
      pinned_type = pin_meeting_to_its_own_type(user, profile, meeting)

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      # The other type is not offered at all any more: a reschedule shows the
      # meeting's own type and nothing else.
      refute has_element?(
               view,
               "button[data-testid='duration-option'][phx-value-duration='quick-chat']"
             )

      # The card is gone, but the event behind it is still the client's to
      # push, so the server is what has to hold. The only card on the page is
      # clicked with another type's slug overriding its value — the closest a
      # test gets to a crafted client without bypassing the component.
      view
      |> element("button[data-testid='duration-option']")
      |> render_click(%{"duration" => "quick-chat"})

      render(view)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.meeting_type.id == pinned_type.id
      assert assigns.booking_window_days == 180

      # The slug is discarded rather than kept alongside the pinned type: left
      # on "quick-chat" it is no longer one of `:meeting_types`, and the step's
      # own validation then refuses to advance with no card showing why.
      assert assigns.selected_duration == "pinned-chat"
      assert assigns.duration == "pinned-chat"
    end

    @tag :capture_log
    test "a stale slug in the URL does not move the reschedule off its type", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      # `/:username/:slug` resolves the type from the slug, and a reschedule
      # reaches it through a mid-flow locale switch or an old direct booking
      # link with the uid appended. Resolved by slug, the page offered slots
      # against "Quick Chat"'s 30-day window while the submit validated against
      # the meeting's own 180-day one.
      pinned_type = pin_meeting_to_its_own_type(user, profile, meeting)

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/quick-chat?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}"
        )

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.meeting_type.id == pinned_type.id
      assert assigns.booking_window_days == 180
      assert assigns.selected_duration == "pinned-chat"
      assert assigns.duration == "pinned-chat"
    end

    @tag :capture_log
    test "offers the meeting's own type, already selected", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      second_public_type(user)

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      # One card out of the two the organiser offers, and it is the meeting's
      # own: a reschedule is not a choice of meeting type, so the step confirms
      # what is being moved rather than asking for something that cannot be
      # changed.
      cards =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='duration-option']")

      assert length(cards) == 1
      assert Floki.attribute(cards, "phx-value-duration") == ["quick-chat"]

      # Already selected, so "next" is one click rather than a forced pick.
      assert has_element?(view, "[data-testid='duration-option'].duration-card--selected")
      refute has_element?(view, "[data-testid='next-step'][disabled]")
    end

    @tag :capture_log
    test "offers the meeting's own type already selected in Rhythm too", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      # Rhythm marks the selection on the card's wrapper rather than on the
      # button carrying the testid, so the Quill assertion above matches
      # nothing here and would pass on a page that pinned nothing.
      second_public_type(user)
      {:ok, profile} = profile |> Changeset.change(%{booking_theme: "2"}) |> Repo.update()

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      cards =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='duration-option']")

      assert length(cards) == 1
      assert Floki.attribute(cards, "phx-value-duration") == ["quick-chat"]

      assert has_element?(view, ".duration-card.selected [data-testid='duration-option']")
      refute has_element?(view, "[data-testid='next-step'][disabled]")
    end

    @tag :capture_log
    test "clicking the pinned card in Rhythm does not deselect it", %{
      conn: conn,
      profile: profile,
      meeting: meeting
    } do
      # Rhythm deselects the selected card when it is clicked again, which is
      # how a booker changes their mind there. On a pinned reschedule that
      # would disable "next" over a choice that was never theirs and leave
      # them stuck on the step, so the selection has to survive the click.
      {:ok, profile} = profile |> Changeset.change(%{booking_theme: "2"}) |> Repo.update()

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      # Anchored first: without this the refute below passes just as well on a
      # page that never pinned anything, where the click selects a card.
      assert has_element?(view, ".duration-card.selected [data-testid='duration-option']")

      view |> element("[data-testid='duration-option']") |> render_click()
      render(view)

      assert has_element?(view, ".duration-card.selected [data-testid='duration-option']")
      refute has_element?(view, "[data-testid='next-step'][disabled]")
    end
  end
end
