defmodule TymeslotWeb.Plugs.StripeWebhookPlugTest do
  @moduledoc """
  Composition tests for the Stripe webhook pipeline: `WebhookBodyCachePlug`
  (run as a `body_reader` from `Plug.Parsers`), `StripeWebhookPlug` (rate
  limiting in the `:webhook` router pipeline) and `StripeWebhookController`.

    * **Rate limit on both endpoints**: the platform and the Connect endpoint
      each answer an exhausted limiter with a halted 429 before any
      verification work is done.

    * **End-to-end signature wiring**: a real POST to `/webhooks/stripe` with
      a valid HMAC must succeed without any manual `assign(:raw_body,
      payload)` in the test. This proves the pair (the route's `raw_body: true`
      metadata + `body_reader` = `WebhookBodyCachePlug.read_body`) is wired
      correctly; a regression that dropped the metadata would surface here as
      a 400 (empty cached body, so the signature cannot match).

  The numeric bound (1000 requests per minute, in a bucket of its own so
  Telegram and Zoom traffic cannot starve Stripe) lives in
  `Tymeslot.Security.RateLimiter.Bookings` and is pinned by its own tests;
  what matters here is the response when the limiter reports `:rate_limited`.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs
  @moduletag :payments

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  setup :verify_on_exit!

  setup do
    IdempotencyCache.clear_all()
    :ok
  end

  describe "rate limit" do
    setup %{conn: conn} do
      # A per-test address keeps the exhausted bucket from leaking into any
      # other test that posts from the default 127.0.0.1.
      last_octet = rem(System.unique_integer([:positive]), 250) + 1
      conn = %{conn | remote_ip: {10, 77, 0, last_octet}}
      client_ip = ClientIP.get(conn)

      # Hit 1001 times to avoid boundary races in the sliding window backend.
      for _i <- 1..1001, do: RateLimit.hit("stripe_webhook:#{client_ip}", 60_000, 1_000)
      assert {:error, :rate_limited} = RateLimiter.check_stripe_webhook_rate_limit(client_ip)

      on_exit(fn -> RateLimiter.clear_bucket("stripe_webhook:#{client_ip}") end)

      %{conn: conn}
    end

    test "the platform endpoint answers 429 and halts", %{conn: conn} do
      payload = ~s({"type":"checkout.session.completed","id":"evt_rate_limited"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/stripe", payload)

      assert conn.status == 429
      assert conn.halted

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "rate_limited",
               "message" => "Too many requests"
             }
    end

    test "the Connect endpoint answers 429 and halts before verifying anything", %{conn: conn} do
      # The secret is configured and no `StripeAdapterMock` expectation is
      # set, so reaching signature verification would raise
      # `Mox.UnexpectedCallError`.
      with_config(:tymeslot, stripe_connect_webhook_secret: "whsec_test_connect")

      payload = ~s({"type":"account.updated","id":"evt_connect_rate_limited"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=GOOD")
        |> post("/webhooks/stripe/connect", payload)

      assert conn.status == 429
      assert conn.halted
    end
  end

  describe "rate limit isolation" do
    test "an exhausted generic webhook bucket does not throttle Stripe", %{conn: conn} do
      last_octet = rem(System.unique_integer([:positive]), 250) + 1
      conn = %{conn | remote_ip: {10, 78, 0, last_octet}}
      client_ip = ClientIP.get(conn)

      # The bucket Telegram and Zoom share; Stripe must not draw from it.
      for _i <- 1..101, do: RateLimit.hit("webhook:#{client_ip}", 600_000, 100)
      assert {:error, :rate_limited} = RateLimiter.check_webhook_rate_limit(client_ip)
      on_exit(fn -> RateLimiter.clear_bucket("webhook:#{client_ip}") end)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/stripe", ~s({"type":"checkout.session.completed"}))

      refute conn.status == 429
    end
  end

  describe "end-to-end through /webhooks/stripe: signature verification" do
    test "accepts a POST with a valid HMAC signature when the body is cached by WebhookBodyCachePlug",
         %{conn: conn} do
      secret = "whsec_e2e_valid"

      with_config(:tymeslot,
        skip_webhook_verification: false,
        stripe_provider: Tymeslot.Payments.Stripe,
        stripe_webhook_secret: secret
      )

      session = PaymentTestHelpers.mock_stripe_checkout_session()
      event = PaymentTestHelpers.mock_stripe_webhook_event("checkout.session.completed", session)
      payload = Jason.encode!(event)
      signature = PaymentTestHelpers.generate_stripe_signature(payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> post("/webhooks/stripe", payload)

      assert response(conn, 200) == ""
    end

    test "rejects a POST with an invalid HMAC signature with an empty 400",
         %{conn: conn} do
      secret = "whsec_e2e_invalid"

      with_config(:tymeslot,
        skip_webhook_verification: false,
        stripe_provider: Tymeslot.Payments.Stripe,
        stripe_webhook_secret: secret
      )

      payload = ~s({"type":"checkout.session.completed","id":"evt_bad_sig"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1700000000,v1=deadbeef")
        |> post("/webhooks/stripe", payload)

      assert response(conn, 400) == ""
    end
  end
end
