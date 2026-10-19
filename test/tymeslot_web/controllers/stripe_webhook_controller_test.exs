defmodule TymeslotWeb.StripeWebhookControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :payments
  @moduletag :controllers

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Payments.Webhooks.StripeEventSchema, as: WebhookEvent
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.Repo

  @secret "whsec_controller_test"

  setup :verify_on_exit!

  defp deliver(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "stripe-signature",
      PaymentTestHelpers.generate_stripe_signature(payload, @secret)
    )
    |> assign(:raw_body, payload)
    |> post("/webhooks/stripe", payload)
  end

  describe "POST /webhooks/stripe" do
    setup do
      with_config(:tymeslot, stripe_webhook_secret: @secret)

      :ok
    end

    test "returns an empty 400 when webhook signature is missing", %{conn: conn} do
      with_config(:tymeslot, stripe_webhook_secret: "whsec_test")

      payload = ~s({"type":"checkout.session.completed", "id":"evt_123"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert response(conn, 400) == ""
    end

    test "returns an empty 400 when webhook signature is invalid", %{conn: conn} do
      with_config(:tymeslot, stripe_webhook_secret: "whsec_test")

      payload = ~s({"type":"checkout.session.completed", "id":"evt_123"})

      # Use a malformed signature that doesn't have t= and v1=
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "invalid_signature")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert response(conn, 400) == ""
    end

    test "returns an empty 400 when webhook signature is valid but for different payload", %{
      conn: conn
    } do
      secret = "whsec_test"

      with_config(:tymeslot, stripe_webhook_secret: secret)

      payload = ~s({"type":"checkout.session.completed", "id":"evt_123"})
      different_payload = ~s({"type":"checkout.session.completed", "id":"evt_456"})
      signature = PaymentTestHelpers.generate_stripe_signature(different_payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert response(conn, 400) == ""
    end

    test "processes valid webhook with checkout.session.completed event", %{conn: conn} do
      # Create a test session
      session = PaymentTestHelpers.mock_stripe_checkout_session()
      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)

      payload = Jason.encode!(event)

      conn =
        deliver(conn, payload)

      # Should return 200 OK (controller returns empty string, not JSON)
      assert response(conn, 200) == ""
    end

    test "prevents duplicate processing of same event", %{conn: _conn} do
      session = PaymentTestHelpers.mock_stripe_checkout_session()
      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)
      event_id = event["id"] || event[:id]

      payload = Jason.encode!(event)

      # Process first time
      conn1 =
        deliver(build_conn(), payload)

      assert response(conn1, 200) == ""

      # Process second time - should be rejected as duplicate (halted in plug)
      conn2 =
        deliver(build_conn(), payload)

      # The duplicate is answered with a byte-identical `200 ""`, so the response
      # alone cannot tell the two deliveries apart; the single `webhook_events`
      # row shows the duplicate was not processed a second time.
      assert response(conn2, 200) == ""

      assert Repo.aggregate(
               from(w in WebhookEvent, where: w.stripe_event_id == ^event_id),
               :count,
               :id
             ) == 1
    end

    test "returns 200 when subscription manager is not configured", %{conn: conn} do
      with_config(:tymeslot, subscription_manager: nil)

      session =
        PaymentTestHelpers.mock_stripe_checkout_session(%{
          mode: "subscription"
        })

      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)
      payload = Jason.encode!(event)

      conn =
        deliver(conn, payload)

      assert response(conn, 200) == ""
    end

    test "returns 503 and allows retry on transient Stripe errors", %{conn: _conn} do
      # A renewal invoice whose subscription has no completed transaction yet is
      # the handler's transient case: it returns `:retry_later` so Stripe
      # redelivers, rather than acknowledging an event it could not process.
      invoice = %{
        "id" => "in_test_retry",
        "subscription" => "sub_test_retry",
        "billing_reason" => "subscription_cycle",
        "amount_paid" => 900,
        "total" => 900,
        "currency" => "eur",
        "created" => System.system_time(:second)
      }

      event = PaymentTestHelpers.mock_stripe_webhook_event("invoice.paid", invoice)
      payload = Jason.encode!(event)

      conn1 =
        deliver(build_conn(), payload)

      # Empty body: the retry message is internal and only logged.
      assert response(conn1, 503) == ""

      # The reservation was released, so the redelivery is processed again
      # rather than treated as in progress or already processed. Probing it
      # takes the slot, so give it straight back for the redelivery.
      assert IdempotencyCache.reserve(event["id"]) == {:ok, :reserved}
      :ok = IdempotencyCache.release(event["id"])

      conn2 =
        deliver(build_conn(), payload)

      assert response(conn2, 503) == ""
    end

    test "returns an empty 503 when the webhook secret is not configured", %{conn: conn} do
      with_config(:tymeslot, stripe_webhook_secret: nil)

      payload = ~s({"type":"checkout.session.completed", "id":"evt_no_secret"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=abc")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      # Nothing about the server's configuration reaches the caller.
      assert response(conn, 503) == ""
    end

    test "acknowledges and records an event whose handler returns a permanent error",
         %{conn: conn} do
      # `TrialWillEndHandler` answers a non-integer `trial_end` with
      # `{:error, :permanent, :invalid_timestamp}`. It must settle as a
      # permanent failure: 200, and the event recorded so Stripe stops
      # redelivering it, rather than leaving the reservation held.
      subscription = %{
        "id" => "sub_bad_trial_end",
        "customer" => "cus_bad_trial_end",
        "trial_end" => "not-a-timestamp"
      }

      event =
        PaymentTestHelpers.mock_stripe_webhook_event(
          "customer.subscription.trial_will_end",
          subscription
        )

      payload = Jason.encode!(event)

      conn =
        deliver(conn, payload)

      assert response(conn, 200) == ""
      assert IdempotencyCache.reserve(event["id"]) == {:ok, :already_processed}
      assert Repo.get_by(WebhookEvent, stripe_event_id: event["id"])
    end

    test "persists event payload to database on successful processing", %{conn: conn} do
      session = PaymentTestHelpers.mock_stripe_checkout_session()
      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)
      event_id = event["id"] || event[:id]

      payload = Jason.encode!(event)

      deliver(conn, payload)

      record = Repo.get_by!(WebhookEvent, stripe_event_id: event_id)
      assert record.payload["type"] == "checkout.session.completed"
    end

    test "acknowledges and does not get stuck on a malformed trial_will_end event", %{
      conn: conn
    } do
      subscription = %{
        "id" => "sub_malformed_trial",
        "customer" => "cus_malformed_trial",
        "trial_end" => "not_a_timestamp"
      }

      event =
        PaymentTestHelpers.mock_stripe_webhook_event(
          "customer.subscription.trial_will_end",
          subscription
        )

      event_id = event["id"]
      payload = Jason.encode!(event)

      conn =
        deliver(conn, payload)

      # A handler that can't process the event must not crash the controller;
      # Stripe gets a plain 200 so it stops retrying an event that will never
      # succeed.
      assert response(conn, 200) == ""

      # And the event is marked processed rather than left "in progress",
      # so a genuine Stripe retry of the same event is also acknowledged
      # immediately instead of receiving a 503.
      conn2 =
        deliver(build_conn(), payload)

      assert response(conn2, 200) == ""

      assert Repo.aggregate(
               from(w in WebhookEvent, where: w.stripe_event_id == ^event_id),
               :count,
               :id
             ) == 1
    end

    test "handles unknown event types gracefully", %{conn: conn} do
      event =
        PaymentTestHelpers.mock_stripe_webhook_event("unknown.event.type", %{
          "id" => "evt_unknown"
        })

      payload = Jason.encode!(event)

      # We can't easily assert on the Task.start or Logger output without more complex setup,
      # but we can ensure the request completes successfully.
      conn =
        deliver(conn, payload)

      # Should return 200 OK even for unknown events (controller returns empty string, not JSON)
      assert response(conn, 200) == ""
    end
  end
end
