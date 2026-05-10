defmodule Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments do
  @moduledoc """
  Cron sweeper that reconciles `booking_payments` stuck in `pending` past a
  one-hour grace period. Acts as a safety net for missed Stripe webhooks:
  for every stale row that still has a `stripe_checkout_session_id`, the
  worker polls `Stripe.Checkout.Session` and replays the appropriate
  state transition through the existing webhook handlers so the calendar
  push, email pipeline, and meeting status update all share a single
  code path.

  Runs every 15 minutes (configured in the Oban crontab). Failures for a
  single row are logged and counted but never stop the sweep — one host
  with a broken connected account must not block reconciliation for
  everyone else.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 1,
    unique: [period: 60]

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired

  @stale_after_seconds 60 * 60

  @type sweep_result :: %{
          reconciled: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@stale_after_seconds, :second)
      |> DateTime.truncate(:second)

    payments = BookingPaymentQueries.list_stale_pending(cutoff)

    result =
      Enum.reduce(payments, %{reconciled: 0, skipped: 0, errors: 0}, fn payment, acc ->
        case reconcile_one(payment) do
          :reconciled -> Map.update!(acc, :reconciled, &(&1 + 1))
          :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
          :error -> Map.update!(acc, :errors, &(&1 + 1))
        end
      end)

    Logger.info("ReconcileAwaitingPayments sweep complete",
      reconciled: result.reconciled,
      skipped: result.skipped,
      errors: result.errors
    )

    {:ok, result}
  end

  @spec reconcile_one(BookingPaymentSchema.t()) :: :reconciled | :skipped | :error
  defp reconcile_one(%BookingPaymentSchema{stripe_checkout_session_id: session_id} = payment)
       when is_binary(session_id) do
    case StripeAdapter.retrieve_checkout_session(session_id,
           connect_account: payment.stripe_account_id
         ) do
      {:ok, session} -> dispatch(payment, session)
      {:error, reason} -> log_error(payment, reason)
    end
  end

  defp dispatch(payment, %{"payment_status" => "paid"} = session) do
    handle_or_log(payment, &CheckoutSessionCompleted.handle/1, synthetic_event(payment, session))
    :reconciled
  end

  defp dispatch(payment, %{"status" => "expired"} = session) do
    handle_or_log(payment, &CheckoutSessionExpired.handle/1, synthetic_event(payment, session))
    :reconciled
  end

  defp dispatch(_payment, _session), do: :skipped

  defp handle_or_log(payment, handler, event) do
    case handler.(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("ReconcileAwaitingPayments handler failed",
          booking_payment_id: payment.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp synthetic_event(payment, session) do
    %{
      "id" => "reconcile:#{payment.stripe_checkout_session_id}",
      "data" => %{"object" => session}
    }
  end

  defp log_error(payment, reason) do
    Logger.warning("ReconcileAwaitingPayments could not retrieve Stripe session",
      booking_payment_id: payment.id,
      stripe_checkout_session_id: payment.stripe_checkout_session_id,
      reason: inspect(reason)
    )

    :error
  end
end
