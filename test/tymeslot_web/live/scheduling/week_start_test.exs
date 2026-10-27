defmodule TymeslotWeb.Live.Scheduling.WeekStartTest do
  @moduledoc """
  The booking calendar starts its weeks on the visitor's day: the region in
  their `Accept-Language` first, then a language that settles it alone, and
  otherwise the organiser's own first day of the week from their calendar
  settings. Both themes: Quill's month grid and Rhythm's week strip.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :i18n
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  describe "Quill month grid" do
    setup do: setup_host("1")

    @tag :capture_log
    test "a US visitor's grid starts on Sunday", %{conn: conn, profile: profile} do
      doc = schedule_page(conn, profile, "en-US,en;q=0.9")

      assert hd(headings(doc)) == "Sun"
      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid-container")) == 7
    end

    @tag :capture_log
    test "a British visitor's grid starts on Monday", %{conn: conn, profile: profile} do
      doc = schedule_page(conn, profile, "en-GB,en;q=0.9")

      assert hd(headings(doc)) == "Mon"
      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid-container")) == 1
    end

    @tag :capture_log
    test "a bare English header falls back to the organiser's Sunday",
         %{conn: conn, profile: profile} do
      {:ok, _prefs} =
        Management.save_preferences(profile.user_id, %{week_start_day: "sunday"})

      doc = schedule_page(conn, profile, "en")

      assert hd(headings(doc)) == "Sun"
      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid-container")) == 7
    end

    @tag :capture_log
    test "the visitor's region wins over the organiser's setting",
         %{conn: conn, profile: profile} do
      {:ok, _prefs} =
        Management.save_preferences(profile.user_id, %{week_start_day: "sunday"})

      doc = schedule_page(conn, profile, "de-DE")

      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid-container")) == 1
    end

    @tag :capture_log
    test "no header and no organiser setting starts on Monday", %{conn: conn, profile: profile} do
      doc = schedule_page(conn, profile, nil)

      assert hd(headings(doc)) == "Mon"
      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid-container")) == 1
    end
  end

  describe "Rhythm week strip" do
    setup do: setup_host("2")

    @tag :capture_log
    test "a US visitor's week starts on Sunday", %{conn: conn, profile: profile} do
      doc = schedule_page(conn, profile, "en-US")

      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid")) == 7
    end

    @tag :capture_log
    test "a bare English header falls back to the organiser's Sunday",
         %{conn: conn, profile: profile} do
      {:ok, _prefs} =
        Management.save_preferences(profile.user_id, %{week_start_day: "sunday"})

      doc = schedule_page(conn, profile, "en")

      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid")) == 7
    end

    @tag :capture_log
    test "a French visitor's week starts on Monday", %{conn: conn, profile: profile} do
      doc = schedule_page(conn, profile, "fr")

      assert Date.day_of_week(first_grid_date(doc, ".calendar-grid")) == 1
    end
  end

  defp schedule_page(conn, profile, accept_language) do
    conn =
      if accept_language, do: put_req_header(conn, "accept-language", accept_language), else: conn

    {:ok, view, _html} = live(conn, "/#{profile.username}/chat?timezone=Etc/UTC&locale=en")
    view |> render() |> LazyHTML.from_document()
  end

  defp headings(doc) do
    doc
    |> LazyHTML.query(".calendar-weekday")
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  defp first_grid_date(doc, container) do
    [date | _rest] =
      doc
      |> LazyHTML.query("#{container} [data-testid='calendar-day']")
      |> LazyHTML.attribute("data-date")

    Date.from_iso8601!(date)
  end

  defp setup_host(theme_id) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "weekhost#{theme_id}",
        booking_theme: theme_id,
        timezone: "Etc/UTC"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0
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

    insert(:meeting_type, user: user, duration_minutes: 30, name: "Chat", is_active: true)
    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile}
  end
end
