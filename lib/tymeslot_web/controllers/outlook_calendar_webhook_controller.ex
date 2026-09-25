defmodule TymeslotWeb.OutlookCalendarWebhookController do
  @moduledoc """
  Receives Microsoft Graph webhooks for Outlook Calendar subscriptions.

  Each subscription carries two URLs, one per action here:

    * `notification/2` (`POST /webhooks/outlook-calendar`) receives change
      notifications: a JSON body whose `value` list names the subscription,
      its `clientState` and the changed event.

    * `lifecycle/2` (`POST /webhooks/outlook-lifecycle`) receives lifecycle
      events: `reauthorizationRequired` when the subscription's grant needs
      refreshing, and `subscriptionRemoved` when Graph has dropped it and it
      has to be registered again.

  Graph validates both URLs with the same synchronous handshake, a POST
  carrying `?validationToken=...`: the token has to come back verbatim as
  plain text with 200 within seconds, or the whole subscription is rejected.
  A token carrying non-printable bytes is refused with 400 rather than echoed.

  Every other payload is handed to `Tymeslot.Integrations.Calendar.Webhooks`,
  which verifies each entry against the stored secret and enqueues the work,
  and is acknowledged with 202 whatever shape it arrives in, so Graph does
  not retry. Invalid or unknown entries are skipped silently.

  Both endpoints share the calendar push bucket per source address, sized so
  that provider traffic never reaches it (see
  `Tymeslot.Security.RateLimiter.Calendar.check_push_endpoint/1`). A source
  that floods them gets 429, which Graph retries.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Integrations.Calendar.Webhooks, as: CalendarWebhooks
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Receives a Microsoft Graph change notification or validation challenge.
  """
  @spec notification(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def notification(conn, params),
    do: handle(conn, params, &CalendarWebhooks.handle_outlook_notifications/1)

  @doc """
  Receives a Microsoft Graph lifecycle notification or validation challenge.
  """
  @spec lifecycle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lifecycle(conn, params),
    do: handle(conn, params, &CalendarWebhooks.handle_outlook_lifecycle_notifications/1)

  defp handle(conn, params, handle_notifications) do
    case RateLimiter.check_calendar_push_rate_limit(ClientIP.get(conn)) do
      :ok -> respond(conn, params, handle_notifications)
      {:error, :rate_limited} -> conn |> send_resp(429, "") |> halt()
    end
  end

  defp respond(conn, %{"validationToken" => token}, _handle_notifications)
       when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= 256 do
    if String.printable?(token) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, token)
      |> halt()
    else
      conn |> send_resp(400, "") |> halt()
    end
  end

  defp respond(conn, _params, handle_notifications) do
    conn.body_params
    |> get_in(["value"])
    |> handle_notifications.()

    conn |> send_resp(202, "") |> halt()
  end
end
