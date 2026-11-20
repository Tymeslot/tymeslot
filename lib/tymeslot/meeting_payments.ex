defmodule Tymeslot.MeetingPayments do
  @moduledoc """
  Main entry point for meeting-payments operations.

  Covers the Stripe Connect account's lifecycle and status, refunds, and
  the host's currency. Two public siblings carry the rest of the domain:
  `Tymeslot.MeetingPayments.Checkout`, for taking a payment (opening,
  abandoning and reading the outcome of a checkout, and releasing a booking
  held while it was open), and `Tymeslot.MeetingPayments.BookingPayments`,
  for reading payment records. External callers (web, workers, email
  templates, cross-domain modules) use this module or those two; every
  other submodule is internal.

  ## Public struct types

  `BookingPaymentSchema` and `ConnectAccountSchema` are intentionally
  part of this module's public API surface, exposed via the `t:booking_payment/0`
  and `t:account/0` type declarations respectively. Callers may alias these
  schema modules **solely to pattern-match on structs returned by facade
  functions** — for example, in `perform/1` clause heads of Oban workers
  that dispatch on struct fields.

  The following uses remain prohibited for all external callers:

    * Direct `Repo.*` calls against these schemas
    * Constructing or applying changesets (`Ecto.Changeset`)
    * Calling any function defined in the submodule itself

  Pattern-matching on a `%BookingPaymentSchema{}` or `%ConnectAccountSchema{}`
  value that was *returned by this facade* is permitted and does not constitute
  a layering violation.
  """

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.AccountCurrency
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountRetirement
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.Currency
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Workers.ResyncConnectAccount
  alias Tymeslot.Payments.Config, as: PaymentsConfig

  @type account :: ConnectAccountSchema.t()
  @type booking_payment :: BookingPaymentSchema.t()

  @typedoc """
  What a disconnect walked away from: the pending bookings it cancelled, and
  the refunds the host is still holding and can no longer issue from Tymeslot.
  """
  @type disconnect_result :: %{
          cancelled_count: non_neg_integer(),
          outstanding_refunds_count: non_neg_integer()
        }

  # ---------------------------------------------------------------------------
  # Connect account lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts connecting a host's Stripe account through OAuth.

  Enforces the meeting-payments feature gate and returns the Stripe URL to
  send the host to. On failure: a `Tymeslot.Features.check_access/2` reason,
  `:oauth_not_configured`, or `:already_connected`.
  """
  @spec start_onboarding(user :: %{id: integer()}) ::
          {:ok, %{url: String.t(), account: account()}}
          | {:error, :oauth_not_configured | :already_connected | term()}
  defdelegate start_onboarding(user), to: ConnectAccounts

  @doc """
  Completes a Stripe connection when the host returns from Stripe with a code.

  See `Tymeslot.MeetingPayments.ConnectAccounts.complete_oauth_callback/3`.
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
  defdelegate complete_oauth_callback(user, code, state), to: ConnectAccounts

  @doc """
  Soft-deletes the host's Stripe Connect account row.
  """
  @spec disconnect(user :: %{id: integer()}) ::
          {:ok, disconnect_result()} | {:error, term()}
  defdelegate disconnect(user), to: ConnectAccountRetirement

  @doc """
  Expires the host's open Stripe Checkout sessions and cancels their pending
  bookings, leaving the Connect account in place. See
  `Tymeslot.MeetingPayments.ConnectAccountRetirement.cancel_pending_checkouts/1`.
  """
  @spec cancel_pending_checkouts(user :: %{id: integer()}) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate cancel_pending_checkouts(user), to: ConnectAccountRetirement

  @doc """
  Fetches a Connect account by its row ID, or `nil` if not found.
  """
  @spec get_connect_account(Ecto.UUID.t()) :: account() | nil
  def get_connect_account(id), do: ConnectAccountQueries.get(id)

  @doc """
  Returns the live (non-deleted) Connect account for a user, or `nil`.

  A row with no Stripe account yet is the placeholder written when the host
  pressed Connect, and counts as no account: a host who cancelled at Stripe is
  back where they started, not part-way through connecting.
  """
  @spec get_connect_account_for_user(integer()) :: account() | nil
  def get_connect_account_for_user(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{stripe_account_id: stripe_account_id} = account when is_binary(stripe_account_id) ->
        account

      _none_or_placeholder ->
        nil
    end
  end

  @doc """
  Maps a Connect account (or `nil`) to its onboarding display state.

  This is the single source of truth for "where is this account in the Stripe
  Connect lifecycle?" — consumed both by the payments status banner
  (`TymeslotWeb.Dashboard.PaymentsSettings.StatusCard`) and the integrations
  hub summary. `nil` (no account) reads as `:not_connected`.

  Two submitted states are distinct on purpose: `:incomplete` is onboarding
  that was never submitted (Stripe stamps a brand-new account with
  `requirements.past_due`, so `disabled_reason` must not be read until
  `details_submitted` is true), while `:pending_review` is a submitted account
  Stripe is still reviewing.

  An account that is otherwise ready but carries a currency payments cannot
  charge at all (`Currency.support/1` is `:unsupported`) reads as
  `:unsupported_currency`, since it takes no payments until its host picks a
  supported one.
  """
  @spec connect_display_state(map() | nil) ::
          :not_connected
          | :incomplete
          | :pending_review
          | :ready
          | :unsupported_currency
          | :restricted
          | :deleted
  def connect_display_state(nil), do: :not_connected
  def connect_display_state(%{deleted_at: dt}) when is_struct(dt, DateTime), do: :deleted
  def connect_display_state(%{details_submitted: true} = account), do: submitted_state(account)
  def connect_display_state(_account), do: :incomplete

  defp submitted_state(%{disabled_reason: reason}) when is_binary(reason), do: :restricted

  defp submitted_state(%{charges_enabled: true, payouts_enabled: true} = account) do
    if Currency.support(Map.get(account, :default_currency)) == :unsupported,
      do: :unsupported_currency,
      else: :ready
  end

  defp submitted_state(_account), do: :pending_review

  @doc """
  Returns `true` when the instance has a real Stripe platform API key
  configured — i.e. a `STRIPE_SECRET_KEY` env var was supplied and is not
  the `"sk_test_fake"` placeholder used in dev/test fixtures. The admin UI
  uses this to lock the "Meeting payments" toggle into the disabled state
  when an operator has not yet supplied platform credentials.
  """
  @spec platform_configured?() :: boolean()
  def platform_configured? do
    case PaymentsConfig.stripe_api_key() do
      nil -> false
      "sk_test_fake" -> false
      _real -> true
    end
  end

  @doc """
  Returns `true` if the user's Connect account has charges enabled, in a
  currency checkout can charge. See
  `Tymeslot.MeetingPayments.AccountCurrency.charges_enabled_for_user?/1`.
  """
  @spec charges_enabled_for_user?(integer()) :: boolean()
  defdelegate charges_enabled_for_user?(user_id), to: AccountCurrency

  @doc """
  The currency checkout charges the user in, or `nil` while it cannot charge
  them. See `Tymeslot.MeetingPayments.AccountCurrency.charge_currency/1`.
  """
  @spec charge_currency(integer()) :: String.t() | nil
  defdelegate charge_currency(user_id), to: AccountCurrency

  @doc """
  Returns `true` if the user may set or change a meeting type's price. See
  `Tymeslot.MeetingPayments.AccountCurrency.price_settable?/1`.
  """
  @spec price_settable?(integer() | nil) :: boolean()
  defdelegate price_settable?(user_id), to: AccountCurrency

  @doc """
  Returns `true` if the user can take a payment right now: their Connect
  account has charges enabled and their plan grants `:meeting_payments`.

  This is the same full grant checkout enforces, so a booking refused here
  would also have been refused at checkout.
  """
  @spec accepting_payments?(integer()) :: boolean()
  def accepting_payments?(user_id) do
    charges_enabled_for_user?(user_id) and
      Features.check_access(user_id, :meeting_payments) == :ok
  end

  @doc """
  Enqueues a background job to re-sync the Connect account from Stripe.

  Safe to call on every return from the Stripe onboarding flow;
  the worker's uniqueness constraint deduplicates within a 60-second window.
  """
  @spec enqueue_resync_for_account(stripe_account_id :: String.t()) :: :ok
  def enqueue_resync_for_account(stripe_account_id) do
    case %{stripe_account_id: stripe_account_id}
         |> ResyncConnectAccount.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue Stripe account resync",
          stripe_account_id: stripe_account_id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Refunds
  # ---------------------------------------------------------------------------

  @doc """
  Returns the remaining refundable balance in cents for a booking payment; see
  `Refunds.refundable_remaining_cents/1`.
  """
  @spec refundable_remaining_cents(booking_payment()) :: non_neg_integer()
  defdelegate refundable_remaining_cents(payment), to: Refunds

  @doc """
  What a host's cancellation of one booking refunds unless the host says
  otherwise; see `Refunds.default_cancellation_refund_cents/1`.
  """
  @spec default_cancellation_refund_cents(booking_payment()) :: non_neg_integer()
  defdelegate default_cancellation_refund_cents(payment), to: Refunds

  @doc """
  Why `payment` cannot be refunded at all (`:not_paid`,
  `:outside_refund_window`, `:under_dispute`), or `:ok`; see
  `Refunds.refusal/1`.
  """
  @spec refund_refusal(booking_payment()) ::
          :ok | {:error, :not_paid | :outside_refund_window | :under_dispute}
  defdelegate refund_refusal(payment), to: Refunds, as: :refusal

  @doc """
  Returns `true` when the payment can still be refunded in-app; see
  `Refunds.refundable?/1`.
  """
  @spec refundable?(booking_payment() | nil) :: boolean()
  defdelegate refundable?(payment), to: Refunds

  @doc """
  Returns `true` when the host still holds money the attendee has not been
  given back, whether or not the refund window has passed; see
  `Refunds.refund_outstanding?/1`.
  """
  @spec refund_outstanding?(booking_payment() | nil) :: boolean()
  defdelegate refund_outstanding?(payment), to: Refunds

  @doc """
  Parses raw refund-form params into a validated `{:ok, pos_integer()}` or
  a tagged `{:error, atom()}`; see `Refunds.parse_refund_amount/2`.
  """
  @spec parse_refund_amount(booking_payment(), map()) ::
          {:ok, pos_integer()} | {:error, :invalid_amount | :exceeds_remaining | :choose_type}
  defdelegate parse_refund_amount(payment, params), to: Refunds

  @doc """
  Issues a full or partial refund for a booking payment, whoever took it.

  Unscoped; see `Refunds.issue_refund/4`. A refund a signed-in user asks for
  must go through `refund_payment_for_host/5`.

  `key` is the Stripe idempotency key for this one refund, fixed when the
  refund is decided and carrying the amount, so that a retry gets the same
  refund back; see `Tymeslot.MeetingPayments.Refunds`.
  """
  @spec issue_refund(booking_payment(), integer(), String.t(), String.t() | nil) ::
          {:ok, booking_payment()} | {:error, Refunds.refund_error()}
  defdelegate issue_refund(payment, amount_cents, key, reason \\ nil), to: Refunds

  @doc """
  Refunds a booking payment on behalf of the host who took it.

  Only that host may refund it. Ownership is decided under the payment's row
  lock, in the same transaction as the refund itself. Another host's payment,
  an unknown id and a malformed id all return `{:error, :not_found}`.

  `key` is the Stripe idempotency key, as for `issue_refund/4`.
  """
  @spec refund_payment_for_host(term(), integer(), integer(), String.t(), String.t() | nil) ::
          {:ok, booking_payment()} | {:error, :not_found | Refunds.refund_error()}
  defdelegate refund_payment_for_host(
                payment_id,
                host_user_id,
                amount_cents,
                key,
                reason \\ nil
              ),
              to: Refunds,
              as: :issue_host_refund

  @doc """
  Moves the payment of the seat `old_participant_id` to the seat it was
  moved to (`new_participant` on `new_meeting`), keeping its status,
  amount and refunds: a moved seat keeps its payment, and no price
  difference is charged or refunded. A free seat has no payment, and
  nothing changes. Inside the move's transaction, under its meeting locks,
  so the payment row is locked after them (see
  `BookingPaymentQueries.move_to_participant/3` for why that order is safe).
  """
  @spec move_seat_payment(binary(), %{id: binary()}, %{id: binary()}) :: :ok
  def move_seat_payment(old_participant_id, new_participant, new_meeting) do
    _moved =
      BookingPaymentQueries.move_to_participant(old_participant_id, new_participant, new_meeting)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Currency
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of supported currency codes (lowercase ISO 4217).
  """
  @spec currency_allowlist() :: [String.t()]
  defdelegate currency_allowlist(), to: Currency, as: :allowlist

  @doc """
  Returns the host's pricing currency, the one new prices are set and checked
  against. See `Tymeslot.MeetingPayments.AccountCurrency.host_currency/1`.
  """
  @spec host_currency(integer() | nil) :: String.t()
  defdelegate host_currency(user_id), to: AccountCurrency

  @doc """
  The currency the host's stored prices are in, for showing them. See
  `Tymeslot.MeetingPayments.AccountCurrency.account_currency/1`.
  """
  @spec account_currency(integer() | nil) :: String.t()
  defdelegate account_currency(user_id), to: AccountCurrency

  @doc """
  How far meeting payments support an account currency: `:supported`,
  `:legacy` (still charged, but prices cannot be set in it), `:unsupported`
  (no payments) or `:none`. See `Tymeslot.MeetingPayments.Currency.support/1`.
  """
  @spec currency_support(String.t() | nil) :: :supported | :legacy | :unsupported | :none
  defdelegate currency_support(currency), to: Currency, as: :support

  @doc """
  Returns `true` if the given currency code is in the supported allowlist.
  """
  @spec currency_allowed?(String.t()) :: boolean()
  defdelegate currency_allowed?(currency), to: Currency, as: :allowed?

  @doc """
  Returns the minimum charge amount in cents for a currency.
  """
  @spec currency_minimum_cents(String.t()) :: pos_integer()
  defdelegate currency_minimum_cents(currency), to: Currency, as: :minimum_cents

  @doc """
  Changes the host's default currency on their Connect account and resets all
  paid meeting types to free, since their prices were in the old currency.
  See `Tymeslot.MeetingPayments.AccountCurrency.change_default_currency/2`.
  """
  @spec change_default_currency(account(), String.t()) ::
          {:ok, :reset | :no_reset | :unchanged}
          | {:error, :unsupported_currency | :pending_payments_exist}
          | {:error, term()}
  defdelegate change_default_currency(account, currency), to: AccountCurrency
end
