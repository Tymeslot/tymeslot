defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ImportIcsModal do
  @moduledoc """
  Modal for importing an `.ics` file into one of the user's calendars. See
  `TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.IcsImport` for the flow.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Calendar
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CalendarPicker

  attr :ics_import, :map, required: true
  attr :upload, :any, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :myself, :any, required: true

  @spec import_ics_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def import_ics_modal(assigns) do
    assigns =
      assigns
      |> assign(:targets, Calendar.writable_integrations(assigns.integrations))
      |> assign(:running, assigns.ics_import.stage == :running)

    ~H"""
    <.modal
      id="import-ics-modal"
      show={true}
      on_cancel={JS.push("close_ics_import", target: @myself)}
      size={:medium}
    >
      <:header>{dgettext("dashboard_calendar_events", "Import events")}</:header>
      <:subtitle>
        {dgettext(
          "dashboard_calendar_events",
          "Copy the events of an .ics file into one of your calendars."
        )}
      </:subtitle>

      <div data-testid="import-ics-modal" class="space-y-4">
        <.info_box :if={@targets == []} variant={:info}>
          {dgettext(
            "dashboard_calendar_events",
            "Connect a calendar Tymeslot can write to before importing events."
          )}
        </.info_box>

        <div
          :if={@targets != [] and @running}
          class="space-y-2"
          role="status"
          data-testid="import-ics-progress"
        >
          <div class="flex items-center gap-2 text-token-sm text-tymeslot-700">
            <.spinner />
            <span>
              {dgettext("dashboard_calendar_events", "Importing %{done} of %{total} events...",
                done: @ics_import.done,
                total: length(@ics_import.plan.events)
              )}
            </span>
          </div>
          <p class="text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_events",
              "You can close this window; the import carries on."
            )}
          </p>
        </div>

        <div :if={@targets != [] and not @running} id="import-ics-panel" class="space-y-4">
          <%!-- The file input itself is the calendar grid's, so a file dropped
                anywhere on the calendar lands in the same upload. This button
                opens it with a non-bubbling click (LiveView's own handling of
                a dispatched click on a file input): a label for it would
                forward a click from outside the modal, which closes it. --%>
          <button
            type="button"
            id="import-ics-choose"
            phx-click={JS.dispatch("click", to: "##{@upload.ref}")}
            class="w-full flex flex-col items-center justify-center gap-2 px-4 py-6 border-2 border-dashed border-tymeslot-200 rounded-token-lg cursor-pointer hover:border-turquoise-300 hover:bg-tymeslot-50 focus:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-500 transition-colors"
          >
            <.icon name="hero-arrow-up-tray" class="w-6 h-6 text-tymeslot-400" />
            <span class="text-token-sm font-semibold text-tymeslot-700">
              {if @ics_import.file_name,
                do: @ics_import.file_name,
                else: dgettext("dashboard_calendar_events", "Choose or drop an .ics file")}
            </span>
            <span class="text-token-xs text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_events",
                "Exported from Google Calendar, Outlook, Apple Calendar or any other calendar app."
              )}
            </span>
          </button>

          <div
            :if={@upload.entries != [] or @ics_import.reading}
            class="flex items-center gap-2 text-token-sm text-tymeslot-600"
            role="status"
          >
            <.spinner />
            <span>{dgettext("dashboard_calendar_events", "Reading the file...")}</span>
          </div>

          <.info_box :if={@ics_import.error} variant={:error}>
            <span data-testid="import-ics-error">{@ics_import.error}</span>
          </.info_box>

          <div :if={@ics_import.plan} data-testid="import-ics-summary">
            <p class="text-token-sm text-tymeslot-700">
              {dngettext(
                "dashboard_calendar_events",
                "Found 1 event.",
                "Found %{count} events.",
                length(@ics_import.plan.events)
              )}
              <span :if={@ics_import.plan.series > 0}>
                {dngettext(
                  "dashboard_calendar_events",
                  "1 of them repeats.",
                  "%{count} of them repeat.",
                  @ics_import.plan.series
                )}
              </span>
            </p>
            <p class="mt-1 text-token-xs text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_events",
                "Guests are not imported, and nobody is sent an invitation."
              )}
            </p>
          </div>

          <div :if={@ics_import.plan}>
            <p class="mb-2 text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar_events", "Import into")}
            </p>
            <CalendarPicker.calendar_picker
              integrations={@integrations}
              integration_colors={@integration_colors}
              selected_integration_id={@ics_import.integration_id}
              selected_calendar_id={@ics_import.calendar_id}
              myself={@myself}
              event_name="select_ics_import_calendar"
            />
          </div>
        </div>
      </div>

      <:footer>
        <div class="flex gap-2">
          <.action_button
            :if={@targets != [] and not @running}
            variant={:primary}
            disabled={is_nil(@ics_import.plan)}
            phx-click="start_ics_import"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_events", "Import")}
          </.action_button>
          <.action_button
            variant={:secondary}
            phx-click={JS.push("close_ics_import", target: @myself)}
          >
            {if @running,
              do: dgettext("dashboard_calendar_events", "Close"),
              else: dgettext("dashboard_calendar_events", "Cancel")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
