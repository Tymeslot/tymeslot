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
  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Repo

  @doc """
  Creates an OAuth user within a transaction to prevent race conditions.

  This function:
  1. Checks if a user with the email already exists
  2. If not, creates the user
  3. Creates the associated profile
  4. Broadcasts the user registration event

  All operations happen within a single database transaction.

  ## Parameters
  - auth_params: Map containing user authentication parameters
  - profile_params: Map containing user profile parameters (currently unused but kept for future use)

  ## Returns
  - {:ok, %{user: user, profile: profile}} on success
  - {:error, :user_already_exists, reason} when user already exists
  - {:error, operation, reason} on other failures
  """
  @spec create_oauth_user_transactionally(map(), map()) ::
          {:ok, %{user: UserSchema.t(), profile: any()}}
          | {:error, :user_already_exists, any()}
          | {:error, atom(), any()}
  def create_oauth_user_transactionally(auth_params, profile_params) do
    result =
      UserQueries.transaction(fn ->
        with {:ok, :no_existing_user} <- check_for_existing_user(Repo, auth_params),
             {:ok, user} <- create_user(Repo, auth_params),
             {:ok, profile} <- create_profile(Repo, user, profile_params) do
          broadcast_user_registered(user)
          %{user: user, profile: profile}
        else
          {:error, {:user_already_exists, reason}} ->
            UserQueries.rollback({:user_already_exists, reason})

          {:error, {operation, reason}} ->
            UserQueries.rollback({operation, reason})
        end
      end)

    case result do
      {:ok, %{user: user, profile: profile}} ->
        {:ok, %{user: user, profile: profile}}

      {:error, {:user_already_exists, reason}} ->
        {:error, :user_already_exists, reason}

      {:error, {operation, reason}} ->
        Logger.error("OAuth user creation failed at #{operation}: #{inspect(reason)}")
        {:error, operation, reason}
    end
  end

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
  @spec find_or_create_oauth_user(atom(), map(), map()) ::
          {:ok, %{user: UserSchema.t(), created: boolean()}}
          | {:error, any()}
  def find_or_create_oauth_user(provider, auth_params, profile_params \\ %{}) do
    provider_field = provider_uid_field(provider)
    provider_uid = auth_params[provider_field]

    result =
      UserQueries.transaction(fn ->
        with {:ok, {user, created}} <-
               find_or_create_by_provider(Repo, provider, provider_uid, auth_params),
             {:ok, _} <- ensure_profile(Repo, user, created, profile_params) do
          if created do
            broadcast_user_registered(user)
          end

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
        Logger.error("OAuth find_or_create failed at #{operation}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp ensure_profile(repo, user, true, profile_params) do
    create_profile(repo, user, profile_params)
  end

  defp ensure_profile(_repo, _user, false, _profile_params), do: {:ok, :existing}

  defp check_for_existing_user(repo, auth_params) do
    email = auth_params["email"]

    case UserQueries.get_user_by_email(email, repo) do
      {:error, :not_found} ->
        {:ok, :no_existing_user}

      {:ok, _existing_user} ->
        {:error, {:user_already_exists, "User with email #{email} already exists"}}
    end
  end

  defp create_user(repo, auth_params) do
    case UserQueries.create_social_user(auth_params, repo) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        {:error, {:create_user, changeset}}
    end
  end

  defp create_profile(repo, user, profile_params) do
    # Use the repo passed in to ensure we're in the same transaction
    profile_attrs = %{user_id: user.id}

    # Add full_name from profile_params if provided
    profile_attrs =
      case profile_params[:full_name] do
        name when is_binary(name) and name != "" ->
          Map.put(profile_attrs, :full_name, String.trim(name))

        _ ->
          profile_attrs
      end

    case ProfileQueries.create_profile_in_transaction(repo, profile_attrs) do
      {:ok, profile} ->
        Logger.info("Created profile for user_id=#{user.id}")
        {:ok, profile}

      {:error, reason} ->
        Logger.error("Profile creation failed for user_id=#{user.id}: #{inspect(reason)}")
        {:error, {:create_profile, reason}}
    end
  end

  defp broadcast_user_registered(user) do
    PubSub.broadcast_user_registered(user)
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
      _ -> {:error, :not_found}
    end
  end

  defp handle_user_not_found_by_provider(repo, provider, provider_uid, auth_params) do
    email = auth_params["email"]

    case UserQueries.get_user_by_email(email, repo) do
      {:error, :not_found} ->
        create_new_user(repo, auth_params)

      {:ok, existing_user} ->
        link_provider_to_existing_user(repo, existing_user, provider, provider_uid)
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
      _ -> %{}
    end
  end

  defp provider_uid_field(:github), do: "github_user_id"
  defp provider_uid_field(:google), do: "google_user_id"
  defp provider_uid_field(_), do: nil
end
