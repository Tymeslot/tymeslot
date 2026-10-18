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

  @spec calendar_field(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_field(assigns) do
    assigns = assign(assigns, :options, options(assigns.choices))

    ~H"""
    <.input
      type="select"
      id="calendar-panel-calendar"
      name="calendar"
      label={dgettext("dashboard_calendar", "Calendar")}
      value={@value}
      options={@options}
      disabled={@disabled}
    />
    """
  end

  @doc """
  The choices as `<.input type="select">` option groups,
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
