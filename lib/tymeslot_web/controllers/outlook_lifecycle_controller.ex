defmodule TymeslotWeb.OutlookLifecycleController do
  @moduledoc """
  Handles Microsoft Graph lifecycle notifications for Outlook Calendar subscriptions.

  Graph delivers lifecycle events when a subscription requires attention:

    - `reauthorizationRequired`: the subscription's OAuth tokens need to be
      refreshed and the subscription re-authorised.

    - `subscriptionRemoved`: Graph has removed the subscription (e.g. due to
      token expiry or inactivity), so it has to be re-registered for change
      notifications to resume.

  The controller answers the validation handshake, applies the per-client rate
  limit, and hands the events to `Tymeslot.Integrations.Calendar.Webhooks`,
  which verifies each one and enqueues the token refresh and re-registration.

  All well-formed payloads return HTTP 202 regardless of the outcome, so Graph
  does not retry indefinitely.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Integrations.Calendar.Webhooks, as: CalendarWebhooks
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Receives a Microsoft Graph lifecycle notification or validation challenge.
  """
  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, %{"validationToken" => token})
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= 256 do
    # Graph validates the lifecycleNotificationUrl with the same synchronous
    # handshake it uses for the notificationUrl: echo the token as plain text
    # with 200, or the whole subscription is rejected.
    case RateLimiter.check_webhook_rate_limit(ClientIP.get(conn)) do
      :ok ->
        if String.printable?(token) do
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, token)
          |> halt()
        else
          conn |> send_resp(400, "") |> halt()
        end

      {:error, :rate_limited} ->
        conn |> send_resp(429, "") |> halt()
    end
  end

  def webhook(conn, _params) do
    case RateLimiter.check_webhook_rate_limit(ClientIP.get(conn)) do
      :ok ->
        CalendarWebhooks.handle_outlook_lifecycle_notifications(
          get_in(conn.body_params, ["value"]) || []
        )

        conn |> send_resp(202, "") |> halt()

      {:error, :rate_limited} ->
        conn |> send_resp(429, "") |> halt()
    end
  end
end
