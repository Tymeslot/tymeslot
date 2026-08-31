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

  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Payments.Config
  alias Tymeslot.Payments.PubSub
  alias Tymeslot.Payments.Webhooks.WebhookUtils

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?("customer.subscription.trial_will_end"), do: true
  def can_handle?(_event_type), do: false

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(event, subscription_object) do
    subscription_id = subscription_object["id"]
    # customer_id = subscription_object["customer"]
    trial_end = subscription_object["trial_end"]

    Logger.info("Trial ending soon",
      subscription_id: subscription_id,
      trial_end: trial_end
    )

    # Convert Unix timestamp to DateTime
    case is_integer(trial_end) && DateTime.from_unix(trial_end) do
      {:ok, trial_ends_at} ->
        # Broadcast event for SaaS to update trial end date and handle notifications
        PubSub.broadcast_payment_event(:trial_will_end, %{
          event_id: event["id"],
          stripe_subscription_id: subscription_id,
          trial_ends_at: trial_ends_at
        })

        # Find subscription in our database for local notifications
        case find_subscription(subscription_id) do
          nil ->
            Logger.warning("Trial ending - subscription not found",
              subscription_id: subscription_id
            )

            {:ok, :subscription_not_found}

          subscription ->
            # Calculate days remaining
            days_remaining = calculate_days_remaining(trial_ends_at)

            # Send reminder email
            send_trial_ending_email(subscription)

            # Broadcast event for real-time UI updates
            broadcast_trial_ending_event(subscription.user_id, days_remaining, trial_ends_at)

            {:ok, :trial_ending_notified}
        end

      _other ->
        Logger.error("Trial ending - invalid timestamp",
          subscription_id: subscription_id,
          trial_end: inspect(trial_end)
        )

        {:error, :invalid_timestamp}
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(subscription_object) when is_map(subscription_object) do
    required_fields = ["id", "customer", "trial_end"]

    if Enum.all?(required_fields, &Map.has_key?(subscription_object, &1)) do
      :ok
    else
      {:error, :missing_fields, "Missing required fields in trial_will_end object"}
    end
  end

  def validate(_event), do: {:error, :invalid_structure, "Invalid trial_will_end object"}

  # Private functions

  defp find_subscription(stripe_subscription_id) do
    repo = Config.repo()
    subscription_schema = Config.subscription_schema()

    if subscription_schema && Code.ensure_loaded?(subscription_schema) do
      repo.get_by(subscription_schema, stripe_subscription_id: stripe_subscription_id)
    else
      nil
    end
  end

  defp calculate_days_remaining(trial_ends_at) do
    diff_seconds = DateTime.diff(trial_ends_at, DateTime.utc_now(), :second)
    max(0, ceil(diff_seconds / 86_400))
  end

  defp broadcast_trial_ending_event(user_id, days_remaining, trial_ends_at) do
    PubSub.broadcast_to_user(
      user_id,
      {:trial_will_end,
       %{
         days_remaining: days_remaining,
         trial_ends_at: trial_ends_at
       }}
    )
  end

  defp send_trial_ending_email(subscription) do
    WebhookUtils.deliver_user_email(
      subscription.user_id,
      :trial_ending_reminder_template,
      :trial_ending_reminder_email,
      [subscription],
      success_msg: "Trial ending reminder sent to user #{subscription.user_id}",
      error_msg: "Failed to send trial ending reminder: ",
      standalone_msg: "Trial ending reminder template not configured (Standalone mode)"
    )
  end
end
