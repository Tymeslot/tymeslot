defmodule TymeslotWeb.AdminLive do
  @moduledoc """
  Self-hosted admin control panel. Two tabs:

    * `:settings` — toggle admin-editable runtime settings (registration,
      password auth). These overrides shadow any matching environment
      variable / application config value.
    * `:users` — list users with counts at the top and
      promote/demote admin actions.

  Mounted under `/admin` with the `RequireAdminUiEnabled` + `RequireAdmin`
  plugs on the static path and the `EnsureAdminHook` on_mount on the live
  socket. Returning here from a non-admin context 404s rather than 403s.

  `/admin` resolves to `:settings`; each tab's rendering lives in its own
  component module under `TymeslotWeb.AdminLive.Components.*`. This module
  owns the LiveView callbacks, data loading, and event handling.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.AppSettings
  alias Tymeslot.Auth
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.AdminLive.Components.{Layout, Settings, Users}
  alias TymeslotWeb.AdminLive.Formatters

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:profile, nil)
     |> assign(:pending_action, nil)
     |> assign(:role_change_submitting, false)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, load_data(socket)}
  end

  # --- Settings tab events ---

  @impl Phoenix.LiveView
  def handle_event("set_setting", %{"key" => key, "state" => state}, socket) do
    with {:ok, atom_key} <- parse_setting_key(key),
         {:ok, parsed} <- parse_setting_value(state) do
      handle_setting_update(socket, atom_key, parsed, state)
    else
      _other ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  # Submit handler used by score and email inputs that don't fit the
  # two-state Enabled/Disabled toggle pattern. Score inputs autosave on blur
  # via `phx-change`, so the handler short-circuits when the value is
  # unchanged to avoid spurious flashes on tab-through.
  def handle_event("save_setting", %{"key" => key} = params, socket) do
    raw_value = Map.get(params, "value", "")

    with {:ok, atom_key} <- parse_setting_key(key),
         {:ok, value} <- parse_typed_value(atom_key, raw_value),
         :changed <- detect_change(socket, atom_key, value) do
      handle_typed_setting_update(socket, atom_key, value)
    else
      :unchanged ->
        {:noreply, socket}

      :invalid ->
        {:noreply, put_flash(socket, :error, value_invalid_message(key))}

      _other ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  # --- Users tab events: role-change flow ---

  def handle_event("request_promote", params, socket),
    do: open_pending_action(:promote, params, socket)

  def handle_event("request_demote", params, socket),
    do: open_pending_action(:demote, params, socket)

  def handle_event("cancel_pending_action", _params, socket) do
    {:noreply, clear_pending_action(socket)}
  end

  def handle_event("promote_user", %{"id" => id}, socket) do
    with_user_id(id, socket, &handle_promote(&1, assign(socket, :role_change_submitting, true)))
  end

  def handle_event("demote_user", %{"id" => id}, socket) do
    with_user_id(id, socket, &handle_demote(&1, assign(socket, :role_change_submitting, true)))
  end

  defp handle_setting_update(socket, atom_key, parsed, state) do
    case AppSettings.update(%{atom_key => parsed}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> put_flash(:info, setting_change_message(atom_key, state))
         |> load_data()}

      {:error, :would_lock_out} ->
        {:noreply, put_flash(socket, :error, lock_out_message(atom_key, parsed))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  # Picks the lock-reason copy that matches the specific key/value the admin
  # tried to set. Falls back to a generic message if no tailored clause
  # exists, so an SSO toggle rejection never shows a password-auth message.
  defp lock_out_message(key, value) do
    Formatters.lock_reason(key, value) ||
      dgettext("dashboard_admin", "That change would lock everyone out and was not applied.")
  end

  # --- Settings helpers ---

  defp parse_setting_key(key) do
    AppSettings.keys()
    |> Map.new(fn k -> {Atom.to_string(k), k} end)
    |> Map.fetch(key)
  end

  defp parse_setting_value("true"), do: {:ok, true}
  defp parse_setting_value("false"), do: {:ok, false}
  defp parse_setting_value(_other), do: :error

  defp setting_change_message(key, "true"),
    do: dgettext("dashboard_admin", "%{name} enabled.", name: Formatters.humanise(key))

  defp setting_change_message(key, "false"),
    do: dgettext("dashboard_admin", "%{name} disabled.", name: Formatters.humanise(key))

  defp handle_typed_setting_update(socket, key, value) do
    case AppSettings.update(%{key => value}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("dashboard_admin", "%{name} updated.", name: Formatters.humanise(key))
         )
         |> push_event("ts:setting-saved", %{key: Atom.to_string(key)})
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset, key))}

      {:error, _other} ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  defp parse_typed_value(key, raw) do
    case Formatters.kind(key) do
      :score -> parse_score(raw)
      :email -> parse_email(raw)
      :boolean -> :invalid
    end
  end

  defp detect_change(socket, key, value) do
    case get_in(socket.assigns, [:effective_values, key]) do
      %{value: ^value} -> :unchanged
      _other -> :changed
    end
  end

  # Empty string clears the override. Trim to avoid whitespace-only inputs
  # reaching the schema.
  defp parse_email(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_email(_other), do: :invalid

  defp parse_score(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {score, ""} when score >= 0.0 and score <= 1.0 -> {:ok, score}
      _other -> :invalid
    end
  end

  defp parse_score(_other), do: :invalid

  defp value_invalid_message(key) do
    case parse_setting_key(key) do
      {:ok, atom_key} ->
        case Formatters.kind(atom_key) do
          :score -> dgettext("dashboard_admin", "Enter a number between 0.0 and 1.0.")
          :email -> dgettext("dashboard_admin", "Enter a valid email address.")
          _other -> dgettext("dashboard_admin", "Could not update setting.")
        end

      _other ->
        dgettext("dashboard_admin", "Could not update setting.")
    end
  end

  # Changeset errors from validate_format ("has invalid format") and
  # validate_number ("must be greater than or equal to 0.0", etc.) are
  # accurate but not friendly. Map them to the same human messages the inline
  # parser uses so admins see one consistent phrasing whichever guard catches
  # the bad input.
  defp changeset_message(%Ecto.Changeset{errors: errors}, key) do
    case Keyword.get(errors, key) do
      {_message, _meta} -> value_invalid_message(Atom.to_string(key))
      nil -> dgettext("dashboard_admin", "Could not update setting.")
    end
  end

  # --- Role-change helpers ---

  defp open_pending_action(kind, %{"id" => id, "email" => email}, socket) do
    case parse_user_id(id) do
      {:ok, user_id} ->
        {:noreply, assign(socket, :pending_action, %{kind: kind, id: user_id, email: email})}

      :error ->
        {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid user id."))}
    end
  end

  defp open_pending_action(_kind, _params, socket) do
    {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid request."))}
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

  defp role_change_error_message(_action, :admin_ui_disabled),
    do: dgettext("dashboard_admin", "Admin UI is disabled.")

  defp role_change_error_message(:demote, :last_admin),
    do: dgettext("dashboard_admin", "Cannot demote the last admin. Promote someone else first.")

  defp role_change_error_message(:promote, %Ecto.Changeset{}),
    do: dgettext("dashboard_admin", "Could not promote user.")

  defp role_change_error_message(:demote, %Ecto.Changeset{}),
    do: dgettext("dashboard_admin", "Could not demote user.")

  defp clear_pending_action(socket) do
    socket
    |> assign(:pending_action, nil)
    |> assign(:role_change_submitting, false)
  end

  # --- Data loading ---

  defp load_data(socket) do
    user = socket.assigns.current_user
    profile = Profiles.get_profile(user.id) || %ProfileSchema{user_id: user.id}

    socket
    |> assign(:profile, profile)
    |> assign(:effective_values, AppSettings.effective_values())
    |> assign(:users, Auth.list_users())
    |> assign(:user_count, Auth.count_users())
    |> assign(:admin_count, Auth.count_admins())
  end

  # --- Render: each tab is a thin shell around its component module ---

  @impl Phoenix.LiveView
  def render(%{live_action: :settings} = assigns) do
    ~H"""
    <Layout.admin_layout
      live_action={@live_action}
      current_user={@current_user}
      profile={@profile}
    >
      <Settings.settings_tab effective_values={@effective_values} />
    </Layout.admin_layout>
    """
  end

  def render(%{live_action: :users} = assigns) do
    ~H"""
    <Layout.admin_layout
      live_action={@live_action}
      current_user={@current_user}
      profile={@profile}
    >
      <Users.users_tab
        users={@users}
        current_user={@current_user}
        user_count={@user_count}
        admin_count={@admin_count}
        pending_action={@pending_action}
        role_change_submitting={@role_change_submitting}
      />
    </Layout.admin_layout>
    """
  end
end
