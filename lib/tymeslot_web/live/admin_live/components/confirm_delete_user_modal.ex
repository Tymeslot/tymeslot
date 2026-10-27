defmodule TymeslotWeb.AdminLive.Components.ConfirmDeleteUserModal do
  @moduledoc """
  Confirmation modal for deleting a user from the admin users tab. The
  deletion starts at once (no grace period) and cannot be undone, and the
  user's guests are not told about the bookings that go, so the modal says
  so before the admin confirms.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :user, :map, required: true, doc: "Map with :id and :email"
  attr :submitting, :boolean, default: false

  @spec confirm_delete_user_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_delete_user_modal(assigns) do
    ~H"""
    <.modal
      id="confirm-delete-user-modal"
      show={true}
      on_cancel={JS.push("cancel_pending_action")}
      size={:small}
    >
      <:header>{dgettext("dashboard_admin", "Delete user")}</:header>

      <p class="text-base text-tymeslot-700 font-medium leading-relaxed">
        {dgettext("dashboard_admin", "Delete %{email} and all their data now?", email: @user.email)}
      </p>
      <p class="mt-3 text-sm text-amber-600 font-medium">
        {dgettext(
          "dashboard_admin",
          "This cannot be undone. Their bookings are deleted and their guests are not notified; existing calendar events and video links stay as they are."
        )}
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
            variant={:danger}
            loading={@submitting}
            loading_text={dgettext("dashboard_admin", "Deleting...")}
            phx-click="delete_user"
            phx-value-id={@user.id}
          >
            {dgettext("dashboard_admin", "Delete user")}
          </.loading_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
