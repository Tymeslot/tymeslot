defmodule Tymeslot.Bookings.Create.PaidBooking do
  @moduledoc """
  Creating a booking that has to be paid for before it counts.

  A free booking is one transaction: insert the meeting, its guests and its
  calendar job, and roll all three back together if any fails. A paid booking
  cannot be, because it has to talk to Stripe, and that is why it lives apart
  from the free path rather than as a branch inside it.

  ## Why the checkout call is outside the transaction

  Holding a pooled database connection open across a network round-trip to
  Stripe risks exhausting the pool whenever Stripe is slow. So the meeting is
  created and conflict-checked atomically first, and the Stripe call follows
  once the connection is back in the pool.

  ## What replaces the rollback

  Without a transaction spanning both, a failure after the meeting exists has
  to be compensated by hand: the meeting is expired so its slot is released
  immediately instead of sitting as `awaiting_payment` until the reconciliation
  sweep notices. That applies to a failed checkout *and* to failed guest
  insertion, which runs after the meeting is committed.

  The reconciliation sweep is still the net for failures that cannot be
  observed from here at all, such as a crash between creating the session and
  the client reaching the redirect.
  """

  require Logger

  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.Scheduling

  @typedoc "The successful outcome: a held slot plus somewhere to go and pay."
  @type result ::
          {:ok, :payment_required, %{meeting: struct(), checkout_url: String.t()}}
          | {:error, term()}

  @doc """
  Creates the meeting in `awaiting_payment`, adds its guests, and opens a
  Stripe checkout session.

  Takes the callbacks the caller already owns rather than reaching back into
  `Create`: `create_meeting` applies the conflict check, `create_guests`
  applies the guest policy, and `classify_error` maps a raw failure onto the
  caller's semantic error vocabulary.
  """
  @spec create(map(), map(), keyword()) :: result()
  def create(meeting_attrs, booking_data, callbacks) do
    create_meeting = Keyword.fetch!(callbacks, :create_meeting)
    create_guests = Keyword.fetch!(callbacks, :create_guests)
    classify_error = Keyword.fetch!(callbacks, :classify_error)
    on_created = Keyword.fetch!(callbacks, :on_created)

    paid_attrs = Map.put(meeting_attrs, :status, "awaiting_payment")

    with {:ok, meeting} <- create_meeting.(paid_attrs),
         {:ok, _guests} <- guests_or_expire(meeting, booking_data, create_guests),
         {:ok, %{checkout_url: url}} <- checkout_or_expire(meeting) do
      on_created.()
      {:ok, :payment_required, %{meeting: meeting, checkout_url: url}}
    else
      {:error, reason} -> {:error, classify_error.(reason)}
    end
  end

  defp guests_or_expire(meeting, booking_data, create_guests) do
    case create_guests.(meeting, booking_data) do
      {:ok, guests} ->
        {:ok, guests}

      {:error, reason} ->
        expire_unpaid_meeting(meeting, reason)
        {:error, reason}
    end
  end

  defp checkout_or_expire(meeting) do
    case MeetingPayments.create_checkout_session(meeting) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        expire_unpaid_meeting(meeting, reason)
        {:error, {:checkout_failed, reason}}
    end
  end

  # Best-effort: the booking has already failed, and failing to expire it only
  # means the reconciliation sweep picks the slot up later instead of now.
  defp expire_unpaid_meeting(meeting, reason) do
    case Scheduling.update_meeting_with_conflict_check(meeting, %{status: "expired"}) do
      {:ok, _expired} ->
        :ok

      {:error, expire_error} ->
        Logger.warning("Failed to expire meeting after checkout failure",
          meeting_id: meeting.id,
          checkout_error: inspect(reason),
          expire_error: inspect(expire_error)
        )

        :ok
    end
  end
end
