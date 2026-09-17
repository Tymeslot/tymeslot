defmodule TymeslotWeb.GoogleCalendarWebhookController do
  @moduledoc """
  Handles incoming Google Calendar push notification webhooks.

  Google delivers a POST to /webhooks/google-calendar whenever an event changes
  in a watched calendar. The request carries two identifying headers:

    - X-Goog-Channel-ID: matches the channel ID we registered
    - X-Goog-Channel-Token: the secret we provided during registration

  The controller applies the per-client rate limit and hands both header values
  to `Tymeslot.Integrations.Calendar.Webhooks`, which verifies the token and
  enqueues the sync. All responses are HTTP 200 to prevent Google from
  retrying; invalid or unknown requests are silently acknowledged.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Integrations.Calendar.Webhooks, as: CalendarWebhooks
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Receives a Google Calendar push notification.
  """
  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, _params) do
    with :ok <- RateLimiter.check_webhook_rate_limit(ClientIP.get(conn)) do
      CalendarWebhooks.handle_google_notification(
        extract_header(conn, "x-goog-channel-id"),
        extract_header(conn, "x-goog-channel-token")
      )
    end

    conn |> send_resp(200, "") |> halt()
  end

  defp extract_header(conn, header_name) do
    case get_req_header(conn, header_name) do
      [value | _rest] -> value
      [] -> ""
    end
  end
end
