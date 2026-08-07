defmodule TymeslotWeb.AuthLive.PasswordResetEvents do
  @moduledoc """
  The password reset flow's event handlers, lifted out of `TymeslotWeb.AuthLive`.

  Two forms, two steps: request a reset link by email, then set a new password
  against the token that link carried. They are handled together because they
  share the failure vocabulary (a CSRF rejection, a rate limit, an expired
  token) and differ only in which of them can happen.

  Requesting a reset is rate limited per email *and* per IP: without the IP
  bound, an attacker enumerating addresses would get a fresh budget for each
  one, and the mailbox owner would carry the cost.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Tymeslot.Auth.AuthActions
  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.{InputProcessor, RateLimiter}
  alias TymeslotWeb.AuthLive.SecurityHelper

  @typedoc "A LiveView `handle_event/3` return value."
  @type reply :: {:noreply, Phoenix.LiveView.Socket.t()}

  @doc """
  Validates the email on the "forgot password" form as it is typed.
  """
  @spec validate_request(String.t(), Phoenix.LiveView.Socket.t()) :: reply()
  def validate_request(email, socket) do
    metadata = SecurityHelper.extract_client_metadata(socket)

    case InputProcessor.validate_form(%{"email" => email}, [{"email", :email}],
           metadata: metadata
         ) do
      {:ok, sanitized} ->
        {:noreply, form_state(socket, %{}, %{email: sanitized["email"]})}

      {:error, errors} ->
        {:noreply, form_state(socket, Map.take(errors, [:email]), %{email: email})}
    end
  end

  @doc """
  Requests a reset link for an email address.

  The confirmation is deliberately the same whether or not the address has an
  account, so this cannot be used to discover who is registered.
  """
  @spec submit_request(String.t(), map(), Phoenix.LiveView.Socket.t()) :: reply()
  def submit_request(email, params, socket) do
    metadata = SecurityHelper.extract_client_metadata(socket)

    with :ok <- SecurityHelper.validate_csrf_token(socket, params),
         :ok <-
           RateLimiter.check_password_reset_rate_limit(
             email,
             SecurityHelper.rate_limit_ip(metadata)
           ),
         {:ok, new_state, message} <- AuthActions.request_password_reset(email, socket) do
      socket =
        socket
        |> AuthActions.transition_state(new_state, :reset_password)
        |> put_flash(:info, message)
        |> push_patch(to: ~p"/auth/reset-password-sent")

      {:noreply, socket}
    else
      {:error, :invalid_csrf} -> general_error(socket, csrf_message())
      {:error, :rate_limited, message} -> general_error(socket, message)
      {:error, message} -> general_error(socket, message)
    end
  end

  @doc """
  Validates the new password and its confirmation as they are typed.
  """
  @spec validate_new_password(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def validate_new_password(params, socket) do
    entered = %{
      "password" => params["password"],
      "password_confirmation" => params["password_confirmation"]
    }

    metadata = SecurityHelper.extract_client_metadata(socket)

    with {:ok, sanitized} <-
           InputProcessor.validate_form(
             entered,
             [{"password", :password}, {"password_confirmation", :password}],
             metadata: metadata
           ),
         :ok <-
           PasswordValidator.validate_confirmation(
             sanitized["password"],
             sanitized["password_confirmation"]
           ) do
      {:noreply, form_state(socket, %{}, sanitized)}
    else
      {:error, errors} when is_map(errors) ->
        {:noreply, form_state(socket, errors, entered)}

      {:error, confirmation_error} ->
        {:noreply, form_state(socket, %{password_confirmation: confirmation_error}, entered)}
    end
  end

  @doc """
  Sets the new password against the token the reset link carried.
  """
  @spec submit_new_password(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def submit_new_password(params, socket) do
    case SecurityHelper.validate_csrf_token(socket, params) do
      :ok -> reset(socket.assigns[:reset_token], params, socket)
      {:error, :invalid_csrf} -> general_error(socket, csrf_message())
    end
  end

  defp reset(token, params, socket) when is_binary(token) do
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
          |> push_patch(to: ~p"/auth/password-reset-success")

        {:noreply, socket}

      {:error, message} ->
        general_error(socket, message)
    end
  end

  # No token on the socket: the form was reached without following a link, or
  # the link's token was rejected while determining the auth state.
  defp reset(_missing, _params, socket),
    do: general_error(socket, dgettext("auth", "Invalid reset token"))

  defp form_state(socket, errors, form_data) do
    socket |> assign(:errors, errors) |> assign(:form_data, form_data)
  end

  defp general_error(socket, message) do
    {:noreply, SecurityHelper.set_errors(socket, %{general: message})}
  end

  defp csrf_message,
    do: dgettext("auth", "Security validation failed. Please refresh the page.")
end
