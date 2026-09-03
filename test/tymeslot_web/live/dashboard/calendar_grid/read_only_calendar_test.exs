defmodule TymeslotWeb.Dashboard.CalendarGrid.ReadOnlyCalendarTest do
  @moduledoc """
  Events on a calendar the provider will not accept writes to.

  A subscribed feed is the organiser's own integration, and a shared Google
  calendar can be owned yet granted with `reader` access only, so ownership
  alone cannot decide whether the detail modal may offer edit and delete
  controls. Offering them anyway sent the
  organiser through a confirmation dialog into a provider round-trip that
  could only ever come back "Failed to delete event".

  What is asserted here is the user-visible half of that: the controls are
  not offered, and a write that arrives regardless (a stale socket, a forged
  event) is refused with a message that names the reason.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  describe "an event on a read-only provider (subscribed feed)" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "ics_url",
          name: "Team holidays",
          calendar_list: [%{id: "feed", name: "Team holidays", selected: true, read_only: true}]
        )

      {:ok, event: insert_event(integration, "ics_url", "feed", "Bank Holiday")}
    end

    test "the detail modal offers neither delete nor an editable title", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "Bank Holiday"
      refute html =~ "Delete event"
      refute html =~ "event-title-input"
    end

    test "a delete request is refused instead of opening the confirmation", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv |> element("#calendar-grid") |> render_hook("request_delete_event", %{})

      # The flash is relayed to the parent LiveView, so it lands on the next
      # render rather than in the hook's own reply.
      html = render(lv)

      assert html =~ "This calendar is read-only"
      refute html =~ "Are you sure you want to delete"
    end

    test "a title edit is refused and the event keeps its summary", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      html = render(lv)

      assert html =~ "This calendar is read-only"
      refute html =~ "Renamed"
      assert html =~ "Bank Holiday"
    end
  end

  describe "an event on a read-only calendar of a writable provider" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "google",
          name: "Work",
          calendar_list: [
            %{id: "own", name: "Own calendar", selected: true, read_only: false},
            %{id: "shared", name: "Shared with me", selected: true, read_only: true}
          ]
        )

      {:ok,
       shared_event: insert_event(integration, "google", "shared", "All-hands"),
       own_event: insert_event(integration, "google", "own", "One-to-one")}
    end

    test "the shared calendar's event is not editable", %{conn: conn, shared_event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "All-hands"
      refute html =~ "Delete event"
    end

    test "the organiser's own calendar under the same account stays editable", %{
      conn: conn,
      own_event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "One-to-one"
      assert html =~ "Delete event"
      assert html =~ "event-title-input"
    end
  end

  defp insert_event(integration, provider, calendar_id, summary) do
    today = Date.utc_today()

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: provider,
      provider_calendar_id: calendar_id,
      summary: summary,
      start_at: DateTime.new!(today, ~T[09:00:00], "Etc/UTC"),
      end_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
      all_day: false
    )
  end
end
