defmodule TymeslotWeb.StripeWebhookControllerTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: false

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Stripe.Error, as: StripeError
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.TestFixtures

  setup :verify_on_exit!
  @moduletag :utils

  setup do
    # Clear idempotency cache before each test
    IdempotencyCache.clear_all()
    stub(Tymeslot.Payments.StripeMock, :verify_session, fn _session_id -> {:ok, %{}} end)
    :ok
  end

  describe "POST /webhooks/stripe" do
    # Note: In test environment, skip_webhook_verification is enabled,
    # so signature validation tests would pass even with missing/invalid signatures.
    # These tests are kept for documentation but will pass due to development mode bypass.

    test "returns 400 when webhook signature is missing", %{conn: conn} do
      with_config(:tymeslot, skip_webhook_verification: false)

      payload = ~s({"type":"checkout.session.completed", "id":"evt_123"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert json_response(conn, 400)
    end

    test "returns 400 when webhook signature is invalid", %{conn: conn} do
      with_config(:tymeslot,
        skip_webhook_verification: false,
        stripe_provider: Tymeslot.Payments.Stripe,
        stripe_webhook_secret: "whsec_test"
      )

      payload = ~s({"type":"checkout.session.completed", "id":"evt_123"})

      # Use a malformed signature that doesn't have t= and v1=
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "invalid_signature")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert json_response(conn, 400)
    end

    test "returns 400 when webhook signature is valid but for different payload", %{conn: conn} do
      secret = "whsec_test"

      with_config(:tymeslot,
        skip_webhook_verification: false,
        stripe_provider: Tymeslot.Payments.Stripe,
        stripe_webhook_secret: secret
      )

      payload = ~s({"type":"checkout.session.completed", "id":"evt_123"})
      different_payload = ~s({"type":"checkout.session.completed", "id":"evt_456"})
      signature = PaymentTestHelpers.generate_stripe_signature(different_payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert json_response(conn, 400)
    end

    test "processes valid webhook with checkout.session.completed event", %{conn: conn} do
      # Create a test session
      session = PaymentTestHelpers.mock_stripe_checkout_session()
      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)

      payload = Jason.encode!(event)

      # In development mode (no webhook secret), signature verification is skipped
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      # Should return 200 OK (controller returns empty string, not JSON)
      assert response(conn, 200) == ""
    end

    test "prevents duplicate processing of same event", %{conn: _conn} do
      session = PaymentTestHelpers.mock_stripe_checkout_session()
      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)

      payload = Jason.encode!(event)

      # Process first time
      conn1 =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert response(conn1, 200) == ""

      # Process second time - should be rejected as duplicate (halted in plug)
      conn2 =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      # The plug halts with 200 for already processed events
      assert response(conn2, 200) == ""
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
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert response(conn, 200) == ""
    end

    test "returns 503 and allows retry on transient Stripe errors", %{conn: _conn} do
      user = TestFixtures.create_user_fixture()
      session_id = "cs_test_retry"

      session =
        PaymentTestHelpers.mock_stripe_checkout_session(%{
          session_id: session_id
        })

      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        stripe_id: session_id,
        status: "pending"
      })

      expect(Tymeslot.Payments.StripeMock, :verify_session, 2, fn ^session_id ->
        {:error, %StripeError{source: :network, message: "timeout", code: :network_error}}
      end)

      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)
      payload = Jason.encode!(event)

      conn1 =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert response(conn1, 503)

      # Second request should not be blocked by idempotency
      conn2 =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert response(conn2, 503)
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
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      # Should return 200 OK even for unknown events (controller returns empty string, not JSON)
      assert response(conn, 200) == ""
    end
  end
end
