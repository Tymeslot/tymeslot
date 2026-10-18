defmodule TymeslotWeb.Dashboard.Calendar.PanelNewForm do
  @moduledoc """
  The side panel's "New event" form: the draft's fields in one form whose
  changes update the draft (`panel:draft_change`) and whose submit either
  adds a guest or creates the event (`panel:draft_submit`, by `intent`).
  The Create button names what it will do: "Create and invite" when the
  draft has guests, who are emailed once it is created.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Calendar.PanelCalendarField
  alias TymeslotWeb.Dashboard.Calendar.PanelGuestsField
  alias TymeslotWeb.Dashboard.Calendar.PanelVideoField

  attr :values, :map, required: true, doc: "the typed values (`panel.form`)"
  attr :saving, :boolean, required: true
  attr :calendar_choices, :list, required: true
  attr :video_integrations, :list, required: true
  attr :guest_form_key, :integer, required: true
  attr :surface, :any, required: true

  @spec new_form(map()) :: Phoenix.LiveView.Rendered.t()
  def new_form(assigns) do
    assigns = assign(assigns, :shown_end, shown_end(assigns.values))

    ~H"""
    <form
      id="calendar-panel-new-form"
      class="space-y-4"
      phx-change="panel:draft_change"
      phx-submit="panel:draft_submit"
      phx-target={@surface}
    >
      <.input
        id="calendar-panel-new-title"
        name="title"
        value={@values["title"]}
        label={dgettext("dashboard_calendar_editing", "Title")}
        placeholder={dgettext("dashboard_calendar_editing", "New event")}
        data-panel-focus="true"
      />
      <.input
        type="checkbox"
        id="calendar-panel-new-all-day"
        name="all_day"
        value={@values["all_day"]}
        label={dgettext("dashboard_calendar_editing", "All day")}
      />
      <div class="grid grid-cols-2 gap-2">
        <.input
          type={if @values["all_day"], do: "date", else: "datetime-local"}
          id="calendar-panel-new-start"
          name="start"
          value={@values["start"]}
          label={dgettext("dashboard_calendar_editing", "Starts")}
        />
        <.input
          type={if @values["all_day"], do: "date", else: "datetime-local"}
          id="calendar-panel-new-end"
          name="end"
          value={@shown_end}
          label={dgettext("dashboard_calendar_editing", "Ends")}
        />
      </div>
      <PanelCalendarField.calendar_field choices={@calendar_choices} value={@values["calendar"]} />
      <div>
        <.input
          type="select"
          id="calendar-panel-new-free"
          name="free"
          label={dgettext("dashboard_calendar_editing", "Show as")}
          value={to_string(@values["free"])}
          options={[
            {dgettext("dashboard_calendar_editing", "Busy"), "false"},
            {dgettext("dashboard_calendar_editing", "Free"), "true"}
          ]}
        />
        <p class="mt-1 text-token-xs text-tymeslot-500">
          {if @values["free"],
            do: dgettext("dashboard_calendar_editing", "Guests can book this time"),
            else: dgettext("dashboard_calendar_editing", "Guests can't book this time")}
        </p>
      </div>
      <.input
        id="calendar-panel-new-location"
        name="location"
        value={@values["location"]}
        label={dgettext("dashboard_calendar_editing", "Place")}
      />
      <PanelVideoField.video_choice
        video_integrations={@video_integrations}
        value={@values["video_integration_id"]}
      />
      <PanelGuestsField.draft_guests
        guests={@values["guests"]}
        form_key={@guest_form_key}
        surface={@surface}
      />
      <.input
        type="textarea"
        id="calendar-panel-new-description"
        name="description"
        value={@values["description"]}
        label={dgettext("dashboard_calendar_editing", "Notes")}
      />
      <div class="flex justify-end gap-2 border-t border-tymeslot-100 pt-3">
        <.action_button
          id="calendar-panel-new-cancel"
          type="button"
          variant={:secondary}
          phx-click="panel:draft_cancel"
          phx-target={@surface}
        >
          {dgettext("dashboard_calendar_editing", "Cancel")}
        </.action_button>
        <.action_button
          id="calendar-panel-create"
          type="submit"
          name="intent"
          value="create"
          variant={:primary}
          disabled={@saving}
        >
          {if @values["guests"] == [],
            do: dgettext("dashboard_calendar_editing", "Create"),
            else: dgettext("dashboard_calendar_editing", "Create and invite")}
        </.action_button>
      </div>
    </form>
    """
  end

  # The all-day form shows the last day; the draft holds the exclusive end.
  defp shown_end(%{"all_day" => true, "end" => last}) when is_binary(last) do
    case Date.from_iso8601(last) do
      {:ok, date} -> date |> Date.add(-1) |> Date.to_iso8601()
      _invalid -> last
    end
  end

  defp shown_end(values), do: values["end"]
end
