defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted do
  @moduledoc """
  Handler for the Stripe `checkout.session.completed` Connect event.

  Marks the matching `booking_payment` as paid, transitions the meeting
  from `awaiting_payment` to `confirmed`, and triggers the same
  side-effect pipeline (calendar push + confirmation emails) that the
  free booking flow uses. The whole state mutation runs inside a single
  `Repo.transaction/1` so a crash mid-flow rolls back cleanly.

  Idempotent — replaying an event whose id matches the stored
  `last_event_id` is a no-op, as is delivering an event for a meeting
  that is no longer in `awaiting_payment`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoRoomWorker

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(%{"id" => event_id, "data" => %{"object" => object}}) do
    case lookup_payment(object) do
      nil ->
        Logger.info("checkout.session.completed: no booking_payment matched",
          checkout_session_id: object["id"],
          meeting_id: object["client_reference_id"]
        )

        :ok

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        Logger.info("checkout.session.completed: idempotent replay", event_id: event_id)
        :ok

      payment ->
        run(payment, event_id, object)
    end
  end

  def handle(_other), do: {:error, :invalid_event}

  defp lookup_payment(%{"client_reference_id" => meeting_id} = object)
       when is_binary(meeting_id) do
    BookingPaymentQueries.by_meeting_id(meeting_id) || lookup_by_session(object)
  end

  defp lookup_payment(object), do: lookup_by_session(object)

  defp lookup_by_session(%{"id" => session_id}) when is_binary(session_id) do
    BookingPaymentQueries.by_checkout_session(session_id)
  end

  defp lookup_by_session(_object), do: nil

  defp run(payment, event_id, object) do
    case Repo.transaction(fn -> run_in_transaction(payment, event_id, object) end) do
      {:ok, {:advanced, paid, meeting}} ->
        broadcast_paid(meeting.id)
        enqueue_post_payment_effects(meeting, paid)
        :ok

      {:ok, :no_op} ->
        :ok

      {:error, reason} ->
        Logger.error("checkout.session.completed handler failed",
          event_id: event_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp run_in_transaction(payment, event_id, object) do
    with {:ok, meeting} <- fetch_meeting(payment.meeting_id),
         :ok <- ensure_awaiting_payment(meeting),
         {:ok, paid} <- mark_paid(payment, event_id, object),
         {:ok, meeting} <- MeetingQueries.update_meeting(meeting, %{status: "confirmed"}) do
      {:advanced, paid, meeting}
    else
      :no_op ->
        :no_op

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp fetch_meeting(nil), do: {:error, :meeting_missing}
  defp fetch_meeting(meeting_id), do: MeetingQueries.get_meeting(meeting_id)

  defp ensure_awaiting_payment(%{status: "awaiting_payment"}), do: :ok
  defp ensure_awaiting_payment(_other), do: :no_op

  defp mark_paid(payment, event_id, object) do
    BookingPaymentQueries.update(payment, %{
      status: "paid",
      paid_at: DateTime.utc_now(:second),
      stripe_payment_intent_id: object["payment_intent"],
      last_event_id: event_id
    })
  end

  defp broadcast_paid(meeting_id) do
    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :paid)
  end

  defp enqueue_post_payment_effects(meeting, _payment) do
    if meeting.video_integration_id do
      VideoRoomWorker.schedule_video_room_creation_with_emails(meeting.id)
    else
      _result = Events.meeting_created(meeting)
      :ok
    end
  end
end
