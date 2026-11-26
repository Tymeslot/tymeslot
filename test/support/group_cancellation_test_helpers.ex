defmodule Tymeslot.GroupCancellationTestHelpers do
  @moduledoc """
  A paid group session in tests: its host, the seats paid or still held
  on it, on a connected Stripe account. Shared by the group cancellation
  test files.
  """

  import Tymeslot.Factory

  @account "acct_GROUP_CANCEL"
  @price_cents 2000

  @doc "The connected account every seat is charged on."
  @spec account() :: String.t()
  def account, do: @account

  @doc "One seat's price, in cents (EUR)."
  @spec price_cents() :: pos_integer()
  def price_cents, do: @price_cents

  @doc "A host with a paid group session; `attrs` override the meeting's."
  @spec host_and_session(keyword()) :: map()
  def host_and_session(attrs \\ []) do
    host = insert(:user, email: "host@example.com", name: "Host")
    insert(:profile, user: host, timezone: "Etc/UTC")

    meeting_type =
      insert(:meeting_type,
        user: host,
        name: "Group Class",
        max_participants: 6,
        payment_required: true,
        price_cents: @price_cents
      )

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

    session =
      insert(
        :group_meeting,
        Keyword.merge(
          [
            organizer_user: host,
            organizer_email: host.email,
            meeting_type_ref: meeting_type,
            title: meeting_type.name,
            start_time: start_time,
            end_time: DateTime.add(start_time, 30, :minute),
            duration: 30,
            capacity: 6,
            status: :confirmed
          ],
          attrs
        )
      )

    %{host: host, meeting_type: meeting_type, session: session}
  end

  @doc "A seat paid and booked; `payment_attrs` override the payment's."
  @spec paid_seat(map(), String.t(), keyword()) :: struct()
  def paid_seat(%{host: host, session: session}, email, payment_attrs \\ []) do
    participant = insert(:participant, meeting: session, email: email)
    hold = insert(:seat_hold, meeting: session, email: email, status: :converted)

    insert(
      :paid_booking_payment,
      Keyword.merge(
        [
          meeting_id: session.id,
          participant_id: participant.id,
          seat_hold_id: hold.id,
          seat_payment: true,
          seats: 1,
          amount_cents: @price_cents,
          host_user_id: host.id,
          host_email: host.email,
          attendee_email: email,
          stripe_account_id: @account
        ],
        payment_attrs
      )
    )
  end

  @doc "A seat held for a booker whose checkout is still open."
  @spec open_hold(map(), String.t()) :: struct()
  def open_hold(%{host: host, session: session}, email) do
    hold = insert(:seat_hold, meeting: session, email: email)

    insert(:booking_payment,
      meeting_id: session.id,
      seat_hold_id: hold.id,
      seat_payment: true,
      seats: 1,
      amount_cents: @price_cents,
      host_user_id: host.id,
      stripe_account_id: @account,
      stripe_checkout_session_id: "cs_open_#{hold.id}"
    )

    hold
  end
end
