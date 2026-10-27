defmodule Tymeslot.MeetingPayments.ConnectAccounts do
  @moduledoc """
  Stripe Connect lifecycle for hosts.

  Owns the placeholder-first onboarding flow: a row is persisted before
  Stripe is ever called so that a crash mid-flight cannot orphan a real
  Stripe account. The Stripe API call itself is idempotency-keyed by that
  placeholder row, which makes a retry after a crash safe.
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
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendConnectAccountRestricted
  alias TymeslotWeb.Endpoint

  @type account :: ConnectAccountSchema.t()

  @doc """
  Starts (or resumes) Stripe Connect onboarding for `user`.

  Enforces the feature gate itself, so a forged request cannot start
  onboarding whatever the caller checked: the error is the
  `Tymeslot.Features.check_access/2` reason (`:feature_disabled`,
  `:insufficient_plan`, …). `{:error, :stripe_required}` from that check
  counts as allowed, since establishing the account is what this flow is for.

  A host whose row already carries a Stripe account (they left the hosted
  onboarding part-way and came back) gets a fresh onboarding link for that
  account; a new account is created only when the row has none. Returns
  `{:error, :account_creation_restricted}` when Stripe has put a temporary
  hold on the platform creating connected accounts, and
  `{:error, :unsupported_currency}` when the new account's currency (its
  country's) is not one meeting payments support.
  """
  @spec start_onboarding(user :: %{id: integer()}) ::
          {:ok, %{url: String.t(), account: account()}} | {:error, term()}
  def start_onboarding(user) do
    country = default_country()

    with :ok <- check_onboarding_access(user.id),
         {:ok, account} <- ensure_placeholder(user.id, country) do
      onboard(account, country)
    end
  end

  defp onboard(%ConnectAccountSchema{stripe_account_id: stripe_account_id} = account, _country)
       when is_binary(stripe_account_id) do
    with {:ok, link} <- create_account_link(stripe_account_id) do
      {:ok, %{url: link.url, account: account}}
    end
  end

  defp onboard(%ConnectAccountSchema{} = placeholder, country) do
    with {:ok, stripe_account} <- create_stripe_account(placeholder, country),
         :ok <- check_currency(stripe_account, country),
         {:ok, link} <- create_account_link(stripe_account.id),
         {:ok, account} <-
           ConnectAccountQueries.update(placeholder, %{
             stripe_account_id: stripe_account.id,
             default_currency: stripe_account.default_currency,
             status: "active"
           }) do
      {:ok, %{url: link.url, account: account}}
    end
  end

  # Stripe gives a new account its country's currency. The country is the
  # operator's MEETING_PAYMENTS_DEFAULT_COUNTRY, so a currency outside the
  # allowlist is a configuration error no host can fix; it is logged for the
  # operator, and the placeholder is left as it was, so onboarding can be
  # retried once the setting is corrected.
  defp check_currency(%{default_currency: currency}, country) do
    if is_binary(currency) and Currency.allowed?(currency) do
      :ok
    else
      Logger.error("Stripe Connect account created in an unsupported currency",
        country: country,
        currency: currency
      )

      {:error, :unsupported_currency}
    end
  end

  # Uses the shared boolean predicate for the yes/no decision, and falls back
  # to the raw `check_access/2` reason only when denied, so the caller can
  # tell the host why.
  defp check_onboarding_access(user_id) do
    if Features.meeting_payments_allowed?(user_id),
      do: :ok,
      else: Features.check_access(user_id, :meeting_payments)
  end

  # The user's profile carries no country field, so onboarding uses the
  # operator-configured default (MEETING_PAYMENTS_DEFAULT_COUNTRY, "ch" when
  # unset). Read at runtime because `config/runtime.exs` sets it.
  defp default_country,
    do: Application.get_env(:tymeslot, :meeting_payments_default_country, "ch")

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

    now = DateTime.utc_now(:second)

    fn ->
      {cancelled_count, expired} = cancel_pending_bookings(pending, now)
      ConnectAccountQueries.soft_delete_for_user(user.id, now)

      {%{cancelled_count: cancelled_count, outstanding_refunds_count: outstanding.count}, expired}
    end
    |> Repo.transaction()
    |> announce_after_commit()
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

  # The Stripe dashboard always lives at this canonical URL; we keep the
  # link generic rather than per-account because account_link sessions are
  # short-lived and would force us to call into Stripe synchronously.
  defp stripe_dashboard_url, do: "https://dashboard.stripe.com/"

  @spec ensure_placeholder(integer(), String.t()) ::
          {:ok, account()} | {:error, Ecto.Changeset.t()}
  defp ensure_placeholder(user_id, country) do
    case ConnectAccountQueries.live_for_user(user_id) do
      nil -> insert_or_fetch_placeholder(user_id, country)
      %ConnectAccountSchema{} = account -> {:ok, account}
    end
  end

  # On concurrent requests the unique index on (user_id) WHERE deleted_at IS
  # NULL means only one insert wins. The loser gets a unique-constraint error;
  # we re-fetch to return the winner's row instead of propagating the error.
  defp insert_or_fetch_placeholder(user_id, country) do
    case ConnectAccountQueries.insert_placeholder(user_id, country) do
      {:ok, _account} = ok ->
        ok

      {:error, %Ecto.Changeset{errors: [user_id: {_message, constraint_opts}]}}
      when is_list(constraint_opts) ->
        if Keyword.get(constraint_opts, :constraint) == :unique do
          {:ok, ConnectAccountQueries.live_for_user(user_id)}
        else
          {:error, :unexpected_constraint}
        end

      {:error, _reason} = err ->
        err
    end
  end

  # The idempotency key only protects a retry within Stripe's 24-hour key
  # window; `onboard/2` never reaches here for a row that already has an
  # account, which is what stops a later return creating a second one. It is
  # keyed by the placeholder row rather than the user: a host who disconnects
  # and starts again gets a new row, and must get a new account rather than
  # Stripe's cached answer naming the one they just left.
  defp create_stripe_account(%ConnectAccountSchema{id: placeholder_id}, country) do
    %{
      type: "standard",
      country: country,
      capabilities: %{
        card_payments: %{requested: true},
        transfers: %{requested: true}
      }
    }
    |> StripeAdapter.create_account(idempotency_key: "connect_account:#{placeholder_id}")
    |> classify_account_creation_error()
  end

  # Stripe's risk system can place a temporary hold on the platform's ability
  # to create connected accounts ("…temporarily restricted your ability to
  # create this type of connected account…"). It is lifted only from the
  # Stripe Dashboard, so an immediate retry cannot succeed. The message text
  # is the only signal Stripe gives to tell it apart from other invalid
  # requests.
  defp classify_account_creation_error(
         {:error, %Stripe.Error{code: :invalid_request_error, message: message}} = error
       )
       when is_binary(message) do
    if String.contains?(message, "temporarily restricted"),
      do: {:error, :account_creation_restricted},
      else: error
  end

  defp classify_account_creation_error(result), do: result

  defp create_account_link(stripe_account_id) do
    StripeAdapter.create_account_link(%{
      account: stripe_account_id,
      type: "account_onboarding",
      refresh_url: dashboard_url("/dashboard/payments?refresh=1"),
      return_url: dashboard_url("/dashboard/payments?return=1")
    })
  end

  defp dashboard_url(path), do: Endpoint.url() <> path

  # Drop events whose timestamp is older than OR equal to the last recorded
  # event. Equal-timestamp replays (Stripe may redeliver with the same
  # `created` value) would otherwise trigger a second DB write and potentially
  # enqueue a duplicate SendConnectAccountRestricted job.
  defp stale_or_equal?(_event_dt, nil), do: false
  defp stale_or_equal?(event_dt, last), do: DateTime.compare(event_dt, last) in [:lt, :eq]
end
