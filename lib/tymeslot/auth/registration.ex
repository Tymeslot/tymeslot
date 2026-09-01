defmodule Tymeslot.Auth.Registration do
  @moduledoc """
  Handles user registration for Tymeslot.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger
  alias Tymeslot.Auth.{AdminBootstrap, ErrorFormatter, Helpers.AccountLogging, UserQueries}
  alias Tymeslot.Infrastructure.{Config, PubSub}
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Security.{InputProcessor, RateLimiter, SecurityLogger}
  alias TymeslotWeb.Helpers.ClientIP

  @type signup_params :: Tymeslot.Auth.Validation.signup_params()

  # Use function instead of compile-time module attribute to allow test-time mocking
  defp verification_module,
    do: Application.get_env(:tymeslot, :verification_module, Tymeslot.Auth.Verification)

  @doc """
  Registers a new user with the provided parameters.

  ## Parameters
    - params: User registration parameters
    - socket_or_conn: Phoenix socket or connection
    - opts: Optional parameters including:
      - :return_url - URL to redirect to after registration
      - :metadata - Map of app-specific data to include in PubSub event
      - :rate_limit_checked - set to `true` when the caller has already
        consumed a signup rate-limit token for this attempt (e.g.
        `Tymeslot.Auth.SignupSecurity.gate/2` on the LiveView signup path),
        so this function skips its own check instead of double-counting

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure with appropriate flash message
  """
  @spec register_user(signup_params(), Phoenix.LiveView.Socket.t() | Plug.Conn.t(), Keyword.t()) ::
          {:ok, term(), String.t()} | {:error, atom(), String.t()} | {:error, :input, map()}
  def register_user(params, socket_or_conn, opts \\ []) do
    with {:ok, validated_params} <- validate_input(params),
         :ok <- check_rate_limit(validated_params["email"], socket_or_conn, opts),
         {:ok, user} <- create_and_verify_user(validated_params, socket_or_conn, opts) do
      {:ok, user,
       dgettext(
         "auth",
         "Account created successfully. Please check your email for verification instructions."
       )}
    else
      {:error, reason, message} -> {:error, reason, message}
    end
  end

  # The signup form collects an email, a password and the terms checkbox, and
  # `create_user/1` persists nothing else. There is no name field to validate.
  @signup_field_spec [
    {"email", :email},
    {"password", :password}
  ]

  defp validate_input(params) do
    case InputProcessor.validate_form(params, @signup_field_spec) do
      {:ok, validated_params} ->
        validate_terms(params, validated_params)

      {:error, errors} ->
        AccountLogging.log_validation_failure("signup", params["email"], errors)
        {:error, :input, errors}
    end
  end

  defp validate_terms(params, validated_params) do
    if Application.get_env(:tymeslot, :enforce_legal_agreements, false) do
      case Map.get(params, "terms_accepted") do
        value when value in ["true", "on", true] ->
          {:ok, validated_params}

        _other ->
          errors = %{
            terms_accepted: dgettext("auth", "Terms of service must be accepted")
          }

          AccountLogging.log_validation_failure("signup", params["email"], errors)
          formatted = ErrorFormatter.format_validation_errors(errors)

          {:error, :input,
           dgettext("auth", "Please correct the following errors: %{errors}", errors: formatted)}
      end
    else
      {:ok, validated_params}
    end
  end

  defp check_rate_limit(email, socket_or_conn, opts) do
    if Keyword.get(opts, :rate_limit_checked, false) do
      :ok
    else
      ip = ClientIP.get(socket_or_conn)

      case RateLimiter.check_signup_rate_limit(email, ip) do
        :ok ->
          :ok

        {:error, :rate_limited, message} ->
          SecurityLogger.log_rate_limit_violation(email, "signup", %{ip_address: ip})
          {:error, :rate_limited, message}
      end
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
         dgettext(
           "auth",
           "This email is already registered. Please use a different email or sign in."
         )}

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

            {:error, :auth, ErrorFormatter.format_user_friendly_error("registration", reason)}
        end
    end
  end

  defp check_email_uniqueness(email) do
    if UserQueries.email_exists_case_insensitive?(email) do
      {:error, :duplicate}
    else
      :ok
    end
  end

  # The profile and the registration broadcast complete the account; the
  # verification email only notifies the user about it. They are ordered that
  # way deliberately: a send that fails or is rate limited must not leave a
  # committed user row with no profile and no broadcast, because the address is
  # then rejected as a duplicate on retry and the account can never be reached.
  defp verify_and_notify_user(user, validated_params, socket_or_conn, opts) do
    case create_profile_and_announce(user, opts) do
      :ok -> send_verification_email(user, validated_params, socket_or_conn)
      {:error, _reason, _message} = error -> error
    end
  end

  defp create_profile_and_announce(user, opts) do
    case Profiles.create_profile(user.id) do
      {:ok, _profile} ->
        Logger.info("Created profile", user_id: user.id)

        # Notify apps about successful registration via PubSub
        metadata = Keyword.get(opts, :metadata, %{})
        PubSub.broadcast_user_registered(user, metadata)
        :ok

      {:error, reason} ->
        Logger.error("Profile creation failed", user_id: user.id, reason: inspect(reason))

        {:error, :profile_creation,
         dgettext("auth", "Account created but profile creation failed: %{reason}",
           reason: inspect(reason)
         )}
    end
  end

  defp send_verification_email(user, validated_params, socket_or_conn) do
    verification = verification_module()

    case verification.verify_user_email(socket_or_conn, user, validated_params) do
      {:ok, _updated_user} ->
        {:ok, user}

      # `Tymeslot.Infrastructure.VerificationBehaviour` declares this three-element
      # member alongside the two-element one; the account is complete, only the
      # email was withheld, so point the user at the resend rather than an error.
      {:error, :rate_limited, _message} ->
        Logger.warning("Verification email rate limited during signup", user_id: user.id)

        {:error, :rate_limited,
         dgettext(
           "auth",
           "Your account was created, but the verification email could not be sent yet. Please wait a few minutes, then use the resend link."
         )}

      {:error, reason} ->
        Logger.error("Verification failed", user_id: user.id, reason: inspect(reason))

        {:error, :verification,
         dgettext("auth", "Account created but verification failed: %{reason}",
           reason: inspect(reason)
         )}
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

    transaction_result =
      Repo.transaction(fn ->
        case Config.user_queries_module().create_user(user_params) do
          {:ok, user} ->
            case AdminBootstrap.maybe_promote_first_user(user) do
              {:ok, bootstrapped_user} -> bootstrapped_user
              {:error, changeset} -> Repo.rollback(changeset)
            end

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case transaction_result do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        # Log only the constraint errors without sensitive data
        constraint_errors = extract_constraint_errors(changeset)
        Logger.error("User creation failed with constraints", errors: inspect(constraint_errors))
        {:error, :auth, ErrorFormatter.format_changeset_errors(changeset)}
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
