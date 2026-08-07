defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent do
  @moduledoc """
  Function components for rendering the Meeting Types section header, add button, empty state,
  and the grid of meeting type cards, emitting events to the parent via parent_myself.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.MeetingSettings.Card

  attr :meeting_types, :list, required: true
  attr :show_add_form, :boolean, default: false
  attr :editing_type, :any, default: nil
  attr :currency, :string, default: "eur"
  attr :parent_myself, :any, required: true

  @spec meeting_types_section(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_types_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-token-xl font-semibold text-tymeslot-800">
          {dgettext("dashboard_meeting_types", "Meeting Types")}
        </h2>
        <%= unless @show_add_form || @editing_type do %>
          <button
            phx-click="toggle_add_form"
            phx-target={@parent_myself}
            class="btn btn-primary btn-sm"
          >
            <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            {dgettext("dashboard_meeting_types", "Add Meeting Type")}
          </button>
        <% end %>
      </div>

      <%= if @meeting_types == [] && !@show_add_form do %>
        <div class="card-glass text-center py-8">
          <svg
            class="w-12 h-12 mx-auto text-tymeslot-400 mb-3"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <p class="text-tymeslot-600">
            {dgettext("dashboard_meeting_types", "No meeting types configured yet")}
          </p>
          <p class="text-token-sm text-tymeslot-500 mt-1">
            {dgettext(
              "dashboard_meeting_types",
              "Create meeting types to offer different appointment options"
            )}
          </p>
        </div>
      <% else %>
        <div
          id="meeting-types-sortable-list"
          phx-hook="MeetingTypeSortable"
          data-target={@parent_myself}
          class="flex flex-col space-y-2"
        >
          <%= for type <- @meeting_types do %>
            <div draggable="true" data-meeting-type-id={type.id} class="cursor-move">
              <Card.meeting_type_card type={type} currency={@currency} myself={@parent_myself} />
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
