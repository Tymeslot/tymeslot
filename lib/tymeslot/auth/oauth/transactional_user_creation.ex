defmodule Tymeslot.Auth.OAuth.TransactionalUserCreation do
  @moduledoc """
  Handles OAuth user creation with proper transaction support to prevent race conditions.

  This module ensures that checking for existing users and creating new users
  happens atomically within a database transaction.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias Tymeslot.DatabaseQueries.{ProfileQueries, UserQueries}
  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.Repo

  @doc """
  Finds or creates an OAuth user within a transaction.

  This is useful when you want to either get an existing user or create a new one
  atomically. Prevents duplicate user creation in high-concurrency scenarios.

  ## Parameters
  - provider: The OAuth provider (:github or :google)
  - auth_params: Map containing user authentication parameters

  ## Returns
  - {:ok, %{user: user, created: boolean}} where created indicates if user was newly created
  - {:error, reason} on failure
  """
  @spec find_or_create_oauth_user(atom(), map(), map(), keyword()) ::
          {:ok, %{user: UserSchema.t(), created: boolean()}}
          | {:error, any()}
  def find_or_create_oauth_user(provider, auth_params, profile_params \\ %{}, _opts \\ []) do
    provider_field = provider_uid_field(provider)
    provider_uid = auth_params[provider_field]

    result =
      UserQueries.transaction(fn ->
        with {:ok, {user, created}} <-
               find_or_create_by_provider(Repo, provider, provider_uid, auth_params),
             {:ok, _result} <- ensure_profile(Repo, user, created, profile_params) do
          {user, created}
        else
          {:error, {operation, reason}} ->
            UserQueries.rollback({operation, reason})
        end
      end)

    case result do
      {:ok, {user, created}} ->
        {:ok, %{user: user, created: created}}

      {:error, {operation, reason}} ->
        Logger.error("OAuth find_or_create failed", operation: operation, reason: inspect(reason))
        {:error, reason}
    end
  end

  # Private functions

  defp ensure_profile(repo, user, true, profile_params) do
    create_profile(repo, user, profile_params)
  end

  defp ensure_profile(_repo, _user, false, _profile_params), do: {:ok, :existing}

  defp create_profile(repo, user, profile_params) do
    # Use the repo passed in to ensure we're in the same transaction
    profile_attrs = %{user_id: user.id}

    # Add full_name from profile_params if provided
    profile_attrs =
      case profile_params[:full_name] do
        name when is_binary(name) and name != "" ->
          Map.put(profile_attrs, :full_name, String.trim(name))

        _other ->
          profile_attrs
      end

    case ProfileQueries.create_profile_in_transaction(repo, profile_attrs) do
      {:ok, profile} ->
        Logger.info("Created profile", user_id: user.id)
        {:ok, profile}

      {:error, reason} ->
        Logger.error("Profile creation failed", user_id: user.id, reason: inspect(reason))
        {:error, {:create_profile, reason}}
    end
  end

  defp find_or_create_by_provider(repo, provider, provider_uid, auth_params) do
    case find_user_by_provider(repo, provider, provider_uid) do
      {:error, :not_found} ->
        handle_user_not_found_by_provider(repo, provider, provider_uid, auth_params)

      {:ok, user} ->
        {:ok, {user, false}}
    end
  end

  defp find_user_by_provider(repo, provider, provider_uid) do
    case provider do
      :github -> UserQueries.get_user_by_github_id(provider_uid, repo)
      :google -> UserQueries.get_user_by_google_id(provider_uid, repo)
      :oauth -> UserQueries.get_user_by_provider("oauth", provider_uid, repo)
      _other -> {:error, :not_found}
    end
  end

  defp handle_user_not_found_by_provider(repo, provider, provider_uid, auth_params) do
    email = auth_params["email"]
    email_verified = auth_params["is_verified"] == true

    # Only link to an existing account by email when the provider has verified the
    # address. Trusting an unverified email could let an attacker claim any address
    # and silently take over the matching account.
    if email_verified do
      case UserQueries.get_user_by_email(email, repo) do
        {:error, :not_found} ->
          create_new_user(repo, auth_params)

        {:ok, existing_user} ->
          link_provider_to_existing_user(repo, existing_user, provider, provider_uid)
      end
    else
      create_new_user(repo, auth_params)
    end
  end

  defp create_new_user(repo, auth_params) do
    case UserQueries.create_social_user(auth_params, repo) do
      {:ok, user} -> {:ok, {user, true}}
      {:error, changeset} -> {:error, {:find_or_create, changeset}}
    end
  end

  defp link_provider_to_existing_user(repo, user, provider, provider_uid) do
    update_attrs = build_provider_update_attrs(provider, provider_uid)

    changeset = Changeset.change(user, update_attrs)

    case UserQueries.update_changeset(changeset, repo) do
      {:ok, updated_user} -> {:ok, {updated_user, false}}
      {:error, changeset} -> {:error, {:find_or_create, changeset}}
    end
  end

  defp build_provider_update_attrs(provider, provider_uid) do
    case provider do
      :github -> %{github_user_id: provider_uid}
      :google -> %{google_user_id: provider_uid}
      :oauth -> %{provider: "oauth", provider_uid: provider_uid}
      _other -> %{}
    end
  end

  defp provider_uid_field(:github), do: "github_user_id"
  defp provider_uid_field(:google), do: "google_user_id"
  defp provider_uid_field(:oauth), do: "provider_uid"
  defp provider_uid_field(_arg), do: nil
end
