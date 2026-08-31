defmodule TymeslotWeb.StripeConnectWebhookControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :controllers

  import Mox

  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Webhooks.WebhookQueries

  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :stripe_connect_webhook_secret, "whsec_test_connect")
    IdempotencyCache.clear_all()

    on_exit(fn ->
      Application.delete_env(:tymeslot, :stripe_connect_webhook_secret)
    end)

    :ok
  end

  describe "POST /webhooks/stripe/connect" do
    test "returns 400 when signature verification fails", %{conn: conn} do
      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:error, "Invalid signature"}
      end)

      payload = ~s({"id":"evt_BAD","type":"account.updated","created":#{System.os_time(:second)}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=BAD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(conn, 400)
    end

    test "returns 400 when event is older than the 5-minute replay window", %{conn: conn} do
      stale_created = System.os_time(:second) - 6 * 60

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok, %{"id" => "evt_OLD", "type" => "account.updated", "created" => stale_created}}
      end)

      payload = ~s({"id":"evt_OLD","created":#{stale_created}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=GOOD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(conn, 400)
    end

    test "returns 200 when a valid event is dispatched to a known handler", %{conn: conn} do
      now = System.os_time(:second)

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok,
         %{
           "id" => "evt_OK",
           "type" => "account.updated",
           "created" => now,
           "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
         }}
      end)

      payload = ~s({"id":"evt_OK","type":"account.updated","created":#{now}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=GOOD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(conn, 200)
    end

    test "returns 200 when event type has no registered handler (silently ignored)",
         %{conn: conn} do
      now = System.os_time(:second)

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok, %{"id" => "evt_OK", "type" => "ping.event", "created" => now}}
      end)

      payload = ~s({"id":"evt_OK","type":"ping.event","created":#{now}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=GOOD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(conn, 200)
    end

    test "a replayed event is not redispatched (single fan-out for a duplicate delivery)", %{
      conn: conn
    } do
      now = System.os_time(:second)
      event_id = "evt_DUPLICATE"

      # `expect/3` defaults to exactly one call: if the second delivery
      # reached the handler again, this expectation would be violated.
      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok,
         %{
           "id" => event_id,
           "type" => "account.updated",
           "created" => now,
           "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
         }}
      end)

      payload =
        ~s({"id":"#{event_id}","type":"account.updated","created":#{now}})

      first =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=GOOD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(first, 200)

      second =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=GOOD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(second, 200)
    end

    test "a genuine redelivery after a failed-signature attempt is still dispatched, not swallowed",
         %{conn: conn} do
      now = System.os_time(:second)
      event_id = "evt_REDELIVERY"
      payload = ~s({"id":"#{event_id}","type":"account.updated","created":#{now}})

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:error, "Invalid signature"}
      end)

      failed =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=BAD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(failed, 400)

      # The failed-signature delivery must not have reserved the dedup slot
      # for this event id, or a genuine, correctly-signed redelivery of the
      # same event would be swallowed as `:already_processed` below.
      assert IdempotencyCache.check_idempotency(event_id) == {:ok, :not_processed}
      refute WebhookQueries.get_webhook_event_by_stripe_id(event_id)

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok,
         %{
           "id" => event_id,
           "type" => "account.updated",
           "created" => now,
           "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
         }}
      end)

      redelivered =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=GOOD")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(redelivered, 200)
      assert IdempotencyCache.check_idempotency(event_id) == {:ok, :already_processed}

      stored = WebhookQueries.get_webhook_event_by_stripe_id(event_id)
      assert stored.event_type == "account.updated"
    end

    test "returns 503 when the webhook secret is not configured (so Stripe retries)", %{
      conn: conn
    } do
      Application.delete_env(:tymeslot, :stripe_connect_webhook_secret)

      payload = ~s({"id":"evt_X","type":"account.updated"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=X")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe/connect", payload)

      assert response(conn, 503)
    end
  end
end
