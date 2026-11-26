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

  A paid series' one payment releases every session of the series still
  awaiting payment (`HeldMeetings.expire_series/1`), announced once, on its
  first session's topic.

  A held group seat's payment releases its hold instead (`:expired` for a
  lapsed checkout, `:failed` for a failed payment; a hold released already
  keeps its first reason) and settles the hold's meeting
  (`SeatRelease.settle_after_hold/1`): a slot only holds took expires, an
  emptied confirmed one is cancelled. Every such payment ends `failed`, so
  none stays pending to block its host's currency change.

  Idempotent on `last_event_id`; safe to invoke again on Stripe retry.
  """

  require Logger

  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
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
        %BookingPaymentSchema{status: :pending} = locked ->
          with {:ok, _bp} <- mark_failed(locked, event_id, reason),
               {:ok, outcome} <- release(locked, reason) do
            {:ok, {:failed, outcome}}
          end

        %BookingPaymentSchema{status: :failed} = locked ->
          case release(locked, reason) do
            {:ok, %MeetingSchema{} = meeting} -> {:ok, {:failed, meeting}}
            {:ok, {:seat, %{released?: true}} = seat} -> {:ok, {:failed, seat}}
            {:ok, _unchanged} -> {:ok, {:not_pending, :failed}}
            {:error, _reason} = error -> error
          end

        %BookingPaymentSchema{status: status} ->
          {:ok, {:not_pending, status}}
      end)

    announce(result, payment, event_id)
  end

  defp announce(result, payment, event_id) do
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

      {:ok, {:failed, {:seat, released}}} ->
        SeatRelease.announce_released(released)

      {:ok, {:failed, :unchanged}} ->
        :ok

      {:error, rollback_reason} ->
        {:error, rollback_reason}
    end
  end

  # Releases what the payment held: its meeting, every session of its
  # series (locked after the payment, series row first), or its seat hold
  # (its meeting locked before the hold). Returns the meeting to announce (a
  # series' first session), `{:seat, release}` for a hold, `{:moved_on,
  # meeting_id}` when nothing was held any more, or `:unchanged` when there
  # is no meeting.
  # A seat payment whose hold is gone has nothing left to release, and
  # never its group meeting, which other seats share.
  defp release(%BookingPaymentSchema{seat_payment: true, seat_hold_id: nil}, _reason),
    do: {:ok, :unchanged}

  defp release(%BookingPaymentSchema{seat_hold_id: hold_id}, reason) when is_binary(hold_id) do
    case SeatHolds.get(hold_id) do
      %SeatHoldSchema{} = hold ->
        with {:ok, released} <-
               SeatRelease.release_hold(hold, hold_release_reason(reason)),
             do: {:ok, {:seat, released}}

      nil ->
        {:ok, :unchanged}
    end
  end

  defp release(%BookingPaymentSchema{series_id: series_id}, _reason) when is_binary(series_id) do
    case HeldMeetings.expire_series(series_id) do
      {:ok, :expired, first} -> {:ok, first}
      {:ok, :unchanged, first_id} -> {:ok, moved_on(first_id)}
      {:error, _reason} = error -> error
    end
  end

  defp release(%BookingPaymentSchema{meeting_id: meeting_id}, _reason) do
    case HeldMeetings.expire(meeting_id) do
      {:ok, :expired, meeting} -> {:ok, meeting}
      {:ok, :unchanged} -> {:ok, moved_on(meeting_id)}
      {:error, _changeset} = error -> error
    end
  end

  # Why a seat hold is released, by the reason its payment failed.
  defp hold_release_reason(:webhook_expired), do: :expired
  defp hold_release_reason(:webhook_async_payment_failed), do: :failed

  defp moved_on(nil), do: :unchanged
  defp moved_on(meeting_id), do: {:moved_on, meeting_id}

  defp mark_failed(payment, event_id, reason) do
    case BookingPaymentQueries.update(payment, %{status: :failed, last_event_id: event_id}) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, reason)
        result

      {:error, _changeset} = err ->
        err
    end
  end
end
