defmodule Tymeslot.Payments.Webhooks.DisputeHandler do
  @moduledoc """
  Handles Stripe dispute (chargeback) webhook events.

  This handler tracks payment disputes and alerts administrators.
  Per user configuration: logs and alerts only - does NOT automatically suspend access.

  Events handled:
  - charge.dispute.created: Customer filed a dispute/chargeback
  - charge.dispute.updated: Dispute status changed
  - charge.dispute.closed: Dispute resolved (won or lost)
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.DatabaseQueries.PaymentQueries
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Mailer
  alias Tymeslot.Payments.Config

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type)
      when event_type in [
             "charge.dispute.created",
             "charge.dispute.updated",
             "charge.dispute.closed"
           ] do
    true
  end

  def can_handle?(_event_type), do: false

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(%{"type" => "charge.dispute.created"} = event, dispute) do
    handle_created(event, dispute)
  end

  def process(%{"type" => "charge.dispute.updated"} = event, dispute) do
    handle_updated(event, dispute)
  end

  def process(%{"type" => "charge.dispute.closed"} = event, dispute) do
    handle_closed(event, dispute)
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(dispute) when is_map(dispute) do
    required_fields = ["id", "charge", "amount", "status"]

    case Enum.all?(required_fields, &Map.has_key?(dispute, &1)) do
      true -> :ok
      false -> {:error, :missing_fields, "Missing required fields in dispute object"}
    end
  end

  def validate(_event), do: {:error, :invalid_structure, "Invalid dispute object"}

  # Private functions

  defp handle_created(event, dispute) do
    dispute_id = dispute["id"]
    charge_id = dispute["charge"]
    amount = dispute["amount"]
    reason = dispute["reason"]
    status = dispute["status"]

    Logger.warning("DISPUTE CREATED - Chargeback filed",
      dispute_id: dispute_id,
      charge_id: charge_id,
      amount: amount,
      reason: reason,
      status: status
    )

    case fetch_charge(charge_id) do
      {:ok, charge} ->
        customer_id = get_charge_customer_id(charge)

        if subscription_charge?(charge) do
          Tymeslot.Payments.PubSub.broadcast_payment_event(:dispute_created, %{
            event_id: event["id"],
            stripe_customer_id: customer_id,
            dispute: dispute
          })

          Logger.info("DISPUTE FORWARDED - Subscription dispute sent to SaaS",
            dispute_id: dispute_id,
            charge_id: charge_id
          )

          {:ok, :subscription_dispute_forwarded}
        else
          case find_user_by_customer(customer_id) do
            nil ->
              Logger.warning("Dispute unlinked - could not find user",
                dispute_id: dispute_id,
                charge_id: charge_id
              )

              # Alert admin about unlinked dispute
              alert_admin_dispute_created(dispute_id, nil, amount, reason)

              {:ok, :dispute_logged}

            user_id ->
              Logger.info("Dispute logged for one-time payment",
                user_id: user_id,
                dispute_id: dispute_id,
                charge_id: charge_id
              )

              # Alert admin (log and potentially other notifications)
              alert_admin_dispute_created(dispute_id, user_id, amount, reason)

              # Send email to admin
              send_dispute_created_alert(dispute)

              # Broadcast event
              broadcast_dispute_event(user_id, :dispute_created, dispute_id)

              {:ok, :dispute_created}
          end
        end

      {:error, :stripe_api_error, _message} ->
        {:error, :retry_later, "Stripe API unavailable"}
    end
  end

  defp handle_updated(event, dispute) do
    dispute_id = dispute["id"]
    status = dispute["status"]
    charge_id = dispute["charge"]

    Logger.info("Dispute status updated", dispute_id: dispute_id, status: status)

    case fetch_charge(charge_id) do
      {:ok, charge} ->
        if subscription_charge?(charge) do
          # Broadcast event for SaaS to update dispute status
          Tymeslot.Payments.PubSub.broadcast_payment_event(:dispute_updated, %{
            event_id: event["id"],
            stripe_dispute_id: dispute_id,
            status: status
          })

          {:ok, :dispute_updated}
        else
          {:ok, :dispute_updated}
        end

      {:error, :stripe_api_error, _message} ->
        {:error, :retry_later, "Stripe API unavailable"}
    end
  end

  defp handle_closed(event, dispute) do
    dispute_id = dispute["id"]
    status = dispute["status"]
    charge_id = dispute["charge"]

    Logger.info("Dispute closed",
      dispute_id: dispute_id,
      status: status
    )

    case fetch_charge(charge_id) do
      {:ok, charge} ->
        if subscription_charge?(charge) do
          # Broadcast event for SaaS to update dispute status and handle outcome
          Tymeslot.Payments.PubSub.broadcast_payment_event(:dispute_closed, %{
            event_id: event["id"],
            stripe_dispute_id: dispute_id,
            status: status,
            dispute: dispute
          })

          {:ok, :dispute_closed}
        else
          # We still alert admin in Core for visibility
          if status == "lost" do
            alert_admin_dispute_lost(dispute_id, nil)
            send_dispute_lost_alert(dispute)
          end

          if status == "won" do
            send_dispute_won_notification(dispute)
          end

          {:ok, :dispute_closed}
        end

      {:error, :stripe_api_error, _message} ->
        {:error, :retry_later, "Stripe API unavailable"}
    end
  end

  defp alert_admin_dispute_lost(dispute_id, user_id) do
    AdminAlerts.send_alert(:dispute_lost, %{
      dispute_id: dispute_id,
      user_id: user_id
    })
  end

  defp fetch_charge(charge_id) do
    case stripe_provider().get_charge(charge_id) do
      {:ok, charge} ->
        {:ok, charge}

      {:error, reason} ->
        Logger.error("Failed to fetch charge from Stripe",
          charge_id: charge_id,
          reason: inspect(reason)
        )

        {:error, :stripe_api_error, "Failed to fetch charge from Stripe API"}
    end
  end

  defp get_charge_customer_id(charge) do
    Map.get(charge, "customer") || Map.get(charge, :customer)
  end

  defp subscription_charge?(charge) do
    invoice = Map.get(charge, "invoice") || Map.get(charge, :invoice)
    subscription = Map.get(charge, "subscription") || Map.get(charge, :subscription)
    not is_nil(invoice) or not is_nil(subscription)
  end

  defp find_user_by_customer(nil), do: nil

  defp find_user_by_customer(customer_id) do
    case PaymentQueries.get_latest_one_time_transaction_by_customer(customer_id) do
      {:ok, transaction} -> transaction.user_id
      {:error, :transaction_not_found} -> nil
    end
  end

  defp alert_admin_dispute_created(dispute_id, user_id, amount, reason) do
    AdminAlerts.send_alert(:dispute_created, %{
      dispute_id: dispute_id,
      user_id: user_id,
      amount: amount,
      reason: reason
    })
  end

  defp broadcast_dispute_event(user_id, event_type, dispute_id) do
    Phoenix.PubSub.broadcast(
      Tymeslot.PubSub,
      "user:#{user_id}",
      {event_type, %{dispute_id: dispute_id}}
    )
  end

  defp send_dispute_created_alert(dispute_data) do
    deliver_dispute_email(:dispute_created_alert, dispute_data)
  end

  defp send_dispute_lost_alert(dispute_record) do
    deliver_dispute_email(:dispute_lost_alert, dispute_record)
  end

  defp send_dispute_won_notification(dispute_record) do
    deliver_dispute_email(:dispute_won_notification, dispute_record)
  end

  defp deliver_dispute_email(template_fun, data) do
    admin_email = get_admin_email()

    case admin_email do
      nil ->
        Logger.warning("No admin email configured for dispute alerts")
        :ok

      email ->
        template = Application.get_env(:tymeslot, :dispute_alert_template)

        if template && Code.ensure_loaded?(template) do
          email_struct = apply(template, template_fun, [email, data])

          case Mailer.deliver(email_struct) do
            {:ok, _result} ->
              Logger.info("Dispute email sent", template: template_fun, email: email)
              :ok

            {:error, reason} ->
              Logger.error("Failed to send dispute email",
                template: template_fun,
                reason: inspect(reason)
              )

              :ok
          end
        else
          Logger.debug("Dispute alert template not configured (Standalone mode)")
          :ok
        end
    end
  end

  defp get_admin_email do
    # Get admin email from configuration
    # Default to support@tymeslot.app if not configured
    Application.get_env(:tymeslot, :admin_email) || "support@tymeslot.app"
  end

  defp stripe_provider do
    Config.stripe_provider()
  end
end
