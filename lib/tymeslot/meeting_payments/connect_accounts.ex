defmodule Tymeslot.MeetingPayments.ConnectAccounts do
  @moduledoc """
  Stripe Connect lifecycle for hosts.

  Owns the placeholder-first onboarding flow: a row is persisted before
  Stripe is ever called so that a crash mid-flight cannot orphan a real
  Stripe account. The Stripe API call itself is idempotency-keyed by the
  user id, which makes a retry after a crash safe.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendConnectAccountRestricted
  alias TymeslotWeb.Endpoint

  @type account :: ConnectAccountSchema.t()

  @spec start_onboarding(user :: %{id: integer()}, opts :: keyword()) ::
          {:ok, %{url: String.t(), account: account()}} | {:error, term()}
  def start_onboarding(user, opts) do
    country = Keyword.fetch!(opts, :country)

    with {:ok, placeholder} <- ensure_placeholder(user.id, country),
         {:ok, stripe_account} <- create_stripe_account(user.id, country),
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

  Returns `{:ok, %{cancelled_count: n}}` on success, `{:error, reason}` if the
  transaction fails.

  ## Race with checkout.session.completed

  The conditional `UPDATE … WHERE status = 'pending'` in step 3 means a
  `checkout.session.completed` webhook that has already flipped a row to `paid`
  will not be overwritten — the update silently skips that row, and
  `cancelled_count` reflects only the rows that were actually cancelled.

  If the webhook arrives *after* step 3 sets the meeting to `expired`, the
  `CheckoutSessionCompleted.ensure_awaiting_payment/1` guard will find the
  meeting in `expired` status and return `:no_op`, leaving the payment untouched.

  ## Stripe session expiry failures

  Stripe session expiry is best-effort. If a call fails (network error, session
  already expired/completed) we log and continue — the meeting and booking_payment
  are cancelled locally regardless, so the attendee cannot complete the booking
  even if the Stripe session is still technically open.
  """
  @spec disconnect(user :: %{id: integer()}) ::
          {:ok, %{cancelled_count: non_neg_integer()}} | {:error, term()}
  def disconnect(user) do
    pending = BookingPaymentQueries.list_pending_for_host(user.id)
    account = ConnectAccountQueries.live_for_user(user.id)

    expire_stripe_sessions(pending, account)

    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      cancelled_count =
        Enum.reduce(pending, 0, fn payment, acc ->
          case cancel_pending_booking(payment, now) do
            :ok -> acc + 1
            :skipped -> acc
          end
        end)

      ConnectAccountQueries.soft_delete_for_user(user.id, now)

      %{cancelled_count: cancelled_count}
    end)
  end

  # Cancel a pending booking_payment and, if it has a linked awaiting_payment
  # meeting, transition that meeting to expired so the slot is released.
  #
  # Uses a conditional UPDATE that only writes when status = 'pending', so a
  # concurrent checkout.session.completed webhook that has already flipped the
  # row to 'paid' is not overwritten.
  #
  # Returns :ok when the row was cancelled, :skipped when the row was already
  # in a terminal state (concurrent webhook beat us to it).
  defp cancel_pending_booking(payment, now) do
    case BookingPaymentQueries.cancel_if_pending(payment.id, now) do
      {:ok, :cancelled} ->
        maybe_expire_meeting(payment.meeting)
        :ok

      {:ok, :skipped} ->
        :skipped

      {:error, _reason} ->
        :skipped
    end
  end

  defp maybe_expire_meeting(nil), do: :ok

  defp maybe_expire_meeting(%{status: "awaiting_payment"} = meeting) do
    case MeetingQueries.update_meeting(meeting, %{status: "expired"}) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning("disconnect: failed to expire meeting",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )
    end
  end

  defp maybe_expire_meeting(_meeting), do: :ok

  defp expire_stripe_sessions(pending, account) do
    stripe_account_id = account && account.stripe_account_id

    Enum.each(pending, fn payment ->
      session_id = payment.stripe_checkout_session_id

      result =
        StripeAdapter.expire_checkout_session(session_id,
          connect_account: stripe_account_id
        )

      case result do
        {:ok, _session} ->
          :ok

        {:error, reason} ->
          Logger.warning("disconnect: failed to expire Stripe checkout session",
            session_id: session_id,
            reason: inspect(reason)
          )
      end
    end)
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
  @spec apply_account_event(map(), DateTime.t()) :: :ok
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

          {:ok, updated} =
            ConnectAccountQueries.update(local, %{
              charges_enabled: account["charges_enabled"],
              payouts_enabled: account["payouts_enabled"],
              details_submitted: account["details_submitted"],
              disabled_reason: new_disabled_reason,
              last_synced_at: now,
              last_account_event_at: event_at
            })

          maybe_notify_restriction(updated, local.disabled_reason)
          :ok
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

  # Stripe Express dashboard always lives at this canonical URL; we keep the
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

  defp create_stripe_account(user_id, country) do
    StripeAdapter.create_account(
      %{
        type: "standard",
        country: country,
        capabilities: %{
          card_payments: %{requested: true},
          transfers: %{requested: true}
        }
      },
      idempotency_key: "account:#{user_id}"
    )
  end

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
