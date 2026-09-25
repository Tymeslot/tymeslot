defmodule TymeslotWeb.AuthLive.PasswordResetEvents do
  @moduledoc """
  The password reset flow's event handlers, lifted out of `TymeslotWeb.AuthLive`.

  Two forms, two steps: request a reset link by email, then set a new password
  against the token that link carried. They are handled together because they
  share the failure vocabulary (a CSRF rejection, a rate limit, an expired
  token) and differ only in which of them can happen.

  Requesting a reset is rate limited per email *and* per IP: without the IP
  bound, an attacker enumerating addresses would get a fresh budget for each
  one, and the mailbox owner would carry the cost. That limit is charged once,
  inside `Tymeslot.Auth.PasswordReset`, which is also where a rejection is
  audited. Checking it here as well would spend the budget twice per request
  and reject at a layer that logs nothing.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Tymeslot.Auth
  alias TymeslotWeb.AuthLive.{SecurityHelper, StateHelper}
  alias TymeslotWeb.Helpers.ClientIP

  @typedoc "A LiveView `handle_event/3` return value."
  @type reply :: {:noreply, Phoenix.LiveView.Socket.t()}

  @doc """
  Validates the email on the "forgot password" form as it is typed.
  """
  @spec validate_request(String.t(), Phoenix.LiveView.Socket.t()) :: reply()
  def validate_request(email, socket) do
    metadata = socket |> ClientIP.request_opts() |> Map.new()

    case Auth.validate_email(email, metadata) do
      {:ok, sanitized} -> {:noreply, form_state(socket, %{}, %{email: sanitized})}
      {:error, message} -> {:noreply, form_state(socket, %{email: message}, %{email: email})}
    end
  end

  @doc """
  Requests a reset link for an email address.

  The confirmation is deliberately the same whether or not the address has an
  account, so this cannot be used to discover who is registered.
  """
  @spec submit_request(String.t(), map(), Phoenix.LiveView.Socket.t()) :: reply()
  def submit_request(email, params, socket) do
    with :ok <- SecurityHelper.validate_csrf_token(socket, params),
         {:ok, message} <- Auth.request_password_reset(email, ClientIP.request_opts(socket)) do
      socket =
        socket
        |> StateHelper.transition_state(:reset_password_sent, :reset_password)
        |> put_flash(:info, message)
        |> push_patch(to: ~p"/auth/reset-password-sent")

      {:noreply, socket}
    else
      {:error, :invalid_csrf} -> general_error(socket, SecurityHelper.csrf_message())
      {:error, _reason, message} -> general_error(socket, message)
    end
  end

  @doc """
  Sets the new password against the token the reset link carried.
  """
  @spec submit_new_password(map(), Phoenix.LiveView.Socket.t()) :: reply()
  def submit_new_password(params, socket) do
    case SecurityHelper.validate_csrf_token(socket, params) do
      :ok -> reset(socket.assigns[:reset_token], params, socket)
      {:error, :invalid_csrf} -> general_error(socket, SecurityHelper.csrf_message())
    end
  end

  defp reset(token, params, socket) when is_binary(token) do
    case Auth.reset_password(
           token,
           params["password"],
           params["password_confirmation"],
           ClientIP.request_opts(socket)
         ) do
      {:ok, _user, message} ->
        socket =
          socket
          |> StateHelper.transition_state(:password_reset_success, :reset_password_form)
          |> put_flash(:success, message)
          |> push_patch(to: ~p"/auth/password-reset-success")

        {:noreply, socket}

      {:error, _reason, message} ->
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
end
