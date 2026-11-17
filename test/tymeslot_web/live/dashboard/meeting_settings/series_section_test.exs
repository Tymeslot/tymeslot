defmodule TymeslotWeb.Dashboard.MeetingSettings.SeriesSectionTest do
  @moduledoc """
  The meeting type editor's Series section: switching a series on and
  setting it up saves the type, the modes a type cannot offer are disabled
  with the reason, the notes where the series meets the booking window and
  limits show, and without the plan the section is locked, or read-only for
  a type that already has a series.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  defp edit(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp toggle(view),
    do: view |> element("input[phx-value-series_action='toggle']") |> render_click()

  defp reload(meeting_type),
    do: MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)

  defp change_series(view, field, value) do
    view
    |> element("input[name='series[#{field}]']")
    |> render_change(%{"series" => %{field => value}})
  end

  defp form_wrapper(meeting_type),
    do: "#meeting-type-form-wrapper-meeting-type-form-edit-#{meeting_type.id}"

  defp weekly_series(attrs \\ []) do
    Keyword.merge(
      [
        series_mode: :recurring,
        series_frequency: :weekly,
        series_interval: 1,
        series_min_occurrences: 4,
        series_max_occurrences: 4
      ],
      attrs
    )
  end

  test "turning series on saves a recurring series", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user)
    view = edit(conn, meeting_type)

    refute has_element?(view, "[data-testid='series-mode-recurring']")

    toggle(view)
    change_series(view, "rhythm", "weekly:1")
    change_series(view, "min", "4")
    change_series(view, "max", "4")

    saved = %{
      series_mode: :recurring,
      series_frequency: :weekly,
      series_interval: 1,
      series_min_occurrences: 4,
      series_max_occurrences: 4,
      series_required: true
    }

    assert Map.take(reload(meeting_type), Map.keys(saved)) == saved
    assert has_element?(view, "[data-testid='series-mode-recurring'][aria-pressed='true']")

    # An unrelated change saves the whole form, and keeps the series as it is.
    view
    |> element("input[name='meeting_type[name]']")
    |> render_change(%{"meeting_type" => %{"name" => "Six-week course"}})

    reloaded = reload(meeting_type)
    assert reloaded.name == "Six-week course"
    assert Map.take(reloaded, Map.keys(saved)) == saved
  end

  test "unticking the fixed number opens a range above the minimum",
       %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type, [user: user] ++ weekly_series(series_min_occurrences: 4))

    view = edit(conn, meeting_type)

    assert has_element?(view, "input[phx-value-series_action='fixed'][checked]")
    view |> element("input[phx-value-series_action='fixed']") |> render_click()

    assert %{series_min_occurrences: 4, series_max_occurrences: 5} = reload(meeting_type)
    assert has_element?(view, "input[name='series[max]'][value='5']")
  end

  test "a count out of range shows its error on the field", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user)
    view = edit(conn, meeting_type)

    toggle(view)
    change_series(view, "max", "30")

    assert has_element?(view, "[id^='series-max-'][id$='-error']", "must be between 2 and 26")
    refute has_element?(view, "[id^='series-min-'][id$='-error']")

    assert reload(meeting_type).series_max_occurrences == 8
  end

  test "the fixed number ties the maximum to the minimum, and a single session can be allowed",
       %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user)
    view = edit(conn, meeting_type)

    toggle(view)
    view |> element("input[phx-value-series_action='fixed']") |> render_click()
    change_series(view, "min", "6")

    refute has_element?(view, "input[name='series[max]']")

    view |> element("input[phx-value-series_action='single']") |> render_click()

    assert %{series_min_occurrences: 6, series_max_occurrences: 6, series_required: false} =
             reload(meeting_type)
  end

  test "flexible mode hides the frequency", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user)
    view = edit(conn, meeting_type)

    toggle(view)
    assert has_element?(view, "[data-testid='series-rhythm']")

    view |> element("[data-testid='series-mode-flexible']") |> render_click()

    refute has_element?(view, "[data-testid='series-rhythm']")
    refute has_element?(view, "input[name='series[rhythm]']")
    assert %{series_mode: :flexible, series_frequency: nil} = reload(meeting_type)
  end

  test "a monthly series explains which day it falls on", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user)
    view = edit(conn, meeting_type)

    toggle(view)
    change_series(view, "rhythm", "monthly:1")

    assert render(view) =~ "On the same weekday of the month, for example the second Thursday."
    assert %{series_frequency: :monthly, series_interval: 1} = reload(meeting_type)
  end

  test "a rhythm too slow for the maximum within a year shows the error on the maximum",
       %{conn: conn, user: user} do
    meeting_type =
      insert(
        :meeting_type,
        [user: user] ++ weekly_series(series_min_occurrences: 2, series_max_occurrences: 8)
      )

    view = edit(conn, meeting_type)

    change_series(view, "rhythm", "monthly:4")

    assert has_element?(
             view,
             "[id^='series-max-'][id$='-error']",
             "must be at most 3 at this rhythm, so that every session falls within a year"
           )

    refute has_element?(view, "[id^='series-min-'][id$='-error']")
    assert %{series_frequency: :weekly, series_max_occurrences: 8} = reload(meeting_type)
  end

  test "one-off types cannot turn series on", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, one_off: true, max_participants: 5)
    view = edit(conn, meeting_type)

    assert has_element?(view, "input[phx-value-series_action='toggle'][disabled]")
    assert render(view) =~ "One-off meeting types cannot be booked as a series."

    view
    |> with_target(form_wrapper(meeting_type))
    |> render_click("update_series", %{"series_action" => "toggle"})

    assert reload(meeting_type).series_mode == nil
  end

  test "types that ask invitees to confirm their email cannot turn series on",
       %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, requires_email_verification: true)
    view = edit(conn, meeting_type)

    assert has_element?(view, "input[phx-value-series_action='toggle'][disabled]")

    assert render(view) =~
             "Meeting types that ask invitees to confirm their email cannot be booked as a series."

    view
    |> with_target(form_wrapper(meeting_type))
    |> render_click("update_series", %{"series_action" => "toggle"})

    assert reload(meeting_type).series_mode == nil
  end

  test "a type with fixed dates offers only sessions the booker picks",
       %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, fixed_dates: true)
    view = edit(conn, meeting_type)

    toggle(view)

    assert has_element?(view, "[data-testid='series-mode-recurring'][disabled]")

    assert has_element?(
             view,
             "[data-testid='series-mode-recurring-reason']",
             "only as sessions the booker picks"
           )

    assert reload(meeting_type).series_mode == :flexible

    view
    |> with_target(form_wrapper(meeting_type))
    |> render_click("update_series", %{"series_action" => "mode", "mode" => "recurring"})

    assert reload(meeting_type).series_mode == :flexible
  end

  test "the booking window note shows while a series is on", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, advance_booking_days: 30)
    view = edit(conn, meeting_type)

    refute has_element?(view, "[data-testid='series-booking-window']")
    refute has_element?(view, "[data-testid='booking-window-series-note']")

    toggle(view)

    assert has_element?(
             view,
             "[data-testid='series-booking-window']",
             "Your booking window (30 days) applies to the first session only."
           )

    assert has_element?(
             view,
             "[data-testid='booking-window-series-note']",
             "this applies to the first session only"
           )
  end

  test "a weekly series with a monthly cap of 2 warns", %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type, [user: user, max_bookings_per_month: 2] ++ weekly_series())

    view = edit(conn, meeting_type)

    message =
      "Your limit of 2 bookings per month is lower than the 4 sessions a series can book in one month"

    assert has_element?(view, "[data-testid='series-limit-conflict']", message)
    assert has_element?(view, "[data-testid='limits-series-conflict']", message)
  end

  test "group and paid series say how they count", %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type, [user: user, max_participants: 6] ++ weekly_series())

    view = edit(conn, meeting_type)

    assert has_element?(
             view,
             "[data-testid='series-group']",
             "Each session in a series takes one seat."
           )

    refute has_element?(view, "[data-testid='series-paid']")
  end

  test "a series on a type taking guests says guests are for single bookings",
       %{conn: conn, user: user} do
    with_guests = insert(:meeting_type, [user: user, allow_guests: true] ++ weekly_series())
    without_guests = insert(:meeting_type, [user: user, allow_guests: false] ++ weekly_series())

    assert has_element?(
             edit(conn, with_guests),
             "[data-testid='series-guests']",
             "Guests can only be added to single bookings, not to a series."
           )

    refute has_element?(edit(conn, without_guests), "[data-testid='series-guests']")
  end

  describe "without the plan" do
    defmodule DenyRecurringChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :recurring_bookings_allowed), do: {:error, :insufficient_plan}
      def check_access(_user_id, _feature), do: :ok
    end

    setup do
      assigns = Application.get_env(:tymeslot, :feature_assigns, [])

      setup_config(:tymeslot,
        feature_access_checker: DenyRecurringChecker,
        feature_assigns: Keyword.put(assigns, :recurring_bookings_allowed, false),
        feature_placeholder_components: nil
      )
    end

    test "locked without access", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user)
      view = edit(conn, meeting_type)

      assert has_element?(
               view,
               "[data-testid='series-locked']",
               "Recurring bookings are not included in your current plan."
             )

      refute has_element?(view, "input[phx-value-series_action='toggle']")

      view
      |> with_target(form_wrapper(meeting_type))
      |> render_click("update_series", %{"series_action" => "toggle"})

      assert reload(meeting_type).series_mode == nil
    end

    test "read-only when access is gone", %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, [user: user, max_bookings_per_month: 2] ++ weekly_series())

      view = edit(conn, meeting_type)

      refute has_element?(view, "[data-testid='series-locked']")

      assert has_element?(
               view,
               "[data-testid='series-paused']",
               "Series booking is paused: this meeting type books single sessions until you upgrade."
             )

      assert has_element?(view, "input[name='series[min]'][disabled]")
      assert has_element?(view, "input[phx-value-series_action='single'][disabled]")
      assert has_element?(view, "[data-testid='series-mode-flexible'][disabled]")

      # The notes describe a series that books; this one does not.
      refute has_element?(view, "[data-testid='series-booking-window']")
      refute has_element?(view, "[data-testid='series-limit-conflict']")
      refute has_element?(view, "[data-testid='limits-series-conflict']")
      refute has_element?(view, "[data-testid='booking-window-series-note']")

      view
      |> with_target(form_wrapper(meeting_type))
      |> render_click("update_series", %{"series_action" => "single"})

      # Other changes still save, and keep the series as it was.
      view
      |> element("input[name='meeting_type[name]']")
      |> render_change(%{"meeting_type" => %{"name" => "Renamed course"}})

      assert %{
               name: "Renamed course",
               series_mode: :recurring,
               series_max_occurrences: 4,
               series_required: true
             } = reload(meeting_type)
    end

    test "a paused series can be switched off, which frees the type to be invitation-only",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, [user: user] ++ weekly_series())
      view = edit(conn, meeting_type)

      refute has_element?(view, "input[phx-value-series_action='toggle'][disabled]")
      toggle(view)

      assert reload(meeting_type).series_mode == nil
      assert has_element?(view, "[data-testid='series-locked']")

      view |> element("#meeting-type-invitation-only-toggle-#{meeting_type.id}") |> render_click()

      assert %{series_mode: nil, invitation_only: true} = reload(meeting_type)
    end
  end
end
