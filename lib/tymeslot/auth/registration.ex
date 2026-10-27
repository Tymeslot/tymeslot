defmodule Tymeslot.Auth.Registration do
  @moduledoc """
  Handles user registration for Tymeslot.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Auth.{
    AdminBootstrap,
    ErrorFormatter,
    Helpers.AccountLogging,
    RateLimit,
    RegistrationAnnouncement,
    SignupSecurity,
    UserSchema,
    Validation,
    Verification
  }

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Security.{InputProcessor, Password, RateLimiter}

  @type signup_params :: Tymeslot.Auth.Validation.signup_params()

  @doc """
  Registers a new user with the provided parameters.

  Every sign-up passes `Tymeslot.Auth.SignupSecurity.gate/2` first, so the
  per-IP signup rate limit is charged exactly once per attempt, before any bot
  check that costs an external call. The per-address limit is charged once
  the input is valid.

  ## Options
    - `:ip` (required), `:user_agent` - the requesting client, for the rate
      limit, the audit trail and the registration broadcast
    - `:via` - `:signup_form` (the default) or `:provisioning`, for trusted
      server-side callers with no browser. Provisioning skips the honeypot
      and reCAPTCHA, which only a browser form can satisfy, and its
      broadcast carries no terms acceptance or client, so the caller alone
      decides whether legal terms were accepted. The rate limit applies
      either way.

  ## Returns
    - `{:ok, user, message}` when a new account was created. A verification
      email that could not be sent (rate limited, or a scheduling failure)
      does not change this: the account waits for a resend.
    - `{:existing_account, message}` when no account was created because the
      address already had one, or because it has used up its own sign-up
      allowance. `message` is the same one a new account gets, and nothing
      user-facing may tell these apart: the owner of a taken address is
      emailed instead (see `create_and_verify_user/2`), and an address over
      its allowance is sent nothing. The distinct tag exists so machine
      callers cannot mistake it for a created account. A `:provisioning`
      caller is refused with `{:error, :rate_limited, message}` over the
      address's allowance instead.
    - `{:honeypot, message}` when the honeypot caught a bot. Nothing is
      created, but the reply and the verification allowance spent match a
      real sign-up's, so the bot learns nothing.
    - `{:error, reason, message}` on failure with appropriate flash message,
      which never depends on whether the address has an account
  """
  @spec register_user(signup_params(), keyword()) ::
          {:ok, UserSchema.t(), String.t()}
          | {:existing_account, String.t()}
          | {:honeypot, String.t()}
          | {:error, atom(), String.t()}
          | {:error, :input, map() | String.t()}
  def register_user(params, opts) do
    gate_opts = [bot_checks: via(opts) == :signup_form] ++ opts

    case SignupSecurity.gate(params, gate_opts) do
      :ok -> validate_and_register(params, opts)
      :honeypot -> answer_honeypot(opts[:ip])
      {:error, _kind, _message} = refused -> refused
    end
  end

  # The address's own allowance is charged only once the input is valid, so a
  # malformed form is still told what is wrong with it rather than answered
  # as a sign-up.
  defp validate_and_register(params, opts) do
    with {:ok, validated_params} <- validate_input(params) do
      case recipient_allowance(validated_params["email"], opts) do
        :ok ->
          register_validated(params, validated_params, opts)

        {:error, :rate_limited, _message} = refused ->
          answer_over_allowance(refused, validated_params, opts)
      end
    end
  end

  # Caps the sign-ups one address can see. Anyone can spend it by typing the
  # address, so a refusal is audited here and answered by the caller.
  defp recipient_allowance(email, opts) do
    RateLimit.check(RateLimiter.check(:signup_email, email),
      event: "signup",
      identifier: email,
      ip: opts[:ip],
      user_agent: opts[:user_agent]
    )
  end

  # On the sign-up form, an address over its allowance is answered exactly as
  # a taken one is, at the same bcrypt cost and verification allowance, but
  # nothing is sent: refusing out loud would let one client keep the
  # address's owner from signing up for a day. A provisioning caller has no
  # visitor to keep it from, so it is told.
  defp answer_over_allowance(refused, validated_params, opts) do
    case via(opts) do
      :signup_form ->
        _discarded = Password.hash_password(validated_params["password"])
        _allowance = spend_verification_allowance(opts[:ip])
        {:existing_account, success_message()}

      :provisioning ->
        refused
    end
  end

  defp register_validated(params, validated_params, opts) do
    terms_accepted = Validation.terms_accepted?(params["terms_accepted"])
    validated_params = Map.put(validated_params, "terms_accepted", terms_accepted)

    opts = Keyword.put(opts, :metadata, broadcast_metadata(opts, terms_accepted))

    case create_and_verify_user(validated_params, opts) do
      {:ok, :existing_account} -> {:existing_account, success_message()}
      {:ok, user} -> {:ok, user, success_message()}
      {:error, _reason, _message} = error -> error
    end
  end

  defp via(opts), do: Keyword.get(opts, :via, :signup_form)

  # The registration hook records legal acceptance from this metadata, so only
  # a sign-up form's carries it; a provisioning task must be able to leave it
  # pending.
  defp broadcast_metadata(opts, terms_accepted) do
    case via(opts) do
      :signup_form ->
        %{
          ip: opts[:ip],
          user_agent: opts[:user_agent],
          source: "signup",
          terms_accepted: terms_accepted
        }

      :provisioning ->
        %{source: "provisioning"}
    end
  end

  # Spends the address's verification allowance as a real sign-up's email
  # does, so the resend budget left afterwards matches too.
  defp answer_honeypot(ip) do
    _allowance = spend_verification_allowance(ip)
    {:honeypot, success_message()}
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
      if Validation.terms_accepted?(params["terms_accepted"]) do
        {:ok, validated_params}
      else
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

  # A taken address is answered exactly as a free one is: the same reply, and
  # the same dominant cost, one bcrypt hash (the new-user branch pays it in the
  # registration changeset). The explanation goes to the address's owner by
  # email, which only they can read. No account is created.
  defp create_and_verify_user(validated_params, opts) do
    case Config.user_queries_module().get_user_by_email(validated_params["email"]) do
      {:ok, existing} ->
        _discarded = Password.hash_password(validated_params["password"])
        duplicate_attempt(existing, opts[:ip])

      {:error, :not_found} ->
        create_new_user(validated_params, opts)
    end
  end

  defp create_new_user(validated_params, opts) do
    case create_user(validated_params, Keyword.fetch!(opts, :metadata)) do
      {:ok, user} ->
        AccountLogging.log_user_created(user)
        verify_and_notify_user(user, opts)

      # Another sign-up for the address committed between the lookup and the
      # insert. The changeset has already paid the bcrypt cost, so this is the
      # duplicate branch in every respect but that.
      {:error, :email_taken} ->
        case Config.user_queries_module().get_user_by_email(validated_params["email"]) do
          {:ok, existing} -> duplicate_attempt(existing, opts[:ip])
          # The winner is already gone again; there is no one to tell.
          {:error, :not_found} -> {:ok, :existing_account}
        end

      {:error, :registration_hook, _message} = error ->
        error

      {:error, :auth, %Ecto.Changeset{} = changeset} ->
        AccountLogging.log_operation_failure(
          "registration",
          validated_params["email"],
          changeset.errors |> Keyword.keys() |> Enum.uniq() |> Enum.join(",")
        )

        {:error, :auth, ErrorFormatter.format_user_friendly_error("registration", changeset)}
    end
  end

  defp duplicate_attempt(existing, ip) do
    _outcome = answer_taken_address(existing, ip)
    {:ok, :existing_account}
  end

  @doc """
  Handles a sign-up for an address that already has an account, on any
  sign-up form, so the visitor's reply can match a new account's.

  Spends the requesting address's verification allowance, as a new account's
  verification email would, and within it sends the owner the sign-up attempt
  notice (capped per recipient). The result says whether that allowance let
  the "email" through, `:sent` or `:rate_limited`, so a caller that reports
  delivery can report it the same way it would for a new account.
  """
  @spec answer_taken_address(UserSchema.t(), String.t() | nil) :: :sent | :rate_limited
  def answer_taken_address(%UserSchema{} = existing, ip) do
    AccountLogging.log_operation_failure("registration", existing.email, :duplicate_email, %{
      user_id: existing.id
    })

    # The source's allowance first: a source over its own limit must spend
    # nothing of the owner's notice budget, or it could exhaust that budget
    # and silence the notice for the genuine attempts that follow.
    case spend_verification_allowance(ip) do
      :ok ->
        notify_owner_of_attempt(existing)
        :sent

      {:error, :rate_limited, _message} ->
        :rate_limited
    end
  end

  # The source's verification allowance, spent as a new account's email
  # would spend it; a refusal is audited once, like every auth limit.
  defp spend_verification_allowance(ip) do
    RateLimit.check(RateLimiter.check(:verification_ip, ip),
      event: "email_verification",
      identifier: nil,
      ip: ip
    )
  end

  # Capped per recipient so the sign-up form cannot be used to flood an
  # owner's mailbox; over the cap the note is simply not sent.
  defp notify_owner_of_attempt(existing) do
    with :ok <-
           RateLimit.check(
             RateLimiter.check(:signup_attempt_notice, existing.id),
             event: "signup_attempt_notice",
             identifier: existing.id
           ),
         {:ok, _status} <- EmailScheduler.schedule_signup_attempt_notice(existing.id) do
      :ok
    else
      {:error, :rate_limited, _message} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule sign-up attempt notice",
          user_id: existing.id,
          reason: LogFormat.reason(reason)
        )
    end
  end

  # The profile and the registration broadcast complete the account; the
  # verification email only notifies the user about it. They are ordered that
  # way deliberately: a send that fails or is rate limited must not leave a
  # committed user row with no profile and no broadcast, because the address is
  # then rejected as a duplicate on retry and the account can never be reached.
  defp verify_and_notify_user(user, opts) do
    case create_profile_and_announce(user) do
      :ok -> send_verification_email(user, opts[:ip])
      {:error, _reason, _message} = error -> error
    end
  end

  defp create_profile_and_announce(user) do
    case Profiles.create_profile(user.id) do
      {:ok, _profile} ->
        Logger.info("Created profile", user_id: user.id)

        # Notify apps about the completed registration
        RegistrationAnnouncement.announce(user)
        :ok

      {:error, reason} ->
        Logger.error("Profile creation failed",
          user_id: user.id,
          reason: LogFormat.reason(reason)
        )

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
  defp send_verification_email(user, ip) do
    case Verification.send_verification_email(user, ip) do
      {:ok, _updated_user} ->
        :ok

      {:error, :rate_limited, _message} ->
        Logger.warning("Verification email rate limited during signup", user_id: user.id)

      {:error, reason} ->
        Logger.error("Verification failed", user_id: user.id, reason: LogFormat.reason(reason))
    end

    {:ok, user}
  end

  # The registration hook's job is enqueued in the same transaction, so the
  # account never commits without it (and the terms acceptance it records).
  defp create_user(params, metadata) do
    user_params = %{
      email: params["email"],
      password: params["password"],
      # Using same password since no confirmation field in form
      password_confirmation: params["password"],
      terms_accepted: params["terms_accepted"]
    }

    transaction_result =
      Repo.transaction(fn ->
        with {:ok, user} <- Config.user_queries_module().create_user(user_params),
             {:ok, bootstrapped_user} <- AdminBootstrap.maybe_promote_first_user(user),
             :ok <- RegistrationAnnouncement.enqueue_hook(bootstrapped_user.id, metadata) do
          bootstrapped_user
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case transaction_result do
      {:ok, user} ->
        {:ok, user}

      {:error, {:registration_hook, reason}} ->
        Logger.error("Could not enqueue the registration hook; account not created",
          reason: LogFormat.reason(reason)
        )

        {:error, :registration_hook,
         dgettext("auth", "Failed to create user account. Please try again.")}

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

    Logger.error("User creation failed with constraints",
      errors: LogFormat.reason(constraint_errors)
    )

    {:error, :auth, changeset}
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
