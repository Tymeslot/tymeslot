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

  describe "duplicating a schedule" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")
      view |> element("[phx-click='toggle_schedule_menu']") |> render_click()

      %{view: view}
    end

    test "says nothing extra when there were no overrides to lose", %{view: view} do
      view |> element("[phx-click='duplicate_schedule']") |> render_click()

      html = render(view)
      assert html =~ "Schedule duplicated"
      refute html =~ "date overrides were not copied"
    end

    test "warns that date overrides did not come along", %{
      view: view,
      default_schedule: default_schedule
    } do
      # A copy takes the hours, breaks and rules but not the dated exceptions,
      # so a host who blocked a holiday would otherwise find it silently absent.
      insert(:availability_override, schedule: default_schedule, date: ~D[2026-12-24])

      view |> element("[phx-click='duplicate_schedule']") |> render_click()

      assert render(view) =~ "date overrides were not copied"
    end
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

      # The page follows the new schedule: its tab is the selected one, and the
      # actions only a non-default schedule offers are now available.
      assert has_element?(view, "#tab-#{created.id}[aria-selected='true']")

      view |> element("[phx-click='toggle_schedule_menu']") |> render_click()
      assert has_element?(view, "[phx-click='set_default_schedule']")
    end

    test "switching back to the default schedule reselects it", %{
      conn: conn,
      profile: profile,
      default_schedule: default_schedule
    } do
      other = insert(:availability_schedule, profile: profile, name: "Evening hours")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("#tab-#{other.id}") |> render_click()

      assert has_element?(view, "#tab-#{other.id}[aria-selected='true']")

      view |> element("#tab-#{default_schedule.id}") |> render_click()

      assert has_element?(view, "#tab-#{default_schedule.id}[aria-selected='true']")
    end

    test "reopens the schedule named in the query string", %{
      conn: conn,
      profile: profile
    } do
      other = insert(:availability_schedule, profile: profile, name: "Evening hours")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability?schedule=#{other.id}")

      assert has_element?(view, "#tab-#{other.id}[aria-selected='true']")
    end

    test "falls back to the default when the query string names a stale schedule", %{
      conn: conn,
      default_schedule: default_schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability?schedule=999999")

      assert has_element?(view, "#tab-#{default_schedule.id}[aria-selected='true']")
    end
  end

  describe "the schedule limit" do
    test "stops offering creation once the profile owns the maximum", %{
      conn: conn,
      profile: profile
    } do
      # One default already exists, so this fills the remaining slots.
      for n <- 2..Schedules.max_schedules() do
        insert(:availability_schedule, profile: profile, name: "Schedule #{n}")
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # The button stays put and greys out, so the ceiling is visible rather
      # than inferred from a control that vanished.
      refute has_element?(view, "[phx-click='show_schedule_form'][phx-value-mode='create']")
      assert has_element?(view, "button[disabled]", "New schedule")
      assert render(view) =~ "reached the limit"

      # Duplicating would also push past the cap, so the menu drops it too.
      view |> element("[phx-click='toggle_schedule_menu']") |> render_click()
      refute has_element?(view, "[phx-click='duplicate_schedule']")
    end

    test "refuses to create past the maximum", %{profile: profile} do
      for n <- 2..Schedules.max_schedules() do
        insert(:availability_schedule, profile: profile, name: "Schedule #{n}")
      end

      assert {:error, :schedule_limit_reached} =
               Schedules.create(profile.id, %{name: "One too many"})

      assert length(Schedules.list_for_profile(profile.id)) == Schedules.max_schedules()
    end
  end

  describe "the default schedule" do
    test "offers no delete action, while another schedule does", %{
      conn: conn,
      profile: profile
    } do
      other = insert(:availability_schedule, profile: profile, name: "Evening hours")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view |> element("[phx-click='toggle_schedule_menu']") |> render_click()

      # The default schedule is selected first: neither deleting it nor making
      # it the default again is offered.
      refute has_element?(view, "[phx-click='show_delete_schedule_modal']")
      refute has_element?(view, "[phx-click='set_default_schedule']")

      view |> element("#tab-#{other.id}") |> render_click()
      view |> element("[phx-click='toggle_schedule_menu']") |> render_click()

      assert has_element?(view, "[phx-click='show_delete_schedule_modal']")
    end

    test "the management actions stay behind the menu until it is opened", %{
      conn: conn,
      profile: profile
    } do
      insert(:availability_schedule, profile: profile, name: "Evening hours")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # Closed by default, so the tabs are the loudest thing on the strip.
      refute has_element?(view, "[phx-click='show_schedule_form'][phx-value-mode='rename']")

      view |> element("[phx-click='toggle_schedule_menu']") |> render_click()

      assert has_element?(view, "[phx-click='show_schedule_form'][phx-value-mode='rename']")
    end
  end

  describe "what a schedule applies to" do
    test "names the meeting types booked against the selected schedule", %{
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

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability?schedule=#{other.id}")

      assert render(view) =~ "Used by Evening Consultation."
    end

    test "says so when a non-default schedule is used by nothing", %{
      conn: conn,
      profile: profile
    } do
      other = insert(:availability_schedule, profile: profile, name: "Evening hours")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability?schedule=#{other.id}")

      assert render(view) =~ "No meeting type uses these hours yet"
    end

    test "explains that the default catches everything unassigned", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      assert render(view) =~ "Used by every meeting type that has no schedule of its own."
    end

    test "the default still says it catches everything unassigned when named explicitly", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      # Naming the default on a meeting type does not stop it applying to the
      # ones that name nothing, so listing only the explicit user would
      # understate what editing these hours affects.
      default = Schedules.get_default(profile.id)

      insert(:meeting_type,
        user: user,
        name: "Standing Review",
        availability_schedule_id: default.id
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability?schedule=#{default.id}")

      html = render(view)

      assert html =~ "Used by Standing Review, and by every meeting type"
      assert html =~ "that has no schedule of its own."
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

      view |> element("#tab-#{other.id}") |> render_click()

      view |> element("[phx-click='toggle_schedule_menu']") |> render_click()
      view |> element("[phx-click='show_delete_schedule_modal']") |> render_click()

      html = render(view)
      assert html =~ "Evening Consultation"

      view |> element("#delete-schedule-modal button", "Delete Schedule") |> render_click()

      assert render(view) =~ "Schedule deleted"
      refute Enum.any?(Schedules.list_for_profile(profile.id), &(&1.id == other.id))
    end
  end
end
