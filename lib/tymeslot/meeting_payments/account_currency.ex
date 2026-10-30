defmodule Tymeslot.MeetingPayments.AccountCurrency do
  @moduledoc """
  The currency side of a host's Stripe Connect account: which currency
  checkout charges them in, which one their prices are set and shown in,
  whether they may set a price at all, and changing the account's default
  currency. Reached through `Tymeslot.MeetingPayments`.
  """

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.Currency
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Repo

  @doc """
  Returns `true` if the user's Connect account has charges enabled, in a
  currency checkout can charge: an allowlisted one, or a legacy one counted
  in hundredths (see `Tymeslot.MeetingPayments.Currency.support/1`).
  """
  @spec charges_enabled_for_user?(integer()) :: boolean()
  def charges_enabled_for_user?(user_id), do: charge_currency(user_id) != nil

  @doc """
  The currency checkout charges the user in: their live Connect account's
  default currency, while the account has charges enabled in a currency
  checkout can charge (see `charges_enabled_for_user?/1`), and `nil` otherwise.
  This is the currency to show a stored price in to someone about to pay it.
  """
  @spec charge_currency(integer()) :: String.t() | nil
  def charge_currency(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{charges_enabled: true, default_currency: currency} ->
        if Currency.chargeable?(currency), do: currency

      _other ->
        nil
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
    case live_currency(user_id) do
      nil -> Currency.fallback()
      currency -> if Currency.allowed?(currency), do: currency, else: Currency.fallback()
    end
  end

  @doc """
  The currency the host's stored prices are in, for showing them: their live
  Connect account's default currency, whether or not meeting payments
  support it (see `Tymeslot.MeetingPayments.currency_support/1`), or the fallback where
  `host_currency/1` would use it.
  """
  @spec account_currency(integer() | nil) :: String.t()
  def account_currency(nil), do: Currency.fallback()

  def account_currency(user_id) do
    case live_currency(user_id) do
      nil -> Currency.fallback()
      currency -> currency
    end
  end

  # The default currency of the user's live Connect account, or `nil` when
  # there is no such account or it carries no currency yet.
  defp live_currency(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{default_currency: currency} when is_binary(currency) and currency != "" -> currency
      _no_currency -> nil
    end
  end

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
  @spec change_default_currency(ConnectAccountSchema.t(), String.t()) ::
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
end
