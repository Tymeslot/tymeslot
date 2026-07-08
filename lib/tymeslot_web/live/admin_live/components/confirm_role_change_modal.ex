defmodule TymeslotWeb.AdminLive.Components.ConfirmRoleChangeModal do
  @moduledoc """
  Confirmation modal for promoting a user to admin or demoting an admin.
  Replaces the browser-native `data-confirm` dialog so the admin flow stays
  inside the design system.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :action, :atom, required: true, values: [:promote, :demote]
  attr :user, :map, required: true, doc: "Map with :id and :email"
  attr :self?, :boolean, default: false, doc: "True when the target is the current admin"
  attr :submitting, :boolean, default: false

  @spec confirm_role_change_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_role_change_modal(assigns) do
    ~H"""
    <.modal
      id="confirm-role-change-modal"
      show={true}
      on_cancel={JS.push("cancel_pending_action")}
      size={:xsmall}
    >
      <:header>{header_label(@action, @self?)}</:header>

      <p :if={@action == :promote} class="text-base text-tymeslot-700 font-medium leading-relaxed">
        {dgettext("dashboard_admin", "Promote")}
        <span class="font-black text-tymeslot-900">{@user.email}</span>
        {dgettext("dashboard_admin", "to admin?")}
      </p>
      <p
        :if={@action == :demote and @self?}
        class="text-base text-tymeslot-700 font-medium leading-relaxed"
      >
        {dgettext("dashboard_admin", "Demote yourself from admin?")}
      </p>
      <p
        :if={@action == :demote and not @self?}
        class="text-base text-tymeslot-700 font-medium leading-relaxed"
      >
        {dgettext("dashboard_admin", "Demote")}
        <span class="font-black text-tymeslot-900">{@user.email}</span>
        {dgettext("dashboard_admin", "from admin?")}
      </p>

      <p :if={@action == :promote} class="mt-3 text-sm text-tymeslot-500">
        {dgettext("dashboard_admin", "They will gain access to admin settings and user management.")}
      </p>
      <p :if={@action == :demote and @self?} class="mt-3 text-sm text-amber-600 font-medium">
        {dgettext("dashboard_admin", 
          "You will lose access to admin settings and user management, and be returned to your dashboard."
        )}
      </p>
      <p :if={@action == :demote and not @self?} class="mt-3 text-sm text-amber-600 font-medium">
        {dgettext("dashboard_admin", "They will lose access to admin settings and user management.")}
      </p>

      <:footer>
        <div class="flex gap-3 justify-end">
          <.action_button
            variant={:secondary}
            disabled={@submitting}
            phx-click={JS.push("cancel_pending_action")}
          >
            {dgettext("dashboard_admin", "Cancel")}
          </.action_button>
          <.loading_button
            variant={confirm_variant(@action)}
            loading={@submitting}
            loading_text={loading_label(@action)}
            phx-click={confirm_event(@action)}
            phx-value-id={@user.id}
          >
            {confirm_label(@action, @self?)}
          </.loading_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  defp header_label(:promote, _self?), do: dgettext("dashboard_admin", "Promote user to admin")
  defp header_label(:demote, true), do: dgettext("dashboard_admin", "Demote yourself")
  defp header_label(:demote, false), do: dgettext("dashboard_admin", "Demote admin")

  defp confirm_variant(:promote), do: :primary
  defp confirm_variant(:demote), do: :danger

  defp confirm_event(:promote), do: "promote_user"
  defp confirm_event(:demote), do: "demote_user"

  defp confirm_label(:promote, _self?), do: dgettext("dashboard_admin", "Promote")
  defp confirm_label(:demote, true), do: dgettext("dashboard_admin", "Demote me")
  defp confirm_label(:demote, false), do: dgettext("dashboard_admin", "Demote")

  defp loading_label(:promote), do: dgettext("dashboard_admin", "Promoting...")
  defp loading_label(:demote), do: dgettext("dashboard_admin", "Demoting...")
end
