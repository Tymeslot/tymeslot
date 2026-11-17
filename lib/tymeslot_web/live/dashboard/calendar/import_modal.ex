defmodule TymeslotWeb.Dashboard.Calendar.ImportModal do
  @moduledoc """
  The calendar's import modal, one view per stage of `IcsImport`:
  choose a file, read it, pick a calendar, follow the import, read the
  result, and the surface's drop zone (the upload form and overlay). Its
  strings are in `dashboard_calendar_import`, with `IcsImportFlow`'s.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Calendar.PanelCalendarField

  @choosing [:choose, :reading, :ready]
  @result_variants %{info: :success, warning: :warning, error: :error}

  attr :ics_import, :map, required: true
  attr :uploads, :map, required: true
  attr :choices, :list, required: true, doc: "from `CalendarDirectory.choices/1`"
  attr :target, :any, required: true

  @spec import_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def import_modal(assigns) do
    assigns =
      assign(assigns,
        upload: assigns.uploads.ics_file,
        choosing: assigns.ics_import.stage in @choosing,
        close: JS.push("calendar:ics_close", target: assigns.target)
      )

    ~H"""
    <.modal id="calendar-import" show size={:medium} on_cancel={@close}>
      <:header>{dgettext("dashboard_calendar_import", "Import events")}</:header>
      <:subtitle>
        {dgettext(
          "dashboard_calendar_import",
          "Copy the events of an .ics file into one of your calendars."
        )}
      </:subtitle>

      <div class="space-y-4">
        <.info_box :if={@choices == []} variant={:info}>
          {dgettext(
            "dashboard_calendar_import",
            "Connect a calendar Tymeslot can write to before importing events."
          )}
        </.info_box>

        <div
          :if={@choices != [] and @ics_import.stage == :running}
          class="space-y-2"
          role="status"
          data-testid="calendar-import-progress"
        >
          <div class="flex items-center gap-2 text-token-sm text-tymeslot-700">
            <.spinner />
            <span>
              {dgettext("dashboard_calendar_import", "Importing %{done} of %{total} events...",
                done: @ics_import.done,
                total: @ics_import.total
              )}
            </span>
          </div>
          <p class="text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_import",
              "You can close this window; the import carries on."
            )}
          </p>
          <.info_box :if={@ics_import.error} variant={:error}>
            <span data-testid="calendar-import-error">{@ics_import.error}</span>
          </.info_box>
        </div>

        <div :if={@ics_import.stage == :done} id="calendar-import-result" role="status">
          <.info_box variant={result_variant(@ics_import.result)}>
            {elem(@ics_import.result, 1)}
          </.info_box>
        </div>

        <div :if={@choices != [] and @choosing} id="calendar-import-panel" class="space-y-4">
          <%!-- The file input is the surface's (`IcsImport.drop_zone/1`), so a
                file dropped anywhere on the calendar lands in the same upload.
                This button opens it with a non-bubbling click; a label for it
                would forward a click from outside the modal, which closes it. --%>
          <button
            type="button"
            id="calendar-import-choose"
            phx-click={JS.dispatch("click", to: "##{@upload.ref}")}
            class="flex min-h-11 w-full cursor-pointer flex-col items-center justify-center gap-2 rounded-token-lg border-2 border-dashed border-tymeslot-200 px-4 py-6 transition-colors hover:border-turquoise-300 hover:bg-tymeslot-50 focus:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-500 motion-reduce:transition-none"
          >
            <.icon name="hero-arrow-up-tray" class="h-6 w-6 text-tymeslot-400" />
            <span class="text-token-sm font-semibold text-tymeslot-700">
              {@ics_import.file_name ||
                dgettext("dashboard_calendar_import", "Choose or drop an .ics file")}
            </span>
            <span class="text-token-xs text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_import",
                "Exported from Google Calendar, Outlook, Apple Calendar or any other calendar app."
              )}
            </span>
          </button>

          <div
            :if={@ics_import.stage == :reading or @upload.entries != []}
            class="flex items-center gap-2 text-token-sm text-tymeslot-600"
            role="status"
          >
            <.spinner />
            <span>{dgettext("dashboard_calendar_import", "Reading the file...")}</span>
          </div>

          <.info_box :if={@ics_import.error} variant={:error}>
            <span data-testid="calendar-import-error">{@ics_import.error}</span>
          </.info_box>

          <div :if={@ics_import.summary} data-testid="calendar-import-summary">
            <p class="text-token-sm text-tymeslot-700">
              {dngettext(
                "dashboard_calendar_import",
                "Found 1 event.",
                "Found %{count} events.",
                @ics_import.summary.events
              )}
              <span :if={@ics_import.summary.series > 0}>
                {dngettext(
                  "dashboard_calendar_import",
                  "1 of them repeats.",
                  "%{count} of them repeat.",
                  @ics_import.summary.series
                )}
              </span>
            </p>
            <p class="mt-1 text-token-xs text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_import",
                "Guests are not imported, and nobody is sent an invitation."
              )}
            </p>
          </div>

          <form
            :if={@ics_import.stage == :ready}
            novalidate
            id="calendar-import-calendar"
            phx-change="calendar:ics_calendar"
            phx-target={@target}
          >
            <.select
              id="calendar-import-calendar-select"
              name="calendar"
              label={dgettext("dashboard_calendar_import", "Import into")}
              value={@ics_import.calendar_key}
              options={PanelCalendarField.options(@choices)}
            />
          </form>
        </div>
      </div>

      <:footer>
        <div class="flex gap-2">
          <.action_button
            :if={@choices != [] and @choosing}
            id="calendar-import-start"
            variant={:primary}
            disabled={@ics_import.stage != :ready}
            phx-click="calendar:ics_start"
            phx-target={@target}
          >
            {dgettext("dashboard_calendar_import", "Import")}
          </.action_button>
          <.action_button id="calendar-import-close" variant={:secondary} phx-click={@close}>
            {if @choosing,
              do: dgettext("dashboard_calendar_import", "Cancel"),
              else: dgettext("dashboard_calendar_import", "Close")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  attr :uploads, :map, required: true
  attr :target, :any, required: true

  @doc """
  The hidden upload form and the drop overlay, the surface root's first
  children. The root carries `phx-drop-target`, so LiveView marks it
  `phx-drop-target-active` while a file is over it and the overlay shows.
  """
  @spec drop_zone(map()) :: Phoenix.LiveView.Rendered.t()
  def drop_zone(assigns) do
    ~H"""
    <form id="calendar-ics-upload" phx-change="calendar:ics_validate" phx-target={@target} novalidate>
      <%!-- The import dialog's picker button is the control keyboard and
            screen reader users meet, so the input is out of the tab order and
            the accessibility tree. It stays rendered (no `hidden`), or neither
            the drop target nor the button's `click()` reaches it. --%>
      <.live_file_input
        upload={@uploads.ics_file}
        class="sr-only"
        tabindex="-1"
        aria-hidden="true"
      />
    </form>
    <div
      id="calendar-drop-overlay"
      class="pointer-events-none absolute inset-0 hidden flex-col items-center justify-center gap-2 rounded-token-lg border-2 border-dashed border-turquoise-400 bg-turquoise-50/90 phx-drop-target-active:flex"
      aria-hidden="true"
    >
      <.icon name="hero-arrow-down-tray" class="h-8 w-8 text-turquoise-600" />
      <p class="text-token-base font-semibold text-turquoise-800">
        {dgettext("dashboard_calendar", "Drop an .ics file to import its events")}
      </p>
    </div>
    """
  end

  defp result_variant({kind, _message}), do: Map.fetch!(@result_variants, kind)
end
