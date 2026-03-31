defmodule TymeslotWeb.OutlookLifecycleControllerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :controllers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Workers.ReregisterOutlookSubscriptionWorker

  @lifecycle_path "/webhooks/outlook-lifecycle"

  defp build_lifecycle_payload(events) do
    %{"value" => events}
  end

  defp build_lifecycle_event(attrs) do
    Map.merge(
      %{
        "subscriptionId" => "sub-default",
        "lifecycleEvent" => "reauthorizationRequired",
        "clientState" => "default-state"
      },
      attrs
    )
  end

  defp post_lifecycle(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@lifecycle_path, payload)
  end

  defp insert_outlook_integration(attrs \\ %{}) do
    defaults = %{
      provider: "outlook",
      graph_subscription_id: "sub-lifecycle-#{System.unique_integer([:positive])}",
      graph_client_state: "client-state-#{System.unique_integer([:positive])}"
    }

    insert(:calendar_integration, Map.to_list(Map.merge(defaults, Map.new(attrs))))
  end

  describe "webhook/2 - reauthorizationRequired" do
    @tag capture_log: true
    test "returns 202 and enqueues TokenRefreshJob and ReregisterOutlookSubscriptionWorker", %{
      conn: conn
    } do
      integration = insert_outlook_integration()

      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => integration.graph_client_state
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202

      assert_enqueued(
        worker: TokenRefreshJob,
        args: %{"integration_id" => integration.id}
      )

      assert_enqueued(
        worker: ReregisterOutlookSubscriptionWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "webhook/2 - subscriptionRemoved" do
    @tag capture_log: true
    test "returns 202 and enqueues reregistration but not token refresh", %{conn: conn} do
      integration = insert_outlook_integration()

      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "subscriptionRemoved",
            "clientState" => integration.graph_client_state
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202
      refute_enqueued(worker: TokenRefreshJob)

      assert_enqueued(
        worker: ReregisterOutlookSubscriptionWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "webhook/2 - invalid clientState" do
    @tag capture_log: true
    test "returns 202 without enqueuing a job when clientState is wrong", %{conn: conn} do
      integration = insert_outlook_integration()

      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => "wrong-secret"
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202
      refute_enqueued(worker: TokenRefreshJob)
    end

    @tag capture_log: true
    test "returns 202 without enqueuing a job when clientState is empty", %{conn: conn} do
      integration = insert_outlook_integration()

      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => ""
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202
      refute_enqueued(worker: TokenRefreshJob)
    end
  end

  describe "webhook/2 - unknown subscriptionId" do
    test "returns 202 without enqueuing a job for an unknown subscriptionId", %{conn: conn} do
      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => "nonexistent-subscription-id",
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => "any-state"
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202
      refute_enqueued(worker: TokenRefreshJob)
    end
  end

  describe "webhook/2 - unknown lifecycleEvent type" do
    @tag capture_log: true
    test "returns 202 for an unrecognised lifecycle event type", %{conn: conn} do
      integration = insert_outlook_integration()

      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "unknownEventType",
            "clientState" => integration.graph_client_state
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202
      refute_enqueued(worker: TokenRefreshJob)
    end
  end

  describe "webhook/2 - missing or empty value array" do
    test "returns 202 with an empty value list", %{conn: conn} do
      conn = post_lifecycle(conn, %{"value" => []})

      assert conn.status == 202
      refute_enqueued(worker: TokenRefreshJob)
    end

    test "returns 202 when value key is missing", %{conn: conn} do
      conn = post_lifecycle(conn, %{})

      assert conn.status == 202
      refute_enqueued(worker: TokenRefreshJob)
    end
  end

  describe "webhook/2 - batch deduplication" do
    @tag capture_log: true
    test "deduplicates events by subscriptionId within a single batch", %{conn: conn} do
      integration = insert_outlook_integration()

      # Same subscription sends 5 reauthorizationRequired events in one batch
      events =
        for _i <- 1..5 do
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => integration.graph_client_state
          })
        end

      conn = post_lifecycle(conn, build_lifecycle_payload(events))

      assert conn.status == 202

      # Only 1 TokenRefreshJob should be enqueued, not 5
      token_jobs = all_enqueued(worker: TokenRefreshJob)
      assert length(token_jobs) == 1

      # Only 1 reregistration job should be enqueued, not 5
      rereg_jobs = all_enqueued(worker: ReregisterOutlookSubscriptionWorker)
      assert length(rereg_jobs) == 1
    end
  end

  describe "webhook/2 - multiple lifecycle events" do
    @tag capture_log: true
    test "processes all events in a single payload", %{conn: conn} do
      integration_a = insert_outlook_integration()
      integration_b = insert_outlook_integration()

      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => integration_a.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => integration_a.graph_client_state
          }),
          build_lifecycle_event(%{
            "subscriptionId" => integration_b.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => integration_b.graph_client_state
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202

      assert_enqueued(
        worker: TokenRefreshJob,
        args: %{"integration_id" => integration_a.id}
      )

      assert_enqueued(
        worker: TokenRefreshJob,
        args: %{"integration_id" => integration_b.id}
      )
    end

    @tag capture_log: true
    test "valid and invalid events in the same payload are handled independently", %{conn: conn} do
      integration = insert_outlook_integration()

      payload =
        build_lifecycle_payload([
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => integration.graph_client_state
          }),
          build_lifecycle_event(%{
            "subscriptionId" => integration.graph_subscription_id,
            "lifecycleEvent" => "reauthorizationRequired",
            "clientState" => "wrong-state"
          })
        ])

      conn = post_lifecycle(conn, payload)

      assert conn.status == 202

      # Only the valid event should enqueue a job
      assert_enqueued(
        worker: TokenRefreshJob,
        args: %{"integration_id" => integration.id}
      )
    end
  end
end
