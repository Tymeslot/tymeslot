defmodule TymeslotWeb.Live.Dashboard.Availability.ScheduleSwitcherTest do
  @moduledoc """
  LiveView coverage for the availability page's schedule manager: creating a
  schedule and switching the page onto it, and the guard that keeps the default
  schedule undeletable.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Availability.Schedules

  setup :setup_dashboard_user

  setup %{profile: profile} = ctx do
    {:ok, default_schedule} = Schedules.create_default(profile.id)

    Map.put(ctx, :default_schedule, default_schedule)
  end

  describe "creating a schedule" do
    test "creates it and switches the page onto the new schedule", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='show_schedule_form'][phx-value-mode='create']")
      |> render_click()

      view
      |> form("#schedule-name-form", %{"name" => "Consulting hours"})
      |> render_submit()

      html = render(view)
      assert html =~ "Schedule created"
      assert html =~ "Consulting hours"

      created =
        Enum.find(Schedules.list_for_profile(profile.id), &(&1.name == "Consulting hours"))

      refute created.is_default

      # The page follows the new schedule: its option is selected, and the
      # actions only a non-default schedule offers are now available.
      assert has_element?(view, "option[value='#{created.id}'][selected]")
      assert has_element?(view, "[phx-click='set_default_schedule']")
    end

    test "switching back to the default schedule reselects it", %{
      conn: conn,
      profile: profile,
      default_schedule: default_schedule
    } do
      other = insert(:availability_schedule, profile: profile, name: "Evening hours")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> form("form[phx-change='select_schedule']", %{"schedule_id" => to_string(other.id)})
      |> render_change()

      assert has_element?(view, "option[value='#{other.id}'][selected]")

      view
      |> form("form[phx-change='select_schedule']", %{
        "schedule_id" => to_string(default_schedule.id)
      })
      |> render_change()

      assert has_element?(view, "option[value='#{default_schedule.id}'][selected]")
    end
  end

  describe "the default schedule" do
    test "offers no delete action, while another schedule does", %{
      conn: conn,
      profile: profile
    } do
      other = insert(:availability_schedule, profile: profile, name: "Evening hours")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # The default schedule is selected first: neither deleting it nor making
      # it the default again is offered.
      refute has_element?(view, "[phx-click='show_delete_schedule_modal']")
      refute has_element?(view, "[phx-click='set_default_schedule']")

      view
      |> form("form[phx-change='select_schedule']", %{"schedule_id" => to_string(other.id)})
      |> render_change()

      assert has_element?(view, "[phx-click='show_delete_schedule_modal']")
    end
  end

  describe "deleting a schedule" do
    test "names the meeting types that fall back to the default", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      other = insert(:availability_schedule, profile: profile, name: "Evening hours")

      insert(:meeting_type,
        user: user,
        name: "Evening Consultation",
        availability_schedule_id: other.id
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> form("form[phx-change='select_schedule']", %{"schedule_id" => to_string(other.id)})
      |> render_change()

      view |> element("[phx-click='show_delete_schedule_modal']") |> render_click()

      html = render(view)
      assert html =~ "Evening Consultation"

      view |> element("#delete-schedule-modal button", "Delete Schedule") |> render_click()

      assert render(view) =~ "Schedule deleted"
      refute Enum.any?(Schedules.list_for_profile(profile.id), &(&1.id == other.id))
    end
  end
end
