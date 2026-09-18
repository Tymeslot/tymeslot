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

  Every change notification payload receives HTTP 202, whatever shape it
  arrives in; validation challenges receive HTTP 200 with the token echoed
  back. Invalid or unknown notifications are silently skipped. A source
  address that floods the endpoint gets 429.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Integrations.Calendar.Webhooks, as: CalendarWebhooks
  alias TymeslotWeb.Helpers.GraphWebhook

  @doc """
  Receives a Microsoft Graph change notification or validation challenge.
  """
  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, %{"validationToken" => token})
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= 256 do
    GraphWebhook.answer_validation_challenge(conn, token)
  end

  def webhook(conn, _params) do
    GraphWebhook.with_rate_limit(conn, fn ->
      conn.body_params
      |> get_in(["value"])
      |> CalendarWebhooks.handle_outlook_notifications()

      conn |> send_resp(202, "") |> halt()
    end)
  end
end
