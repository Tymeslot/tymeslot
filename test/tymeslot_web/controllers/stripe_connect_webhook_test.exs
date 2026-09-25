defmodule TymeslotWeb.StripeConnectWebhookTest do
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

  defp post_connect(conn, payload, signature \\ "t=1,v1=GOOD") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature)
    |> assign(:raw_body, payload)
    |> post("/webhooks/stripe/connect", payload)
  end

  defp verified(event) do
    expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, "whsec_test_connect" ->
      {:ok, event}
    end)
  end

  describe "POST /webhooks/stripe/connect" do
    test "returns an empty 400 when signature verification fails", %{conn: conn} do
      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:error, "Invalid signature"}
      end)

      payload = ~s({"id":"evt_BAD","type":"account.updated"})

      assert conn |> post_connect(payload, "t=1,v1=BAD") |> response(400) == ""
    end

    test "acknowledges and records a signed but malformed event, so Stripe stops redelivering it",
         %{conn: conn} do
      # `account.updated` without a `data.object` is rejected by its handler
      # as `:invalid_event`, which no retry can fix.
      verified(%{"id" => "evt_MALFORMED", "type" => "account.updated"})

      payload = ~s({"id":"evt_MALFORMED","type":"account.updated"})

      assert conn |> post_connect(payload) |> response(200) == ""
      assert IdempotencyCache.check_idempotency("evt_MALFORMED") == {:ok, :already_processed}
    end

    test "returns 200 and records the event when it is dispatched to a known handler",
         %{conn: conn} do
      now = System.os_time(:second)

      verified(%{
        "id" => "evt_OK",
        "type" => "account.updated",
        "created" => now,
        "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
      })

      payload = ~s({"id":"evt_OK","type":"account.updated","created":#{now}})

      assert conn |> post_connect(payload) |> response(200) == ""

      assert WebhookQueries.get_webhook_event_by_stripe_id("evt_OK").event_type ==
               "account.updated"
    end

    test "returns 200 when event type has no registered handler (silently ignored)",
         %{conn: conn} do
      verified(%{"id" => "evt_PING", "type" => "ping.event"})

      payload = ~s({"id":"evt_PING","type":"ping.event"})

      assert conn |> post_connect(payload) |> response(200) == ""
    end

    test "a replayed event is not redispatched (single fan-out for a duplicate delivery)", %{
      conn: conn
    } do
      now = System.os_time(:second)

      event = %{
        "id" => "evt_DUPLICATE",
        "type" => "account.updated",
        "created" => now,
        "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
      }

      # Signature verification now runs before deduplication, so both
      # deliveries are verified; the replay must stop there.
      expect(StripeAdapterMock, :construct_webhook_event, 2, fn _payload, _sig, _secret ->
        {:ok, event}
      end)

      payload = Jason.encode!(event)

      assert conn |> post_connect(payload) |> response(200) == ""
      assert build_conn() |> post_connect(payload) |> response(200) == ""
    end

    test "a failed-signature attempt never reserves the event, so a genuine delivery is dispatched",
         %{conn: conn} do
      now = System.os_time(:second)
      event_id = "evt_REDELIVERY"
      payload = ~s({"id":"#{event_id}","type":"account.updated","created":#{now}})

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:error, "Invalid signature"}
      end)

      assert conn |> post_connect(payload, "t=1,v1=BAD") |> response(400) == ""

      # A forged payload carrying a guessed event id must not claim the dedup
      # slot, or Stripe's genuine delivery would be swallowed as a duplicate.
      assert IdempotencyCache.check_idempotency(event_id) == {:ok, :not_processed}
      refute WebhookQueries.get_webhook_event_by_stripe_id(event_id)

      verified(%{
        "id" => event_id,
        "type" => "account.updated",
        "created" => now,
        "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
      })

      assert build_conn() |> post_connect(payload) |> response(200) == ""
      assert IdempotencyCache.check_idempotency(event_id) == {:ok, :already_processed}
    end

    test "returns an empty 503 when the webhook secret is not configured (so Stripe retries)", %{
      conn: conn
    } do
      Application.delete_env(:tymeslot, :stripe_connect_webhook_secret)

      payload = ~s({"id":"evt_X","type":"account.updated"})

      assert conn |> post_connect(payload, "t=1,v1=X") |> response(503) == ""
    end
  end
end
