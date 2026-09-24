defmodule Tymeslot.Auth.OAuth.UserRegistration do
  @moduledoc """
  Finds and creates the account behind a social sign-in identity.
  """

  require Logger
  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Auth.OAuth.{Providers, TransactionalUserCreation}
  alias Tymeslot.Auth.{UserQueries, UserSchema, UserTokenQueries}
  alias Tymeslot.Infrastructure.{Config, PubSub}
  alias Tymeslot.Repo
  alias Tymeslot.Security.FieldValidators.EmailValidator

  @type provider :: Providers.provider()
  @type oauth_registration_data :: %{
          required(:provider_uid) => String.t() | nil,
          required(:email) => String.t() | nil,
          optional(:email_from_provider) => boolean(),
          optional(:terms_accepted) => boolean(),
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

  All generic OAuth users share `provider = "oauth"` whichever identity
  provider issued them, so switching identity providers requires clearing the
  old provider's rows: a new `sub` colliding with an old one would match.
  """
  @spec find_existing_user(provider(), oauth_registration_data()) ::
          {:ok, map()} | {:error, :not_found | :email_already_taken}
  def find_existing_user(provider, %{provider_uid: uid} = identity) do
    case Providers.find_user(provider, uid, Repo) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> check_email_unregistered(Map.get(identity, :email))
    end
  end

  @doc """
  Creates a new user from OAuth provider information, or returns the account
  that already carries this provider ID.

  The account is always created verified: callers only get here with a
  proved email, one the provider vouched for or one confirmed through
  `Tymeslot.Auth.OAuth.SignupConfirmation`. An address typed into the
  complete-registration form never reaches this function unconfirmed, so no
  account exists for it until its owner follows the emailed link. Accounts
  created unverified before that change keep the verify-first handling in
  `Tymeslot.Auth.OAuth.FlowHandler`.
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
  Marks `account` verified when its email has not been verified yet and the
  provider vouches for that very address (among any it vouches for), and
  returns the account either way.

  Covers accounts created before the provider's word counted, and typed
  addresses the provider has since verified: sending an email to prove what
  the provider already has would only lock the owner out until they read it.
  """
  @spec verify_vouched_email(map(), map()) :: map()
  def verify_vouched_email(%UserSchema{verified_at: nil, email: email} = account, identity)
      when is_binary(email) do
    vouched = Enum.map(Map.get(identity, :verified_emails, []), &String.downcase/1)

    with true <- String.downcase(email) in vouched,
         {:ok, verified} <- UserTokenQueries.consume_verification_token(account) do
      AccountLogging.log_user_verified(verified, "oauth_provider", %{
        provider: account.provider
      })

      :telemetry.execute([:tymeslot, :auth, :email_verified], %{count: 1}, %{})
      verified
    else
      _not_vouched_or_failed -> account
    end
  end

  def verify_vouched_email(account, _identity), do: account

  @doc """
  Validates data submitted via the OAuth completion form.

  Checks that the email is present and well-formed, and that legal
  agreements have been accepted when required. Whether the address is taken
  is the caller's question: a typed address that is taken must be answered
  like a free one (see `Tymeslot.Auth.SocialAuthentication`).
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
        :ok
    end
  end

  defp check_email_unregistered(email) when is_binary(email) and email != "" do
    case UserQueries.get_user_by_email(email) do
      {:ok, _user} -> {:error, :email_already_taken}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp check_email_unregistered(_email), do: {:error, :not_found}

  defp build_auth_params(provider, oauth_user) do
    uid_field = Atom.to_string(Providers.fetch!(provider).uid_field)

    %{
      "provider" => to_string(provider),
      "email" => oauth_user.email,
      uid_field => oauth_user.provider_uid,
      "verified_at" => DateTime.utc_now(:second)
    }
  end
end
