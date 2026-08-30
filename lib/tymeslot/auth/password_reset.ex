defmodule Tymeslot.Auth.PasswordReset do
  @moduledoc """
  Handles password reset functionality for user accounts.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Auth.{
    ErrorFormatter,
    Helpers.AccountLogging,
    Session,
    UserSchema,
    Validation
  }

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Repo
  alias Tymeslot.Security.{InputProcessor, RateLimiter, SecurityLogger, Token}
  alias Tymeslot.Utils.UrlBuilder
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

    with {:ok, validated_email} <- validate_email_format(email),
         :ok <- check_reset_rate_limit(validated_email, ip) do
      process_password_reset_secure(validated_email, user_queries)
    else
      {:error, reason, message} -> {:error, reason, message}
    end
  end

  defp check_reset_rate_limit(email, ip) do
    case RateLimiter.check_password_reset_rate_limit(email, ip) do
      :ok ->
        :ok

      {:error, :rate_limited, message} ->
        SecurityLogger.log_rate_limit_violation(email, "password_reset", %{ip_address: ip})
        {:error, :rate_limited, message}
    end
  end

  # Secure implementation that prevents timing attacks and email enumeration.
  # The timing randomisation lives inside handle_password_reset_attempt/2
  # (Process.sleep for the not-found case), so no Task wrapping is needed here.
  defp process_password_reset_secure(email, user_queries) do
    case handle_password_reset_attempt(email, user_queries) do
      {:oauth_user_error, message} ->
        {:error, :oauth_user, message}

      _other ->
        # Always return the same message for non-OAuth cases to prevent user enumeration
        {:ok, :reset_initiated,
         dgettext(
           "auth",
           "If an account exists with this email address, password reset instructions have been sent."
         )}
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
          {:ok, _user, _token} -> :email_sent
          {:error, :oauth_user, message} -> {:oauth_user_error, message}
          _other -> :error
        end
    end
  end

  defp handle_user_found(user, _user_queries) do
    case user.provider do
      provider when provider in [nil, "email"] ->
        process_regular_user_reset(user)

      provider ->
        handle_oauth_user_reset(user, provider)
    end
  end

  defp validate_email_format(email) do
    case InputProcessor.validate_field(email, :email) do
      {:ok, validated} -> {:ok, validated}
      {:error, msg} -> {:error, :invalid_input, msg}
    end
  end

  # `:ip_address` is the canonical key (matches `PasswordUpdate.update_user_password/5`'s
  # convention, and what the audit entry itself is keyed under); `:ip` is
  # accepted too since `AuthActions` still passes it for this flow's callers.
  defp extract_ip_from_opts(opts) do
    opts[:ip_address] || opts[:ip] ||
      case opts[:socket_or_conn] do
        nil -> nil
        soc -> ClientIP.get(soc)
      end
  end

  defp process_regular_user_reset(user) do
    {token, _expiry} = Token.generate_password_reset_token()
    reset_url = UrlBuilder.password_reset_url(token)
    token_hash = Token.hash_token(token)

    # Persist the token first so it is valid in the database before the job runs.
    # The job carries the token's hash; the worker discards it at send time if a
    # newer request has since rotated the stored token, so an in-flight or
    # retrying job can never deliver an invalidated link.
    with {:ok, updated_user} <- persist_reset_token_and_log(user, token),
         {:ok, _status} <- schedule_reset_email(updated_user, reset_url, token_hash) do
      {:ok, :email_sent,
       dgettext("auth", "Password reset instructions have been sent to your email.")}
    else
      {:error, :token_storage_failed} ->
        {:error, :server_error,
         dgettext("auth", "Unable to send password reset email. Please try again later.")}

      {:error, reason} ->
        Logger.error("Failed to send password reset email",
          user_id: user.id,
          email: user.email,
          reason: inspect(reason),
          event: :password_reset_email_failed
        )

        {:error, :server_error,
         dgettext("auth", "Unable to send password reset email. Please try again later.")}
    end
  end

  defp persist_reset_token_and_log(user, token) do
    case Config.user_token_queries_module().set_reset_token(user, token) do
      {:ok, updated_user} ->
        # Logged at persist time — the email is scheduled separately afterwards, so
        # this records token storage only, not delivery (mirrors the verification flow).
        Logger.info("Password reset token stored",
          user_id: updated_user.id,
          email: updated_user.email,
          event: :password_reset_token_persisted
        )

        AccountLogging.log_password_reset(updated_user, "initiated")

        {:ok, updated_user}

      {:error, _error_reason} ->
        AccountLogging.log_operation_failure(
          "password_reset",
          user.email,
          :token_storage_failed,
          %{user_id: user.id}
        )

        {:error, :token_storage_failed}
    end
  end

  defp schedule_reset_email(user, reset_url, token_hash) do
    case EmailScheduler.schedule_password_reset(user.id, reset_url, token_hash) do
      {:ok, :scheduled} ->
        {:ok, :scheduled}

      {:ok, :duplicate} ->
        Logger.info("Password reset email already queued; updated with fresh token",
          user_id: user.id,
          email: user.email,
          event: :password_reset_email_deduplicated
        )

        {:ok, :duplicate}

      {:error, reason} ->
        Logger.error("Failed to schedule password reset email",
          user_id: user.id,
          email: user.email,
          reason: inspect(reason),
          event: :password_reset_email_failed
        )

        {:error, reason}
    end
  end

  defp handle_oauth_user_reset(user, provider) do
    AccountLogging.log_operation_failure("password_reset", user.email, :oauth_user, %{
      user_id: user.id,
      provider: provider
    })

    {:error, :oauth_user, ErrorFormatter.format_password_reset_error(:oauth_user)}
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
    case Config.user_token_queries_module().get_user_by_reset_token(token) do
      {:error, :not_found} ->
        Logger.warning("Invalid password reset token",
          # Log only part of the token for security
          token: String.slice(token, 0, 8) <> "...",
          event: :password_reset_invalid_token
        )

        {:error, :invalid_token, dgettext("auth", "Invalid or expired password reset token.")}

      {:ok, user} ->
        # Calculate expiry as reset_sent_at + 2 hours
        expiry = DateTime.add(user.reset_sent_at, 2 * 3600, :second)

        case Token.verify_token(token, expiry) do
          {:ok, _verified_token} ->
            {:ok, Map.from_struct(user), dgettext("auth", "Token verified successfully.")}

          {:error, :token_expired} ->
            Logger.warning("Password reset token expired",
              user_id: user.id,
              email: user.email,
              event: :password_reset_token_expired
            )

            {:error, :token_expired,
             dgettext(
               "auth",
               "Your reset token has expired. Please request a new password reset."
             )}
        end
    end
  end

  @doc """
  Resets the password for a user.

  ## Parameters
    - token: String.t() (password reset token)
    - new_password: String.t() (new password)
    - password_confirmation: String.t() (password confirmation)
    - opts: Keyword list; `:ip_address` (or `:ip`) and `:user_agent` are recorded on the audit
      entry the completed reset emits

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure
  """
  @spec reset_password(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map(), String.t()}
          | {:error, atom(), String.t()}
  def reset_password(token, new_password, password_confirmation, opts \\ []) do
    case consume_and_update(token, new_password, password_confirmation) do
      {:ok, updated_user} ->
        AccountLogging.log_password_reset(updated_user, "completed")
        :ok = invalidate_all_sessions(updated_user)

        SecurityLogger.log_password_change(updated_user.id, %{
          ip_address: extract_ip_from_opts(opts),
          user_agent: opts[:user_agent],
          sessions_invalidated: true
        })

        {:ok, Map.from_struct(updated_user),
         dgettext("auth", "Your password has been reset successfully")}

      {:error, reason, message} ->
        {:error, reason, message}
    end
  end

  # The lookup + update run inside a single transaction with `FOR UPDATE` on
  # the token row so two concurrent requests can't both pass the
  # `used_at IS NULL` check and each apply a password update — without the
  # lock, the later update silently overwrites the earlier one.
  defp consume_and_update(token, new_password, password_confirmation) do
    txn =
      Repo.transaction(fn ->
        with {:ok, user} <- consume_reset_token(token),
             {:ok, _validated} <-
               validate_password_input(new_password, password_confirmation, user),
             {:ok, updated_user} <- perform_password_update(user, new_password) do
          updated_user
        else
          {:error, reason, message} -> Repo.rollback({reason, message})
        end
      end)

    case txn do
      {:ok, user} -> {:ok, user}
      {:error, {reason, message}} -> {:error, reason, message}
    end
  end

  defp consume_reset_token(token) do
    case Config.user_token_queries_module().get_user_by_reset_token_for_update(token) do
      {:error, :not_found} ->
        Logger.warning("Invalid password reset token",
          token: String.slice(token, 0, 8) <> "...",
          event: :password_reset_invalid_token
        )

        {:error, :invalid_token, dgettext("auth", "Invalid or expired password reset token.")}

      {:ok, user} ->
        expiry = DateTime.add(user.reset_sent_at, 2 * 3600, :second)

        case Token.verify_token(token, expiry) do
          {:ok, _verified} ->
            {:ok, user}

          {:error, :token_expired} ->
            Logger.warning("Password reset token expired",
              user_id: user.id,
              email: user.email,
              event: :password_reset_token_expired
            )

            {:error, :token_expired,
             dgettext(
               "auth",
               "Your reset token has expired. Please request a new password reset."
             )}
        end
    end
  end

  defp validate_password_input(new_password, password_confirmation, user) do
    params = %{"password" => new_password, "password_confirmation" => password_confirmation}

    case Validation.validate_new_password_input(params) do
      {:ok, _sanitized} ->
        {:ok, :validated}

      {:error, errors} ->
        AccountLogging.log_validation_failure("password_reset", user.email, errors, %{
          user_id: user.id
        })

        {:error, :invalid_input, password_error_message(errors)}
    end
  end

  # The password validator's messages are already whole sentences naming their
  # own field ("Password must contain at least one special character"), and the
  # confirmation field is validated against the same rules, so it reports the
  # same failure. Running that through the generic field-prefixing formatter
  # produced "Password Password must contain… Password confirmation Password
  # must contain…". The distinct messages, joined, are what a user can act on.
  defp password_error_message(errors) do
    errors
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp perform_password_update(user, new_password) do
    case update_user_password(user, new_password) do
      {:ok, updated_user} ->
        {:ok, updated_user}

      {:error, errors} ->
        Logger.error("Failed to update password",
          user_id: user.id,
          email: user.email,
          errors: inspect(errors),
          event: :password_reset_update_password_failed
        )

        {:error, :invalid_password,
         dgettext(
           "auth",
           "The password couldn't be updated. Please try again with a different password."
         )}
    end
  end

  # Private functions

  defp update_user_password(user, new_password) do
    actual_user =
      case user do
        %UserSchema{} ->
          user

        %{email: email} when is_binary(email) ->
          case Config.user_queries_module().get_user_by_email(email) do
            {:ok, user} -> user
            _error -> nil
          end

        _invalid ->
          nil
      end

    case actual_user do
      %UserSchema{} = valid_user ->
        # Pass raw passwords to let the changeset handle validation and hashing
        Config.user_queries_module().reset_password(valid_user, %{
          password: new_password,
          password_confirmation: new_password
        })

      _invalid ->
        {:error, :invalid_user}
    end
  end

  # Invalidate all user sessions after password reset for security. Also
  # disconnects any still-connected live sockets so the revocation is immediate.
  defp invalidate_all_sessions(user) do
    Session.revoke_all_sessions(user.id)

    Logger.info("Invalidated all sessions after password reset",
      user_id: user.id,
      email: user.email,
      event: :sessions_invalidated_password_reset
    )

    :ok
  end
end
