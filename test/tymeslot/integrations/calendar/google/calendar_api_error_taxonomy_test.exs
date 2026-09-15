defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPIErrorTaxonomyTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "error taxonomy" do
    # Callers downstream of CalendarAPI (CalendarEventWorker, CircuitBreaker,
    # retry policies) route on the second element of the error tuple. These
    # tests lock in the contract that each HTTP status maps to a
    # distinguishable atom so those call sites keep working.

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

    test "404 from the Google API surfaces as :not_found", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :not_found, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "404 on a calendar-scoped path names the calendar", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :not_found, "Calendar not found"} =
               CalendarAPI.list_events(
                 integration,
                 "primary",
                 DateTime.utc_now(),
                 DateTime.add(DateTime.utc_now(), 3600)
               )
    end

    # A 404 on /calendars/<id>/events/<event-id> almost always means the event
    # is gone, not the calendar — reporting "Calendar not found" there sent
    # self-hosters looking for a calendar problem that did not exist.
    test "404 on an event-scoped path names the event", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :not_found, "Event not found"} =
               CalendarAPI.delete_event(integration, "primary", "missing-event-id")
    end

    test "500 from the Google API surfaces as :network_error", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: ""}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "403 with rateLimitExceeded reason surfaces as :rate_limited", %{
      integration: integration
    } do
      body =
        Jason.encode!(%{
          "error" => %{
            "message" => "Rate Limit Exceeded",
            "errors" => [%{"reason" => "rateLimitExceeded"}]
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: body}}
      end)

      assert {:error, :rate_limited, _msg} =
               CalendarAPI.create_event(integration, "primary", %{
                 summary: "Team sync",
                 start_time: ~U[2026-05-01 10:00:00Z],
                 end_time: ~U[2026-05-01 11:00:00Z]
               })
    end

    test "403 with notACalendarUser reason surfaces as :not_a_calendar_user", %{
      integration: integration
    } do
      body =
        Jason.encode!(%{
          "error" => %{
            "message" => "The user must be signed up for Google Calendar.",
            "errors" => [%{"reason" => "notACalendarUser"}]
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: body}}
      end)

      assert {:error, :not_a_calendar_user, "The user must be signed up for Google Calendar."} =
               CalendarAPI.list_calendars(integration)
    end

    test "a transport timeout surfaces as :network_error", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end
  end
end
