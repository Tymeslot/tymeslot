defmodule TymeslotWeb.Live.Scheduling.GroupSlotDisplayTest do
  @moduledoc """
  The spots display on the public booking schedule step, on every shipped
  theme (`ThemeTestMatrix.all/0`), under each of the organiser's display
  settings. Solo meeting types must render exactly as before (no badge
  markup). The day is picked through the markup contract
  (`BookingDriver.pick_date/2`), so no theme's own calendar classes are read.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    %{user: insert(:user)}
  end

  defp setup_booking_page(user, theme, slug_name, meeting_type_attrs) do
    profile =
      insert(:profile,
        user: user,
        username: "seats-#{theme}-#{System.unique_integer([:positive])}",
        booking_theme: theme,
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    meeting_type =
      insert(
        :meeting_type,
        Keyword.merge(
          [user: user, duration_minutes: 30, name: slug_name, is_active: true],
          meeting_type_attrs
        )
      )

    {profile, meeting_type}
  end

  # Opens /:username/:slug (direct schedule entry), picks tomorrow and waits
  # for its times.
  defp open_schedule_and_pick_tomorrow(profile, slug) do
    timezone = profile.timezone
    {:ok, view, _html} = live(build_conn(), "/#{profile.username}/#{slug}?timezone=#{timezone}")

    date_str =
      timezone |> DateTime.now!() |> DateTime.to_date() |> Date.add(1) |> Date.to_string()

    BookingDriver.pick_date(view, date_str)
    wait_until(fn -> has_element?(view, ~s([data-testid="time-slot"])) end)
    {view, date_str}
  end

  describe "the meeting-type list" do
    for theme <- ThemeTestMatrix.all() do
      @theme theme

      @tag :capture_log
      test "#{theme.name} marks a group type as a group session, and only that type",
           %{user: user} do
        {profile, _group} =
          setup_booking_page(user, @theme.id, "Workshop", max_participants: 3)

        insert(:meeting_type,
          user: user,
          duration_minutes: 45,
          name: "Solo Call",
          is_active: true
        )

        {:ok, view, _html} = live(build_conn(), "/#{profile.username}?timezone=UTC")

        hints =
          view
          |> render()
          |> Floki.parse_document!()
          |> Floki.find("[data-testid='group-session-hint']")

        assert [hint] = hints
        assert Floki.text(hint) =~ "Group session · up to 3 people"

        assert has_element?(
                 view,
                 "[data-fact='meeting_type'][data-value='workshop'] [data-testid='group-session-hint']"
               )
      end
    end
  end

  describe "the schedule step's slots" do
    for theme <- ThemeTestMatrix.all() do
      @theme theme

      @tag :capture_log
      test "#{theme.name}: group slots show a seat badge with the full capacity free",
           %{user: user} do
        {profile, _meeting_type} =
          setup_booking_page(user, @theme.id, "Group Chat", max_participants: 10)

        {view, _date} = open_schedule_and_pick_tomorrow(profile, "group-chat")

        html = render(view)
        assert html =~ ~s(data-testid="seat-badge")
        assert html =~ "seat-green"
        assert html =~ "Plenty left"
        refute html =~ "spots left"
        assert html =~ "slot-list__slot--seats"
      end

      @tag :capture_log
      test "#{theme.name}: solo slots render without any badge markup", %{user: user} do
        {profile, _meeting_type} =
          setup_booking_page(user, @theme.id, "Solo Chat", max_participants: 1)

        {view, _date} = open_schedule_and_pick_tomorrow(profile, "solo-chat")

        html = render(view)
        refute html =~ "seat-badge"
        refute html =~ "spots left"
        refute html =~ "slot-list__slot--seats"
        refute html =~ "group-session-hint"
      end
    end

    @tag :capture_log
    test "a full group slot is absent for the next visitor", %{user: user} do
      {profile, _meeting_type} =
        setup_booking_page(user, "1", "Tiny Group", max_participants: 2, allow_guests: true)

      # First booker fills the slot: capacity 2 as themselves plus one guest.
      {first, _date} = open_schedule_and_pick_tomorrow(profile, "tiny-group")

      taken_time =
        first
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute(~s([data-testid="time-slot"]), "phx-value-time")
        |> List.first()

      BookingDriver.pick_time(first, taken_time)
      BookingDriver.continue(first)

      send(first.pid, {:step_event, :booking, :toggle_guests, nil})
      send(first.pid, {:step_event, :booking, :add_guest, "guest@example.com"})

      first
      |> form("form[phx-submit='submit']", %{
        "booking" => %{"name" => "Filler", "email" => "filler@example.com", "message" => ""}
      })
      |> render_submit()

      wait_until(fn -> render(first) =~ "filler@example.com" end)

      # A fresh visitor no longer sees that slot; the rest of the day remains.
      {second, _date} = open_schedule_and_pick_tomorrow(profile, "tiny-group")

      refute has_element?(
               second,
               ~s([data-testid="time-slot"][phx-value-time="#{taken_time}"])
             )
    end
  end

  # Capacity 10 and nobody booked yet: every slot has 10 spots left, so a
  # threshold of 10 shows the count and one of 9 does not.
  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name} spots display settings" do
      @theme theme.id

      @tag :capture_log
      test "with colours off and no count, slots carry no badge but the step still says group session",
           %{user: user} do
        view = group_schedule(user, @theme, show_seat_availability: false)

        refute has_element?(view, ~s([data-testid="seat-badge"]))
        refute has_element?(view, ~s([data-testid="time-slot"].slot-list__slot--seats))
        assert has_element?(view, ~s([data-testid="group-session-hint"]), "up to 10 people")
      end

      @tag :capture_log
      test "with colours off, the count shows neutrally once within the threshold", %{user: user} do
        view =
          group_schedule(user, @theme, show_seat_availability: false, last_spots_threshold: 10)

        assert has_element?(view, ~s([data-testid="seat-badge"].seat-neutral), "10 spots left")
        refute render(view) =~ "seat-green"
      end

      @tag :capture_log
      test "with colours on, the count replaces the level label within the threshold",
           %{user: user} do
        view = group_schedule(user, @theme, last_spots_threshold: 10)

        assert has_element?(view, ~s([data-testid="seat-badge"].seat-green), "10 spots left")
        refute render(view) =~ "Plenty left"
      end

      @tag :capture_log
      test "the count stays hidden above the threshold", %{user: user} do
        view = group_schedule(user, @theme, last_spots_threshold: 9)

        assert has_element?(view, ~s([data-testid="seat-badge"].seat-green), "Plenty left")
        refute render(view) =~ "spots left"
      end
    end
  end

  defp group_schedule(user, theme, display_attrs) do
    {profile, _meeting_type} =
      setup_booking_page(user, theme, "Group Display", [max_participants: 10] ++ display_attrs)

    {view, _date} = open_schedule_and_pick_tomorrow(profile, "group-display")
    view
  end
end
