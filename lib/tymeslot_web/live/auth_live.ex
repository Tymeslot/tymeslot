defmodule TymeslotWeb.AuthLive do
  @moduledoc """
  Unified LiveView for all authentication flows.

  Handles login, signup, password reset, email verification, and OAuth completion
  with smooth transitions between states to eliminate page flashes.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Phoenix.Controller
  alias Tymeslot.Auth.{AuthActions, Session, SignupSecurity, Verification}
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.{InputProcessor, RateLimiter}
  alias TymeslotWeb.AuthLive.{PageMetaHelper, SecurityHelper, StateHelper}
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Registration.CompleteRegistrationComponent
  alias TymeslotWeb.Registration.SignupComponent
  alias TymeslotWeb.Registration.VerifyEmailComponent
  alias TymeslotWeb.Session.LoginComponent
  alias TymeslotWeb.Session.PasswordResetComponent

  require Logger

  # How long the "resend verification email" button stays disabled after a click,
  # to stop users from hammering it. Server-side rate limiting remains the real
  # security boundary; this is purely a UX guard with a live countdown.
  @resend_cooldown_seconds 60

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    csrf_token = Controller.get_csrf_token()
    client_ip = ClientIP.get_from_mount(socket)
    user_agent = ClientIP.get_user_agent_from_mount(socket)
    unverified_user = Session.get_unverified_user_from_session(session)

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:resend_cooldown, 0)
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
  def handle_info(:resend_cooldown_tick, socket) do
    case socket.assigns.resend_cooldown - 1 do
      remaining when remaining > 0 ->
        Process.send_after(self(), :resend_cooldown_tick, 1000)
        {:noreply, assign(socket, :resend_cooldown, remaining)}

      _elapsed ->
        {:noreply, assign(socket, :resend_cooldown, 0)}
    end
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
  def handle_event("validate_login_email", %{"value" => email}, socket) do
    form_data = Map.put(socket.assigns[:form_data] || %{}, :email, email)
    params = %{"email" => email, "password" => ""}

    case validate_login_params(params) do
      {:ok, _validated} ->
        {:noreply, socket |> assign(:errors, %{}) |> assign(:form_data, form_data)}

      {:error, errors} ->
        {:noreply,
         socket |> assign(:errors, Map.take(errors, [:email])) |> assign(:form_data, form_data)}
    end
  end

  def handle_event("validate_login", %{"email" => email, "password" => password}, socket) do
    params = %{"email" => email, "password" => password}

    case validate_login_params(params) do
      {:ok, _validated} ->
        {:noreply, assign(socket, :errors, %{})}

      {:error, errors} ->
        {:noreply, assign(socket, :errors, errors)}
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
    form_data = Map.merge(socket.assigns[:form_data] || %{}, %{email: user_params["email"] || ""})

    case InputProcessor.validate_form(
           user_params,
           [{"email", :email}],
           metadata: metadata
         ) do
      {:ok, _sanitized_params} ->
        {:noreply, socket |> assign(:errors, %{}) |> assign(:form_data, form_data)}

      {:error, errors} ->
        email_errors = Map.take(errors, [:email])
        {:noreply, socket |> assign(:errors, email_errors) |> assign(:form_data, form_data)}
    end
  end

  def handle_event("submit_signup", %{"user" => user_params} = params, socket) do
    case SecurityHelper.validate_csrf_token(socket, params) do
      :ok ->
        metadata = SecurityHelper.extract_client_metadata(socket)

        case SignupSecurity.gate(user_params, metadata) do
          :ok ->
            handle_recaptcha_verified_signup(socket, user_params)

          :honeypot ->
            handle_honeypot_signup(socket, user_params)

          {:error, _kind, message} ->
            {:noreply, SecurityHelper.set_errors(socket, %{general: message})}
        end

      {:error, :invalid_csrf} ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{
           general: dgettext("auth", "Security validation failed. Please refresh the page.")
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
           general: dgettext("auth", "Security validation failed. Please refresh the page.")
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
           general: dgettext("auth", "Security validation failed. Please refresh the page.")
         })}

      false ->
        {:noreply,
         SecurityHelper.set_errors(socket, %{general: dgettext("auth", "Invalid reset token")})}
    end
  end

  def handle_event("resend_verification", _params, socket)
      when socket.assigns.resend_cooldown > 0 do
    # The button is disabled client-side during the cooldown, but a fast double-click
    # can deliver a second event before the DOM patch lands. Ignore it server-side so
    # we never spawn a duplicate timer chain (which would drain the countdown early)
    # or trigger a redundant resend.
    {:noreply, socket}
  end

  def handle_event("resend_verification", _params, socket) do
    # Start the cooldown on every click — success, rate-limited or error — so the
    # button can't be hammered while the (possibly deduplicated) email is in flight.
    socket = start_resend_cooldown(socket)

    if socket.assigns[:honeypot_signup] do
      metadata = SecurityHelper.extract_client_metadata(socket)
      ip = normalize_ip_for_security(metadata.ip)

      case RateLimiter.check_verification_rate_limit("honeypot", ip) do
        :ok ->
          SignupSecurity.log_honeypot_resend(metadata)

          socket =
            socket
            |> assign(:loading, false)
            |> put_flash(
              :info,
              dgettext("auth", "Verification email sent! Please check your inbox.")
            )

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
              |> put_flash(
                :info,
                dgettext("auth", "Verification email sent! Please check your inbox.")
              )

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
              |> put_flash(
                :error,
                dgettext("auth", "Failed to send verification email. Please try again later.")
              )

            {:noreply, socket}
        end
      else
        socket =
          socket
          |> assign(:loading, false)
          |> put_flash(
            :error,
            dgettext("auth", "Unable to resend verification email. Please try signing up again.")
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
    message =
      dgettext(
        "auth",
        "Account created successfully. Please check your email for verification instructions."
      )

    socket =
      socket
      |> AuthActions.transition_state(:verify_email, :signup)
      |> put_flash(:info, message)
      |> assign(:form_data, %{email: user_params["email"]})
      |> assign(:honeypot_signup, true)

    {:noreply, push_patch(socket, to: ~p"/auth/verify-email")}
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

      {:error, :field_errors, errors} ->
        {:noreply, SecurityHelper.set_errors(socket, errors)}

      {:error, error_message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: error_message})}
    end
  end

  defp validate_login_params(params) do
    errors =
      case InputProcessor.validate_field(params["email"], :email) do
        {:ok, _sanitized} -> %{}
        {:error, msg} -> %{email: msg}
      end

    errors =
      if is_nil(params["password"]) or params["password"] == "" do
        Map.put(errors, :password, dgettext("auth", "Password is required"))
      else
        errors
      end

    if map_size(errors) == 0, do: {:ok, params}, else: {:error, errors}
  end

  defp start_resend_cooldown(socket) do
    Process.send_after(self(), :resend_cooldown_tick, 1000)
    assign(socket, :resend_cooldown, @resend_cooldown_seconds)
  end

  defp normalize_ip_for_security(ip) when ip in [nil, ""] do
    "unknown"
  end

  defp normalize_ip_for_security(ip), do: ip

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div
      id="auth-live"
      class="brand-container bg-transparent!"
      data-state={@current_state}
      phx-hook="AuthAutoFocus"
    >
      <%= case @current_state do %>
        <% :login -> %>
          <LoginComponent.auth_login {assigns} />
        <% :signup -> %>
          <SignupComponent.auth_signup {assigns} />
        <% :verify_email -> %>
          <VerifyEmailComponent.verify_email_page {assigns} />
        <% :reset_password -> %>
          <PasswordResetComponent.forgot_password_form {assigns} />
        <% :reset_password_form -> %>
          <PasswordResetComponent.new_password_form {assigns} />
        <% :reset_password_sent -> %>
          <PasswordResetComponent.forgot_password_confirm_page {assigns} />
        <% :complete_registration -> %>
          <CompleteRegistrationComponent.complete_registration_form {assigns} />
        <% :password_reset_success -> %>
          <PasswordResetComponent.password_reset_success {assigns} />
        <% :invalid_token -> %>
          <PasswordResetComponent.invalid_token {assigns} />
        <% _other -> %>
          {LoginComponent.auth_login(assigns)}
      <% end %>
    </div>
    """
  end
end
