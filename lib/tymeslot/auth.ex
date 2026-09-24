defmodule Tymeslot.Auth do
  @moduledoc """
  The Auth context.

  This module is the public API for all auth-related operations including
  authentication, registration, session management, and user verification.
  It encapsulates the business logic and provides a clean interface for the web layer.
  """

  alias Tymeslot.Auth.{
    AccountDeletion,
    AdminRoles,
    AdminUserQueries,
    Authentication,
    EmailChange,
    ErrorFormatter,
    PasswordReset,
    PasswordUpdate,
    Registration,
    SocialAuthentication,
    UserQueries,
    UserSchema,
    Validation,
    Verification
  }

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.PubSub

  @typedoc "A flow that signs in or manages an account with an email and password."
  @type password_flow :: :login | :signup | :reset

  @doc """
  Whether a password flow is open on this deployment.

  Password authentication can be switched off entirely, which closes every
  flow; registration can be switched off on its own, which closes `:signup`.
  Every entry point below that runs a password flow checks this, so the web
  layer only needs it to refuse early (a link, a navigation) with the same
  message the flow itself would give.
  """
  @spec check_password_flow(password_flow()) ::
          :ok | {:error, :password_auth_disabled | :registration_disabled, String.t()}
  def check_password_flow(flow) when flow in [:login, :signup, :reset] do
    cond do
      not Config.password_auth_enabled?() -> flow_closed(:password_auth_disabled)
      flow == :signup -> check_registration_open()
      true -> :ok
    end
  end

  @doc """
  Whether new accounts may be created on this deployment, by any sign-up
  method, with the message to show when they may not.
  """
  @spec check_registration_open() :: :ok | {:error, :registration_disabled, String.t()}
  def check_registration_open do
    if Config.registration_enabled?(), do: :ok, else: flow_closed(:registration_disabled)
  end

  defp flow_closed(reason), do: {:error, reason, ErrorFormatter.format_auth_error(reason)}

  @doc """
  The user-facing message for an auth failure reason, such as
  `:registration_disabled`; see `Tymeslot.Auth.ErrorFormatter.format_auth_error/1`.
  """
  @spec error_message(atom()) :: String.t()
  defdelegate error_message(reason), to: ErrorFormatter, as: :format_auth_error

  @doc """
  Authenticates a user with email and password, once password sign-in is
  open (see `check_password_flow/1`).

  `opts` carries the client (`:ip`, `:user_agent`). A wrong password, an
  unknown address, an account with no password and an unverified account all
  return the same generic error; see
  `Tymeslot.Auth.Authentication.authenticate_user/3`.
  """
  @spec authenticate_user(String.t(), String.t(), keyword()) ::
          {:ok, UserSchema.t(), String.t()}
          | {:error, atom(), String.t()}
          | {:error, :invalid_input, map()}
  def authenticate_user(email, password, opts \\ []) do
    with :ok <- check_password_flow(:login) do
      Authentication.authenticate_user(email, password, opts)
    end
  end

  @doc """
  Validates a sign-in form's fields without looking anything up, for
  instant feedback: the same rules `authenticate_user/3` applies. Messages
  are translated and keyed by field.
  """
  @spec validate_login(term(), term()) ::
          :ok | {:error, %{optional(:email | :password) => String.t()}}
  defdelegate validate_login(email, password), to: Validation, as: :validate_login_input

  @doc """
  Validates an email address as every auth form does, for instant feedback.
  Returns the sanitised address or a translated message.
  """
  @spec validate_email(term(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate validate_email(email, metadata \\ %{}), to: Validation

  @doc """
  Requests an email change for a user.
  Validates password, creates token, stores pending email, and sends verification emails.
  A failure is `{:error, %{field => message}}`, keyed by the form field each
  message belongs to.
  """
  @spec request_email_change(term(), term(), term(), keyword()) ::
          {:ok, term(), String.t()}
          | {:error, %{optional(:current_password | :new_email) => String.t()}}
          | {:error, :rate_limited, String.t()}
  def request_email_change(user, new_email, current_password, opts \\ []) do
    EmailChange.request_email_change(user, new_email, current_password, opts)
  end

  @doc """
  Verifies and completes an email change using the verification token.
  Uses a database transaction to ensure atomicity.
  """
  @spec verify_email_change(String.t(), keyword()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, {atom(), String.t()}}
  def verify_email_change(token, opts \\ []) when is_binary(token) do
    EmailChange.verify_email_change(token, opts)
  end

  @doc """
  Cancels a pending email change request.
  """
  @spec cancel_email_change(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, {atom(), String.t()}}
  def cancel_email_change(user) do
    EmailChange.cancel_email_change(user)
  end

  @doc """
  Updates a user's password after verifying their current password.
  Pure domain logic without HTTP concerns. A failure is
  `{:error, %{field => message}}`, keyed by the form field each message
  belongs to.
  """
  @spec update_user_password(term(), term(), term(), term(), keyword()) ::
          {:ok, term()}
          | {:error, %{optional(PasswordUpdate.error_field()) => String.t()}}
          | {:error, :rate_limited, String.t()}
  def update_user_password(
        user,
        current_password,
        new_password,
        new_password_confirmation,
        opts \\ []
      ) do
    PasswordUpdate.update_user_password(
      user,
      current_password,
      new_password,
      new_password_confirmation,
      opts
    )
  end

  @doc """
  Updates the user's interface language preference. Pass `nil` or an empty
  string to clear it and fall back to browser/session locale detection.
  """
  @spec update_user_locale(term(), String.t() | nil) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def update_user_locale(user, locale) do
    UserQueries.update_user_locale(user, locale)
  end

  @doc """
  Registers a new user account with an email and password, once sign-up is
  open (see `check_password_flow/1`: both password authentication and
  registration must be enabled).

  Runs the anti-abuse gate (honeypot, rate limit, reCAPTCHA), validates the
  input, creates the account and its profile, broadcasts the registration and
  sends the verification email. `opts` carries the client (`:ip`,
  `:user_agent`), the broadcast `:metadata` and `:bot_checks`; see
  `Tymeslot.Auth.Registration.register_user/2`.

  Returns `{:ok, user, message}` for a new account and
  `{:existing_account, message}` when the address was already registered, or
  `{:honeypot, message}` when a bot was caught. The message is identical in
  all three, and the owner of a taken address is emailed instead.
  """
  @spec register_user(map(), keyword()) ::
          {:ok, Tymeslot.Auth.UserSchema.t(), String.t()}
          | {:existing_account, String.t()}
          | {:honeypot, String.t()}
          | {:error, term(), String.t()}
          | {:error, :input, map() | String.t()}
  def register_user(params, opts \\ []) do
    with :ok <- check_password_flow(:signup) do
      Registration.register_user(params, opts)
    end
  end

  @doc """
  Requests a password reset link for `email`, once password resets are open
  (see `check_password_flow/1`).

  The reply is the same whether or not the address has an account, so it
  cannot be used to discover who is registered. `opts` carries the client
  (`:ip`, `:user_agent`) for the rate limit.
  """
  @spec request_password_reset(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def request_password_reset(email, opts \\ []) do
    with :ok <- check_password_flow(:reset) do
      case PasswordReset.initiate_reset(email, opts) do
        {:ok, :reset_initiated, message} -> {:ok, message}
        # The address is the visitor's own input: say which rule it broke.
        {:error, :invalid_input, _message} = invalid -> invalid
        {:error, reason, _message} -> reset_failed(reason)
      end
    end
  end

  @doc """
  Sets a new password against a reset token, once password resets are open
  (see `check_password_flow/1`). Every session the account had is revoked.

  `opts` carries the client (`:ip`, `:user_agent`) for the audit entry.
  """
  @spec reset_password(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, UserSchema.t(), String.t()} | {:error, atom(), String.t()}
  def reset_password(token, password, password_confirmation, opts \\ []) do
    with :ok <- check_password_flow(:reset) do
      case PasswordReset.reset_password(token, password, password_confirmation, opts) do
        {:ok, _user, _message} = ok -> ok
        # A rejected password keeps its own message: the user needs to know
        # which rule it broke. Every other reason describes the token.
        {:error, :invalid_input, _message} = invalid -> invalid
        {:error, reason, _message} -> reset_failed(reason)
      end
    end
  end

  defp reset_failed(reason),
    do: {:error, reason, ErrorFormatter.format_password_reset_error(reason)}

  @doc """
  Checks a password reset token without spending it, for showing the form
  it leads to.
  """
  @spec verify_password_reset_token(String.t()) ::
          {:ok, UserSchema.t(), String.t()} | {:error, atom(), String.t()}
  defdelegate verify_password_reset_token(token), to: PasswordReset, as: :verify_token

  @doc """
  Resends the verification link to the session-bound unverified account
  `email`, answering the same way whatever the address turns out to be; see
  `Tymeslot.Auth.Verification.resend_verification_email_by_email/2`.
  """
  @spec resend_verification_email(String.t() | nil, String.t() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  defdelegate resend_verification_email(email, ip),
    to: Verification,
    as: :resend_verification_email_by_email

  @doc """
  Verifies a user's email address.

  Deliberately broadcasts nothing: `user_registered` is published once, at
  registration, and a second broadcast here made every subscriber keeping
  per-event tallies count a verified password signup twice.
  """
  @spec verify_user_email(String.t()) :: {:ok, Ecto.Schema.t()} | {:error, any()}
  def verify_user_email(token) do
    Verification.verify_user(token)
  end

  @doc """
  Completes an emailed verification link, reporting whether the person who
  opened it may be signed straight in (`:auto_login`) or must log in
  (`:manual`). See `Tymeslot.Auth.Verification.verify_email_and_maybe_login/2`.
  """
  @spec verify_email_and_maybe_login(String.t(), String.t() | nil) ::
          {:ok, Ecto.Schema.t(), :auto_login | :manual} | {:error, atom()}
  defdelegate verify_email_and_maybe_login(token, request_ip), to: Verification

  @doc """
  Subscribes the calling process to user-registration events.

  Every account that completes registration is delivered to the caller's
  mailbox as `{:user_registered, %{user: user, metadata: metadata}}`. The
  context owns the topic, so a subscriber never spells one itself. Returns
  `{:error, reason}` rather than raising when no PubSub server is running,
  leaving the caller to decide whether a missing subscription is fatal.
  """
  @spec subscribe_to_user_registrations() :: :ok | {:error, term()}
  defdelegate subscribe_to_user_registrations, to: PubSub

  @doc """
  Publishes a user-registration event to every subscriber.

  The counterpart to `subscribe_to_user_registrations/0`: both name the event
  rather than the transport, so the topic stays an implementation detail of
  this context.
  """
  @spec broadcast_user_registered(struct(), map()) :: :ok
  defdelegate broadcast_user_registered(user, metadata \\ %{}), to: PubSub

  @doc """
  Generates a fresh verification token for a user and persists it without sending an email.

  Intended for background workers that need to produce a valid verification URL before
  delivering their own email (e.g. a 24-hour reminder). The raw token is never stored, and
  an existing one may have expired (see `Tymeslot.Auth.AccountTokens.ttl_seconds/1`), so
  callers must regenerate before building any verification link.
  """
  @spec regenerate_verification_token(integer()) :: {:ok, String.t()} | {:error, atom()}
  def regenerate_verification_token(user_id) do
    case Verification.issue_verification_token(user_id) do
      {:ok, _user, token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the Google account email to use as an OAuth `login_hint` when the user
  signed up (or linked an account) via Google, or `nil` otherwise.

  Passing this hint to the calendar OAuth flow lets Google skip the account
  picker, so a Google-authenticated user can connect their calendar in one click
  instead of re-selecting the account they just signed in with.
  """
  @spec google_signup_login_hint(Ecto.Schema.t()) :: String.t() | nil
  def google_signup_login_hint(%{google_user_id: nil}), do: nil

  def google_signup_login_hint(%{google_user_id: _id} = user),
    do: user.provider_email || user.email

  def google_signup_login_hint(_user), do: nil

  @doc """
  Checks if an email is available for registration.
  Returns :ok if available, {:error, :email_already_taken | :invalid_email} otherwise.
  """
  @spec check_email_availability(term()) :: :ok | {:error, :email_already_taken | :invalid_email}
  def check_email_availability(email) do
    SocialAuthentication.check_email_availability(email)
  end

  @doc """
  Gets a user by email.
  """
  @spec get_user_by_email(String.t()) :: term() | nil
  def get_user_by_email(email) do
    case UserQueries.get_user_by_email(email) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Gets a user by ID.
  """
  @spec get_user(integer()) :: {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def get_user(id) do
    UserQueries.get_user(id)
  end

  @doc """
  Deletes a user account.

  Runs the configured account-deletion hook (e.g. SaaS subscription
  cancellation) before any database change; if it fails, the deletion is
  aborted and the user is left intact. On success, anonymises payment
  records and deletes the user row in a single transaction.
  """
  @spec delete_account(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_account(user) do
    AccountDeletion.delete_account(user)
  end

  @doc """
  Lists all users in the system, ordered by id ascending.
  """
  defdelegate list_users(), to: AdminUserQueries, as: :list_all_users

  @doc """
  Counts all users in the system.
  """
  defdelegate count_users(), to: AdminUserQueries

  @doc """
  Counts admin users in the system.
  """
  defdelegate count_admins(), to: AdminUserQueries

  @doc """
  Returns `true` if at least one admin can sign in via email + password.
  """
  defdelegate any_admin_uses_password_auth?(), to: AdminUserQueries

  @doc """
  Counts admins, other than `user_id`, who can actually sign in today.
  See `Tymeslot.Auth.AdminUserQueries.count_signin_capable_admins_excluding/3`.
  """
  @spec count_signin_capable_admins_excluding(integer(), [atom()]) :: non_neg_integer()
  def count_signin_capable_admins_excluding(user_id, usable_sso_providers) do
    AdminUserQueries.count_signin_capable_admins_excluding(user_id, usable_sso_providers)
  end

  @doc """
  Returns `true` if at least one admin account exists.
  """
  defdelegate any_admin?(), to: AdminUserQueries

  @doc """
  Promotes the user identified by `user_id` to admin.

  See `Tymeslot.Auth.AdminRoles.promote/2` for the full contract.
  """
  defdelegate promote_admin(actor, user_id), to: AdminRoles, as: :promote

  @doc """
  Demotes the user identified by `user_id` from admin.

  See `Tymeslot.Auth.AdminRoles.demote/2` for the full contract.
  """
  defdelegate demote_admin(actor, user_id), to: AdminRoles, as: :demote
end
