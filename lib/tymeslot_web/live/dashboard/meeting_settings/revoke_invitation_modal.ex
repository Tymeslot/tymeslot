defmodule TymeslotWeb.Dashboard.MeetingSettings.RevokeInvitationModal do
  @moduledoc """
  Confirms revoking an invitation link. Revoking stops new bookings only, so
  the modal says an appointment already booked through the link stays booked.

  Confirm pushes `revoke` with the invitation's id and Cancel pushes
  `cancel_revoke`, both to the owning `InvitationsComponent` (`myself`).
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  attr :id, :string, required: true
  attr :invitation_id, :any, default: nil, doc: "The invitation to revoke; nil hides the modal"
  attr :myself, :any, required: true

  @spec revoke_invitation_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def revoke_invitation_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id={@id}
      show={@invitation_id != nil}
      title={dgettext("dashboard_meeting_types", "Revoke this link?")}
      confirm_label={dgettext("dashboard_meeting_types", "Revoke link")}
      on_cancel={JS.push("cancel_revoke", target: @myself)}
      on_confirm={JS.push("revoke", value: %{id: @invitation_id}, target: @myself)}
    >
      <p>
        {dgettext(
          "dashboard_meeting_types",
          "It will stop working. Any appointment already booked stays booked."
        )}
      </p>
    </Modal.confirm_modal>
    """
  end
end
