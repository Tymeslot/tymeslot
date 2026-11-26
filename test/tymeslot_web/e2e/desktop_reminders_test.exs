defmodule TymeslotWeb.E2E.DesktopRemindersTest do
  @moduledoc """
  Desktop notifications on the calendar, in a real browser: the display
  options' switch asks the browser for permission inside the click and is
  saved on only once the browser allows it; a refusal leaves it off and
  says why; a preference saved on before the browser was asked offers
  "Allow notifications", which asks; and with permission granted a reminder
  fires for a meeting about to start, with its title and when it starts,
  and not for one hours away.

  Only a browser runs the `DesktopReminderPermission` and `DesktopReminders`
  hooks. `window.Notification` is replaced with a recorder before the
  calendar mounts: the page is loaded on another dashboard screen, the stub
  installed, and the calendar reached by live navigation, so the hooks mount
  in the same page with the stub in place. The reminder hook checks its
  feed when it mounts, looking back 90 seconds, so a reminder whose time has
  just come fires at once and no clock needs driving.
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :calendar

  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks

  # Records what the hooks do with the Notification API: each notification
  # constructed, and each permission request with the answer it gets.
  @stub """
  const [permission, answer] = arguments;
  window.__notifications = [];
  window.__permissionRequests = 0;
  class RecordingNotification {
    constructor(title, options = {}) {
      window.__notifications.push({ title, body: options.body, tag: options.tag });
    }
  }
  RecordingNotification.permission = permission;
  RecordingNotification.requestPermission = () => {
    window.__permissionRequests += 1;
    RecordingNotification.permission = answer;
    return Promise.resolve(answer);
  };
  window.Notification = RecordingNotification;
  """

  setup do
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()
    :ok
  end

  # An organiser in UTC with a 24-hour clock and one Google calendar.
  defp organiser(session, preferences) do
    {session, user} =
      log_in_via_browser(session, %{dashboard_tour_seen_at: DateTime.utc_now(:second)})

    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_timezone(profile, "Etc/UTC")

    {:ok, _prefs} =
      CalendarPreferencesQueries.upsert(user.id, Map.merge(%{time_format: "24h"}, preferences))

    integration =
      insert(:calendar_integration,
        user: user,
        name: "Work account",
        provider: "google",
        is_active: true,
        calendar_list: [%{"id" => "work", "name" => "Work", "selected" => true}]
      )

    {session, user, integration}
  end

  defp reminded(integration, title, %DateTime{} = start_at, minutes_before) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: "work",
      summary: title,
      location: "Room 4",
      start_at: start_at,
      end_at: DateTime.add(start_at, 30, :minute),
      all_day: false,
      sync_state: "synced",
      reminders: [%{"method" => "popup", "minutes_before" => minutes_before}]
    )
  end

  # Loads another dashboard screen, puts the recorder in place of the
  # browser's Notification (reporting `permission`, answering a request with
  # `answer`), then navigates to the calendar without reloading the page.
  defp open_calendar(session, permission, answer) do
    session
    |> resize_window(1280, 800)
    |> visit("/dashboard/overview")
    |> wait_for_live()
    |> execute_script(@stub, [permission, answer])
    |> execute_script("window.liveSocket.js().navigate('/dashboard/calendar')")
    |> assert_has(css("#calendar-canvas[aria-busy='false']"))
    |> assert_has(css("#calendar-reminder-feed", visible: false))
  end

  defp open_display_options(session) do
    session
    |> click(css("#calendar-display-toggle"))
    |> assert_has(css("#calendar-desktop-reminders"))
  end

  defp permission_requests(session),
    do: evaluate_script(session, "return window.__permissionRequests;")

  defp notifications(session), do: evaluate_script(session, "return window.__notifications;")

  defp saved_enabled(user),
    do: CalendarPreferencesQueries.get_or_create(user.id).desktop_reminders_enabled

  feature "the switch asks the browser, and saves notifications on once it allows them", %{
    session: session
  } do
    {session, user, _integration} = organiser(session, %{})

    session =
      session
      |> open_calendar("default", "granted")
      |> assert_has(css("#calendar-reminder-feed[data-enabled='false']", visible: false))
      |> open_display_options()
      |> assert_has(css("#calendar-desktop-reminders[aria-checked='false']"))

    assert permission_requests(session) == 0

    session
    |> click(css("#calendar-desktop-reminders"))
    |> assert_has(css("#calendar-desktop-reminders[aria-checked='true']"))
    |> assert_has(css("#calendar-reminder-feed[data-enabled='true']", visible: false))
    |> assert_has(css("#calendar-desktop-permission-note", count: 0))

    assert permission_requests(session) == 1
    eventually(fn -> assert saved_enabled(user) == true end, timeout: 5_000)
  end

  feature "a browser that refuses leaves notifications off and says why", %{session: session} do
    {session, user, _integration} = organiser(session, %{})

    session =
      session
      |> open_calendar("default", "denied")
      |> open_display_options()
      |> assert_has(css("#calendar-desktop-permission-note", count: 0))
      |> click(css("#calendar-desktop-reminders"))
      |> assert_has(
        css("#calendar-desktop-permission-note", text: "Blocked in your browser settings")
      )
      |> assert_has(css("#calendar-desktop-reminders[aria-checked='false']"))
      |> assert_has(css("#calendar-reminder-feed[data-enabled='false']", visible: false))

    assert permission_requests(session) == 1
    assert saved_enabled(user) == false
  end

  feature "notifications saved on before the browser was asked offer Allow notifications", %{
    session: session
  } do
    {session, _user, _integration} = organiser(session, %{desktop_reminders_enabled: true})

    session =
      session
      |> open_calendar("default", "granted")
      |> open_display_options()
      |> assert_has(css("#calendar-desktop-reminders[aria-checked='true']"))
      |> assert_has(
        css("#calendar-desktop-permission-note",
          text: "your browser has not allowed them yet"
        )
      )
      |> click(css("#calendar-desktop-permission-note-grant", text: "Allow notifications"))
      |> assert_has(css("#calendar-desktop-permission-note", count: 0))
      |> assert_has(css("#calendar-desktop-reminders[aria-checked='true']"))

    assert permission_requests(session) == 1
  end

  feature "with permission granted, a reminder fires for a meeting about to start", %{
    session: session
  } do
    {session, _user, integration} = organiser(session, %{desktop_reminders_enabled: true})

    # Its ten-minute reminder came due five seconds ago: the hook's first
    # check looks back 90 seconds (`INITIAL_LOOKBACK_MS`), so the calendar
    # has most of that to mount in.
    soon = DateTime.add(DateTime.utc_now(:second), 595, :second)
    row = reminded(integration, "Design review", soon, 10)
    # Its reminder is hours off.
    reminded(integration, "Board meeting", DateTime.add(soon, 3, :hour), 10)

    day = if DateTime.to_date(soon) == Date.utc_today(), do: "Today", else: "Tomorrow"
    expected_body = "#{day} at #{Calendar.strftime(soon, "%H:%M")} · Room 4"

    session = open_calendar(session, "granted", "granted")

    eventually(fn -> assert notifications(session) != [] end, timeout: 5_000)

    assert notifications(session) == [
             %{
               "title" => "Reminder: Design review",
               "body" => expected_body,
               "tag" => "#{row.id}|#{DateTime.to_unix(soon)}|10"
             }
           ]

    assert permission_requests(session) == 0
  end
end
