defmodule Tymeslot.MeetingPayments.SeatPaymentQueries do
  @moduledoc """
  Queries for the payments of group seats (`booking_payments` rows with
  `seat_payment` set): found by the seat hold they were opened for or the
  participant they paid for, locked, linked to a seat once paid, and moved
  with a seat. The rest of the table's queries are in
  `Tymeslot.MeetingPayments.BookingPaymentQueries`.
  """

  import Ecto.Query

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo

  @doc """
  The seat payment that paid for the participant `participant_id`, or `nil`
  for a free seat or an id that names nobody.
  """
  @spec by_participant_id(term()) :: BookingPaymentSchema.t() | nil
  def by_participant_id(participant_id) do
    case cast_id(participant_id) do
      {:ok, uuid} ->
        # One at most: `booking_payments_participant_id_index` is unique over
        # seat payments.
        BookingPaymentSchema
        |> where([b], b.participant_id == ^uuid and b.seat_payment)
        |> Repo.one()

      {:error, :not_found} ->
        nil
    end
  end

  @doc "The payment opened for the seat hold `hold_id`, or `nil`. A malformed id returns `nil`."
  @spec by_seat_hold_id(term()) :: BookingPaymentSchema.t() | nil
  def by_seat_hold_id(hold_id) do
    case cast_id(hold_id) do
      {:ok, uuid} -> Repo.get_by(BookingPaymentSchema, seat_hold_id: uuid)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  As `by_seat_hold_id/1`, holding the row `FOR UPDATE` for the rest of the
  current transaction. Must be called inside a `Repo.transaction/1`.
  """
  @spec lock_by_seat_hold_id(term()) :: BookingPaymentSchema.t() | nil
  def lock_by_seat_hold_id(hold_id) do
    case cast_id(hold_id) do
      {:ok, uuid} ->
        BookingPaymentSchema
        |> where([b], b.seat_hold_id == ^uuid)
        |> lock("FOR UPDATE")
        |> Repo.one()

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  The seat payments of the seats still live on the group meeting
  `meeting_id`, oldest first: each linked to a participant who has not
  cancelled. A payment whose hold never became a seat (no participant: its
  hold was refused or released before converting) and the payment of a
  participant who has left are not returned.
  """
  @spec list_for_live_seats(Ecto.UUID.t()) :: [BookingPaymentSchema.t()]
  def list_for_live_seats(meeting_id) do
    BookingPaymentSchema
    |> join(:inner, [b], p in assoc(b, :participant))
    |> where([b, p], b.meeting_id == ^meeting_id and b.seat_payment and is_nil(p.cancelled_at))
    |> order_by([b], asc: b.inserted_at, asc: b.id)
    |> Repo.all()
  end

  @doc """
  Points the seat payment of the participant `old_participant_id` at
  `new_participant` on `new_meeting`, in one update, returning how many
  rows it moved (0 for a free seat).

  The update locks the payment row, and its caller already holds the
  meeting locks of the move: meetings first, payment after, the reverse of
  the order a webhook takes (`Tymeslot.MeetingPayments.Webhooks.LockedPayment`: payment, then
  meeting). That is safe only because no webhook for a converted seat's
  payment (the only kind this moves) takes a meeting lock: a dispute or a
  refund event locks the payment alone. A future webhook handler that
  locks a meeting under a converted seat's payment must keep it so, or
  take its locks in this order, or it can deadlock with a seat move.
  """
  @spec move_to_participant(binary(), %{id: binary()}, %{id: binary()}) :: non_neg_integer()
  def move_to_participant(old_participant_id, %{id: participant_id}, %{id: meeting_id})
      when is_binary(old_participant_id) do
    {count, _rows} =
      BookingPaymentSchema
      |> where([b], b.participant_id == ^old_participant_id and b.seat_payment)
      |> Repo.update_all(
        set: [
          participant_id: participant_id,
          meeting_id: meeting_id,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    count
  end

  @doc """
  Whether a seat checkout of a host's is still pending: a booker holds seats
  on one of their group meetings, which may have been confirmed by others
  already, and has not yet paid.
  """
  @spec pending_seat_payment_for_host?(integer()) :: boolean()
  def pending_seat_payment_for_host?(host_user_id) do
    BookingPaymentSchema
    |> where([b], b.host_user_id == ^host_user_id and b.seat_payment and b.status == :pending)
    |> Repo.exists?()
  end

  @doc "Links a converted seat payment to its participant and meeting (`BookingPaymentSchema.convert_changeset/2`)."
  @spec link_seat(BookingPaymentSchema.t(), map()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, Ecto.Changeset.t()}
  def link_seat(schema, attrs) do
    schema
    |> BookingPaymentSchema.convert_changeset(attrs)
    |> Repo.update()
  end

  defp cast_id(id) do
    case UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
