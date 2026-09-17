defmodule TymeslotWeb.OutlookCalendarWebhookController do
  @moduledoc """
  Handles incoming Microsoft Graph change notifications for Outlook Calendar.

  Microsoft Graph delivers notifications in two forms:

    1. Validation challenge — a GET or POST with `?validationToken=...`. We must
       respond with the token as plain text within 10 seconds to confirm ownership
       of the endpoint before Graph will activate the subscription.

    2. Change notifications — a POST with a JSON body containing one or more
       notification objects. Each notification identifies a subscription and
       carries a `clientState` value. The controller hands the list to
       `Tymeslot.Integrations.Calendar.Webhooks`, which verifies each one
       against the stored secret and enqueues the sync.

  All well-formed change notification payloads receive HTTP 202; validation
  challenges receive HTTP 200 with the token echoed back. Invalid or unknown
  notifications are silently skipped.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Tymeslot.Integrations.Calendar.Webhooks, as: CalendarWebhooks
  alias Tymeslot.Security.RateLimiter

  @doc """
  Receives a Microsoft Graph change notification or validation challenge.
  """
  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, %{"validationToken" => token})
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= 256 do
    client_ip = to_string(:inet_parse.ntoa(conn.remote_ip))

    case RateLimiter.check_webhook_rate_limit(client_ip) do
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
    case get_in(conn.body_params, ["value"]) do
      nil ->
        Logger.warning("Outlook webhook received request with no notification value")

      notifications when is_list(notifications) ->
        CalendarWebhooks.handle_outlook_notifications(notifications)
    end

    conn |> send_resp(202, "") |> halt()
  end
end
