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

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments.Behaviours.WebhookHandler
  alias Tymeslot.Payments.{Config, PaymentQueries, PubSub}
  alias Tymeslot.Workers.SendConfiguredEmail

  @impl WebhookHandler
  def handle(
        %{
          "type" => type,
          "data" => %{
            "object" =>
              %{"id" => _id, "charge" => _charge, "amount" => _amount, "status" => _status} =
                dispute
          }
        } = event
      ) do
    case type do
      "charge.dispute.created" -> handle_created(event, dispute)
      "charge.dispute.updated" -> handle_updated(event, dispute)
      "charge.dispute.closed" -> handle_closed(event, dispute)
    end
  end

  def handle(_event), do: {:error, :permanent, :missing_fields}

  # Private functions

  # A subscription dispute is the payment-event handler's to record; if the
  # hand-off fails, Stripe redelivers the event.
  defp hand_off_dispute(event_type, data, outcome) do
    case PubSub.hand_off_payment_event(event_type, data) do
      :ok ->
        Logger.info("Subscription dispute handed off", event: event_type)
        {:ok, outcome}

      {:error, reason} ->
        {:error, :retry_later, {:hand_off_failed, reason}}
    end
  end

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
          hand_off_dispute(
            :dispute_created,
            %{
              event_id: event["id"],
              event_created: event["created"],
              stripe_customer_id: customer_id,
              dispute: dispute
            },
            :subscription_dispute_forwarded
          )
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
              send_dispute_created_alert(alert_data(dispute, user_id))

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
          hand_off_dispute(
            :dispute_updated,
            %{
              event_id: event["id"],
              event_created: event["created"],
              stripe_dispute_id: dispute_id,
              status: status
            },
            :dispute_updated
          )
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
          hand_off_dispute(
            :dispute_closed,
            %{
              event_id: event["id"],
              event_created: event["created"],
              stripe_dispute_id: dispute_id,
              status: status,
              dispute: dispute
            },
            :dispute_closed
          )
        else
          # A one-time charge resolves to its user as on creation: by the
          # charge's customer, through their local transaction.
          user_id = find_user_by_customer(get_charge_customer_id(charge))

          # We still alert admin in Core for visibility
          if status == "lost" do
            alert_admin_dispute_lost(
              dispute_id,
              user_id,
              dispute["amount"],
              dispute["reason"]
            )

            send_dispute_lost_alert(alert_data(dispute, user_id))
          end

          if status == "won" do
            send_dispute_won_notification(alert_data(dispute, user_id))
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
          reason: LogFormat.reason(reason)
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

  # The alert job stores its arguments as JSON, so it carries only what the
  # alert shows, never the dispute itself (its evidence holds the customer's
  # name and addresses).
  defp alert_data(dispute, user_id) do
    %{
      "stripe_dispute_id" => dispute["id"],
      "user_id" => user_id,
      "amount" => dispute["amount"],
      "currency" => dispute["currency"],
      "reason" => dispute["reason"],
      "evidence_due_by" => evidence_due_by(dispute)
    }
  end

  defp evidence_due_by(%{"evidence_details" => %{"due_by" => due_by}}) when is_integer(due_by) do
    case DateTime.from_unix(due_by) do
      {:ok, datetime} -> datetime |> DateTime.to_date() |> Date.to_iso8601()
      {:error, _reason} -> nil
    end
  end

  defp evidence_due_by(_dispute), do: nil

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
        do_deliver_dispute_email(template_fun, email, data)
    end
  end

  # From a job, so a mail outage delays the alert rather than losing it.
  defp do_deliver_dispute_email(template_fun, email, data) do
    case SendConfiguredEmail.enqueue(:dispute_alert_template, template_fun, {:address, email}, [
           data
         ]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue dispute email",
          template: template_fun,
          reason: LogFormat.reason(reason)
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
