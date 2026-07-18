defmodule TymeslotWeb.Dashboard.Polls.PollList do
  @moduledoc """
  Presentation components for the dashboard poll list.

  Renders one card per poll (title, status badge, slot and participant counts,
  a vote-progress summary, a gated copy-share-link control, and a view-results
  button) and the empty state shown when the host has no polls yet. All data is
  passed in; these are display-only function components with no internal state.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Polls
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.CoreComponents.Icons

  @doc """
  Renders the list of polls, or an empty state when there are none.
  """
  attr :polls, :list, required: true
  attr :profile, :any, required: true
  attr :integration_status, :map, required: true
  attr :selected_poll_id, :any, default: nil
  attr :myself, :any, required: true

  @spec poll_list(map()) :: Phoenix.LiveView.Rendered.t()
  def poll_list(%{polls: []} = assigns) do
    ~H"""
    <div class="card-glass py-12 px-6 text-center">
      <Icons.icon name="hero-hand-raised" class="w-10 h-10 mx-auto mb-3 text-tymeslot-300" />
      <p class="text-token-base font-medium text-tymeslot-700">
        {dgettext("dashboard_common", "No polls yet")}
      </p>
      <p class="mt-1 text-token-sm text-tymeslot-500">
        {dgettext(
          "dashboard_common",
          "Create a poll to propose a few times and let your guests vote."
        )}
      </p>
    </div>
    """
  end

  def poll_list(assigns) do
    ~H"""
    <div class="space-y-4">
      <.poll_card
        :for={poll <- @polls}
        poll={poll}
        profile={@profile}
        integration_status={@integration_status}
        selected={@selected_poll_id == poll.id}
        myself={@myself}
      />
    </div>
    """
  end

  attr :poll, :map, required: true
  attr :profile, :any, required: true
  attr :integration_status, :map, required: true
  attr :selected, :boolean, default: false
  attr :myself, :any, required: true

  @spec poll_card(map()) :: Phoenix.LiveView.Rendered.t()
  def poll_card(assigns) do
    tallies = Polls.tallies(assigns.poll)

    assigns =
      assigns
      |> assign(:slot_count, length(assigns.poll.time_slots))
      |> assign(:participant_count, length(assigns.poll.participants))
      |> assign(:vote_count, total_votes(tallies))
      |> assign(
        :can_link?,
        LinkAccessPolicy.can_link?(assigns.profile, assigns.integration_status)
      )
      |> assign(:share_url, share_url(assigns.profile, assigns.poll))

    ~H"""
    <div class={[
      "card-glass py-4 px-5",
      @selected && "ring-2 ring-turquoise-400"
    ]}>
      <div class="flex items-start gap-3">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 min-w-0">
            <h3 class="text-token-base font-semibold text-tymeslot-800 truncate">
              {@poll.title}
            </h3>
            <.status_badge status={@poll.status} />
          </div>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 mt-2 text-token-xs text-tymeslot-600">
            <span class="flex items-center gap-1">
              <Icons.icon name="hero-clock-mini" class="w-3.5 h-3.5" />
              {dngettext(
                "dashboard_common",
                "%{count} time option",
                "%{count} time options",
                @slot_count,
                count: @slot_count
              )}
            </span>
            <span class="flex items-center gap-1">
              <Icons.icon name="hero-users-mini" class="w-3.5 h-3.5" />
              {dngettext(
                "dashboard_common",
                "%{count} participant",
                "%{count} participants",
                @participant_count,
                count: @participant_count
              )}
            </span>
            <span class="flex items-center gap-1">
              <Icons.icon name="hero-check-circle-mini" class="w-3.5 h-3.5" />
              {dngettext(
                "dashboard_common",
                "%{count} vote",
                "%{count} votes",
                @vote_count,
                count: @vote_count
              )}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-1.5 shrink-0">
          <button
            :if={@can_link?}
            id={"poll-copy-#{@poll.id}"}
            type="button"
            phx-hook="CopyOnClick"
            data-copy-text={@share_url}
            data-copy-feedback={dgettext("dashboard_common", "Poll link copied to clipboard!")}
            class="p-2 rounded-lg bg-white border-2 border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-400 hover:text-turquoise-700 transition-colors"
            title={dgettext("dashboard_common", "Copy poll link to clipboard")}
          >
            <Icons.icon name="hero-clipboard" class="w-4 h-4" />
          </button>
          <button
            :if={!@can_link?}
            type="button"
            aria-disabled="true"
            aria-label={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
            class="p-2 rounded-lg bg-tymeslot-100 text-tymeslot-400 cursor-not-allowed opacity-60"
            title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
          >
            <Icons.icon name="hero-clipboard" class="w-4 h-4" />
          </button>

          <button
            type="button"
            phx-click="select_poll"
            phx-value-id={@poll.id}
            phx-target={@myself}
            class="p-2 rounded-lg text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 transition-colors"
            title={dgettext("dashboard_common", "View results")}
          >
            <Icons.icon name="hero-chart-bar" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "shrink-0 inline-flex items-center px-2 py-0.5 rounded-token-full text-token-xs font-medium",
      status_badge_class(@status)
    ]}>
      {status_label(@status)}
    </span>
    """
  end

  defp status_badge_class(:open), do: "bg-turquoise-100 text-turquoise-700"
  defp status_badge_class(:confirmed), do: "bg-blue-100 text-blue-700"
  defp status_badge_class(:cancelled), do: "bg-tymeslot-100 text-tymeslot-500"

  defp status_label(:open), do: dgettext("dashboard_common", "Open")
  defp status_label(:confirmed), do: dgettext("dashboard_common", "Confirmed")
  defp status_label(:cancelled), do: dgettext("dashboard_common", "Cancelled")

  defp total_votes(tallies) do
    Enum.reduce(tallies, 0, fn {_slot_id, counts}, acc ->
      acc + counts.yes + counts.if_need_be + counts.no
    end)
  end

  defp share_url(%{username: username}, poll)
       when is_binary(username) and username != "" do
    UrlBuilder.build_url("/#{username}/poll/#{poll.token}")
  end

  defp share_url(_profile, _poll), do: nil
end
