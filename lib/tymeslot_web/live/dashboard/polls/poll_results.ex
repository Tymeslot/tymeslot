defmodule TymeslotWeb.Dashboard.Polls.PollResults do
  @moduledoc """
  Presentation components for the dashboard poll results panel.

  Renders the host's live view of a single poll as one summary card per
  candidate slot: the time, a proportional response bar, the counts, and a
  confirm action. Each slot carries a conflict badge when it clashes with the
  host's calendar, and the slots leading on yes votes are badged while voting
  is open.

  Who answered which way sits behind a per-slot disclosure rather than in the
  card itself. The host's question is which time wins, not how each individual
  voted, and a column per respondent stops fitting on screen well before the
  poll's forty-participant cap.

  The panel adapts to the poll's lifecycle: an open poll offers a per-slot
  "confirm this time" action and a "cancel poll" action; a confirmed poll
  highlights the winning slot and links to the minted meeting; a cancelled poll
  shows a closed state. All data is passed in — these are display-only function
  components with no internal state; confirm/cancel/disclosure events target the
  owning `PollsComponent`.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Dashboard.Polls.PollShareLink

  @responses [:yes, :if_need_be, :no]
  @bar_responses [:yes, :if_need_be, :no, :none]

  @doc """
  Renders the results panel for a single selected poll.
  """
  attr :poll, :map, required: true
  attr :tallies, :map, required: true
  attr :slot_health, :map, required: true
  attr :slot_health_loading, :boolean, default: false
  attr :slot_errors, :map, default: %{}
  attr :winning_slot_id, :any, default: nil
  attr :expanded_slots, :any, required: true
  attr :profile, :any, required: true
  attr :integration_status, :map, required: true
  attr :editing_details?, :boolean, default: false
  attr :detail_errors, :map, default: %{}
  attr :meetings_path, :string, required: true
  attr :myself, :any, required: true

  @spec results_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def results_panel(assigns) do
    assigns =
      assigns
      |> assign(:votes, vote_index(assigns.poll.participants))
      |> assign(:open?, assigns.poll.status == :open)
      |> assign(:participant_count, length(assigns.poll.participants))
      |> assign(:leaders, leader_ids(assigns.poll.time_slots, assigns.tallies))

    ~H"""
    <div id={"poll-results-#{@poll.id}"} class="card-glass py-6 px-6 space-y-6">
      <.details_form
        :if={@editing_details?}
        poll={@poll}
        errors={@detail_errors}
        myself={@myself}
      />

      <div :if={!@editing_details?} class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-token-lg font-semibold text-tymeslot-800 truncate">
            {@poll.title}
          </h3>
          <%!-- The zone qualifies every time in the panel, so it reads as a
                property of the poll rather than a sentence about it. The full
                phrasing stays on the label, which keeps the already-translated
                string and gives the badge an accessible reading. --%>
          <span
            class="inline-flex items-center gap-1 mt-1 px-2 py-0.5 rounded-token-full text-token-xs font-medium bg-tymeslot-100 text-tymeslot-600"
            aria-label={
              dgettext("dashboard_common", "Times shown in %{timezone}", timezone: @poll.timezone)
            }
            data-testid="poll-timezone-badge"
          >
            <Icons.icon name="hero-globe-alt-mini" class="w-3.5 h-3.5" />
            {@poll.timezone}
          </span>

          <%!-- The host's own description. Shown here because the panel is
                where they check what they asked their guests, and it is the
                only place in the dashboard the text appears at all. --%>
          <p
            :if={@poll.description not in [nil, ""]}
            class="mt-2 text-token-sm text-tymeslot-600 whitespace-pre-line"
            data-testid="poll-description"
          >
            {@poll.description}
          </p>
        </div>

        <div class="flex items-center gap-1.5 shrink-0">
          <%!-- The voting link belongs next to the open poll, not only on the
                list card the panel pushes off screen. --%>
          <PollShareLink.copy_link_button
            id={"poll-results-copy-#{@poll.id}"}
            poll={@poll}
            profile={@profile}
            integration_status={@integration_status}
          />
          <%!-- Wording only, and only while the poll is open: see
                `Polls.update_details/3` for why the times are not editable. --%>
          <button
            :if={@open?}
            type="button"
            phx-click="edit_poll_details"
            phx-target={@myself}
            class="p-2 rounded-lg bg-white border-2 border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-400 hover:text-turquoise-700 transition-colors"
            title={dgettext("dashboard_common", "Edit title and description")}
            data-testid="poll-edit-details"
          >
            <Icons.icon name="hero-pencil-square" class="w-4 h-4" />
          </button>
          <button
            type="button"
            phx-click="deselect_poll"
            phx-target={@myself}
            class="p-2 rounded-lg text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 transition-colors"
            aria-label={dgettext("dashboard_common", "Close results")}
          >
            <Icons.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <.state_banner poll={@poll} meetings_path={@meetings_path} />

      <p
        :if={@slot_health_loading}
        class="flex items-center gap-2 text-token-xs text-tymeslot-500"
      >
        <Icons.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
        {dgettext("dashboard_common", "Checking your calendar for conflicts…")}
      </p>

      <p class="text-token-sm text-tymeslot-600" data-testid="poll-respondent-count">
        {dngettext(
          "dashboard_common",
          "%{count} guest has voted so far.",
          "%{count} guests have voted so far.",
          @participant_count
        )}
      </p>

      <div class="space-y-3">
        <.slot_summary
          :for={slot <- @poll.time_slots}
          slot={slot}
          participants={@poll.participants}
          votes={@votes}
          counts={Map.get(@tallies, slot.id, empty_counts())}
          participant_count={@participant_count}
          health={Map.get(@slot_health, slot.id, :ok)}
          slot_error={Map.get(@slot_errors, slot.id)}
          timezone={@poll.timezone}
          winner?={@winning_slot_id == slot.id}
          leader?={@open? && slot.id in @leaders}
          expanded?={slot.id in @expanded_slots}
          open?={@open?}
          myself={@myself}
        />
      </div>

      <div :if={@open?} class="flex justify-end pt-2 border-t border-tymeslot-100">
        <button
          type="button"
          phx-click="request_cancel_poll"
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

  # --- Details form ---

  attr :poll, :map, required: true
  attr :errors, :map, required: true
  attr :myself, :any, required: true

  defp details_form(assigns) do
    ~H"""
    <form
      id={"poll-details-form-#{@poll.id}"}
      phx-submit="save_poll_details"
      phx-target={@myself}
      class="space-y-4"
      data-testid="poll-details-form"
    >
      <Forms.input
        type="text"
        name="poll[title]"
        label={dgettext("dashboard_common", "Title")}
        value={@poll.title}
        required
        errors={error_list(@errors, :title)}
        icon="hero-hand-raised"
      />

      <Forms.input
        type="textarea"
        name="poll[description]"
        label={dgettext("dashboard_common", "Description (optional)")}
        value={@poll.description}
        placeholder={dgettext("dashboard_common", "Add any context for your guests")}
        errors={error_list(@errors, :description)}
      />

      <div class="flex justify-end gap-2">
        <button
          type="button"
          phx-click="cancel_edit_poll_details"
          phx-target={@myself}
          class="btn btn-secondary btn-sm"
        >
          {dgettext("dashboard_common", "Cancel")}
        </button>
        <button type="submit" class="btn btn-primary btn-sm">
          {dgettext("dashboard_common", "Save changes")}
        </button>
      </div>
    </form>
    """
  end

  defp error_list(errors, field), do: Map.get(errors, field, [])

  # --- Lifecycle banner ---

  attr :poll, :map, required: true
  attr :meetings_path, :string, required: true

  defp state_banner(%{poll: %{status: :confirmed}} = assigns) do
    ~H"""
    <div class="rounded-token-lg bg-blue-50 border border-blue-100 px-4 py-3 text-token-sm text-blue-800 flex items-center gap-2 flex-wrap">
      <Icons.icon name="hero-check-circle-solid" class="w-5 h-5 text-blue-500 shrink-0" />
      <span>{dgettext(
        "dashboard_common",
        "This poll is confirmed. The winning time is highlighted below."
      )}</span>
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
      <span>{dgettext(
        "dashboard_common",
        "Voting is open. Confirm a time once your guests have voted."
      )}</span>
    </div>
    """
  end

  # --- Slot summary card ---

  attr :slot, :map, required: true
  attr :participants, :list, required: true
  attr :votes, :map, required: true
  attr :counts, :map, required: true
  attr :participant_count, :integer, required: true
  attr :health, :atom, required: true
  attr :slot_error, :any, default: nil
  attr :timezone, :string, required: true
  attr :winner?, :boolean, default: false
  attr :leader?, :boolean, default: false
  attr :expanded?, :boolean, default: false
  attr :open?, :boolean, required: true
  attr :myself, :any, required: true

  defp slot_summary(assigns) do
    ~H"""
    <div
      id={"poll-slot-#{@slot.id}"}
      data-slot-id={@slot.id}
      data-testid="poll-slot"
      class={[
        "rounded-token-lg border p-4 space-y-3",
        @winner? && "border-blue-200 bg-blue-50",
        !@winner? && "border-tymeslot-100 bg-white"
      ]}
    >
      <div class="flex items-start justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-2 flex-wrap min-w-0">
          <span class="font-medium text-tymeslot-800">
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
            :if={@leader?}
            class="inline-flex items-center gap-1 px-2 py-0.5 rounded-token-full text-token-xs font-medium bg-turquoise-100 text-turquoise-700"
            data-testid="poll-slot-leader"
          >
            <Icons.icon name="hero-arrow-trending-up-mini" class="w-3.5 h-3.5" />
            {dgettext("dashboard_common", "Most votes")}
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

        <button
          :if={@open?}
          type="button"
          phx-click="confirm_slot"
          phx-value-slot={@slot.id}
          phx-target={@myself}
          phx-disable-with={dgettext("common", "Processing...")}
          class="btn btn-secondary btn-sm inline-flex items-center gap-1 shrink-0"
        >
          <Icons.icon name="hero-check" class="w-4 h-4" />
          {dgettext("dashboard_common", "Confirm this time")}
        </button>
      </div>

      <.response_bar counts={@counts} total={@participant_count} />

      <.tally counts={@counts} total={@participant_count} />

      <%!-- The per-person breakdown is a disclosure rather than always-on: it
            is the long tail of the data, and the host is here to pick a time.
            It gets a full-width row in the brand colour because a quiet label
            in the corner reads as a caption, not something to click.

            Expansion is held in the parent component's assigns, not in a native
            <details>, so a live vote arriving over PubSub cannot collapse a
            panel the host has open. --%>
      <button
        :if={@participant_count > 0}
        type="button"
        phx-click="toggle_slot_voters"
        phx-value-slot={@slot.id}
        phx-target={@myself}
        aria-expanded={to_string(@expanded?)}
        aria-controls={"poll-voters-#{@slot.id}"}
        class="w-full flex items-center justify-center gap-1.5 pt-3 border-t border-tymeslot-100 text-token-sm font-medium text-turquoise-700 hover:text-turquoise-900 transition-colors"
      >
        <Icons.icon
          name={if @expanded?, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
          class="w-4 h-4"
        />
        <%= if @expanded? do %>
          {dgettext("dashboard_common", "Hide who voted")}
        <% else %>
          {dgettext("dashboard_common", "Who voted")}
        <% end %>
      </button>

      <div
        :if={@expanded?}
        id={"poll-voters-#{@slot.id}"}
        class="space-y-2"
        data-testid="poll-slot-voters"
      >
        <.voter_group
          :for={response <- bar_responses()}
          response={response}
          names={voter_names(@participants, @votes, @slot.id, response)}
        />
      </div>

      <p :if={@slot_error} class="form-error">{@slot_error}</p>
    </div>
    """
  end

  # --- Response bar ---

  attr :counts, :map, required: true
  attr :total, :integer, required: true

  defp response_bar(%{total: 0} = assigns) do
    ~H"""
    <p class="text-token-xs text-tymeslot-400">
      {dgettext("dashboard_common", "No responses yet.")}
    </p>
    """
  end

  defp response_bar(assigns) do
    ~H"""
    <div
      class="flex h-2 w-full overflow-hidden rounded-token-full bg-tymeslot-100"
      role="img"
      aria-label={bar_label(@counts, @total)}
      data-testid="poll-response-bar"
    >
      <div
        :for={response <- bar_responses()}
        class={bar_segment_class(response)}
        style={"width: #{percent(count_for(@counts, response, @total), @total)}%"}
      >
      </div>
    </div>
    """
  end

  # --- Tally summary ---

  attr :counts, :map, required: true
  attr :total, :integer, required: true

  defp tally(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-token-sm">
      <span
        :for={response <- responses()}
        class="inline-flex items-center gap-1 text-tymeslot-700"
      >
        <Icons.icon name={response_icon(response)} class={"w-4 h-4 " <> response_class(response)} />
        <span class="font-semibold">{count_for(@counts, response, @total)}</span>
        <span class="text-tymeslot-500">{response_label(response)}</span>
      </span>
    </div>
    """
  end

  # --- Voter groups ---

  attr :response, :atom, required: true
  attr :names, :list, required: true

  defp voter_group(%{names: []} = assigns), do: ~H""

  defp voter_group(assigns) do
    ~H"""
    <div class="flex items-start gap-2 text-token-xs" data-response={@response}>
      <Icons.icon
        name={response_icon(@response)}
        class={"w-4 h-4 shrink-0 mt-0.5 " <> response_class(@response)}
      />
      <span class="text-tymeslot-500 shrink-0">{response_label(@response)}:</span>
      <span class="text-tymeslot-700">{Enum.join(@names, ", ")}</span>
    </div>
    """
  end

  # --- Data helpers ---

  defp responses, do: @responses

  defp bar_responses, do: @bar_responses

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

  defp voter_names(participants, votes, slot_id, response) do
    participants
    |> Enum.filter(&(vote_for(votes, &1.id, slot_id) == response))
    |> Enum.map(& &1.name)
  end

  # `:none` is not stored as a vote — it is everyone the tallies did not
  # account for, so it is derived rather than looked up.
  defp count_for(counts, :none, total) do
    max(total - Enum.sum(Enum.map(@responses, &Map.get(counts, &1, 0))), 0)
  end

  defp count_for(counts, response, _total), do: Map.get(counts, response, 0)

  defp percent(_count, 0), do: 0
  defp percent(count, total), do: count / total * 100

  defp empty_counts, do: %{yes: 0, if_need_be: 0, no: 0}

  # The slots tied on the most yes votes, breaking ties on "if need be" so a
  # slot half the group can only just make does not outrank one they can.
  #
  # A badge only means something if it distinguishes. An unanswered poll has no
  # leader, and neither does one where every slot scores the same — a poll where
  # the group is equally free throughout is a real outcome, and marking all six
  # slots "most votes" tells the host nothing they can act on.
  @spec leader_ids([map()], map()) :: [binary()]
  defp leader_ids(time_slots, tallies) do
    scores =
      Map.new(time_slots, fn slot ->
        counts = Map.get(tallies, slot.id, empty_counts())
        {slot.id, {Map.get(counts, :yes, 0), Map.get(counts, :if_need_be, 0)}}
      end)

    leaders =
      case scores |> Map.values() |> Enum.max(fn -> {0, 0} end) do
        {0, 0} -> []
        best -> for {id, score} <- scores, score == best, do: id
      end

    if length(leaders) == map_size(scores), do: [], else: leaders
  end

  defp format_slot(slot, timezone) do
    slot.start_time
    |> DateTimeUtils.convert_to_timezone(timezone)
    |> Calendar.strftime("%a %-d %b, %H:%M")
  end

  # --- Response presentation ---

  defp bar_label(counts, total) do
    Enum.map_join(@responses, ", ", fn response ->
      "#{count_for(counts, response, total)} #{response_label(response)}"
    end)
  end

  defp bar_segment_class(:yes), do: "bg-green-500"
  defp bar_segment_class(:if_need_be), do: "bg-amber-400"
  defp bar_segment_class(:no), do: "bg-red-400"
  defp bar_segment_class(:none), do: "bg-tymeslot-200"

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
