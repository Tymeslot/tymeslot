defmodule TymeslotWeb.Dashboard.Calendar.SeriesScopeModal do
  @moduledoc """
  Asks which events of a repeating series a change applies to. A timing
  change offers this event, this and the following events, or all events;
  a delete offers this event or all events, the two scopes a delete takes
  (`Tymeslot.CalendarGrid.EventDeletion`). Each choice is sent as the
  `scope` of `calendar:choose_scope`; Cancel, Escape and a click outside
  send `calendar:cancel_scope`.
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
        {dgettext("dashboard_calendar", "Only “This event” can be undone.")}
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

  defp choices(:timing),
    do: [
      {"this_only", dgettext("dashboard_calendar", "This event")},
      {"following", dgettext("dashboard_calendar", "This and following events")},
      {"all", dgettext("dashboard_calendar", "All events")}
    ]

  defp choices(:delete),
    do: [
      {"occurrence", dgettext("dashboard_calendar", "This event")},
      {"series", dgettext("dashboard_calendar", "All events")}
    ]

  defp title(:timing), do: dgettext("dashboard_calendar", "Change a repeating event")
  defp title(:delete), do: dgettext("dashboard_calendar", "Delete a repeating event")

  defp question(%{kind: :timing, title: title}),
    do:
      dgettext("dashboard_calendar", "“%{title}” repeats. Which events should change?",
        title: title
      )

  defp question(%{kind: :delete, title: title}),
    do:
      dgettext("dashboard_calendar", "“%{title}” repeats. Which events should be deleted?",
        title: title
      )
end
