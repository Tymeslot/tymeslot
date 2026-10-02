defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.VenuePicker do
  @moduledoc """
  The saved locations an in-person location offers, as the same pill picker
  the video providers use, plus the "+ New location" control that opens
  `NewVenueComponent` in the editor.

  With nothing ticked the location's address is arranged after booking,
  which the hint beneath says, so an empty picker reads as a decision rather
  than something the organiser forgot.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  import TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.ChoiceToggle,
    only: [choice_toggle: 1]

  attr :changeset, :any, required: true
  attr :venues, :list, required: true
  attr :field_errors, :map, required: true
  attr :myself, :any, required: true, doc: "the location editor, which owns the new-venue form"

  @spec venue_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def venue_picker(assigns) do
    assigns = assign(assigns, :selected, selected(assigns.changeset, assigns.venues))

    ~H"""
    <div class="space-y-2" data-testid="venue-picker">
      <%= if @venues == [] do %>
        <Forms.label>{dgettext("dashboard_meeting_form", "Locations")}</Forms.label>
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_meeting_form",
            "You have no saved locations yet. Add one here, or leave this empty to arrange the address after booking."
          )}
        </p>
      <% else %>
        <.choice_toggle
          id="location_venue_ids"
          name="location[venue_ids][]"
          value={@selected}
          label={dgettext("dashboard_meeting_form", "Locations")}
          options={venue_options(@venues)}
          multiple
          errors={FormValidationHelpers.field_errors(@field_errors, :venue_ids)}
        >
          <:description>
            {dgettext(
              "dashboard_meeting_form",
              "Pick one or more. With several, the booker chooses where to meet."
            )}
          </:description>
        </.choice_toggle>
      <% end %>

      <p :if={@selected == []} class="text-token-xs text-tymeslot-500" data-testid="venue-hint">
        {dgettext(
          "dashboard_meeting_form",
          "No address selected: bookers are told it will be arranged after booking."
        )}
      </p>

      <CoreComponents.action_button
        type="button"
        variant={:secondary}
        phx-click="toggle_new_venue"
        phx-target={@myself}
        data-testid="new-venue-toggle"
        size={:sm}
      >
        {dgettext("dashboard_meeting_form", "+ New location")}
      </CoreComponents.action_button>
    </div>
    """
  end

  # Only the ticked ids that are still saved venues: one deleted since the
  # location was saved has no pill, so it must not hide the hint either.
  defp selected(changeset, venues) do
    known = MapSet.new(venues, & &1.id)
    Enum.filter(Changeset.get_field(changeset, :venue_ids) || [], &MapSet.member?(known, &1))
  end

  # A pill shows the venue's name, with its address in the tooltip.
  defp venue_options(venues) do
    Enum.map(venues, fn venue ->
      %{value: venue.id, label: venue.name, icon: "hero-map-pin", title: venue.description}
    end)
  end
end
