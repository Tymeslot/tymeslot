defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal do
  @moduledoc """
  Asks which occurrences of a repeating event an edit applies to: this
  event, this and every following one, or all of them.

  Each button sends its `Tymeslot.CalendarGrid.RecurrenceScope` as the
  `scope` value of `confirm_recurrence_scope`. The prompt is shown only for
  a member of a series whose provider writes each scope (Google, Outlook and
  the CalDAV family; see `EditWorkflow.series_edit?/1`), so every button it
  offers is one the domain can honour.

  A change of repeat rule belongs to the series, not to one of its
  occurrences, so its prompt leaves out "This event" (see
  `offered_scopes/1`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.RecurrenceScope

  attr :recurrence_prompt, :map, required: true
  attr :myself, :any, required: true

  @spec recurrence_prompt_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def recurrence_prompt_modal(assigns) do
    assigns = assign(assigns, :scopes, offered_scopes(assigns.recurrence_prompt))

    ~H"""
    <.modal
      id="recurrence-prompt-modal"
      show={true}
      on_cancel={JS.push("cancel_recurrence_prompt", target: @myself)}
      size={:small}
    >
      <:header>{dgettext("dashboard_calendar_events", "Edit recurring event")}</:header>

      <p class="text-token-sm text-tymeslot-500 mb-4">
        {dgettext(
          "dashboard_calendar_events",
          "This event is part of a repeating series. Which events should your change apply to?"
        )}
      </p>

      <ul class="space-y-2 text-token-sm text-tymeslot-600">
        <li :for={scope <- @scopes}>
          <span class="font-semibold text-tymeslot-800">{scope_label(scope)}:</span>
          {scope_description(scope)}
        </li>
      </ul>

      <:footer>
        <div class="flex flex-wrap gap-2">
          <.action_button
            :for={scope <- @scopes}
            phx-click="confirm_recurrence_scope"
            phx-value-scope={scope}
            phx-target={@myself}
          >
            {scope_label(scope)}
          </.action_button>
          <.action_button
            variant={:secondary}
            phx-click={JS.push("cancel_recurrence_prompt", target: @myself)}
          >
            {dgettext("dashboard_calendar_events", "Cancel")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  @doc """
  The scopes `prompt` offers, in the order the buttons show them. A change of
  repeat rule is not offered for this event alone, which cannot take a rule
  of its own.
  """
  @spec offered_scopes(map()) :: [RecurrenceScope.t()]
  def offered_scopes(%{kind: :recurrence_rule}), do: RecurrenceScope.values() -- [:this_only]
  def offered_scopes(_prompt), do: RecurrenceScope.values()

  defp scope_label(:this_only), do: dgettext("dashboard_calendar_events", "This event")

  defp scope_label(:following),
    do: dgettext("dashboard_calendar_events", "This and following events")

  defp scope_label(:all), do: dgettext("dashboard_calendar_events", "All events")

  defp scope_description(:this_only),
    do:
      dgettext(
        "dashboard_calendar_events",
        "only this occurrence changes, and the rest of the series stays as it is."
      )

  defp scope_description(:following),
    do:
      dgettext(
        "dashboard_calendar_events",
        "this occurrence and every later one change, and the earlier ones stay as they are."
      )

  defp scope_description(:all),
    do:
      dgettext(
        "dashboard_calendar_events",
        "every occurrence in the series changes, earlier ones included."
      )
end
