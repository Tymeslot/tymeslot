defmodule Tymeslot.Auth.OAuth.UserProcessor do
  @moduledoc """
  Turns a provider's userinfo into the identity sign-in works with:

      %{provider_uid: "…", email: "…" | nil, email_from_provider: boolean, name: "…" | nil}

  `email` is the provider's address only when the provider vouches for it
  (see `:email` in `Tymeslot.Auth.OAuth.Providers`); an address the provider
  has not verified is dropped, so the user types one and proves it by email
  instead. `email_from_provider` records which of the two happened.
  """

  require Logger

  alias Tymeslot.Auth.OAuth.{Client, Providers}

  @type provider :: Providers.provider()
  @type identity :: %{
          required(:provider_uid) => String.t(),
          required(:email) => String.t() | nil,
          required(:email_from_provider) => boolean(),
          required(:name) => String.t() | nil
        }

  @doc """
  Fetches the userinfo with `token` and normalises it.
  """
  @spec fetch_identity(provider(), String.t()) :: {:ok, identity()} | {:error, term()}
  def fetch_identity(provider, token) do
    with {:ok, user_info} <- Client.fetch_userinfo(provider, token),
         {:ok, provider_uid} <- provider_uid(provider, user_info) do
      {:ok,
       Map.merge(verified_email(provider, user_info, token), %{
         provider_uid: provider_uid,
         name: string_or_nil(Map.get(user_info, "name"))
       })}
    end
  end

  defp provider_uid(provider, user_info) when is_map(user_info) do
    case Enum.find_value(uid_claims(provider), &Map.get(user_info, &1)) do
      uid when is_integer(uid) -> {:ok, Integer.to_string(uid)}
      uid when is_binary(uid) and uid != "" -> {:ok, uid}
      _missing -> missing_uid(provider)
    end
  end

  defp provider_uid(_provider, _user_info), do: {:error, :invalid_user_info}

  # Non-OIDC providers may return "id" or "user_id" instead of the standard
  # "sub" claim. These identifiers are not standardised and can collide across
  # identity providers, so they are only accepted when the admin opts in with
  # OAUTH_ALLOW_ID_FALLBACK=true.
  defp uid_claims(:oauth) do
    claims = Providers.fetch!(:oauth).uid_claims
    if allow_id_fallback?(), do: claims ++ ["id", "user_id"], else: claims
  end

  defp uid_claims(provider), do: Providers.fetch!(provider).uid_claims

  defp missing_uid(:oauth) do
    Logger.error(
      "OAuth provider returned no usable \"sub\" claim",
      id_fallback_enabled: allow_id_fallback?()
    )

    {:error, :invalid_user_info}
  end

  defp missing_uid(_provider), do: {:error, :invalid_user_info}

  defp verified_email(provider, user_info, token) do
    case Providers.fetch!(provider).email do
      {:claim, claim} ->
        vouched(
          string_or_nil(Map.get(user_info, "email")),
          Map.get(user_info, claim) in [true, "true"]
        )

      {:emails_endpoint, url} ->
        vouched(listed_verified_email(provider, url, token), true)
    end
  end

  # The primary address when the provider has verified it, otherwise any
  # verified one. A failed request leaves the user to type an address.
  defp listed_verified_email(provider, url, token) do
    case Client.get(provider, url, token) do
      {:ok, emails} when is_list(emails) ->
        verified = Enum.filter(emails, &(is_map(&1) and &1["verified"] == true))
        primary = Enum.find(verified, &(&1["primary"] == true))
        string_or_nil((primary || List.first(verified) || %{})["email"])

      other ->
        Logger.warning("Could not read the provider's email addresses",
          provider: to_string(provider),
          reason: inspect(other)
        )

        nil
    end
  end

  defp vouched(email, true) when is_binary(email), do: %{email: email, email_from_provider: true}
  defp vouched(_email, _verified), do: %{email: nil, email_from_provider: false}

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp allow_id_fallback? do
    :tymeslot
    |> Application.get_env(:oauth_provider, [])
    |> Keyword.get(:allow_id_fallback, false)
  end
end
