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

  For a change of repeat rule the prompt shows, under each scope, the
  pattern that scope writes (`:scope_rules`, built by `RecurrenceEdit`),
  and why a calendar refuses one, in place of its button.

  The prompt's `:following_notes`, when it has any, say under "This and
  following events" what that choice will not carry
  (`Tymeslot.CalendarGrid.SeriesEdit.following_notes/2`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.RecurrenceEdit
  alias TymeslotWeb.Dashboard.CalendarGrid.SeriesNotes

  attr :recurrence_prompt, :map, required: true
  attr :myself, :any, required: true

  @spec recurrence_prompt_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def recurrence_prompt_modal(assigns) do
    prompt = assigns.recurrence_prompt

    assigns =
      assign(assigns,
        scopes: offered_scopes(prompt),
        listed: listed_scopes(prompt),
        following_notes: Map.get(prompt, :following_notes, [])
      )

    ~H"""
    <.modal
      id="recurrence-prompt-modal"
      show={true}
      on_cancel={JS.push("cancel_recurrence_prompt", target: @myself)}
      size={:small}
    >
      <:header>{dgettext("dashboard_calendar_recurrence", "Edit recurring event")}</:header>

      <p class="text-token-sm text-tymeslot-500 mb-4">
        {dgettext(
          "dashboard_calendar_recurrence",
          "This event is part of a repeating series. Which events should your change apply to?"
        )}
      </p>

      <ul class="space-y-2 text-token-sm text-tymeslot-600">
        <li :for={{scope, rule} <- @listed} id={"recurrence-scope-#{scope}"}>
          <span class="font-semibold text-tymeslot-800">{scope_label(scope)}:</span>
          {scope_description(scope)}
          <p :if={rule} class="mt-0.5 text-tymeslot-800" data-role="scope-summary">
            {rule.summary}
          </p>
          <p :if={rule && rule.refusal} class="mt-0.5 text-red-700" data-role="scope-refusal">
            {RecurrenceEdit.refusal_message(rule.refusal)}
          </p>
          <p :if={rule && rule.unavailable} class="mt-0.5 text-red-700" data-role="scope-refusal">
            {RecurrenceEdit.unavailable_message_for(rule.unavailable)}
          </p>
          <ul
            :if={scope == :following and @following_notes != []}
            id="recurrence-following-notes"
            class="mt-1 space-y-1 list-disc pl-5 text-tymeslot-500"
          >
            <li :for={note <- @following_notes}>{SeriesNotes.text(note)}</li>
          </ul>
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
            {dgettext("dashboard_calendar_recurrence", "Cancel")}
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
  def offered_scopes(%{kind: :recurrence_rule, scope_rules: scope_rules}),
    do: for(rule <- scope_rules, RecurrenceEdit.offered?(rule), do: rule.scope)

  def offered_scopes(%{kind: :recurrence_rule}), do: RecurrenceScope.values() -- [:this_only]
  def offered_scopes(_prompt), do: RecurrenceScope.values()

  # Every scope the prompt describes, with what a change of repeat rule
  # writes in it (`RecurrenceEdit`): a scope its calendar refuses is listed
  # with the reason, and has no button.
  defp listed_scopes(%{kind: :recurrence_rule, scope_rules: scope_rules}),
    do: for(rule <- scope_rules, do: {rule.scope, rule})

  defp listed_scopes(prompt), do: for(scope <- offered_scopes(prompt), do: {scope, nil})

  defp scope_label(:this_only), do: dgettext("dashboard_calendar_recurrence", "This event")

  defp scope_label(:following),
    do: dgettext("dashboard_calendar_recurrence", "This and following events")

  defp scope_label(:all), do: dgettext("dashboard_calendar_recurrence", "All events")

  defp scope_description(:this_only),
    do:
      dgettext(
        "dashboard_calendar_recurrence",
        "only this occurrence changes, and the rest of the series stays as it is."
      )

  defp scope_description(:following),
    do:
      dgettext(
        "dashboard_calendar_recurrence",
        "this occurrence and every later one change, and the earlier ones stay as they are."
      )

  defp scope_description(:all),
    do:
      dgettext(
        "dashboard_calendar_recurrence",
        "every occurrence in the series changes, earlier ones included."
      )
end
