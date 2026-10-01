defmodule TymeslotWeb.Dashboard.Locations.VenueCard do
  @moduledoc """
  One saved location on the Locations page: its name, its address as the
  organiser wrote it, how many meeting types offer it, and Edit and Delete.
  The card is the draggable item `QuestionsSortable` reorders, identified by
  `data-id`.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :venue, :map, required: true
  attr :usage, :integer, required: true, doc: "how many meeting types offer the venue"
  attr :myself, :any, required: true

  @spec venue_card(map()) :: Phoenix.LiveView.Rendered.t()
  def venue_card(assigns) do
    ~H"""
    <div
      class="card-glass p-4 flex items-start gap-3"
      data-testid="venue-card"
      data-venue-id={@venue.id}
      data-id={@venue.id}
      draggable="true"
    >
      <span class="drag-handle cursor-grab active:cursor-grabbing text-tymeslot-400 shrink-0 mt-0.5">
        <.icon name="hero-bars-2" class="w-4 h-4" />
      </span>
      <.icon name="hero-map-pin" class="w-5 h-5 text-turquoise-500 shrink-0 mt-0.5" />
      <div class="flex-1 min-w-0">
        <h3 class="text-token-base font-semibold text-tymeslot-800 truncate">{@venue.name}</h3>
        <%!-- Kept on one line: under whitespace-pre-line, any line break
             around the text would render as an empty line. --%>
        <p
          :if={@venue.description}
          class="mt-1 text-token-sm text-tymeslot-600 whitespace-pre-line break-words"
          phx-no-format
        >{@venue.description}</p>
        <p class="mt-1 text-token-xs text-tymeslot-500" data-testid="venue-usage">
          {usage_label(@usage)}
        </p>
      </div>

      <div class="flex shrink-0 gap-2">
        <.action_button
          variant={:secondary}
          phx-click="edit_venue"
          phx-value-id={@venue.id}
          phx-target={@myself}
          class="py-1! px-2! text-token-xs"
        >
          {dgettext("dashboard_meeting_types", "Edit")}
        </.action_button>
        <.action_button
          variant={:danger}
          phx-click="delete_venue"
          phx-value-id={@venue.id}
          phx-target={@myself}
          class="py-1! px-2! text-token-xs"
        >
          {dgettext("dashboard_meeting_types", "Delete")}
        </.action_button>
      </div>
    </div>
    """
  end

  defp usage_label(0), do: dgettext("dashboard_meeting_types", "Not used by any meeting type yet")

  defp usage_label(count) do
    dngettext(
      "dashboard_meeting_types",
      "Used by %{count} meeting type",
      "Used by %{count} meeting types",
      count
    )
  end
end
