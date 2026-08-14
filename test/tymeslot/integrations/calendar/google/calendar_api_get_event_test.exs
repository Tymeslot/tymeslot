defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPIGetEventTest do
  @moduledoc """
  The single-event GET, and the id-mapping trap it deliberately avoids.

  Every other event-scoped call in `CalendarAPI` takes a Tymeslot UID and passes
  it through `EventMapper.uuid_to_google_event_id/1`, which re-hashes anything
  that is not base32hex. `get_event/3` does not, because the ids it is given —
  `recurringEventId` values off the cache — are *already* Google event ids and
  routinely contain characters outside that alphabet. Mapping one would produce
  a valid-looking 32-character digest addressing an event that does not exist,
  and the symptom would be a 404 for an event plainly visible in the calendar.

  Its own file rather than a describe block in `calendar_api_test.exs`: that
  module is already at Credo's 650-line ceiling, and the reason these tests
  exist is specific enough to be worth finding by filename.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

    %{integration: integration}
  end

  describe "get_event/3" do
    test "GETs the event and returns the raw provider body", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, headers, _opts ->
        assert url ==
                 "https://www.googleapis.com/calendar/v3/calendars/primary/events/master_abc123"

        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer valid_token"
               end)

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "master_abc123",
               "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=TU"]
             })
         }}
      end)

      assert {:ok, %{"recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=TU"]}} =
               CalendarAPI.get_event(integration, "primary", "master_abc123")
    end

    # The trap this file exists for. `6f8g2h_20260707T090000Z` is the shape
    # Google gives an expanded instance's `recurringEventId`; the underscore
    # puts it outside base32hex, so `uuid_to_google_event_id/1` would hash the
    # whole string and address something else entirely.
    test "sends the provider id verbatim rather than re-mapping it", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.ends_with?(url, "/events/6f8g2h_20260707T090000Z")

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "6f8g2h"})}}
      end)

      assert {:ok, _event} =
               CalendarAPI.get_event(integration, "primary", "6f8g2h_20260707T090000Z")
    end

    # A master deleted between the sync and the mirror is an ordinary outcome,
    # not an exception: the caller turns it into a skip and lets the reconcile
    # sweep retry.
    test "a missing event surfaces as :not_found rather than raising", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :not_found, "Event not found"} =
               CalendarAPI.get_event(integration, "primary", "gone-master")
    end

    test "the calendar id travels into the path, so a secondary calendar is reachable", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "/calendars/team@group.calendar.google.com/events/")

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "master_abc123"})}}
      end)

      assert {:ok, _event} =
               CalendarAPI.get_event(
                 integration,
                 "team@group.calendar.google.com",
                 "master_abc123"
               )
    end
  end
end
