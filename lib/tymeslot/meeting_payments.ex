defmodule Tymeslot.MeetingPayments do
  @moduledoc """
  Main entry point for meeting-payments operations.

  Provides a high-level interface covering Stripe Connect onboarding,
  booking payments, refunds, currency management, and data retention.
  All external callers (web, workers, email templates, cross-domain
  modules, SaaS) must interact with this module — never with submodules
  directly.

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
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.CheckoutOutcome
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.Currency
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Workers.ResyncConnectAccount
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Payments.Config, as: PaymentsConfig
  alias Tymeslot.Repo

  @type account :: ConnectAccountSchema.t()
  @type booking_payment :: BookingPaymentSchema.t()

  @typedoc """
  How many refunds a host still owes, and how much of each currency.
  """
  @type outstanding_refunds_summary :: %{
          count: non_neg_integer(),
          totals: [%{currency: String.t(), amount_cents: non_neg_integer()}]
        }

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
  Starts the Stripe Connect onboarding flow for a user.

  Enforces the meeting-payments feature gate, persists a placeholder row
  before calling Stripe (making the flow crash-safe), and reuses a Stripe
  account the host already has. Returns the Stripe-hosted onboarding URL on
  success; on failure, a `Tymeslot.Features.check_access/2` reason,
  `{:error, :account_creation_restricted}`, or the underlying Stripe error.
  """
  @spec start_onboarding(user :: %{id: integer()}) ::
          {:ok, %{url: String.t(), account: account()}} | {:error, term()}
  defdelegate start_onboarding(user), to: ConnectAccounts

  @doc """
  Soft-deletes the host's Stripe Connect account row.
  """
  @spec disconnect(user :: %{id: integer()}) ::
          {:ok, disconnect_result()} | {:error, term()}
  defdelegate disconnect(user), to: ConnectAccounts

  @doc """
  Expires the host's open Stripe Checkout sessions and cancels their pending
  bookings, leaving the Connect account in place. See
  `Tymeslot.MeetingPayments.ConnectAccounts.cancel_pending_checkouts/1`.
  """
  @spec cancel_pending_checkouts(user :: %{id: integer()}) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate cancel_pending_checkouts(user), to: ConnectAccounts

  # ---------------------------------------------------------------------------
  # Bookings held for payment
  # ---------------------------------------------------------------------------

  @doc """
  The PubSub topic carrying a meeting's payment status changes. Subscribers
  receive the bare atoms `:paid` and `:expired`.
  """
  @spec payment_topic(String.t()) :: String.t()
  defdelegate payment_topic(meeting_id), to: HeldMeetings, as: :topic

  @doc """
  Releases a booking held for payment, inside the caller's transaction and
  after its payment has been locked or claimed. See
  `Tymeslot.MeetingPayments.HeldMeetings.expire/1`.
  """
  @spec expire_held_meeting(String.t() | nil) ::
          {:ok, :expired, MeetingSchema.t()}
          | {:ok, :unchanged}
          | {:error, Ecto.Changeset.t()}
  defdelegate expire_held_meeting(meeting_id), to: HeldMeetings, as: :expire

  @doc """
  After the transaction that released a held booking has committed, offers
  its slot again and tells the waiting attendee it expired.
  """
  @spec announce_expired(MeetingSchema.t()) :: :ok
  defdelegate announce_expired(meeting), to: HeldMeetings

  @doc """
  Fetches a Connect account by its row ID, or `nil` if not found.
  """
  @spec get_connect_account(Ecto.UUID.t()) :: account() | nil
  def get_connect_account(id), do: ConnectAccountQueries.get(id)

  @doc """
  Returns the live (non-deleted) Connect account for a user, or `nil`.
  """
  @spec get_connect_account_for_user(integer()) :: account() | nil
  def get_connect_account_for_user(user_id),
    do: ConnectAccountQueries.live_for_user(user_id)

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
  currency checkout can charge: an allowlisted one, or a legacy one counted
  in hundredths (see `Currency.support/1`).
  """
  @spec charges_enabled_for_user?(integer()) :: boolean()
  def charges_enabled_for_user?(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{charges_enabled: true, default_currency: currency} -> Currency.chargeable?(currency)
      _other -> false
    end
  end

  @doc """
  Returns `true` if the user may set or change a meeting type's price: their
  Connect account has charges enabled in an allowlisted currency. A legacy
  currency is still charged at checkout (`charges_enabled_for_user?/1`), but
  no new price is set in it.
  """
  @spec price_settable?(integer() | nil) :: boolean()
  def price_settable?(nil), do: false

  def price_settable?(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{charges_enabled: true, default_currency: currency} ->
        Currency.support(currency) == :supported

      _other ->
        false
    end
  end

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
  # Booking payments
  # ---------------------------------------------------------------------------

  @doc """
  Lists recent booking payments for a host, newest first.
  """
  @spec list_payments_for_host(integer(), keyword()) :: [booking_payment()]
  def list_payments_for_host(host_user_id, opts \\ []),
    do: BookingPaymentQueries.for_host(host_user_id, opts)

  @doc """
  Lists the host's cancelled bookings that still hold the attendee's money,
  and expired ones paid after their slot was taken. Oldest first, by when
  the booking was cancelled, or by when it was paid for one that never was
  (an expired booking), with ties broken by payment id.

  Not bounded by `list_payments_for_host/2`'s recent-payments window, so an
  older unrefunded cancellation stays visible instead of scrolling out of
  sight.
  """
  @spec list_outstanding_refunds_for_host(integer(), keyword()) :: [booking_payment()]
  def list_outstanding_refunds_for_host(host_user_id, opts \\ []),
    do: BookingPaymentQueries.outstanding_refunds_for_host(host_user_id, opts)

  @doc """
  Summarises the host's outstanding refunds: how many there are, and how much
  is owed in each currency.

  Unbounded, unlike `list_outstanding_refunds_for_host/2`, so a caller can say
  "showing 50 of 63" instead of truncating in silence, and so the disconnect
  confirmation can name what the host is about to walk away from.
  """
  @spec outstanding_refunds_summary_for_host(integer()) :: outstanding_refunds_summary()
  def outstanding_refunds_summary_for_host(host_user_id),
    do: BookingPaymentQueries.outstanding_refunds_summary_for_host(host_user_id)

  @doc """
  Returns the total count of pending booking payments for a host.

  Unlike `list_payments_for_host/2`, this is not bounded by any pagination
  limit and always reflects the true pending count across all rows.
  """
  @spec count_pending_payments_for_host(integer()) :: non_neg_integer()
  def count_pending_payments_for_host(host_user_id),
    do: BookingPaymentQueries.count_pending_for_host(host_user_id)

  @doc """
  Returns lifetime payment totals for a host, one entry per currency.
  """
  @spec lifetime_stats_for_host(integer()) :: [
          %{
            currency: String.t(),
            received: integer(),
            refunded: integer(),
            platform_fee: integer()
          }
        ]
  def lifetime_stats_for_host(host_user_id),
    do: BookingPaymentQueries.lifetime_stats(host_user_id)

  @doc """
  Fetches a booking payment by ID, or `nil` if not found.

  Unscoped: for workers and system rules only. A lookup driven by a signed-in
  user must use `get_payment_for_host/2`.
  """
  @spec get_payment(Ecto.UUID.t()) :: booking_payment() | nil
  def get_payment(id), do: BookingPaymentQueries.get(id)

  @doc """
  Fetches a booking payment by ID only if `host_user_id` took it.

  Another host's payment, an unknown id and a malformed id all return
  `{:error, :not_found}`, so the answer discloses nothing about payments the
  caller does not own.
  """
  @spec get_payment_for_host(term(), integer()) ::
          {:ok, booking_payment()} | {:error, :not_found}
  def get_payment_for_host(id, host_user_id) do
    case BookingPaymentQueries.get_for_host(id, host_user_id) do
      nil -> {:error, :not_found}
      payment -> {:ok, payment}
    end
  end

  @doc """
  Fetches the booking payment for a given meeting, or `nil`.

  Unscoped: for system rules only. A lookup on behalf of a signed-in user must
  use `payment_for_meeting/2`.
  """
  @spec payment_for_meeting(Ecto.UUID.t()) :: booking_payment() | nil
  def payment_for_meeting(meeting_id), do: BookingPaymentQueries.by_meeting_id(meeting_id)

  @doc """
  Fetches the booking payment for a meeting only if `host_user_id` took it,
  or `nil`.

  Someone else who can see the meeting (its attendee, for instance) gets `nil`,
  exactly as for an unpaid meeting: the payment is the host's business.
  """
  @spec payment_for_meeting(term(), integer()) :: booking_payment() | nil
  def payment_for_meeting(meeting_id, host_user_id),
    do: BookingPaymentQueries.by_meeting_id_for_host(meeting_id, host_user_id)

  @doc """
  Returns the remaining refundable balance in cents for a booking payment.

  Computes `max(amount_cents - refunded_amount_cents, 0)`.
  """
  @spec refundable_remaining_cents(booking_payment()) :: non_neg_integer()
  defdelegate refundable_remaining_cents(payment), to: Refunds

  @doc """
  Returns `true` when the payment still owes the attendee money and was paid
  within the 60-day refund window.
  """
  @spec refundable?(booking_payment() | nil) :: boolean()
  defdelegate refundable?(payment), to: Refunds

  @doc """
  Returns `true` when the host still holds money the attendee has not been
  given back, regardless of whether the 60-day window has passed.
  """
  @spec refund_outstanding?(booking_payment() | nil) :: boolean()
  defdelegate refund_outstanding?(payment), to: Refunds

  @doc """
  Parses raw refund-form params into a validated `{:ok, pos_integer()}` or
  a tagged `{:error, atom()}`.

  Accepts the standard `"refund_type"` param shape used by the payments UI.
  Error atoms: `:choose_type`, `:invalid_amount`, `:exceeds_remaining`.
  """
  @spec parse_refund_amount(booking_payment(), map()) ::
          {:ok, pos_integer()} | {:error, :invalid_amount | :exceeds_remaining | :choose_type}
  defdelegate parse_refund_amount(payment, params), to: Refunds

  @doc """
  Issues a full or partial refund for a booking payment, whoever took it.

  Unscoped: for system rules that refund with no acting user, such as
  releasing the payment for a request that was never approved. A refund a
  signed-in user asks for must go through `refund_payment_for_host/4`.
  """
  @spec issue_refund(booking_payment(), pos_integer(), String.t() | nil) ::
          {:ok, booking_payment()} | {:error, Refunds.refund_error()}
  defdelegate issue_refund(payment, amount_cents, reason \\ nil), to: Refunds

  @doc """
  Refunds a booking payment on behalf of the host who took it.

  Only that host may refund it. Ownership is decided under the payment's row
  lock, in the same transaction as the refund itself. Another host's payment,
  an unknown id and a malformed id all return `{:error, :not_found}`.
  """
  @spec refund_payment_for_host(term(), integer(), pos_integer(), String.t() | nil) ::
          {:ok, booking_payment()} | {:error, :not_found | Refunds.refund_error()}
  defdelegate refund_payment_for_host(payment_id, host_user_id, amount_cents, reason \\ nil),
    to: Refunds,
    as: :issue_host_refund

  # ---------------------------------------------------------------------------
  # Checkout
  # ---------------------------------------------------------------------------

  @doc """
  Creates a Stripe Checkout Session for an `awaiting_payment` meeting.

  Returns the Stripe-hosted checkout URL and the persisted `booking_payment` row.
  """
  @spec create_checkout_session(MeetingSchema.t()) ::
          {:ok, CheckoutSessions.create_result()} | {:error, term()}
  defdelegate create_checkout_session(meeting),
    to: CheckoutSessions,
    as: :create_session_for_booking

  @doc """
  What an attendee returning from Stripe Checkout should be told about their
  booking: still `:processing`, `:failed`, `:awaiting_approval`, `:declined`,
  `:expired`, `:confirmed` or `:cancelled`. See `CheckoutOutcome` for the rules.
  """
  @spec checkout_outcome(booking_payment() | nil, MeetingSchema.t() | nil) ::
          CheckoutOutcome.t()
  defdelegate checkout_outcome(payment, meeting), to: CheckoutOutcome, as: :classify

  # ---------------------------------------------------------------------------
  # Currency
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of supported currency codes (lowercase ISO 4217).
  """
  @spec currency_allowlist() :: [String.t()]
  defdelegate currency_allowlist(), to: Currency, as: :allowlist

  @doc """
  Returns the host's pricing currency: the default currency of their live
  (non-deleted) Connect account, or the fallback currency when there is no
  such account, the account carries no currency yet or one outside the
  allowlist, or there is no user. This is the currency new prices are set
  and checked against; `account_currency/1` is the one stored prices are
  shown in.

  Checkout charges the account's currency directly and never reaches the
  fallback; the fallback only labels prices and minimums shown to a host who
  cannot currently set them.
  """
  @spec host_currency(integer() | nil) :: String.t()
  def host_currency(nil), do: Currency.fallback()

  def host_currency(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{default_currency: currency} when is_binary(currency) and currency != "" ->
        if Currency.allowed?(currency), do: currency, else: Currency.fallback()

      _no_currency ->
        Currency.fallback()
    end
  end

  @doc """
  The currency the host's stored prices are in, for showing them: their live
  Connect account's default currency, whether or not meeting payments
  support it (see `currency_support/1`), or the fallback where
  `host_currency/1` would use it.
  """
  @spec account_currency(integer() | nil) :: String.t()
  def account_currency(nil), do: Currency.fallback()

  def account_currency(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{default_currency: currency} when is_binary(currency) and currency != "" -> currency
      _no_currency -> Currency.fallback()
    end
  end

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

  Returns `{:ok, :reset}` when paid meeting types were cleared, `{:ok,
  :no_reset}` when the account had none, `{:ok, :unchanged}` when `currency`
  is already the account's, `{:error, :unsupported_currency}` for a currency
  outside the allowlist, `{:error, :pending_payments_exist}` while the host
  has meetings awaiting payment (they must be resolved first), or
  `{:error, reason}` on other failures.

  The account row is locked for the whole change, as a checkout locks it to
  read the currency and price (`CheckoutSessions`), so a booking either
  starts its checkout first, and then counts as awaiting payment here, or
  finds its meeting type already free.
  """
  @spec change_default_currency(account(), String.t()) ::
          {:ok, :reset | :no_reset | :unchanged}
          | {:error, :unsupported_currency | :pending_payments_exist}
          | {:error, term()}
  def change_default_currency(%ConnectAccountSchema{user_id: user_id}, currency) do
    if Currency.allowed?(currency) do
      Repo.transaction(fn ->
        case change_locked_currency(ConnectAccountQueries.lock_live_for_user(user_id), currency) do
          {:ok, outcome} -> outcome
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :unsupported_currency}
    end
  end

  defp change_locked_currency(nil, _currency), do: {:error, :not_found}

  defp change_locked_currency(%{default_currency: currency}, currency), do: {:ok, :unchanged}

  defp change_locked_currency(%ConnectAccountSchema{user_id: user_id} = account, currency) do
    with :ok <- check_no_pending_payments(user_id),
         {:ok, _updated} <- ConnectAccountQueries.update(account, %{default_currency: currency}) do
      {count, _rows} = MeetingTypeQueries.clear_payments_for_user(user_id)
      {:ok, if(count > 0, do: :reset, else: :no_reset)}
    end
  end

  defp check_no_pending_payments(user_id) do
    if MeetingQueries.count_awaiting_payment_for_organizer(user_id) > 0,
      do: {:error, :pending_payments_exist},
      else: :ok
  end

  # ---------------------------------------------------------------------------
  # Stripe receipt URL
  # ---------------------------------------------------------------------------

  @doc """
  Fetches the Stripe-hosted receipt URL for a charge via the Connect API.

  Returns `{:ok, url}` when a URL is present, `{:ok, nil}` when the charge
  has no receipt URL, or `{:error, reason}` when the Stripe call fails.
  """
  @spec retrieve_charge_receipt_url(charge_id :: String.t(), account_id :: String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def retrieve_charge_receipt_url(charge_id, account_id) do
    # The adapter normalises every read response to a string-keyed map, so the
    # receipt URL lives under the "receipt_url" string key regardless of whether
    # the production stripity struct or a Mox stub produced it.
    case StripeAdapter.retrieve_charge(charge_id, connect_account: account_id) do
      {:ok, %{"receipt_url" => url}} when is_binary(url) and url != "" -> {:ok, url}
      {:ok, _other} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
