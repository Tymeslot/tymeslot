defmodule Tymeslot.Auth.Invitations do
  @moduledoc """
  Accounts an admin creates by inviting an email address, for installs that
  keep public registration closed.

  An invitation creates the account straight away, with its profile and
  default meeting types, but with no password and an unverified address. The
  invitee is emailed a single-use link (see `Tymeslot.Auth.AccountTokens`,
  purpose `:invitation`); following it, they choose how they will sign in: a
  password (`accept/4`) or one of the enabled social sign-in providers
  (`accept_with_provider/6`). Either verifies the address, since the link was
  delivered to it, and signs them in.

  A social acceptance links the provider identity to the invited account on
  the strength of the link alone: the identity's own email is never compared
  with the invited address, so an invitee whose provider account uses a
  different address can still accept. The invited address stays the
  account's email.

  Invitations need at least one way to sign in: password sign-in or an
  enabled social provider. Whether public registration is open makes no
  difference.

  An invitation is pending while its token hash is stored. Accepting it, or
  any other change to the account's credentials (a password reset requested
  through "forgot password"), clears the hash. An admin who cancels it
  (`revoke/2`) deletes the invited account.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Auth.{
    AccountTokens,
    AdminRoles,
    AdminUserQueries,
    RateLimit,
    RegistrationAnnouncement,
    SocialAuthentication,
    UserQueries,
    UserSchema,
    UserTokenQueries,
    Validation
  }

  alias Tymeslot.Auth.AccountDeletion.Operator

  alias Tymeslot.Auth.OAuth.Providers

  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Security.{RateLimiter, Token}
  alias Tymeslot.Utils.UrlBuilder

  @type invite_error ::
          :admin_ui_disabled
          | :forbidden
          | :no_sign_in_method
          | :invalid_email
          | :email_taken
          | :email_not_sent
          | term()

  @type provider_accept_error ::
          :invalid_token
          | :token_expired
          | :provider_disabled
          | :rate_limited
          | :identity_in_use
          | :oauth_error
          | :general_error

  @doc """
  Whether invitations can be sent and accepted on this deployment: they need
  password sign-in or at least one enabled social sign-in provider.
  """
  @spec available?() :: boolean()
  def available?, do: Config.password_auth_enabled?() or Providers.enabled() != []

  @doc """
  Whether `user` holds an invitation that has not been accepted yet.
  """
  @spec pending?(UserSchema.t()) :: boolean()
  def pending?(%UserSchema{invitation_token_hash: nil}), do: false
  def pending?(%UserSchema{}), do: true

  @doc """
  Whether `user`'s pending invitation link has expired, so the invitee needs
  a fresh one.
  """
  @spec expired?(UserSchema.t()) :: boolean()
  def expired?(%UserSchema{} = user),
    do: pending?(user) and AccountTokens.expired?(:invitation, user)

  @doc """
  Creates an account for `email` on behalf of the admin `actor` and emails
  the invitation.

  Returns `{:ok, user}` once the account exists and the email is queued.
  `{:error, :email_not_sent}` means the account was created but the email
  could not be queued; `resend/2` retries it.
  """
  @spec invite(AdminRoles.actor(), String.t()) :: {:ok, UserSchema.t()} | {:error, invite_error()}
  def invite(actor, email) do
    with :ok <- AdminRoles.authorise(actor),
         :ok <- ensure_available(),
         {:ok, email} <- validate_email(email),
         {:ok, user, token} <- create_invited_account(email) do
      AccountLogging.log_user_created(user, %{source: "invitation"})
      RegistrationAnnouncement.announce(user)
      log_invitation(:account_invitation_sent, actor, user)
      deliver(user, token)
    end
  end

  @doc """
  Issues `user_id` a fresh invitation link on behalf of the admin `actor`,
  replacing the earlier one, and emails it.
  """
  @spec resend(AdminRoles.actor(), pos_integer()) ::
          {:ok, UserSchema.t()} | {:error, :not_found | :not_invited | invite_error()}
  def resend(actor, user_id) do
    with :ok <- AdminRoles.authorise(actor),
         :ok <- ensure_available(),
         {:ok, user} <- fetch_pending(user_id),
         {:ok, user, token} <- AccountTokens.issue(:invitation, user) do
      log_invitation(:account_invitation_resent, actor, user)
      deliver(user, token)
    end
  end

  @doc """
  Cancels `user_id`'s pending invitation on behalf of the admin `actor`, by
  deleting the invited account: it has no password, identity or data of its
  own yet.

  The link stops working when this returns, before the deletion job has run:
  the token hash is cleared in the same transaction that schedules the
  deletion (`Tymeslot.Auth.AccountDeletion.Operator`), and a queued
  invitation email whose hash no longer matches is discarded. An acceptance
  re-reads the token under the same row lock, so whichever commits first
  wins: an accepted invitation is refused with `{:error, :not_invited}`, and
  an acceptance after the revoke, a social one already at the provider
  included, finds no live token.
  """
  @spec revoke(AdminRoles.actor(), pos_integer()) ::
          {:ok, UserSchema.t()} | {:error, :not_found | :not_invited | Operator.error()}
  def revoke(actor, user_id) do
    with :ok <- AdminRoles.authorise(actor),
         {:ok, user} <- revoke_and_delete(actor, user_id) do
      Logger.info("Account invitation revoked",
        user_id: user.id,
        actor_id: actor_id(actor),
        event: :account_invitation_revoked
      )

      {:ok, user}
    end
  end

  defp revoke_and_delete(actor, user_id) do
    Repo.transaction(fn ->
      # The deletion's own lock order, admins before the account, so an
      # invitee promoted to admin cannot deadlock against a role change.
      AdminUserQueries.lock_admins()

      with {:ok, user} <- UserQueries.get_user_for_update(user_id),
           :ok <- ensure_pending(user),
           {:ok, _revoked} <- UserTokenQueries.clear_invitation_token(user),
           {:ok, pending} <- Operator.delete_now(actor, user.id) do
        pending
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_pending(user), do: if(pending?(user), do: :ok, else: {:error, :not_invited})

  @doc """
  Resolves an invitation link's token to the invited account, without
  spending it, for showing the form it leads to.
  """
  @spec fetch(String.t()) ::
          {:ok, UserSchema.t()}
          | {:error, :invalid_token | :token_expired | :no_sign_in_method}
  def fetch(token) when is_binary(token) do
    with :ok <- ensure_available() do
      case AccountTokens.fetch(:invitation, token) do
        {:ok, user} -> {:ok, user}
        {:error, :token_expired, _user} -> {:error, :token_expired}
        {:error, :invalid_token} -> {:error, :invalid_token}
      end
    end
  end

  @doc """
  Accepts an invitation: sets the invitee's first password and verifies the
  account. The caller signs the returned user in.

  `opts` carries the client (`:ip`, `:user_agent`), for the per-address limit
  on attempts and the audit entry. A rejected password is
  `{:error, :invalid_input, message}`, with the rule it broke.
  """
  @spec accept(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, UserSchema.t()}
          | {:error, :invalid_token | :token_expired | :password_auth_disabled}
          | {:error, :invalid_input | :rate_limited, String.t()}
  def accept(token, password, password_confirmation, opts) do
    with :ok <- ensure_password_auth() do
      RateLimit.with_limit(
        RateLimiter.check(:invitation_accept, opts[:ip]),
        [event: "invitation_accept", ip: opts[:ip], user_agent: opts[:user_agent]],
        fn -> consume(token, password, password_confirmation) end
      )
    end
  end

  defp consume(token, password, password_confirmation) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- fetch_locked(token),
             :ok <- validate_password(password, password_confirmation),
             {:ok, accepted} <-
               AccountTokens.consume(:invitation, user, %{
                 password: password,
                 password_confirmation: password_confirmation
               }) do
          accepted
        else
          {:error, %Ecto.Changeset{}} -> Repo.rollback({:invalid_input, password_not_set()})
          {:error, :invalid_input, message} -> Repo.rollback({:invalid_input, message})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, user} ->
        AccountLogging.log_user_verified(user, "invitation")
        {:ok, user}

      {:error, {:invalid_input, message}} ->
        {:error, :invalid_input, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Accepts an invitation with a social sign-in, from the provider's callback:
  exchanges the code, then links the identity to the invited account and
  verifies it. The caller signs the returned user in.

  The web layer has already checked the flow's state and recovered its PKCE
  `code_verifier`; `opts` carries the client (`:ip`, `:user_agent`), for the
  per-address limit on attempts (shared with `accept/4`) and the audit entry. `{:error, :identity_in_use}` means the identity already signs
  in to another account; the invitation stays pending.
  """
  @spec accept_with_provider(
          String.t(),
          Providers.provider(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, UserSchema.t()} | {:error, provider_accept_error()}
  def accept_with_provider(token, provider, code, code_verifier, callback_url, opts) do
    with :ok <- ensure_provider(provider) do
      case RateLimit.with_limit(
             RateLimiter.check(:invitation_accept, opts[:ip]),
             [event: "invitation_accept", ip: opts[:ip], user_agent: opts[:user_agent]],
             fn -> identify_and_link(token, provider, code, code_verifier, callback_url, opts) end
           ) do
        {:error, :rate_limited, _message} -> {:error, :rate_limited}
        result -> result
      end
    end
  end

  defp identify_and_link(token, provider, code, code_verifier, callback_url, opts) do
    with {:ok, identity} <-
           SocialAuthentication.identify(provider, code, code_verifier, callback_url, opts),
         :ok <- ensure_identity_free(provider, identity) do
      link_identity(token, provider, identity)
    end
  end

  defp link_identity(token, provider, identity) do
    attrs = identity_attrs(provider, identity)

    result =
      Repo.transaction(fn ->
        with {:ok, user} <- fetch_locked(token),
             {:ok, accepted} <- AccountTokens.consume(:invitation, user, attrs) do
          accepted
        else
          # The identity's ID columns are the only unique ones the link
          # writes: another account took the identity since it was checked.
          {:error, %Ecto.Changeset{}} -> Repo.rollback(:identity_in_use)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, user} <- result do
      AccountLogging.log_user_verified(user, "invitation", %{provider: to_string(provider)})
      {:ok, user}
    end
  end

  defp identity_attrs(provider, identity) do
    Map.put(
      %{provider: to_string(provider)},
      Providers.fetch!(provider).uid_field,
      identity.provider_uid
    )
  end

  defp ensure_provider(provider) do
    if Providers.enabled?(provider), do: :ok, else: {:error, :provider_disabled}
  end

  defp ensure_identity_free(provider, identity) do
    case Providers.find_user(provider, identity.provider_uid, Repo) do
      {:ok, _account} -> {:error, :identity_in_use}
      {:error, :not_found} -> :ok
    end
  end

  defp password_not_set,
    do:
      dgettext(
        "auth_invitation",
        "The password couldn't be set. Please try again with a different one."
      )

  defp fetch_locked(token) do
    case AccountTokens.fetch(:invitation, token, lock: true) do
      {:ok, user} -> {:ok, user}
      {:error, :token_expired, _user} -> {:error, :token_expired}
      {:error, :invalid_token} -> {:error, :invalid_token}
    end
  end

  defp validate_password(password, password_confirmation) do
    params = %{"password" => password, "password_confirmation" => password_confirmation}

    case Validation.validate_new_password_input(params) do
      {:ok, _sanitised} -> :ok
      {:error, errors} -> {:error, :invalid_input, Validation.password_error_message(errors)}
    end
  end

  defp ensure_password_auth do
    if Config.password_auth_enabled?(), do: :ok, else: {:error, :password_auth_disabled}
  end

  defp ensure_available do
    if available?(), do: :ok, else: {:error, :no_sign_in_method}
  end

  defp validate_email(email) do
    case Validation.validate_email(email) do
      {:ok, valid} -> {:ok, valid}
      {:error, _message} -> {:error, :invalid_email}
    end
  end

  defp fetch_pending(user_id) do
    case UserQueries.get_user(user_id) do
      {:ok, %UserSchema{} = user} ->
        if pending?(user), do: {:ok, user}, else: {:error, :not_invited}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # The account, its profile, the registration hook's job and the token
  # commit together, so a failure leaves no half-made account holding the
  # address.
  defp create_invited_account(email) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- UserQueries.create_invited_user(%{email: email}),
             {:ok, _profile} <- Profiles.create_profile(user.id),
             :ok <- RegistrationAnnouncement.enqueue_hook(user.id, %{source: "invitation"}),
             {:ok, user, token} <- AccountTokens.issue(:invitation, user) do
          {user, token}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {user, token}} -> {:ok, user, token}
      {:error, %Ecto.Changeset{} = changeset} -> creation_failed(changeset)
      {:error, reason} -> {:error, reason}
    end
  end

  defp creation_failed(changeset) do
    if email_taken?(changeset), do: {:error, :email_taken}, else: {:error, changeset}
  end

  defp email_taken?(changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {_message, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  defp deliver(user, token) do
    case EmailScheduler.schedule_account_invitation(
           user.id,
           UrlBuilder.invitation_url(token),
           Token.hash_token(token)
         ) do
      {:ok, _status} ->
        {:ok, user}

      {:error, reason} ->
        Logger.error("Could not schedule the account invitation email",
          user_id: user.id,
          reason: LogFormat.reason(reason)
        )

        {:error, :email_not_sent}
    end
  end

  defp log_invitation(event, actor, user) do
    Logger.info("Account invitation issued",
      user_id: user.id,
      actor_id: actor_id(actor),
      event: event
    )
  end

  defp actor_id(:cli), do: "cli"
  defp actor_id(%UserSchema{id: id}), do: id
end
