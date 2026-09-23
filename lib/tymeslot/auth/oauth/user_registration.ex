defmodule Tymeslot.Auth.OAuth.UserRegistration do
  @moduledoc """
  Handles finding and creating users from OAuth information.
  """

  require Logger
  alias Tymeslot.Auth
  alias Tymeslot.Auth.OAuth.TransactionalUserCreation
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Security.FieldValidators.EmailValidator

  @type provider :: :github | :google | :oauth
  @type oauth_registration_data :: %{
          required(:email) => String.t() | nil,
          optional(:github_user_id) => String.t() | integer(),
          optional(:google_user_id) => String.t(),
          optional(:provider_uid) => String.t(),
          optional(:email_from_provider) => boolean(),
          optional(atom()) => term()
        }
  @type oauth_profile_params :: TransactionalUserCreation.oauth_profile_params()

  @doc """
  Finds the account an OAuth login belongs to, by the provider's own user ID.

  Never matches by email: each account belongs to the sign-in method that
  created it. When no account carries this provider ID but the login's email
  is already registered, returns `{:error, :email_already_taken}` so the
  caller can point the user at their original sign-in method rather than
  routing them into a registration that cannot succeed.
  """
  @spec find_existing_user(provider(), oauth_registration_data()) ::
          {:ok, map()} | {:error, :not_found | :email_already_taken}
  def find_existing_user(:github, %{github_user_id: github_id} = user) do
    user_queries = Config.user_queries_module()

    find_user_by_provider_id(
      user_queries,
      &user_queries.get_user_by_github_id/1,
      normalize_github_id(github_id),
      Map.get(user, :email)
    )
  end

  def find_existing_user(:google, %{google_user_id: google_id} = user) do
    user_queries = Config.user_queries_module()

    find_user_by_provider_id(
      user_queries,
      &user_queries.get_user_by_google_id/1,
      google_id,
      Map.get(user, :email)
    )
  end

  def find_existing_user(:oauth, %{provider_uid: uid} = user) do
    user_queries = Config.user_queries_module()

    find_user_by_provider_id(
      user_queries,
      &user_queries.get_user_by_provider("oauth", &1),
      uid,
      Map.get(user, :email)
    )
  end

  @doc """
  Creates a new user from OAuth provider information, or returns the account
  that already carries this provider ID.

  The account is created verified only when the provider vouched for the
  email (`email_from_provider: true`); an address the user typed stays
  unverified until they follow the emailed link.
  """
  @spec create_oauth_user(
          provider(),
          oauth_registration_data(),
          oauth_profile_params(),
          keyword()
        ) ::
          {:ok, map()} | {:error, any()}
  def create_oauth_user(provider, oauth_user, profile_params \\ %{}, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    auth_params = build_auth_params(provider, oauth_user)

    case TransactionalUserCreation.find_or_create_oauth_user(
           provider,
           auth_params,
           profile_params
         ) do
      {:ok, %{user: user, created: true}} ->
        PubSub.broadcast_user_registered(user, metadata)
        {:ok, user}

      {:ok, %{user: user, created: false}} ->
        {:ok, user}

      {:error, reason} ->
        Logger.error("OAuth user creation failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Validates data submitted via the OAuth completion form.

  Checks that the email is present, well-formed, not already registered, and
  that legal agreements have been accepted when required.
  """
  @spec validate_completion_data(oauth_registration_data()) :: :ok | {:error, atom() | String.t()}
  def validate_completion_data(oauth_data) do
    email = oauth_data.email

    cond do
      is_nil(email) or String.trim(email) == "" ->
        {:error, :email_required}

      EmailValidator.validate(email) != :ok ->
        {:error, :invalid_email}

      Config.enforce_legal_agreements?() and not oauth_data.terms_accepted ->
        {:error, :terms_not_accepted}

      true ->
        Auth.check_email_availability(email)
    end
  end

  @doc """
  Determines what information is missing for OAuth registration completion.
  """
  @spec check_oauth_requirements(provider(), oauth_registration_data()) ::
          {:missing, list(atom())} | :complete
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

  defp find_user_by_provider_id(user_queries, id_lookup_fn, user_id, email) do
    case lookup_by_provider_id(id_lookup_fn, user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> check_email_unregistered(user_queries, email)
    end
  end

  defp lookup_by_provider_id(id_lookup_fn, user_id)
       when is_integer(user_id) or is_binary(user_id),
       do: id_lookup_fn.(user_id)

  defp lookup_by_provider_id(_id_lookup_fn, _user_id), do: {:error, :not_found}

  defp check_email_unregistered(user_queries, email) when is_binary(email) and email != "" do
    case user_queries.get_user_by_email(email) do
      {:ok, _user} -> {:error, :email_already_taken}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp check_email_unregistered(_user_queries, _email), do: {:error, :not_found}

  defp build_auth_params(provider, oauth_user) do
    uid_field = TransactionalUserCreation.provider_uid_field(provider)

    Map.merge(
      %{
        "provider" => to_string(provider),
        "email" => oauth_user.email,
        uid_field => Map.get(oauth_user, String.to_existing_atom(uid_field))
      },
      verified_at(oauth_user)
    )
  end

  defp verified_at(%{email_from_provider: true}),
    do: %{"verified_at" => DateTime.utc_now(:second)}

  defp verified_at(_oauth_user), do: %{}
end
