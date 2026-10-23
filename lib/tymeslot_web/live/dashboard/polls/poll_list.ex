defmodule TymeslotWeb.Dashboard.Polls.PollList do
  @moduledoc """
  Presentation components for the dashboard poll list.

  Renders one card per poll (title, status badge, slot and participant counts,
  a vote-progress summary, the shared copy-share-link control, and a view-results
  button) and the empty state shown when the host has no polls yet. All data is
  passed in; these are display-only function components with no internal state.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Polls
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Dashboard.Polls.PollShareLink

  @doc """
  Renders the list of polls, or an empty state when there are none.

  Guests vote on a page that opens only once the host has a calendar
  connected, so without one the empty state asks for it instead of offering a
  new poll, and a list of earlier polls carries the same request above it.
  """
  attr :polls, :list, required: true
  attr :profile, :any, required: true
  attr :integration_status, :map, required: true
  attr :selected_poll_id, :any, default: nil
  attr :open_poll_ids, :any, required: true, doc: "MapSet of the ids of polls taking votes"
  attr :myself, :any, required: true

  @spec poll_list(map()) :: Phoenix.LiveView.Rendered.t()
  def poll_list(%{polls: []} = assigns) do
    if LinkAccessPolicy.has_calendar?(assigns.integration_status),
      do: empty_state(assigns),
      else: connect_calendar_empty_state(assigns)
  end

  def poll_list(assigns) do
    assigns =
      assign(
        assigns,
        :calendar_connected?,
        LinkAccessPolicy.has_calendar?(assigns.integration_status)
      )

    ~H"""
    <div class="space-y-4">
      <.connect_calendar_notice :if={!@calendar_connected?} />
      <.poll_card
        :for={poll <- @polls}
        poll={poll}
        profile={@profile}
        integration_status={@integration_status}
        selected={@selected_poll_id == poll.id}
        voting_open?={MapSet.member?(@open_poll_ids, poll.id)}
        myself={@myself}
      />
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <Feedback.empty_state
      icon="hero-hand-raised"
      size={:lg}
      data-testid="polls-empty"
      title={dgettext("dashboard_polls", "No polls yet")}
      description={
        dgettext(
          "dashboard_polls",
          "Create a poll to propose a few times and let your guests vote."
        )
      }
    >
      <:action><.new_poll_button myself={@myself} /></:action>
    </Feedback.empty_state>
    """
  end

  defp connect_calendar_empty_state(assigns) do
    ~H"""
    <Feedback.empty_state
      icon="hero-calendar-days"
      size={:lg}
      data-testid="polls-connect-calendar"
      title={dgettext("dashboard_polls", "Connect a calendar to start a poll")}
      description={connect_calendar_reason()}
    >
      <:action><.connect_calendar_link /></:action>
    </Feedback.empty_state>
    """
  end

  defp connect_calendar_notice(assigns) do
    ~H"""
    <Containers.card padding={:sm} data-testid="polls-connect-calendar">
      <div class="flex flex-wrap items-center gap-3">
        <Icons.icon name="hero-calendar-days" class="w-5 h-5 text-turquoise-600 shrink-0" />
        <p class="flex-1 min-w-[12rem] text-token-sm text-tymeslot-700">
          {connect_calendar_reason()}
        </p>
        <.connect_calendar_link />
      </div>
    </Containers.card>
    """
  end

  defp connect_calendar_link(assigns) do
    ~H"""
    <Buttons.action_link
      navigate="/dashboard/integrations?tab=calendars"
      size={:sm}
      icon="hero-plus"
      class="shrink-0"
    >
      {dgettext("dashboard_polls", "Connect a calendar")}
    </Buttons.action_link>
    """
  end

  defp connect_calendar_reason,
    do:
      dgettext(
        "dashboard_polls",
        "Guests vote on a page that opens once your calendar is connected, so Tymeslot can flag the times you're busy and book the winner without double-booking you."
      )

  @doc """
  The button that opens the new-poll form: in the empty state while there are
  no polls, above the list once there are.
  """
  attr :myself, :any, required: true
  attr :rest, :global

  @spec new_poll_button(map()) :: Phoenix.LiveView.Rendered.t()
  def new_poll_button(assigns) do
    ~H"""
    <Buttons.action_button icon="hero-plus" phx-click="new_poll" phx-target={@myself} {@rest}>
      {dgettext("dashboard_polls", "New poll")}
    </Buttons.action_button>
    """
  end

  attr :poll, :map, required: true
  attr :profile, :any, required: true
  attr :integration_status, :map, required: true
  attr :selected, :boolean, default: false
  attr :voting_open?, :boolean, required: true
  attr :myself, :any, required: true

  @spec poll_card(map()) :: Phoenix.LiveView.Rendered.t()
  defp poll_card(assigns) do
    tallies = Polls.tallies(assigns.poll)

    assigns =
      assigns
      |> assign(:slot_count, length(assigns.poll.time_slots))
      |> assign(:participant_count, length(assigns.poll.participants))
      |> assign(:vote_count, total_votes(tallies))

    ~H"""
    <Containers.card padding={:sm} class={@selected && "ring-2 ring-turquoise-400"}>
      <div class="flex items-start gap-3">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 min-w-0">
            <h2 class="text-token-lg font-semibold text-tymeslot-900 truncate">
              {@poll.title}
            </h2>
            <.status_pill status={status(@poll, @voting_open?)} />
          </div>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 mt-2 text-token-xs text-tymeslot-600">
            <span class="flex items-center gap-1">
              <Icons.icon name="hero-clock-mini" class="w-3.5 h-3.5" />
              {dngettext(
                "dashboard_polls",
                "%{count} time option",
                "%{count} time options",
                @slot_count,
                count: @slot_count
              )}
            </span>
            <span class="flex items-center gap-1">
              <Icons.icon name="hero-users-mini" class="w-3.5 h-3.5" />
              {dngettext(
                "dashboard_polls",
                "%{count} participant",
                "%{count} participants",
                @participant_count,
                count: @participant_count
              )}
            </span>
            <span class="flex items-center gap-1">
              <Icons.icon name="hero-check-circle-mini" class="w-3.5 h-3.5" />
              {dngettext(
                "dashboard_polls",
                "%{count} vote",
                "%{count} votes",
                @vote_count,
                count: @vote_count
              )}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <PollShareLink.copy_link_button
            id={"poll-copy-#{@poll.id}"}
            poll={@poll}
            profile={@profile}
            integration_status={@integration_status}
          />

          <Buttons.icon_button
            icon="hero-chart-bar"
            label={dgettext("dashboard_polls", "View results")}
            phx-click="select_poll"
            phx-value-id={@poll.id}
            phx-target={@myself}
          />
        </div>
      </div>
    </Containers.card>
    """
  end

  attr :status, :atom, required: true

  @spec status_pill(map()) :: Phoenix.LiveView.Rendered.t()
  defp status_pill(assigns) do
    ~H"""
    <Feedback.pill tone={status_tone(@status)} uppercase data-testid="poll-status">
      {status_label(@status)}
    </Feedback.pill>
    """
  end

  # An open poll past its deadline takes no more votes, though it still
  # waits for the host to confirm a time.
  defp status(%{status: :open}, true = _voting_open?), do: :open
  defp status(%{status: :open}, false = _voting_open?), do: :voting_closed
  defp status(%{status: status}, _voting_open?), do: status

  defp status_tone(:open), do: :brand
  defp status_tone(:voting_closed), do: :warning
  defp status_tone(:confirmed), do: :info
  defp status_tone(:cancelled), do: :neutral

  defp status_label(:open), do: dgettext("dashboard_polls", "Open")
  defp status_label(:voting_closed), do: dgettext("dashboard_polls", "Voting closed")
  defp status_label(:confirmed), do: dgettext("dashboard_polls", "Confirmed")
  defp status_label(:cancelled), do: dgettext("dashboard_polls", "Cancelled")

  defp total_votes(tallies) do
    Enum.reduce(tallies, 0, fn {_slot_id, counts}, acc ->
      acc + counts.yes + counts.if_need_be + counts.no
    end)
  end
end
