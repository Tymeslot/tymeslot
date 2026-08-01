defmodule TymeslotWeb.Dashboard.MeetingSettings.ReadOnlyCalendarPickerTest do
  @moduledoc """
  User-facing coverage for the read-only-calendar fix: when every calendar
  selected for an integration is read-only, the target-calendar picker must
  explain why the picker is empty instead of rendering a silent blank state.

  Covers two paths that reach the same `@no_writable_calendars` branch in
  `TymeslotWeb.Dashboard.MeetingSettings.Components.BookingComponents`:
  the initial render (`MeetingTypeForm.Init.maybe_initialize/1`) and the
  async calendar-list refresh handler
  (`TymeslotWeb.Dashboard.MeetingFormMessages.handle_calendar_list_refreshed/3`).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarEntry

  setup :setup_dashboard_user

  describe "editing a meeting type whose calendars are all read-only" do
    test "explains why the picker is empty instead of showing a blank state", %{
      conn: conn,
      user: user
    } do
      calendar_integration =
        insert(:calendar_integration,
          user: user,
          calendar_list: [
            %{
              "id" => "cal-1",
              "name" => "Shared (view only)",
              "selected" => true,
              "read_only" => true
            }
          ]
        )

      meeting_type =
        insert(:meeting_type,
          user: user,
          calendar_integration_id: calendar_integration.id,
          target_calendar_id: nil
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      html = render(view)

      assert html =~
               "None of the calendars you selected for this account can accept bookings"

      assert html =~ ~s(href="/dashboard/integrations?tab=calendars")
      refute html =~ "select_target_calendar"
    end
  end

  describe "handle_calendar_list_refreshed/3" do
    test "switches the picker to the explanation once a refresh finds only read-only calendars",
         %{conn: conn, user: user} do
      calendar_integration =
        insert(:calendar_integration,
          user: user,
          calendar_list: [
            %{"id" => "cal-1", "name" => "Primary", "selected" => true, "read_only" => false}
          ]
        )

      meeting_type =
        insert(:meeting_type,
          user: user,
          calendar_integration_id: calendar_integration.id,
          target_calendar_id: "cal-1"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      # Before the refresh, the writable calendar from initialisation renders
      # normally — no explanation, a real target-calendar button.
      html_before = render(view)
      refute html_before =~ "None of the calendars you selected for this account"
      assert html_before =~ "select_target_calendar"

      form_id = "meeting-type-form-edit-#{meeting_type.id}"

      read_only_calendars =
        Enum.map(
          [%{id: "cal-1", name: "Primary", selected: true, read_only: true}],
          &CalendarEntry.normalize/1
        )

      # Simulates the async refresh task's completion message that
      # `DashboardLive.handle_info/2` routes to
      # `MeetingFormMessages.handle_calendar_list_refreshed/3`.
      send(
        view.pid,
        {:calendar_list_refreshed, form_id, calendar_integration.id, read_only_calendars}
      )

      html_after = render(view)

      assert html_after =~
               "None of the calendars you selected for this account can accept bookings"

      assert html_after =~ ~s(href="/dashboard/integrations?tab=calendars")
      refute html_after =~ "select_target_calendar"
    end
  end
end
