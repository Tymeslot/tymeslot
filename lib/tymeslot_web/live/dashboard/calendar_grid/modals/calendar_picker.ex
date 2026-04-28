defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.CalendarPicker do
  @moduledoc "Shared calendar picker component used by calendar grid modals."

  use TymeslotWeb, :html

  alias Tymeslot.Integrations.Calendar, as: CalendarIntegration
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :selected_integration_id, :integer, required: true
  attr :selected_calendar_id, :string, default: nil
  attr :myself, :any, required: true
  attr :event_name, :string, required: true

  @spec calendar_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_picker(assigns) do
    ~H"""
    <div class="space-y-3">
      <div :for={integration <- @integrations}>
        <% calendars = selected_calendars(integration) %>
        <% is_active_integration = integration.id == @selected_integration_id %>
        <%!-- Integration header --%>
        <div class="flex items-center gap-1.5 mb-1.5">
          <div class={"w-2 h-2 rounded-full flex-shrink-0 #{Helpers.color_dot(%{integration_colors: @integration_colors}, integration)}"}></div>
          <ProviderIcon.provider_icon provider={integration.provider} type="calendar" size="mini" />
          <span class="text-token-xs font-semibold text-tymeslot-500 uppercase tracking-wide truncate">
            <%= integration.name %>
          </span>
        </div>

        <%!-- Calendar buttons --%>
        <% fallback_id = default_calendar_id(calendars) %>
        <div :if={calendars != []} class="flex flex-wrap gap-1.5 pl-3.5">
          <% cal_id = fn cal -> cal["id"] || cal[:id] end %>
          <% cal_name = fn cal -> CalendarIntegration.extract_calendar_display_name(cal) end %>
          <% is_selected = fn cal -> is_active_integration and calendar_selected?(cal_id.(cal), @selected_calendar_id, fallback_id) end %>
          <button
            :for={cal <- calendars}
            type="button"
            phx-click={@event_name}
            phx-value-integration-id={integration.id}
            phx-value-calendar-id={cal_id.(cal)}
            phx-target={@myself}
            class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_selected.(cal), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
            title={cal_name.(cal)}
          >
            <div :if={cal["color"] || cal[:color]} class="w-2 h-2 rounded-full flex-shrink-0" style={"background-color: #{cal["color"] || cal[:color]}"}></div>
            <span class="truncate max-w-[10rem]"><%= cal_name.(cal) %></span>
            <span :if={cal["primary"] || cal[:primary]} class="text-token-xs font-bold bg-tymeslot-200 px-1 py-0.5 rounded text-tymeslot-500 uppercase">Primary</span>
          </button>
        </div>
        <%!-- Fallback: integration with no calendar list (single calendar) --%>
        <div :if={calendars == []} class="pl-3.5">
          <button
            type="button"
            phx-click={@event_name}
            phx-value-integration-id={integration.id}
            phx-target={@myself}
            class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_active_integration, do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
          >
            <span>Default calendar</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Derives which calendar ID within an integration an event belongs to.

  For Google: matches organizer email from provider_metadata against calendar list IDs.
  For CalDAV: matches the calendar path prefix in provider_event_id.
  Falls back to default_booking_calendar_id or first calendar.
  """
  @spec derive_event_calendar_id(map(), map() | nil) :: String.t() | nil
  def derive_event_calendar_id(_event, nil), do: nil

  def derive_event_calendar_id(event, integration) do
    calendars = integration.calendar_list || []

    derived =
      cond do
        is_map(event.provider_metadata) && is_map(event.provider_metadata["organizer"]) ->
          find_google_calendar_id(calendars, event.provider_metadata["organizer"]["email"])

        is_binary(event.provider_event_id) ->
          find_caldav_calendar_id(calendars, event.provider_event_id)

        true ->
          nil
      end

    derived || EditWorkflow.default_calendar_id_for(integration)
  end

  defp selected_calendars(integration) do
    Enum.filter(integration.calendar_list || [], fn cal ->
      (cal["selected"] || cal[:selected]) &&
        not (Map.get(cal, "read_only", false) || Map.get(cal, :read_only, false))
    end)
  end

  defp calendar_selected?(cal_id, selected_id, default_id) do
    if is_binary(selected_id), do: cal_id == selected_id, else: cal_id == default_id
  end

  defp default_calendar_id([]), do: nil

  defp default_calendar_id(calendars) do
    primary = Enum.find(calendars, &(&1["primary"] || &1[:primary]))
    cal = primary || List.first(calendars)
    cal["id"] || cal[:id]
  end

  defp find_google_calendar_id(calendars, organizer_email) do
    match = Enum.find(calendars, fn c -> (c["id"] || c[:id]) == organizer_email end)
    if match, do: match["id"] || match[:id]
  end

  defp find_caldav_calendar_id(calendars, provider_event_id) do
    match =
      Enum.find(calendars, fn c ->
        path = c["path"] || c[:path] || c["id"] || c[:id]
        is_binary(path) and String.starts_with?(provider_event_id, path)
      end)

    if match, do: match["id"] || match[:id]
  end
end
