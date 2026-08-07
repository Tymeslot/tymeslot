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
    <CoreComponents.modal
      id="delete-meeting-type-modal"
      show={@show && @meeting_type != nil}
      on_cancel={JS.push("hide_delete_modal", target: @myself)}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-2">
          <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
            />
          </svg>
          <span>{dgettext("dashboard_meeting_types", "Delete Meeting Type")}</span>
        </div>
      </:header>

      <%= if @meeting_type do %>
        <div class="space-y-4">
          <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
            {dgettext(
              "dashboard_meeting_types",
              "Are you sure you want to delete the meeting type \"%{name}\"?",
              name: @meeting_type.name
            )}
          </p>
          <p class="text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_meeting_types",
              "This action cannot be undone and will permanently remove this meeting type from your account."
            )}
          </p>
        </div>
      <% end %>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button
            variant={:secondary}
            phx-click={JS.push("hide_delete_modal", target: @myself)}
          >
            {dgettext("dashboard_meeting_types", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button
            variant={:danger}
            phx-click={JS.push("confirm_delete_meeting_type", target: @myself)}
          >
            {dgettext("dashboard_meeting_types", "Delete Meeting Type")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
