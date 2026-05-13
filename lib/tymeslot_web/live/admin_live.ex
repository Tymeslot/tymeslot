defmodule TymeslotWeb.AdminLive do
  @moduledoc """
  Self-hosted admin control panel. Three tabs:

    * `:overview` — install summary (counts, source of truth for each setting)
    * `:settings` — toggle admin-editable runtime settings (registration,
      password auth, video transcoding)
    * `:users` — list users and promote/demote admin status

  Mounted under `/admin` with the `RequireAdminUiEnabled` + `RequireAdmin`
  plugs on the static path and the `EnsureAdminHook` on_mount on the live
  socket. Returning here from a non-admin context 404s rather than 403s.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.AppSettings
  alias Tymeslot.Auth

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Admin")}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, load_data(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("update_settings", %{"app_settings" => params}, socket) do
    case AppSettings.update(coerce_setting_values(params)) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Settings updated."))
         |> load_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :settings_form, to_form(changeset, as: "app_settings"))}
    end
  end

  def handle_event("reset_setting", %{"key" => key}, socket) do
    valid_keys = Map.new(AppSettings.keys(), fn k -> {Atom.to_string(k), k} end)

    case Map.fetch(valid_keys, key) do
      {:ok, atom_key} ->
        case AppSettings.reset(atom_key) do
          {:ok, _settings} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Setting reset to default."))
             |> load_data()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to reset setting."))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Unknown setting."))}
    end
  end

  def handle_event("promote_user", %{"id" => id}, socket) do
    case parse_user_id(id) do
      {:ok, user_id} -> handle_promote(user_id, socket)
      :error -> {:noreply, put_flash(socket, :error, gettext("Invalid user id."))}
    end
  end

  def handle_event("demote_user", %{"id" => id}, socket) do
    case parse_user_id(id) do
      {:ok, user_id} -> handle_demote(user_id, socket)
      :error -> {:noreply, put_flash(socket, :error, gettext("Invalid user id."))}
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
         |> put_flash(:info, gettext("User promoted to admin."))
         |> push_patch(to: ~p"/admin/users")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("User not found."))}

      {:error, :admin_ui_disabled} ->
        {:noreply, put_flash(socket, :error, gettext("Admin UI is disabled."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Could not promote user."))}
    end
  end

  defp handle_demote(user_id, socket) do
    case Auth.demote_admin(socket.assigns.current_user, user_id) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("User demoted from admin."))
         |> push_patch(to: ~p"/admin/users")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("User not found."))}

      {:error, :last_admin} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cannot demote the last admin. Promote someone else first.")
         )}

      {:error, :self_demotion} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot demote yourself."))}

      {:error, :admin_ui_disabled} ->
        {:noreply, put_flash(socket, :error, gettext("Admin UI is disabled."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Could not demote user."))}
    end
  end

  defp load_data(socket) do
    settings = AppSettings.get!()

    socket
    |> assign(:settings, settings)
    |> assign(:settings_form, to_form(Changeset.change(settings), as: "app_settings"))
    |> assign(:effective_values, AppSettings.effective_values())
    |> assign(:users, Auth.list_users())
    |> assign(:user_count, Auth.count_users())
    |> assign(:admin_count, Auth.count_admins())
  end

  # The select sends "" for "Use default", which maps to nil so the DB row
  # holds a NULL and the baseline/config value takes over again.
  defp coerce_setting_values(params) do
    params
    |> Map.take(Enum.map(AppSettings.keys(), &Atom.to_string/1))
    |> Map.new(fn {key, value} -> {key, coerce(value)} end)
  end

  defp coerce(""), do: nil
  defp coerce("true"), do: true
  defp coerce("false"), do: false
  defp coerce(other), do: other

  @impl Phoenix.LiveView
  def render(%{live_action: :overview} = assigns) do
    ~H"""
    <.admin_layout {assigns}>
      <div class="grid gap-6 sm:grid-cols-3">
        <.stat_card label={gettext("Total users")} value={@user_count} />
        <.stat_card label={gettext("Admins")} value={@admin_count} />
        <.stat_card label={gettext("DB overrides active")} value={count_db_overrides(@effective_values)} />
      </div>

      <div class="mt-8">
        <h2 class="text-token-xl font-semibold text-tymeslot-900 mb-4">{gettext("Effective settings")}</h2>
        <.settings_table effective_values={@effective_values} />
      </div>
    </.admin_layout>
    """
  end

  def render(%{live_action: :settings} = assigns) do
    ~H"""
    <.admin_layout {assigns}>
      <.form
        for={@settings_form}
        id="app-settings-form"
        phx-submit="update_settings"
        class="space-y-6"
      >
        <.setting_row
          :for={key <- AppSettings.keys()}
          field={@settings_form[key]}
          key={key}
          effective={Map.fetch!(@effective_values, key)}
        />

        <div class="flex justify-end">
          <.action_button type="submit" variant={:primary}>{gettext("Save changes")}</.action_button>
        </div>
      </.form>
    </.admin_layout>
    """
  end

  def render(%{live_action: :users} = assigns) do
    ~H"""
    <.admin_layout {assigns}>
      <div class="overflow-hidden rounded-token-lg border border-tymeslot-200 bg-white">
        <table class="min-w-full divide-y divide-tymeslot-200">
          <thead class="bg-tymeslot-50">
            <tr>
              <.th>{gettext("Email")}</.th>
              <.th>{gettext("Role")}</.th>
              <.th class="text-right">{gettext("Actions")}</.th>
            </tr>
          </thead>
          <tbody class="divide-y divide-tymeslot-100">
            <tr :for={user <- @users}>
              <td class="px-4 py-3 text-token-sm text-tymeslot-900">
                {user.email}
                <span :if={user.id == @current_user.id} class="ml-2 text-token-xs text-tymeslot-500">
                  {gettext("(you)")}
                </span>
              </td>
              <td class="px-4 py-3 text-token-sm">
                <span
                  :if={user.is_admin}
                  class="inline-flex items-center rounded-token-full bg-turquoise-100 px-2 py-0.5 text-token-xs font-medium text-turquoise-700"
                >
                  {gettext("Admin")}
                </span>
                <span :if={!user.is_admin} class="text-tymeslot-500">{gettext("User")}</span>
              </td>
              <td class="px-4 py-3 text-right">
                <button
                  :if={user.is_admin}
                  type="button"
                  phx-click="demote_user"
                  phx-value-id={user.id}
                  aria-label={gettext("Demote %{email} from admin", email: user.email)}
                  data-confirm={gettext("Demote %{email} from admin?", email: user.email)}
                  class="text-token-sm font-medium text-red-600 hover:text-red-800"
                >
                  {gettext("Demote")}
                </button>
                <button
                  :if={!user.is_admin}
                  type="button"
                  phx-click="promote_user"
                  phx-value-id={user.id}
                  aria-label={gettext("Promote %{email} to admin", email: user.email)}
                  data-confirm={gettext("Promote %{email} to admin?", email: user.email)}
                  class="text-token-sm font-medium text-turquoise-600 hover:text-turquoise-800"
                >
                  {gettext("Promote")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.admin_layout>
    """
  end

  # ----- Layout & UI helpers -----

  attr :live_action, :atom, required: true
  attr :current_user, :map, required: true
  slot :inner_block, required: true

  defp admin_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-tymeslot-50">
      <div class="container mx-auto px-4 py-8">
        <header class="mb-8 flex items-center justify-between">
          <div>
            <h1 class="display-lg text-tymeslot-900">{gettext("Admin")}</h1>
            <p class="mt-1 text-token-sm text-tymeslot-600">
              {gettext("Manage this self-hosted Tymeslot install.")}
            </p>
          </div>
          <.link
            navigate={~p"/dashboard"}
            class="text-token-sm font-medium text-turquoise-600 hover:text-turquoise-800"
          >
            {gettext("← Back to dashboard")}
          </.link>
        </header>

        <nav class="mb-6 flex gap-1 border-b border-tymeslot-200">
          <.tab_link to={~p"/admin"} active={@live_action == :overview}>{gettext("Overview")}</.tab_link>
          <.tab_link to={~p"/admin/settings"} active={@live_action == :settings}>{gettext("Settings")}</.tab_link>
          <.tab_link to={~p"/admin/users"} active={@live_action == :users}>{gettext("Users")}</.tab_link>
        </nav>

        <main>
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "px-4 py-2 text-token-sm font-medium border-b-2 -mb-px transition-colors",
        if(@active,
          do: "border-turquoise-500 text-turquoise-700",
          else: "border-transparent text-tymeslot-600 hover:text-tymeslot-900"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-token-lg border border-tymeslot-200 bg-white p-6">
      <p class="text-token-xs font-medium uppercase tracking-wide text-tymeslot-500">{@label}</p>
      <p class="mt-2 text-token-3xl font-semibold text-tymeslot-900">{@value}</p>
    </div>
    """
  end

  attr :effective_values, :map, required: true

  defp settings_table(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-token-lg border border-tymeslot-200 bg-white">
      <table class="min-w-full divide-y divide-tymeslot-200">
        <thead class="bg-tymeslot-50">
          <tr>
            <.th>{gettext("Setting")}</.th>
            <.th>{gettext("Value")}</.th>
            <.th>{gettext("Source")}</.th>
          </tr>
        </thead>
        <tbody class="divide-y divide-tymeslot-100">
          <%!-- Iterate in AppSettings.keys/0 order so the table is deterministic across renders. --%>
          <tr :for={key <- AppSettings.keys()}>
            <td class="px-4 py-3 text-token-sm font-medium text-tymeslot-900">
              {humanise(key)}
            </td>
            <td class="px-4 py-3 text-token-sm text-tymeslot-700">
              {format_value(Map.fetch!(@effective_values, key).value)}
            </td>
            <td class="px-4 py-3 text-token-sm">
              <.source_badge source={Map.fetch!(@effective_values, key).source} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :key, :atom, required: true
  attr :effective, :map, required: true

  defp setting_row(assigns) do
    ~H"""
    <div class="rounded-token-lg border border-tymeslot-200 bg-white p-6">
      <div class="flex items-start justify-between gap-6">
        <div class="flex-1">
          <h3 class="text-token-base font-semibold text-tymeslot-900">{humanise(@key)}</h3>
          <p class="mt-1 text-token-sm text-tymeslot-600">
            {gettext("Currently")} <span class="font-medium">{format_value(@effective.value)}</span>
            (<.source_badge source={@effective.source} inline />).
          </p>
        </div>

        <div class="flex items-center gap-3">
          <.input
            type="select"
            field={@field}
            value={value_to_select_value(@field.value)}
            options={[{gettext("Enabled"), "true"}, {gettext("Disabled"), "false"}]}
            prompt={gettext("Use config / default")}
          />

          <button
            :if={@effective.source == :db}
            type="button"
            phx-click="reset_setting"
            phx-value-key={@key}
            class="text-token-xs font-medium text-tymeslot-500 hover:text-tymeslot-900"
          >
            {gettext("Reset")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :source, :atom, required: true
  attr :inline, :boolean, default: false

  defp source_badge(assigns) do
    classes =
      case assigns.source do
        :db -> "bg-turquoise-100 text-turquoise-700"
        :config -> "bg-blue-100 text-blue-700"
        :default -> "bg-tymeslot-100 text-tymeslot-700"
      end

    label =
      case assigns.source do
        :db -> gettext("DB override")
        :config -> gettext("Environment / config")
        :default -> gettext("Built-in default")
      end

    assigns = assign(assigns, classes: classes, label: label)

    ~H"""
    <span class={[
      "inline-flex items-center rounded-token-full px-2 py-0.5 text-token-xs font-medium",
      @classes,
      if(@inline, do: "ml-0", else: "")
    ]}>
      {@label}
    </span>
    """
  end

  attr :class, :string, default: ""
  slot :inner_block, required: true

  defp th(assigns) do
    ~H"""
    <th
      scope="col"
      class={[
        "px-4 py-3 text-left text-token-xs font-medium uppercase tracking-wide text-tymeslot-500",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end

  defp humanise(:registration_enabled), do: gettext("Registration enabled")
  defp humanise(:password_auth_enabled), do: gettext("Password authentication")
  defp humanise(:video_transcoding_enabled), do: gettext("Video transcoding")

  defp humanise(key),
    do: key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_value(true), do: gettext("Enabled")
  defp format_value(false), do: gettext("Disabled")
  defp format_value(nil), do: "—"
  defp format_value(other), do: inspect(other)

  defp value_to_select_value(nil), do: ""
  defp value_to_select_value(true), do: "true"
  defp value_to_select_value(false), do: "false"
  defp value_to_select_value(value) when is_binary(value), do: value

  defp count_db_overrides(effective_values) do
    Enum.count(effective_values, fn {_key, info} -> info.source == :db end)
  end
end
