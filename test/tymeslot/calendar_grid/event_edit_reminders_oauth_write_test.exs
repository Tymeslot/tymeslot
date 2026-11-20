defmodule Tymeslot.CalendarGrid.EventEditRemindersOAuthWriteTest do
  @moduledoc """
  What a grid edit puts on the wire for a Google or Outlook event's
  reminders.

  The `:calendar_module` seam and the Google and Outlook API modules are
  pointed back at the runtime modules, so only the HTTP client is mocked and
  the body the provider receives is the thing under test. Both providers read
  their reminders back on sync and treat a missing key as a reset (Google's
  calendar defaults, Outlook's reminder switched off), so an edit that is not
  about reminders restates the cached list.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  defp oauth_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  setup do
    swap_env(:calendar_module, Operations)
    %{user: insert(:user)}
  end

  describe "editing a synced Google event with reminder overrides" do
    setup %{user: user} do
      swap_env(:google_calendar_api_module, GoogleAPI)

      integration =
        oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "boardmeeting",
          provider: "google",
          provider_calendar_id: "primary",
          provider_event_id: "boardmeeting",
          summary: "Board meeting",
          start_at: ~U[2026-09-10 09:00:00.000000Z],
          end_at: ~U[2026-09-10 10:00:00.000000Z],
          all_day: false,
          reminders: [%{"method" => "email", "minutes_before" => 1440}],
          sync_state: "synced"
        )

      %{event: event}
    end

    # `events.update` is a `PUT`: a body without `reminders` puts the event
    # back on the calendar's defaults, so the synced overrides must be sent.
    test "a rename restates the synced overrides", %{user: user, event: event} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :put, _url, body, _headers, _opts ->
        send(test_pid, {:google_put, body})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "boardmeeting"})}}
      end)

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{summary: "Renamed"})

      assert_received {:google_put, body}

      assert Jason.decode!(body)["reminders"] == %{
               "useDefault" => false,
               "overrides" => [%{"method" => "email", "minutes" => 1440}]
             }
    end

    # Left out, the key would put the event back on the calendar's defaults,
    # and the reminder just removed would come back with the next sync.
    test "removing every reminder sends none, not the calendar's defaults", %{
      user: user,
      event: event
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :put, _url, body, _headers, _opts ->
        send(test_pid, {:google_put, body})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "boardmeeting"})}}
      end)

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{reminders: []})

      assert_received {:google_put, body}
      assert Jason.decode!(body)["reminders"] == %{"useDefault" => false, "overrides" => []}
    end
  end

  describe "editing a synced Google event on the calendar's default reminders" do
    setup %{user: user} do
      swap_env(:google_calendar_api_module, GoogleAPI)

      integration =
        oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      # The sync caches an event on the calendar's defaults with no reminders
      # of its own.
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "standup",
          provider: "google",
          provider_calendar_id: "primary",
          provider_event_id: "standup",
          summary: "Stand-up",
          start_at: ~U[2026-09-10 09:00:00.000000Z],
          end_at: ~U[2026-09-10 09:15:00.000000Z],
          all_day: false,
          reminders: [],
          sync_state: "synced"
        )

      %{event: event}
    end

    test "a rename leaves it on the defaults", %{user: user, event: event} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :put, _url, body, _headers, _opts ->
        send(test_pid, {:google_put, body})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "standup"})}}
      end)

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{summary: "Renamed"})

      assert_received {:google_put, body}
      refute Map.has_key?(Jason.decode!(body), "reminders")
    end
  end

  describe "editing a synced Outlook event with a reminder" do
    setup %{user: user} do
      swap_env(:outlook_calendar_api_module, OutlookAPI)

      integration =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "040000008200E00074C5B7101A82E00B",
          provider: "outlook",
          provider_calendar_id: "primary",
          provider_event_id: "AAMkBoard",
          summary: "Board meeting",
          start_at: ~U[2026-11-10 09:00:00.000000Z],
          end_at: ~U[2026-11-10 10:00:00.000000Z],
          all_day: false,
          timezone: "Etc/UTC",
          reminders: [%{"method" => "popup", "minutes_before" => 30}],
          sync_state: "synced"
        )

      %{event: event}
    end

    # The Graph mapper reads a missing `:reminders` as "no reminder" and sends
    # `isReminderOn: false`, so the synced lead time must be sent.
    test "a rename keeps the reminder on with its lead time", %{user: user, event: event} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :patch, _url, body, _headers, _opts ->
        send(test_pid, {:graph_patch, body})

        answer = %{
          "id" => "AAMkBoard",
          "iCalUId" => "040000008200E00074C5B7101A82E00B",
          "type" => "singleInstance",
          "subject" => "Renamed",
          "start" => %{"dateTime" => "2026-11-10T09:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-11-10T10:00:00.0000000", "timeZone" => "UTC"}
        }

        {:ok, %Req.Response{status: 200, body: Jason.encode!(answer)}}
      end)

      assert {:ok, _updated} = EventEdit.update_event(user.id, event, %{summary: "Renamed"})

      assert_received {:graph_patch, body}
      sent = Jason.decode!(body)
      assert sent["isReminderOn"] == true
      assert sent["reminderMinutesBeforeStart"] == 30
    end
  end
end
