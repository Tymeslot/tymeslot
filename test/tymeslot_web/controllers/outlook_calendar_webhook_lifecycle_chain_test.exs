defmodule TymeslotWeb.OutlookCalendarWebhookLifecycleChainTest do
  @moduledoc """
  The whole path of a Microsoft Graph `reauthorizationRequired` lifecycle
  event: the endpoint enqueues `TokenRefreshJob` and, behind it,
  `ReregisterOutlookSubscriptionWorker`; the refresh stores a fresh token, and
  the re-registration renews the subscription with that token and stores what
  Graph answered. The enqueue alone is covered in
  `OutlookCalendarWebhookControllerLifecycleTest`.

  Graph is played through `HTTPClientMock` and the token endpoint through
  `OutlookCalendarAPIMock.refresh_token/1`; everything between runs for real.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :calendar

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.ReregisterOutlookSubscriptionWorker

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :webhook_base_url, "https://hook.example.com")
    :ok
  end

  test "reauthorizationRequired refreshes the token, then renews the subscription with it", %{
    conn: conn
  } do
    # The access token has expired: renewing the subscription needs the
    # refresh to have run first.
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        access_token_encrypted: Encryption.encrypt("stale-token"),
        refresh_token_encrypted: Encryption.encrypt("refresh-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second),
        graph_subscription_id: "graph-sub-live",
        graph_client_state: "chain-client-state",
        graph_subscription_expires_at: DateTime.add(DateTime.utc_now(:second), 1, :day)
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/outlook-lifecycle", %{
        "value" => [
          %{
            "subscriptionId" => "graph-sub-live",
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => "chain-client-state"
          }
        ]
      })

    assert conn.status == 202

    assert [refresh_job] =
             all_enqueued(worker: TokenRefreshJob, args: %{"integration_id" => integration.id})

    assert [reregister_job] =
             all_enqueued(
               worker: ReregisterOutlookSubscriptionWorker,
               args: %{"calendar_integration_id" => integration.id}
             )

    # The re-registration is held back so the refresh runs first.
    assert DateTime.diff(reregister_job.scheduled_at, refresh_job.scheduled_at) >= 29

    fresh_expiry = DateTime.add(DateTime.utc_now(:second), 3600, :second)

    expect(OutlookCalendarAPIMock, :refresh_token, fn _integration ->
      {:ok, {"fresh-token", "fresh-refresh-token", fresh_expiry}}
    end)

    assert :ok = perform_job(TokenRefreshJob, refresh_job.args)

    renewed_expiry = DateTime.add(DateTime.utc_now(:second), 3, :day)

    expect(Tymeslot.HTTPClientMock, :request, fn :patch, url, _body, headers, _opts ->
      assert String.ends_with?(url, "/subscriptions/graph-sub-live")
      assert {"Authorization", "Bearer fresh-token"} in headers

      {:ok,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "id" => "graph-sub-live",
             "expirationDateTime" => DateTime.to_iso8601(renewed_expiry)
           })
       }}
    end)

    assert :ok = perform_job(ReregisterOutlookSubscriptionWorker, reregister_job.args)

    stored =
      CalendarIntegrationSchema
      |> Repo.get!(integration.id)
      |> CalendarIntegrationSchema.decrypt_oauth_tokens()

    assert stored.access_token == "fresh-token"
    assert stored.graph_subscription_id == "graph-sub-live"
    assert stored.graph_client_state == "chain-client-state"
    assert stored.graph_subscription_expires_at == renewed_expiry
  end
end
