defmodule TymeslotWeb.StripeConnectWebhookTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :controllers

  import Tymeslot.Factory

  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Payments.Webhooks.StripeEventQueries
  alias Tymeslot.PaymentTestHelpers

  @secret "whsec_test_connect"

  setup do
    Application.put_env(:tymeslot, :stripe_connect_webhook_secret, @secret)

    on_exit(fn ->
      Application.delete_env(:tymeslot, :stripe_connect_webhook_secret)
    end)

    :ok
  end

  defp post_connect(conn, payload, signature \\ nil) do
    signature = signature || PaymentTestHelpers.generate_stripe_signature(payload, @secret)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature)
    |> assign(:raw_body, payload)
    |> post("/webhooks/stripe/connect", payload)
  end

  describe "POST /webhooks/stripe/connect" do
    test "returns an empty 400 when signature verification fails", %{conn: conn} do
      payload = ~s({"id":"evt_BAD","type":"account.updated"})

      assert conn |> post_connect(payload, "t=1,v1=BAD") |> response(400) == ""
    end

    test "acknowledges and records a signed but malformed event, so Stripe stops redelivering it",
         %{conn: conn} do
      # `account.updated` without a `data.object` is rejected by its handler
      # as `:invalid_event`, which no retry can fix.
      event_id = unique_event_id("evt_MALFORMED")
      payload = Jason.encode!(%{"id" => event_id, "type" => "account.updated"})

      assert conn |> post_connect(payload) |> response(200) == ""
      assert IdempotencyCache.reserve(event_id) == {:ok, :already_processed}
    end

    test "returns 200 and records the event when it is dispatched to a known handler",
         %{conn: conn} do
      now = System.os_time(:second)
      event_id = unique_event_id("evt_OK")

      payload =
        Jason.encode!(%{
          "id" => event_id,
          "type" => "account.updated",
          "created" => now,
          "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
        })

      assert conn |> post_connect(payload) |> response(200) == ""

      assert StripeEventQueries.get_by_stripe_id(event_id).event_type ==
               "account.updated"
    end

    test "answers 503 when the account update fails, so Stripe redelivers the event",
         %{conn: conn} do
      now = System.os_time(:second)
      account = insert(:connect_account, charges_enabled: false, last_account_event_at: nil)
      event_id = unique_event_id("evt_REJECTED")

      payload =
        Jason.encode!(%{
          "id" => event_id,
          "type" => "account.updated",
          "created" => now,
          "data" => %{
            "object" => %{
              "id" => account.stripe_account_id,
              "created" => now,
              "charges_enabled" => "not-a-boolean"
            }
          }
        })

      assert conn |> post_connect(payload) |> response(503) == ""
      refute StripeEventQueries.get_by_stripe_id(event_id)
    end

    test "returns 200 when event type has no registered handler (silently ignored)",
         %{conn: conn} do
      event_id = unique_event_id("evt_PING")
      payload = Jason.encode!(%{"id" => event_id, "type" => "ping.event"})

      assert conn |> post_connect(payload) |> response(200) == ""
    end

    test "a replayed event is not redispatched (single fan-out for a duplicate delivery)", %{
      conn: conn
    } do
      now = System.os_time(:second)

      event = %{
        "id" => unique_event_id("evt_DUPLICATE"),
        "type" => "account.updated",
        "created" => now,
        "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
      }

      # Signature verification runs before deduplication, so both deliveries
      # are verified; the replay must stop there.
      payload = Jason.encode!(event)

      assert conn |> post_connect(payload) |> response(200) == ""
      assert build_conn() |> post_connect(payload) |> response(200) == ""
    end

    test "a failed-signature attempt never reserves the event, so a genuine delivery is dispatched",
         %{conn: conn} do
      now = System.os_time(:second)
      event_id = unique_event_id("evt_REDELIVERY")

      payload =
        Jason.encode!(%{
          "id" => event_id,
          "type" => "account.updated",
          "created" => now,
          "data" => %{"object" => %{"id" => "acct_UNKNOWN", "created" => now}}
        })

      assert conn |> post_connect(payload, "t=1,v1=BAD") |> response(400) == ""

      # A forged payload carrying a guessed event id must not claim the dedup
      # slot, or Stripe's genuine delivery would be swallowed as a duplicate
      # and never recorded as processed below.
      refute StripeEventQueries.get_by_stripe_id(event_id)

      assert build_conn() |> post_connect(payload) |> response(200) == ""
      assert IdempotencyCache.reserve(event_id) == {:ok, :already_processed}
    end

    test "returns an empty 503 when the webhook secret is not configured (so Stripe retries)", %{
      conn: conn
    } do
      Application.delete_env(:tymeslot, :stripe_connect_webhook_secret)

      payload = ~s({"id":"evt_X","type":"account.updated"})

      assert conn |> post_connect(payload, "t=1,v1=X") |> response(503) == ""
    end
  end

  # The idempotency cache's in-memory tier outlives the sandbox, so every
  # test delivers an event id no other test has used.
  defp unique_event_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
