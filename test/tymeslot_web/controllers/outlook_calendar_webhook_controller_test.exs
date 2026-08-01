defmodule TymeslotWeb.OutlookCalendarWebhookControllerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :controllers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  describe "webhook/2 - validation challenge" do
    test "returns 200 with the validationToken as plain text body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar?validationToken=abc-def-123")

      assert conn.status == 200
      assert conn.resp_body == "abc-def-123"
      assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"
    end

    test "echoes the token when the provider negotiates text/plain", %{conn: conn} do
      # Microsoft Graph's subscription-validation handshake sends
      # `Accept: text/plain`. The json-only pipeline used to reject this with
      # 406 Not Acceptable, so Graph abandoned the subscription with an HTTP 400
      # validation error. The route must accept the text/plain handshake.
      conn =
        conn
        |> put_req_header("accept", "text/plain")
        |> post("/webhooks/outlook-calendar?validationToken=graph-challenge-xyz")

      assert conn.status == 200
      assert conn.resp_body == "graph-challenge-xyz"
      assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"
    end

    test "does not enqueue any job for a validation challenge", %{conn: conn} do
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/outlook-calendar?validationToken=challenge-token")

      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end
  end

  describe "webhook/2 - valid change notification" do
    test "enqueues SyncOutlookCalendarWorker and returns 202 for a valid notification", %{
      conn: conn
    } do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-abc-123",
          graph_client_state: "client-state-secret"
        )

      payload = %{
        "value" => [
          %{
            "subscriptionId" => integration.graph_subscription_id,
            "clientState" => integration.graph_client_state,
            "resourceData" => %{"id" => "event-resource-id-xyz"}
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", payload)

      assert conn.status == 202

      assert_enqueued(
        worker: SyncOutlookCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "updates last_outlook_notification_at on a valid notification", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-ts-update",
          graph_client_state: "state-secret-update",
          last_outlook_notification_at: nil
        )

      payload = %{
        "value" => [
          %{
            "subscriptionId" => integration.graph_subscription_id,
            "clientState" => integration.graph_client_state,
            "resourceData" => %{"id" => "event-id"}
          }
        ]
      }

      conn
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/outlook-calendar", payload)

      updated = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert %DateTime{} = updated.last_outlook_notification_at
    end
  end

  describe "webhook/2 - invalid clientState" do
    test "returns 202 without enqueuing a job when clientState is wrong", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-bad-state",
          graph_client_state: "real-secret"
        )

      payload = %{
        "value" => [
          %{
            "subscriptionId" => integration.graph_subscription_id,
            "clientState" => "wrong-secret",
            "resourceData" => %{"id" => "event-id"}
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", payload)

      assert conn.status == 202
      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end

    test "returns 202 without enqueuing a job when clientState is missing", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-no-state",
          graph_client_state: "some-secret"
        )

      payload = %{
        "value" => [
          %{
            "subscriptionId" => integration.graph_subscription_id,
            "resourceData" => %{"id" => "event-id"}
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", payload)

      assert conn.status == 202
      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end
  end

  describe "webhook/2 - unknown subscription" do
    test "returns 202 without enqueuing a job for an unknown subscriptionId", %{conn: conn} do
      payload = %{
        "value" => [
          %{
            "subscriptionId" => "nonexistent-subscription-id",
            "clientState" => "any-state",
            "resourceData" => %{"id" => "event-id"}
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", payload)

      assert conn.status == 202
      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end

    test "returns 202 with an empty value list", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", %{"value" => []})

      assert conn.status == 202
      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end
  end

  describe "webhook/2 - batch notifications" do
    test "enqueues jobs only for valid integrations and skips unknown subscriptions", %{
      conn: conn
    } do
      integration_a =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-batch-a",
          graph_client_state: "state-batch-a"
        )

      integration_b =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-batch-b",
          graph_client_state: "state-batch-b"
        )

      payload = %{
        "value" => [
          %{
            "subscriptionId" => integration_a.graph_subscription_id,
            "clientState" => integration_a.graph_client_state,
            "resourceData" => %{"id" => "event-a"}
          },
          %{
            "subscriptionId" => integration_b.graph_subscription_id,
            "clientState" => integration_b.graph_client_state,
            "resourceData" => %{"id" => "event-b"}
          },
          %{
            "subscriptionId" => "nonexistent-sub-id",
            "clientState" => "irrelevant",
            "resourceData" => %{"id" => "event-unknown"}
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", payload)

      assert conn.status == 202

      assert_enqueued(
        worker: SyncOutlookCalendarWorker,
        args: %{"calendar_integration_id" => integration_a.id}
      )

      assert_enqueued(
        worker: SyncOutlookCalendarWorker,
        args: %{"calendar_integration_id" => integration_b.id}
      )

      # The unknown subscription should not have enqueued a job —
      # only 2 jobs should exist in total.
      assert length(all_enqueued(worker: SyncOutlookCalendarWorker)) == 2
    end
  end
end
