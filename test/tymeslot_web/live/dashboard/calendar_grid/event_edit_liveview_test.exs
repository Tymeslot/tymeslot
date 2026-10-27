defmodule TymeslotWeb.Dashboard.CalendarGrid.EventEditLiveViewTest do
  @moduledoc """
  Editing an event from the calendar grid, end to end: the organiser's edit in
  the detail modal, the provider write it becomes, and what the grid shows
  once that write has answered.

  The provider write runs in a supervised Task and reaches the suite-wide
  `Tymeslot.CalendarMock`. Each expectation reports the Task's pid, so a test
  can wait for the Task to finish instead of sleeping.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.RepeatEditorHelpers
  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Google.EventMapper, as: GoogleEventMapper
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  @attendees [%{"email" => "guest@example.com", "name" => "Guest", "status" => "accepted"}]
  @rrule "FREQ=WEEKLY;BYDAY=MO"

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    integration = insert(:calendar_integration, user: user, is_active: true)
    {:ok, conn: conn, user: user, integration: integration}
  end

  describe "renaming an event" do
    test "keeps its attendees, reminders, repeat rule and colour on the calendar", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration)
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      payload = await_provider_update(lv)
      assert payload.summary == "Renamed"
      assert payload.attendees == @attendees
      assert [%{minutes_before: 15}] = payload.reminders
      assert payload.recurrence_rule == @rrule
      assert payload.colour == "tomato"
    end

    test "keeps the event's series link and etag in the cache", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration, %{recurring_event_id: "series-1"})
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Renamed"
      assert row.recurring_event_id == "series-1"
      assert row.etag == "\"etag-1\""
      assert row.attendees == @attendees
    end
  end

  describe "toggling an event to all-day" do
    test "sends date-only timing and keeps attendees and the repeat rule", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration)
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      payload = await_provider_update(lv)
      today = Clock.utc_today()
      assert payload.start_time == today
      assert payload.end_time == Date.add(today, 1)
      assert payload.attendees == @attendees
      assert payload.recurrence_rule == @rrule
    end

    test "keeps an evening event that ends at midnight on its one day", %{
      conn: conn,
      integration: integration
    } do
      today = Clock.utc_today()

      event =
        insert_timed_event(integration, %{
          start_at: DateTime.new!(today, ~T[22:00:00.000000], "Etc/UTC"),
          end_at: DateTime.new!(Date.add(today, 1), ~T[00:00:00.000000], "Etc/UTC"),
          recurrence_rule: nil,
          recurring_event_id: nil
        })

      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      payload = await_provider_update(lv)
      assert payload.start_time == today
      assert payload.end_time == Date.add(today, 1)
    end

    test "rewrites the series' UNTIL to the bare date an all-day DTSTART needs", %{
      conn: conn,
      integration: integration
    } do
      # Relative to today: a fixed date would end the series before the
      # event the test opens, once the suite runs past it.
      until = Clock.utc_today() |> Date.add(60) |> Calendar.strftime("%Y%m%d")

      event =
        insert_timed_event(integration, %{
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;UNTIL=#{until}T235959Z"
        })

      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      payload = await_provider_update(lv)
      assert payload.recurrence_rule == "FREQ=WEEKLY;BYDAY=MO;UNTIL=#{until}"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.recurrence_rule == "FREQ=WEEKLY;BYDAY=MO;UNTIL=#{until}"
    end
  end

  describe "an event in a zone the time-zone database does not know" do
    # Outlook-made calendar files often name their zone "Customized Time
    # Zone"; the grid reads such an event in the organiser's zone.
    test "a series toggles to all-day on the day it shows on", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration, %{timezone: "Customized Time Zone"})

      expect_provider_update(:ok)

      lv = open_event(conn, event)
      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      payload = await_provider_update(lv)
      assert payload.start_time == Clock.utc_today()
    end

    test "opens the repeat editor for its series", %{conn: conn, integration: integration} do
      event = insert_timed_event(integration, %{timezone: "Customized Time Zone"})

      lv = open_event(conn, event)

      # A weekly pattern repeats on its start's weekday: today's, and one more.
      today = Date.day_of_week(DateTime.to_date(event.start_at)) - 1
      days = Enum.sort([today, rem(today + 2, 7)])

      html =
        lv
        |> element("#calendar-grid")
        |> render_repeat_save(%{
          "freq" => "weekly",
          "interval" => "1",
          "by_day" => Enum.map(days, &Enum.at(~w(mo tu we th fr sa su), &1)),
          "end_type" => "never"
        })

      assert html =~
               "Repeats weekly on #{Enum.map_join(days, ", ", &Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), &1))}"
    end
  end

  describe "toggling to all-day an event kept in another zone than the viewer's" do
    setup %{user: user} do
      user.id
      |> Profiles.get_profile()
      |> Changeset.change(timezone: "America/New_York")
      |> Repo.update!()

      %{today: Clock.utc_now() |> DateTime.shift_zone!("America/New_York") |> DateTime.to_date()}
    end

    # 22:00 in New York is already tomorrow in Berlin, the event's own zone.
    test "a one-off lands on the day the viewer sees it on", %{
      conn: conn,
      integration: integration,
      today: today
    } do
      start_at = new_york(today, ~T[22:00:00])

      event =
        insert_timed_event(integration, %{
          start_at: start_at,
          end_at: DateTime.add(start_at, 30, :minute),
          timezone: "Europe/Berlin",
          recurrence_rule: nil,
          recurring_event_id: nil
        })

      expect_provider_update(:ok)

      lv = open_event(conn, event)
      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      payload = await_provider_update(lv)
      assert payload.start_time == today
    end

    # A series belongs to the calendar it repeats on: 00:30 in Berlin is
    # still the evening before in New York, and the series keeps Berlin's day.
    test "a series keeps the day of the calendar it repeats on", %{
      conn: conn,
      integration: integration,
      today: today
    } do
      start_at = new_york(today, ~T[19:30:00])
      berlin_day = start_at |> DateTime.shift_zone!("Europe/Berlin") |> DateTime.to_date()
      assert Date.diff(berlin_day, today) == 1

      event =
        insert_timed_event(integration, %{
          start_at: start_at,
          end_at: DateTime.add(start_at, 30, :minute),
          timezone: "Europe/Berlin"
        })

      expect_provider_update(:ok)

      lv = open_event(conn, event)
      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      payload = await_provider_update(lv)
      assert payload.start_time == berlin_day
    end
  end

  describe "adding an attendee to an all-day event" do
    test "sends the event's dates rather than empty times", %{
      conn: conn,
      integration: integration
    } do
      today = Clock.utc_today()

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Company Offsite",
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: today,
          end_date: Date.add(today, 1),
          attendees: []
        )

      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='allday-event-#{event.id}-']") |> render_click()

      lv
      |> element("form[phx-submit=add_event_attendee]")
      |> render_submit(%{"email" => "colleague@example.com"})

      payload = await_provider_update(lv)
      assert payload.start_time == today
      assert payload.end_time == Date.add(today, 1)
      assert [%{email: "colleague@example.com"}] = payload.attendees
    end
  end

  describe "adding an attendee to an event others have already answered" do
    setup %{integration: integration} do
      # The shape the sync stores and the JSONB column hands back.
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "google",
          summary: "Sprint review",
          start_at: DateTime.new!(Clock.utc_today(), ~T[14:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Clock.utc_today(), ~T[15:00:00], "Etc/UTC"),
          all_day: false,
          attendees: [
            %{
              "email" => "ada@example.com",
              "display_name" => "Ada Lovelace",
              "response_status" => "accepted",
              "optional" => false
            }
          ]
        )

      %{event: event}
    end

    test "Google keeps the existing reply and gets none for the new invitee", %{
      conn: conn,
      event: event
    } do
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("form[phx-submit=add_event_attendee]")
      |> render_submit(%{"email" => "grace@example.com"})

      payload = await_provider_update(lv)

      # `events.update` is a full replace: the cached reply has to travel, and
      # the new invitee has to go without one so that Google applies its own
      # default rather than a reply nobody gave.
      assert [ada, grace] = GoogleEventMapper.format_event_data(payload)["attendees"]
      assert ada["responseStatus"] == "accepted"
      assert grace["email"] == "grace@example.com"
      refute Map.has_key?(grace, "responseStatus")
    end

    test "the cache stores the new invitee in the canonical shape, with no reply", %{
      conn: conn,
      integration: integration,
      event: event
    } do
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("form[phx-submit=add_event_attendee]")
      |> render_submit(%{"email" => "grace@example.com"})

      await_provider_update(lv)

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)

      assert [%{"response_status" => "accepted"}, grace] = row.attendees

      assert grace == %{
               "email" => "grace@example.com",
               "display_name" => nil,
               "response_status" => nil,
               "optional" => false
             }
    end
  end

  describe "an edit the calendar could not accept" do
    test "a write queued for retry keeps the edit and says it will sync", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      event =
        insert_timed_event(integration, %{
          provider: "caldav",
          recurrence_rule: nil,
          recurring_event_id: nil
        })

      expect_provider_update({:error, :server_error})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)
      html = render(lv)

      assert html =~ "will sync"
      refute html =~ "changes reverted"
      assert html =~ "Renamed"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "locally_modified"
      assert row.summary == "Renamed"
    end

    test "a write that cannot be retried is reverted and never queued", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      event =
        insert_timed_event(integration, %{
          provider: "caldav",
          recurrence_rule: nil,
          recurring_event_id: nil
        })

      expect_provider_update({:error, :unauthorized})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)
      html = render(lv)

      assert html =~ "Failed to update event - changes reverted"
      refute html =~ "Renamed"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "synced"
    end

    test "a repeat rule Outlook refuses is reverted and says the pattern cannot be saved there",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration, user: user, is_active: true, provider: "outlook")

      event =
        insert_timed_event(integration, %{
          provider: "outlook",
          recurrence_rule: "FREQ=MONTHLY;BYDAY=2TU,-1FR"
        })

      expect_provider_update({:error, :rule_not_supported_by_outlook})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)
      html = render(lv)

      assert html =~ "This repeat pattern can&#39;t be saved to Outlook."
      refute html =~ "changes reverted"
      refute html =~ "Renamed"
    end

    test "a write that crashes is reverted instead of left on screen", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration)
      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context ->
        send(test_pid, {:provider_update, self(), nil})
        raise "provider exploded"
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)
      html = render(lv)

      assert html =~ "Failed to update event - changes reverted"
      refute html =~ "Renamed"
    end
  end

  # A series master's own row, which a write sends with its rule.
  defp insert_timed_event(integration, attrs \\ %{}) do
    today = Clock.utc_today()

    defaults = %{
      calendar_integration: integration,
      summary: "Weekly sync",
      start_at: DateTime.new!(today, ~T[10:00:00.000000], "Etc/UTC"),
      end_at: DateTime.new!(today, ~T[11:00:00.000000], "Etc/UTC"),
      all_day: false,
      attendees: @attendees,
      reminders: [%{"method" => "popup", "minutes_before" => 15}],
      recurrence_rule: @rrule,
      colour: "tomato",
      etag: "\"etag-1\"",
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp open_event(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("[id^='event-#{event.id}-']") |> render_click()
    lv
  end

  defp new_york(date, time),
    do: date |> DateTime.new!(time, "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

  defp expect_provider_update(result) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, self(), payload})
      result
    end)
  end

  # Waits for the Task that made the provider write to exit, then renders
  # twice: once for the LiveView to handle the Task's result message, once
  # for the grid component to apply what that handler sent it.
  defp await_provider_update(lv) do
    assert_receive {:provider_update, task_pid, payload}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end
end
