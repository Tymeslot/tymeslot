defmodule TymeslotWeb.Dashboard.CalendarGrid.EventAsyncResultsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "async event update failure" do
    test "reverts event and shows error flash when update fails", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Failing Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Failing Event"

      # Simulate the async error result message arriving at the LiveView
      send(lv.pid, {:event_update_result, {:error, original_event: event, reason: :api_error}})

      html = render(lv)
      assert html =~ "Failed to update event"
      assert html =~ "Failing Event"
    end
  end

  describe "async event create result" do
    test "caches new event and refreshes grid when task reports success", %{
      conn: conn,
      user: user
    } do
      # Regression: the dashboard create flow runs in a Task that sends
      # {:create_event_result, ...} back to the LiveView pid. Two historical bugs
      # crashed this path:
      #
      # 1. CreateExecution.handle_create_result/2 looked up integrations on the
      #    parent LiveView socket, which never carries the :integrations assign.
      # 2. CalendarGrid.cache_created_event/1 received second-precision
      #    DateTimes built from DateTime.new!, but the schema requires
      #    microsecond precision.
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      start_at = DateTime.new!(Date.utc_today(), ~T[15:45:00], "Etc/UTC")
      end_at = DateTime.new!(Date.utc_today(), ~T[16:15:00], "Etc/UTC")

      creating = %{
        date: Date.to_iso8601(Date.utc_today()),
        end_date: Date.to_iso8601(Date.utc_today()),
        title: "Dashboard Created Event",
        integration_id: integration.id,
        calendar_id: "primary",
        attendees: [],
        attendee_input: "",
        video_integration_id: nil,
        start_hour: 15,
        start_minute: 45,
        end_hour: 16,
        end_minute: 15
      }

      send(
        lv.pid,
        {:create_event_result,
         {:ok,
          %{
            uid: "dashboard-created-uid",
            creating: creating,
            start_at: start_at,
            end_at: end_at,
            provider: "google",
            default_booking_calendar_id: "primary",
            attendees: [],
            meeting_url: nil,
            description: nil
          }}}
      )

      # First render flushes handle_info and the send_update to the component;
      # second render processes the event_created action and reloads events.
      render(lv)
      assert render(lv) =~ "Dashboard Created Event"
    end

    test "shows reconnect flash when task signals reauth_required", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      start_at = DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC")
      end_at = DateTime.new!(Date.utc_today(), ~T[10:30:00], "Etc/UTC")

      creating = %{
        date: Date.to_iso8601(Date.utc_today()),
        end_date: Date.to_iso8601(Date.utc_today()),
        title: "Reauth Event",
        integration_id: integration.id,
        calendar_id: "primary",
        attendees: [],
        attendee_input: "",
        video_integration_id: nil,
        start_hour: 10,
        start_minute: 0,
        end_hour: 10,
        end_minute: 30
      }

      send(
        lv.pid,
        {:create_event_result,
         {:ok,
          %{
            uid: "reauth-event-uid",
            creating: creating,
            start_at: start_at,
            end_at: end_at,
            provider: "google",
            default_booking_calendar_id: "primary",
            attendees: [],
            meeting_url: nil,
            description: nil,
            reauth_required: true
          }}}
      )

      html = render(lv)
      assert html =~ "reconnected"
    end
  end

  describe "async event move result" do
    test "error path reverts event and flashes", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Move Me",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:event_move_result, {:error, original_event: event, reason: :api_error}})

      html = render(lv)
      assert html =~ "Could not move the event. It is still on its original calendar."
      assert html =~ "Move Me"
    end

    test "a refused recurring move reverts and explains why", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Weekly Standup",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(
        lv.pid,
        {:event_move_result, {:error, original_event: event, reason: :recurring_event}}
      )

      html = render(lv)
      assert html =~ "Recurring events cannot be moved to another calendar yet."
      refute html =~ "Could not move the event"
    end

    test "success path keeps the grid rendering without errors", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Moved Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(
        lv.pid,
        {:event_move_result, {:ok, uid: event.uid, integration_id: integration.id}}
      )

      render(lv)
      html = render(lv)
      refute html =~ "Could not move the event"
      assert html =~ "Event moved to the new calendar."
      assert html =~ "Moved Event"
    end
  end

  describe "async event delete result" do
    test "success path refreshes the grid and confirms", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(
        lv.pid,
        {:delete_event_result,
         {:ok, %{uid: "gone", integration_id: integration.id, linked_meeting: :none}}}
      )

      render(lv)
      assert render(lv) =~ "Event deleted."
    end

    test "a cancelled linked meeting is reported", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(
        lv.pid,
        {:delete_event_result,
         {:ok, %{uid: "gone", integration_id: integration.id, linked_meeting: :cancelled}}}
      )

      render(lv)
      assert render(lv) =~ "Event and linked meeting cancelled."
    end

    test "a linked meeting that could not be cancelled is reported", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(
        lv.pid,
        {:delete_event_result,
         {:ok, %{uid: "gone", integration_id: integration.id, linked_meeting: :cancel_failed}}}
      )

      render(lv)
      assert render(lv) =~ "Event deleted, but meeting cancellation failed."
    end

    test "error path flashes failure message", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      insert_event(integration, %{
        summary: "Stubborn Event",
        start_at: DateTime.new!(Date.utc_today(), ~T[13:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
        all_day: false
      })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:delete_event_result, {:error, %{reason: :api_error, retry: :not_queued}}})

      html = render(lv)
      assert html =~ "Failed to delete event"
      assert html =~ "Stubborn Event"
    end

    test "a delete queued for the next sync says so", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:delete_event_result, {:error, %{reason: :server_error, retry: :queued}}})

      assert render(lv) =~ "Delete failed - queued to retry on next sync"
    end
  end

  describe "async ad-hoc meeting result" do
    test "success path flashes confirmation", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:create_ad_hoc_meeting_result, {:ok, %{meeting_id: 1}}})

      html = render(lv)
      assert html =~ "Meeting created and invitation sent"
    end

    test "error path flashes the reason", %{conn: conn, user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:create_ad_hoc_meeting_result, {:error, "Calendar unavailable"}})

      html = render(lv)
      assert html =~ "Calendar unavailable"
    end
  end

  describe "integration lifecycle messages" do
    # Both messages exist to invalidate the cached integration status and
    # reassign it. The setup checklist above the grid is where that status
    # surfaces: its "done of total" badge counts "Connect a calendar" as done
    # exactly when the host has an active calendar integration.
    test "integration_added re-reads the status a stale cache would have hidden", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      assert ["0", total] = checklist_progress(lv)

      insert(:calendar_integration, user: user, is_active: true)
      send(lv.pid, {:integration_added, :calendar})

      assert ["1", ^total] = checklist_progress(lv)
    end

    test "integration_removed re-reads the status after the calendar is deleted", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      assert ["1", total] = checklist_progress(lv)

      Repo.delete!(integration)
      send(lv.pid, {:integration_removed, :calendar})

      assert ["0", ^total] = checklist_progress(lv)
    end

    defp checklist_progress(lv) do
      lv
      |> element("[data-testid='onboarding-checklist']")
      |> render()
      |> then(&Regex.run(~r{(\d+)/(\d+)}, &1, capture: :all_but_first))
    end
  end

  describe "async create failure" do
    test "a create queued for the next sync says so", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:create_event_result, {:error, %{reason: :server_error, retry: :queued}}})

      assert render(lv) =~ "Create failed - queued to retry on next sync"
    end

    test "a create that was not queued says it failed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:create_event_result, {:error, %{reason: :server_error, retry: :not_queued}}})

      html = render(lv)
      assert html =~ "Failed to create event"
      refute html =~ "queued to retry"
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
