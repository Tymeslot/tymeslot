defmodule TymeslotWeb.AdminLive.Components.Users do
  @moduledoc """
  Users tab: install user counts at the top, followed by the list of users
  with promote/demote actions and the confirmation modal that opens when
  a row action is triggered.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.AdminLive.Components.{ConfirmRoleChangeModal, Shared}

  attr :users, :list, required: true
  attr :current_user, :map, required: true
  attr :user_count, :integer, required: true
  attr :admin_count, :integer, required: true
  attr :pending_action, :any, required: true
  attr :role_change_submitting, :boolean, required: true

  @spec users_tab(map()) :: Phoenix.LiveView.Rendered.t()
  def users_tab(assigns) do
    ~H"""
    <div class="grid gap-6 sm:grid-cols-2 mb-8">
      <.stat_card label={dgettext("dashboard", "Total users")} value={@user_count} />
      <.stat_card label={dgettext("dashboard", "Admins")} value={@admin_count} />
    </div>

    <div class="card-glass !p-0 overflow-hidden">
      <table class="min-w-full divide-y divide-tymeslot-100">
        <thead class="bg-tymeslot-50/60">
          <tr>
            <Shared.th>{dgettext("dashboard", "Email")}</Shared.th>
            <Shared.th>{dgettext("dashboard", "Display name")}</Shared.th>
            <Shared.th>{dgettext("dashboard", "Booking slug")}</Shared.th>
            <Shared.th>{dgettext("dashboard", "Role")}</Shared.th>
            <Shared.th class="text-right">{dgettext("dashboard", "Actions")}</Shared.th>
          </tr>
        </thead>
        <tbody class="divide-y divide-tymeslot-50">
          <tr :for={user <- @users} class="hover:bg-tymeslot-50/40 transition-colors">
            <td class="px-6 py-4 text-sm font-medium text-tymeslot-900">
              {user.email}
              <span
                :if={user.id == @current_user.id}
                class="ml-2 text-xs font-bold text-tymeslot-500 uppercase tracking-wider"
              >
                {dgettext("dashboard", "(you)")}
              </span>
            </td>
            <td class="px-6 py-4 text-sm text-tymeslot-900">
              <span :if={profile_full_name(user)}>{profile_full_name(user)}</span>
              <span :if={!profile_full_name(user)} class="text-tymeslot-400">—</span>
            </td>
            <td class="px-6 py-4 text-sm text-tymeslot-700">
              <span :if={profile_username(user)} class="font-mono">{profile_username(user)}</span>
              <span :if={!profile_username(user)} class="text-tymeslot-400">—</span>
            </td>
            <td class="px-6 py-4">
              <span
                :if={user.is_admin}
                class="inline-flex items-center rounded-full bg-turquoise-100 px-3 py-1 text-xs font-black uppercase tracking-wider text-turquoise-700"
              >
                {dgettext("dashboard", "Admin")}
              </span>
              <span :if={!user.is_admin} class="text-sm text-tymeslot-500">{dgettext("dashboard", "User")}</span>
            </td>
            <td class="px-6 py-4 text-right">
              <.user_row_action
                user={user}
                is_self={user.id == @current_user.id}
                is_last_admin={@admin_count <= 1}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <ConfirmRoleChangeModal.confirm_role_change_modal
      :if={@pending_action}
      action={@pending_action.kind}
      user={@pending_action}
      self?={@pending_action.id == @current_user.id}
      submitting={@role_change_submitting}
    />
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="card-glass">
      <p class="text-xs font-black uppercase tracking-wider text-tymeslot-500 mb-2">{@label}</p>
      <p class="text-4xl font-black text-tymeslot-900 tracking-tight">{@value}</p>
    </div>
    """
  end

  defp profile_full_name(%{profile: %ProfileSchema{full_name: name}})
       when is_binary(name) and name != "",
       do: name

  defp profile_full_name(_user), do: nil

  defp profile_username(%{profile: %ProfileSchema{username: username}})
       when is_binary(username) and username != "",
       do: username

  defp profile_username(_user), do: nil

  attr :user, :map, required: true
  attr :is_self, :boolean, required: true
  attr :is_last_admin, :boolean, required: true

  defp user_row_action(assigns) do
    ~H"""
    <%!-- Only-admin self row: explain why demote is disabled. --%>
    <div
      :if={@user.is_admin and @is_self and @is_last_admin}
      class="inline-flex flex-col items-end gap-1"
      data-testid="last-admin-self-note"
    >
      <span class="inline-flex items-center text-sm font-bold text-tymeslot-300 cursor-not-allowed select-none">
        {dgettext("dashboard", "Demote")}
      </span>
      <span class="text-xs text-tymeslot-500 font-medium max-w-xs text-right">
        {dgettext("dashboard", "You're the only admin. Promote someone else before demoting yourself.")}
      </span>
    </div>

    <%!-- @admin_count is loaded per handle_params; the server guard in AdminRoles
         is authoritative and will block the last-admin demote even if this button
         is momentarily visible due to concurrent role changes between sessions. --%>
    <button
      :if={@user.is_admin and not (@is_self and @is_last_admin)}
      type="button"
      phx-click="request_demote"
      phx-value-id={@user.id}
      phx-value-email={@user.email}
      aria-label={dgettext("dashboard", "Demote %{email} from admin", email: @user.email)}
      class="inline-flex items-center text-sm font-bold text-red-600 hover:text-red-800 transition-colors"
    >
      {dgettext("dashboard", "Demote")}
    </button>

    <button
      :if={not @user.is_admin}
      type="button"
      phx-click="request_promote"
      phx-value-id={@user.id}
      phx-value-email={@user.email}
      aria-label={dgettext("dashboard", "Promote %{email} to admin", email: @user.email)}
      class="inline-flex items-center text-sm font-bold text-turquoise-600 hover:text-turquoise-800 transition-colors"
    >
      {dgettext("dashboard", "Promote")}
    </button>
    """
  end
end
