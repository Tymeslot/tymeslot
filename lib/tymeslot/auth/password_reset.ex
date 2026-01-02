defmodule Tymeslot.Auth.PasswordReset do
  @moduledoc """
  Handles password reset functionality for user accounts.
  """

  require Logger

  alias Tymeslot.Auth.Helpers.{AccountLogging, ErrorFormatting}
  alias Tymeslot.DatabaseQueries.UserSessionQueries
  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.{AuthInputProcessor, RateLimiter, Token}
  alias Tymeslot.Utils.UrlBuilder
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Initiates the password reset process for a given email.

  ## Parameters
    - email: String.t() (user email)
    - opts: Keyword list

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure
  """
  @spec initiate_reset(String.t(), keyword()) ::
          {:ok, atom(), String.t()}
          | {:error, atom(), String.t()}
  def initiate_reset(email, opts \\ []) do
    user_queries = Keyword.get(opts, :user_queries_module, Config.user_queries_module())
    ip = extract_ip_from_opts(opts)

    case RateLimiter.check_password_reset_rate_limit(email, ip) do
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
      :ok -> process_password_reset_secure(email, user_queries)
    end
  end

  # Secure implementation that prevents timing attacks and email enumeration
  defp process_password_reset_secure(email, user_queries) do
    task = Task.async(fn -> handle_password_reset_attempt(email, user_queries) end)

    case Task.await(task, 5000) do
      {:oauth_user_error, message} ->
        {:error, :oauth_user, message}

      _ ->
        # Always return the same message for non-OAuth cases to prevent user enumeration
        {:ok, :reset_initiated,
         "If an account exists with this email address, password reset instructions have been sent."}
    end
  end

  defp handle_password_reset_attempt(email, user_queries) do
    case user_queries.get_user_by_email(email) do
      {:error, :not_found} ->
        # Simulate work to match timing of successful case
        Process.sleep(:rand.uniform(50) + 50)
        AccountLogging.log_operation_failure("password_reset", email, :user_not_found)
        :user_not_found

      {:ok, user} ->
        case handle_user_found(user, user_queries) do
          {:ok, _, _} -> :email_sent
          {:error, :oauth_user, message} -> {:oauth_user_error, message}
          _ -> :error
        end
    end
  end

  defp handle_user_found(user, user_queries) do
    case user.provider do
      provider when provider in [nil, "email"] ->
        process_regular_user_reset(user, user_queries)

      provider when provider in ["google", "github"] ->
        handle_oauth_user_reset(user, provider)

      provider ->
        handle_unknown_provider_reset(user, provider)
    end
  end

  defp extract_ip_from_opts(opts) do
    case Keyword.get(opts, :ip) do
      nil ->
        case Keyword.get(opts, :socket_or_conn) do
          nil -> nil
          socket_or_conn -> safe_client_ip(socket_or_conn)
        end

      ip ->
        ip
    end
  end

  defp safe_client_ip(socket_or_conn) do
    ClientIP.get(socket_or_conn)
  rescue
    _ -> nil
  end

  defp process_regular_user_reset(user, user_queries) do
    {token, expiry} = Token.generate_password_reset_token()

    case store_reset_token(user, token, expiry, user_queries) do
      {:ok, updated_user} ->
        reset_url = build_reset_url(token)
        send_reset_email_and_log(updated_user, reset_url)
        AccountLogging.log_password_reset(updated_user, "initiated")

        {:ok, :email_sent, "Password reset instructions have been sent to your email."}

      {:error, _reason} ->
        AccountLogging.log_operation_failure(
          "password_reset",
          user.email,
          :token_storage_failed,
          %{user_id: user.id}
        )

        {:error, :server_error, "Unable to send password reset email. Please try again later."}
    end
  end

  defp send_reset_email_and_log(user, reset_url) do
    case send_password_reset_email(user, reset_url) do
      {:ok, _} ->
        Logger.info("Password reset email sent", %{
          user_id: user.id,
          email: user.email,
          event: :password_reset_email_sent
        })

      {:error, reason} ->
        Logger.error("Failed to send password reset email", %{
          user_id: user.id,
          email: user.email,
          reason: inspect(reason),
          event: :password_reset_email_failed
        })
    end
  end

  defp handle_oauth_user_reset(user, provider) do
    AccountLogging.log_operation_failure("password_reset", user.email, :oauth_user, %{
      user_id: user.id,
      provider: provider
    })

    {:error, :oauth_user, ErrorFormatting.format_password_reset_error(:oauth_user)}
  end

  defp handle_unknown_provider_reset(user, provider) do
    AccountLogging.log_operation_failure("password_reset", user.email, :oauth_user, %{
      user_id: user.id,
      provider: provider
    })

    {:error, :oauth_user, ErrorFormatting.format_password_reset_error(:oauth_user)}
  end

  @doc """
  Verifies a password reset token.

  ## Parameters
    - token: String.t() (password reset token)
    - opts: Keyword list

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure
  """
  @spec verify_token(String.t(), keyword()) ::
          {:ok, map(), String.t()}
          | {:error, atom(), String.t()}
  def verify_token(token, _opts \\ []) do
    case Config.user_queries_module().get_user_by_reset_token(token) do
      {:error, :not_found} ->
        Logger.warning("Invalid password reset token", %{
          # Log only part of the token for security
          token: String.slice(token, 0, 8) <> "...",
          event: :password_reset_invalid_token
        })

        {:error, :invalid_token, "Invalid or expired password reset token."}

      {:ok, user} ->
        # Calculate expiry as reset_sent_at + 2 hours
        expiry = DateTime.add(user.reset_sent_at, 2 * 3600, :second)

        case Token.verify_token(token, expiry) do
          {:ok, _} ->
            {:ok, Map.from_struct(user), "Token verified successfully."}

          {:error, :token_expired} ->
            Logger.warning("Password reset token expired", %{
              user_id: user.id,
              email: user.email,
              event: :password_reset_token_expired
            })

            {:error, :token_expired,
             "Your reset token has expired. Please request a new password reset."}
        end
    end
  end

  @doc """
  Resets the password for a user.

  ## Parameters
    - token: String.t() (password reset token)
    - new_password: String.t() (new password)
    - password_confirmation: String.t() (password confirmation)
    - opts: Keyword list

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure
  """
  @spec reset_password(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map(), String.t()}
          | {:error, atom(), String.t()}
  def reset_password(token, new_password, password_confirmation, opts \\ []) do
    with {:ok, user, _} <- verify_token(token, opts),
         {:ok, _} <- validate_password_input(new_password, password_confirmation, user),
         {:ok, updated_user} <- perform_password_update(user, new_password),
         {:ok, final_user} <- perform_token_clear(updated_user),
         :ok <- invalidate_all_sessions(final_user) do
      {:ok, Map.from_struct(final_user), "Your password has been reset successfully"}
    else
      {:error, reason, message} -> {:error, reason, message}
    end
  end

  defp validate_password_input(new_password, password_confirmation, user) do
    case AuthInputProcessor.validate_password_reset_form(
           %{"password" => new_password, "password_confirmation" => password_confirmation},
           metadata: %{}
         ) do
      {:ok, _sanitized} ->
        {:ok, :validated}

      {:error, errors} when is_map(errors) ->
        AccountLogging.log_validation_failure("password_reset", user.email, errors, %{
          user_id: user.id
        })

        error_message = ErrorFormatting.format_validation_errors(errors)
        {:error, :invalid_input, "Please fix the following errors: #{error_message}"}
    end
  end

  defp perform_password_update(user, new_password) do
    # Get password_confirmation from the user struct since we validated it earlier
    # Both should be the same since validation passed
    password_confirmation = new_password

    case update_user_password(user, new_password, password_confirmation) do
      {:ok, updated_user} ->
        {:ok, updated_user}

      {:error, errors} ->
        Logger.error("Failed to update password", %{
          user_id: user.id,
          email: user.email,
          errors: inspect(errors),
          event: :password_reset_update_password_failed
        })

        {:error, :invalid_password,
         "The password couldn't be updated. Please try again with a different password."}
    end
  end

  defp perform_token_clear(user) do
    case clear_reset_token(user) do
      {:ok, final_user} ->
        AccountLogging.log_password_reset(final_user, "completed")
        {:ok, final_user}

      {:error, reason} ->
        AccountLogging.log_operation_failure("password_reset", user.email, :clear_token_failed, %{
          user_id: user.id,
          reason: inspect(reason)
        })

        {:error, :server_error,
         "An error occurred while resetting your password. Please try again."}
    end
  end

  # Private functions

  defp store_reset_token(user, token, _expiry, user_queries) do
    user_queries.set_reset_token(user, token)
  end

  defp update_user_password(user, new_password, password_confirmation) do
    actual_user =
      case user do
        %UserSchema{} ->
          user

        %{email: email} when is_binary(email) ->
          case Config.user_queries_module().get_user_by_email(email) do
            {:ok, user} -> user
            _ -> nil
          end

        _ ->
          nil
      end

    case actual_user do
      %UserSchema{} = valid_user ->
        # Pass raw passwords to let the changeset handle validation and hashing
        Config.user_queries_module().reset_password(valid_user, %{
          password: new_password,
          password_confirmation: password_confirmation
        })

      _ ->
        {:error, :invalid_user}
    end
  end

  defp clear_reset_token(user) do
    Config.user_queries_module().set_reset_token(user, nil)
  end

  # Private helper to build the reset URL
  defp build_reset_url(token) do
    UrlBuilder.password_reset_url(token)
  end

  # Private helper to send password reset email
  defp send_password_reset_email(user, reset_url) do
    # Use the email worker to send the password reset email asynchronously
    case EmailWorker.schedule_password_reset(user.id, reset_url) do
      :ok ->
        Logger.info("Password reset email job scheduled for user_id=#{user.id}")
        {:ok, :ok}

      {:error, reason} ->
        Logger.error(
          "Failed to schedule password reset email for user_id=#{user.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Invalidate all user sessions after password reset for security
  defp invalidate_all_sessions(user) do
    case UserSessionQueries.delete_user_sessions(user.id) do
      {_count, _} ->
        Logger.info("Invalidated all sessions after password reset", %{
          user_id: user.id,
          email: user.email,
          event: :sessions_invalidated_password_reset
        })

        :ok
    end
  end
end
