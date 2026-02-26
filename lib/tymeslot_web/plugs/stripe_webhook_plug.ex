defmodule TymeslotWeb.Plugs.StripeWebhookPlug do
  @moduledoc """
  A plug to verify and process Stripe webhook requests.
  """

  require Logger

  @behaviour Plug

  alias Plug.Conn
  alias Tymeslot.Payments.Errors.WebhookError
  alias Tymeslot.Payments.Stripe, as: StripeProvider
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Payments.Webhooks.Security.{DevelopmentMode, SignatureVerifier}
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  # Test helper function - kept for backward compatibility with tests
  @doc false
  @spec stripe_webhook_secret() :: String.t() | nil
  def stripe_webhook_secret do
    StripeProvider.webhook_secret()
  end

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    Logger.info("StripeWebhookPlug processing webhook", path: conn.request_path)
    process_webhook(conn)
  end

  @spec process_webhook(Plug.Conn.t()) :: Plug.Conn.t()
  defp process_webhook(conn) do
    client_ip = ClientIP.get(conn)

    # Rate limiting check - before any processing
    case RateLimiter.check_webhook_rate_limit(client_ip) do
      :ok ->
        # Continue with existing logic
        with {:ok, raw_body, conn} <- read_body_once(conn),
             {:ok, event} <- verify_webhook(conn, raw_body),
             {:ok, event_id} <- require_event_id(event),
             {:ok, :reserved} <- reserve_event(event_id) do
          Logger.info("Stripe webhook validated successfully", event_type: event_type(event))
          Conn.assign(conn, :stripe_event, event)
        else
          {:ok, :already_processed} ->
            Logger.info("Skipping already processed webhook")

            conn
            |> Conn.send_resp(200, "")
            |> Conn.halt()

          {:ok, :in_progress} ->
            Logger.info("Webhook processing already in progress, retrying later")

            conn
            |> Conn.send_resp(503, "")
            |> Conn.halt()

          {:error, error} ->
            # Log detailed error information
            log_error(error, conn)
            handle_error(conn, error)
        end

      {:error, :rate_limited} ->
        Logger.warning("Webhook rate limit exceeded", client_ip: client_ip)

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(
          429,
          Jason.encode!(%{error: "rate_limited", message: "Too many requests"})
        )
        |> Conn.halt()
    end
  end

  @spec verify_webhook(Plug.Conn.t(), binary()) ::
          {:ok, map()} | {:error, WebhookError.SignatureError.t()}
  defp verify_webhook(conn, raw_body) do
    # Try development mode first if allowed
    case DevelopmentMode.verify_if_allowed(raw_body) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_allowed} ->
        # Production path: require signature
        with {:ok, signature} <- get_stripe_signature(conn) do
          SignatureVerifier.verify(raw_body, signature)
        end

      {:error, _dev_error} = error ->
        error
    end
  end

  defp event_id(event), do: Map.get(event, :id) || Map.get(event, "id")
  defp event_type(event), do: Map.get(event, :type) || Map.get(event, "type")

  defp require_event_id(event) do
    case event_id(event) do
      nil ->
        {:error,
         %WebhookError.SignatureError{
           reason: :missing_event_id,
           message: "Missing Stripe event ID"
         }}

      "" ->
        {:error,
         %WebhookError.SignatureError{
           reason: :missing_event_id,
           message: "Empty Stripe event ID"
         }}

      id ->
        {:ok, id}
    end
  end

  # Use the cached body from WebhookBodyCachePlug
  @spec read_body_once(Plug.Conn.t()) :: {:ok, binary(), Plug.Conn.t()}
  defp read_body_once(conn) do
    case conn.assigns[:raw_body] do
      nil ->
        Logger.warning(
          "No cached raw body found - WebhookBodyCachePlug may not be configured properly"
        )

        # Fallback to reading body directly (this will likely fail after Plug.Parsers)
        case Conn.read_body(conn, []) do
          {:ok, body, conn} ->
            {:ok, body, conn}

          {:error, :already_read} ->
            {:ok, "", conn}

          {:error, reason} ->
            Logger.error("Failed to read body", reason: inspect(reason))
            {:ok, "", conn}
        end

      raw_body when is_binary(raw_body) ->
        {:ok, raw_body, conn}

      _invalid_body ->
        Logger.error("Invalid raw_body in assigns", value: inspect(conn.assigns[:raw_body]))
        {:ok, "", conn}
    end
  end

  @spec get_stripe_signature(Plug.Conn.t()) ::
          {:ok, String.t()} | {:error, WebhookError.SignatureError.t()}
  defp get_stripe_signature(conn) do
    case Conn.get_req_header(conn, "stripe-signature") do
      [signature | _rest] ->
        Logger.debug("Stripe signature found")
        {:ok, signature}

      _no_signature ->
        Logger.error("Missing Stripe signature header")

        {:error,
         %WebhookError.SignatureError{
           reason: :missing_signature,
           message: "Missing Stripe signature header"
         }}
    end
  end

  # Use ETS-based cache for idempotency reservation
  @spec reserve_event(String.t()) :: {:ok, :reserved | :in_progress | :already_processed}
  defp reserve_event(event_id) do
    IdempotencyCache.reserve(event_id)
  end

  @spec handle_error(Plug.Conn.t(), WebhookError.SignatureError.t()) :: Plug.Conn.t()
  defp handle_error(conn, %WebhookError.SignatureError{} = error) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(400, Jason.encode!(%{error: error.reason, message: error.message}))
    |> Conn.halt()
  end

  @spec log_error(Tymeslot.Payments.Errors.WebhookError.SignatureError.t(), Plug.Conn.t()) :: :ok
  defp log_error(error, conn) do
    Logger.error("StripeWebhookPlug error",
      error: inspect(error),
      path: conn.request_path
    )

    :ok
  end
end
