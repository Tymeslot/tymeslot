defmodule Tymeslot.Auth.Registration do
  @moduledoc """
  Handles user registration for Foundersbundle.
  """

  require Logger
  alias Tymeslot.Auth.Helpers.{AccountLogging, ErrorFormatting}
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Security.{AuthInputProcessor, RateLimiter}
  alias TymeslotWeb.Helpers.ClientIP
  # Use function instead of compile-time module attribute to allow test-time mocking
  defp verification_module,
    do: Application.get_env(:auth, :verification_module, Tymeslot.Auth.Verification)

  @doc """
  Registers a new user with the provided parameters.

  ## Parameters
    - params: User registration parameters
    - socket_or_conn: Phoenix socket or connection
    - opts: Optional parameters including:
      - :return_url - URL to redirect to after registration
      - :metadata - Map of app-specific data to include in PubSub event

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure with appropriate flash message
  """
  @spec register_user(map(), Phoenix.LiveView.Socket.t() | Plug.Conn.t(), Keyword.t()) ::
          {:ok, term(), String.t()} | {:error, atom(), String.t()}
  def register_user(params, socket_or_conn, opts \\ []) do
    with {:ok, validated_params} <- validate_input(params),
         :ok <- check_rate_limit(params["email"], socket_or_conn),
         {:ok, user} <- create_and_verify_user(validated_params, socket_or_conn, opts) do
      {:ok, user,
       "Account created successfully. Please check your email for verification instructions."}
    else
      {:error, reason, message} -> {:error, reason, message}
    end
  end

  defp validate_input(params) do
    case AuthInputProcessor.validate_signup_input(params) do
      {:ok, validated_params} ->
        {:ok, validated_params}

      {:error, errors} ->
        AccountLogging.log_validation_failure("signup", params["email"], errors)
        formatted_errors = ErrorFormatting.format_validation_errors(errors)
        {:error, :input, "Please correct the following errors: #{formatted_errors}"}
    end
  end

  defp check_rate_limit(email, socket_or_conn) do
    ip = ClientIP.get(socket_or_conn)

    case RateLimiter.check_signup_rate_limit(email, ip) do
      :ok ->
        :ok

      {:error, :rate_limited, message} ->
        {:error, :rate_limited, message}
    end
  end

  defp create_and_verify_user(validated_params, socket_or_conn, opts) do
    # Check for case-insensitive duplicate emails before attempting creation
    case check_email_uniqueness(validated_params["email"]) do
      {:error, :duplicate} ->
        AccountLogging.log_operation_failure(
          "registration",
          validated_params["email"],
          :duplicate_email
        )

        {:error, :auth,
         "This email is already registered. Please use a different email or sign in."}

      :ok ->
        case create_user(validated_params) do
          {:ok, user} ->
            AccountLogging.log_user_created(user)
            verify_and_notify_user(user, validated_params, socket_or_conn, opts)

          {:error, :auth, reason} ->
            AccountLogging.log_operation_failure(
              "registration",
              validated_params["email"],
              reason
            )

            {:error, :auth, ErrorFormatting.format_user_friendly_error("registration", reason)}
        end
    end
  end

  defp check_email_uniqueness(email) do
    alias Tymeslot.DatabaseSchemas.UserSchema
    alias Tymeslot.Repo
    import Ecto.Query

    # Case-insensitive email check
    case UserSchema
         |> where([u], fragment("LOWER(?) = LOWER(?)", u.email, ^email))
         |> Repo.one() do
      nil ->
        :ok

      _user ->
        {:error, :duplicate}
    end
  end

  defp verify_and_notify_user(user, validated_params, socket_or_conn, opts) do
    verification = verification_module()

    case verification.verify_user_email(socket_or_conn, user, validated_params) do
      {:ok, _updated_user} ->
        # Create user profile with default settings
        case ProfileQueries.create_profile(user.id) do
          {:ok, _profile} ->
            Logger.info("Created profile for user_id=#{user.id}")

            # Notify apps about successful registration via PubSub
            metadata = Keyword.get(opts, :metadata, %{})
            PubSub.broadcast_user_registered(user, metadata)
            {:ok, user}

          {:error, reason} ->
            Logger.error("Profile creation failed for user_id=#{user.id}: #{inspect(reason)}")

            {:error, :profile_creation,
             "Account created but profile creation failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("Verification failed for user_id=#{user.id}: #{inspect(reason)}")
        {:error, :verification, "Account created but verification failed: #{inspect(reason)}"}
    end
  end

  defp create_user(params) do
    user_params = %{
      email: params["email"],
      password: params["password"],
      # Using same password since no confirmation field in form
      password_confirmation: params["password"],
      terms_accepted: params["terms_accepted"]
    }

    case Config.user_queries_module().create_user(user_params) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        # Log only the constraint errors without sensitive data
        constraint_errors = extract_constraint_errors(changeset)
        Logger.error("User creation failed with constraints: #{inspect(constraint_errors)}")
        {:error, :auth, ErrorFormatting.format_changeset_errors(changeset)}
    end
  end

  # Helper function to safely extract constraint errors without sensitive data
  defp extract_constraint_errors(changeset) do
    changeset.errors
    |> Enum.filter(fn {_field, {_message, opts}} ->
      Keyword.has_key?(opts, :constraint) || Keyword.has_key?(opts, :constraint_name)
    end)
    |> Enum.map(fn {field, {message, opts}} ->
      %{
        field: field,
        message: message,
        constraint: Keyword.get(opts, :constraint),
        constraint_name: Keyword.get(opts, :constraint_name)
      }
    end)
  end
end
