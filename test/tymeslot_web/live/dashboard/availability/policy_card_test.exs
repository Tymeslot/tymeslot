defmodule TymeslotWeb.Live.Dashboard.Availability.PolicyCardTest do
  @moduledoc """
  The scheduling policy (buffer, advance booking window, minimum notice) belongs
  to a named schedule, so it is edited on the availability page. These tests
  moved here from the meeting settings page with the card itself.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Repo

  setup :setup_dashboard_user

  setup %{profile: profile} = ctx do
    {:ok, schedule} = Schedules.create_default(profile.id)

    Map.put(ctx, :schedule, schedule)
  end

  describe "Scheduling preferences" do
    test "selecting a buffer time preset updates the schedule", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='update_buffer_minutes'][phx-value-buffer_minutes='15']")
      |> render_click()

      assert render(view) =~ "Buffer time updated"
      assert Repo.reload!(schedule).buffer_minutes == 15
    end

    test "selecting an advance booking window preset updates the schedule", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='update_advance_booking_days'][phx-value-advance_booking_days='30']")
      |> render_click()

      assert render(view) =~ "Advance booking window updated"
      assert Repo.reload!(schedule).advance_booking_days == 30
    end

    test "selecting a minimum notice preset updates the schedule", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='update_min_advance_hours'][phx-value-min_advance_hours='4']")
      |> render_click()

      assert render(view) =~ "Minimum booking notice updated"
      assert Repo.reload!(schedule).min_advance_hours == 4
    end

    test "entering a custom buffer value outside the allowed range is rejected", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # Enabling custom mode saves a default value; capture it before the invalid attempt
      view
      |> element("[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      persisted_value = Repo.reload!(schedule).buffer_minutes

      # Now attempt an out-of-range update via form change
      view
      |> form("form[phx-change='update_buffer_minutes']", %{"buffer_minutes" => "999"})
      |> render_change()

      # The schedule value must not have changed to 999
      assert Repo.reload!(schedule).buffer_minutes == persisted_value

      # The user must also see an error message explaining the rejection
      assert render(view) =~ "Buffer minutes cannot exceed 120"
    end
  end
end
