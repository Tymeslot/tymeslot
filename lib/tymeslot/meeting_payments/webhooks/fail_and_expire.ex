defmodule Tymeslot.MeetingPayments.Webhooks.FailAndExpire do
  @moduledoc """
  Shared handling for the two Connect events that fail a booking payment and
  release its slot without confirming anything: `checkout.session.expired` and
  `checkout.session.async_payment_failed`.

  Both mark the `booking_payment` as `failed` and transition the meeting from
  `awaiting_payment` to `expired`; neither sends an email or pushes a calendar
  event. They differ only in the Stripe event type they answer and the
  telemetry reason they stamp, so the whole flow lives here and each handler is
  a thin wrapper supplying those two values.

  Idempotent on `last_event_id`; safe to invoke again on Stripe retry.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo

  @doc """
  Runs the fail-and-expire flow for `event`, wrapped in the webhook telemetry
  span. `event_type` is the Stripe event name and `telemetry_reason` the status
  atom stamped on the payment transition.
  """
  @spec handle(map(), String.t(), atom()) :: {:ok, atom()} | {{:error, term()}, :error}
  def handle(event, event_type, telemetry_reason) do
    Telemetry.span_webhook(event_type, fn -> do_handle(event, event_type, telemetry_reason) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}}, event_type, reason) do
    case lookup_payment(object) do
      nil ->
        Logger.info("No booking_payment matched for Connect event",
          event_type: event_type,
          checkout_session_id: object["id"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        classify(run(payment, event_id, reason))
    end
  end

  defp do_handle(_other, _event_type, _reason), do: {{:error, :invalid_event}, :error}

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

  defp run(payment, event_id, reason) do
    result =
      Repo.transaction(fn ->
        with {:ok, _bp} <- mark_failed(payment, event_id, reason),
             :ok <- maybe_expire_meeting(payment.meeting_id) do
          :ok
        else
          {:error, rollback_reason} -> Repo.rollback(rollback_reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        broadcast_expired(payment.meeting_id)
        :ok

      {:error, rollback_reason} ->
        {:error, rollback_reason}
    end
  end

  defp broadcast_expired(nil), do: :ok

  defp broadcast_expired(meeting_id) do
    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :expired)
  end

  defp mark_failed(payment, event_id, reason) do
    case BookingPaymentQueries.update(payment, %{status: "failed", last_event_id: event_id}) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, reason)
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
