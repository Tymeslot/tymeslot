defmodule TymeslotWeb.AuthLive do
  @moduledoc """
  One LiveView for every authentication flow: login, signup, password reset,
  email verification and OAuth completion.

  They share a process so moving between them patches the current view rather
  than loading a new page, which is what keeps "sign in" to "create an account"
  from flashing. The cost is that four independent flows would otherwise pile
  into one module, so each keeps its own handlers next door and this module is
  left with what genuinely spans them: the state machine, the login form, and
  the render that picks a component for the current state.

  - `TymeslotWeb.AuthLive.SignupEvents`
  - `TymeslotWeb.AuthLive.PasswordResetEvents`
  - `TymeslotWeb.AuthLive.VerificationEvents`
  - `TymeslotWeb.AuthLive.StateHelper` for the state machine itself

  Login is the exception that stays here: its form posts to `SessionController`
  rather than to this process, so all that is left of it is live validation.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Phoenix.Controller
  alias Tymeslot.Auth.{AuthActions, Session}
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.AuthLive.PageMetaHelper
  alias TymeslotWeb.AuthLive.PasswordResetEvents
  alias TymeslotWeb.AuthLive.SignupEvents
  alias TymeslotWeb.AuthLive.StateHelper
  alias TymeslotWeb.AuthLive.VerificationEvents
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Registration.CompleteRegistrationComponent
  alias TymeslotWeb.Registration.SignupComponent
  alias TymeslotWeb.Registration.VerifyEmailComponent
  alias TymeslotWeb.Session.LoginComponent
  alias TymeslotWeb.Session.PasswordResetComponent

  require Logger

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        loading: false,
        resend_cooldown: 0,
        errors: %{},
        current_year: DateTime.utc_now().year,
        current_state: :login,
        previous_state: nil,
        form_data: %{},
        csrf_token: Controller.get_csrf_token(),
        client_ip: ClientIP.get_from_mount(socket),
        user_agent: ClientIP.get_user_agent_from_mount(socket),
        unverified_user: Session.get_unverified_user_from_session(session),
        pending_oauth_registration: session["pending_oauth_registration"]
      )

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
  def handle_info(:resend_cooldown_tick, socket), do: VerificationEvents.tick(socket)

  @impl Phoenix.LiveView
  def handle_event("navigate_to", %{"state" => state}, socket) do
    Logger.info("AuthLive: navigate_to event received", state: state)

    case blocked_reason(state) do
      nil -> navigate(state, socket)
      message -> {:noreply, put_flash(socket, :info, message)}
    end
  end

  # Login's form posts directly to SessionController, so only validation runs
  # through this process.
  def handle_event("validate_login_email", %{"value" => email}, socket) do
    errors = login_errors(%{"email" => email, "password" => ""})

    {:noreply,
     socket
     |> assign(:errors, Map.take(errors, [:email]))
     |> assign(:form_data, Map.put(socket.assigns[:form_data] || %{}, :email, email))}
  end

  def handle_event("validate_login", %{"email" => email, "password" => password}, socket) do
    {:noreply, assign(socket, :errors, login_errors(%{"email" => email, "password" => password}))}
  end

  def handle_event("validate_signup", params, socket),
    do: SignupEvents.validate(params, socket)

  def handle_event("submit_signup", params, socket),
    do: SignupEvents.submit(params, socket)

  def handle_event("validate_reset_request", %{"email" => email}, socket),
    do: PasswordResetEvents.validate_request(email, socket)

  def handle_event("submit_reset_request", %{"email" => email} = params, socket),
    do: PasswordResetEvents.submit_request(email, params, socket)

  def handle_event("validate_password_reset", params, socket),
    do: PasswordResetEvents.validate_new_password(params, socket)

  def handle_event("submit_password_reset", params, socket),
    do: PasswordResetEvents.submit_new_password(params, socket)

  def handle_event("resend_verification", _params, socket) do
    if VerificationEvents.cooling_down?(socket) do
      {:noreply, socket}
    else
      VerificationEvents.resend(socket)
    end
  end

  # Catch-all event handler
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Both self-hosters and the managed offering can turn password auth or new
  # registrations off, and the sidebar links stay visible either way, so the
  # navigation itself has to refuse rather than land on a dead form.
  defp blocked_reason("signup") do
    cond do
      not Config.password_auth_enabled?() -> AuthActions.password_auth_disabled_message()
      not Config.registration_enabled?() -> AuthActions.registration_disabled_message()
      true -> nil
    end
  end

  defp blocked_reason("reset_password") do
    if Config.password_auth_enabled?(),
      do: nil,
      else: AuthActions.password_auth_disabled_message()
  end

  defp blocked_reason(_state), do: nil

  defp navigate(state, socket) do
    if StateHelper.valid_state?(state) do
      path = StateHelper.get_path_for_state(String.to_existing_atom(state))
      Logger.info("AuthLive: navigating", path: path)
      {:noreply, push_patch(socket, to: path)}
    else
      Logger.warning("AuthLive: invalid state", state: state)
      {:noreply, socket}
    end
  end

  defp login_errors(params) do
    errors =
      case InputProcessor.validate_field(params["email"], :email) do
        {:ok, _sanitized} -> %{}
        {:error, message} -> %{email: message}
      end

    if params["password"] in [nil, ""] do
      Map.put(errors, :password, dgettext("auth", "Password is required"))
    else
      errors
    end
  end

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
