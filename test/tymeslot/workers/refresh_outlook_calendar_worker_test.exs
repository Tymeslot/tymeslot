defmodule Tymeslot.Workers.RefreshOutlookCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker

  # set_mox_global so expectations are visible from the AccessToken / circuit
  # breaker process boundary that DeltaSync hops through.
  setup :set_mox_global
  setup :verify_on_exit!

  defp outlook_integration(attrs) do
    defaults = [
      provider: "outlook",
      is_active: true,
      access_token_encrypted: Encryption.encrypt("test-access-token"),
      refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, attrs))
  end

  defp subscribe_to_sync_topic(user_id) do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user_id}")
  end

  describe "perform/1 without a stored delta link" do
    test "bootstraps a delta baseline, registers a subscription and broadcasts completion" do
      integration = outlook_integration(graph_delta_link: nil)
      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        assert received.id == integration.id
        {:ok, %{integration | graph_delta_link: "fresh-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:ok, integration}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, user_id, integration_id}
      assert user_id == integration.user_id
      assert integration_id == integration.id
    end

    test "still completes successfully when webhook registration is not configured" do
      integration = outlook_integration(graph_delta_link: nil)
      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        {:ok, %{received | graph_delta_link: "fresh-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, _user_id, _integration_id}
    end

    test "returns an error and does NOT register a subscription when bootstrap fails" do
      integration = outlook_integration(graph_delta_link: nil)
      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :circuit_open}
      end)

      # Mox would raise if register_graph_subscription were called — the test
      # passes only if the worker does not invoke it after a bootstrap failure.

      assert {:error, :bootstrap_failed} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      refute_receive {:calendar_sync_complete, _user_id, _integration_id}
    end
  end

  describe "perform/1 with a stored delta link" do
    test "delegates to delta sync, persists the new link and broadcasts completion" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      # Empty delta response (no changed/removed events) plus a fresh deltaLink.
      delta_response_body =
        Jason.encode!(%{
          "value" => [],
          "@odata.deltaLink" =>
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: delta_response_body}}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, user_id, integration_id}
      assert user_id == integration.user_id
      assert integration_id == integration.id

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert reloaded.graph_delta_link =~ "$deltatoken=fresh"
    end

    test "chains into bootstrap in the same job when the obsolete-link auto-clear fires" do
      # Existing integrations may carry a `/me/events/delta` link from the old
      # bootstrap path. DeltaSync detects and clears it; the worker must then
      # finish the job by bootstrapping a fresh `calendarView/delta` baseline,
      # not punt to an Oban retry — otherwise the first click would do nothing
      # visible.
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=obsolete"
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      # Bootstrap must run inside this job, not on a later retry.
      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        assert received.id == integration.id
        assert is_nil(received.graph_delta_link)
        {:ok, %{received | graph_delta_link: "fresh-calendarview-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      # Mox would raise if any HTTP request fires against the obsolete URL.

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, _user_id, _integration_id}
    end

    test "returns an error and does not broadcast when delta sync fails" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "boom"}}
      end)

      assert {:error, :delta_sync_failed} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      refute_receive {:calendar_sync_complete, _user_id, _integration_id}
    end
  end

  describe "perform/1 input validation" do
    test "discards when the integration does not exist" do
      assert {:discard, "Integration not found"} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => 999_999_999
               })
    end

    test "discards when the integration is not an Outlook one" do
      # A Google integration accidentally routed here (factory bug, stale args,
      # etc.) must NOT trigger Outlook-specific API calls. Mox would raise on
      # any unexpected call.
      integration = insert(:calendar_integration, provider: "google", is_active: true)

      assert {:discard, "Integration is not Outlook"} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end
end
