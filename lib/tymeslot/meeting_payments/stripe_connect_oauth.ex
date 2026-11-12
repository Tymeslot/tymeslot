defmodule Tymeslot.MeetingPayments.StripeConnectOAuth do
  @moduledoc """
  Stripe Connect OAuth helper: builds the authorise URL and verifies the
  signed state Stripe hands back on the callback.

  The state carries the user and a nonce. The nonce, stored on the host's
  `connect_accounts` row and claimed atomically before the code exchange, is
  what makes an authorise attempt single use; the token's long expiry only
  bounds how long a host may take to finish Stripe's form.
  """

  alias Tymeslot.SignedToken
  alias TymeslotWeb.Endpoint

  @authorize_url "https://connect.stripe.com/oauth/authorize"
  @callback_path "/dashboard/payments/connect/callback"

  @doc "Whether a Connect client ID is configured, so new connections can start."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:tymeslot, :stripe_connect_client_id) do
      id when is_binary(id) -> String.trim(id) != ""
      _unset -> false
    end
  end

  @doc "Builds the Stripe URL the host is sent to in order to connect an account."
  @spec authorize_url(integer(), String.t()) :: String.t()
  def authorize_url(user_id, nonce) do
    query =
      URI.encode_query(%{
        client_id: Application.fetch_env!(:tymeslot, :stripe_connect_client_id),
        response_type: "code",
        scope: "read_write",
        redirect_uri: redirect_uri(),
        state: SignedToken.sign(:stripe_connect_state, %{user_id: user_id, nonce: nonce})
      })

    "#{@authorize_url}?#{query}"
  end

  @doc "Verifies the state returned by Stripe."
  @spec verify_state(String.t()) ::
          {:ok, %{user_id: integer(), nonce: String.t()}}
          | {:error, :expired_state | :invalid_state}
  def verify_state(state) do
    case SignedToken.verify(:stripe_connect_state, state) do
      {:ok, %{user_id: user_id, nonce: nonce}} when is_integer(user_id) and is_binary(nonce) ->
        {:ok, %{user_id: user_id, nonce: nonce}}

      {:ok, _other} ->
        {:error, :invalid_state}

      {:error, :expired} ->
        {:error, :expired_state}

      {:error, _reason} ->
        {:error, :invalid_state}
    end
  end

  @doc "The callback URL registered as a redirect URI in the Stripe Connect settings."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: Endpoint.url() <> @callback_path
end
