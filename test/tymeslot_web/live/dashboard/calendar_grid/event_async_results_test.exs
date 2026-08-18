defmodule TymeslotWeb.Dashboard.CalendarGrid.EventAsyncResultsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
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
      assert html =~ "Failed to move event"
      assert html =~ "Move Me"
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
      refute html =~ "Failed to move event"
      assert html =~ "Moved Event"
    end
  end

  describe "async event delete result" do
    test "success path removes event from cache and grid", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Delete Me",
          start_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[12:00:00], "Etc/UTC"),
          all_day: false
        })

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Delete Me"

      send(
        lv.pid,
        {:delete_event_result, {:ok, %{uid: event.uid, integration_id: integration.id}}}
      )

      render(lv)
      html = render(lv)
      refute html =~ "Delete Me"

      assert {:error, :not_found} = CalendarGrid.get_cached_event(integration.id, event.uid)
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

      send(lv.pid, {:delete_event_result, {:error, :api_error}})

      html = render(lv)
      assert html =~ "Failed to delete event"
      assert html =~ "Stubborn Event"
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

  describe "async create failure with CalDAV offline queue" do
    test "tags cache row for retry and shows queued flash", %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      uid = "offline-create-#{System.unique_integer([:positive])}"

      send(
        lv.pid,
        {:create_event_result,
         {:error, :server_error,
          %{
            uid: uid,
            calendar_integration_id: integration.id,
            summary: "Offline Create",
            start_time: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
            end_time: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
            location: nil,
            description: nil,
            timezone: "Etc/UTC"
          }}}
      )

      html = render(lv)
      assert html =~ "queued to retry on next sync"

      assert {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      assert cached.sync_state == "locally_created"
      assert cached.summary == "Offline Create"
    end
  end

  describe "async delete failure with CalDAV offline queue" do
    test "tags cache row for retry and shows queued flash", %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      event =
        insert_event(integration, %{
          uid: "offline-delete-#{System.unique_integer([:positive])}",
          summary: "Offline Delete",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          provider: "caldav",
          provider_calendar_id: "/cal/"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # The delete error path passes the context directly (uid + calendar_integration_id)
      context = %{uid: event.uid, calendar_integration_id: integration.id}

      send(lv.pid, {:delete_event_result, {:error, :server_error, context}})

      html = render(lv)
      assert html =~ "queued to retry on next sync"

      assert {:ok, cached} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)

      assert cached.sync_state == "locally_deleted"
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
