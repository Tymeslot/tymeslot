defmodule TymeslotWeb.AuthLive do
  @moduledoc """
  Unified LiveView for all authentication flows.

  Handles login, signup, password reset, email verification, and OAuth completion
  with smooth transitions between states to eliminate page flashes.
  """

  use TymeslotWeb, :live_view
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3, redirect: 2]

  alias Phoenix.Controller
  alias Tymeslot.Auth.{AuthActions, Session, Verification}
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.{InputProcessor, RateLimiter}
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.AuthLive.{PageMetaHelper, SecurityHelper, StateHelper}
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Registration.CompleteRegistrationComponent
  alias TymeslotWeb.Registration.SignupComponent
  alias TymeslotWeb.Registration.VerifyEmailComponent
  alias TymeslotWeb.Session.LoginComponent
  alias TymeslotWeb.Session.PasswordResetComponent

  require Logger

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    csrf_token = Controller.get_csrf_token()
    client_ip = ClientIP.get_from_mount(socket)
    user_agent = ClientIP.get_user_agent_from_mount(socket)
    unverified_user = Session.get_unverified_user_from_session(session)

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:errors, %{})
      |> assign(:flash_messages, %{})
      |> assign(:current_year, DateTime.utc_now().year)
      |> assign(:current_state, :login)
      |> assign(:previous_state, nil)
      |> assign(:form_data, %{})
      |> assign(:csrf_token, csrf_token)
      |> assign(:client_ip, client_ip)
      |> assign(:user_agent, user_agent)
      |> assign(:unverified_user, unverified_user)
      |> assign(:pending_oauth_registration, session["pending_oauth_registration"])

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> StateHelper.determine_auth_state(params, uri)
      |> StateHelper.handle_auth_params(params)
      |> Session.populate_unverified_user_data()
      |> StateHelper.clear_errors()
      |> PageMetaHelper.assign_page_meta()

    Logger.info("AuthLive: handle_params completed", current_state: socket.assigns.current_state)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("navigate_to", %{"state" => state}, socket) do
    Logger.info("AuthLive: navigate_to event received", state: state)

    cond do
      state == "signup" and not Config.password_auth_enabled?() ->
        Logger.info("AuthLive: signup navigation blocked (password auth disabled)")
        {:noreply, put_flash(socket, :info, AuthActions.password_auth_disabled_message())}

      state == "signup" and not Config.registration_enabled?() ->
        Logger.info("AuthLive: signup navigation blocked (registration disabled)")
        {:noreply, put_flash(socket, :info, AuthActions.registration_disabled_message())}

      state == "reset_password" and not Config.password_auth_enabled?() ->
        Logger.info("AuthLive: reset_password navigation blocked (password auth disabled)")
        {:noreply, put_flash(socket, :info, AuthActions.password_auth_disabled_message())}

      StateHelper.valid_state?(state) ->
        path = StateHelper.get_path_for_state(String.to_existing_atom(state))
        Logger.info("AuthLive: navigating", path: path)
        {:noreply, push_patch(socket, to: path)}

      true ->
        Logger.warning("AuthLive: invalid state", state: state)
        {:noreply, socket}
    end
  end

  # Login Events
  def handle_event("validate_login", %{"email" => email, "password" => password}, socket) do
    params = %{"email" => email, "password" => password}

    case validate_login_params(params) do
      {:ok, _validated} ->
        updated_socket = assign(socket, :form_errors, %{})
        {:noreply, updated_socket}

      {:error, errors} ->
        updated_socket = assign(socket, :form_errors, errors)
        {:noreply, updated_socket}
    end
  end

  # Login form now submits directly to SessionController via standard HTML form submission
  # This handler is no longer needed since the form has action="/auth/session"
  # def handle_event("submit_login", params, socket) do
  #   # Form submission is handled by SessionController.create/2
  # end

  # Signup Events
  def handle_event("validate_signup", params, socket) do
    user_params = params["user"] || %{}
    metadata = SecurityHelper.extract_client_metadata(socket)

    case InputProcessor.validate_form(
           user_params,
           [{"email", :email}, {"password", :password}, {"full_name", :full_name}],
           metadata: metadata
         ) do
      {:ok, _sanitized_params} ->
        updated_socket = assign(socket, :form_errors, %{})
        {:noreply, updated_socket}

      {:error, errors} ->
        updated_socket = assign(socket, :form_errors, errors)
        {:noreply, updated_socket}
    end
  end

  def handle_event("submit_signup", %{"user" => user_params} = params, socket) do
    case SecurityHelper.validate_csrf_token(socket, params) do
      :ok ->
        if honeypot_tripped?(user_params) do
          handle_honeypot_signup(socket, user_params)
        else
          handle_legitimate_signup(socket, user_params)
        end

      {:error, :invalid_csrf} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general: "Security validation failed. Please refresh the page."
         })}
    end
  end

  # Password Reset Events
  def handle_event("validate_reset_request", %{"email" => email}, socket) do
    params = %{"email" => email}
    metadata = SecurityHelper.extract_client_metadata(socket)

    case InputProcessor.validate_form(params, [{"email", :email}], metadata: metadata) do
      {:ok, sanitized_params} ->
        socket =
          socket
          |> assign(:errors, %{})
          |> assign(:form_data, %{email: sanitized_params["email"]})

        {:noreply, socket}

      {:error, errors} ->
        # Only show email errors for password reset
        email_errors = Map.take(errors, [:email])

        socket =
          socket
          |> assign(:errors, email_errors)
          |> assign(:form_data, %{email: email})

        {:noreply, socket}
    end
  end

  def handle_event("submit_reset_request", %{"email" => email} = params, socket) do
    metadata = SecurityHelper.extract_client_metadata(socket)
    ip = normalize_ip_for_security(metadata.ip)

    with :ok <- SecurityHelper.validate_csrf_token(socket, params),
         :ok <- RateLimiter.check_password_reset_rate_limit(email, ip) do
      case AuthActions.request_password_reset(email, socket) do
        {:ok, new_state, message} ->
          socket =
            socket
            |> AuthActions.transition_state(new_state, :reset_password)
            |> assign(:reset_email, email)
            |> put_flash(:info, message)

          {:noreply, push_patch(socket, to: ~p"/auth/reset-password-sent")}

        {:error, error_message} ->
          {:noreply, SecurityHelper.set_errors(socket, %{general: error_message})}
      end
    else
      {:error, :invalid_csrf} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general: "Security validation failed. Please refresh the page."
         })}

      {:error, :rate_limited, message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: message})}
    end
  end

  def handle_event("validate_password_reset", params, socket) do
    validation_input = %{
      "password" => params["password"],
      "password_confirmation" => params["password_confirmation"]
    }

    metadata = SecurityHelper.extract_client_metadata(socket)

    with {:ok, sanitized_params} <-
           InputProcessor.validate_form(
             validation_input,
             [{"password", :password}, {"password_confirmation", :password}],
             metadata: metadata
           ),
         :ok <-
           PasswordValidator.validate_confirmation(
             sanitized_params["password"],
             sanitized_params["password_confirmation"]
           ) do
      socket =
        socket
        |> assign(:errors, %{})
        |> assign(:form_data, sanitized_params)

      {:noreply, socket}
    else
      {:error, errors} when is_map(errors) ->
        socket =
          socket
          |> assign(:errors, errors)
          |> assign(:form_data, validation_input)

        {:noreply, socket}

      {:error, confirmation_error} ->
        socket =
          socket
          |> assign(:errors, %{password_confirmation: confirmation_error})
          |> assign(:form_data, validation_input)

        {:noreply, socket}
    end
  end

  def handle_event("submit_password_reset", params, socket) do
    token = socket.assigns[:reset_token]

    with :ok <- SecurityHelper.validate_csrf_token(socket, params),
         true <- not is_nil(token) do
      case AuthActions.reset_password(
             token,
             params["password"],
             params["password_confirmation"],
             socket
           ) do
        {:ok, new_state, message} ->
          socket =
            socket
            |> AuthActions.transition_state(new_state, :reset_password_form)
            |> put_flash(:success, message)

          {:noreply, push_patch(socket, to: ~p"/auth/password-reset-success")}

        {:error, error_message} ->
          {:noreply, SecurityHelper.set_errors(socket, %{general: error_message})}
      end
    else
      {:error, :invalid_csrf} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general: "Security validation failed. Please refresh the page."
         })}

      false ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: "Invalid reset token"})}
    end
  end

  # Complete Registration Events
  def handle_event("validate_complete_registration", params, socket) do
    auth_params = params["auth"] || %{}
    profile_params = params["profile"] || %{}

    # Don't override OAuth errors with form validation errors
    if Map.get(socket.assigns, :has_oauth_error) do
      socket = assign(socket, :form_data, %{auth: auth_params, profile: profile_params})
      {:noreply, socket}
    else
      validation_map = %{
        "email" => auth_params["email"],
        "full_name" => profile_params["full_name"],
        "terms_accepted" => auth_params["terms_accepted"]
      }

      metadata = SecurityHelper.extract_client_metadata(socket)

      case InputProcessor.validate_form(
             validation_map,
             [{"email", :email}, {"password", :password}, {"full_name", :full_name}],
             metadata: metadata
           ) do
        {:ok, _sanitized_params} ->
          socket =
            socket
            |> assign(:errors, %{})
            |> assign(:form_data, %{auth: auth_params, profile: profile_params})

          {:noreply, socket}

        {:error, errors} ->
          socket =
            socket
            |> assign(:errors, errors)
            |> assign(:form_data, %{auth: auth_params, profile: profile_params})

          {:noreply, socket}
      end
    end
  end

  def handle_event("submit_complete_registration", params, socket) do
    client_ip = ClientIP.get(socket)

    with :ok <- SecurityHelper.validate_csrf_token(socket, params),
         :ok <- RateLimiter.check_oauth_registration_rate_limit(client_ip) do
      case AuthActions.complete_oauth_registration(params, socket) do
        {:ok, updated_socket, message} ->
          socket =
            updated_socket
            |> assign(:loading, false)
            |> put_flash(:info, message)
            |> redirect(to: get_success_redirect_path())

          {:noreply, socket}

        {:error, error_message} ->
          {:noreply, SecurityHelper.set_errors(socket, %{general: error_message})}
      end
    else
      {:error, :invalid_csrf} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general: "Security validation failed. Please refresh the page."
         })}

      {:error, :rate_limited, message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: message})}
    end
  end

  def handle_event("resend_verification", _params, socket) do
    if socket.assigns[:honeypot_signup] do
      metadata = SecurityHelper.extract_client_metadata(socket)
      ip = normalize_ip_for_security(metadata.ip)

      case RateLimiter.check_verification_rate_limit("honeypot", ip) do
        :ok ->
          log_honeypot_resend(metadata)

          socket =
            socket
            |> assign(:loading, false)
            |> put_flash(:info, "Verification email sent! Please check your inbox.")

          {:noreply, socket}

        {:error, :rate_limited, message} ->
          socket =
            socket
            |> assign(:loading, false)
            |> put_flash(:error, message)

          {:noreply, socket}
      end
    else
      email = Session.get_verification_email(socket)

      if email do
        case Verification.resend_verification_email_by_email(email, socket) do
          {:ok, _user} ->
            socket =
              socket
              |> assign(:loading, false)
              |> put_flash(:info, "Verification email sent! Please check your inbox.")

            {:noreply, socket}

          {:error, :rate_limited, message} ->
            socket =
              socket
              |> assign(:loading, false)
              |> put_flash(:error, message)

            {:noreply, socket}

          {:error, _reason} ->
            socket =
              socket
              |> assign(:loading, false)
              |> put_flash(:error, "Failed to send verification email. Please try again later.")

            {:noreply, socket}
        end
      else
        socket =
          socket
          |> assign(:loading, false)
          |> put_flash(
            :error,
            "Unable to resend verification email. Please try signing up again."
          )

        {:noreply, socket}
      end
    end
  end

  # Catch-all event handler
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp handle_honeypot_signup(socket, user_params) do
    log_honeypot(socket)

    message =
      "Account created successfully. Please check your email for verification instructions."

    socket =
      socket
      |> AuthActions.transition_state(:verify_email, :signup)
      |> put_flash(:info, message)
      |> assign(:form_data, %{email: user_params["email"]})
      |> assign(:honeypot_signup, true)

    {:noreply, push_patch(socket, to: ~p"/auth/verify-email")}
  end

  defp handle_legitimate_signup(socket, user_params) do
    email = user_params["email"]
    metadata = SecurityHelper.extract_client_metadata(socket)

    # HYBRID APPROACH: Check rate limiting first (fast gate) before reCAPTCHA verification (slow gate)
    # This prevents attackers from hammering Google API with invalid tokens from distributed IPs
    case RateLimiter.check_signup_rate_limit(email, metadata[:ip]) do
      {:error, :rate_limited, reason} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general: reason
         })}

      :ok ->
        handle_rate_limited_signup(socket, user_params, metadata)
    end
  end

  defp handle_rate_limited_signup(socket, user_params, metadata) do
    recaptcha_token = Map.get(user_params, "g-recaptcha-response", "")

    case RecaptchaHelpers.maybe_verify_signup_token(recaptcha_token, metadata) do
      :ok ->
        handle_recaptcha_verified_signup(socket, user_params)

      {:error, :recaptcha_failed} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general: "Security verification failed. Please try again."
         })}

      {:error, :recaptcha_script_blocked} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general:
             "Security verification unavailable. Please enable JavaScript and refresh the page, or contact support if the problem persists."
         })}
    end
  end

  defp handle_recaptcha_verified_signup(socket, user_params) do
    case AuthActions.register_user(user_params, socket) do
      {:ok, new_state, message} ->
        socket =
          socket
          |> AuthActions.transition_state(new_state, :signup)
          |> put_flash(:info, message)
          |> assign(:form_data, %{email: user_params["email"]})

        {:noreply, push_patch(socket, to: ~p"/auth/verify-email")}

      {:error, error_message} ->
        socket =
          socket
          |> assign(:loading, false)
          |> put_flash(:error, error_message)

        {:noreply, socket}
    end
  end

  defp honeypot_tripped?(params) do
    case Map.get(params, "website") do
      value when is_binary(value) -> value != ""
      _other -> false
    end
  end

  defp log_honeypot(socket) do
    SecurityLogger.log_security_event("signup_honeypot_triggered", %{
      ip_address: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket)
    })
  end

  defp log_honeypot_resend(metadata) do
    SecurityLogger.log_security_event("signup_honeypot_resend", %{
      ip_address: metadata.ip,
      user_agent: metadata.user_agent
    })
  end

  defp validate_login_params(params) do
    errors =
      case InputProcessor.validate_field(params["email"], :email) do
        {:ok, _sanitized} -> %{}
        {:error, msg} -> %{email: msg}
      end

    errors =
      if is_nil(params["password"]) or params["password"] == "" do
        Map.put(errors, :password, "Password is required")
      else
        errors
      end

    if map_size(errors) == 0, do: {:ok, params}, else: {:error, errors}
  end

  defp normalize_ip_for_security(ip) when ip in [nil, ""] do
    "unknown"
  end

  defp normalize_ip_for_security(ip), do: ip

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="auth-live" class="brand-container !bg-transparent" data-state={@current_state}>
      <%= case @current_state do %>
        <% :login -> %>
          {LoginComponent.auth_login(assigns)}
        <% :signup -> %>
          {SignupComponent.auth_signup(assigns)}
        <% :verify_email -> %>
          {VerifyEmailComponent.verify_email_page(assigns)}
        <% :reset_password -> %>
          {PasswordResetComponent.forgot_password_form(assigns)}
        <% :reset_password_form -> %>
          {PasswordResetComponent.new_password_form(assigns)}
        <% :reset_password_sent -> %>
          {PasswordResetComponent.forgot_password_confirm_page(assigns)}
        <% :complete_registration -> %>
          {CompleteRegistrationComponent.complete_registration_form(assigns)}
        <% :password_reset_success -> %>
          <TymeslotWeb.Shared.Auth.LayoutComponents.auth_card_layout
            title="Success!"
            flash={assigns.flash}
          >
            <:form>
              <div class="text-center mb-8">
                <div class="mx-auto w-20 h-20 flex items-center justify-center rounded-2xl bg-emerald-50 border-2 border-emerald-100 shadow-xl shadow-emerald-500/10 mb-6 transform hover:scale-105 transition-all duration-300">
                  <svg class="w-10 h-10 text-emerald-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                </div>
                <h2 class="text-xl font-bold text-slate-900 tracking-tight mb-3">Password Reset Successfully</h2>
                <p class="text-base text-slate-600 font-medium max-w-md mx-auto leading-relaxed">
                  Your password has been reset. You can now log in with your new credentials.
                </p>
              </div>
              <div class="mt-6">
                <TymeslotWeb.Shared.Auth.ButtonComponents.auth_button
                  phx-click="navigate_to"
                  phx-value-state="login"
                >
                  Log In
                </TymeslotWeb.Shared.Auth.ButtonComponents.auth_button>
              </div>
            </:form>
          </TymeslotWeb.Shared.Auth.LayoutComponents.auth_card_layout>
        <% :invalid_token -> %>
          <TymeslotWeb.Shared.Auth.LayoutComponents.auth_card_layout
            title="Invalid Link"
            flash={assigns.flash}
          >
            <:form>
              <div class="text-center mb-8">
                <div class="mx-auto w-20 h-20 flex items-center justify-center rounded-2xl bg-red-50 border-2 border-red-100 shadow-xl shadow-red-500/10 mb-6 transform hover:scale-105 transition-all duration-300">
                  <svg class="w-10 h-10 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                </div>
                <h2 class="text-xl font-bold text-slate-900 tracking-tight mb-3">Link Expired or Invalid</h2>
                <p class="text-base text-slate-600 font-medium max-w-md mx-auto leading-relaxed">
                  The security link you followed is no longer valid. Please request a new one to continue.
                </p>
              </div>
              <div class="space-y-4">
                <TymeslotWeb.Shared.Auth.ButtonComponents.auth_button
                  phx-click="navigate_to"
                  phx-value-state="reset_password"
                >
                  Request New Link
                </TymeslotWeb.Shared.Auth.ButtonComponents.auth_button>
                <button
                  type="button"
                  phx-click="navigate_to"
                  phx-value-state="login"
                  class="btn-secondary w-full py-3.5"
                >
                  Back to Login
                </button>
              </div>
            </:form>
          </TymeslotWeb.Shared.Auth.LayoutComponents.auth_card_layout>
        <% _other -> %>
          {LoginComponent.auth_login(assigns)}
      <% end %>
    </div>
    """
  end

  # Private Helper Functions

  defp get_success_redirect_path do
    Config.success_redirect_path()
  end
end
