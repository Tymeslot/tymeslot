defmodule Tymeslot.MeetingPayments.Webhooks.AccountDeauthorized do
  @moduledoc """
  Handler for the Stripe `account.application.deauthorized` Connect event,
  sent when a host removes Tymeslot from their Stripe account.

  The event's `data.object` is the platform's *application*, so the
  connected account is read from the envelope's top-level `account`, and the
  ordering timestamp from the envelope's `created`.

  An event whose `livemode` differs from the deployment's mode (read from the
  platform key) is acknowledged and ignored.

  Safe to replay: once the row is retired a second delivery finds no live
  account and does nothing.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @event_type "account.application.deauthorized"

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"account" => account_id, "created" => created} = event)
       when is_binary(account_id) and is_integer(created) do
    if other_mode?(event) do
      {:ok, :ok}
    else
      case ConnectAccounts.handle_deauthorized(account_id, DateTime.from_unix!(created)) do
        :ok -> {:ok, :ok}
        {:error, reason} -> {{:error, :retry_later, reason}, :error}
      end
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}

  # Stripe delivers live and test events to the same production endpoint, and
  # a test-mode disconnect must not retire a live connection. An event
  # without a boolean `livemode` is handled as any other.
  defp other_mode?(%{"livemode" => livemode}) when is_boolean(livemode),
    do: livemode != live_deployment?()

  defp other_mode?(_event), do: false

  defp live_deployment? do
    case Application.get_env(:stripity_stripe, :api_key) do
      key when is_binary(key) -> String.contains?(key, "_live_")
      _unset -> false
    end
  end
end
