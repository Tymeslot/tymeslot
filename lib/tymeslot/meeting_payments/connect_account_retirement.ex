defmodule Tymeslot.MeetingPayments.ConnectAccountRetirement do
  @moduledoc """
  How a host's Connect account leaves Tymeslot: the host disconnecting it
  (`disconnect/1`), the host removing Tymeslot at Stripe
  (`handle_deauthorized/2`), and the revocation of the platform's access that
  follows a disconnect (`schedule_revocation/1`).

  `disconnect/1` and `handle_deauthorized/2` cancel the host's pending
  bookings and soft-delete the row in one transaction, recording the host's
  charge currency first, and announce the meetings they expired only once that
  transaction has committed. Deleting the host's account is a third way out,
  in `Tymeslot.MeetingPayments.DataRetention`: it soft-deletes the row and
  schedules the revocation, but records no charge currency, as the host is
  leaving.
  """

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.Currency
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  # Checkout sessions live 30 minutes (`@session_expiry_seconds` in
  # `CheckoutSessions`), and a session Stripe failed to expire may still
  # complete, which then needs access to the account for the automatic refund.
  @revoke_delay_seconds 35 * 60

  @doc """
  Disconnects the host's Stripe account.

  Performs three steps in order so attendees cannot complete payment after
  the account is gone:

    1. Collect pending booking_payments for this host (no lock needed).
    2. Expire each open Stripe Checkout Session (HTTP calls, outside any
       DB transaction to avoid holding the connection open).
    3. Atomic transaction: mark each booking_payment as `failed` (conditional
       UPDATE — only when `status = 'pending'`, so a concurrent
       `checkout.session.completed` webhook that has already moved the row to
       `paid` is not overwritten), transition the linked `awaiting_payment`
       meeting to `expired`, then soft-delete the connect_account row.

  The removal also schedules the revocation of Tymeslot's access to the
  host's Stripe account, 35 minutes later (see `schedule_revocation/1`); a reconnection in the meantime cancels
  it in effect, since the worker leaves a connected account alone.

  Returns `{:ok, %{cancelled_count: n, outstanding_refunds_count: m}}` on
  success, `{:error, reason}` if the transaction fails.

  ## Outstanding refunds

  `outstanding_refunds_count` is measured before the soft delete and is not
  acted on: these are cancelled bookings whose money the host still holds, and
  disconnecting neither settles nor cancels them. It is reported because the
  disconnect is the moment the host loses the ability to issue them from
  Tymeslot (from here on only their Stripe dashboard can settle them), so the
  caller can say so rather than let the obligation disappear quietly.

  ## Race with checkout.session.completed

  The conditional `UPDATE … WHERE status = 'pending'` in step 3 means a
  `checkout.session.completed` webhook that has already flipped a row to `paid`
  will not be overwritten — the update silently skips that row, and
  `cancelled_count` reflects only the rows that were actually cancelled.

  If the webhook arrives *after* step 3, it finds the meeting `expired` and
  the payment `failed`, and the money has been taken all the same, so
  `CheckoutSessionCompleted` does not ignore it: it confirms the booking
  after all if the slot is still free (checked under the organiser's
  schedule lock), and refunds the payment in full on the connected account
  if the slot has been taken since, leaving the meeting expired.

  ## Stripe session expiry failures

  Stripe session expiry is best-effort. If a call fails (network error, session
  already expired/completed) we log and continue — the meeting and booking_payment
  are cancelled locally regardless, so the attendee cannot complete the booking
  even if the Stripe session is still technically open.

  ## Paid meeting types are left alone

  Deliberately: `payment_required` and `price_cents` survive a disconnect so a
  host who reconnects gets their prices back instead of re-entering every one.
  The currency they were set in is recorded on the profile, so a reconnect
  cannot re-denominate them.
  The form no longer clears them by omission
  (`Tymeslot.MeetingTypes.FormMapper.build_attrs/3`), the changeset no longer
  fails unrelated saves over the stored flag
  (`MeetingTypeSchema.validate_payment_fields/2`), and `Bookings.Create`
  refuses a paid booking outright while charges are off, so nothing is taken
  in the meantime. Clearing them here, as `MeetingPayments.change_default_currency/2`
  does for a currency change, would destroy that state for the far more common
  case of a temporary disconnect.
  """
  @spec disconnect(user :: %{id: integer()}) ::
          {:ok,
           %{cancelled_count: non_neg_integer(), outstanding_refunds_count: non_neg_integer()}}
          | {:error, term()}
  def disconnect(user) do
    pending = BookingPaymentQueries.list_pending_for_host(user.id)
    outstanding = BookingPaymentQueries.outstanding_refunds_summary_for_host(user.id)
    account = ConnectAccountQueries.live_for_user(user.id)

    expire_stripe_sessions(pending, account)

    with {:ok, cancelled_count} <-
           user.id
           |> retire(pending, &schedule_revocation/1)
           |> announce_after_commit() do
      {:ok, %{cancelled_count: cancelled_count, outstanding_refunds_count: outstanding.count}}
    end
  end

  @doc """
  Retires the live account of `stripe_account_id` after its host removed
  Tymeslot at Stripe (`account.application.deauthorized`).

  Does what `disconnect/1` does, minus what Stripe has made pointless: open
  checkout sessions are not expired (access is already gone) and no
  revocation is scheduled. The host's charge currency is still recorded.

  A no-op when no live row exists (a replay), and when the row was connected
  after `event_at` (an event from before a reconnect). An event in the same
  second as the connection counts as applying. Both are checked again on the
  row locked inside the transaction, so a host who disconnects and reconnects
  another account while the event is handled keeps the new connection.
  """
  @spec handle_deauthorized(stripe_account_id :: String.t(), event_at :: DateTime.t()) ::
          :ok | {:error, term()}
  def handle_deauthorized(stripe_account_id, %DateTime{} = event_at) do
    case ConnectAccountQueries.by_stripe_account_id(stripe_account_id) do
      nil ->
        :ok

      %ConnectAccountSchema{user_id: user_id} = account ->
        if connected_after?(account, event_at) do
          :ok
        else
          pending = BookingPaymentQueries.list_pending_for_host(user_id)

          user_id
          |> retire(pending, &still_deauthorized!(&1, stripe_account_id, event_at))
          |> announce_after_commit()
          |> case do
            {:ok, _cancelled_count} -> :ok
            {:error, :superseded} -> :ok
            {:error, _reason} = error -> error
          end
        end
    end
  end

  # Runs on the row locked inside the transaction. A row that is gone, holds
  # another account, or was connected after the event has replaced the one the
  # event is about, so the whole retirement is rolled back.
  defp still_deauthorized!(locked, stripe_account_id, event_at) do
    case locked do
      %ConnectAccountSchema{stripe_account_id: ^stripe_account_id} = account ->
        if connected_after?(account, event_at), do: Repo.rollback(:superseded), else: :ok

      _replaced_or_gone ->
        Repo.rollback(:superseded)
    end
  end

  defp connected_after?(%ConnectAccountSchema{oauth_connected_at: %DateTime{} = at}, event_at),
    do: DateTime.after?(at, event_at)

  defp connected_after?(_account, _event_at), do: false

  # Cancels the pending bookings and soft-deletes the live row in one
  # transaction, then hands the removed row to `after_retire`, which runs in
  # the same transaction.
  defp retire(user_id, pending, after_retire) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      {cancelled_count, expired} = cancel_pending_bookings(pending, now)
      after_retire.(retire_connect_account(user_id, now))
      {cancelled_count, expired}
    end)
  end

  @doc """
  Steps 1 to 3 of `disconnect/1` without the soft delete: expires the host's
  open Stripe Checkout sessions and cancels their pending bookings, leaving
  the Connect account in place. Used when a host's account is frozen pending
  deletion, so no attendee can still pay for a booking the host will never
  hold. A checkout that completes regardless is refunded by
  `CheckoutSessionCompleted`.

  Returns `{:ok, cancelled_count}`, or `{:error, reason}` if the transaction
  fails.
  """
  @spec cancel_pending_checkouts(user :: %{id: integer()}) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cancel_pending_checkouts(user) do
    pending = BookingPaymentQueries.list_pending_for_host(user.id)
    expire_stripe_sessions(pending, ConnectAccountQueries.live_for_user(user.id))
    now = DateTime.utc_now(:second)

    fn -> cancel_pending_bookings(pending, now) end
    |> Repo.transaction()
    |> announce_after_commit()
  end

  # Must run inside a transaction: the row is locked so the currency recorded
  # is the one the row held when it was removed. Returns the row removed.
  defp retire_connect_account(user_id, now) do
    account = ConnectAccountQueries.lock_live_for_user(user_id)
    currency = account && account.default_currency

    if Currency.allowed?(currency), do: Profiles.record_last_charge_currency(user_id, currency)

    ConnectAccountQueries.soft_delete_for_user(user_id, now)
    account
  end

  @doc """
  Schedules the revocation of the platform's access to `account`'s Stripe
  account, once any checkout session still open on it can have ended.

  A later disconnect of the same account pushes back a revocation still
  pending, so the delay always runs from the most recent disconnect.

  Every account is revoked, including a legacy one the platform created
  before OAuth: Stripe accepts those too (the worker cancels the job should it
  refuse one as platform-controlled). Nothing is enqueued for `nil` or a row
  with no Stripe account.

  Must run inside the transaction that removes the row: a failed insert rolls
  the transaction back, so the row is never removed with no revocation
  scheduled.
  """
  @spec schedule_revocation(ConnectAccountSchema.t() | nil) :: :ok
  def schedule_revocation(%ConnectAccountSchema{stripe_account_id: stripe_account_id})
      when is_binary(stripe_account_id) do
    case DeauthorizeConnectAccount.schedule(stripe_account_id, @revoke_delay_seconds) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:revocation_not_scheduled, reason})
    end
  end

  def schedule_revocation(_account), do: :ok

  # Returns the number of bookings cancelled and the meetings whose hold was
  # released, which are announced only once the transaction has committed.
  defp cancel_pending_bookings(pending, now) do
    Enum.reduce(pending, {0, []}, fn payment, {count, expired} ->
      case cancel_pending_booking(payment, now) do
        {:ok, nil} -> {count + 1, expired}
        {:ok, meeting} -> {count + 1, [meeting | expired]}
        :skipped -> {count, expired}
      end
    end)
  end

  defp announce_after_commit({:ok, {result, expired}}) do
    Enum.each(expired, &HeldMeetings.announce_expired/1)
    {:ok, result}
  end

  defp announce_after_commit({:error, _reason} = error), do: error

  # Cancel a pending booking_payment and, if it has a linked awaiting_payment
  # meeting, transition that meeting to expired so the slot is released.
  #
  # Uses a conditional UPDATE that only writes when status = 'pending', so a
  # concurrent checkout.session.completed webhook that has already flipped the
  # row to 'paid' is not overwritten. The meeting is locked only after that
  # claim, the same order the webhooks take their locks in.
  #
  # Returns `{:ok, expired_meeting | nil}` when the row was cancelled, and
  # :skipped when it was already in a terminal state (a concurrent webhook
  # beat us to it).
  defp cancel_pending_booking(payment, now) do
    case BookingPaymentQueries.cancel_if_pending(payment.id, now) do
      {:ok, :cancelled} ->
        {:ok, expire_held_meeting(payment.meeting_id)}

      {:ok, :skipped} ->
        :skipped

      {:error, reason} ->
        ErrorTracking.report_error(reason, nil, %{booking_payment_id: payment.id})
        :skipped
    end
  end

  # A meeting write that fails is logged and the cancellation stands: the
  # payment's own `checkout.session.expired` event later expires a meeting
  # still awaiting payment behind a cancelled payment
  # (`Webhooks.FailAndExpire`).
  defp expire_held_meeting(meeting_id) do
    case HeldMeetings.expire(meeting_id) do
      {:ok, :expired, meeting} ->
        meeting

      {:ok, :unchanged} ->
        nil

      {:error, reason} ->
        Logger.warning("Failed to expire the meeting of a cancelled checkout",
          meeting_id: meeting_id,
          reason: LogFormat.reason(reason)
        )

        nil
    end
  end

  defp expire_stripe_sessions(pending, account) do
    stripe_account_id = account && account.stripe_account_id

    Enum.each(pending, &expire_stripe_session(&1.stripe_checkout_session_id, stripe_account_id))
  end

  # Isolated per session: one that raises is logged like one that fails, so
  # the rest are still expired and every booking is still cancelled locally.
  defp expire_stripe_session(session_id, stripe_account_id) do
    case StripeAdapter.expire_checkout_session(session_id, connect_account: stripe_account_id) do
      {:ok, _session} -> :ok
      {:error, reason} -> log_expire_failure(session_id, reason)
    end
  rescue
    exception -> log_expire_failure(session_id, exception)
  end

  defp log_expire_failure(session_id, reason) do
    Logger.warning("Failed to expire Stripe checkout session",
      session_id: session_id,
      reason: LogFormat.reason(reason)
    )
  end
end
