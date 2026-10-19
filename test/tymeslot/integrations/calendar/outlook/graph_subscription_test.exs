defmodule Tymeslot.Integrations.Calendar.Outlook.GraphSubscriptionTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar, as: CalendarContext
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Outlook.GraphSubscription
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        access_token_encrypted: Encryption.encrypt("valid-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        graph_delta_link: nil
      )

    {:ok, integration: integration}
  end

  describe "bootstrap_sync/1" do
    test "calls calendarView/delta with rolling startDateTime/endDateTime params",
         %{integration: integration} do
      # Regression: an earlier version called /me/events/delta with no params,
      # which froze the date window into the returned $deltatoken — events
      # outside that ~30-day window never reached the cache.
      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "/me/calendarView/delta")
        refute String.contains?(url, "/me/events/delta")
        assert String.contains?(url, "startDateTime=")
        assert String.contains?(url, "endDateTime=")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.deltaLink" =>
                 "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=window"
             })
         }}
      end)

      assert {:ok, _updated} = GraphSubscription.bootstrap_sync(integration)
    end

    test "fetches initial delta, persists events to the cache, and stores the delta link",
         %{integration: integration} do
      event = %{
        "id" => "graph-event-1",
        "iCalUId" => "outlook-bootstrap-1@example.com",
        "subject" => "Quarterly review",
        "body" => %{"content" => "Agenda"},
        "location" => %{"displayName" => "Board room"},
        "showAs" => "busy",
        "sensitivity" => "normal",
        "isAllDay" => false,
        "isCancelled" => false,
        "responseStatus" => %{"response" => "accepted"},
        "start" => %{"dateTime" => "2030-06-01T10:00:00Z", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2030-06-01T11:00:00Z", "timeZone" => "UTC"},
        "organizer" => %{"emailAddress" => %{"address" => "luka@example.com"}},
        "attendees" => [],
        "reminderMinutesBeforeStart" => 15,
        "recurrence" => nil,
        "seriesMasterId" => nil
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "/me/calendarView/delta")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [event],
               "@odata.deltaLink" =>
                 "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=seeded"
             })
         }}
      end)

      assert {:ok, updated} = GraphSubscription.bootstrap_sync(integration)
      assert updated.graph_delta_link =~ "deltatoken=seeded"

      cached = Repo.get_by(ProviderCalendarEventSchema, uid: "outlook-bootstrap-1@example.com")
      assert %ProviderCalendarEventSchema{} = cached
      assert cached.summary == "Quarterly review"

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert reloaded.graph_delta_link =~ "deltatoken=seeded"

      # The link's window starts now; its age is measured from here.
      assert DateTime.diff(DateTime.utc_now(), reloaded.last_full_sync_at) < 60
    end

    test "does not send unsupported query parameters to /me/calendarView/delta",
         %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "/me/calendarView/delta")

        # Microsoft Graph rejects $orderby, $filter, $select, $expand, $search
        # on the calendarView/delta change-tracking resource with HTTP 400.
        refute String.contains?(String.downcase(url), "$select")
        refute String.contains?(String.downcase(url), "$expand")
        refute String.contains?(String.downcase(url), "$filter")
        refute String.contains?(String.downcase(url), "$orderby")
        refute String.contains?(String.downcase(url), "$search")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.deltaLink" =>
                 "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=first"
             })
         }}
      end)

      assert {:ok, _updated} = GraphSubscription.bootstrap_sync(integration)
    end

    test "strips unsupported params from @odata.nextLink before paginating",
         %{integration: integration} do
      # Graph sometimes echoes the requested $select/$expand back in nextLink.
      # The pagination follow-up must still be clean.
      next_link =
        "https://graph.microsoft.com/v1.0/me/calendarView/delta?" <>
          "$skiptoken=page2&$select=id,subject&$expand=extendedProperties"

      Tymeslot.HTTPClientMock
      |> expect(:request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.nextLink" => next_link
             })
         }}
      end)
      |> expect(:request, fn :get, url, _body, _headers, _opts ->
        # URI.encode_query percent-encodes the leading `$`, so the
        # skiptoken key is serialised as either `$skiptoken` or `%24skiptoken`.
        decoded = URI.decode(url)
        assert String.contains?(decoded, "$skiptoken=page2")
        refute String.contains?(String.downcase(decoded), "$select")
        refute String.contains?(String.downcase(decoded), "$expand")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.deltaLink" =>
                 "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=done"
             })
         }}
      end)

      assert {:ok, updated} = GraphSubscription.bootstrap_sync(integration)
      assert updated.graph_delta_link =~ "deltatoken=done"
    end

    test "returns an error tuple when the HTTP client raises", %{integration: integration} do
      # The circuit breaker rescues exceptions and hands back `{:error, exception}`.
      # Matching only `{:error, :circuit_open}` used to turn that into a
      # CaseClauseError, crashing the caller instead of failing the sync.
      on_exit(fn -> CalendarCircuitBreaker.reset(:outlook) end)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        raise "graph exploded"
      end)

      assert {:error, %RuntimeError{message: "graph exploded"}} =
               GraphSubscription.bootstrap_sync(integration)
    end

    test "returns the API error when Graph rejects the delta request",
         %{integration: integration} do
      # The breaker passes a `CalendarAPI` 3-tuple error through unwrapped;
      # matching only the wrapped form turned it into a CaseClauseError.
      on_exit(fn -> CalendarCircuitBreaker.reset(:outlook) end)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: Jason.encode!(%{"error" => %{}})}}
      end)

      assert {:error, _type, _message} = GraphSubscription.bootstrap_sync(integration)
    end

    test "returns an error tuple when Graph paginates past the page limit",
         %{integration: integration} do
      # Every page carries a nextLink and never a deltaLink, so the read runs
      # into `Outlook.Paging`'s page cap, the same answer every Graph read
      # gives past it.
      on_exit(fn -> CalendarCircuitBreaker.reset(:outlook) end)

      stub(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.nextLink" =>
                 "https://graph.microsoft.com/v1.0/me/calendarView/delta?$skiptoken=endless"
             })
         }}
      end)

      assert {:error, :too_many_pages, _message} = GraphSubscription.bootstrap_sync(integration)
    end

    test "does not require :webhook_base_url to be configured",
         %{integration: integration} do
      original = Application.get_env(:tymeslot, :webhook_base_url)
      Application.delete_env(:tymeslot, :webhook_base_url)
      on_exit(fn -> Application.put_env(:tymeslot, :webhook_base_url, original) end)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.deltaLink" =>
                 "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=empty"
             })
         }}
      end)

      assert {:ok, updated} = GraphSubscription.bootstrap_sync(integration)
      assert updated.graph_delta_link =~ "deltatoken=empty"
    end
  end

  describe "register/1" do
    test "returns :webhook_base_url_not_configured when URL is missing",
         %{integration: integration} do
      original = Application.get_env(:tymeslot, :webhook_base_url)
      Application.delete_env(:tymeslot, :webhook_base_url)
      on_exit(fn -> Application.put_env(:tymeslot, :webhook_base_url, original) end)

      # No HTTP expectation — we must not touch the Graph API when bailing out.
      assert {:error, :webhook_base_url_not_configured} = GraphSubscription.register(integration)
    end

    test "creates the subscription and persists subscription fields only (no delta link touch)",
         %{integration: integration} do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hook.example.com")

      on_exit(fn -> Application.delete_env(:tymeslot, :webhook_base_url) end)

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert String.contains?(url, "/subscriptions")
        decoded = Jason.decode!(body)

        assert decoded["notificationUrl"] ==
                 "https://hook.example.com/webhooks/outlook-calendar"

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "graph-sub-id-1",
               "expirationDateTime" => "2030-06-03T10:00:00Z"
             })
         }}
      end)

      assert {:ok, updated} = GraphSubscription.register(integration)
      assert updated.graph_subscription_id == "graph-sub-id-1"
      # Untouched by register/1 — bootstrap_sync/1 owns the delta link.
      assert is_nil(updated.graph_delta_link)
    end

    test "renews a stored subscription in place instead of creating another",
         %{integration: integration} do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hook.example.com")
      on_exit(fn -> Application.delete_env(:tymeslot, :webhook_base_url) end)

      integration = with_stored_subscription(integration, "graph-sub-live")

      expect(Tymeslot.HTTPClientMock, :request, fn :patch, url, body, _headers, _opts ->
        assert String.ends_with?(url, "/subscriptions/graph-sub-live")
        decoded = Jason.decode!(body)
        assert decoded["expirationDateTime"]
        assert decoded["notificationUrl"] == "https://hook.example.com/webhooks/outlook-calendar"

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "graph-sub-live",
               "expirationDateTime" => "2030-06-05T10:00:00Z"
             })
         }}
      end)

      assert {:ok, updated} = GraphSubscription.register(integration)
      assert updated.graph_subscription_id == "graph-sub-live"
      assert updated.graph_client_state == "stored-client-state"
      assert updated.graph_subscription_expires_at == ~U[2030-06-05 10:00:00Z]
    end

    test "creates a new subscription when Graph no longer has the stored one",
         %{integration: integration} do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hook.example.com")
      on_exit(fn -> Application.delete_env(:tymeslot, :webhook_base_url) end)

      integration = with_stored_subscription(integration, "graph-sub-removed")

      expect(Tymeslot.HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: Jason.encode!(%{"error" => %{}})}}
      end)

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, _body, _headers, _opts ->
        assert String.ends_with?(url, "/subscriptions")

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "graph-sub-new",
               "expirationDateTime" => "2030-06-05T10:00:00Z"
             })
         }}
      end)

      assert {:ok, updated} = GraphSubscription.register(integration)
      assert updated.graph_subscription_id == "graph-sub-new"
      refute updated.graph_client_state == "stored-client-state"
    end

    test "returns the API error when Graph rejects the new subscription",
         %{integration: integration} do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hook.example.com")
      on_exit(fn -> Application.delete_env(:tymeslot, :webhook_base_url) end)
      on_exit(fn -> CalendarCircuitBreaker.reset(:outlook) end)

      # The breaker passes a `CalendarAPI` 3-tuple error through unwrapped;
      # matching only the wrapped form turned it into a CaseClauseError.
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: Jason.encode!(%{"error" => %{}})}}
      end)

      assert {:error, _type, _message} = GraphSubscription.register(integration)
      assert is_nil(Repo.reload!(integration).graph_subscription_id)
    end

    test "does not create a subscription when renewing the stored one fails transiently",
         %{integration: integration} do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hook.example.com")
      on_exit(fn -> Application.delete_env(:tymeslot, :webhook_base_url) end)

      integration = with_stored_subscription(integration, "graph-sub-live")

      # verify_on_exit! fails the test on any POST to /subscriptions.
      expect(Tymeslot.HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 503, body: "unavailable"}}
      end)

      assert {:error, _type, _message} = GraphSubscription.register(integration)
    end
  end

  defp with_stored_subscription(integration, subscription_id) do
    {:ok, integration} =
      CalendarIntegrationWebhookQueries.update_graph_subscription(integration, %{
        graph_subscription_id: subscription_id,
        graph_client_state: "stored-client-state",
        graph_subscription_expires_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
      })

    integration
  end

  describe "unregister/1" do
    test "makes no request when no subscription is stored", %{integration: integration} do
      # Mox fails the test on any unexpected HTTP call.
      assert :ok = GraphSubscription.unregister(%{integration | graph_subscription_id: nil})
    end

    test "treats a subscription Graph no longer knows as gone", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      log =
        capture_log([level: :warning], fn ->
          assert :ok =
                   GraphSubscription.unregister(%{integration | graph_subscription_id: "sub-1"})
        end)

      refute log =~ "Failed to delete Graph subscription"
    end
  end

  # The disconnect journey through the calendar context, with only HTTP
  # stubbed: removing an Outlook integration must stop Graph pushing to the
  # webhook, and must never be blocked by Graph failing to answer.
  describe "disconnecting an Outlook integration" do
    @subscription_url "https://graph.microsoft.com/v1.0/subscriptions/sub-1"

    setup %{integration: integration} do
      CalendarCircuitBreaker.reset(:outlook)
      on_exit(fn -> CalendarCircuitBreaker.reset(:outlook) end)

      integration =
        integration
        |> Changeset.change(
          graph_subscription_id: "sub-1",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(:second), 1, :day)
        )
        |> Repo.update!()

      %{integration: integration}
    end

    defp disconnect(integration),
      do:
        CalendarContext.delete_with_primary_reassignment_and_invalidate(
          integration.user_id,
          integration.id
        )

    test "deletes its Graph subscription before the integration is removed", %{
      integration: integration
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, opts ->
        send(test_pid, {:deleted, url, Repo.get(CalendarIntegrationSchema, integration.id)})
        send(test_pid, {:delete_options, opts})
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert {:ok, _result} = disconnect(integration)

      assert_receive {:deleted, @subscription_url, %CalendarIntegrationSchema{}}

      # Bounded: the disconnect click waits on this request.
      assert_receive {:delete_options, opts}
      assert opts[:request_timeout] == 5_000
      refute Repo.get(CalendarIntegrationSchema, integration.id)
    end

    test "still disconnects when Graph answers 500", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :delete, @subscription_url, _b, _h, _o ->
        {:ok, %Req.Response{status: 500, body: ""}}
      end)

      log =
        capture_log([level: :warning], fn -> assert {:ok, _result} = disconnect(integration) end)

      assert log =~ "Failed to delete Graph subscription"
      refute Repo.get(CalendarIntegrationSchema, integration.id)
    end

    test "still disconnects when the request times out", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :delete, @subscription_url, _b, _h, _o ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      log =
        capture_log([level: :warning], fn -> assert {:ok, _result} = disconnect(integration) end)

      assert log =~ "Failed to delete Graph subscription"
      refute Repo.get(CalendarIntegrationSchema, integration.id)
    end
  end
end
