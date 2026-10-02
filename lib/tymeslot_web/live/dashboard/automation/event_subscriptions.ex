defmodule TymeslotWeb.Dashboard.Automation.EventSubscriptions do
  @moduledoc """
  The "Event Subscriptions" card of the webhook, Slack and Telegram forms: one
  checkbox row per booking event, with its label and what it means.

  Each checkbox submits under `name` with the form and, when clicked, pushes
  `toggle_event` with `%{"event" => value}` to `target`, which keeps the
  selection in its own form state.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :name, :string, required: true, doc: "The checkboxes' field name, e.g. `webhook[events][]`"
  attr :events, :list, required: true, doc: "`%{value: _, label: _, description: _}` maps"
  attr :selected, :list, required: true, doc: "The values currently ticked"
  attr :toggle_event, :string, required: true
  attr :target, :any, required: true
  attr :errors, :list, default: [], doc: "Messages to show under the list"
  attr :description, :string, required: true, doc: "What a ticked event triggers"

  @spec event_subscriptions(map()) :: Phoenix.LiveView.Rendered.t()
  def event_subscriptions(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="mb-6">
        <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
          {dgettext("dashboard_automation", "Event Subscriptions")}
        </h3>
        <p class="text-token-sm text-tymeslot-500 font-bold mt-1">{@description}</p>
      </div>

      <div class="space-y-3">
        <label
          :for={event <- @events}
          class="flex items-start gap-3 p-4 rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 cursor-pointer transition-colors"
        >
          <.input
            type="checkbox"
            name={@name}
            value={event.value}
            checked={event.value in @selected}
            phx-click={JS.push(@toggle_event, value: %{"event" => event.value}, target: @target)}
          />
          <div class="flex-1">
            <div class="font-black text-tymeslot-900">{event.label}</div>
            <div class="text-token-sm text-tymeslot-600 font-medium">{event.description}</div>
          </div>
        </label>
      </div>
      <p :for={error <- @errors} class="text-token-sm text-red-600 font-medium mt-3">{error}</p>
    </div>
    """
  end
end
