defmodule TymeslotWeb.AccountLive.Handlers do
  @moduledoc """
  Event handlers for account management operations.
  Handles form validation, email updates, and password changes.
  """

  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView
  alias Tymeslot.Auth
  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.{InputProcessor, RateLimiter}
  alias TymeslotWeb.AccountLive.{ErrorFormatter, Helpers}
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Themes.Shared.LocaleHandler

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
      {:noreply, LiveView.put_flash(socket, :error, social_user_message(socket, :email))}
    else
      update_email(socket, params)
    end
  end

  def handle_event("update_password", %{"password_form" => params}, socket) do
    if socket.assigns.is_social_user do
      {:noreply, LiveView.put_flash(socket, :error, social_user_message(socket, :password))}
    else
      update_password(socket, params)
    end
  end

  def handle_event("change_language", %{"language_form" => %{"locale" => locale}}, socket) do
    case Auth.update_user_locale(socket.assigns.current_user, locale) do
      {:ok, updated_user} ->
        new_locale = updated_user.locale || LocaleHandler.default_locale()
        Gettext.put_locale(TymeslotWeb.Gettext, new_locale)

        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:locale, new_locale)
         |> LiveView.put_flash(:info, dgettext("account", "Language preference saved."))}

      {:error, _changeset} ->
        {:noreply,
         LiveView.put_flash(
           socket,
           :error,
           dgettext("account", "Could not save language preference.")
         )}
    end
  end

  def handle_event("cancel_email_change", _params, socket) do
    user = socket.assigns.current_user

    case Auth.cancel_email_change(user) do
      {:ok, updated_user, message} ->
        {:noreply,
         socket
         |> LiveView.put_flash(:info, message)
         |> assign(:current_user, updated_user)}

      {:error, reason} ->
        {:noreply, LiveView.put_flash(socket, :error, reason)}
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
           InputProcessor.validate_form(
             params,
             [{"new_email", :email}, {"current_password", :password}],
             metadata: metadata,
             universal_opts: [allow_html: false]
           ),
         :ok <- RateLimiter.check_auth_rate_limit(user.email, metadata[:ip]),
         {:ok, updated_user, message} <-
           Auth.request_email_change(
             user,
             sanitized_params["new_email"],
             sanitized_params["current_password"]
           ) do
      {:noreply,
       socket
       |> LiveView.put_flash(:info, message)
       |> Helpers.reset_form_state(:email, updated_user)}
    else
      {:error, :rate_limited, message} ->
        {:noreply, socket |> LiveView.put_flash(:error, message) |> assign(:saving_email, false)}

      {:error, errors} ->
        handle_update_error(socket, errors, :email)
    end
  end

  defp update_password(socket, params) do
    socket = assign(socket, :saving_password, true)
    metadata = build_metadata(socket)
    user = socket.assigns.current_user

    with {:ok, sanitized_params} <-
           validate_password_change_input(params, metadata),
         :ok <- RateLimiter.check_auth_rate_limit(user.email, metadata[:ip]),
         {:ok, _updated_user} <-
           Auth.update_user_password(
             user,
             sanitized_params["current_password"],
             sanitized_params["new_password"],
             sanitized_params["new_password_confirmation"]
           ) do
      {:noreply,
       socket
       |> LiveView.put_flash(
         :info,
         dgettext(
           "account",
           "Your password has been changed. Please sign in again with your new password."
         )
       )
       |> LiveView.redirect(to: ~p"/auth/login")}
    else
      {:error, :rate_limited, message} ->
        {:noreply,
         socket |> LiveView.put_flash(:error, message) |> assign(:saving_password, false)}

      {:error, errors} ->
        handle_update_error(socket, errors, :password)
    end
  end

  defp handle_update_error(socket, errors, form_type) do
    formatted_errors = ErrorFormatter.format(errors)

    {error_key, saving_key} =
      case form_type do
        :email -> {:email_form_errors, :saving_email}
        :password -> {:password_form_errors, :saving_password}
      end

    {:noreply,
     socket
     |> assign(error_key, formatted_errors)
     |> assign(saving_key, false)}
  end

  defp build_metadata(socket) do
    %{
      ip: ClientIP.get(socket),
      user_agent: socket.assigns[:user_agent] || "unknown",
      user_id: socket.assigns.current_user.id
    }
  end

  defp social_user_message(socket, field) do
    provider = String.capitalize(socket.assigns.current_user.provider || @social_provider_default)

    case field do
      :email ->
        dgettext("account", "Email changes are managed through your %{provider} account",
          provider: provider
        )

      :password ->
        dgettext("account", "Password authentication is not available for %{provider} login",
          provider: provider
        )
    end
  end

  defp validate_password_change_input(params, metadata) do
    with {:ok, sanitized_params} <-
           InputProcessor.validate_form(
             params,
             [
               {"current_password", :password},
               {"new_password", :password},
               {"new_password_confirmation", :password}
             ],
             metadata: metadata,
             universal_opts: [allow_html: false]
           ),
         :ok <-
           PasswordValidator.validate_confirmation(
             sanitized_params["new_password"],
             sanitized_params["new_password_confirmation"]
           ),
         :ok <- check_passwords_differ(sanitized_params) do
      {:ok, sanitized_params}
    else
      {:error, errors} when is_map(errors) ->
        {:error, errors}

      {:error, confirmation_msg} when is_binary(confirmation_msg) ->
        {:error, %{new_password_confirmation: confirmation_msg}}

      {:error, :same_password} ->
        {:error,
         %{
           new_password:
             dgettext("account", "New password must be different from current password")
         }}
    end
  end

  defp check_passwords_differ(params) do
    current = Map.get(params, "current_password", "")
    new_pw = Map.get(params, "new_password", "")

    if current == new_pw and current != "" do
      {:error, :same_password}
    else
      :ok
    end
  end
end
