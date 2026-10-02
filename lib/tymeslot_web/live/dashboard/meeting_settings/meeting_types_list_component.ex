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
  attr :venues, :list, default: []
  attr :parent_myself, :any, required: true

  @spec meeting_types_section(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_types_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-token-xl font-semibold text-tymeslot-800">
          {dgettext("dashboard_meeting_types", "Meeting Types")}
        </h2>
        <%!-- With no meeting types yet, the empty state below carries the action. --%>
        <.add_meeting_type_button
          :if={!@show_add_form and !@editing_type and @meeting_types != []}
          parent_myself={@parent_myself}
        />
      </div>

      <%= if @meeting_types == [] && !@show_add_form do %>
        <.empty_state
          icon="hero-clock"
          size={:lg}
          title={dgettext("dashboard_meeting_types", "No meeting types configured yet")}
          description={
            dgettext(
              "dashboard_meeting_types",
              "Create meeting types to offer different appointment options"
            )
          }
        >
          <:action :if={!@editing_type}>
            <.add_meeting_type_button parent_myself={@parent_myself} />
          </:action>
        </.empty_state>
      <% else %>
        <div
          id="meeting-types-sortable-list"
          phx-hook="MeetingTypeSortable"
          data-target={@parent_myself}
          class="flex flex-col space-y-2"
        >
          <%= for type <- @meeting_types do %>
            <div draggable="true" data-meeting-type-id={type.id} class="cursor-move">
              <Card.meeting_type_card
                type={type}
                currency={@currency}
                venues={@venues}
                myself={@parent_myself}
              />
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :parent_myself, :any, required: true

  defp add_meeting_type_button(assigns) do
    ~H"""
    <button phx-click="toggle_add_form" phx-target={@parent_myself} class="btn btn-primary btn-sm">
      <.icon name="hero-plus" class="w-4 h-4 mr-2" />
      {dgettext("dashboard_meeting_types", "Add Meeting Type")}
    </button>
    """
  end
end
