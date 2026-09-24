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
  alias Tymeslot.Locales
  alias TymeslotWeb.AccountLive.{ErrorFormatter, Helpers}
  alias TymeslotWeb.Helpers.ClientIP

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

  def handle_event("change_language", %{"locale" => locale}, socket) do
    case Auth.update_user_locale(socket.assigns.current_user, locale) do
      {:ok, updated_user} ->
        new_locale = Locales.acceptable(updated_user.locale) || socket.assigns.ambient_locale
        Gettext.put_locale(new_locale)

        # Re-navigate to the same page so the whole LiveView remounts and every
        # translated string re-renders in the new locale. LiveView's change
        # tracking otherwise keeps `dgettext/2` output that depends on no assign
        # (the card heading/description, the "Back to Dashboard" link) frozen in
        # the previous language. `AppLocaleHook` re-resolves the locale from the
        # saved `user.locale` on remount, falling back through the session/
        # default chain (`:ambient_locale`) when the preference was cleared
        # ("Automatic"). The flash mirrors that same resolution so it, too,
        # reads in the new language.
        {:noreply,
         socket
         |> LiveView.put_flash(:info, dgettext("account", "Language preference saved."))
         |> LiveView.push_navigate(to: ~p"/dashboard/account")}

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

      {:error, {_reason, message}} ->
        {:noreply, LiveView.put_flash(socket, :error, message)}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  # Private functions

  defp update_email(socket, params) do
    socket = assign(socket, :saving_email, true)

    # Every rule (rate limit, address format, current password) is the
    # domain's, which reports each field's problem at once.
    case Auth.request_email_change(
           socket.assigns.current_user,
           params["new_email"],
           params["current_password"],
           ClientIP.request_opts(socket)
         ) do
      {:ok, updated_user, message} ->
        {:noreply,
         socket
         |> LiveView.put_flash(:info, message)
         |> Helpers.reset_form_state(:email, updated_user)}

      {:error, :rate_limited, message} ->
        {:noreply, socket |> LiveView.put_flash(:error, message) |> assign(:saving_email, false)}

      {:error, errors} ->
        handle_update_error(socket, errors, :email)
    end
  end

  defp update_password(socket, params) do
    socket = assign(socket, :saving_password, true)

    # Every rule (rate limit, current password, new-password policy,
    # confirmation) is the domain's; restating any of them here would let the
    # two drift.
    case Auth.update_user_password(
           socket.assigns.current_user,
           params["current_password"],
           params["new_password"],
           params["new_password_confirmation"],
           ClientIP.request_opts(socket)
         ) do
      {:ok, _updated_user} ->
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
end
