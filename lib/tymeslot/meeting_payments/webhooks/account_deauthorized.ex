defmodule Tymeslot.MeetingPayments.Webhooks.AccountDeauthorized do
  @moduledoc """
  Handler for the Stripe `account.application.deauthorized` Connect event,
  sent when a host removes Tymeslot from their Stripe account.

  The event's `data.object` is the platform's *application*, so the
  connected account is read from the envelope's top-level `account`, and the
  ordering timestamp from the envelope's `created`.

  Events of the other mode never get here: the Connect ingress ignores them
  before dispatch.

  Safe to replay: once the row is retired a second delivery finds no live
  account and does nothing.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  alias Tymeslot.MeetingPayments.ConnectAccountRetirement
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @event_type "account.application.deauthorized"

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"account" => account_id, "created" => created})
       when is_binary(account_id) and is_integer(created) do
    case ConnectAccountRetirement.handle_deauthorized(account_id, DateTime.from_unix!(created)) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {{:error, :retry_later, reason}, :error}
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}
end
