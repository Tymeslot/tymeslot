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
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @doc """
  Runs the fail-and-expire flow for `event`, wrapped in the webhook telemetry
  span. `event_type` is the Stripe event name and `telemetry_reason` the status
  atom stamped on the payment transition.
  """
  @spec handle(map(), String.t(), atom()) :: WebhookHandler.result()
  def handle(event, event_type, telemetry_reason) do
    Telemetry.span_webhook(event_type, fn -> do_handle(event, event_type, telemetry_reason) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event, event_type, reason) do
    case PaymentLookup.find_for_session(event) do
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

  defp do_handle(_other, _event_type, _reason), do: {{:error, :permanent, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, reason}), do: {{:error, :retry_later, reason}, :error}

  # Decided from the locked rows (`LockedPayment`, then the meeting), so a
  # completion committed since the row was resolved is seen rather than
  # raced. Only a payment still `pending` can fail: one that has since been
  # paid, disputed or refunded keeps its status and its meeting.
  #
  # A payment failed already can still have its meeting awaiting payment:
  # a Stripe disconnect fails its pending payments and expires their
  # meetings in separate writes, and one whose meeting write failed leaves
  # the slot held. That meeting is expired here, with the usual side
  # effects; a failed payment whose meeting has moved on is left alone.
  defp run(payment, event_id, reason) do
    result =
      LockedPayment.run(payment, event_id, fn
        %BookingPaymentSchema{status: "pending"} = locked ->
          with {:ok, _bp} <- mark_failed(locked, event_id, reason),
               {:ok, outcome} <- expire_meeting(locked.meeting_id) do
            {:ok, {:failed, failed_outcome(outcome, locked.meeting_id)}}
          end

        %BookingPaymentSchema{status: "failed"} = locked ->
          case expire_meeting(locked.meeting_id) do
            {:ok, %MeetingSchema{} = meeting} -> {:ok, {:failed, meeting}}
            {:ok, :unchanged} -> {:ok, {:not_pending, "failed"}}
            {:error, _reason} = error -> error
          end

        %BookingPaymentSchema{status: status} ->
          {:ok, {:not_pending, status}}
      end)

    case result do
      {:ok, :idempotent_replay} ->
        :ok

      {:ok, {:not_pending, status}} ->
        Logger.info("Connect event ignored: booking payment is no longer pending",
          payment_id: payment.id,
          event_id: event_id,
          status: status
        )

        :ok

      {:ok, {:failed, %MeetingSchema{} = meeting}} ->
        # An `awaiting_payment` booking holds its slot on the booking page as
        # well as at the submit, so expiring it has to release the cached
        # offer, exactly as confirming the payment does.
        HeldMeetings.announce_expired(meeting)

      # The payment failed but its meeting had moved on already (an
      # organiser cancelling it, say, which says nothing on the payment
      # topic), so no slot is released; an attendee still waiting on the
      # payment is told all the same.
      {:ok, {:failed, {:moved_on, meeting_id}}} ->
        HeldMeetings.broadcast(meeting_id, :expired)
        :ok

      {:ok, {:failed, :unchanged}} ->
        :ok

      {:error, rollback_reason} ->
        {:error, rollback_reason}
    end
  end

  defp failed_outcome(%MeetingSchema{} = meeting, _meeting_id), do: meeting
  defp failed_outcome(:unchanged, nil), do: :unchanged
  defp failed_outcome(:unchanged, meeting_id), do: {:moved_on, meeting_id}

  defp mark_failed(payment, event_id, reason) do
    case BookingPaymentQueries.update(payment, %{status: "failed", last_event_id: event_id}) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, reason)
        result

      {:error, _changeset} = err ->
        err
    end
  end

  defp expire_meeting(meeting_id) do
    case HeldMeetings.expire(meeting_id) do
      {:ok, :expired, meeting} -> {:ok, meeting}
      {:ok, :unchanged} -> {:ok, :unchanged}
      {:error, _changeset} = error -> error
    end
  end
end
