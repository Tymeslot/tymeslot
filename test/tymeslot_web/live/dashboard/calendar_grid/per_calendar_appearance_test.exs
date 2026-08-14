defmodule TymeslotWeb.Dashboard.CalendarGrid.PerCalendarAppearanceTest do
  @moduledoc """
  Showing, hiding and colouring one calendar inside a connected account, from
  the dashboard calendar's "My Calendars" dropdown.

  The pieces below this are covered elsewhere: `appearance_test.exs` for the
  store and its ownership check, `calendar_colour_classes_test.exs` for the
  order a colour is resolved in. What is asserted here is what only the
  LiveView can show: that a choice made in the dropdown reaches the grid, and
  that it does not take the account's other calendars with it.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Appearance

  setup :setup_dashboard_user

  setup %{user: user} do
    integration =
      insert(:calendar_integration,
        user: user,
        is_active: true,
        name: "Work",
        calendar_list: [
          %{id: "cal-main", name: "Main calendar", selected: true},
          %{id: "cal-birthdays", name: "Birthdays", selected: true}
        ]
      )

    {:ok, integration: integration}
  end

  defp open_dropdown(view) do
    view |> element("button[phx-click='toggle_calendar_list']") |> render_click()
  end

  defp grid_html(html) do
    html |> Floki.parse_document!() |> Floki.find("#calendar-grid") |> Floki.raw_html()
  end

  # The class list of the grid element rendering the event with this title.
  defp event_classes(html, summary) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[id^='event-']")
    |> Enum.filter(&(Floki.text(&1) =~ summary))
    |> Floki.attribute("class")
    |> Enum.join(" ")
  end

  defp pressed?(html, calendar_id, colour) do
    html
    |> Floki.parse_document!()
    |> Floki.find(
      ~s(button[phx-value-calendar_id="#{calendar_id}"][phx-value-colour="#{colour}"])
    )
    |> Floki.attribute("aria-pressed")
    |> Enum.any?(&(&1 == "true"))
  end

  describe "the My Calendars dropdown" do
    test "lists each synced calendar under its account", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")

      html = open_dropdown(view)

      assert html =~ "Work"
      assert html =~ "Main calendar"
      assert html =~ "Birthdays"
    end

    test "omits a calendar the organiser has not selected for sync", %{conn: conn, user: user} do
      insert(:calendar_integration,
        user: user,
        is_active: true,
        name: "Other account",
        calendar_list: [%{id: "cal-off", name: "Not synced", selected: false}]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")

      refute open_dropdown(view) =~ "Not synced"
    end
  end

  describe "hiding one calendar" do
    test "stores the choice against that calendar alone", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      view
      |> element(
        "input[phx-click='toggle_calendar_visibility'][phx-value-calendar-id='cal-birthdays']"
      )
      |> render_click()

      assert [%{provider_calendar_id: "cal-birthdays", hidden: true}] =
               Appearance.list_for_user(user.id)
    end

    test "clicking again shows it once more", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      selector =
        "input[phx-click='toggle_calendar_visibility'][phx-value-calendar-id='cal-birthdays']"

      view |> element(selector) |> render_click()
      view |> element(selector) |> render_click()

      assert [%{hidden: false}] = Appearance.list_for_user(user.id)
    end

    test "takes that calendar's events out of the grid and leaves its siblings", %{
      conn: conn,
      integration: integration
    } do
      # The assertions above prove the row is written. This one proves the row
      # is read: without it, deleting the filter entirely still passes the suite.
      today = Date.utc_today()
      at = DateTime.new!(today, ~T[10:00:00], "Etc/UTC")

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_calendar_id: "cal-birthdays",
        summary: "Someone's birthday",
        start_at: at,
        end_at: DateTime.add(at, 3600)
      )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_calendar_id: "cal-main",
        summary: "Sprint planning",
        start_at: at,
        end_at: DateTime.add(at, 3600)
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      assert view |> render() |> grid_html() =~ "Someone&#39;s birthday"

      open_dropdown(view)

      html =
        view
        |> element(
          "input[phx-click='toggle_calendar_visibility'][phx-value-calendar-id='cal-birthdays']"
        )
        |> render_click()

      # Scoped to the grid: the Up-next strip above it reads `Agenda`, which
      # works from the account's active integrations and knows nothing about
      # per-calendar visibility, so it still names whichever event is next.
      refute grid_html(html) =~ "Someone&#39;s birthday"
      assert grid_html(html) =~ "Sprint planning"
    end

    test "leaves the account-level toggle untouched", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      view
      |> element(
        "input[phx-click='toggle_calendar_visibility'][phx-value-calendar-id='cal-birthdays']"
      )
      |> render_click()

      # Hiding one calendar must not hide the whole account: the two controls
      # are separate stores, and conflating them would lose the finer choice.
      assert CalendarGrid.get_or_create_preferences(user.id).hidden_integration_ids == []
    end
  end

  describe "colouring one calendar" do
    test "stores the palette key against that calendar", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      view
      |> element(
        "button[phx-click='set_calendar_colour'][phx-value-calendar_id='cal-main'][phx-value-colour='banana']"
      )
      |> render_click()

      assert [%{provider_calendar_id: "cal-main", colour: "banana"}] =
               Appearance.list_for_user(user.id)
    end

    test "paints that calendar's events in the grid and leaves its siblings alone", %{
      conn: conn,
      integration: integration
    } do
      # Storing the row is not the feature; painting the event is. Asserting only
      # on the stored colour passes even when no view receives the colour map,
      # which is exactly how the first version of this shipped broken.
      at = DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC")

      for {cal, summary} <- [{"cal-main", "Sprint planning"}, {"cal-birthdays", "A birthday"}] do
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider_calendar_id: cal,
          summary: summary,
          start_at: at,
          end_at: DateTime.add(at, 3600)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      view
      |> element(
        "button[phx-click='set_calendar_colour'][phx-value-calendar_id='cal-main'][phx-value-colour='tomato']"
      )
      |> render_click()

      html = render(view)

      assert event_classes(html, "Sprint planning") =~ "bg-calendar-tomato"
      refute event_classes(html, "A birthday") =~ "bg-calendar-tomato"
    end

    test "leaves the account's other calendars inheriting", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      view
      |> element(
        "button[phx-click='set_calendar_colour'][phx-value-calendar_id='cal-main'][phx-value-colour='banana']"
      )
      |> render_click()

      keys = user.id |> Appearance.list_for_user() |> Enum.map(& &1.provider_calendar_id)

      refute "cal-birthdays" in keys
    end

    test "the clearing pill restores inheritance rather than storing a colour", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      view
      |> element(
        "button[phx-click='set_calendar_colour'][phx-value-calendar_id='cal-main'][phx-value-colour='banana']"
      )
      |> render_click()

      view
      |> element(
        "button[phx-click='set_calendar_colour'][phx-value-calendar_id='cal-main'][phx-value-colour='default']"
      )
      |> render_click()

      assert [%{colour: nil}] = Appearance.list_for_user(user.id)
    end

    test "marks the chosen swatch as pressed without a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")
      open_dropdown(view)

      html =
        view
        |> element(
          "button[phx-click='set_calendar_colour'][phx-value-calendar_id='cal-main'][phx-value-colour='banana']"
        )
        |> render_click()

      # The swatch reads its pressed state from `calendar_colour_keys`, which is
      # a different assign from the one the grid paints with. Refreshing only
      # the painting map would leave the control the organiser just clicked
      # looking unselected. Parsed rather than regexed so the assertion does not
      # depend on the order the attributes happen to be rendered in.
      assert pressed?(html, "cal-main", "banana")
      refute pressed?(html, "cal-main", "grape")
    end
  end
end
