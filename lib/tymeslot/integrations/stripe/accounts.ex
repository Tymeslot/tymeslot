defmodule Tymeslot.Integrations.Stripe.Accounts do
  @moduledoc """
  Stripe `Accounts` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does.

  Operations, as named in telemetry and test stubs: `retrieve_account`,
  `create_account`, `delete_account`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  `retrieve_account`: a connected account, read through the `Stripe-Account`
  header (the only way to fetch another account's own record). Raises
  `ArgumentError` when `opts` already carries a different `:connect_account`.
  """
  @spec retrieve_connected(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_connected(account_id, opts) do
    case Keyword.get(opts, :connect_account, account_id) do
      ^account_id -> :ok
      other -> raise ArgumentError, "conflicting :connect_account #{inspect(other)}"
    end

    Client.run(
      Request.new(
        :retrieve_account,
        :get,
        ["account"],
        %{},
        Keyword.put(opts, :connect_account, account_id)
      )
    )
  end

  @doc "`create_account`. No feature uses this yet; the live test suite does."
  @spec create(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(params, opts),
    do: Client.run(Request.new(:create_account, :post, ["accounts"], params, opts))

  @doc "`delete_account`. No feature uses this yet; the live test suite does."
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(id, opts),
    do: Client.run(Request.new(:delete_account, :delete, ["accounts", id], %{}, opts))
end
