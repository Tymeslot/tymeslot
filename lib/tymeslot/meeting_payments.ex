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

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.Currency
  alias Tymeslot.MeetingPayments.DataRetention
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Webhooks.WebhookProcessor
  alias Tymeslot.MeetingPayments.Workers.ResyncConnectAccount
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Repo

  @type account :: ConnectAccountSchema.t()
  @type booking_payment :: BookingPaymentSchema.t()

  # ---------------------------------------------------------------------------
  # Connect account lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts the Stripe Connect onboarding flow for a user.

  Persists a placeholder row before calling Stripe, making the flow
  crash-safe. Returns the Stripe-hosted onboarding URL on success.
  """
  @spec start_onboarding(user :: %{id: integer()}, opts :: keyword()) ::
          {:ok, %{url: String.t(), account: account()}} | {:error, term()}
  defdelegate start_onboarding(user, opts), to: ConnectAccounts

  @doc """
  Soft-deletes the host's Stripe Connect account row.
  """
  @spec disconnect(user :: %{id: integer()}) ::
          {:ok, %{cancelled_count: non_neg_integer()}} | {:error, term()}
  defdelegate disconnect(user), to: ConnectAccounts

  @doc """
  Reconciles a local `connect_accounts` row from a Stripe account snapshot.
  Guards against out-of-order delivery by comparing `event_at` (the event
  emission time for webhooks; the fetch time for a resync) against
  `last_account_event_at`.
  """
  @spec apply_account_event(map(), DateTime.t()) :: :ok
  defdelegate apply_account_event(account, event_at), to: ConnectAccounts

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
  """
  @spec connect_display_state(map() | nil) ::
          :not_connected | :incomplete | :pending_review | :ready | :restricted | :deleted
  def connect_display_state(nil), do: :not_connected
  def connect_display_state(%{deleted_at: dt}) when is_struct(dt, DateTime), do: :deleted
  def connect_display_state(%{details_submitted: true} = account), do: submitted_state(account)
  def connect_display_state(_account), do: :incomplete

  defp submitted_state(%{disabled_reason: reason}) when is_binary(reason), do: :restricted
  defp submitted_state(%{charges_enabled: true, payouts_enabled: true}), do: :ready
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
    key =
      Application.get_env(:tymeslot, :stripe_secret_key) ||
        Application.get_env(:stripity_stripe, :api_key)

    case key do
      nil -> false
      "" -> false
      "sk_test_fake" -> false
      _real -> true
    end
  end

  @doc """
  Returns `true` if the user's Connect account has charges enabled.
  """
  @spec charges_enabled_for_user?(integer()) :: boolean()
  def charges_enabled_for_user?(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{charges_enabled: true} -> true
      _other -> false
    end
  end

  @doc """
  Enqueues a background job to re-sync the Connect account from Stripe.

  Safe to call on every return from the Stripe Express onboarding flow;
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
          reason: inspect(reason)
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
  Returns the total count of pending booking payments for a host.

  Unlike `list_payments_for_host/2`, this is not bounded by any pagination
  limit and always reflects the true pending count across all rows.
  """
  @spec count_pending_payments_for_host(integer()) :: non_neg_integer()
  def count_pending_payments_for_host(host_user_id),
    do: BookingPaymentQueries.count_pending_for_host(host_user_id)

  @doc """
  Returns lifetime payment totals for a host.
  """
  @spec lifetime_stats_for_host(integer()) :: %{
          received: integer(),
          refunded: integer(),
          platform_fee: integer()
        }
  def lifetime_stats_for_host(host_user_id),
    do: BookingPaymentQueries.lifetime_stats(host_user_id)

  @doc """
  Fetches a booking payment by ID, or `nil` if not found.
  """
  @spec get_payment(Ecto.UUID.t()) :: booking_payment() | nil
  def get_payment(id), do: BookingPaymentQueries.get(id)

  @doc """
  Fetches the booking payment for a given meeting, or `nil`.
  """
  @spec payment_for_meeting(Ecto.UUID.t()) :: booking_payment() | nil
  def payment_for_meeting(meeting_id), do: BookingPaymentQueries.by_meeting_id(meeting_id)

  @doc """
  Returns the remaining refundable balance in cents for a booking payment.

  Computes `max(amount_cents - refunded_amount_cents, 0)`.
  """
  @spec refundable_remaining_cents(booking_payment()) :: non_neg_integer()
  defdelegate refundable_remaining_cents(payment), to: Refunds

  @doc """
  Returns `true` when the payment is in a refundable status and was paid
  within the 60-day refund window.
  """
  @spec refundable?(booking_payment()) :: boolean()
  defdelegate refundable?(payment), to: Refunds

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
  Issues a full or partial refund for a booking payment.
  """
  @spec issue_refund(booking_payment(), pos_integer(), String.t() | nil) ::
          {:ok, booking_payment()} | {:error, Refunds.refund_error()}
  defdelegate issue_refund(payment, amount_cents, reason \\ nil), to: Refunds

  # ---------------------------------------------------------------------------
  # Checkout
  # ---------------------------------------------------------------------------

  @doc """
  Creates a Stripe Checkout Session for an `awaiting_payment` meeting.

  Returns the Stripe-hosted checkout URL and the persisted `booking_payment` row.
  """
  @spec create_checkout_session(Tymeslot.Meetings.MeetingSchema.t()) ::
          {:ok, CheckoutSessions.create_result()} | {:error, term()}
  defdelegate create_checkout_session(meeting),
    to: CheckoutSessions,
    as: :create_session_for_booking

  # ---------------------------------------------------------------------------
  # Currency
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of supported currency codes (lowercase ISO 4217).
  """
  @spec currency_allowlist() :: [String.t()]
  defdelegate currency_allowlist(), to: Currency, as: :allowlist

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
  paid meeting types to free.

  Runs atomically. Returns `{:ok, :reset}` when paid meeting types were
  cleared, `{:ok, :no_reset}` when the account had no paid types,
  `{:error, :pending_payments_exist}` when the host has meetings in
  `awaiting_payment` status (the host must resolve those bookings first),
  or `{:error, reason}` on other failures.

  Callers must not call this when `currency` is equal to the account's
  current default currency — they should guard that upstream and skip
  the call entirely.
  """
  @spec change_default_currency(account(), String.t()) ::
          {:ok, :reset | :no_reset}
          | {:error, :pending_payments_exist}
          | {:error, term()}
  def change_default_currency(%ConnectAccountSchema{user_id: user_id} = account, currency) do
    if MeetingQueries.count_awaiting_payment_for_organizer(user_id) > 0 do
      {:error, :pending_payments_exist}
    else
      Repo.transaction(fn ->
        case ConnectAccountQueries.update(account, %{default_currency: currency}) do
          {:ok, _updated} ->
            {count, _rows} = MeetingTypeQueries.clear_payments_for_user(user_id)

            if count > 0, do: :reset, else: :no_reset

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
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

  # ---------------------------------------------------------------------------
  # Webhook processing
  # ---------------------------------------------------------------------------

  @doc """
  Verifies the Stripe-Signature header and dispatches the event to the
  appropriate handler.

  Returns `:ok` on success, `{:error, reason}` on signature failure, replay
  detection, or an unrecognised event.
  """
  @spec process_webhook(payload :: String.t(), signature :: String.t(), secret :: String.t()) ::
          :ok | {:error, term()}
  defdelegate process_webhook(payload, signature, secret), to: WebhookProcessor, as: :process

  # ---------------------------------------------------------------------------
  # Data retention
  # ---------------------------------------------------------------------------

  @doc """
  Anonymises all booking-payment and payment-transaction rows for a host and
  soft-deletes their Connect account. Run before user deletion for GDPR
  Art. 17(3)(b) compliance.
  """
  @spec anonymise_host(integer()) :: :ok | {:error, term()}
  defdelegate anonymise_host(user_id), to: DataRetention
end
