defmodule TymeslotWeb.Dashboard.Polls.CandidateTimesField do
  @moduledoc """
  The create form's candidate times (`PollForm`): the host's week to pick
  them from (`AvailabilityWeek`), then one row per time, each a
  `datetime-local` input with its warnings under it (`SlotWarnings`), and a
  button for a row typed by hand. The form owns the rows and every event
  here; this only draws them.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Polls.PollSchema
  alias TymeslotWeb.Components.CoreComponents.{Buttons, Forms}
  alias TymeslotWeb.Dashboard.Polls.{AvailabilityWeek, SlotWarnings}

  attr :id, :string, required: true
  attr :slots, :list, required: true
  attr :time_off_keys, :any, required: true
  attr :conflict_keys, :any, required: true
  attr :errors, :list, default: []
  attr :week, :map, required: true, doc: "the attributes `AvailabilityWeek.grid/1` takes"
  attr :myself, :any, required: true

  @doc "The candidate times section."
  @spec field(map()) :: Phoenix.LiveView.Rendered.t()
  def field(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <label class="label mb-0">
          {dgettext("dashboard_polls", "Candidate times")}
        </label>
        <span class="text-token-xs text-tymeslot-500">
          <%!-- The noun counts the maximum ("1 of 40 times"), so the
                plural follows it rather than the times added. --%>
          {dngettext(
            "dashboard_polls",
            "%{used} of %{count} time",
            "%{used} of %{count} times",
            PollSchema.max_slots(),
            used: length(@slots)
          )}
        </span>
      </div>

      <AvailabilityWeek.grid id={"#{@id}-week"} slots={@slots} myself={@myself} {@week} />

      <div :for={{slot, index} <- Enum.with_index(@slots)} class="space-y-1">
        <div class="flex items-center gap-2">
          <div class="flex-1">
            <Forms.input
              type="datetime-local"
              name={"poll[slots][#{slot.key}]"}
              value={slot.value}
              aria-label={dgettext("dashboard_polls", "Candidate time %{n}", n: index + 1)}
            />
          </div>
          <Buttons.icon_button
            icon="hero-x-mark"
            label={dgettext("dashboard_polls", "Remove time")}
            variant={:danger}
            phx-click="remove_slot"
            phx-value-key={slot.key}
            phx-target={@myself}
          />
        </div>
        <SlotWarnings.warnings
          key={slot.key}
          time_off?={MapSet.member?(@time_off_keys, slot.key)}
          conflict?={MapSet.member?(@conflict_keys, slot.key)}
        />
      </div>

      <p :for={error <- @errors} class="form-error">{error}</p>

      <Buttons.action_button
        variant={:secondary}
        size={:sm}
        icon="hero-plus"
        phx-click="add_slot"
        phx-target={@myself}
      >
        {dgettext("dashboard_polls", "Add time")}
      </Buttons.action_button>
    </div>
    """
  end
end
