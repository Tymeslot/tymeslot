defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired do
  @moduledoc """
  Handler for the Stripe `checkout.session.expired` Connect event.

  Stripe expires a Checkout Session after 30 minutes of inactivity (or
  earlier when explicitly cancelled). When that happens we:

    * mark the booking_payment as `failed`
    * transition the meeting from `awaiting_payment` to `expired`,
      releasing the slot for other attendees

  No emails or calendar push are triggered — there is nothing to confirm.

  Idempotent on `last_event_id`; safe to invoke again on Stripe retry.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo

  @event_type "checkout.session.expired"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}}) do
    case lookup_payment(object) do
      nil ->
        Logger.info("checkout.session.expired: no booking_payment matched",
          checkout_session_id: object["id"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        classify(run(payment, event_id))
    end
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  defp lookup_payment(%{"client_reference_id" => meeting_id} = object)
       when is_binary(meeting_id) do
    BookingPaymentQueries.by_meeting_id(meeting_id) || lookup_by_session(object)
  end

  defp lookup_payment(object), do: lookup_by_session(object)

  defp lookup_by_session(%{"id" => session_id}) when is_binary(session_id) do
    BookingPaymentQueries.by_checkout_session(session_id)
  end

  defp lookup_by_session(_object), do: nil

  defp run(payment, event_id) do
    result =
      Repo.transaction(fn ->
        with {:ok, _bp} <- mark_failed(payment, event_id),
             :ok <- maybe_expire_meeting(payment.meeting_id) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        broadcast_expired(payment.meeting_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_expired(nil), do: :ok

  defp broadcast_expired(meeting_id) do
    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :expired)
  end

  defp mark_failed(payment, event_id) do
    case BookingPaymentQueries.update(payment, %{status: "failed", last_event_id: event_id}) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, :webhook_expired)
        result

      {:error, _changeset} = err ->
        err
    end
  end

  defp maybe_expire_meeting(nil), do: :ok

  defp maybe_expire_meeting(meeting_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, %{status: "awaiting_payment"} = meeting} ->
        case MeetingQueries.update_meeting(meeting, %{status: "expired"}) do
          {:ok, _meeting} -> :ok
          {:error, _changeset} = err -> err
        end

      {:ok, _other} ->
        :ok

      {:error, :not_found} ->
        :ok
    end
  end
end
