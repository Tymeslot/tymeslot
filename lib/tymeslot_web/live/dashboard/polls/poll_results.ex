defmodule TymeslotWeb.Dashboard.Polls.PollResults do
  @moduledoc """
  Presentation components for the dashboard poll results panel.

  Renders the host's live view of a single poll: candidate slots as rows,
  participants as columns, each cell marked with that participant's response
  (yes / if need be / no / no answer). Every slot carries a per-slot tally
  summary and, when it clashes with the host's calendar, a conflict badge.

  The panel adapts to the poll's lifecycle: an open poll offers a per-slot
  "confirm this time" action and a "cancel poll" action; a confirmed poll
  highlights the winning slot and links to the minted meeting; a cancelled poll
  shows a closed state. All data is passed in — these are display-only function
  components with no internal state; confirm/cancel events target the owning
  `PollsComponent`.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.CoreComponents.Icons

  @responses [:yes, :if_need_be, :no]

  @doc """
  Renders the results panel for a single selected poll.
  """
  attr :poll, :map, required: true
  attr :tallies, :map, required: true
  attr :slot_health, :map, required: true
  attr :slot_health_loading, :boolean, default: false
  attr :slot_errors, :map, default: %{}
  attr :winning_slot_id, :any, default: nil
  attr :meetings_path, :string, required: true
  attr :myself, :any, required: true

  @spec results_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def results_panel(assigns) do
    assigns =
      assigns
      |> assign(:votes, vote_index(assigns.poll.participants))
      |> assign(:open?, assigns.poll.status == :open)

    ~H"""
    <div id={"poll-results-#{@poll.id}"} class="card-glass py-6 px-6 space-y-6">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-token-lg font-semibold text-tymeslot-800 truncate">
            {@poll.title}
          </h3>
          <p class="text-token-xs text-tymeslot-500 mt-0.5">
            {dgettext("dashboard_common", "Times shown in %{timezone}", timezone: @poll.timezone)}
          </p>
        </div>
        <button
          type="button"
          phx-click="deselect_poll"
          phx-target={@myself}
          class="p-2 rounded-lg text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 transition-colors shrink-0"
          aria-label={dgettext("dashboard_common", "Close results")}
        >
          <Icons.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <.state_banner poll={@poll} meetings_path={@meetings_path} />

      <p
        :if={@slot_health_loading}
        class="flex items-center gap-2 text-token-xs text-tymeslot-500"
      >
        <Icons.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
        {dgettext("dashboard_common", "Checking your calendar for conflicts…")}
      </p>

      <div class="overflow-x-auto">
        <table class="w-full border-collapse text-token-sm">
          <thead>
            <tr class="border-b border-tymeslot-100">
              <th scope="col" class="text-left font-medium text-tymeslot-600 py-2 pr-4">
                {dgettext("dashboard_common", "Candidate time")}
              </th>
              <th
                :for={participant <- @poll.participants}
                scope="col"
                class="px-2 py-2 font-medium text-tymeslot-600 whitespace-nowrap"
              >
                {participant.name}
              </th>
            </tr>
          </thead>
          <tbody>
            <.slot_row
              :for={slot <- @poll.time_slots}
              slot={slot}
              participants={@poll.participants}
              votes={@votes}
              counts={Map.get(@tallies, slot.id, empty_counts())}
              health={Map.get(@slot_health, slot.id, :ok)}
              slot_error={Map.get(@slot_errors, slot.id)}
              timezone={@poll.timezone}
              winner?={@winning_slot_id == slot.id}
              open?={@open?}
              myself={@myself}
            />
          </tbody>
        </table>
      </div>

      <div :if={@open?} class="flex justify-end pt-2 border-t border-tymeslot-100">
        <button
          type="button"
          phx-click="cancel_poll"
          phx-target={@myself}
          class="btn btn-danger btn-sm inline-flex items-center gap-1"
        >
          <Icons.icon name="hero-x-circle" class="w-4 h-4" />
          {dgettext("dashboard_common", "Cancel poll")}
        </button>
      </div>
    </div>
    """
  end

  # --- Lifecycle banner ---

  attr :poll, :map, required: true
  attr :meetings_path, :string, required: true

  defp state_banner(%{poll: %{status: :confirmed}} = assigns) do
    ~H"""
    <div class="rounded-token-lg bg-blue-50 border border-blue-100 px-4 py-3 text-token-sm text-blue-800 flex items-center gap-2 flex-wrap">
      <Icons.icon name="hero-check-circle-solid" class="w-5 h-5 text-blue-500 shrink-0" />
      <span>{dgettext("dashboard_common", "This poll is confirmed. The winning time is highlighted below.")}</span>
      <.link navigate={@meetings_path} class="font-medium text-blue-700 underline hover:text-blue-900">
        {dgettext("dashboard_common", "View meeting")}
      </.link>
    </div>
    """
  end

  defp state_banner(%{poll: %{status: :cancelled}} = assigns) do
    ~H"""
    <div class="rounded-token-lg bg-tymeslot-100 border border-tymeslot-200 px-4 py-3 text-token-sm text-tymeslot-600 flex items-center gap-2">
      <Icons.icon name="hero-x-circle-solid" class="w-5 h-5 text-tymeslot-400 shrink-0" />
      <span>{dgettext("dashboard_common", "This poll was cancelled. Voting is closed.")}</span>
    </div>
    """
  end

  defp state_banner(assigns) do
    ~H"""
    <div class="rounded-token-lg bg-turquoise-50 border border-turquoise-100 px-4 py-3 text-token-sm text-turquoise-800 flex items-center gap-2">
      <Icons.icon name="hero-hand-raised" class="w-5 h-5 text-turquoise-500 shrink-0" />
      <span>{dgettext("dashboard_common", "Voting is open. Confirm a time once your guests have voted.")}</span>
    </div>
    """
  end

  # --- Slot row ---

  attr :slot, :map, required: true
  attr :participants, :list, required: true
  attr :votes, :map, required: true
  attr :counts, :map, required: true
  attr :health, :atom, required: true
  attr :slot_error, :any, default: nil
  attr :timezone, :string, required: true
  attr :winner?, :boolean, default: false
  attr :open?, :boolean, required: true
  attr :myself, :any, required: true

  defp slot_row(assigns) do
    ~H"""
    <tr
      id={"poll-slot-#{@slot.id}"}
      data-slot-id={@slot.id}
      class={[
        "border-b border-tymeslot-50 align-top",
        @winner? && "bg-blue-50"
      ]}
    >
      <td class="py-3 pr-4 align-top">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-medium text-tymeslot-800 whitespace-nowrap">
            {format_slot(@slot, @timezone)}
          </span>
          <span
            :if={@winner?}
            class="inline-flex items-center gap-1 px-2 py-0.5 rounded-token-full text-token-xs font-medium bg-blue-100 text-blue-700"
          >
            <Icons.icon name="hero-check-circle-mini" class="w-3.5 h-3.5" />
            {dgettext("dashboard_common", "Winner")}
          </span>
          <span
            :if={@health == :conflict}
            class="inline-flex items-center gap-1 px-2 py-0.5 rounded-token-full text-token-xs font-medium bg-amber-100 text-amber-700"
            title={dgettext("dashboard_common", "This time clashes with an event on your calendar")}
          >
            <Icons.icon name="hero-exclamation-triangle-mini" class="w-3.5 h-3.5" />
            {dgettext("dashboard_common", "Calendar conflict")}
          </span>
        </div>

        <.tally counts={@counts} />

        <div :if={@open?} class="mt-2">
          <button
            type="button"
            phx-click="confirm_slot"
            phx-value-slot={@slot.id}
            phx-target={@myself}
            class="btn btn-secondary btn-sm inline-flex items-center gap-1"
          >
            <Icons.icon name="hero-check" class="w-4 h-4" />
            {dgettext("dashboard_common", "Confirm this time")}
          </button>
          <p :if={@slot_error} class="form-error mt-1">{@slot_error}</p>
        </div>
      </td>

      <td
        :for={participant <- @participants}
        class="px-2 py-3 text-center align-middle"
        data-participant={participant.id}
        data-response={vote_for(@votes, participant.id, @slot.id)}
      >
        <.vote_mark response={vote_for(@votes, participant.id, @slot.id)} name={participant.name} />
      </td>
    </tr>
    """
  end

  # --- Vote mark ---

  attr :response, :atom, required: true
  attr :name, :string, required: true

  defp vote_mark(assigns) do
    ~H"""
    <Icons.icon name={response_icon(@response)} class={"w-5 h-5 mx-auto " <> response_class(@response)} />
    <span class="sr-only">{@name}: {response_label(@response)}</span>
    """
  end

  # --- Tally summary ---

  attr :counts, :map, required: true

  defp tally(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mt-1.5 text-token-xs">
      <span
        :for={response <- responses()}
        aria-label={"#{count_for(@counts, response)} #{response_label(response)}"}
        class="inline-flex items-center gap-1 text-tymeslot-600"
      >
        <Icons.icon name={response_icon(response)} class={"w-3.5 h-3.5 " <> response_class(response)} />
        {count_for(@counts, response)}
      </span>
    </div>
    """
  end

  # --- Data helpers ---

  defp responses, do: @responses

  # Builds a lookup of {participant_id, slot_id} => response for O(1) cell reads.
  @spec vote_index([map()]) :: %{{integer(), binary()} => atom()}
  defp vote_index(participants) do
    for participant <- participants,
        vote <- participant.votes,
        into: %{},
        do: {{participant.id, vote.poll_time_slot_id}, vote.response}
  end

  defp vote_for(votes, participant_id, slot_id) do
    Map.get(votes, {participant_id, slot_id}, :none)
  end

  defp count_for(counts, response), do: Map.get(counts, response, 0)

  defp empty_counts, do: %{yes: 0, if_need_be: 0, no: 0}

  defp format_slot(slot, timezone) do
    slot.start_time
    |> DateTimeUtils.convert_to_timezone(timezone)
    |> Calendar.strftime("%a %-d %b, %H:%M")
  end

  # --- Response presentation ---

  defp response_icon(:yes), do: "hero-check-circle-solid"
  defp response_icon(:if_need_be), do: "hero-question-mark-circle-solid"
  defp response_icon(:no), do: "hero-x-circle-solid"
  defp response_icon(:none), do: "hero-minus-circle"

  defp response_class(:yes), do: "text-green-500"
  defp response_class(:if_need_be), do: "text-amber-500"
  defp response_class(:no), do: "text-red-500"
  defp response_class(:none), do: "text-tymeslot-300"

  defp response_label(:yes), do: dgettext("dashboard_common", "Yes")
  defp response_label(:if_need_be), do: dgettext("dashboard_common", "If need be")
  defp response_label(:no), do: dgettext("dashboard_common", "No")
  defp response_label(:none), do: dgettext("dashboard_common", "No answer")
end
