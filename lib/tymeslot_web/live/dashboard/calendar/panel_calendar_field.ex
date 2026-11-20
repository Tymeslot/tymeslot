defmodule TymeslotWeb.Dashboard.Calendar.PanelCalendarField do
  @moduledoc """
  The side panel's Calendar select: the organiser's writable calendars,
  grouped by account, hidden calendars included (hiding a calendar only
  hides its events), from the flat list
  `Tymeslot.CalendarGrid.CalendarDirectory.choices/1` gives (the one the hook
  gets as `settings.calendars`). Rendered bare so the panel can put it in
  the form of either mode: in the edit mode its change moves the event
  (`panel:transfer`), in the new-event mode it is one field of the draft.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :choices, :list,
    required: true,
    doc: "`[%{key, name, account, colour}]`, from `CalendarDirectory.choices/1`"

  attr :value, :string, default: nil, doc: "the chosen calendar's key"
  attr :disabled, :boolean, default: false

  attr :version, :integer,
    default: 0,
    doc: "a new version draws the select again, with the server's value"

  @spec calendar_field(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_field(assigns) do
    assigns = assign(assigns, :options, options(assigns.choices))

    ~H"""
    <div id={"calendar-panel-calendar-field-#{@version}"}>
      <.select
        id="calendar-panel-calendar"
        name="calendar"
        label={dgettext("dashboard_calendar_editing", "Calendar")}
        value={@value}
        options={@options}
        prompt={
          if is_nil(@value), do: dgettext("dashboard_calendar_editing", "Not on a listed calendar")
        }
        disabled={@disabled}
      />
    </div>
    """
  end

  attr :meeting, :boolean, required: true, doc: "whether the draft is a Tymeslot meeting"
  attr :has_accounts, :boolean, default: false, doc: "whether any account is connected"

  @doc """
  The New event state's Calendar field when the organiser has no calendar
  to write to: a Tymeslot meeting is kept in Tymeslot alone, and an event
  cannot be made, which the note says.
  """
  @spec no_calendar(map()) :: Phoenix.LiveView.Rendered.t()
  def no_calendar(assigns) do
    ~H"""
    <div id="calendar-panel-no-calendar">
      <%!-- Styled as the form's other field labels, though no control follows. --%>
      <p id="calendar-panel-no-calendar-label" class="label mb-0">
        {dgettext("dashboard_calendar_editing", "Calendar")}
      </p>
      <p :if={@meeting} id="calendar-panel-calendar-none" class="mt-1 text-token-sm text-tymeslot-600">
        {dgettext("dashboard_calendar_editing", "None (Tymeslot only)")}
      </p>
      <p
        :if={!@meeting}
        id="calendar-panel-calendar-note"
        role="note"
        class="mt-1 text-token-xs text-tymeslot-500"
      >
        {if @has_accounts,
          do:
            dgettext(
              "dashboard_calendar_booking",
              "Your connected calendars are read-only, so events can't be added here."
            ),
          else: dgettext("dashboard_calendar_booking", "Connect a calendar to add events here.")}
      </p>
    </div>
    """
  end

  @doc """
  The choices as `<.select>` option groups,
  `[{account name, [{calendar name, key}]}]`, keeping the rail's order
  (`choices/1` lists each account's calendars together).
  """
  @spec options([map()]) :: [{String.t(), [{String.t(), String.t()}]}]
  def options(choices) do
    choices
    |> Enum.chunk_by(& &1.account)
    |> Enum.map(fn [%{account: account} | _rest] = calendars ->
      {account, Enum.map(calendars, &{&1.name, &1.key})}
    end)
  end
end
