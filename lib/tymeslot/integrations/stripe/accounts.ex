defmodule Tymeslot.Integrations.Stripe.Accounts do
  @moduledoc """
  Stripe `Accounts` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `retrieve_account`, `create_account`, `delete_account`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Retrieves a connected account (GET /v1/account) through the `Stripe-Account`
  header, the only way to read another account's own record. `opts` may carry
  an equal `:connect_account`; a different one raises `ArgumentError`.
  """
  @spec retrieve_connected(String.t(), keyword()) :: Client.result()
  def retrieve_connected(account_id, opts \\ []) do
    case Keyword.get(opts, :connect_account, account_id) do
      ^account_id -> :ok
      other -> raise ArgumentError, "conflicting :connect_account #{inspect(other)}"
    end

    request =
      Request.new(
        :retrieve_account,
        :get,
        ["account"],
        %{},
        Keyword.put(opts, :connect_account, account_id)
      )

    Client.run(request)
  end

  @doc """
  Creates an account (POST /v1/accounts). No feature uses this yet; the live test suite does.
  """
  @spec create(map() | keyword(), keyword()) :: Client.result()
  def create(params, opts \\ []) do
    Client.run(Request.new(:create_account, :post, ["accounts"], params, opts))
  end

  @doc """
  Deletes an account (DELETE /v1/accounts/:id). No feature uses this yet; the live test suite does.
  """
  @spec delete(String.t(), keyword()) :: Client.result()
  def delete(id, opts \\ []) do
    Client.run(Request.new(:delete_account, :delete, ["accounts", id], %{}, opts))
  end
end
