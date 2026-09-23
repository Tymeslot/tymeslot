defmodule Tymeslot.Auth.OAuth.UserProcessor do
  @moduledoc """
  Processes user information returned from OAuth providers.
  """

  require Logger

  alias Tymeslot.Auth.OAuth.Client

  @type provider :: :github | :google | :oauth
  # `email` is the provider's address only when the provider vouches for it
  # (GitHub's verified list, Google's `verified_email`, the OIDC
  # `email_verified` claim); an address the provider has not verified is
  # dropped, so the user types one and proves it by email instead.
  # `email_from_provider` records which of the two happened.
  @type normalized_user :: %{
          required(:email) => String.t() | nil,
          required(:name) => String.t() | nil,
          required(:email_from_provider) => boolean(),
          optional(:github_user_id) => String.t(),
          optional(:google_user_id) => String.t(),
          optional(:provider_uid) => String.t()
        }

  @doc """
  Processes the raw user info from the provider into a normalized user map.

  GitHub's `/user` email is ignored here: whether it is verified is only
  known from `/user/emails`, which `enhance_user_data/3` reads.
  """
  @spec process_user(provider(), map()) :: {:ok, normalized_user()} | {:error, :invalid_user_info}
  def process_user(:github, %{"id" => github_user_id} = user_info)
      when is_integer(github_user_id) or is_binary(github_user_id) do
    {:ok,
     Map.merge(vouched_email(nil, false), %{
       github_user_id: to_string(github_user_id),
       name: Map.get(user_info, "name")
     })}
  end

  def process_user(:google, %{"id" => google_user_id} = user_info)
      when is_binary(google_user_id) do
    email = extract_email(user_info)

    {:ok,
     Map.merge(vouched_email(email, Map.get(user_info, "verified_email") == true), %{
       google_user_id: google_user_id,
       name: Map.get(user_info, "name")
     })}
  end

  def process_user(:oauth, %{"sub" => provider_uid} = user_info) do
    build_oauth_user(user_info, provider_uid)
  end

  def process_user(:oauth, user_info) when is_map(user_info) do
    # Non-OIDC providers may return "id" or "user_id" instead of the standard
    # "sub" claim. Because these identifiers are not standardized, they can
    # collide across different IdPs. Only accept them when the admin has
    # explicitly opted in via OAUTH_ALLOW_ID_FALLBACK=true.
    if allow_id_fallback?() do
      case Map.get(user_info, "id") || Map.get(user_info, "user_id") do
        nil ->
          {:error, :invalid_user_info}

        uid ->
          Logger.warning(
            "OAuth provider returned no \"sub\" claim; falling back to alternative ID",
            key_used: if(Map.has_key?(user_info, "id"), do: "id", else: "user_id")
          )

          build_oauth_user(user_info, uid)
      end
    else
      Logger.error(
        "OAuth provider did not return a \"sub\" claim and OAUTH_ALLOW_ID_FALLBACK is not enabled"
      )

      {:error, :invalid_user_info}
    end
  end

  def process_user(_provider, _user_info), do: {:error, :invalid_user_info}

  @doc """
  Adds what the first userinfo response cannot carry: for GitHub, the
  primary verified address from `/user/emails`.
  """
  @spec enhance_user_data(provider(), normalized_user(), OAuth2.Client.t()) :: normalized_user()
  def enhance_user_data(:github, user, client) do
    case get_github_user_emails(client) do
      {:ok, emails} when is_list(emails) ->
        Map.merge(user, vouched_email(verified_github_email(emails), true))

      {:error, reason} ->
        Logger.warning("Could not read GitHub email addresses", reason: inspect(reason))
        user
    end
  end

  def enhance_user_data(_provider, user, _client), do: user

  # Fetches the authenticated user's email addresses from the GitHub API.
  @spec get_github_user_emails(OAuth2.Client.t()) :: {:ok, list(map())} | {:error, any()}
  defp get_github_user_emails(client) do
    client = Client.with_auth_header(client, :github)

    case OAuth2.Client.get(client, "https://api.github.com/user/emails") do
      {:ok, %OAuth2.Response{body: body}} -> parse_user_emails_body(body)
      err -> err
    end
  end

  # Private helpers

  defp allow_id_fallback? do
    config = Application.get_env(:tymeslot, :oauth_provider, [])
    Keyword.get(config, :allow_id_fallback, false)
  end

  defp build_oauth_user(user_info, provider_uid)
       when is_binary(provider_uid) or is_integer(provider_uid) do
    uid_string = to_string(provider_uid)

    if uid_string == "" do
      {:error, :invalid_user_info}
    else
      # A missing `email_verified` claim counts as unverified: nothing then
      # vouches for the address.
      verified = Map.get(user_info, "email_verified") in [true, "true"]

      {:ok,
       Map.merge(vouched_email(extract_email(user_info), verified), %{
         provider_uid: uid_string,
         name: Map.get(user_info, "name")
       })}
    end
  end

  defp build_oauth_user(_user_info, _provider_uid), do: {:error, :invalid_user_info}

  defp extract_email(user_info) do
    case Map.get(user_info, "email") do
      nil -> nil
      "" -> nil
      email when is_binary(email) -> email
      _other -> nil
    end
  end

  defp parse_user_emails_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _other} -> {:error, {:unexpected_body, body}}
      {:error, %Jason.DecodeError{} = err} -> {:error, err}
    end
  end

  defp parse_user_emails_body(body) when is_list(body), do: {:ok, body}
  defp parse_user_emails_body(other), do: {:error, {:unexpected_body, other}}

  defp vouched_email(email, true) when is_binary(email),
    do: %{email: email, email_from_provider: true}

  defp vouched_email(_email, _verified), do: %{email: nil, email_from_provider: false}

  # The primary address when GitHub has verified it, otherwise any verified one.
  defp verified_github_email(emails) do
    verified = Enum.filter(emails, &(Map.get(&1, "verified") == true))
    primary = Enum.find(verified, &(Map.get(&1, "primary") == true))

    case primary || List.first(verified) do
      %{"email" => email} when is_binary(email) and email != "" -> email
      _none -> nil
    end
  end
end
