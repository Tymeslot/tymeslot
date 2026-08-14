defmodule TymeslotWeb.Dashboard.CalendarGrid.Header.CalendarListPanel do
  @moduledoc """
  The "My Calendars" panel: one row per connected integration, and beneath it
  one row per calendar that integration syncs.

  The integration row keeps the coarse toggle, because hiding a whole account in
  one click stays the common case. The rows below it are the fine control, each
  with its own toggle and its own swatch picker.

  Only calendars marked `selected` in the integration's `calendar_list` appear.
  An unselected calendar is not synced at all, so it has no events to show,
  hide, or colour, and listing it would offer a control that does nothing.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.Components.Dashboard.ColourSwatches
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :calendar_colour_keys, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :hidden_calendar_keys, :any, required: true
  attr :myself, :any, required: true

  @spec calendar_list_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_list_panel(assigns) do
    ~H"""
    <h4 class="text-token-xs font-semibold text-tymeslot-500 uppercase tracking-wide mb-2">
      {dgettext("dashboard_calendar", "My Calendars")}
    </h4>

    <div :for={integration <- @integrations} class="mb-3 last:mb-0">
      <label class="flex items-center gap-2 py-1.5 cursor-pointer hover:bg-tymeslot-50 rounded-token-md px-1">
        <input
          type="checkbox"
          checked={integration.id not in @hidden_integration_ids}
          phx-click="toggle_integration_visibility"
          phx-value-integration-id={integration.id}
          phx-target={@myself}
          class="rounded"
        />
        <div
          class={"w-3 h-3 rounded-full shrink-0 #{Helpers.color_class_for_integration(@integration_colors, integration.id)}"}
          aria-hidden="true"
        >
        </div>
        <span class="text-token-sm font-semibold text-tymeslot-700 truncate">
          {DisplayHelpers.integration_label(integration)}
        </span>
      </label>

      <div
        :for={calendar <- synced_calendars(integration)}
        class="ml-4 border-l-2 border-tymeslot-50 pl-3"
      >
        <label class="flex items-center gap-2 py-1 cursor-pointer hover:bg-tymeslot-50 rounded-token-md px-1">
          <input
            type="checkbox"
            checked={not hidden?(@hidden_calendar_keys, integration.id, calendar.id)}
            phx-click="toggle_calendar_visibility"
            phx-value-integration-id={integration.id}
            phx-value-calendar-id={calendar.id}
            phx-target={@myself}
            class="rounded"
          />
          <span class="text-token-sm text-tymeslot-600 truncate">{calendar.name}</span>
        </label>
        <div class="pb-1.5 pl-6">
          <ColourSwatches.colour_swatches
            selected={colour_key(@calendar_colour_keys, integration.id, calendar.id)}
            event="set_calendar_colour"
            target={@myself}
            group_label={
              dgettext("dashboard_calendar", "Colour for %{calendar}", calendar: calendar.name)
            }
            values={
              %{
                "phx-value-integration_id" => integration.id,
                "phx-value-calendar_id" => calendar.id
              }
            }
          />
        </div>
      </div>
    </div>

    <p :if={@integrations == []} class="text-token-sm text-tymeslot-400">
      {dgettext("dashboard_calendar", "No calendars connected")}
    </p>
    """
  end

  # `calendar_list` is persisted as embedded entries, but a hand-written row or
  # an older record may still be a plain map, so normalise before reading.
  defp synced_calendars(integration) do
    integration.calendar_list
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Enum.filter(&(&1.selected and is_binary(&1.id)))
  end

  defp hidden?(hidden_keys, integration_id, calendar_id),
    do: MapSet.member?(hidden_keys, {integration_id, calendar_id})

  # Reads the stored palette key, not the resolved Tailwind class: the picker
  # marks a swatch pressed by comparing keys, and inverting a class back to its
  # key would be a second copy of the palette mapping to keep in step.
  defp colour_key(colour_keys, integration_id, calendar_id),
    do: Map.get(colour_keys, {integration_id, calendar_id})
end
