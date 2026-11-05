defmodule TymeslotWeb.AdminLive.UserActions do
  @moduledoc """
  The users tab's actions for `TymeslotWeb.AdminLive`: opening and clearing
  the confirmation step (`:pending_action`) and the changes behind it. Kept
  apart from the LiveView so that module stays within the size limit; it
  touches only the socket and calls the `Tymeslot.Auth` context.
  """

  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3, redirect: 2]

  alias Tymeslot.Auth
  alias Tymeslot.Auth.Invitations

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  The invite form, blank or holding `email` with an error to show against it.
  """
  @spec invite_form(String.t(), String.t() | nil) :: Phoenix.HTML.Form.t()
  def invite_form(email \\ "", error \\ nil) do
    errors = if error, do: [email: {error, []}], else: []
    to_form(%{"email" => email}, as: :invite, errors: errors)
  end

  @spec invite(String.t(), socket()) :: {:noreply, socket()}
  def invite(email, socket) do
    case Invitations.invite(socket.assigns.current_user, email) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:invite_form, invite_form())
         |> put_flash(
           :info,
           dgettext("dashboard_admin", "Invitation sent to %{email}.", email: user.email)
         )
         |> push_patch(to: ~p"/admin/users")}

      {:error, :email_not_sent} ->
        {:noreply,
         socket
         |> assign(:invite_form, invite_form())
         |> put_flash(:error, invitation_not_sent_message())
         |> push_patch(to: ~p"/admin/users")}

      {:error, reason} when reason in [:invalid_email, :email_taken] ->
        {:noreply, assign(socket, :invite_form, invite_form(email, invite_error_message(reason)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, invite_error_message(reason))}
    end
  end

  @spec resend_invitation(String.t(), socket()) :: {:noreply, socket()}
  def resend_invitation(id, socket) do
    with_user_id(id, socket, fn user_id ->
      case Invitations.resend(socket.assigns.current_user, user_id) do
        {:ok, user} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             dgettext("dashboard_admin", "A new invitation is on its way to %{email}.",
               email: user.email
             )
           )
           |> push_patch(to: ~p"/admin/users")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, invite_error_message(reason))}
      end
    end)
  end

  defp invite_error_message(:invalid_email),
    do: dgettext("dashboard_admin", "Enter a valid email address.")

  defp invite_error_message(:email_taken),
    do: dgettext("dashboard_admin", "An account with this email address already exists.")

  defp invite_error_message(:password_auth_disabled),
    do:
      dgettext(
        "dashboard_admin",
        "Invitations need password sign-in. Enable password authentication first."
      )

  defp invite_error_message(:not_invited),
    do: dgettext("dashboard_admin", "This user has already accepted their invitation.")

  defp invite_error_message(:email_not_sent), do: invitation_not_sent_message()

  defp invite_error_message(reason) when reason in [:not_found, :forbidden, :admin_ui_disabled],
    do: role_change_error_message(:invite, reason)

  defp invite_error_message(_other),
    do: dgettext("dashboard_admin", "Could not send the invitation. Please try again.")

  defp invitation_not_sent_message,
    do:
      dgettext(
        "dashboard_admin",
        "The account was created, but the invitation email could not be sent. Use Resend invitation to try again."
      )

  @spec open_pending_action(atom(), map(), socket()) :: {:noreply, socket()}
  def open_pending_action(kind, %{"id" => id, "email" => email}, socket) do
    case parse_user_id(id) do
      {:ok, user_id} ->
        {:noreply, assign(socket, :pending_action, %{kind: kind, id: user_id, email: email})}

      :error ->
        {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid user id."))}
    end
  end

  def open_pending_action(_kind, _params, socket) do
    {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid request."))}
  end

  @spec clear_pending_action(socket()) :: socket()
  def clear_pending_action(socket) do
    socket
    |> assign(:pending_action, nil)
    |> assign(:role_change_submitting, false)
  end

  @spec promote(String.t(), socket()) :: {:noreply, socket()}
  def promote(id, socket) do
    with_user_id(id, socket, &handle_promote(&1, assign(socket, :role_change_submitting, true)))
  end

  @spec demote(String.t(), socket()) :: {:noreply, socket()}
  def demote(id, socket) do
    with_user_id(id, socket, &handle_demote(&1, assign(socket, :role_change_submitting, true)))
  end

  @spec delete(String.t(), socket()) :: {:noreply, socket()}
  def delete(id, socket) do
    with_user_id(id, socket, &handle_delete(&1, assign(socket, :role_change_submitting, true)))
  end

  defp with_user_id(id, socket, fun) do
    case parse_user_id(id) do
      {:ok, user_id} ->
        fun.(user_id)

      :error ->
        {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid user id."))}
    end
  end

  defp parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {user_id, ""} when user_id > 0 -> {:ok, user_id}
      _other -> :error
    end
  end

  defp parse_user_id(_id), do: :error

  defp handle_promote(user_id, socket) do
    case Auth.promote_admin(socket.assigns.current_user, user_id) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:info, dgettext("dashboard_admin", "User promoted to admin."))
         |> push_patch(to: ~p"/admin/users")}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:error, role_change_error_message(:promote, reason))}
    end
  end

  defp handle_demote(user_id, socket) do
    self_demote? = user_id == socket.assigns.current_user.id

    case Auth.demote_admin(socket.assigns.current_user, user_id) do
      {:ok, _user} when self_demote? ->
        # Self-demote: force a full reload of /dashboard so the new request
        # runs through the plug pipeline with the now-demoted user, dropping
        # the admin menu entry and blocking /admin reentry.
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:info, dgettext("dashboard_admin", "You have been demoted from admin."))
         |> redirect(to: ~p"/dashboard")}

      {:ok, _user} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:info, dgettext("dashboard_admin", "User demoted from admin."))
         |> push_patch(to: ~p"/admin/users")}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:error, role_change_error_message(:demote, reason))}
    end
  end

  defp role_change_error_message(_action, :not_found),
    do: dgettext("dashboard_admin", "User not found.")

  defp role_change_error_message(_action, :forbidden),
    do: dgettext("dashboard_admin", "Admin access required.")

  defp role_change_error_message(_action, :admin_ui_disabled),
    do: dgettext("dashboard_admin", "Admin UI is disabled.")

  defp role_change_error_message(:demote, :last_admin),
    do:
      dgettext(
        "dashboard_admin",
        "Cannot demote this admin: no other admin can sign in. Make sure another admin can sign in first."
      )

  defp role_change_error_message(:promote, %Ecto.Changeset{}),
    do: dgettext("dashboard_admin", "Could not promote user.")

  defp role_change_error_message(:demote, %Ecto.Changeset{}),
    do: dgettext("dashboard_admin", "Could not demote user.")

  defp handle_delete(user_id, socket) do
    case Auth.delete_account_now(socket.assigns.current_user, user_id) do
      {:ok, pending} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(
           :info,
           dgettext(
             "dashboard_admin",
             "Deleting %{email}. The account leaves this list once the deletion has run.",
             email: pending.email
           )
         )
         |> push_patch(to: ~p"/admin/users")}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:error, delete_error_message(reason))}
    end
  end

  defp delete_error_message(:self) do
    dgettext(
      "dashboard_admin",
      "You cannot delete your own account here. Use your account settings instead."
    )
  end

  defp delete_error_message(:last_admin),
    do:
      dgettext(
        "dashboard_admin",
        "Cannot delete this admin: no other admin can sign in. Make sure another admin can sign in first."
      )

  defp delete_error_message(reason) when reason in [:not_found, :forbidden, :admin_ui_disabled],
    do: role_change_error_message(:delete, reason)

  defp delete_error_message(_other), do: dgettext("dashboard_admin", "Could not delete user.")
end
