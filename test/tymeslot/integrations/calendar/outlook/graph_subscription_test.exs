defmodule Tymeslot.Integrations.Calendar.Outlook.GraphSubscriptionTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
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
        assert String.contains?(url, "/me/events/delta")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [event],
               "@odata.deltaLink" =>
                 "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=seeded"
             })
         }}
      end)

      assert {:ok, updated} = GraphSubscription.bootstrap_sync(integration)
      assert updated.graph_delta_link =~ "deltatoken=seeded"

      cached = Repo.get_by(ProviderCalendarEventSchema, uid: "outlook-bootstrap-1@example.com")
      assert cached != nil
      assert cached.summary == "Quarterly review"

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert reloaded.graph_delta_link =~ "deltatoken=seeded"
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
  end
end
