defmodule Tymeslot.Auth.Registration do
  @moduledoc """
  Handles user registration for Tymeslot.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger
  alias Tymeslot.Auth.{AdminBootstrap, ErrorFormatter, Helpers.AccountLogging, UserSchema}
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.{Config, PubSub}
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Security.{InputProcessor, Password, RateLimiter, SecurityLogger}
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
    - `{:ok, user, message}` when a new account was created. A verification
      email that could not be sent (rate limited, or a scheduling failure)
      does not change this: the account waits for a resend.
    - `{:existing_account, message}` when the address already had an
      account. `message` is the same one a new account gets, and nothing
      user-facing may tell the two apart: the owner is emailed instead (see
      `create_and_verify_user/3`). The distinct tag exists so machine callers
      cannot mistake it for a created account.
    - `{:error, reason, message}` on failure with appropriate flash message,
      which never depends on whether the address has an account
  """
  @spec register_user(signup_params(), Phoenix.LiveView.Socket.t() | Plug.Conn.t(), Keyword.t()) ::
          {:ok, UserSchema.t(), String.t()}
          | {:existing_account, String.t()}
          | {:error, atom(), String.t()}
          | {:error, :input, map()}
  def register_user(params, socket_or_conn, opts \\ []) do
    with {:ok, validated_params} <- validate_input(params),
         :ok <- check_rate_limit(validated_params["email"], socket_or_conn, opts) do
      case create_and_verify_user(validated_params, socket_or_conn, opts) do
        {:ok, :existing_account} -> {:existing_account, success_message()}
        {:ok, user} -> {:ok, user, success_message()}
        {:error, _reason, _message} = error -> error
      end
    end
  end

  # One message for every outcome that reaches the mailbox, new account or
  # taken address alike.
  defp success_message do
    dgettext(
      "auth",
      "Account created successfully. Please check your email for verification instructions."
    )
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

  # A taken address is answered exactly as a free one is: the same reply, and
  # the same dominant cost, one bcrypt hash (the new-user branch pays it in the
  # registration changeset). The explanation goes to the address's owner by
  # email, which only they can read. No account is created.
  defp create_and_verify_user(validated_params, socket_or_conn, opts) do
    case Config.user_queries_module().get_user_by_email(validated_params["email"]) do
      {:ok, existing} ->
        _discarded = Password.hash_password(validated_params["password"])
        duplicate_attempt(existing, socket_or_conn)

      {:error, :not_found} ->
        create_new_user(validated_params, socket_or_conn, opts)
    end
  end

  defp create_new_user(validated_params, socket_or_conn, opts) do
    case create_user(validated_params) do
      {:ok, user} ->
        AccountLogging.log_user_created(user)
        verify_and_notify_user(user, validated_params, socket_or_conn, opts)

      # Another sign-up for the address committed between the lookup and the
      # insert. The changeset has already paid the bcrypt cost, so this is the
      # duplicate branch in every respect but that.
      {:error, :email_taken} ->
        case Config.user_queries_module().get_user_by_email(validated_params["email"]) do
          {:ok, existing} -> duplicate_attempt(existing, socket_or_conn)
          # The winner is already gone again; there is no one to tell.
          {:error, :not_found} -> {:ok, :existing_account}
        end

      {:error, :auth, reason} ->
        AccountLogging.log_operation_failure(
          "registration",
          validated_params["email"],
          reason
        )

        {:error, :auth, ErrorFormatter.format_user_friendly_error("registration", reason)}
    end
  end

  # A new account's verification email spends the address's verification
  # allowance (`Verification.verify_user_email/3` charges it); the duplicate
  # spends the same, or the resend budget left afterwards would tell the two
  # apart. The answer is ignored for the same reason it is for a new account.
  defp duplicate_attempt(existing, socket_or_conn) do
    AccountLogging.log_operation_failure("registration", existing.email, :duplicate_email, %{
      user_id: existing.id
    })

    _spent = RateLimiter.check_verification_ip_rate_limit(ClientIP.get(socket_or_conn))
    notify_owner_of_attempt(existing)
    {:ok, :existing_account}
  end

  # Capped per recipient so the sign-up form cannot be used to flood an
  # owner's mailbox; over the cap the note is simply not sent.
  defp notify_owner_of_attempt(existing) do
    with :ok <- RateLimiter.check_signup_attempt_notice_rate_limit(existing.id),
         {:ok, _status} <- EmailScheduler.schedule_signup_attempt_notice(existing.id) do
      :ok
    else
      {:error, :rate_limited, _message} ->
        SecurityLogger.log_rate_limit_violation(existing.id, "signup_attempt_notice", %{})

      {:error, reason} ->
        Logger.error("Failed to schedule sign-up attempt notice",
          user_id: existing.id,
          reason: inspect(reason)
        )
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

  # The account is complete once this runs; the email only notifies the user.
  # A send that is refused or fails must not change the reply, because a taken
  # address never reaches this point and would answer differently. The user
  # can resend from the verify-email screen, or sign in to be sent a new link.
  defp send_verification_email(user, validated_params, socket_or_conn) do
    case verification_module().verify_user_email(socket_or_conn, user, validated_params) do
      {:ok, _updated_user} ->
        :ok

      {:error, :rate_limited, _message} ->
        Logger.warning("Verification email rate limited during signup", user_id: user.id)

      {:error, reason} ->
        Logger.error("Verification failed", user_id: user.id, reason: inspect(reason))
    end

    {:ok, user}
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

      {:error, %Ecto.Changeset{} = changeset} ->
        if email_taken?(changeset),
          do: {:error, :email_taken},
          else: creation_failed(changeset)
    end
  end

  defp email_taken?(changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {_message, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  defp creation_failed(changeset) do
    # Log only the constraint errors without sensitive data
    constraint_errors = extract_constraint_errors(changeset)
    Logger.error("User creation failed with constraints", errors: inspect(constraint_errors))
    {:error, :auth, ErrorFormatter.format_changeset_errors(changeset)}
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
