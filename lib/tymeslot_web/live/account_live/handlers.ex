defmodule TymeslotWeb.AccountLive.Handlers do
  @moduledoc """
  Event handlers for account management operations.
  Handles form validation, email updates, and password changes.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Auth
  alias Tymeslot.Security.{AccountInputProcessor, RateLimiter}
  alias TymeslotWeb.AccountLive.{ErrorFormatter, Helpers}
  alias TymeslotWeb.Live.Shared.Flash

  # Provider constants
  @social_provider_default "social"

  @doc """
  Main event handler dispatcher.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_email_form", _params, socket) do
    if socket.assigns.is_social_user do
      {:noreply, socket}
    else
      {:noreply, Helpers.toggle_form(socket, :email)}
    end
  end

  def handle_event("toggle_password_form", _params, socket) do
    if socket.assigns.is_social_user do
      {:noreply, socket}
    else
      {:noreply, Helpers.toggle_form(socket, :password)}
    end
  end

  # Keep validate events no-op to avoid early validation triggering UX issues
  def handle_event("validate_email_field", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("validate_password_field", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("update_email", %{"email_form" => params}, socket) do
    if socket.assigns.is_social_user do
      Flash.error(social_user_message(socket, :email))
      {:noreply, socket}
    else
      update_email(socket, params)
    end
  end

  def handle_event("update_password", %{"password_form" => params}, socket) do
    if socket.assigns.is_social_user do
      Flash.error(social_user_message(socket, :password))
      {:noreply, socket}
    else
      update_password(socket, params)
    end
  end

  def handle_event("cancel_email_change", _params, socket) do
    user = socket.assigns.current_user

    case Auth.cancel_email_change(user) do
      {:ok, updated_user, message} ->
        send(self(), {:user_updated, updated_user})
        Flash.info(message)
        {:noreply, assign(socket, :current_user, updated_user)}

      {:error, reason} ->
        Flash.error(reason)
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  # Private functions

  defp update_email(socket, params) do
    socket = assign(socket, :saving_email, true)
    metadata = build_metadata(socket)
    user = socket.assigns.current_user

    with {:ok, sanitized_params} <-
           AccountInputProcessor.validate_email_change(params, metadata: metadata),
         :ok <- RateLimiter.check_auth_rate_limit(user.email, metadata[:ip]),
         {:ok, updated_user, message} <-
           Auth.request_email_change(
             user,
             sanitized_params["new_email"],
             sanitized_params["current_password"]
           ) do
      send(self(), {:user_updated, updated_user})

      Flash.info(message)

      {:noreply, Helpers.reset_form_state(socket, :email, updated_user)}
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, assign(socket, :saving_email, false)}

      {:error, error} when is_binary(error) ->
        Flash.error(error)
        {:noreply, assign(socket, :saving_email, false)}

      {:error, errors} ->
        handle_update_error(socket, errors, :email)
    end
  end

  defp update_password(socket, params) do
    socket = assign(socket, :saving_password, true)
    metadata = build_metadata(socket)
    user = socket.assigns.current_user

    with {:ok, sanitized_params} <-
           AccountInputProcessor.validate_password_change(params, metadata: metadata),
         :ok <- RateLimiter.check_auth_rate_limit(user.email, metadata[:ip]),
         {:ok, updated_user} <-
           Auth.update_user_password(
             user,
             sanitized_params["current_password"],
             sanitized_params["new_password"],
             sanitized_params["new_password_confirmation"]
           ) do
      send(self(), {:user_updated, updated_user})
      Flash.info("Password updated successfully.")

      {:noreply, Helpers.reset_form_state(socket, :password, updated_user)}
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, assign(socket, :saving_password, false)}

      {:error, errors} ->
        handle_update_error(socket, errors, :password)
    end
  end

  defp handle_update_error(socket, errors, form_type) do
    formatted_errors = ErrorFormatter.format(errors)

    error_key =
      case form_type do
        :email -> :email_form_errors
        :password -> :password_form_errors
      end

    saving_key =
      case form_type do
        :email -> :saving_email
        :password -> :saving_password
      end

    {:noreply,
     socket
     |> assign(error_key, formatted_errors)
     |> assign(saving_key, false)}
  end

  defp build_metadata(socket) do
    %{
      ip: socket.assigns[:client_ip] || "unknown",
      user_agent: socket.assigns[:user_agent] || "unknown",
      user_id: socket.assigns.current_user.id
    }
  end

  defp social_user_message(socket, :email) do
    provider = String.capitalize(socket.assigns.current_user.provider || @social_provider_default)
    "Email changes are managed through your #{provider} account"
  end

  defp social_user_message(socket, :password) do
    provider = String.capitalize(socket.assigns.current_user.provider || @social_provider_default)
    "Password authentication is not available for #{provider} login"
  end
end
