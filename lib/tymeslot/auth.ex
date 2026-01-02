defmodule Tymeslot.Auth do
  @moduledoc """
  The Auth context.

  This module is the public API for all auth-related operations including
  authentication, registration, session management, and user verification.
  It encapsulates the business logic and provides a clean interface for the web layer.
  """

  alias Ecto.Changeset
  alias Tymeslot.Auth.{Authentication, PasswordReset, Registration, Session, Verification}
  alias Tymeslot.DatabaseQueries.{UserQueries, UserSessionQueries}
  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.{Password, Token}
  alias Tymeslot.Utils.{ChangesetUtils, UrlBuilder}
  alias Tymeslot.Workers.EmailWorker

  require Logger

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
    with :ok <- verify_current_password(user, current_password),
         :ok <- validate_email_format(new_email),
         :ok <- validate_email_not_same(user.email, new_email),
         {:ok, :available} <- UserQueries.check_email_availability(new_email),
         token_raw <- Token.generate_token(),
         {:ok, updated_user} <- UserQueries.request_email_change(user, new_email, token_raw) do
      verification_url = UrlBuilder.email_change_url(token_raw)

      # Queue emails via Oban; do not fail the request if scheduling fails
      _ =
        with {:ok, _job1} <-
               Oban.insert(
                 EmailWorker.new(
                   %{
                     "action" => "send_email_change_verification",
                     "user_id" => updated_user.id,
                     "new_email" => new_email,
                     "verification_url" => verification_url
                   },
                   unique: [
                     # Deduplicate verification email jobs for the same user/new_email within 10 minutes
                     period: 600,
                     fields: [:args, :queue],
                     keys: [:action, :user_id, :new_email, :verification_url]
                   ]
                 )
               ),
             {:ok, _job2} <-
               Oban.insert(
                 EmailWorker.new(
                   %{
                     "action" => "send_email_change_notification",
                     "user_id" => updated_user.id,
                     "new_email" => new_email
                   },
                   unique: [
                     # Deduplicate notification email jobs for the same user/new_email within 10 minutes
                     period: 600,
                     fields: [:args, :queue],
                     keys: [:action, :user_id, :new_email]
                   ]
                 )
               ) do
          :ok
        else
          error ->
            Logger.error("Failed to enqueue email change emails",
              error: inspect(error),
              user_id: updated_user.id
            )

            :ok
        end

      {:ok, updated_user, "Verification email sent to #{new_email}"}
    else
      {:error, :invalid_password} ->
        {:error, "Current password is incorrect"}

      {:error, :same_email} ->
        {:error, "New email must be different from current email"}

      {:error, :taken} ->
        {:error, "Email address is already in use"}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  @doc """
  Verifies and completes an email change using the verification token.
  Uses a database transaction to ensure atomicity.
  """
  @spec verify_email_change(String.t()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, atom(), String.t()}
  def verify_email_change(token) when is_binary(token) do
    with {:ok, user} <- UserQueries.get_user_by_email_change_token(token),
         :ok <- check_email_change_token_validity(user),
         old_email <- user.email,
         new_email <- user.pending_email,
         {:ok, result} <- verify_email_change_in_transaction(user, old_email, new_email) do
      # After successful commit, enqueue confirmation emails
      _ =
        case Oban.insert(
               EmailWorker.new(
                 %{
                   "action" => "send_email_change_confirmations",
                   "user_id" => result.user.id,
                   "old_email" => old_email,
                   "new_email" => new_email
                 },
                 unique: [
                   # Deduplicate confirmation email jobs for the same (user, old_email, new_email) within 1 hour
                   period: 3600,
                   fields: [:args, :queue],
                   keys: [:action, :user_id, :old_email, :new_email]
                 ]
               )
             ) do
          {:ok, _job} ->
            :ok

          error ->
            Logger.error("Failed to enqueue email change confirmations",
              error: inspect(error),
              user_id: result.user.id
            )

            :ok
        end

      {:ok, result.user, "Email changed successfully. Please sign in with your new email."}
    else
      {:error, :not_found} ->
        {:error, :invalid_token, "Invalid or expired verification link"}

      {:error, :token_expired} ->
        {:error, :token_expired, "Verification link has expired"}

      {:error, %Changeset{} = changeset} ->
        {:error, :changeset_error, format_changeset_error(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, :unknown, reason}

      _ ->
        {:error, :unknown, "Failed to verify email change"}
    end
  end

  @doc """
  Cancels a pending email change request.
  """
  @spec cancel_email_change(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, String.t()}
  def cancel_email_change(user) do
    case UserQueries.cancel_email_change(user) do
      {:ok, updated_user} ->
        Logger.info("Email change cancelled", user_id: updated_user.id)
        {:ok, updated_user, "Email change request cancelled"}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error(changeset)}
    end
  end

  @doc """
  Updates a user's password after verifying their current password.
  Pure domain logic without HTTP concerns.
  """
  @spec update_user_password(term(), String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, String.t()}
  def update_user_password(
        user,
        current_password,
        new_password,
        new_password_confirmation
      ) do
    with :ok <- verify_current_password(user, current_password),
         :ok <- ensure_not_same_as_old(user, new_password),
         :ok <- validate_new_password(new_password, new_password_confirmation),
         {:ok, updated_user} <- do_update_password(user, new_password, new_password_confirmation),
         {_count, nil} <- UserSessionQueries.delete_user_sessions(user.id) do
      {:ok, updated_user}
    else
      {:error, :invalid_password} ->
        {:error, "Current password is incorrect"}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  # Private helper functions for email/password updates

  defp verify_current_password(user, password) do
    if Password.verify_password(password, user.password_hash) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  defp validate_new_password(password, password_confirmation) do
    cond do
      password != password_confirmation ->
        {:error, "Passwords do not match"}

      String.length(password) < 8 ->
        {:error, "Password must be at least 8 characters long"}

      true ->
        :ok
    end
  end

  defp ensure_not_same_as_old(user, new_password) do
    if Password.verify_password(new_password, user.password_hash) do
      {:error, "New password must be different from current password"}
    else
      :ok
    end
  end

  defp do_update_password(user, new_password, new_password_confirmation) do
    UserQueries.update_user_password(user, new_password, new_password_confirmation)
  end

  defp format_changeset_error(%Changeset{} = changeset) do
    ChangesetUtils.get_first_error(changeset)
  end

  defp validate_email_format(email) do
    case EmailValidator.validate(email) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp validate_email_not_same(current_email, new_email) do
    if String.downcase(String.trim(current_email)) == String.downcase(String.trim(new_email)) do
      {:error, :same_email}
    else
      :ok
    end
  end

  defp verify_email_change_in_transaction(user, old_email, new_email) do
    UserQueries.transaction(fn ->
      # Confirm the email change
      case UserQueries.confirm_email_change(user) do
        {:ok, updated_user} ->
          # Invalidate all existing sessions for security
          UserSessionQueries.delete_user_sessions(updated_user.id)

          Logger.info("Email change verified successfully",
            user_id: updated_user.id,
            old_email: old_email,
            new_email: new_email
          )

          %{user: updated_user}

        {:error, changeset} ->
          UserQueries.rollback({:changeset_error, format_changeset_error(changeset)})
      end
    end)
  end

  defp check_email_change_token_validity(user) do
    case user.email_change_sent_at do
      nil ->
        {:error, :token_expired}

      sent_at ->
        # Token expires after 24 hours
        expiry_time = DateTime.add(sent_at, 24 * 60 * 60, :second)

        if DateTime.compare(DateTime.utc_now(), expiry_time) == :lt do
          :ok
        else
          {:error, :token_expired}
        end
    end
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
    with {:ok, user, message} <- Registration.register_user(params, socket_or_conn, opts) do
      # Broadcast registration event
      Task.start(fn ->
        metadata = Keyword.get(opts, :metadata, %{})
        PubSub.broadcast_user_registered(user, metadata)
      end)

      {:ok, user, message}
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
