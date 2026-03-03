defmodule Tymeslot.Auth.OAuth.UserProcessor do
  @moduledoc """
  Processes user information returned from OAuth providers.
  """

  @type provider :: :github | :google | :oauth

  @doc """
  Processes the raw user info from the provider into a normalized user map.
  """
  @spec process_user(provider, map()) :: {:ok, map()} | {:error, :invalid_user_info}
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
    email = extract_email(user_info)
    email_from_provider = email != nil and String.trim(email) != ""

    user = %{
      email: email,
      provider_uid: to_string(provider_uid),
      name: Map.get(user_info, "name"),
      is_verified: Map.get(user_info, "email_verified", false) == true,
      email_from_provider: email_from_provider
    }

    {:ok, user}
  end

  def process_user(_provider, _user_info), do: {:error, :invalid_user_info}

  @doc """
  Enhances user data with additional information (e.g., fetching GitHub emails).
  """
  @spec enhance_user_data(provider, map(), OAuth2.Client.t()) :: map()
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
          end

        Map.put(user, :email_from_provider, email_provided)

      _existing_flag ->
        user
    end
  end

  # Private helpers

  defp extract_email(user_info) do
    case Map.get(user_info, "email") do
      nil -> nil
      "" -> nil
      email when is_binary(email) -> email
    end
  end

  defp get_github_user_emails(client) do
    # This logic is currently in OauthHelper, but we can move it here or keep it delegated.
    # For now, let's assume we'll use the one in Client if we move it there,
    # but since OauthHelper is the one being refactored, we'll implement it here for now.
    alias Tymeslot.Auth.OAuth.Client
    client = Client.with_auth_header(client, :github)

    case OAuth2.Client.get(client, "https://api.github.com/user/emails") do
      {:ok, %OAuth2.Response{body: body}} -> parse_user_emails_body(body)
      err -> err
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
