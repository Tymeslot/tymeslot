defmodule TymeslotWeb.Dashboard.CalendarGrid.EventsAttendeesTest do
  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.EmailWorker

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  # Edits write to the provider from a background Task; answering it keeps a
  # crashed write from reverting the grid underneath the assertions.
  setup do
    Mox.stub(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)
    :ok
  end

  describe "event creation form" do
    setup %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

    test "shows create form on show_create_form hook event", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

      # Route the hook event to the component via the CalendarCreate hook element
      html =
        lv
        |> element("#calendar-create-zone")
        |> render_hook("show_create_form", %{
          "date" => today_iso,
          "start-hour" => "10",
          "start-minute" => "0",
          "end-hour" => "11",
          "end-minute" => "0"
        })

      assert html =~ "New Event"
    end

    test "closes create form on close_create_form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

      lv
      |> element("#calendar-create-zone")
      |> render_hook("show_create_form", %{
        "date" => today_iso,
        "start-hour" => "10",
        "start-minute" => "0",
        "end-hour" => "11",
        "end-minute" => "0"
      })

      html = lv |> element("#create-event-modal button", "Cancel") |> render_click()
      refute html =~ "New Event"
    end

    test "shows separate start and end date fields", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("#calendar-create-zone")
        |> render_hook("show_create_form", %{
          "date" => today_iso,
          "start-hour" => "10",
          "start-minute" => "0",
          "end-hour" => "11",
          "end-minute" => "0"
        })

      assert html =~ ~s(id="create-event-start-date")
      assert html =~ ~s(id="create-event-end-date")
    end

    test "defaults end-date to start date when not provided", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("#calendar-create-zone")
        |> render_hook("show_create_form", %{
          "date" => today_iso,
          "start-hour" => "14",
          "start-minute" => "0",
          "end-hour" => "15",
          "end-minute" => "0"
        })

      # Both date fields should show today's date
      assert html =~ ~s(name="start-date" value="#{today_iso}")
      assert html =~ ~s(name="end-date" value="#{today_iso}")
    end

    test "accepts separate end-date from cross-day drag", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)
      today_iso = Date.to_iso8601(today)
      tomorrow_iso = Date.to_iso8601(tomorrow)

      html =
        lv
        |> element("#calendar-create-zone")
        |> render_hook("show_create_form", %{
          "date" => today_iso,
          "end-date" => tomorrow_iso,
          "start-hour" => "14",
          "start-minute" => "0",
          "end-hour" => "10",
          "end-minute" => "0"
        })

      assert html =~ ~s(name="start-date" value="#{today_iso}")
      assert html =~ ~s(name="end-date" value="#{tomorrow_iso}")
    end

    test "updates start-date and end-date independently via form change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)
      today_iso = Date.to_iso8601(today)
      tomorrow_iso = Date.to_iso8601(tomorrow)

      lv
      |> element("#calendar-create-zone")
      |> render_hook("show_create_form", %{
        "date" => today_iso,
        "start-hour" => "10",
        "start-minute" => "0",
        "end-hour" => "11",
        "end-minute" => "0"
      })

      # Change only the end-date
      html =
        lv
        |> element("#create-event-modal form[phx-change=update_create_time]")
        |> render_change(%{
          "start-date" => today_iso,
          "end-date" => tomorrow_iso,
          "start-time" => "10:00",
          "end-time" => "11:00"
        })

      assert html =~ ~s(name="start-date" value="#{today_iso}")
      assert html =~ ~s(name="end-date" value="#{tomorrow_iso}")
    end
  end

  describe "attendee management" do
    test "adding an attendee persists immediately and clears input", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: []
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # Open event detail modal
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      # Submit attendee form
      html =
        lv
        |> element("form[phx-submit=add_event_attendee]")
        |> render_submit(%{"email" => "colleague@example.com"})

      assert html =~ "colleague@example.com"
      assert html =~ ~s(id="edit-attendee-email")
    end

    test "shows a synced attendee by the name their calendar gave them", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [
            %{
              "email" => "ada@example.com",
              "display_name" => "Ada Lovelace",
              "response_status" => "accepted",
              "optional" => false
            }
          ]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert lv
             |> element("#event-detail-modal span", "Ada Lovelace")
             |> has_element?()
    end

    test "adding a duplicate attendee is a no-op", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [%{"email" => "existing@example.com"}]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("form[phx-submit=add_event_attendee]")
        |> render_submit(%{"email" => "existing@example.com"})

      # Should still have only one attendee entry (not duplicated)
      assert html =~ "existing@example.com"

      # Count remove buttons — each attendee gets exactly one
      remove_count = html |> String.split("request_remove_attendee") |> length() |> Kernel.-(1)
      assert remove_count == 1, "Expected 1 attendee, but found #{remove_count} remove buttons"
    end

    test "adding an invalid email is a no-op", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: []
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("form[phx-submit=add_event_attendee]")
        |> render_submit(%{"email" => "not-an-email"})

      refute html =~ "not-an-email"
    end
  end

  describe "pending attendee validation" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Validation Test Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [
            %{"email" => "existing@example.com", "name" => "Existing", "status" => "accepted"}
          ]
        })

      {:ok, integration: integration, event: event}
    end

    test "rejects invalid email format", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "not-an-email"})

      refute html =~ "not-an-email"
    end

    test "rejects duplicate of existing attendee", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      before = lv |> render() |> occurrences("existing@example.com")

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "existing@example.com"})

      # Listed once still, and not invited a second time.
      assert occurrences(html, "existing@example.com") == before
      refute render(lv) =~ "Attendee added and invited."
    end

    test "rejects an existing attendee typed in a different case", %{
      conn: conn,
      integration: integration
    } do
      # CalDAV and Outlook keep the case the address was stored with.
      event =
        insert_event(integration, %{
          summary: "Mixed Case Attendee Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[13:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [
            %{"email" => "Mixed.Case@Example.com", "name" => "Mixed", "status" => "accepted"}
          ]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html_before = lv |> element("[id^='event-#{event.id}-']") |> render_click()
      count_before = occurrences(html_before, "mixed.case@example.com")
      assert count_before >= 1

      html_after =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "mixed.case@example.com"})

      assert occurrences(html_after, "mixed.case@example.com") == count_before
    end

    test "rejects duplicate of newly-added attendee", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      # First add: attendee is added to selected_event.attendees and rendered
      html_after_first =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "unique-new@example.com"})

      first_count = length(String.split(html_after_first, "unique-new@example.com")) - 1
      assert first_count >= 1

      # Second add with the same email must be rejected — count must not grow
      html_after_second =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_event_attendee", %{"email" => "unique-new@example.com"})

      second_count = length(String.split(html_after_second, "unique-new@example.com")) - 1
      assert second_count == first_count
    end
  end

  describe "create form attendee management" do
    setup %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

    test "adds an attendee to the create form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("add_create_attendee", %{"email" => "invitee@example.com"})

      assert html =~ "invitee@example.com"
    end

    test "removes an attendee from the create form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("add_create_attendee", %{"email" => "tobe-removed@example.com"})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("remove_create_attendee", %{"email" => "tobe-removed@example.com"})

      refute html =~ "tobe-removed@example.com"
    end

    test "closing create form with pending attendees shows discard confirmation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("add_create_attendee", %{"email" => "invited@example.com"})

      html = lv |> element("#create-event-modal button", "Cancel") |> render_click()

      assert html =~ "Unsent invitations"
    end

    test "discarding clears the create form and pending attendees", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("add_create_attendee", %{"email" => "discard-me@example.com"})

      lv |> element("#create-event-modal button", "Cancel") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("discard_pending_attendees", %{})

      refute html =~ "discard-me@example.com"
      refute html =~ "New Event"
    end
  end

  describe "discard-attendees modal, clicked through" do
    setup %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

    defp open_discard_modal(lv) do
      open_create_form(lv)

      lv
      |> form("#create-add-attendee-form", %{"email" => "invited@example.com"})
      |> render_submit()

      lv |> element("#create-event-modal button", "Cancel") |> render_click()
      assert has_element?(lv, "#confirm-discard-attendees-modal")
    end

    test "Go back closes the prompt and keeps the form and its attendee", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_discard_modal(lv)

      lv |> element("#confirm-discard-attendees-modal button", "Go back") |> render_click()

      refute has_element?(lv, "#confirm-discard-attendees-modal")
      assert has_element?(lv, "#create-event-modal")
      assert render(lv) =~ "invited@example.com"
    end

    test "Discard closes the prompt and the form and drops the attendee", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_discard_modal(lv)

      lv |> element("#confirm-discard-attendees-modal button", "Discard") |> render_click()

      refute has_element?(lv, "#confirm-discard-attendees-modal")
      refute has_element?(lv, "#create-event-modal")
      refute render(lv) =~ "invited@example.com"
    end
  end

  describe "remove-attendee modal, clicked through" do
    setup %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Team Sync",
          start_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [%{"email" => "guest@example.com", "name" => "Guest"}]
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element(
        "button[phx-click='request_remove_attendee'][phx-value-email='guest@example.com']"
      )
      |> render_click()

      assert has_element?(lv, "#confirm-remove-attendee-modal")
      {:ok, lv: lv, event: event, integration: integration}
    end

    test "Cancel closes the prompt and keeps the attendee", %{
      lv: lv,
      event: event,
      integration: integration
    } do
      lv |> element("#confirm-remove-attendee-modal button", "Cancel") |> render_click()

      refute has_element?(lv, "#confirm-remove-attendee-modal")

      assert has_element?(
               lv,
               "button[phx-click='request_remove_attendee'][phx-value-email='guest@example.com']"
             )

      refute render(lv) =~ "Attendee removed and notified."
      refute_enqueued(worker: EmailWorker)

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert [%{"email" => "guest@example.com"}] = row.attendees
    end

    test "Remove closes the prompt, drops the attendee and notifies them", %{lv: lv} do
      lv |> element("#confirm-remove-attendee-modal button", "Remove") |> render_click()

      refute has_element?(lv, "#confirm-remove-attendee-modal")

      refute has_element?(
               lv,
               "button[phx-click='request_remove_attendee'][phx-value-email='guest@example.com']"
             )

      assert render(lv) =~ "Attendee removed and notified."

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "guest@example.com"}
      )
    end
  end

  defp open_create_form(lv) do
    today_iso = Date.to_iso8601(Date.utc_today())

    lv
    |> element("#calendar-create-zone")
    |> render_hook("show_create_form", %{
      "date" => today_iso,
      "start-hour" => "10",
      "start-minute" => "0",
      "end-hour" => "11",
      "end-minute" => "0"
    })
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end

  defp occurrences(html, email) do
    length(String.split(String.downcase(html), email)) - 1
  end
end
