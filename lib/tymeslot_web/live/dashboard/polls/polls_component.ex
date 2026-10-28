defmodule TymeslotWeb.Dashboard.Polls.PollsComponent do
  @moduledoc """
  Dashboard component for meeting polls.

  Meeting polls let a host propose several candidate slots and invite guests to
  vote on the times that suit them, then confirm a booking from the winning slot.
  This module is the parent component for the Polls section: it owns the list of
  the host's polls, the show/hide state of the create form, and the selected
  poll's live results panel. It delegates rendering to `PollList` (the cards),
  `PollForm` (the create flow), and `PollResults` (the results panel), reloads
  the list when the form reports a new poll, and drives the confirm/cancel
  actions plus live vote updates for the selected poll.

  Live updates arrive as `{:poll_updated, poll_id}` PubSub messages. Because a
  `LiveComponent` shares the parent LiveView's process, the subscription lives
  here (via `Polls.subscribe/1`) but the message is delivered to
  `DashboardLive.handle_info/2`, which routes it back with
  `send_update(__MODULE__, poll_updated: poll_id)`.

  Voting on an open poll closes at its deadline without any write, so nothing
  is broadcast then. After every load the component works out the next
  deadline among the polls on screen and sends it to the LiveView, which owns
  the `PollDeadlineTimer` (so it can cancel it when the host leaves the
  section). The timer fires at the LiveView, which routes it back as
  `poll_deadline_reached: poll_id`, and the component reloads. Each load
  judges which polls are open once, into `open_poll_ids`; the children
  render from that set, so they re-render only when a poll actually opens or
  closes, not on every load.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.UUID
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Meetings
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Polls.Invitations
  alias Tymeslot.Polls.SlotHealth
  alias Tymeslot.Scheduling.LinkAccessPolicy

  alias TymeslotWeb.Dashboard.Polls.{
    CancelPollModal,
    ConfirmSlotModal,
    DeletePollModal,
    PollForm,
    PollInvite,
    PollList,
    PollResults
  }

  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.PollDeadlineTimer

  require Logger

  @task_supervisor Tymeslot.TaskSupervisor
  @health_timeout 6_000

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, ModalHook.mount_modal(socket, delete: false, cancel: false)}
  end

  @impl Phoenix.LiveComponent
  def update(%{poll_created: true}, socket) do
    # The child form persisted a poll: refresh the list and close the form.
    {:ok, socket |> assign(:show_form, false) |> load_polls()}
  end

  def update(%{poll_edited: true}, socket) do
    # The editor saved: close it and show the poll as it now stands.
    {:ok,
     socket
     |> assign(:editing_details?, false)
     |> reload_all(refresh_health: true)}
  end

  def update(%{poll_updated: poll_id}, socket) do
    # A live vote (or lifecycle change) arrived for a poll. Refresh only when it
    # is the one currently on screen. Slot health is not re-fetched here — it
    # hits the calendar, and votes never change slot/calendar conflicts.
    if socket.assigns[:selected_poll_id] == poll_id do
      {:ok, reload_selected(socket, refresh_health: false)}
    else
      {:ok, socket}
    end
  end

  def update(%{poll_deadline_reached: _poll_id}, socket) do
    # Some poll on screen reached its deadline, or the timer woke early to
    # re-arm a long wait. Reloading derives "voting open" afresh from the
    # stored deadline (the host may have moved it) and arms the next timer.
    {:ok, reload_all(socket, refresh_health: false)}
  end

  def update(%{poll_slot_health: {poll_id, health}}, socket) do
    # The asynchronous slot-health check finished. Apply it only if the poll is
    # still the one on screen (the host may have moved on while it ran).
    if socket.assigns[:selected_poll_id] == poll_id do
      {:ok, assign(socket, slot_health: health, slot_health_loading: false)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show_form, fn -> false end)
     |> assign_new(:selected_poll_id, fn -> nil end)
     |> assign_new(:selected_poll, fn -> nil end)
     |> assign_new(:unconfirmed_count, fn -> 0 end)
     |> assign_new(:invite_value, fn -> "" end)
     |> assign_new(:invite_error, fn -> nil end)
     |> assign_new(:tallies, fn -> %{} end)
     |> assign_new(:slot_health, fn -> %{} end)
     |> assign_new(:slot_health_loading, fn -> false end)
     |> assign_new(:slot_errors, fn -> %{} end)
     |> assign_new(:winning_slot_id, fn -> nil end)
     |> assign_new(:meeting_types, fn -> [] end)
     |> assign_new(:confirming_slot, fn -> nil end)
     |> assign_new(:expanded_slots, fn -> MapSet.new() end)
     |> assign_new(:editing_details?, fn -> false end)
     |> load_polls()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <.dashboard_page icon="hero-hand-raised" title={dgettext("dashboard_polls", "Polls")}>
        <%!-- With no polls yet, the empty state below carries the action, and
              without a calendar there is none: `PollList` asks for one. --%>
        <:actions :if={
          !@show_form and @polls != [] and LinkAccessPolicy.has_calendar?(@integration_status)
        }>
          <PollList.new_poll_button myself={@myself} data-testid="new-poll" />
        </:actions>
        <p class="text-tymeslot-600 mb-6">
          {dgettext(
            "dashboard_polls",
            "Find a time that works for everyone. Propose a few slots and let your guests vote."
          )}
        </p>

        <div id="polls-container" class="space-y-6">
          <.live_component
            :if={@show_form}
            module={PollForm}
            id="poll-form"
            current_user={@current_user}
            profile={@profile}
            meeting_types={@meeting_types}
            parent_id={@id}
            parent_myself={@myself}
          />

          <PollResults.results_panel
            :if={@selected_poll}
            poll={@selected_poll}
            unconfirmed_count={@unconfirmed_count}
            invite_value={@invite_value}
            invite_error={@invite_error}
            tallies={@tallies}
            slot_health={@slot_health}
            slot_health_loading={@slot_health_loading}
            slot_errors={@slot_errors}
            winning_slot_id={@winning_slot_id}
            expanded_slots={@expanded_slots}
            editing_details?={@editing_details?}
            meeting_types={@meeting_types}
            user_id={@current_user.id}
            parent_id={@id}
            profile={@profile}
            integration_status={@integration_status}
            meetings_path={~p"/dashboard/meetings"}
            time_format={@time_format}
            voting_open?={MapSet.member?(@open_poll_ids, @selected_poll.id)}
            myself={@myself}
          />

          <DeletePollModal.delete_poll_modal
            open={@show_delete_modal}
            poll={@selected_poll}
            myself={@myself}
          />

          <ConfirmSlotModal.confirm_slot_modal
            poll={@selected_poll}
            slot={@confirming_slot}
            time_format={@time_format}
            conflict?={@confirming_slot != nil and @slot_health[@confirming_slot.id] == :conflict}
            myself={@myself}
          />

          <CancelPollModal.cancel_poll_modal
            :if={@selected_poll}
            open={@show_cancel_modal}
            poll={@selected_poll}
            participant_count={Enum.count(@selected_poll.participants, & &1.voted_at)}
            myself={@myself}
          />

          <PollList.poll_list
            :if={!@show_form or @polls != []}
            polls={@polls}
            profile={@profile}
            integration_status={@integration_status}
            selected_poll_id={@selected_poll_id}
            open_poll_ids={@open_poll_ids}
            myself={@myself}
          />
        </div>
      </.dashboard_page>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("new_poll", _params, socket) do
    if LinkAccessPolicy.has_calendar?(socket.assigns.integration_status),
      do: {:noreply, assign(socket, show_form: true, meeting_types: poll_meeting_types(socket))},
      else: {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_poll_form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_poll", %{"id" => id}, socket) do
    case UUID.cast(id) do
      {:ok, id} -> {:noreply, socket |> resubscribe(id) |> open_results(id)}
      :error -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("deselect_poll", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("request_confirm_slot", %{"slot" => slot_id}, socket) do
    slots = if poll = socket.assigns.selected_poll, do: poll.time_slots, else: []
    {:noreply, assign(socket, :confirming_slot, Enum.find(slots, &(&1.id == slot_id)))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("close_confirm_slot_modal", _params, socket) do
    {:noreply, assign(socket, :confirming_slot, nil)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("confirm_slot", %{"slot" => slot_id}, socket) do
    socket = assign(socket, :confirming_slot, nil)
    poll_id = socket.assigns.selected_poll_id
    user_id = socket.assigns.current_user.id

    case Confirm.confirm(poll_id, slot_id, user_id) do
      {:ok, _meeting} ->
        Flash.info(
          dgettext("dashboard_polls", "Meeting confirmed. Your guests have been notified.")
        )

        {:noreply,
         socket
         |> assign(:slot_errors, %{})
         |> reload_all(refresh_health: false)}

      {:error, :slot_taken} ->
        # The slot was booked out from under the poll. Keep the poll open, show
        # an inline error, and refresh conflict badges from the calendar.
        socket =
          socket
          |> put_slot_error(slot_id, dgettext("dashboard_polls", "This time is no longer free"))
          |> reload_selected(refresh_health: true)

        {:noreply, socket}

      {:error, :time_off} ->
        {:noreply,
         put_slot_error(
           socket,
           slot_id,
           dgettext(
             "dashboard_polls",
             "This time falls within your time off. Change or remove the time off to confirm it."
           )
         )}

      {:error, :slot_in_past} ->
        {:noreply,
         put_slot_error(
           socket,
           slot_id,
           dgettext("dashboard_polls", "This time has already begun.")
         )}

      # The host's own entry is not counted (`Confirm`), so a poll only they
      # answered has nobody to invite.
      {:error, :no_participants} ->
        Flash.error(
          dgettext(
            "dashboard_polls",
            "Nobody but you has joined this poll yet, so there is nobody to invite."
          )
        )

        {:noreply, socket}

      {:error, reason} when reason in [:not_open, :not_found] ->
        {:noreply, poll_no_longer_open(socket)}

      {:error, reason} ->
        Logger.warning("Poll confirmation failed",
          poll_id: poll_id,
          reason: LogFormat.reason(reason)
        )

        Flash.error(dgettext("dashboard_polls", "Couldn't confirm this time. Please try again."))
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("edit_poll_details", _params, socket) do
    {:noreply, assign(socket, editing_details?: true, meeting_types: poll_meeting_types(socket))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_edit_poll_details", _params, socket) do
    {:noreply, assign(socket, editing_details?: false)}
  end

  def handle_event("invite_participants", %{"invite" => %{"emails" => text}}, socket) do
    poll_id = socket.assigns.selected_poll_id
    user_id = socket.assigns.current_user.id

    with {:ok, [_entry | _rest] = entries} <- parse_invitees(text),
         {:ok, result} <- Polls.invite_participants(poll_id, user_id, entries) do
      Flash.info(PollInvite.invited_message(result))

      {:noreply,
       socket
       |> assign(invite_value: "", invite_error: nil)
       |> reload_all(refresh_health: false)}
    else
      {:error, :not_open} ->
        {:noreply, poll_no_longer_open(socket)}

      {:error, reason} ->
        {:noreply,
         assign(socket, invite_value: text, invite_error: PollInvite.error_message(reason))}
    end
  end

  def handle_event("toggle_slot_voters", %{"slot" => slot_id}, socket) do
    # Expansion is per slot and additive: a host comparing two close times wants
    # both breakdowns open at once.
    expanded = socket.assigns.expanded_slots

    toggled =
      if MapSet.member?(expanded, slot_id) do
        MapSet.delete(expanded, slot_id)
      else
        MapSet.put(expanded, slot_id)
      end

    {:noreply, assign(socket, :expanded_slots, toggled)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("request_delete_poll", _params, socket) do
    {:noreply, ModalHook.show_modal(socket, :delete)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("close_delete_poll_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_poll", _params, socket) do
    poll_id = socket.assigns.selected_poll_id

    case Polls.delete_poll(poll_id, socket.assigns.current_user.id) do
      :ok ->
        Flash.info(dgettext("dashboard_polls", "Poll deleted"))
        {:noreply, socket |> clear_selection() |> load_polls()}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_polls", "Couldn't delete this poll. Please try again."))

        {:noreply,
         socket |> ModalHook.hide_modal(:delete) |> reload_selected(refresh_health: false)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("request_cancel_poll", _params, socket) do
    {:noreply, ModalHook.show_modal(socket, :cancel)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("close_cancel_poll_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :cancel)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_poll", _params, socket) do
    poll_id = socket.assigns.selected_poll_id
    socket = ModalHook.hide_modal(socket, :cancel)
    user_id = socket.assigns.current_user.id

    case Polls.cancel_poll(poll_id, user_id) do
      {:ok, _poll} ->
        Flash.info(dgettext("dashboard_polls", "Poll cancelled"))
        {:noreply, reload_all(socket, refresh_health: false)}

      {:error, :not_open} ->
        {:noreply, poll_no_longer_open(socket)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_polls", "Couldn't cancel this poll. Please try again."))
        {:noreply, socket}
    end
  end

  # --- Results state ---

  # A confirm/cancel raced a lifecycle change (the poll closed under a stale
  # render). Tell the host plainly and reload so the panel shows the true state.
  defp poll_no_longer_open(socket) do
    Flash.warning(dgettext("dashboard_polls", "This poll is no longer open."))
    reload_all(socket, refresh_health: false)
  end

  # Opens the results panel for a poll: loads it, tallies votes and kicks off the
  # advisory calendar conflict check for open polls.
  defp open_results(socket, poll_id) do
    socket
    |> assign(:selected_poll_id, poll_id)
    |> assign(slot_errors: %{}, invite_value: "", invite_error: nil)
    |> reload_selected(refresh_health: true)
  end

  defp poll_meeting_types(socket),
    do: Polls.meeting_types_for_poll(socket.assigns.current_user.id)

  defp parse_invitees(text) do
    case Invitations.parse(text) do
      {:ok, []} -> {:error, :no_invitees}
      result -> result
    end
  end

  defp reload_selected(socket, opts), do: socket |> fetch_selected(opts) |> sync_deadline()

  defp load_polls(socket), do: socket |> fetch_polls() |> sync_deadline()

  # Both reloads, judged once against the result.
  defp reload_all(socket, opts),
    do: socket |> fetch_selected(opts) |> fetch_polls() |> sync_deadline()

  defp fetch_selected(%{assigns: %{selected_poll_id: nil}} = socket, _opts), do: socket

  defp fetch_selected(socket, opts) do
    user_id = socket.assigns.current_user.id

    case Polls.get_poll_for_host(socket.assigns.selected_poll_id, user_id) do
      {:ok, poll} ->
        socket
        |> assign(:selected_poll, poll)
        |> assign(:unconfirmed_count, Polls.count_unconfirmed(poll))
        |> assign(:tallies, Polls.tallies(poll))
        |> assign_winning_slot(poll)
        |> sync_slot_health(poll, opts)

      {:error, :not_found} ->
        clear_selection(socket)
    end
  end

  # Slot health is meaningful only while voting is open. A confirmed poll's own
  # minted meeting sits on the host calendar, so checking it would flag the
  # winning slot as a conflict against itself; a cancelled poll needs no badges.
  defp sync_slot_health(socket, %{status: :open} = poll, opts) do
    if Keyword.get(opts, :refresh_health, false) do
      request_slot_health(socket, poll)
    else
      socket
    end
  end

  defp sync_slot_health(socket, _poll, _opts) do
    assign(socket, slot_health: %{}, slot_health_loading: false)
  end

  # Runs the advisory calendar conflict check off the LiveView process so a slow
  # provider never freezes the dashboard. The panel renders immediately in a
  # "checking" state; the result arrives as a `{:poll_slot_health, …}` message
  # routed back through `send_update/3`. The inner supervised task bounds the
  # calendar fetch and degrades to all-`:ok` on timeout or failure.
  defp request_slot_health(socket, poll) do
    parent = self()

    Tasks.start_child(@task_supervisor, fn ->
      send(parent, {:poll_slot_health, poll.id, bounded_slot_health(poll)})
    end)

    assign(socket, slot_health: %{}, slot_health_loading: true)
  end

  defp bounded_slot_health(poll) do
    task = Tasks.async_nolink(@task_supervisor, fn -> SlotHealth.check(poll) end)

    case Task.yield(task, @health_timeout) || Task.shutdown(task) do
      {:ok, health} -> health
      _timeout_or_crash -> Map.new(poll.time_slots, &{&1.id, :ok})
    end
  end

  defp assign_winning_slot(socket, %{status: :confirmed, confirmed_meeting_id: meeting_id} = poll)
       when is_binary(meeting_id) do
    winning_id =
      case Meetings.get_meeting(meeting_id) do
        {:ok, meeting} -> winning_slot_id(poll.time_slots, meeting.start_time)
        {:error, _reason} -> nil
      end

    assign(socket, :winning_slot_id, winning_id)
  end

  defp assign_winning_slot(socket, _poll), do: assign(socket, :winning_slot_id, nil)

  defp winning_slot_id(time_slots, start_time) do
    Enum.find_value(time_slots, fn slot ->
      DateTime.compare(slot.start_time, start_time) == :eq && slot.id
    end)
  end

  defp put_slot_error(socket, slot_id, message) do
    assign(socket, :slot_errors, Map.put(socket.assigns.slot_errors, slot_id, message))
  end

  defp clear_selection(socket) do
    if prev = socket.assigns[:selected_poll_id], do: Polls.unsubscribe(prev)

    socket
    |> ModalHook.hide_modal(:delete)
    |> ModalHook.hide_modal(:cancel)
    |> assign(
      selected_poll_id: nil,
      selected_poll: nil,
      tallies: %{},
      slot_health: %{},
      slot_health_loading: false,
      slot_errors: %{},
      winning_slot_id: nil,
      confirming_slot: nil,
      expanded_slots: MapSet.new(),
      editing_details?: false,
      invite_value: "",
      invite_error: nil
    )
  end

  # Subscribes to the newly selected poll, dropping the previous subscription so
  # a re-selection never accumulates duplicate PubSub deliveries.
  defp resubscribe(socket, id) do
    if socket.assigns[:selected_poll_id] == id do
      socket
    else
      if prev = socket.assigns[:selected_poll_id], do: Polls.unsubscribe(prev)
      Polls.subscribe(id)
      socket
    end
  end

  defp fetch_polls(socket),
    do: assign(socket, :polls, Polls.list_polls(socket.assigns.current_user.id))

  # Judges once which polls on screen take votes, and tells the LiveView,
  # which owns the timer, the next deadline among them. A connected socket
  # only: the static render's process ends with the response.
  defp sync_deadline(socket) do
    now = Clock.utc_now()
    polls = polls_on_screen(socket.assigns)

    if connected?(socket),
      do: send(self(), {:poll_deadline_next, PollDeadlineTimer.next_deadline(polls, now)})

    open_ids = for poll <- polls, Polls.voting_open?(poll, now), into: MapSet.new(), do: poll.id
    assign(socket, :open_poll_ids, open_ids)
  end

  # The selected poll stands in for its list copy, which a live vote does not
  # refresh, so a deadline the host moved is read from the fresher one.
  defp polls_on_screen(%{selected_poll: %{id: id} = selected} = assigns),
    do: [selected | Enum.reject(assigns[:polls] || [], &(&1.id == id))]

  defp polls_on_screen(assigns), do: assigns[:polls] || []
end
