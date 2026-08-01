defmodule TymeslotWeb.Plugs.StripeWebhookPlugTest do
  @moduledoc """
  Composition tests for the Stripe webhook pipeline —
  `WebhookBodyCachePlug` (run as a `body_reader` from `Plug.Parsers`) +
  `StripeWebhookPlug` (run in the `:webhook` router pipeline) +
  `StripeWebhookController.webhook/2`.

  Three gaps are closed here:

    * **Rate-limit arm** — the plug's `{:error, :rate_limited}` branch
      returns a 429 JSON body. Previously only the `:ok` side was
      exercised, so a regression that mis-coded the 429 (e.g., 503 or
      an un-halted `send_resp`) would not fail any existing test.

    * **Raw body absent** — the fallback at
      `stripe_webhook_plug.ex:127-154`, `conn.assigns[:raw_body] == nil`,
      feeds the signature verifier an empty string. The user-observable
      outcome must be a 400 with a signature error (not a 500, not a
      silent success).

    * **End-to-end signature wiring** (Task 118) — a real POST to
      `/webhooks/stripe` with a valid HMAC must succeed without any
      manual `assign(:raw_body, payload)` in the test. This proves the
      config pair (`webhook_paths` = `["/webhooks/stripe"]` +
      `body_reader` = `WebhookBodyCachePlug.read_body`) is wired
      correctly; a regression that set `webhook_paths` to the stale
      `/api/webhook/stripe` default would surface here as a 400 (empty
      cached body → signature mismatch).

  Dropped from the plan with rationale:

    * `FetchCurrentUser: expired session → nil assigned, no error;
      malformed user_token → nil, no query crash` — covered at
      `fetch_current_user_test.exs` ("assigns nil current_user when the
      session token does not match any user") and the production code
      composes nil safely (`user_token && get_user_by_session_token/1`).

    * `RequireAuthPlug: unauthenticated request halted + redirect with
      flash` — covered at `require_auth_test.exs` (redirect,
      flash-message, halt assertions are all present).

    * `Overlay-mode plug: request to an overlay route in a Core-only
      deployment → redirect` — covered by the overlay's own plug tests
      (halt and redirect to `/auth/login` when the configured router is
      not the overlay's).

    * Boundary test at exactly 100 vs. 101 real requests — the numeric
      bound lives in `Tymeslot.Security.RateLimiter.Bookings` and is
      pinned by its own tests. Replaying 101 requests here would
      duplicate that coverage at the cost of a slow, flaky suite; the
      behaviourally interesting part is the plug's response when the
      limiter reports `:rate_limited`, which we assert directly.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Plugs.StripeWebhookPlug

  setup do
    IdempotencyCache.clear_all()
    :ok
  end

  describe "StripeWebhookPlug — rate limit arm" do
    test "returns 429 JSON and halts when the rate limiter rejects the request", %{conn: conn} do
      # Exhaust the real Hammer ETS bucket (100 requests per 10 minutes per IP).
      # Hit 101 times to avoid boundary races in the sliding window backend.
      client_ip = "127.0.0.1"

      for _i <- 1..101 do
        RateLimit.hit("webhook:#{client_ip}", 600_000, 100)
      end

      # Verify the bucket is actually exhausted before making the request
      assert {:error, :rate_limited} = RateLimiter.check_webhook_rate_limit(client_ip)

      payload = ~s({"type":"checkout.session.completed","id":"evt_rate_limited"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post("/webhooks/stripe", payload)

      assert conn.status == 429
      assert conn.halted

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "rate_limited",
               "message" => "Too many requests"
             }
    end
  end

  describe "StripeWebhookPlug — raw body absent + empty body yields 400" do
    test "responds with 400 when :raw_body is absent and Conn.read_body returns an empty body",
         %{conn: conn} do
      # When no raw_body assign is present, the plug falls back to
      # Conn.read_body. The Plug test adapter returns {:ok, "", conn},
      # so the signature verifier receives an empty string and must
      # reject it with a 400.
      with_config(:tymeslot,
        skip_webhook_verification: false,
        stripe_provider: Tymeslot.Payments.Stripe,
        stripe_webhook_secret: "whsec_test"
      )

      payload = ~s({"type":"checkout.session.completed","id":"evt_preconsumed"})
      signature = PaymentTestHelpers.generate_stripe_signature(payload, "whsec_test")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> Map.put(:body_params, %{})

      {:ok, _body, conn} = Conn.read_body(conn)

      conn = StripeWebhookPlug.call(conn, [])

      assert conn.status == 400
      assert conn.halted
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_signature"
    end
  end

  describe "end-to-end through /webhooks/stripe — signature verification" do
    test "accepts a POST with a valid HMAC signature when the body is cached by WebhookBodyCachePlug",
         %{conn: conn} do
      # Deliberately does not `assign(:raw_body, payload)`. This proves
      # the full endpoint chain (Plug.Parsers → body_reader →
      # StripeWebhookPlug) caches and verifies without any manual wiring.
      # A regression reverting `config :tymeslot, :webhook_paths` to the
      # stale `/api/webhook/stripe` would surface here as a 400.
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

    test "rejects a POST with an invalid HMAC signature without pre-assigning :raw_body",
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

      assert json_response(conn, 400)
    end
  end
end
