defmodule TymeslotWeb.AdminLive.Components.ConfirmCancelInvitationModal do
  @moduledoc """
  Confirmation modal for cancelling a pending invitation from the admin users
  tab. Cancelling deletes the invited account, which has no password,
  sign-in or data of its own yet, so the emailed link stops working; the
  modal says so before the admin confirms.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :user, :map, required: true, doc: "Map with :id and :email"
  attr :submitting, :boolean, default: false

  @spec confirm_cancel_invitation_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_cancel_invitation_modal(assigns) do
    ~H"""
    <.modal
      id="confirm-cancel-invitation-modal"
      show={true}
      on_cancel={JS.push("cancel_pending_action")}
      size={:small}
    >
      <:header>{dgettext("dashboard_admin_users", "Cancel invitation")}</:header>

      <p class="text-base text-tymeslot-700 font-medium leading-relaxed">
        {dgettext("dashboard_admin_users", "Cancel the invitation to %{email}?", email: @user.email)}
      </p>
      <p class="mt-3 text-sm text-tymeslot-600">
        {dgettext(
          "dashboard_admin_users",
          "The invitation link stops working and the invited account is removed. You can invite this address again later."
        )}
      </p>

      <:footer>
        <div class="flex gap-3 justify-end">
          <.action_button
            variant={:secondary}
            disabled={@submitting}
            phx-click={JS.push("cancel_pending_action")}
          >
            {dgettext("dashboard_admin_users", "Keep invitation")}
          </.action_button>
          <.loading_button
            variant={:danger}
            loading={@submitting}
            loading_text={dgettext("dashboard_admin_users", "Cancelling...")}
            phx-click="cancel_invitation"
            phx-value-id={@user.id}
          >
            {dgettext("dashboard_admin_users", "Cancel invitation")}
          </.loading_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
