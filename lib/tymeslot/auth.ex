defmodule Tymeslot.Auth do
  @moduledoc """
  The Auth context.

  This module is the public API for all auth-related operations including
  authentication, registration, session management, and user verification.
  It encapsulates the business logic and provides a clean interface for the web layer.
  """

  alias Tymeslot.Auth.{
    AuthActions,
    Authentication,
    EmailChange,
    PasswordReset,
    PasswordUpdate,
    Registration,
    Session,
    SocialAuthentication,
    UserQueries,
    Verification
  }

  alias Tymeslot.Infrastructure.{Config, PubSub}
  alias Tymeslot.Security.Token

  @doc """
  Authenticates a user with email and password.

  ## Examples

      iex> authenticate_user("user@example.com", "valid_password")
      {:ok, %User{}, "Welcome back!"}

      iex> authenticate_user("user@example.com", "invalid")
      {:error, :invalid_credentials, "Invalid email or password"}
  """
  @spec authenticate_user(String.t(), String.t(), keyword()) ::
          {:ok, term(), String.t()} | {:error, atom(), String.t()}
  def authenticate_user(email, password, opts \\ []) do
    Authentication.authenticate_user(email, password, opts)
  end

  @doc """
  Requests an email change for a user.
  Validates password, creates token, stores pending email, and sends verification emails.
  """
  @spec request_email_change(term(), String.t(), String.t()) ::
          {:ok, term(), String.t()} | {:error, String.t()}
  def request_email_change(user, new_email, current_password) do
    EmailChange.request_email_change(user, new_email, current_password)
  end

  @doc """
  Verifies and completes an email change using the verification token.
  Uses a database transaction to ensure atomicity.
  """
  @spec verify_email_change(String.t()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, atom(), String.t()}
  def verify_email_change(token) when is_binary(token) do
    EmailChange.verify_email_change(token)
  end

  @doc """
  Cancels a pending email change request.
  """
  @spec cancel_email_change(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, String.t()}
  def cancel_email_change(user) do
    EmailChange.cancel_email_change(user)
  end

  @doc """
  Updates a user's password after verifying their current password.
  Pure domain logic without HTTP concerns.
  """
  @spec update_user_password(term(), String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, String.t()}
  def update_user_password(user, current_password, new_password, new_password_confirmation) do
    PasswordUpdate.update_user_password(
      user,
      current_password,
      new_password,
      new_password_confirmation
    )
  end

  @doc """
  Registers a new user account.

  Handles the complete registration flow including:
  - Input validation
  - Password hashing
  - Account creation
  - Verification email sending
  - PubSub event broadcasting
  """
  @spec register_user(map(), term(), keyword()) ::
          {:ok, term(), String.t()} | {:error, term(), String.t()}
  def register_user(params, socket_or_conn, opts \\ []) do
    if Config.registration_enabled?() do
      Registration.register_user(params, socket_or_conn, opts)
    else
      {:error, :registration_disabled, AuthActions.registration_disabled_message()}
    end
  end

  @doc """
  Creates a new session for an authenticated user.

  This handles:
  - Session token generation
  - Cookie management
  - Session persistence
  """
  @spec create_session(Plug.Conn.t(), Ecto.Schema.t()) ::
          {:ok, Plug.Conn.t(), String.t()} | {:error, atom(), any()}
  def create_session(conn, user) do
    Session.create_session(conn, user)
  end

  @doc """
  Gets the current user ID from session.

  Returns the user ID if session is valid, nil otherwise.
  """
  @spec get_current_user_id(Plug.Conn.t()) :: integer() | nil
  def get_current_user_id(conn) do
    Session.get_current_user_id(conn)
  end

  @doc """
  Terminates a user session.
  """
  @spec delete_session(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_session(conn) do
    Session.delete_session(conn)
  end

  @doc """
  Initiates the password reset process.

  This will:
  - Generate a reset token
  - Send reset instructions via email
  - Return success regardless of whether user exists (security)
  """
  @spec initiate_password_reset(String.t(), keyword()) ::
          {:ok, atom(), String.t()} | {:error, atom(), String.t()}
  def initiate_password_reset(email, opts \\ []) do
    PasswordReset.initiate_reset(email, opts)
  end

  @doc """
  Resets a user's password using a valid reset token.
  """
  @spec reset_password(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term(), String.t()} | {:error, atom(), String.t()}
  def reset_password(token, new_password, password_confirmation, opts \\ []) do
    PasswordReset.reset_password(token, new_password, password_confirmation, opts)
  end

  @doc """
  Validates a password reset token.
  """
  @spec validate_reset_token(String.t(), keyword()) ::
          {:ok, map(), String.t()} | {:error, atom(), String.t()}
  def validate_reset_token(token, opts \\ []) do
    PasswordReset.verify_token(token, opts)
  end

  @doc """
  Verifies a user's email address.
  """
  @spec verify_user_email(String.t()) :: {:ok, Ecto.Schema.t()} | {:error, any()}
  def verify_user_email(token) do
    with {:ok, user} <- Verification.verify_user(token) do
      # Broadcast verification event
      Task.start(fn ->
        PubSub.broadcast_user_registered(user)
      end)

      {:ok, user}
    end
  end

  @doc """
  Resends verification email to a user.
  """
  @spec resend_verification_email(Plug.Conn.t() | Phoenix.LiveView.Socket.t(), Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom(), String.t()}
  def resend_verification_email(socket_or_conn, user) do
    Verification.resend_verification_email(socket_or_conn, user)
  end

  @doc """
  Generates a fresh verification token for a user and persists it without sending an email.

  Intended for background workers that need to produce a valid verification URL before
  delivering their own email (e.g. a 24-hour reminder). Existing tokens expire after 2 hours,
  so callers must regenerate before building any verification link.
  """
  @spec regenerate_verification_token(integer()) :: {:ok, String.t()} | {:error, atom()}
  def regenerate_verification_token(user_id) do
    {token, expiry, _purpose} = Token.generate_email_verification_token(user_id)

    case Verification.store_verification_token(user_id, token, expiry) do
      {:ok, _user} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets user by session token.
  """
  @spec get_user_by_session_token(String.t()) :: Ecto.Schema.t() | nil
  def get_user_by_session_token(token) do
    Authentication.get_user_by_session_token(token)
  end

  @doc """
  Marks a user's onboarding as complete.
  """
  @spec mark_onboarding_complete(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def mark_onboarding_complete(user) do
    UserQueries.mark_onboarding_complete(user)
  end

  @doc """
  Checks if a user has completed onboarding.
  """
  @spec onboarding_completed?(Ecto.Schema.t()) :: boolean()
  def onboarding_completed?(user) do
    not is_nil(user.onboarding_completed_at)
  end

  @doc """
  Checks if an email is available for registration.
  Returns :ok if available, {:error, reason} otherwise.
  """
  @spec check_email_availability(String.t()) :: :ok | {:error, String.t()}
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
  Gets a user by ID and raises if not found.
  """
  @spec get_user!(integer()) :: Ecto.Schema.t()
  def get_user!(id) do
    UserQueries.get_user!(id)
  end
end
