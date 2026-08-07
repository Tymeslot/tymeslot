defmodule TymeslotWeb.AuthLive.SignupEvents do
  @moduledoc """
  The signup flow's event handlers, lifted out of `TymeslotWeb.AuthLive`.

  ## Why a honeypot submission looks like a success

  A submission caught by the honeypot is answered with the same message, the
  same state transition and the same redirect as a real one. That is the point:
  telling a bot it was detected teaches whoever wrote it which field to leave
  alone next time. The only difference is that no account exists, so the
  verify-email screen is flagged (`honeypot_signup`) and the resend handler
  answers it without touching the database.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Tymeslot.Auth.{AuthActions, SignupSecurity}
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.AuthLive.SecurityHelper

  @typedoc "A LiveView `handle_event/3` return value."
  @type reply :: {:noreply, Phoenix.LiveView.Socket.t()}

  @doc """
  Validates the signup email as it is typed.

  Only email errors surface here; the password rules are the submit step's
  business, so a half-typed password is not flagged mid-keystroke.
  """
  @spec validate(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def validate(params, socket) do
    user_params = params["user"] || %{}
    metadata = SecurityHelper.extract_client_metadata(socket)
    form_data = Map.merge(socket.assigns[:form_data] || %{}, %{email: user_params["email"] || ""})

    errors =
      case InputProcessor.validate_form(user_params, [{"email", :email}], metadata: metadata) do
        {:ok, _sanitized} -> %{}
        {:error, errors} -> Map.take(errors, [:email])
      end

    {:noreply, socket |> assign(:errors, errors) |> assign(:form_data, form_data)}
  end

  @doc """
  Submits the signup form, once CSRF and the anti-abuse gate both pass.
  """
  @spec submit(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def submit(%{"user" => user_params} = params, socket) do
    with :ok <- SecurityHelper.validate_csrf_token(socket, params),
         metadata = SecurityHelper.extract_client_metadata(socket),
         :ok <- SignupSecurity.gate(user_params, metadata) do
      register(socket, user_params)
    else
      :honeypot ->
        pretend_registered(socket, user_params)

      {:error, :invalid_csrf} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: csrf_message()})}

      {:error, _kind, message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: message})}
    end
  end

  defp register(socket, user_params) do
    case AuthActions.register_user(user_params, socket) do
      {:ok, new_state, message} ->
        {:noreply, to_verify_email(socket, new_state, message, user_params)}

      {:error, :field_errors, errors} ->
        {:noreply, SecurityHelper.set_errors(socket, errors)}

      {:error, error_message} ->
        {:noreply, SecurityHelper.set_errors(socket, %{general: error_message})}
    end
  end

  defp pretend_registered(socket, user_params) do
    message =
      dgettext(
        "auth",
        "Account created successfully. Please check your email for verification instructions."
      )

    socket =
      socket
      |> to_verify_email(:verify_email, message, user_params)
      |> assign(:honeypot_signup, true)

    {:noreply, socket}
  end

  defp to_verify_email(socket, new_state, message, user_params) do
    socket
    |> AuthActions.transition_state(new_state, :signup)
    |> put_flash(:info, message)
    |> assign(:form_data, %{email: user_params["email"]})
    |> push_patch(to: ~p"/auth/verify-email")
  end

  defp csrf_message,
    do: dgettext("auth", "Security validation failed. Please refresh the page.")
end
