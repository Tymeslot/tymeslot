defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CalendarSelectionModal do
  @moduledoc """
  Modal for managing one connected calendar integration: what it is called,
  what colour its events are shown in, and which of its calendars are used for
  conflict checking.

  Hosts the calendar-selection chip grid that previously lived behind the
  connection row's expand chevron. Surfacing it as an explicit "Manage
  calendars" action keeps the row itself flat.

  Stateless — `show` and the selected integration are owned by the parent
  `CalendarSettingsComponent`. Each control dispatches its event back to
  `@target` (`rename_integration`, `set_integration_colour`,
  `toggle_calendar_selection`); the parent reloads and re-renders this modal
  with the updated integration.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.Components.Dashboard.ColourSwatches

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :integration, :map, default: nil, doc: "the integration being managed, or nil when closed"
  attr :target, :any, required: true
  attr :on_cancel, JS, default: %JS{}

  @spec calendar_selection_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_selection_modal(assigns) do
    calendar_list = (assigns.integration && assigns.integration.calendar_list) || []

    assigns =
      assigns
      |> assign(:calendar_list, calendar_list)
      |> assign(:total_count, length(calendar_list))
      |> assign(:selected_count, Enum.count(calendar_list, & &1.selected))

    ~H"""
    <div id={@id}>
      <TymeslotWeb.Components.CoreComponents.modal
        id={"#{@id}-modal"}
        show={@show}
        on_cancel={@on_cancel}
        size={:medium}
      >
        <%!-- The modal wraps this slot in its own heading, so it takes the
             title text alone: a nested heading is invalid, and the subtitle
             would otherwise land inside the dialog's accessible name. --%>
        <:header>{dgettext("dashboard_calendar_providers", "Manage calendars")}</:header>

        <div :if={@integration}>
          <form
            id={"#{@id}-rename"}
            phx-submit="rename_integration"
            phx-target={@target}
            class="mb-6 flex items-end gap-2"
          >
            <input type="hidden" name="integration_id" value={@integration.id} />
            <div class="flex-1">
              <label for={"#{@id}-name"} class="label mb-1.5 block">
                {dgettext("dashboard_calendar_providers", "Name")}
              </label>
              <input
                id={"#{@id}-name"}
                type="text"
                name="name"
                value={@integration.name}
                required
                maxlength="100"
                autocomplete="off"
                class="input"
              />
            </div>
            <TymeslotWeb.Components.CoreComponents.action_button type="submit" variant={:secondary}>
              {dgettext("dashboard_calendar_providers", "Rename")}
            </TymeslotWeb.Components.CoreComponents.action_button>
          </form>

          <div class="mb-6">
            <p class="label mb-1.5 block">
              {dgettext("dashboard_calendar_providers", "Colour")}
            </p>
            <p class="mb-2 text-token-sm text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_providers",
                "How this calendar's events are shown in your Tymeslot calendar."
              )}
            </p>
            <ColourSwatches.colour_swatches
              selected={@integration.colour}
              event="set_integration_colour"
              target={@target}
              group_label={dgettext("dashboard_calendar_providers", "Colour")}
              values={%{"phx-value-integration_id" => @integration.id}}
            />
          </div>

          <p class="mb-4 text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_providers",
              "Choose which calendars we check to prevent double bookings."
            )}
          </p>

          <div class="mb-3 flex items-center gap-2">
            <span class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400">
              {dngettext(
                "dashboard_calendar_providers",
                "Syncing %{selected} of %{count} calendar",
                "Syncing %{selected} of %{count} calendars",
                @total_count,
                selected: @selected_count,
                count: @total_count
              )}
            </span>
            <div class="h-px flex-1 bg-tymeslot-100"></div>
          </div>

          <div class="flex flex-wrap gap-2.5">
            <button
              :for={calendar <- @calendar_list}
              phx-click="toggle_calendar_selection"
              phx-value-integration_id={@integration.id}
              phx-value-calendar_id={calendar.id}
              phx-target={@target}
              aria-pressed={to_string(calendar.selected)}
              class={[
                "inline-flex items-center gap-2.5 rounded-token-xl border-2 px-3.5 py-2 text-token-xs font-bold transition-all",
                (calendar.selected &&
                   "border-turquoise-400 bg-turquoise-50 text-turquoise-900 shadow-sm shadow-turquoise-500/5") ||
                  "border-tymeslot-50 bg-white text-tymeslot-400 hover:border-tymeslot-200 hover:bg-tymeslot-50"
              ]}
            >
              <div
                :if={calendar.color && calendar.selected}
                class="h-2.5 w-2.5 rounded-token-full ring-2 ring-white"
                style={"background-color: #{calendar.color}"}
              />
              <span>{DisplayHelpers.extract_calendar_display_name(calendar)}</span>
              <span
                :if={calendar.primary}
                class="rounded-token-sm bg-tymeslot-200 px-1.5 py-0.5 text-token-2xs font-black uppercase tracking-tighter text-tymeslot-600"
              >
                {dgettext("dashboard_calendar_providers", "Primary")}
              </span>
              <.icon
                :if={calendar.selected}
                name="hero-check"
                class="h-3.5 w-3.5 text-turquoise-600"
              />
            </button>

            <div :if={@calendar_list == []} class="flex items-center gap-2 py-2 text-tymeslot-400">
              <.icon name="hero-information-circle" class="h-4 w-4" />
              <span class="text-token-xs font-medium italic">
                {dgettext("dashboard_calendar_providers", "No calendars found. Try refreshing the integration.")}
              </span>
            </div>
          </div>
        </div>

        <:footer>
          <div class="flex justify-end">
            <TymeslotWeb.Components.CoreComponents.action_button
              variant={:secondary}
              phx-click={@on_cancel}
            >
              {dgettext("dashboard_calendar_providers", "Done")}
            </TymeslotWeb.Components.CoreComponents.action_button>
          </div>
        </:footer>
      </TymeslotWeb.Components.CoreComponents.modal>
    </div>
    """
  end
end
