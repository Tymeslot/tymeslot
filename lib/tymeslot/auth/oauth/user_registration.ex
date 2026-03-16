defmodule Tymeslot.Auth.OAuth.UserRegistration do
  @moduledoc """
  Handles finding and creating users from OAuth information.
  """

  require Logger
  alias Tymeslot.Auth.OAuth.TransactionalUserCreation
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.PubSub

  @type provider :: :github | :google | :oauth

  @doc """
  Finds an existing user in the database by OAuth provider information.
  """
  @spec find_existing_user(provider, map()) :: {:ok, map()} | {:error, :not_found}
  def find_existing_user(:github, %{email: email, github_user_id: github_id} = user) do
    user_queries = Config.user_queries_module()
    github_id_int = normalize_github_id(github_id)

    find_user_by_id_or_email(
      user_queries,
      &user_queries.get_user_by_github_id/1,
      github_id_int,
      email,
      is_verified: Map.get(user, :is_verified, false)
    )
  end

  def find_existing_user(:google, %{email: email, google_user_id: google_id} = user) do
    user_queries = Config.user_queries_module()

    find_user_by_id_or_email(
      user_queries,
      &user_queries.get_user_by_google_id/1,
      google_id,
      email,
      is_verified: Map.get(user, :is_verified, false)
    )
  end

  def find_existing_user(:oauth, %{provider_uid: uid} = user) do
    user_queries = Config.user_queries_module()

    case user_queries.get_user_by_provider("oauth", uid) do
      {:ok, found_user} ->
        {:ok, found_user}

      {:error, :not_found} ->
        # Only fall back to email lookup when the IdP has verified the email.
        # Trusting an unverified email would let a rogue IdP claim any address
        # and gain access to an existing account.
        if Map.get(user, :is_verified, false) do
          find_user_by_email(user_queries, Map.get(user, :email))
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a new user from OAuth provider information.
  """
  @spec create_oauth_user(provider, map(), map(), keyword()) :: {:ok, map()} | {:error, any()}
  def create_oauth_user(provider, oauth_user, profile_params \\ %{}, opts \\ []) do
    email_verified = determine_email_verification_status(oauth_user)
    metadata = Keyword.get(opts, :metadata, %{})

    auth_params = build_auth_params(provider, oauth_user, email_verified)

    case TransactionalUserCreation.find_or_create_oauth_user(
           provider,
           auth_params,
           profile_params,
           opts
         ) do
      {:ok, %{user: user, created: true}} ->
        {:ok, updated_user} =
          handle_user_verification_status(user, email_verified, oauth_user.email)

        PubSub.broadcast_user_registered(updated_user, metadata)
        {:ok, updated_user}

      {:ok, %{user: user, created: false}} ->
        case check_oauth_account_linking(provider, user, oauth_user) do
          :should_link_account -> {:ok, user}
          :email_already_taken -> {:error, :email_already_taken}
        end

      {:error, reason} ->
        Logger.error("OAuth user creation failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Checks if the registration is complete for the given provider and user.
  """
  @spec registration_complete?(provider, map()) :: boolean()
  def registration_complete?(:github, %{email: email, github_user_id: id})
      when is_binary(email) and email != "" and is_binary(id) and id != "",
      do: true

  def registration_complete?(:google, %{email: email, google_user_id: id})
      when is_binary(email) and email != "" and is_binary(id) and id != "",
      do: true

  def registration_complete?(:oauth, %{email: email, provider_uid: uid})
      when is_binary(email) and is_binary(uid) and email != "" and uid != "",
      do: true

  def registration_complete?(_provider, _user_data), do: false

  @doc """
  Determines what information is missing for OAuth registration completion.
  """
  @spec check_oauth_requirements(provider, map()) :: {:missing, list(atom())} | :complete
  def check_oauth_requirements(_provider, user) do
    missing = []

    missing =
      if is_binary(user.email) and String.length(String.trim(user.email)) > 0 do
        missing
      else
        [:email | missing]
      end

    missing =
      if Config.enforce_legal_agreements?() do
        [:terms | missing]
      else
        missing
      end

    if missing == [], do: :complete, else: {:missing, Enum.reverse(missing)}
  end

  # Private helpers

  defp normalize_github_id(github_id) do
    case github_id do
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int, ""} -> int
          _other -> nil
        end

      _invalid ->
        nil
    end
  end

  defp find_user_by_id_or_email(user_queries, id_lookup_fn, user_id, email, opts) do
    is_verified = Keyword.get(opts, :is_verified, false)

    if is_integer(user_id) or is_binary(user_id) do
      case id_lookup_fn.(user_id) do
        {:error, :not_found} -> find_user_by_verified_email(user_queries, email, is_verified)
        {:ok, user} -> {:ok, user}
      end
    else
      find_user_by_verified_email(user_queries, email, is_verified)
    end
  end

  defp find_user_by_verified_email(user_queries, email, true = _is_verified) do
    find_user_by_email(user_queries, email)
  end

  defp find_user_by_verified_email(_user_queries, _email, _is_verified) do
    {:error, :not_found}
  end

  defp find_user_by_email(user_queries, email) do
    if email && String.trim(email) != "" do
      user_queries.get_user_by_email(email)
    else
      {:error, :not_found}
    end
  end

  defp determine_email_verification_status(%{email_from_provider: true}), do: true
  defp determine_email_verification_status(%{email_from_provider: false}), do: false

  defp determine_email_verification_status(oauth_user) do
    Map.get(oauth_user, :is_verified, false)
  end

  defp build_auth_params(:oauth, oauth_user, email_verified) do
    %{
      "provider" => "oauth",
      "email" => oauth_user.email,
      "is_verified" => email_verified,
      "provider_uid" => Map.get(oauth_user, :provider_uid),
      "terms_accepted" => to_string(Map.get(oauth_user, :terms_accepted, false))
    }
  end

  defp build_auth_params(provider, oauth_user, email_verified) do
    %{
      "provider" => to_string(provider),
      "email" => oauth_user.email,
      "is_verified" => email_verified,
      "#{provider}_user_id" =>
        Map.get(oauth_user, String.to_existing_atom("#{provider}_user_id")),
      "terms_accepted" => to_string(Map.get(oauth_user, :terms_accepted, false))
    }
  end

  defp handle_user_verification_status(user, false, email) when is_binary(email) do
    {:ok, Map.put(user, :needs_email_verification, true)}
  end

  defp handle_user_verification_status(user, _email_verified, _email), do: {:ok, user}

  # NOTE: All generic OAuth users share provider="oauth" regardless of which IdP
  # issued the credentials. If the admin switches IdPs (e.g., Keycloak → Authentik),
  # `provider_uid` values from the old IdP remain in the database. A new IdP user
  # whose `sub` collides with an old IdP user would be incorrectly matched. Switching
  # IdPs requires clearing stale `provider="oauth"` rows from the users table.
  defp check_oauth_account_linking(:oauth, user, oauth_user) do
    if Map.get(user, :provider_uid) == Map.get(oauth_user, :provider_uid) do
      :should_link_account
    else
      :email_already_taken
    end
  end

  defp check_oauth_account_linking(provider, user, oauth_user) do
    provider_id_field = String.to_existing_atom("#{provider}_user_id")

    if Map.get(user, provider_id_field) == Map.get(oauth_user, provider_id_field) do
      :should_link_account
    else
      :email_already_taken
    end
  end
end
