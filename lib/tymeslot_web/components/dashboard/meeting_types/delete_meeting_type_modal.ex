defmodule TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal do
  @moduledoc """
  Delete confirmation modal for meeting types.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders a delete confirmation modal for meeting types.

  ## Attributes

    * `show` - Boolean to show/hide the modal (required)
    * `meeting_type` - The meeting type to be deleted (required when show is true)
    * `myself` - The LiveComponent target for event handling (required)

  ## Examples

      <DeleteMeetingTypeModal.delete_meeting_type_modal
        show={@show_delete_meeting_type_modal}
        meeting_type={@delete_meeting_type_modal_data}
        myself={@myself}
      />
  """
  attr :show, :boolean, required: true
  attr :meeting_type, :map, default: nil
  attr :myself, :any, required: true

  @spec delete_meeting_type_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_meeting_type_modal(assigns) do
    ~H"""
    <CoreComponents.confirm_modal
      id="delete-meeting-type-modal"
      show={@show && @meeting_type != nil}
      title={dgettext("dashboard_meeting_types", "Delete Meeting Type")}
      confirm_label={dgettext("dashboard_meeting_types", "Delete Meeting Type")}
      on_cancel={JS.push("hide_delete_modal", target: @myself)}
      on_confirm={JS.push("confirm_delete_meeting_type", target: @myself)}
    >
      <%= if @meeting_type do %>
        <p>
          {dgettext(
            "dashboard_meeting_types",
            "Are you sure you want to delete the meeting type \"%{name}\"?",
            name: @meeting_type.name
          )}
        </p>
        <p class="text-tymeslot-500">
          {dgettext(
            "dashboard_meeting_types",
            "This action cannot be undone and will permanently remove this meeting type from your account."
          )}
        </p>
      <% end %>
    </CoreComponents.confirm_modal>
    """
  end
end
