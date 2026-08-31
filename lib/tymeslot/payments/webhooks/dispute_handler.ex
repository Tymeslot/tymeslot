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

  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Mailer
  alias Tymeslot.Payments.{Config, PaymentQueries, PubSub}
  alias Tymeslot.Security.SecurityLogger

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

    if Enum.all?(required_fields, &Map.has_key?(dispute, &1)) do
      :ok
    else
      {:error, :missing_fields, "Missing required fields in dispute object"}
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
          PubSub.broadcast_payment_event(:dispute_created, %{
            event_id: event["id"],
            stripe_customer_id: customer_id,
            dispute: dispute
          })

          Logger.info("DISPUTE FORWARDED - Subscription dispute broadcast to subscribers",
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
          PubSub.broadcast_payment_event(:dispute_updated, %{
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
          PubSub.broadcast_payment_event(:dispute_closed, %{
            event_id: event["id"],
            stripe_dispute_id: dispute_id,
            status: status,
            dispute: dispute
          })

          {:ok, :dispute_closed}
        else
          # We still alert admin in Core for visibility
          if status == "lost" do
            alert_admin_dispute_lost(
              dispute_id,
              nil,
              dispute["amount"],
              dispute["reason"]
            )

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

  defp alert_admin_dispute_lost(dispute_id, user_id, amount, dispute_reason) do
    AdminAlerts.report(:dispute_lost,
      summary: "Dispute lost — consider manual access revocation",
      reason: {:dispute_lost, dispute_reason},
      context: %{
        dispute_id: dispute_id,
        user_id: user_id,
        amount: amount
      }
    )
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

  # Charges from subscription invoices used to carry invoice/subscription
  # references; Stripe API 2025-03-31.basil removed both from the charge.
  # When they are absent, fall back to our own records: one-off charges
  # always have a local transaction for their customer, so a customer
  # without one can only mean a subscription charge. Without a configured
  # subscription manager (standalone) there is nothing to forward to, and
  # every dispute stays on the local path.
  defp subscription_charge?(charge) do
    invoice = Map.get(charge, "invoice") || Map.get(charge, :invoice)
    subscription = Map.get(charge, "subscription") || Map.get(charge, :subscription)

    cond do
      invoice || subscription -> true
      is_nil(Config.subscription_manager()) -> false
      true -> is_nil(find_user_by_customer(get_charge_customer_id(charge)))
    end
  end

  defp find_user_by_customer(nil), do: nil

  defp find_user_by_customer(customer_id) do
    case PaymentQueries.get_latest_one_time_transaction_by_customer(customer_id) do
      {:ok, transaction} -> transaction.user_id
      {:error, :transaction_not_found} -> nil
    end
  end

  defp alert_admin_dispute_created(dispute_id, user_id, amount, reason) do
    AdminAlerts.report(:dispute_created,
      summary: "New dispute created — manual review required",
      reason: {:dispute_created, reason},
      context: %{
        dispute_id: dispute_id,
        user_id: user_id,
        amount: amount
      }
    )
  end

  defp broadcast_dispute_event(user_id, event_type, dispute_id) do
    PubSub.broadcast_to_user(user_id, {event_type, %{dispute_id: dispute_id}})
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
    email = get_admin_email()
    template = Application.get_env(:tymeslot, :dispute_alert_template)

    cond do
      is_nil(template) or not Code.ensure_loaded?(template) ->
        Logger.debug("Dispute alert template not configured (Standalone mode)")
        :ok

      email in [nil, ""] ->
        Logger.error(
          "Dispute alert template is configured but no admin alert address is set; " <>
            "set ADMIN_ALERT_EMAIL to receive dispute alerts",
          template: template_fun
        )

        :ok

      true ->
        do_deliver_dispute_email(template, template_fun, email, data)
    end
  end

  defp do_deliver_dispute_email(template, template_fun, email, data) do
    email_struct = apply(template, template_fun, [email, data])

    case Mailer.deliver(email_struct) do
      {:ok, _result} ->
        Logger.info("Dispute email sent",
          template: template_fun,
          email_masked: SecurityLogger.mask_email(email)
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to send dispute email",
          template: template_fun,
          reason: inspect(reason)
        )

        :ok
    end
  end

  # `:admin_email` was declared in no config file, so the fallback was always
  # what shipped — a hosted-service address baked into the open-source core.
  # `:admin_alert_email` is the key this codebase actually declares and
  # documents for operator alerts (`config.exs`, `runtime.exs`), and an overlay
  # that wants a different address sets that one.
  defp get_admin_email do
    Application.get_env(:tymeslot, :admin_alert_email)
  end

  defp stripe_provider do
    Config.stripe_provider()
  end
end
