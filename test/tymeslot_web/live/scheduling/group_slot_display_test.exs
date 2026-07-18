defmodule TymeslotWeb.Live.Scheduling.GroupSlotDisplayTest do
  @moduledoc """
  Traffic-light seat display on the public booking schedule step, per theme.
  Solo meeting types must render exactly as before (no badge markup).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

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
        timezone: "America/New_York",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
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

  # Opens /:username/:slug (direct schedule entry) and selects tomorrow.
  defp open_schedule_and_pick_tomorrow(profile, slug) do
    timezone = profile.timezone
    {:ok, view, _html} = live(build_conn(), "/#{profile.username}/#{slug}?timezone=#{timezone}")

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    date_str = Date.to_string(target_date)

    # Quill starts on the current month; Rhythm on the current week. Advance
    # once if tomorrow is not yet selectable in the rendered strip/grid.
    unless has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']") do
      nav =
        if has_element?(view, "button[phx-click='next_month']"),
          do: "button[phx-click='next_month']",
          else: "button[phx-click='next_week']"

      view |> element(nav) |> render_click()
    end

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()
    {view, date_str}
  end

  describe "Quill (theme 1)" do
    @tag :capture_log
    test "group slots show a seat badge with the full capacity free", %{user: user} do
      {profile, _meeting_type} =
        setup_booking_page(user, "1", "Group Chat", max_participants: 10)

      {view, _date} = open_schedule_and_pick_tomorrow(profile, "group-chat")

      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      html = render(view)
      assert html =~ ~s(data-testid="seat-badge")
      assert html =~ "seat-green"
      assert html =~ "10 seats left"
      assert html =~ "has-seats"
    end

    @tag :capture_log
    test "solo slots render without any badge markup", %{user: user} do
      {profile, _meeting_type} =
        setup_booking_page(user, "1", "Solo Chat", max_participants: 1)

      {view, _date} = open_schedule_and_pick_tomorrow(profile, "solo-chat")

      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      html = render(view)
      refute html =~ "seat-badge"
      refute html =~ "seats left"
      refute html =~ "has-seats"
    end

    @tag :capture_log
    test "a full group slot is absent for the next visitor", %{user: user} do
      {profile, _meeting_type} =
        setup_booking_page(user, "1", "Tiny Group", max_participants: 2, allow_guests: true)

      # First booker fills the slot: capacity 2 as themselves plus one guest.
      {first, _date} = open_schedule_and_pick_tomorrow(profile, "tiny-group")
      wait_until(fn -> has_element?(first, "button.time-slot-button") end)

      taken_time =
        first
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("button.time-slot-button", "phx-value-time")
        |> List.first()

      first
      |> element("button.time-slot-button[phx-value-time='#{taken_time}']")
      |> render_click()

      first |> element("button[phx-click='next_step']") |> render_click()

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
      wait_until(fn -> has_element?(second, "button.time-slot-button") end)

      refute has_element?(
               second,
               "button.time-slot-button[phx-value-time='#{taken_time}']"
             )
    end
  end

  describe "Rhythm (theme 2)" do
    @tag :capture_log
    test "group slots show a seat badge", %{user: user} do
      {profile, _meeting_type} =
        setup_booking_page(user, "2", "Group Beat", max_participants: 10)

      {view, _date} = open_schedule_and_pick_tomorrow(profile, "group-beat")

      wait_until(fn -> has_element?(view, "button.time-slot") end)

      html = render(view)
      assert html =~ ~s(data-testid="seat-badge")
      assert html =~ "seat-green"
      assert html =~ "10 seats left"
    end

    @tag :capture_log
    test "solo slots render without any badge markup", %{user: user} do
      {profile, _meeting_type} =
        setup_booking_page(user, "2", "Solo Beat", max_participants: 1)

      {view, _date} = open_schedule_and_pick_tomorrow(profile, "solo-beat")

      wait_until(fn -> has_element?(view, "button.time-slot") end)

      html = render(view)
      refute html =~ "seat-badge"
      refute html =~ "seats left"
    end
  end
end
