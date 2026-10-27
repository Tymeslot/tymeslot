defmodule TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal do
  @moduledoc """
  Delete confirmation modal for meeting types.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  @doc """
  Renders a delete confirmation modal for meeting types.

  ## Attributes

    * `show` - Boolean to show/hide the modal (required)
    * `meeting_type` - The meeting type to be deleted (required when show is true)
    * `sign_ups` - `{dates, people}`: the fixed-date type's upcoming dates the
      delete cancels and the people booked on them
      (`Tymeslot.MeetingTypes.upcoming_sign_ups/1`)
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
  attr :sign_ups, :any, default: {0, 0}
  attr :myself, :any, required: true

  @spec delete_meeting_type_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_meeting_type_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id="delete-meeting-type-modal"
      show={@show && @meeting_type != nil}
      title={dgettext("dashboard_meeting_types", "Delete meeting type")}
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
        <p :if={elem(@sign_ups, 0) > 0} data-testid="delete-cancels-dates">
          {dngettext(
            "dashboard_meeting_types",
            "Its upcoming date is cancelled.",
            "Its %{count} upcoming dates are cancelled.",
            elem(@sign_ups, 0)
          )}
          <span :if={elem(@sign_ups, 1) > 0}>
            {dngettext(
              "dashboard_meeting_types",
              "The %{count} person who signed up is told by email.",
              "The %{count} people who signed up are told by email.",
              elem(@sign_ups, 1)
            )}
          </span>
        </p>
        <p class="text-tymeslot-500">
          {dgettext(
            "dashboard_meeting_types",
            "This action cannot be undone and will permanently remove this meeting type from your account."
          )}
        </p>
      <% end %>
    </Modal.confirm_modal>
    """
  end
end
