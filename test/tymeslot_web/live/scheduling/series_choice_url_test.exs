defmodule TymeslotWeb.Live.Scheduling.SeriesChoiceUrlTest do
  @moduledoc """
  The series a booker chose rides in the page's URL (`series`), so a
  reconnect (a fresh mount from the address bar) and a language switch (a
  full redirect) keep its count or its picked sessions, on every theme
  that books a series. What the URL carries is visitor input: a value the
  meeting type would not offer gives the default instead, and a carried
  session no longer free is dropped.

  Also here: the fresh reads of the host's calendar a series check and the
  flexible picker make are charged to the visitor (`:booking_series_check`),
  and past the limit nothing is read and the moment says so.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import TymeslotWeb.SeriesBookingHelpers

  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Limits
  alias TymeslotWeb.BookingDriver.Page

  setup :verify_on_exit!
  setup tags, do: setup_series(tags)

  @stepped Keyword.merge(weekly(), series_min_occurrences: 2, series_max_occurrences: 6)
  @flex Keyword.merge(flexible(), series_min_occurrences: 2, series_max_occurrences: 3)

  @themes [quill: {"1", false}, rhythm: {"2", false}, paper: {"3", true}, folio: {"4", true}]

  for {theme, {theme_id, reveal}} <- @themes do
    describe "#{theme}" do
      @describetag theme_id: theme_id
      @describetag flow: [reveal: reveal]

      @tag :capture_log
      test "a remount keeps the count chosen", %{conn: conn, day: day} = ctx do
        %{profile: profile} = organiser(ctx.theme_id, "url-count-#{unquote(theme)}", @stepped)

        view = to_series(conn, profile, day, ctx.flow)
        step_count_up(view, 2)
        assert has_element?(view, "[data-testid='series-count']", "4 sessions")

        url = BookingTestHelpers.last_patched_url(view)
        assert query(url)["series"] == "4"

        view = remount(url)
        assert has_element?(view, "[data-testid='series-count']", "4 sessions")
        assert length(occurrences(view, "available")) == 4
        assert %{mode: :recurring, count: 4} = Page.assigns(view).series_choice
      end

      @tag :capture_log
      test "a remount keeps the sessions picked", %{conn: conn, day: day} = ctx do
        %{profile: profile} = organiser(ctx.theme_id, "url-flex-#{unquote(theme)}", @flex)

        view = to_series(conn, profile, day, ctx.flow)
        add_last_time_of_day(view, 0)
        starts = Page.assigns(view).series_choice.starts
        assert length(starts) == 2

        url = BookingTestHelpers.last_patched_url(view)
        assert "f." <> _offset = query(url)["series"]

        view = remount(url)
        assert Page.assigns(view).series_choice.starts == starts
        assert length(occurrences(view, "available")) == 2
      end
    end
  end

  describe "a language switch" do
    # Folio shows the switcher on every moment; the switch is a full
    # redirect, so only the URL carries the choice across.
    @tag :capture_log
    test "keeps the count chosen", %{conn: conn, day: day} do
      %{profile: profile} = organiser("4", "url-locale-count", @stepped)

      view = to_series(conn, profile, day, reveal: true)
      step_count_up(view, 3)

      to = switch_language(view, "de")
      assert query(to)["series"] == "5"
      assert query(to)["locale"] == "de"

      view = remount(to)
      assert %{mode: :recurring, count: 5} = Page.assigns(view).series_choice
      assert length(occurrences(view, "available")) == 5
    end

    @tag :capture_log
    test "keeps the sessions picked", %{conn: conn, day: day} do
      %{profile: profile} = organiser("4", "url-locale-flex", @flex)

      view = to_series(conn, profile, day, reveal: true)
      add_last_time_of_day(view, 0)
      starts = Page.assigns(view).series_choice.starts

      view = view |> switch_language("de") |> remount()
      assert Page.assigns(view).series_choice.starts == starts
    end
  end

  describe "a tampered series in the URL" do
    @tag :capture_log
    test "a count outside the type's range gives the default", %{conn: conn, day: day} do
      %{profile: profile} = organiser("1", "url-bad-count", @stepped)

      url =
        conn |> to_series(profile, day, reveal: false) |> BookingTestHelpers.last_patched_url()

      for value <- ["7", "1", "0", "-3", "4x", "f.10080", "single", String.duplicate("9", 300)] do
        view = url |> with_series(value) |> remount()

        assert %{mode: :recurring, count: 2} = Page.assigns(view).series_choice,
               "series=#{value} was not refused"
      end
    end

    @tag :capture_log
    test "flexible sessions out of reach give the default", %{conn: conn, day: day} do
      %{profile: profile} = organiser("1", "url-bad-flex", @flex)
      view = to_series(conn, profile, day, reveal: false)
      first = hd(Page.assigns(view).series_choice.starts)
      url = BookingTestHelpers.last_patched_url(view)

      # Before the first, past the year after it, not a number, and more
      # sessions than the type takes.
      for value <- ["f.0", "f.-60", "f.525601", "f.abc", "f.1440.2880.4320", "f1440", "3"] do
        view = url |> with_series(value) |> remount()

        assert Page.assigns(view).series_choice == %{mode: :flexible, starts: [first], count: 1},
               "series=#{value} was not refused"
      end
    end

    @tag :capture_log
    test "a carried session the host does not offer is dropped", %{conn: conn, day: day} do
      %{profile: profile} = organiser("4", "url-unoffered", @flex)
      view = to_series(conn, profile, day, reveal: true)
      add_last_time_of_day(view, 0)
      [first, picked] = Page.assigns(view).series_choice.starts
      url = BookingTestHelpers.last_patched_url(view)

      # 09:01 the day after the first: not a time the schedule offers.
      view = url |> with_series(query(url)["series"] <> ".1441") |> remount()

      assert %{starts: [^first, ^picked], count: 2} = Page.assigns(view).series_choice
      assert length(occurrences(view, "available")) == 2
      assert occurrences(view, "unavailable") == []
    end

    @tag :capture_log
    test "a single session on a type that needs a series gives the default",
         %{conn: conn, day: day} do
      %{profile: profile} = organiser("1", "url-single", @stepped)

      url =
        conn |> to_series(profile, day, reveal: false) |> BookingTestHelpers.last_patched_url()

      view = url |> with_series("single") |> remount()
      assert %{mode: :recurring, count: 2} = Page.assigns(view).series_choice
    end

    @tag :capture_log
    test "a single session on an optional series is kept", %{conn: conn, day: day} do
      %{profile: profile} =
        organiser("1", "url-single-optional", Keyword.put(@stepped, :series_required, false))

      view = to_series(conn, profile, day, reveal: false)
      view |> element("[data-testid='series-book-single']") |> render_click()
      url = BookingTestHelpers.last_patched_url(view)
      assert query(url)["series"] == "single"

      assert url |> remount() |> Page.assigns() |> Map.fetch!(:series_choice) == :single
    end
  end

  describe "the fresh calendar reads" do
    @tag :capture_log
    test "a series check past the visitor's limit reads nothing and says so",
         %{conn: conn, day: day} do
      %{profile: profile} = organiser("1", "limit-count", @stepped)
      view = to_series(conn, profile, day, reveal: false)

      exhaust_series_limit(view)
      count_calendar_reads()

      view |> element("[data-testid='series-count-more']") |> render_click()
      render_async(view)

      assert has_element?(view, "[data-testid='series-check-error']")
      assert has_element?(view, "[data-testid='series-retry']")
      refute_received {:calendar_read, _range}
      refute Page.assigns(view).series_checking?

      # Nor does the retry, while the limit holds; and the way on waits.
      view |> element("[data-testid='series-retry']") |> render_click()
      render_async(view)
      refute_received {:calendar_read, _range}
      assert has_element?(view, "#series-step [data-intent='continue'][disabled]")
    end

    @tag :capture_log
    test "a picker week past the visitor's limit reads nothing and says so",
         %{conn: conn, day: day} do
      %{profile: profile} = organiser("1", "limit-picker", @flex)
      view = to_series(conn, profile, day, reveal: false)

      exhaust_series_limit(view)
      count_calendar_reads()

      view |> element("[data-testid='series-add']") |> render_click()
      render_async(view)

      assert %{error: :rate_limited, loading?: false} = Page.assigns(view).series_picker
      assert has_element?(view, "[data-testid='series-check-error']")
      refute_received {:calendar_read, _range}
    end

    # The picker's week and the check of the choice with a session added
    # are a charge each: with two left both run, and the next week is refused.
    @tag :capture_log
    test "every check and every picker week is charged to the visitor",
         %{conn: conn, day: day} do
      %{profile: profile} = organiser("1", "limit-charged", @flex)
      view = to_series(conn, profile, day, reveal: false)
      ip = Page.assigns(view).client_ip

      RateLimiter.clear_all()
      limit = Limits.fetch!(:booking_series_check)[:limit]
      for _hit <- 1..(limit - 2), do: :ok = RateLimiter.check(:booking_series_check, ip)

      add_last_time_of_day(view, 0)
      assert length(occurrences(view, "available")) == 2

      view |> element("[data-testid='series-add']") |> render_click()
      render_async(view)
      assert %{error: :rate_limited} = Page.assigns(view).series_picker
    end
  end

  # A reconnect: a fresh LiveView mounted from the URL in the address bar,
  # read once the series moment's check has answered.
  defp remount(url) do
    {:ok, view, _html} = live(build_conn(), url)

    Page.wait(
      fn ->
        render_async(view)
        assigns = Page.assigns(view)
        assigns.series_choice != nil and not assigns.series_checking?
      end,
      "the series never settled after the remount"
    )

    view
  end

  defp step_count_up(view, times) do
    for _step <- 1..times do
      view |> element("[data-testid='series-count-more']") |> render_click()
      render_async(view)
    end

    :ok
  end

  defp switch_language(view, locale) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    {:error, {:redirect, %{to: to}}} =
      view
      |> element("button[phx-click='change_locale'][phx-value-locale='#{locale}']")
      |> render_click()

    to
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp with_series(url, value), do: with_param(url, "series", value)

  defp with_param(url, key, value) do
    uri = URI.parse(url)

    query = uri.query |> URI.decode_query() |> Map.put(key, value) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  defp exhaust_series_limit(view) do
    ip = Page.assigns(view).client_ip

    charges = Stream.repeatedly(fn -> RateLimiter.check(:booking_series_check, ip) end)
    Enum.find(charges, &match?({:error, :rate_limited, _message}, &1))
  end

  defp count_calendar_reads do
    test = self()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, from, to ->
      send(test, {:calendar_read, {from, to}})
      {:ok, []}
    end)
  end
end
