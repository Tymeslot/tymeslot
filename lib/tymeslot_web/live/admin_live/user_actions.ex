defmodule TymeslotWeb.AdminLive.UserActions do
  @moduledoc """
  The users tab's actions for `TymeslotWeb.AdminLive`: opening and clearing
  the confirmation step (`:pending_action`) and the changes behind it. Kept
  apart from the LiveView so that module stays within the size limit; it
  touches only the socket and calls the `Tymeslot.Auth` context.
  """

  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3, redirect: 2]

  alias Tymeslot.Auth

  @type socket :: Phoenix.LiveView.Socket.t()

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
