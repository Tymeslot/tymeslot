defmodule Tymeslot.Auth.OAuth.UserProcessor do
  @moduledoc """
  Processes user information returned from OAuth providers.
  """

  require Logger

  alias Tymeslot.Auth.OAuth.Client

  @type provider :: :github | :google | :oauth
  @type normalized_user :: %{
          required(:email) => String.t() | nil,
          required(:name) => String.t() | nil,
          required(:is_verified) => boolean(),
          required(:email_from_provider) => boolean(),
          optional(:github_user_id) => String.t() | integer(),
          optional(:google_user_id) => String.t(),
          optional(:provider_uid) => String.t()
        }

  @doc """
  Processes the raw user info from the provider into a normalized user map.
  """
  @spec process_user(provider(), map()) :: {:ok, normalized_user()} | {:error, :invalid_user_info}
  def process_user(:github, %{"id" => github_user_id} = user_info) do
    email = extract_email(user_info)
    email_from_provider = email != nil and String.trim(email) != ""

    user = %{
      email: email,
      github_user_id: github_user_id,
      name: Map.get(user_info, "name"),
      is_verified: true,
      email_from_provider: email_from_provider
    }

    {:ok, user}
  end

  def process_user(:google, %{"email" => email, "id" => google_user_id} = user_info) do
    user = %{
      email: email,
      google_user_id: google_user_id,
      name: Map.get(user_info, "name"),
      is_verified: true,
      email_from_provider: true
    }

    {:ok, user}
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
  Enhances user data with additional information (e.g., fetching GitHub emails).
  """
  @spec enhance_user_data(provider(), normalized_user(), OAuth2.Client.t()) :: normalized_user()
  def enhance_user_data(:github, %{email: email} = user, client)
      when is_nil(email) or email == "" do
    case get_github_user_emails(client) do
      {:ok, emails} when is_list(emails) ->
        add_github_email_to_user(user, emails)

      {:error, _error_reason} ->
        Map.put(user, :email_from_provider, false)
    end
  end

  def enhance_user_data(_provider, user, _client) do
    case Map.get(user, :email_from_provider) do
      nil ->
        email_provided =
          case user.email do
            nil -> false
            "" -> false
            email when is_binary(email) -> String.trim(email) != ""
            _other -> false
          end

        Map.put(user, :email_from_provider, email_provided)

      _existing_flag ->
        user
    end
  end

  @doc """
  Fetches the authenticated user's email addresses from the GitHub API.
  """
  @spec get_github_user_emails(OAuth2.Client.t()) :: {:ok, list(map())} | {:error, any()}
  def get_github_user_emails(client) do
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
      email = extract_email(user_info)
      email_from_provider = email != nil and String.trim(email) != ""

      user = %{
        email: email,
        provider_uid: uid_string,
        name: Map.get(user_info, "name"),
        is_verified: Map.get(user_info, "email_verified", false) in [true, "true"],
        email_from_provider: email_from_provider
      }

      {:ok, user}
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

  defp add_github_email_to_user(user, emails) do
    primary_email = find_primary_email(emails)
    verified_email = primary_email || find_verified_email(emails)

    case extract_email_address(primary_email, verified_email) do
      {:ok, email} -> %{user | email: email, email_from_provider: true}
      :error -> Map.put(user, :email_from_provider, false)
    end
  end

  defp find_primary_email(emails) do
    Enum.find(emails, fn email ->
      Map.get(email, "primary", false) && Map.get(email, "verified", false)
    end)
  end

  defp find_verified_email(emails) do
    Enum.find(emails, fn email ->
      Map.get(email, "verified", false)
    end)
  end

  defp extract_email_address(%{"email" => email}, _fallback) when is_binary(email),
    do: {:ok, email}

  defp extract_email_address(_primary, %{"email" => email}) when is_binary(email),
    do: {:ok, email}

  defp extract_email_address(_primary, _fallback), do: :error
end
