defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPIErrorTaxonomyTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.RetryHelpers

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

    # A server failure and a throttle are both transient, but neither is a
    # network failure: a caller waits out a rate limit for as long as Google
    # asks, and retries a server failure on its own backoff.
    for status <- [500, 502, 503] do
      test "#{status} from the Google API surfaces as a transient :server_error", %{
        integration: integration
      } do
        expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: unquote(status), body: "<html>busy</html>"}}
        end)

        assert {:error, :server_error, message} = CalendarAPI.list_calendars(integration)
        assert message == "HTTP #{unquote(status)}"
        assert ErrorAnalysis.classify_error(:server_error) == :transient
      end
    end

    test "429 from the Google API surfaces as :rate_limited with its Retry-After", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, headers: %{"retry-after" => ["30"]}, body: ""}}
      end)

      assert {:error, :rate_limited, message} = CalendarAPI.list_calendars(integration)
      assert RetryHelpers.parse_retry_after_from_message(message) == 30
      assert ErrorAnalysis.classify_error({:error, :rate_limited, message}) == :transient
    end

    test "429 without a Retry-After surfaces as :rate_limited", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: ""}}
      end)

      assert {:error, :rate_limited, "Too many requests"} =
               CalendarAPI.list_calendars(integration)
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
