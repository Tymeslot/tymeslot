defmodule Tymeslot.Integrations.Shared.OAuth.PendingFlow do
  @moduledoc """
  PKCE and single-use `state` for the integration OAuth flows (Google
  Calendar and Meet, Outlook, Teams, Zoom).

  Starting a flow stores a random code verifier, encrypted, under a random
  nonce; the nonce travels in the flow's signed `state` and the S256
  challenge of the verifier in the authorisation URL. The callback consumes
  the flow (once, atomically) and presents the verifier with the code, so:

    * a code intercepted on its way back cannot be redeemed without the
      verifier, which never leaves the server (RFC 9700 code injection);
    * a `state` can complete one callback only, instead of any number within
      its hour of validity.

  The flow belongs to the user who started it and to its provider; a nonce
  presented by anyone else, or at another provider's callback, consumes
  nothing.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlowQueries
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlowSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Token

  @behaviour Tymeslot.Security.EncryptedStorage

  # As long as the signed state itself is valid (`State`'s default TTL).
  @ttl_seconds 3600

  # The code verifiers of flows still open, so a key rotation finishes with
  # none of them left on the old key.
  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage, do: {PendingFlowSchema.__schema__(:source), [:code_verifier_encrypted]}

  @typedoc "What a started flow hands the authorisation URL."
  @type started :: %{nonce: String.t(), code_challenge: String.t()}

  @doc """
  Starts a `provider` flow for `user_id` and returns its nonce and code
  challenge.
  """
  @spec start(pos_integer(), atom()) :: {:ok, started()} | {:error, Ecto.Changeset.t()}
  def start(user_id, provider) when is_integer(user_id) and is_atom(provider) do
    nonce = random_token()
    code_verifier = random_token()

    attrs = %{
      nonce: nonce,
      user_id: user_id,
      provider: Atom.to_string(provider),
      code_verifier_encrypted: Encryption.encrypt(code_verifier),
      expires_at: DateTime.add(now(), @ttl_seconds, :second)
    }

    with {:ok, _flow} <- PendingFlowQueries.insert(attrs) do
      {:ok, %{nonce: nonce, code_challenge: code_challenge(code_verifier)}}
    end
  end

  @doc """
  Consumes `user_id`'s `provider` flow `nonce` and returns its code verifier.
  A flow already consumed, expired, or not theirs is `{:error, :flow_not_found}`,
  and so is one whose verifier no configured key opens (its key removed from
  the keyring mid-flow): the user starts the flow again.
  """
  @spec consume(String.t() | nil, pos_integer(), atom()) ::
          {:ok, String.t()} | {:error, :flow_not_found}
  def consume(nonce, user_id, provider) when is_binary(nonce) and is_atom(provider) do
    with {:ok, flow} <-
           PendingFlowQueries.consume(nonce, user_id, Atom.to_string(provider), now()),
         {:ok, code_verifier} when is_binary(code_verifier) <-
           Encryption.decrypt_with_status(flow.code_verifier_encrypted) do
      {:ok, code_verifier}
    else
      _consumed_expired_or_unreadable -> {:error, :flow_not_found}
    end
  end

  def consume(_nonce, _user_id, _provider), do: {:error, :flow_not_found}

  @doc """
  The nonce for the state of the flow started into `options[:pkce]`.
  """
  @spec nonce(keyword()) :: String.t() | nil
  def nonce(options), do: get_in(options, [:pkce, :nonce])

  @doc """
  The authorisation URL parameters for the flow started into
  `options[:pkce]`: its S256 code challenge.
  """
  @spec challenge_params(keyword()) :: map()
  def challenge_params(options) do
    case options[:pkce] do
      %{code_challenge: challenge} -> %{code_challenge: challenge, code_challenge_method: "S256"}
      nil -> %{}
    end
  end

  @doc """
  Adds `opts[:code_verifier]` to a code exchange's form `body`.
  """
  @spec verifier_param(keyword(), map()) :: map()
  def verifier_param(opts, body) do
    case Keyword.get(opts, :code_verifier) do
      nil -> body
      code_verifier -> Map.put(body, :code_verifier, code_verifier)
    end
  end

  @doc """
  Deletes flows past their expiry, consumed or not. Run by the data
  retention sweep.
  """
  @spec prune_expired() :: {non_neg_integer(), nil}
  def prune_expired, do: PendingFlowQueries.delete_expired(now())

  defp now, do: DateTime.truncate(Clock.utc_now(), :second)

  # 32 random bytes, base64url: 43 characters, inside RFC 7636's 43 to 128
  # for a verifier, and free of the `:` and `|` the state's encoding uses.
  defp random_token, do: Token.generate(32)

  defp code_challenge(code_verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
end
