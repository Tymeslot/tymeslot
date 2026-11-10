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
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.Currency
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.StripeConnectOAuth
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Workers.SendConnectAccountRestricted

  @type account :: ConnectAccountSchema.t()

  # Seconds: long enough for a host whose connection could not be read to retry.
  @unread_account_revocation_delay 3600

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
