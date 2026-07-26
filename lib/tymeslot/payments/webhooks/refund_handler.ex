defmodule Tymeslot.Payments.Webhooks.RefundHandler do
  @moduledoc """
  Handles Stripe refund webhook events.

  CRITICAL: This handler protects revenue by revoking Pro access when refunds are issued.
  Without this handler, users could receive refunds while keeping Pro access indefinitely.

  ## Partial Refund Handling

  The handler now supports proper partial refund handling:
  - Calculates total refunded amount across all refunds for a charge
  - Only revokes access when total refunds exceed a configurable threshold
  - Default threshold: 90% of the original charge amount
  - Prevents unfair subscription cancellations for small partial refunds

  ## Configuration

      config :tymeslot, :refund_revocation_threshold_percent, 90

  Events handled:
  - charge.refunded: Refund has been issued
  - charge.refund.updated: Refund status changed
  """

  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Payments.CustomerLookup
  alias Tymeslot.Payments.Webhooks.WebhookUtils

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type) when event_type in ["charge.refunded", "charge.refund.updated"] do
    true
  end

  def can_handle?(_event_type), do: false

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(%{"type" => "charge.refunded"} = event, charge) do
    handle_refunded(event, charge)
  end

  def process(%{"type" => "charge.refund.updated"} = event, refund) do
    handle_refund_updated(event, refund)
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(refund_object) when is_map(refund_object) do
    required_fields = ["id"]

    if Enum.all?(required_fields, &Map.has_key?(refund_object, &1)) do
      :ok
    else
      {:error, :missing_fields, "Missing required fields in refund object"}
    end
  end

  def validate(_event), do: {:error, :invalid_structure, "Invalid refund object"}

  # Private functions

  defp handle_refunded(event, charge) do
    charge_id = charge["id"]
    charge_amount = get_charge_amount(charge)
    total_refunded = calculate_total_refunded(charge)
    customer_id = charge["customer"]

    Logger.info("Refund received",
      charge_id: charge_id,
      customer_id: customer_id,
      total_refunded: total_refunded,
      charge_amount: charge_amount,
      refund_percentage: calculate_refund_percentage(total_refunded, charge_amount),
      stripe_event_id: event["id"]
    )

    # Broadcast event for SaaS to handle subscription revocation
    Tymeslot.Payments.PubSub.broadcast_payment_event(:charge_refunded, %{
      event_id: event["id"],
      charge_id: charge_id,
      customer_id: customer_id,
      total_refunded: total_refunded,
      charge_amount: charge_amount,
      refund_percentage: calculate_refund_percentage(total_refunded, charge_amount)
    })

    # Find the subscription by Stripe customer ID for local notifications
    case CustomerLookup.get_subscription_by_customer_id(customer_id) do
      nil ->
        Logger.warning("Refund unlinked - no subscription found",
          charge_id: charge_id,
          customer_id: customer_id
        )

        # Alert admin about unlinked refund
        AdminAlerts.report(:unlinked_refund,
          summary: "Unlinked refund received — no matching subscription",
          reason: {:no_subscription_for_customer, customer_id},
          context: %{
            charge_id: charge_id,
            customer_id: customer_id,
            total_refunded: total_refunded,
            charge_amount: charge_amount
          }
        )

        {:ok, :refund_logged}

      subscription ->
        # Check if refund exceeds threshold before revoking access
        should_revoke = should_revoke_access?(total_refunded, charge_amount)

        result =
          if should_revoke do
            ensure_revoked_access(
              subscription,
              charge_id,
              customer_id,
              total_refunded,
              charge_amount
            )
          else
            Logger.info("Refund below threshold - not revoking access",
              user_id: subscription.user_id,
              charge_id: charge_id,
              total_refunded: total_refunded,
              charge_amount: charge_amount,
              refund_percentage: calculate_refund_percentage(total_refunded, charge_amount),
              threshold: refund_revocation_threshold_percent()
            )

            :ok
          end

        case result do
          :ok ->
            # Alert admin about processed refund
            AdminAlerts.report(:refund_processed,
              summary: "Refund processed for subscription",
              context: %{
                user_id: subscription.user_id,
                charge_id: charge_id,
                total_refunded: total_refunded,
                charge_amount: charge_amount,
                access_revoked: should_revoke
              }
            )

            # Send email notification to user
            send_refund_email(subscription, total_refunded, should_revoke, charge)

            # Broadcast event for real-time UI updates
            broadcast_refund_event(subscription.user_id, event["id"], should_revoke)

            {:ok, :refund_processed}

          error ->
            error
        end
    end
  end

  defp handle_refund_updated(_event, refund) do
    refund_id = refund["id"]
    status = refund["status"]

    Logger.info("Refund status updated", refund_id: refund_id, status: status)

    # Track refund status changes (succeeded, failed, pending)
    # This is mainly for logging/auditing purposes
    {:ok, :refund_status_updated}
  end

  # Calculates the total amount refunded across all refunds for a charge.
  # Handles both Stripe's expanded refunds list and the amount_refunded summary field.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec calculate_total_refunded(map()) :: non_neg_integer()
  def calculate_total_refunded(charge) do
    # First try to get from amount_refunded (most reliable)
    case Map.get(charge, "amount_refunded") || Map.get(charge, :amount_refunded) do
      amount when is_integer(amount) and amount > 0 ->
        amount

      _amount_other ->
        # Fall back to summing individual refunds
        refunds = get_in(charge, ["refunds", "data"]) || get_in(charge, [:refunds, :data]) || []

        refunds
        |> Enum.map(fn refund ->
          refund["amount"] || refund[:amount] || 0
        end)
        |> Enum.sum()
    end
  end

  # Gets the original charge amount.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec get_charge_amount(map()) :: non_neg_integer()
  def get_charge_amount(charge) do
    Map.get(charge, "amount") || Map.get(charge, :amount) || 0
  end

  # Calculates the refund percentage.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec calculate_refund_percentage(non_neg_integer(), non_neg_integer()) :: float()
  def calculate_refund_percentage(_refunded, 0), do: 0.0

  def calculate_refund_percentage(refunded, charge_amount) do
    Float.round(refunded / charge_amount * 100.0, 2)
  end

  # Determines if access should be revoked based on refund threshold.
  # Access is revoked if total refunded amount exceeds the configured threshold
  # percentage of the original charge amount.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec should_revoke_access?(non_neg_integer(), non_neg_integer()) :: boolean()
  def should_revoke_access?(_refunded, 0), do: false

  def should_revoke_access?(refunded, charge_amount) do
    threshold_percent = refund_revocation_threshold_percent()
    refund_percent = calculate_refund_percentage(refunded, charge_amount)

    refund_percent >= threshold_percent
  end

  # Gets the refund revocation threshold percentage from config.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec refund_revocation_threshold_percent() :: float()
  def refund_revocation_threshold_percent do
    Application.get_env(:tymeslot, :refund_revocation_threshold_percent, 90.0)
  end

  # Extracts the currency from a charge object, supporting both string and atom keys.
  # Defaults to "eur" when the field is absent.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec extract_charge_currency(map()) :: String.t()
  def extract_charge_currency(charge) do
    Map.get(charge, "currency") || Map.get(charge, :currency) || "eur"
  end

  defp broadcast_refund_event(user_id, event_id, access_revoked) do
    Phoenix.PubSub.broadcast(
      Tymeslot.PubSub,
      "user:#{user_id}",
      {:refund_processed, %{event_id: event_id, access_revoked: access_revoked}}
    )
  end

  defp send_refund_email(subscription, refund_amount_cents, _revoked, charge) do
    currency = extract_charge_currency(charge)

    WebhookUtils.deliver_user_email(
      subscription.user_id,
      :refund_processed_template,
      :refund_processed_email,
      [refund_amount_cents, currency],
      success_msg: "Refund notification sent to user #{subscription.user_id}",
      error_msg: "Failed to send refund notification: ",
      standalone_msg: "Refund processed template not configured (Standalone mode)"
    )
  end

  defp revoke_subscription_access(stripe_customer_id) do
    manager = subscription_manager()

    if manager && Code.ensure_loaded?(manager) do
      manager.update_subscription_status(stripe_customer_id, "canceled", DateTime.utc_now())
    else
      {:error, :subscription_manager_unavailable,
       "Subscription manager not configured - cannot revoke access"}
    end
  end

  defp subscription_manager do
    Application.get_env(:tymeslot, :subscription_manager)
  end

  defp ensure_revoked_access(subscription, charge_id, customer_id, total_refunded, charge_amount) do
    case revoke_subscription_access(customer_id) do
      {:ok, _result} ->
        Logger.info("Refund processed - access revoked",
          user_id: subscription.user_id,
          charge_id: charge_id,
          customer_id: customer_id,
          total_refunded: total_refunded,
          charge_amount: charge_amount,
          refund_percentage: calculate_refund_percentage(total_refunded, charge_amount)
        )

        :ok

      {:error, :subscription_manager_unavailable, _message} ->
        Logger.info("REFUND SKIPPED - Subscription manager not configured",
          charge_id: charge_id,
          customer_id: customer_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Refund error - failed to revoke access",
          user_id: subscription.user_id,
          charge_id: charge_id,
          error: inspect(reason)
        )

        {:error, :retry_later, "Subscription revocation failed"}
    end
  end
end
