defmodule Tymeslot.CalendarGrid.EventEditGoogleWriteTest do
  @moduledoc """
  What a grid edit of a synced Google event actually puts on the wire.

  `EventEditTest` stops at the `:calendar_module` seam and pins the payload;
  this module points that seam back at the runtime module so the edit travels
  the whole way down (grid domain, provider adapter, Google API client) and
  the JSON body Google receives can be read.

  `events.update` is a `PUT`, so the attendee array in the body becomes the
  attendee array on the event. An attendee sent without a `responseStatus`
  therefore comes back as `needsAction`, and because the write suppresses
  Google's own notifications nobody is told their reply was discarded. That
  loss is invisible from either end: the payload is complete, the write
  succeeds and the organiser's rename lands.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous do
        Application.put_env(:tymeslot, key, previous)
      else
        Application.delete_env(:tymeslot, key)
      end
    end)
  end

  setup do
    # Both seams the test env stubs out are pointed back at the runtime
    # modules, so only the HTTP client is left mocked and the body Google
    # would receive is the thing under test.
    swap_env(:calendar_module, Operations)
    swap_env(:google_calendar_api_module, CalendarAPI)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        oauth_scope: "https://www.googleapis.com/auth/calendar"
      )

    # The event as the sync stored it: two invitations already answered, in the
    # shape the JSONB column hands back.
    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "sprintreview",
        provider: "google",
        provider_calendar_id: "primary",
        provider_event_id: "sprintreview",
        summary: "Sprint review",
        start_at: ~U[2026-09-10 09:00:00.000000Z],
        end_at: ~U[2026-09-10 10:00:00.000000Z],
        all_day: false,
        attendees: [
          %{
            "email" => "ada@example.com",
            "display_name" => "Ada Lovelace",
            "response_status" => "accepted",
            "optional" => false
          },
          %{
            "email" => "grace@example.com",
            "display_name" => "Grace Hopper",
            "response_status" => "declined",
            "optional" => true
          }
        ],
        sync_state: "synced"
      )

    %{user: user, event: event}
  end

  describe "renaming a synced Google event from the grid" do
    test "sends every attendee back with the reply they already gave", %{
      user: user,
      event: event
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        send(test_pid, {:put, url, body})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "sprintreview"})}}
      end)

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert updated.summary == "Renamed"

      assert_received {:put, url, body}
      assert url =~ "/calendars/primary/events/"
      # Tymeslot sends its own attendee notifications, so Google's are
      # suppressed: nothing would tell an attendee their reply had been reset.
      assert url =~ "sendUpdates=none"

      sent = Jason.decode!(body)
      assert sent["summary"] == "Renamed"

      assert [ada, grace] = sent["attendees"]

      assert ada == %{
               "email" => "ada@example.com",
               "displayName" => "Ada Lovelace",
               "responseStatus" => "accepted"
             }

      assert grace == %{
               "email" => "grace@example.com",
               "displayName" => "Grace Hopper",
               "responseStatus" => "declined",
               "optional" => true
             }
    end

    test "sends no reply for an attendee the edit just added", %{user: user, event: event} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :put, _url, body, _headers, _opts ->
        send(test_pid, {:put, body})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "sprintreview"})}}
      end)

      # The shape the grid builds for a newly typed address: no cached row, so
      # nothing to inherit from the attendee that preceded it.
      new_attendees =
        event.attendees ++
          [%{"email" => "alan@example.com", "name" => nil, "status" => "needs_action"}]

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{attendees: new_attendees})

      assert_received {:put, body}
      sent = Jason.decode!(body)

      assert [ada, _grace, alan] = sent["attendees"]
      assert ada["responseStatus"] == "accepted"
      assert alan["email"] == "alan@example.com"
      refute Map.has_key?(alan, "responseStatus")
    end
  end
end
