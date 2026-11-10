defmodule Tymeslot.MeetingPayments.ConnectAccounts do
  @moduledoc """
  Stripe Connect lifecycle for hosts.

  A host connects a Stripe account they already have through Stripe Connect
  OAuth. A `connect_accounts` row carries a single-use nonce for the attempt,
  which is claimed before the authorisation code is exchanged: Stripe revokes
  a connection whose code is consumed twice, so nothing may exchange a code
  without winning that claim first.
  """

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.Currency
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.StripeConnectOAuth
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendConnectAccountRestricted

  @type account :: ConnectAccountSchema.t()

  # Seconds: long enough for a host whose connection could not be read to retry.
  @unread_account_revocation_delay 3600

  # Checkout sessions live 30 minutes (`@session_expiry_seconds` in
  # `CheckoutSessions`), and a session Stripe failed to expire may still
  # complete, which then needs access to the account for the automatic refund.
  @revoke_delay_seconds 35 * 60

  @doc """
  Starts connecting a Stripe account for `user`, returning the Stripe URL to
  send them to.

  Enforces the feature gate itself, so a forged request cannot start a
  connection whatever the caller checked: the error is the
  `Tymeslot.Features.check_access/2` reason (`:feature_disabled`,
  `:insufficient_plan`, …). `{:error, :stripe_required}` from that check
  counts as allowed, since establishing the account is what this flow is for.

  A row with no account yet, or a legacy account the host never finished, can
  start. Any other live row is `{:error, :already_connected}`. Without a
  Connect client ID the result is `{:error, :oauth_not_configured}`.
  """
  @spec start_onboarding(user :: %{id: integer()}) ::
          {:ok, %{url: String.t(), account: account()}}
          | {:error, :oauth_not_configured | :already_connected | term()}
  def start_onboarding(user) do
    with :ok <- check_onboarding_access(user.id),
         :ok <- check_oauth_configured(),
         {:ok, placeholder} <- ensure_placeholder(user.id),
         :ok <- check_startable(placeholder),
         nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
         {:ok, account} <- ConnectAccountQueries.set_oauth_nonce(placeholder, nonce) do
      {:ok, %{url: StripeConnectOAuth.authorize_url(user.id, nonce), account: account}}
    end
  end

  @doc """
  Completes a connection when Stripe sends the host back with a `code`.

  The nonce in `state` is claimed before the code is exchanged, so a replayed
  or concurrent callback never reaches Stripe. When the account cannot be read
  afterwards, or names no currency, nothing is saved and the result is
  `{:error, :oauth_failed}`: the host retries with a fresh code, and the
  connection is revoked an hour later if they never do.

  An account in a currency meeting payments do not support is refused and
  queued for revocation, which leaves alone any account with a live row. An
  account another host holds is refused and left connected, as it is theirs.
  """
  @spec complete_oauth_callback(user :: %{id: integer()}, code :: String.t(), state :: String.t()) ::
          {:ok, account()}
          | {:error,
             :invalid_state
             | :expired_state
             | :user_mismatch
             | :state_already_used
             | :invalid_grant
             | :oauth_failed
             | :account_already_linked
             | :unsupported_currency
             | term()}
  def complete_oauth_callback(user, code, state) do
    with :ok <- check_onboarding_access(user.id),
         {:ok, nonce} <- verify_state_for(user.id, state),
         :ok <- claim_nonce(user.id, nonce),
         {:ok, %{stripe_user_id: stripe_account_id}} <- StripeAdapter.exchange_oauth_code(code),
         :ok <- check_not_linked_elsewhere(stripe_account_id, user.id) do
      record_connection(user.id, stripe_account_id)
    end
  end

  defp check_oauth_configured do
    if StripeConnectOAuth.configured?(), do: :ok, else: {:error, :oauth_not_configured}
  end

  defp check_startable(%ConnectAccountSchema{stripe_account_id: nil}), do: :ok

  defp check_startable(%ConnectAccountSchema{oauth_connected_at: nil, details_submitted: false}),
    do: :ok

  defp check_startable(%ConnectAccountSchema{}), do: {:error, :already_connected}

  defp verify_state_for(user_id, state) do
    case StripeConnectOAuth.verify_state(state) do
      {:ok, %{user_id: ^user_id, nonce: nonce}} -> {:ok, nonce}
      {:ok, _other_user} -> {:error, :user_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp claim_nonce(user_id, nonce) do
    case ConnectAccountQueries.claim_oauth_nonce(user_id, nonce) do
      :ok -> :ok
      :error -> {:error, :state_already_used}
    end
  end

  # Runs after the exchange on purpose: Stripe names the account only there.
  defp check_not_linked_elsewhere(stripe_account_id, user_id) do
    case ConnectAccountQueries.by_stripe_account_id(stripe_account_id) do
      nil -> :ok
      %ConnectAccountSchema{user_id: ^user_id} -> :ok
      %ConnectAccountSchema{} -> {:error, :account_already_linked}
    end
  end

  # A read that fails, or names no currency, cannot produce a row that is safe
  # to take payments on, so nothing is saved. The code is spent, so the orphan
  # connection is revoked after a delay long enough for the host to retry; a
  # retry leaves a live row, and the job then does nothing.
  defp record_connection(user_id, stripe_account_id) do
    read_at = DateTime.utc_now(:second)

    case StripeAdapter.retrieve_account(stripe_account_id) do
      {:ok, %{"default_currency" => currency} = snapshot} when is_binary(currency) ->
        if Currency.allowed?(currency) do
          connect_with_snapshot(user_id, stripe_account_id, snapshot, read_at)
        else
          enqueue_revocation(stripe_account_id)
          {:error, :unsupported_currency}
        end

      _unusable ->
        enqueue_revocation(stripe_account_id, schedule_in: @unread_account_revocation_delay)
        {:error, :oauth_failed}
    end
  end

  defp enqueue_revocation(stripe_account_id, opts \\ []) do
    case %{stripe_account_id: stripe_account_id}
         |> DeauthorizeConnectAccount.new(opts)
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue the revocation of a Stripe connection",
          stripe_account_id: stripe_account_id,
          reason: LogFormat.reason(reason)
        )
    end
  end

  defp connect_with_snapshot(user_id, stripe_account_id, snapshot, read_at) do
    with {:ok, account} <- save_connection(user_id, stripe_account_id, snapshot),
         :ok <- apply_account_event(snapshot, read_at) do
      {:ok, ConnectAccountQueries.get(account.id) || account}
    end
  end

  # Reuses the host's live row, which is how a stuck legacy account gets
  # replaced. The row is fetched afresh because a disconnect may have removed
  # it during the exchange, and the code is spent either way.
  defp save_connection(user_id, stripe_account_id, snapshot) do
    with {:ok, row} <- ensure_placeholder(user_id) do
      row
      |> ConnectAccountQueries.update(%{
        stripe_account_id: stripe_account_id,
        status: :active,
        oauth_connected_at: DateTime.utc_now(:second),
        oauth_nonce: nil,
        country: snapshot["country"],
        default_currency: connection_currency(user_id, snapshot["default_currency"]),
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false,
        disabled_reason: nil,
        last_account_event_at: nil
      })
      |> classify_link_conflict()
    end
  end

  # Stored prices carry no currency, and a disconnect keeps them, so a host
  # with prices stays in the currency they were set in whatever the new
  # account's default is: 50.00 must not silently turn from euros into pounds.
  defp connection_currency(user_id, stripe_default) do
    last_currency = Profiles.last_charge_currency(user_id)

    if Currency.allowed?(last_currency) and MeetingTypes.has_priced_meeting_types?(user_id),
      do: last_currency,
      else: stripe_default
  end

  defp classify_link_conflict({:error, %Ecto.Changeset{} = changeset} = error) do
    if unique_violation?(changeset, :stripe_account_id),
      do: {:error, :account_already_linked},
      else: error
  end

  defp classify_link_conflict(result), do: result

  # Uses the shared boolean predicate for the yes/no decision, and falls back
  # to the raw `check_access/2` reason only when denied, so the caller can
  # tell the host why.
  defp check_onboarding_access(user_id) do
    if Features.meeting_payments_allowed?(user_id),
      do: :ok,
      else: Features.check_access(user_id, :meeting_payments)
  end

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

  For an account the host connected through OAuth, the removal also schedules
  the revocation of Tymeslot's access to their Stripe account, 35 minutes
  later (see `schedule_revocation/1`); a reconnection in the meantime cancels
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

    user.id
    |> retire_in_transaction(pending, outstanding.count, true)
    |> announce_after_commit()
  end

  @doc """
  Retires the live account of `stripe_account_id` after its host removed
  Tymeslot at Stripe (`account.application.deauthorized`).

  Does what `disconnect/1` does, minus what Stripe has made pointless: open
  checkout sessions are not expired (access is already gone) and no
  revocation is scheduled. The host's charge currency is still recorded.

  A no-op when no live row exists (a replay), and when the row was connected
  after `event_at` (an event from before a reconnect). An event in the same
  second as the connection counts as applying.
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

          with {:ok, _summary} <-
                 user_id
                 |> retire_in_transaction(pending, 0, false)
                 |> announce_after_commit(),
               do: :ok
        end
    end
  end

  defp connected_after?(%ConnectAccountSchema{oauth_connected_at: %DateTime{} = at}, event_at),
    do: DateTime.after?(at, event_at)

  defp connected_after?(_account, _event_at), do: false

  defp retire_in_transaction(user_id, pending, outstanding_count, revoke?) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      {cancelled_count, expired} = cancel_pending_bookings(pending, now)
      retire_connect_account(user_id, now, revoke?)

      {%{cancelled_count: cancelled_count, outstanding_refunds_count: outstanding_count}, expired}
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
  # is the one the row held when it was removed.
  defp retire_connect_account(user_id, now, revoke?) do
    account = ConnectAccountQueries.lock_live_for_user(user_id)
    currency = account && account.default_currency

    if Currency.allowed?(currency), do: Profiles.record_last_charge_currency(user_id, currency)

    ConnectAccountQueries.soft_delete_for_user(user_id, now)
    if revoke?, do: schedule_revocation(account), else: :ok
  end

  @doc """
  Schedules the revocation of the platform's access to `account`'s Stripe
  account, once any checkout session still open on it can have ended.

  A later disconnect of the same account pushes back a revocation still
  pending, so the delay always runs from the most recent disconnect.

  Only an account the host connected through OAuth is revoked. A legacy
  account was created by the platform, and Stripe refuses to deauthorise
  those, so nothing is enqueued for it, nor for `nil`.

  Must run inside the transaction that removes the row: a failed insert rolls
  the transaction back, so the row is never removed with no revocation
  scheduled.
  """
  @spec schedule_revocation(ConnectAccountSchema.t() | nil) :: :ok
  def schedule_revocation(%ConnectAccountSchema{
        stripe_account_id: stripe_account_id,
        oauth_connected_at: %DateTime{}
      })
      when is_binary(stripe_account_id) do
    case %{stripe_account_id: stripe_account_id}
         |> DeauthorizeConnectAccount.new(
           schedule_in: @revoke_delay_seconds,
           unique: [
             period: :infinity,
             keys: [:stripe_account_id],
             states: [:available, :scheduled, :retryable]
           ],
           replace: [scheduled: [:scheduled_at]]
         )
         |> Oban.insert() do
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

  @doc """
  Reconciles a local `connect_accounts` row against a Stripe account snapshot.

  `account` is the Stripe account object (`charges_enabled`, `payouts_enabled`,
  `requirements.disabled_reason`, …). `event_at` is when that snapshot was
  emitted, used purely for the out-of-order guard against `last_account_event_at`.

  Callers must supply `event_at` from the right source. For `account.updated`
  webhooks it is the **event envelope's** `created` (the event emission time) —
  never the account object's own `created`, which is the account-creation
  timestamp and is identical across every event, so keying ordering off it
  would drop every update after the first. A direct account retrieve (resync)
  has no envelope and stamps the current time, since it reflects Stripe's
  current truth as of the fetch.
  """
  @spec apply_account_event(map(), DateTime.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def apply_account_event(%{"id" => stripe_account_id} = account, %DateTime{} = event_at) do
    case ConnectAccountQueries.by_stripe_account_id(stripe_account_id) do
      nil ->
        :ok

      %ConnectAccountSchema{} = local ->
        if stale_or_equal?(event_at, local.last_account_event_at) do
          :ok
        else
          now = DateTime.utc_now(:second)
          new_disabled_reason = get_in(account, ["requirements", "disabled_reason"])

          with {:ok, updated} <-
                 ConnectAccountQueries.update(local, %{
                   charges_enabled: account["charges_enabled"],
                   payouts_enabled: account["payouts_enabled"],
                   details_submitted: account["details_submitted"],
                   disabled_reason: new_disabled_reason,
                   last_synced_at: now,
                   last_account_event_at: event_at
                 }) do
            maybe_notify_restriction(updated, local.disabled_reason)
          end
        end
    end
  end

  # Fire the restriction email only when the disabled_reason transitions into
  # a different value — nil → non-nil, or between two different non-nil
  # values. This mirrors the spec's "transition only" rule and keeps repeated
  # account.updated events for the same restriction state silent.
  #
  # `details_submitted: true` gates the whole thing: an account still mid-
  # onboarding carries `requirements.past_due` as a matter of course, and
  # alarming the host that they are "restricted" before they have even finished
  # signing up is a false alarm. A genuine restriction only applies once Stripe
  # has something to act on, i.e. after details were submitted.
  defp maybe_notify_restriction(
         %ConnectAccountSchema{
           user_id: user_id,
           disabled_reason: new_reason,
           details_submitted: true
         } = account,
         previous_reason
       )
       when is_integer(user_id) and is_binary(new_reason) and new_reason != "" and
              new_reason != previous_reason do
    %{
      connect_account_id: account.id,
      user_id: user_id,
      stripe_account_id: account.stripe_account_id,
      disabled_reason: new_reason,
      previous_disabled_reason: previous_reason,
      dashboard_url: stripe_dashboard_url()
    }
    |> SendConnectAccountRestricted.new()
    |> Oban.insert()

    :ok
  end

  defp maybe_notify_restriction(_updated, _previous), do: :ok

  # The Stripe dashboard always lives at this canonical URL.
  defp stripe_dashboard_url, do: "https://dashboard.stripe.com/"

  @spec ensure_placeholder(integer()) :: {:ok, account()} | {:error, Ecto.Changeset.t()}
  defp ensure_placeholder(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      nil -> insert_or_fetch_placeholder(user_id)
      %ConnectAccountSchema{} = account -> {:ok, account}
    end
  end

  # On concurrent requests the unique index on (user_id) WHERE deleted_at IS
  # NULL means only one insert wins. The loser gets a unique-constraint error;
  # we re-fetch to return the winner's row instead of propagating the error.
  defp insert_or_fetch_placeholder(user_id) do
    case ConnectAccountQueries.insert_placeholder(user_id) do
      {:ok, _account} = ok ->
        ok

      {:error, changeset} = error ->
        if unique_violation?(changeset, :user_id),
          do: {:ok, ConnectAccountQueries.live_for_user(user_id)},
          else: error
    end
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    case errors[field] do
      {_message, opts} -> opts[:constraint] == :unique
      nil -> false
    end
  end

  # Drop events whose timestamp is older than OR equal to the last recorded
  # event. Equal-timestamp replays (Stripe may redeliver with the same
  # `created` value) would otherwise trigger a second DB write and potentially
  # enqueue a duplicate SendConnectAccountRestricted job.
  defp stale_or_equal?(_event_dt, nil), do: false
  defp stale_or_equal?(event_dt, last), do: DateTime.compare(event_dt, last) in [:lt, :eq]
end
