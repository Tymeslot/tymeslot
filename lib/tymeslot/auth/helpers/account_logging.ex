defmodule Tymeslot.Auth.Helpers.AccountLogging do
  @moduledoc """
  Domain-specific structured logging for account operations.

  Provides consistent, structured logging across all account modules
  to improve debugging, monitoring, and audit trail capabilities.
  """

  require Logger

  @doc """
  Logs successful account operations.

  ## Parameters
  - `operation`: The operation type (e.g., "authentication", "registration")
  - `identifier`: User identifier (email, user_id, etc.)
  - `context`: Additional context map (optional)

  ## Examples
      log_operation_success("authentication", "user@example.com", %{user_id: 123})
  """
  @spec log_operation_success(String.t(), String.t() | integer(), map()) :: :ok
  def log_operation_success(operation, identifier, context \\ %{}) do
    Logger.info(
      "#{String.capitalize(operation)} successful",
      build_metadata(
        [
          {:operation, operation},
          {:identifier, identifier},
          {:event, "#{operation}_success"}
        ],
        context
      )
    )
  end

  @doc """
  Logs failed account operations.

  ## Parameters
  - `operation`: The operation type (e.g., "authentication", "registration")
  - `identifier`: User identifier (email, user_id, etc.)
  - `reason`: The failure reason
  - `context`: Additional context map (optional)

  ## Examples
      log_operation_failure("authentication", "user@example.com", :invalid_password)
  """
  @spec log_operation_failure(String.t(), String.t() | integer(), atom() | String.t(), map()) ::
          :ok
  def log_operation_failure(operation, identifier, reason, context \\ %{}) do
    Logger.warning(
      "#{String.capitalize(operation)} failed",
      build_metadata(
        [
          {:operation, operation},
          {:identifier, identifier},
          {:reason, reason},
          {:event, "#{operation}_failure"}
        ],
        context
      )
    )
  end

  @doc """
  Logs rate limit exceeded events.

  ## Parameters
  - `operation`: The operation type being rate limited
  - `identifier`: User identifier (email, user_id, etc.)
  - `context`: Additional context map (optional)

  ## Examples
      log_rate_limit_exceeded("signup", "user@example.com")
  """
  @spec log_rate_limit_exceeded(String.t(), String.t() | integer(), map()) :: :ok
  def log_rate_limit_exceeded(operation, identifier, context \\ %{}) do
    Logger.warning(
      "Rate limit exceeded for #{operation}",
      build_metadata(
        [
          {:operation, operation},
          {:identifier, identifier},
          {:event, "#{operation}_rate_limit_exceeded"}
        ],
        context
      )
    )
  end

  @doc """
  Logs validation failures.

  ## Parameters
  - `operation`: The operation type (e.g., "signup", "password_reset")
  - `identifier`: User identifier (email, user_id, etc.)
  - `errors`: Validation errors map or list
  - `context`: Additional context map (optional)

  ## Examples
      log_validation_failure("signup", "user@example.com", %{email: ["invalid format"]})
  """
  @spec log_validation_failure(String.t(), String.t() | integer(), map() | list(), map()) :: :ok
  def log_validation_failure(operation, identifier, errors, context \\ %{}) do
    Logger.warning(
      "#{String.capitalize(operation)} input validation failed",
      build_metadata(
        [
          {:operation, operation},
          {:identifier, identifier},
          {:errors, inspect(errors)},
          {:event, "#{operation}_validation_failure"}
        ],
        context
      )
    )
  end

  @doc """
  Logs user creation events.

  ## Parameters
  - `user`: The created user struct/map
  - `context`: Additional context map (optional)

  ## Examples
      log_user_created(%{id: 123, email: "user@example.com"})
  """
  @spec log_user_created(map(), map()) :: :ok
  def log_user_created(user, context \\ %{}) do
    Logger.info(
      "User created successfully",
      build_metadata(
        [
          {:user_id, user.id},
          {:email, user.email},
          {:event, "user_created"}
        ],
        context
      )
    )
  end

  @doc """
  Logs user verification events.

  ## Parameters
  - `user`: The verified user struct/map
  - `verification_type`: Type of verification (e.g., "email", "token")
  - `context`: Additional context map (optional)

  ## Examples
      log_user_verified(%{id: 123, email: "user@example.com"}, "email")
  """
  @spec log_user_verified(map(), String.t(), map()) :: :ok
  def log_user_verified(user, verification_type, context \\ %{}) do
    Logger.info(
      "User #{verification_type} verification successful",
      build_metadata(
        [
          {:user_id, user.id},
          {:email, user.email},
          {:verification_type, verification_type},
          {:event, "user_#{verification_type}_verified"}
        ],
        context
      )
    )
  end

  @doc """
  Logs session creation events.

  ## Parameters
  - `user`: The user struct/map
  - `session_info`: Session information (optional)
  - `context`: Additional context map (optional)

  ## Examples
      log_session_created(%{id: 123, email: "user@example.com"})
  """
  @spec log_session_created(map(), map(), map()) :: :ok
  def log_session_created(user, session_info \\ %{}, context \\ %{}) do
    Logger.info(
      "Session created successfully",
      build_metadata(
        [
          {:user_id, user.id},
          {:email, user.email},
          {:event, "session_created"}
        ],
        Map.merge(session_info, context)
      )
    )
  end

  @doc """
  Logs password reset events.

  ## Parameters
  - `user`: The user struct/map
  - `stage`: The reset stage ("initiated", "completed", etc.)
  - `context`: Additional context map (optional)

  ## Examples
      log_password_reset(%{id: 123, email: "user@example.com"}, "initiated")
  """
  @spec log_password_reset(map(), String.t(), map()) :: :ok
  def log_password_reset(user, stage, context \\ %{}) do
    Logger.info(
      "Password reset #{stage}",
      build_metadata(
        [
          {:user_id, user.id},
          {:email, user.email},
          {:stage, stage},
          {:event, "password_reset_#{stage}"}
        ],
        context
      )
    )
  end

  @doc """
  Logs security events (suspicious activity, etc.).

  ## Parameters
  - `event_type`: Type of security event (e.g., "suspicious_login", "token_abuse")
  - `identifier`: User identifier (email, user_id, etc.)
  - `details`: Event details
  - `context`: Additional context map (optional)

  ## Examples
      log_security_event("suspicious_login", "user@example.com", "Multiple failed attempts")
  """
  @spec log_security_event(String.t(), String.t() | integer(), String.t(), map()) :: :ok
  def log_security_event(event_type, identifier, details, context \\ %{}) do
    Logger.warning(
      "Security event: #{event_type}",
      build_metadata(
        [
          {:event_type, event_type},
          {:identifier, identifier},
          {:details, details},
          {:event, "security_#{event_type}"}
        ],
        context
      )
    )
  end

  # Private helpers
  defp build_metadata(base_kv, context) when is_list(base_kv) and is_map(context) do
    # Extract only atom-keyed entries from context for metadata; attach the rest under :context
    {atom_ctx, other_ctx} = Enum.split_with(context, fn {k, _v} -> is_atom(k) end)

    # Convert to keyword list and append :context if there are non-atom keys
    metadata1 = base_kv ++ atom_ctx
    metadata2 = metadata1 ++ if other_ctx == [], do: [], else: [{:context, Map.new(other_ctx)}]
    metadata2
  end

  defp build_metadata(base_kv, _context) when is_list(base_kv), do: base_kv
end
