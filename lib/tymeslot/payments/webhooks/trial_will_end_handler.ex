defmodule Tymeslot.Payments.Webhooks.TrialWillEndHandler do
  @moduledoc """
  Handles Stripe trial ending notification webhook events.

  This handler processes the `customer.subscription.trial_will_end` event,
  which is sent by Stripe 3 days before a trial period expires.

  Responsibilities:
  - Update subscription record with trial end date
  - Send reminder email to user
  - Broadcast event for real-time dashboard updates
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments.Behaviours.WebhookHandler
  alias Tymeslot.Payments.CustomerLookup
  alias Tymeslot.Payments.PubSub
  alias Tymeslot.Payments.Webhooks.WebhookUtils

  @impl WebhookHandler
  def handle(
        %{
          "data" => %{
            "object" => %{
              "id" => subscription_id,
              "customer" => _customer,
              "trial_end" => trial_end
            }
          }
        } = event
      ) do
    Logger.info("Trial ending soon",
      subscription_id: subscription_id,
      trial_end: trial_end
    )

    case is_integer(trial_end) && DateTime.from_unix(trial_end) do
      {:ok, trial_ends_at} ->
        # Hand off first: if the handler fails, no email has gone out yet and
        # Stripe redelivers the event.
        case PubSub.hand_off_payment_event(:trial_will_end, %{
               event_id: event["id"],
               stripe_subscription_id: subscription_id,
               trial_ends_at: trial_ends_at
             }) do
          :ok -> maybe_notify_trial_ending(event, subscription_id, trial_ends_at)
          {:error, reason} -> {:error, :retry_later, {:hand_off_failed, reason}}
        end

      _other ->
        Logger.error("Trial ending - invalid timestamp",
          subscription_id: subscription_id,
          trial_end: LogFormat.reason(trial_end)
        )

        {:error, :permanent, :invalid_timestamp}
    end
  end

  def handle(_event), do: {:error, :permanent, :missing_fields}

  # Stripe sends the event to a subscription cancelled during its trial too,
  # and the reminder says it will continue and be charged. Cancelling sets
  # `cancel_at_period_end`, or only `cancel_at` from the billing portal.
  defp maybe_notify_trial_ending(event, subscription_id, trial_ends_at) do
    if ending?(event["data"]["object"]) do
      Logger.info("Trial ending - subscription set to end, no reminder sent",
        subscription_id: subscription_id
      )

      {:ok, :trial_ending_subscription_cancelled}
    else
      notify_trial_ending(subscription_id, trial_ends_at)
    end
  end

  defp ending?(%{"cancel_at_period_end" => true}), do: true
  defp ending?(%{"cancel_at" => cancel_at}) when is_integer(cancel_at), do: true
  defp ending?(_subscription), do: false

  defp notify_trial_ending(subscription_id, trial_ends_at) do
    # Find subscription in our database for local notifications
    case CustomerLookup.get_subscription_by_subscription_id(subscription_id) do
      nil ->
        Logger.warning("Trial ending - subscription not found",
          subscription_id: subscription_id
        )

        {:ok, :subscription_not_found}

      subscription ->
        send_trial_ending_email(subscription, trial_ends_at)

        {:ok, :trial_ending_notified}
    end
  end

  # Private functions

  # The template takes the trial's end (from the event, as ISO 8601), not the
  # subscription: the job stores its arguments as JSON.
  defp send_trial_ending_email(subscription, trial_ends_at) do
    WebhookUtils.deliver_user_email(
      subscription.user_id,
      :trial_ending_reminder_template,
      :trial_ending_reminder_email,
      [DateTime.to_iso8601(trial_ends_at)],
      success_msg: "Trial ending reminder sent to user #{subscription.user_id}",
      error_msg: "Failed to send trial ending reminder: ",
      standalone_msg: "Trial ending reminder template not configured (Standalone mode)"
    )
  end
end
