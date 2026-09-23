defmodule Tymeslot.Auth.OAuth.TransactionalUserCreation do
  @moduledoc """
  Finds or creates the account for an OAuth identity, together with its
  profile and default schedule, in one transaction.

  The lookup and the insert are not atomic: two requests for the same new
  identity (a double-submitted completion form) can both miss the lookup.
  The unique index on the provider ID lets only one insert through; the loser
  re-reads the winner's account and returns it, so both requests end with the
  same user.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Tymeslot.Auth.{AdminBootstrap, UserQueries, UserSchema}
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @type oauth_auth_params :: %{String.t() => term()}
  @type oauth_profile_params :: %{optional(:full_name) => String.t() | nil}

  @doc """
  Finds or creates an OAuth user within a transaction.

  Returns the existing account when one already carries this provider ID,
  including one a concurrent request inserted first.

  ## Parameters
  - provider: The OAuth provider (:github or :google)
  - auth_params: Map containing user authentication parameters

  ## Returns
  - {:ok, %{user: user, created: boolean}} where created indicates if user was newly created
  - {:error, reason} on failure
  """
  @spec find_or_create_oauth_user(atom(), oauth_auth_params(), oauth_profile_params(), keyword()) ::
          {:ok, %{user: UserSchema.t(), created: boolean()}}
          | {:error, any()}
  def find_or_create_oauth_user(provider, auth_params, profile_params \\ %{}, _opts \\ []) do
    provider_field = provider_uid_field(provider)
    provider_uid = auth_params[provider_field]

    result =
      Repo.transaction(fn ->
        with {:ok, {user, created}} <-
               find_or_create_by_provider(Repo, provider, provider_uid, auth_params),
             {:ok, _result} <- ensure_profile(Repo, user, created, profile_params) do
          {user, created}
        else
          {:error, {operation, reason}} ->
            Repo.rollback({operation, reason})
        end
      end)

    case result do
      {:ok, {user, created}} ->
        {:ok, %{user: user, created: created}}

      {:error, {:find_or_create, %Ecto.Changeset{} = changeset}} ->
        recover_from_concurrent_insert(provider, provider_uid, changeset)

      {:error, {operation, reason}} ->
        Logger.error("OAuth find_or_create failed", operation: operation, reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  The auth-params key (and user column) holding a provider's stable user ID.
  """
  @spec provider_uid_field(atom()) :: String.t()
  def provider_uid_field(:github), do: "github_user_id"
  def provider_uid_field(:google), do: "google_user_id"
  def provider_uid_field(:oauth), do: "provider_uid"

  # Private functions

  # The failed insert aborted the transaction, so the re-read happens outside
  # it. Found: another request created the account first. Not found: the
  # changeset failed for its own reasons (a taken email, say).
  defp recover_from_concurrent_insert(provider, provider_uid, changeset) do
    case find_user_by_provider(Repo, provider, provider_uid) do
      {:ok, user} ->
        {:ok, %{user: user, created: false}}

      {:error, :not_found} ->
        Logger.error("OAuth find_or_create failed",
          operation: :find_or_create,
          reason: inspect(changeset)
        )

        {:error, changeset}
    end
  end

  defp ensure_profile(repo, user, true, profile_params) do
    create_profile(repo, user, profile_params)
  end

  defp ensure_profile(repo, user, false, profile_params) do
    case ProfileQueries.get_by_user_id_in_transaction(repo, user.id) do
      {:ok, _profile} -> {:ok, :existing}
      {:error, :not_found} -> create_profile(repo, user, profile_params)
    end
  end

  # Both signup paths (standard registration and OAuth) must create a default
  # weekly schedule immediately after the profile. Keep these in sync;
  # see Task 1 in the composition test plan for drift regression.
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

    with {:ok, profile} <- ProfileQueries.create_profile_in_transaction(repo, profile_attrs),
         {:ok, _schedule} <- Schedules.create_default(profile.id, repo) do
      Logger.info("Created profile", user_id: user.id)
      {:ok, profile}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Profile insert failed", user_id: user.id, reason: inspect(changeset))
        {:error, {:create_profile, changeset}}

      {:error, reason} ->
        Logger.error("Default schedule creation failed",
          user_id: user.id,
          reason: inspect(reason)
        )

        {:error, {:create_profile, reason}}
    end
  end

  # An account is only ever matched by the provider's own stable user ID, never
  # by email. Each account belongs to the sign-in method that created it; an
  # email match would let anyone controlling that address at another provider
  # (or at the same provider, after the address changes hands) sign straight
  # into it. A new login whose email is already registered fails on the email
  # unique constraint instead.
  defp find_or_create_by_provider(repo, provider, provider_uid, auth_params) do
    case find_user_by_provider(repo, provider, provider_uid) do
      {:ok, user} -> {:ok, {user, false}}
      {:error, :not_found} -> create_new_user(repo, auth_params)
    end
  end

  defp find_user_by_provider(_repo, _provider, nil), do: {:error, :not_found}

  defp find_user_by_provider(repo, provider, provider_uid) do
    case provider do
      :github -> UserQueries.get_user_by_github_id(provider_uid, repo)
      :google -> UserQueries.get_user_by_google_id(provider_uid, repo)
      :oauth -> UserQueries.get_user_by_provider("oauth", provider_uid, repo)
      _other -> {:error, :not_found}
    end
  end

  defp create_new_user(repo, auth_params) do
    with {:ok, user} <- UserQueries.create_social_user(auth_params, repo),
         {:ok, bootstrapped} <- AdminBootstrap.maybe_promote_first_user(user, repo) do
      {:ok, {bootstrapped, true}}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:find_or_create, changeset}}
    end
  end
end
