defmodule Tymeslot.Auth.Helpers.AccountLogging do
  @moduledoc """
  Domain-specific structured logging for account operations.

  Provides consistent, structured logging across all account modules
  to improve debugging, monitoring, and audit trail capabilities.
  """

  alias Tymeslot.Security.SecurityLogger

  require Logger

  @type logging_context :: %{optional(atom()) => term()}
  @type user_entity :: %{
          required(:id) => integer(),
          required(:email) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Logs successful account operations.

  ## Parameters
  - `operation`: The operation type (e.g., "authentication", "registration")
  - `identifier`: User identifier (email, user_id, etc.)
  - `context`: Additional context map (optional)

  ## Examples
      log_operation_success("authentication", "user@example.com", %{user_id: 123})
  """
  @spec log_operation_success(String.t(), String.t() | integer(), logging_context()) :: :ok
  def log_operation_success(operation, identifier, context \\ %{}) do
    Logger.info(
      "Account operation successful",
      build_metadata(
        [
          {:operation, operation},
          {:identifier, mask_identifier(identifier)},
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
  @spec log_operation_failure(
          String.t(),
          String.t() | integer(),
          atom() | String.t(),
          logging_context()
        ) :: :ok
  def log_operation_failure(operation, identifier, reason, context \\ %{}) do
    Logger.warning(
      "Account operation failed",
      build_metadata(
        [
          {:operation, operation},
          {:identifier, mask_identifier(identifier)},
          {:reason, reason},
          {:event, "#{operation}_failure"}
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
  @spec log_validation_failure(
          String.t(),
          String.t() | integer(),
          map() | list(),
          logging_context()
        ) :: :ok
  def log_validation_failure(operation, identifier, errors, context \\ %{}) do
    Logger.warning(
      "Account input validation failed",
      build_metadata(
        [
          {:operation, operation},
          {:identifier, mask_identifier(identifier)},
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
  @spec log_user_created(user_entity(), logging_context()) :: :ok
  def log_user_created(user, context \\ %{}) do
    Logger.info(
      "User created successfully",
      build_metadata(
        [
          {:user_id, user.id},
          {:email, mask_identifier(user.email)},
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
  @spec log_user_verified(user_entity(), String.t(), logging_context()) :: :ok
  def log_user_verified(user, verification_type, context \\ %{}) do
    Logger.info(
      "User verification successful",
      build_metadata(
        [
          {:user_id, user.id},
          {:email, mask_identifier(user.email)},
          {:verification_type, verification_type},
          {:event, "user_#{verification_type}_verified"}
        ],
        context
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
  @spec log_password_reset(user_entity(), String.t(), logging_context()) :: :ok
  def log_password_reset(user, stage, context \\ %{}) do
    Logger.info(
      "Password reset",
      build_metadata(
        [
          {:user_id, user.id},
          {:email, mask_identifier(user.email)},
          {:stage, stage},
          {:event, "password_reset_#{stage}"}
        ],
        context
      )
    )
  end

  # Private helpers

  # Masks a binary identifier the way `SecurityLogger` masks emails, so an
  # email address never reaches Logger metadata verbatim. Anything that
  # isn't a parseable email (e.g. a token, mistakenly passed as an
  # identifier) is dropped entirely rather than logged unmasked. A user id
  # (integer) is not PII in this sense and passes through as-is.
  @spec mask_identifier(String.t() | integer() | term()) :: String.t() | integer() | nil
  defp mask_identifier(identifier) when is_integer(identifier), do: identifier

  defp mask_identifier(identifier) when is_binary(identifier),
    do: SecurityLogger.mask_email(identifier)

  defp mask_identifier(_other), do: nil

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
