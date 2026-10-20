defmodule TymeslotWeb.Dashboard.Calendar.SeriesScopeModal do
  @moduledoc """
  Asks which events of a repeating series a change applies to. A timing
  change offers this event, this and the following events, or all events;
  a delete offers this event or all events, the two scopes a delete takes
  (`Tymeslot.CalendarGrid.EventDeletion`). Each choice is sent as the
  `scope` of `calendar:choose_scope`; Cancel, Escape and a click outside
  send `calendar:cancel_scope`.

  The side panel asks the timing question once for all of its changes
  (`:panel`), with a question that says the answer holds until the details
  are closed. A change of the repeat rule offers only this and the following
  events or all events (`:panel_repeat`), the scopes a rule change takes.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  attr :prompt, :map, required: true, doc: "`%{kind: :timing | :delete, title: title}`"
  attr :target, :any, required: true

  @spec series_scope_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def series_scope_modal(assigns) do
    assigns = assign(assigns, :choices, choices(assigns.prompt.kind))

    ~H"""
    <Modal.confirm_modal
      id="calendar-series-scope"
      show
      size={:small}
      icon="hero-arrow-path"
      confirm_variant={if @prompt.kind == :delete, do: :danger, else: :primary}
      title={title(@prompt.kind)}
      on_cancel={JS.push("calendar:cancel_scope", target: @target)}
    >
      <p>{question(@prompt)}</p>
      <p :if={@prompt.kind == :timing} id="calendar-scope-undo-note" class="text-tymeslot-500">
        {dgettext("dashboard_calendar_recurrence", "Only “This event” can be undone.")}
      </p>
      <:actions>
        <.action_button
          :for={{scope, label} <- @choices}
          id={"calendar-scope-#{scope}"}
          variant={if @prompt.kind == :delete, do: :danger, else: :secondary}
          phx-click="calendar:choose_scope"
          phx-value-scope={scope}
          phx-target={@target}
        >
          {label}
        </.action_button>
      </:actions>
    </Modal.confirm_modal>
    """
  end

  defp choices(kind) when kind in [:timing, :panel],
    do: [
      {"this_only", dgettext("dashboard_calendar_recurrence", "This event")},
      {"following", dgettext("dashboard_calendar_recurrence", "This and following events")},
      {"all", dgettext("dashboard_calendar_recurrence", "All events")}
    ]

  defp choices(:delete),
    do: [
      {"occurrence", dgettext("dashboard_calendar_recurrence", "This event")},
      {"series", dgettext("dashboard_calendar_recurrence", "All events")}
    ]

  defp choices(:panel_repeat),
    do: [
      {"following", dgettext("dashboard_calendar_recurrence", "This and following events")},
      {"all", dgettext("dashboard_calendar_recurrence", "All events")}
    ]

  defp title(kind) when kind in [:timing, :panel, :panel_repeat],
    do: dgettext("dashboard_calendar_recurrence", "Change a repeating event")

  defp title(:delete), do: dgettext("dashboard_calendar_recurrence", "Delete a repeating event")

  defp question(%{kind: :panel, title: title}),
    do:
      dgettext(
        "dashboard_calendar_recurrence",
        "“%{title}” repeats. Which events should your changes apply to? Your answer holds until you close the details.",
        title: title
      )

  defp question(%{kind: :panel_repeat, title: title}),
    do:
      dgettext(
        "dashboard_calendar_recurrence",
        "“%{title}” repeats. Should the new pattern apply to this and the following events, or to all of them?",
        title: title
      )

  defp question(%{kind: :timing, title: title}),
    do:
      dgettext("dashboard_calendar_recurrence", "“%{title}” repeats. Which events should change?",
        title: title
      )

  defp question(%{kind: :delete, title: title}),
    do:
      dgettext(
        "dashboard_calendar_recurrence",
        "“%{title}” repeats. Which events should be deleted?",
        title: title
      )
end
