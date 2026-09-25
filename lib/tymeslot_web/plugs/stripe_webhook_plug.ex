defmodule TymeslotWeb.Plugs.StripeWebhookPlug do
  @moduledoc """
  Rate-limits Stripe webhook deliveries by client IP, ahead of both the
  platform (`/webhooks/stripe`) and Connect (`/webhooks/stripe/connect`)
  endpoints, via the router's `:webhook` pipeline.

  Verification, deduplication and dispatch happen in the domain, called from
  `TymeslotWeb.StripeWebhookController`; this plug only turns away a sender
  that exceeds the limit before any of that work is done. Stripe retries a
  429, so a throttled genuine delivery is delayed rather than lost.
  """

  @behaviour Plug

  require Logger

  alias Plug.Conn
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(conn, _opts) do
    client_ip = ClientIP.get(conn)

    case RateLimiter.check_stripe_webhook_rate_limit(client_ip) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        Logger.warning("Stripe webhook rate limit exceeded",
          client_ip: client_ip,
          path: conn.request_path
        )

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(
          429,
          Jason.encode!(%{error: "rate_limited", message: "Too many requests"})
        )
        |> Conn.halt()
    end
  end
end
