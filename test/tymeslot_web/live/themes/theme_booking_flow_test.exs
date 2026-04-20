defmodule TymeslotWeb.Live.Themes.ThemeBookingFlowTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:list_events_in_range, fn _user_id, _start_dt, _end_dt -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  @themes %{
    "1" => %{name: "quill", duration_selector: "quick-chat"},
    "2" => %{name: "rhythm", duration_selector: "quick-chat"}
  }

  describe "theme booking flow (feature-level)" do
    for {theme_id, meta} <- @themes do
      @tag :capture_log
      test "visitor can book end-to-end with #{meta.name} theme", %{conn: conn} do
        timezone = "America/New_York"
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "book-#{unquote(meta.name)}",
            booking_theme: unquote(theme_id),
            timezone: timezone,
            advance_booking_days: 30,
            min_advance_hours: 0,
            buffer_minutes: 0
          )

        _meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Quick Chat",
            is_active: true
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

        _integration =
          insert(:calendar_integration,
            user: user,
            is_active: true
          )

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{timezone}")

        # Overview: select duration + continue
        view
        |> element(
          "button[data-testid='duration-option'][data-duration='#{unquote(meta.duration_selector)}']"
        )
        |> render_click()

        view
        |> element("button[data-testid='next-step']")
        |> render_click()

        # Schedule: pick a date + time slot
        target_date = next_business_day(Date.utc_today())
        date_str = Date.to_string(target_date)

        navigate_calendar_to_date(view, unquote(meta.name), target_date)

        wait_until(fn ->
          has_element?(
            view,
            "button[data-testid='calendar-day'][phx-value-date='#{date_str}']:not([disabled])"
          )
        end)

        view
        |> element("button[data-testid='calendar-day'][phx-value-date='#{date_str}']")
        |> render_click()

        wait_until(fn -> has_element?(view, "button[data-testid='time-slot']") end)

        slot =
          view
          |> render()
          |> Floki.parse_document!()
          |> first_slot_time()

        view
        |> element("button[data-testid='time-slot'][phx-value-time='#{slot}']")
        |> render_click()

        wait_until(fn -> not has_element?(view, "button[data-testid='next-step'][disabled]") end)

        view
        |> element("button[data-testid='next-step']")
        |> render_click()

        # Booking: submit form
        attendee_email = "attendee-#{unquote(meta.name)}@example.com"

        wait_until(fn -> has_element?(view, "form[data-testid='booking-form']") end)

        submit_booking_form(view, unquote(theme_id), %{
          name: "Test Attendee",
          email: attendee_email,
          message: "Hello!"
        })

        wait_until(fn -> has_element?(view, "[data-testid='confirmation-heading']") end, 10_000)

        assert render(view) =~ attendee_email

        meeting =
          Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

        assert meeting.status == "confirmed"
      end
    end
  end

  describe "booking edge cases" do
    @tag :capture_log
    test "blocks booking on a past date via URL manipulation", %{conn: conn} do
      user = insert(:user)
      # Quill
      profile = insert(:profile, user: user, booking_theme: "1", username: "past-fuzzer")
      _integration = insert(:calendar_integration, user: user, is_active: true)

      # Date in the past
      past_date = Date.to_string(Date.add(Date.utc_today(), -1))
      time = "10:00 AM"
      timezone = "America/New_York"

      # Direct link to booking with past date
      {:ok, view, _html} =
        live(
          conn,
          ~p"/#{profile.username}/30-minutes/book?date=#{past_date}&time=#{time}&timezone=#{timezone}"
        )

      # Submit form
      view
      |> form("form[data-testid='booking-form']", %{
        "booking" => %{
          "name" => "Hacker",
          "email" => "hacker@example.com",
          "message" => "I am from the past"
        }
      })
      |> render_submit()

      # The flash is delivered to the parent LiveView via
      # `send(self(), {:flash, _})` from the submission handler, which is
      # processed after `render_submit/1` returns. Drain the mailbox via a
      # synchronous `:sys.get_state/1` before asserting on the render.
      _drain = :sys.get_state(view.pid)

      # Should show error and NOT redirect to confirmation
      assert render(view) =~ "Booking time must be in the future"
      refute has_element?(view, "[data-testid='confirmation-heading']")
    end

    @tag :capture_log
    test "handles DST transition correctly for slot generation", %{conn: conn} do
      # US DST spring-forward: 2nd Sunday of March, 2:00 AM → 3:00 AM.
      # We want to see if slots during the DST gap (2:00-3:00 AM) are skipped.

      timezone = "America/New_York"

      # Find the next 2nd-Sunday-of-March (DST spring-forward) that's in the future
      dst_date = next_dst_spring_forward(Date.utc_today())
      dst_day_of_week = Date.day_of_week(dst_date)

      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          booking_theme: "1",
          timezone: timezone,
          username: "dst-test",
          advance_booking_days: 400,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      _integration = insert(:calendar_integration, user: user, is_active: true)

      _meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "30 Minutes",
          is_active: true
        )

      # Set availability for the DST day (always a Sunday, day_of_week 7)
      insert(:weekly_availability,
        profile: profile,
        day_of_week: dst_day_of_week,
        is_available: true,
        start_time: ~T[01:00:00],
        end_time: ~T[05:00:00]
      )

      dst_date_str = Date.to_string(dst_date)

      # We use schedule route to see generated slots
      {:ok, view, _html} =
        live(
          conn,
          ~p"/#{profile.username}/30-minutes?date=#{dst_date_str}&timezone=#{timezone}"
        )

      # Wait for slots to load
      wait_until(fn -> has_element?(view, "button[data-testid='time-slot']") end)

      slots_html = render(view)

      # 1:00 AM should be there
      # 1:30 AM should be there
      # 2:00 AM - 3:00 AM should NOT be there (it doesn't exist in EST/EDT transition)
      # 3:00 AM should be there

      assert slots_html =~ "1:00 AM"
      assert slots_html =~ "1:30 AM"
      refute slots_html =~ "2:00 AM"
      refute slots_html =~ "2:30 AM"
      assert slots_html =~ "3:00 AM"
      assert slots_html =~ "3:30 AM"
    end
  end

  describe "theme deep-link/refresh contract" do
    for {theme_id, meta} <- @themes do
      @tag :capture_log
      test "visitor can open schedule route directly with #{meta.name} theme", %{conn: conn} do
        timezone = "America/New_York"
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "deeplink-#{unquote(meta.name)}",
            booking_theme: unquote(theme_id),
            timezone: timezone,
            advance_booking_days: 30,
            min_advance_hours: 0,
            buffer_minutes: 0
          )

        _meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Quick Chat",
            is_active: true
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

        _integration =
          insert(:calendar_integration,
            user: user,
            is_active: true
          )

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/quick-chat?timezone=#{timezone}")

        target_date = next_business_day(Date.utc_today())
        date_str = Date.to_string(target_date)

        navigate_calendar_to_date(view, unquote(meta.name), target_date)

        wait_until(fn ->
          has_element?(
            view,
            "button[data-testid='calendar-day'][phx-value-date='#{date_str}']:not([disabled])"
          )
        end)

        view
        |> element("button[data-testid='calendar-day'][phx-value-date='#{date_str}']")
        |> render_click()

        wait_until(fn -> has_element?(view, "button[data-testid='time-slot']") end)
      end

      @tag :capture_log
      test "visitor can open booking route directly with #{meta.name} theme", %{conn: conn} do
        timezone = "America/New_York"
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "deeplink-book-#{unquote(meta.name)}",
            booking_theme: unquote(theme_id),
            timezone: timezone,
            advance_booking_days: 30,
            min_advance_hours: 0,
            buffer_minutes: 0
          )

        _meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Quick Chat",
            is_active: true
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

        _integration =
          insert(:calendar_integration,
            user: user,
            is_active: true
          )

        # Direct link to booking page without a prior date/time selection must
        # redirect to the schedule step rather than showing an unusable booking form.
        assert {:error, {:redirect, %{to: to}}} =
                 live(conn, ~p"/#{profile.username}/quick-chat/book?timezone=#{timezone}")

        assert to == ~p"/#{profile.username}/quick-chat"
      end
    end
  end

  describe "meeting types ordering" do
    for {theme_id, meta} <- @themes do
      @tag :capture_log
      test "preserves user-configured sort_order on the overview step with #{meta.name} theme",
           %{conn: conn} do
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "order-#{unquote(meta.name)}",
            booking_theme: unquote(theme_id),
            timezone: "America/New_York",
            advance_booking_days: 30,
            min_advance_hours: 0,
            buffer_minutes: 0
          )

        _integration = insert(:calendar_integration, user: user, is_active: true)

        insert(:meeting_type,
          user: user,
          name: "Zebra Session",
          duration_minutes: 45,
          sort_order: 0,
          is_active: true
        )

        insert(:meeting_type,
          user: user,
          name: "Alpha Session",
          duration_minutes: 15,
          sort_order: 1,
          is_active: true
        )

        insert(:meeting_type,
          user: user,
          name: "Middle Session",
          duration_minutes: 30,
          sort_order: 2,
          is_active: true
        )

        {:ok, _view, html} = live(conn, ~p"/#{profile.username}?timezone=America/New_York")

        rendered_slugs =
          html
          |> Floki.parse_document!()
          |> Floki.find("button[data-testid='duration-option']")
          |> Enum.map(&Floki.attribute(&1, "data-duration"))
          |> List.flatten()

        assert rendered_slugs == ["zebra-session", "alpha-session", "middle-session"]
      end
    end
  end

  describe "meeting cancel flow (feature-level)" do
    for {theme_id, meta} <- @themes do
      @tag :capture_log
      test "visitor can keep meeting on cancel page with #{meta.name} theme", %{conn: conn} do
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "cancel-keep-#{unquote(meta.name)}",
            booking_theme: unquote(theme_id)
          )

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            organizer_name: user.name,
            attendee_timezone: profile.timezone,
            status: "confirmed"
          )

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel")

        assert has_element?(view, "[data-testid='keep-meeting']")

        view
        |> element("[data-testid='keep-meeting']")
        |> render_click()

        assert render(view) =~ "Meeting Confirmed"
      end

      @tag :capture_log
      test "visitor can cancel meeting from cancel page with #{meta.name} theme", %{conn: conn} do
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "cancel-cancel-#{unquote(meta.name)}",
            booking_theme: unquote(theme_id)
          )

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            organizer_name: user.name,
            attendee_timezone: profile.timezone,
            status: "confirmed"
          )

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel")

        assert has_element?(view, "[data-testid='cancel-meeting']")

        assert {:error, {:redirect, %{to: to}}} =
                 view
                 |> element("[data-testid='cancel-meeting']")
                 |> render_click()

        assert String.contains?(to, "/cancel-confirmed")

        assert Repo.get_by!(MeetingSchema, uid: meeting.uid).status == "cancelled"
      end
    end
  end

  describe "extra booking edge cases" do
    @tag :capture_log
    test "prevents double booking the same slot (race condition simulation)", %{conn: conn} do
      # This test uses a mock to simulate a slow booking process and then attempts a second one.
      # However, since we are in a single-threaded test process usually, we need to be careful.
      # A better way is to use a second connection or just verify the backend logic.

      user = insert(:user)
      profile = insert(:profile, user: user, booking_theme: "1", username: "race-condition")
      _integration = insert(:calendar_integration, user: user, is_active: true)

      date = Date.to_string(next_business_day(Date.utc_today()))
      time = "10:00 AM"
      timezone = "America/New_York"

      # 1. Start first booking
      {:ok, view1, _html} =
        live(
          conn,
          ~p"/#{profile.username}/30-minutes/book?date=#{date}&time=#{time}&timezone=#{timezone}"
        )

      # 2. Start second booking (different attendee)
      {:ok, view2, _html} =
        live(
          conn,
          ~p"/#{profile.username}/30-minutes/book?date=#{date}&time=#{time}&timezone=#{timezone}"
        )

      # Submit first
      view1
      |> form("form[data-testid='booking-form']", %{
        "booking" => %{"name" => "First", "email" => "first@example.com"}
      })
      |> render_submit()

      wait_until(fn -> has_element?(view1, "[data-testid='confirmation-heading']") end)

      # Submit second for the same slot
      view2
      |> form("form[data-testid='booking-form']", %{
        "booking" => %{"name" => "Second", "email" => "second@example.com"}
      })
      |> render_submit()

      # The flash is delivered to the parent LiveView via
      # `send(self(), {:flash, _})` from the submission handler, which is
      # processed after `render_submit/1` returns. Drain the mailbox via a
      # synchronous `:sys.get_state/1` before asserting on the render.
      _drain = :sys.get_state(view2.pid)

      # Second one should fail because the slot is now taken
      assert render(view2) =~ "This time slot is no longer available"
      refute has_element?(view2, "[data-testid='confirmation-heading']")
    end
  end

  defp submit_booking_form(view, _theme_id, %{name: name, email: email, message: message}) do
    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{"name" => name, "email" => email, "message" => message}
    })
    |> render_submit()
  end

  defp first_slot_time(doc) do
    val = List.first(Floki.attribute(doc, "button[data-testid='time-slot']", "phx-value-time"))

    case val do
      nil ->
        data_time =
          List.first(Floki.attribute(doc, "button[data-testid='time-slot']", "data-time"))

        case data_time do
          nil -> flunk("Expected at least one available time slot after selecting a date")
          slot -> slot
        end

      slot ->
        slot
    end
  end

  defp navigate_calendar_to_date(view, theme_name, target_date) do
    today = Date.utc_today()

    case theme_name do
      "quill" ->
        if target_date.year > today.year ||
             (target_date.year == today.year && target_date.month > today.month) do
          view |> element("button[phx-click='next_month']") |> render_click()
        end

      "rhythm" ->
        week_start = Date.beginning_of_week(today, :monday)
        week_end = Date.add(week_start, 6)

        if Date.compare(target_date, week_end) == :gt do
          view |> element("button[phx-click='next_week']") |> render_click()
        end

      _date ->
        :ok
    end
  end

  defp next_business_day(%Date{} = start_date) do
    Enum.find_value(1..14, fn offset ->
      date = Date.add(start_date, offset)
      dow = Date.day_of_week(date)
      if dow in 1..5, do: date, else: nil
    end) || Date.add(start_date, 1)
  end

  # Returns the next 2nd-Sunday-of-March (US DST spring-forward) after `today`.
  defp next_dst_spring_forward(%Date{} = today) do
    Enum.find_value(today.year..(today.year + 2), fn year ->
      date = second_sunday_of_march(year)
      if Date.compare(date, today) == :gt, do: date
    end)
  end

  defp second_sunday_of_march(year) do
    march_1 = Date.new!(year, 3, 1)
    days_to_sunday = rem(7 - Date.day_of_week(march_1), 7)
    first_sunday = Date.add(march_1, days_to_sunday)
    # If March 1 is a Sunday, first_sunday is March 1
    first_sunday = if days_to_sunday == 0, do: march_1, else: first_sunday
    Date.add(first_sunday, 7)
  end
end
