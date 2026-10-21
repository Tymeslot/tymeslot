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

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Dashboard.Polls.PollAccess
  alias TymeslotWeb.Dashboard.Polls.PollEditor
  alias TymeslotWeb.Dashboard.Polls.PollInvite
  alias TymeslotWeb.Dashboard.Polls.PollShareLink
  alias TymeslotWeb.Helpers.LocaleFormat

  @responses [:yes, :if_need_be, :no]
  @bar_responses [:yes, :if_need_be, :no, :none]

  @doc """
  Renders the results panel for a single selected poll.
  """
  attr :poll, :map, required: true
  attr :unconfirmed_count, :integer, default: 0
  attr :invite_value, :string, default: ""
  attr :invite_error, :string, default: nil
  attr :tallies, :map, required: true
  attr :slot_health, :map, required: true
  attr :slot_health_loading, :boolean, default: false
  attr :slot_errors, :map, default: %{}
  attr :winning_slot_id, :any, default: nil
  attr :expanded_slots, :any, required: true
  attr :profile, :any, required: true
  attr :integration_status, :map, required: true
  attr :editing_details?, :boolean, default: false
  attr :meeting_types, :list, default: []
  attr :user_id, :integer, required: true
  attr :parent_id, :string, required: true
  attr :meetings_path, :string, required: true
  attr :time_format, :string, default: nil
  attr :myself, :any, required: true

  @spec results_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def results_panel(assigns) do
    assigns =
      assigns
      |> assign(:votes, vote_index(assigns.poll.participants))
      |> assign(:open?, assigns.poll.status == :open)
      |> assign(:participant_count, length(assigns.poll.participants))
      |> assign(:voted_count, Enum.count(assigns.poll.participants, & &1.voted_at))
      |> assign(:leaders, Polls.leading_slot_ids(assigns.poll.time_slots, assigns.tallies))

    ~H"""
    <Containers.card id={"poll-results-#{@poll.id}"} class="space-y-6">
      <.live_component
        :if={@editing_details?}
        module={PollEditor}
        id={"poll-editor-#{@poll.id}"}
        poll={@poll}
        meeting_types={@meeting_types}
        user_id={@user_id}
        parent_id={@parent_id}
        parent_myself={@myself}
      />

      <div :if={!@editing_details?} class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-token-lg font-semibold text-tymeslot-900 truncate">
            {@poll.title}
          </h2>
          <%!-- The zone qualifies every time in the panel, so it reads as a
                property of the poll rather than a sentence about it. The full
                phrasing stays on the label, which keeps the already-translated
                string and gives the badge an accessible reading. --%>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <Feedback.pill
              icon="hero-globe-alt-mini"
              aria-label={
                dgettext("dashboard_polls", "Times shown in %{timezone}", timezone: @poll.timezone)
              }
              data-testid="poll-timezone-badge"
            >
              {@poll.timezone}
            </Feedback.pill>
            <PollAccess.access_pill poll={@poll} />
          </div>

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

        <div class="flex items-center gap-2 shrink-0">
          <%!-- The voting link belongs next to the open poll, not only on the
                list card the panel pushes off screen. --%>
          <PollShareLink.copy_link_button
            id={"poll-results-copy-#{@poll.id}"}
            poll={@poll}
            profile={@profile}
            integration_status={@integration_status}
          />
          <%!-- Only while the poll is open: see `Polls.Editing` for what
                can change while people vote. --%>
          <Buttons.icon_button
            :if={@open?}
            icon="hero-pencil-square"
            label={dgettext("dashboard_polls", "Edit poll")}
            phx-click="edit_poll_details"
            phx-target={@myself}
            data-testid="poll-edit-details"
          />
          <Buttons.icon_button
            icon="hero-x-mark"
            label={dgettext("dashboard_polls", "Close results")}
            phx-click="deselect_poll"
            phx-target={@myself}
          />
        </div>
      </div>

      <.state_banner poll={@poll} meetings_path={@meetings_path} />

      <p
        :if={@slot_health_loading}
        class="flex items-center gap-2 text-token-xs text-tymeslot-500"
      >
        <Icons.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
        {dgettext("dashboard_polls", "Checking your calendar for conflicts…")}
      </p>

      <p class="text-token-sm text-tymeslot-600" data-testid="poll-respondent-count">
        {dngettext(
          "dashboard_polls",
          "%{count} guest has voted so far.",
          "%{count} guests have voted so far.",
          @voted_count
        )}
      </p>

      <PollInvite.waiting_for :if={@open?} participants={@poll.participants} />

      <%!-- People who asked for a voting link but have not saved responses
            through it yet. They prove nothing until they do, so they are not
            in the counts above; this tells the host why someone who says they
            voted is not listed. --%>
      <p
        :if={@open? && @unconfirmed_count > 0}
        class="text-token-xs text-tymeslot-500"
        data-testid="poll-unconfirmed-count"
      >
        {dngettext(
          "dashboard_polls",
          "%{count} more person asked for a voting link but hasn't voted with it yet.",
          "%{count} more people asked for a voting link but haven't voted with it yet.",
          @unconfirmed_count
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
          time_format={@time_format}
          winner?={@winning_slot_id == slot.id}
          leader?={@open? && slot.id in @leaders}
          expanded?={slot.id in @expanded_slots}
          open?={@open?}
          myself={@myself}
        />
      </div>

      <PollInvite.invite_form
        :if={@open?}
        poll={@poll}
        value={@invite_value}
        error={@invite_error}
        myself={@myself}
      />

      <%!-- A poll that is over can be deleted to tidy the list; an open one is
            cancelled first, so nothing people still vote on disappears. --%>
      <div :if={!@open?} class="flex justify-end pt-2 border-t border-tymeslot-100">
        <Buttons.action_button
          variant={:danger_soft}
          size={:sm}
          icon="hero-trash"
          phx-click="request_delete_poll"
          phx-target={@myself}
          data-testid="poll-delete"
        >
          {dgettext("dashboard_polls", "Delete poll")}
        </Buttons.action_button>
      </div>

      <div :if={@open?} class="flex justify-end pt-2 border-t border-tymeslot-100">
        <Buttons.action_button
          variant={:danger_soft}
          size={:sm}
          icon="hero-x-circle"
          phx-click="request_cancel_poll"
          phx-target={@myself}
        >
          {dgettext("dashboard_polls", "Cancel poll")}
        </Buttons.action_button>
      </div>
    </Containers.card>
    """
  end

  # --- Lifecycle banner ---

  attr :poll, :map, required: true
  attr :meetings_path, :string, required: true

  defp state_banner(%{poll: %{status: :confirmed}} = assigns) do
    ~H"""
    <div class="rounded-token-lg bg-blue-50 border border-blue-100 px-4 py-3 text-token-sm text-blue-800 flex items-center gap-2 flex-wrap">
      <Icons.icon name="hero-check-circle-solid" class="w-5 h-5 text-blue-500 shrink-0" />
      <span>{dgettext(
        "dashboard_polls",
        "This poll is confirmed. The winning time is highlighted below."
      )}</span>
      <.link navigate={@meetings_path} class="font-medium text-blue-700 underline hover:text-blue-900">
        {dgettext("dashboard_polls", "View meeting")}
      </.link>
    </div>
    """
  end

  defp state_banner(%{poll: %{status: :cancelled}} = assigns) do
    ~H"""
    <div class="rounded-token-lg bg-tymeslot-100 border border-tymeslot-200 px-4 py-3 text-token-sm text-tymeslot-600 flex items-center gap-2">
      <Icons.icon name="hero-x-circle-solid" class="w-5 h-5 text-tymeslot-400 shrink-0" />
      <span>{dgettext("dashboard_polls", "This poll was cancelled. Voting is closed.")}</span>
    </div>
    """
  end

  defp state_banner(assigns) do
    ~H"""
    <div class="rounded-token-lg bg-turquoise-50 border border-turquoise-100 px-4 py-3 text-token-sm text-turquoise-800 flex items-center gap-2">
      <Icons.icon name="hero-hand-raised" class="w-5 h-5 text-turquoise-500 shrink-0" />
      <span>{dgettext(
        "dashboard_polls",
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
  attr :time_format, :string, default: nil
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
            {format_slot(@slot, @timezone, @time_format)}
          </span>
          <Feedback.pill
            :if={@winner?}
            tone={:info}
            icon="hero-check-circle-mini"
          >
            {dgettext("dashboard_polls", "Winner")}
          </Feedback.pill>
          <Feedback.pill
            :if={@leader?}
            tone={:brand}
            icon="hero-arrow-trending-up-mini"
            data-testid="poll-slot-leader"
          >
            {dgettext("dashboard_polls", "Most votes")}
          </Feedback.pill>
          <Feedback.pill
            :if={@health == :conflict}
            tone={:warning}
            icon="hero-exclamation-triangle-mini"
            title={dgettext("dashboard_polls", "This time clashes with an event on your calendar")}
          >
            {dgettext("dashboard_polls", "Calendar conflict")}
          </Feedback.pill>
        </div>

        <Buttons.action_button
          :if={@open?}
          variant={:secondary}
          size={:sm}
          icon="hero-check"
          class="shrink-0"
          phx-click="confirm_slot"
          phx-value-slot={@slot.id}
          phx-target={@myself}
          phx-disable-with={dgettext("common", "Processing...")}
        >
          {dgettext("dashboard_polls", "Confirm this time")}
        </Buttons.action_button>
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
          {dgettext("dashboard_polls", "Hide who voted")}
        <% else %>
          {dgettext("dashboard_polls", "Who voted")}
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
      {dgettext("dashboard_polls", "No responses yet.")}
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
    |> Enum.map(&PollParticipantSchema.display_name/1)
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

  # The weekday and month follow the organiser's language and the clock their
  # own 12/24-hour preference, as everywhere else on the dashboard.
  defp format_slot(slot, timezone, time_format) do
    local = DateTimeUtils.convert_to_timezone(slot.start_time, timezone)
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    "#{LocaleFormat.format_short_weekday_date(local, locale)}, " <>
      TimeFormat.format(local, TimeFormat.resolve(time_format, locale))
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

  defp response_label(:yes), do: dgettext("dashboard_polls", "Yes")
  defp response_label(:if_need_be), do: dgettext("dashboard_polls", "If need be")
  defp response_label(:no), do: dgettext("dashboard_polls", "No")
  defp response_label(:none), do: dgettext("dashboard_polls", "No answer")
end
