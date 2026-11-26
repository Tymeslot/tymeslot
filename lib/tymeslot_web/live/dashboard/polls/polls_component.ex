defmodule TymeslotWeb.Dashboard.Polls.PollsComponent do
  @moduledoc """
  Dashboard component for meeting polls.

  Meeting polls let a host propose several candidate slots and invite guests to
  vote on the times that suit them, then confirm a booking from the winning slot.
  This module is the parent component for the Polls section: it owns the list of
  the host's polls, the show/hide state of the create form, and the selected
  poll's live results panel. Selecting a draft opens it in the create form
  instead, which saves and publishes it; it has no results yet. It delegates rendering to `PollList` (the cards),
  `PollForm` (the create flow), and `PollResults` (the results panel), reloads
  the list when the form reports a new poll, and drives the confirm/cancel
  actions plus live vote updates for the selected poll. The selected poll's
  state is kept on the socket by `SelectedPoll`, and the confirm refusals are
  worded by `ConfirmSlotModal.refusal/1`.

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
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Polls.Invitations
  alias Tymeslot.Scheduling.LinkAccessPolicy

  alias TymeslotWeb.Dashboard.Polls.{
    CancelPollModal,
    ConfirmSlotModal,
    DeletePollModal,
    LeavePollEditorModal,
    PollForm,
    PollInvite,
    PollList,
    PollResults,
    SelectedPoll
  }

  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.PollDeadlineTimer

  require Logger

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, ModalHook.mount_modal(socket, delete: false, cancel: false, leave_editor: false)}
  end

  @impl Phoenix.LiveComponent
  def update(%{poll_created: true}, socket) do
    # The child form persisted a poll or a draft: refresh the list and close
    # the form, letting go of the draft it held.
    {:ok, socket |> close_form() |> load_polls()}
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
            id={
              if draft = SelectedPoll.draft(@selected_poll),
                do: "poll-draft-#{draft.id}",
                else: "poll-form"
            }
            draft={SelectedPoll.draft(@selected_poll)}
            current_user={@current_user}
            profile={@profile}
            meeting_types={@meeting_types}
            time_format={@time_format}
            parent_id={@id}
            parent_myself={@myself}
          />

          <PollResults.results_panel
            :if={@selected_poll && !SelectedPoll.draft(@selected_poll)}
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

          <LeavePollEditorModal.leave_poll_editor_modal
            open={@show_leave_editor_modal}
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
      do:
        {:noreply,
         socket
         |> release_draft()
         |> assign(show_form: true, meeting_types: poll_meeting_types(socket))},
      else: {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_poll_form", _params, socket) do
    {:noreply, close_form(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_poll", %{"id" => id}, socket) do
    case UUID.cast(id) do
      {:ok, id} ->
        {:noreply,
         socket
         |> release_draft()
         |> SelectedPoll.resubscribe(id)
         |> SelectedPoll.open(id)
         |> reload_selected(refresh_health: true)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("deselect_poll", _params, socket) do
    {:noreply, SelectedPoll.clear(socket)}
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

      {:error, reason} ->
        {:noreply, refused(socket, slot_id, reason)}
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

  # A link was followed with the editor's changes unsaved (its
  # `UnsavedChanges` hook holds the link until the host answers).
  def handle_event("leave", _params, socket),
    do: {:noreply, ModalHook.show_modal(socket, :leave_editor)}

  def handle_event("close_leave_poll_editor_modal", _params, socket),
    do: {:noreply, ModalHook.hide_modal(socket, :leave_editor)}

  def handle_event("leave_poll_editor", _params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:leave_editor)
     |> push_event("unsaved:proceed", %{})}
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
        Flash.info(
          if SelectedPoll.draft(socket.assigns.selected_poll),
            do: dgettext("dashboard_polls", "Draft deleted"),
            else: dgettext("dashboard_polls", "Poll deleted")
        )

        {:noreply, socket |> release_draft() |> SelectedPoll.clear() |> load_polls()}

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

  @impl Phoenix.LiveComponent
  def handle_async(:slot_health, {:ok, {poll_id, health}}, socket) do
    # Applied only if the poll is still the one on screen (the host may have
    # moved on while it ran).
    if socket.assigns[:selected_poll_id] == poll_id do
      {:noreply, assign(socket, slot_health: health, slot_health_loading: false)}
    else
      {:noreply, socket}
    end
  end

  # The check never raises; an exit is the task cut short, and the slots are
  # shown without badges, as they are when the calendar fetch fails.
  def handle_async(:slot_health, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, slot_health: %{}, slot_health_loading: false)}

  # --- Results state ---

  # A refused confirmation, answered as `ConfirmSlotModal.refusal/1` says.
  defp refused(socket, slot_id, reason) do
    case ConfirmSlotModal.refusal(reason) do
      {:slot_error, message} ->
        socket |> SelectedPoll.put_error(slot_id, message) |> refresh_taken_slot(reason)

      {:flash, level, message} ->
        Flash.put_flash(socket, level, message)

      :no_longer_open ->
        poll_no_longer_open(socket)

      {:unexpected, message} ->
        Logger.warning("Poll confirmation failed",
          poll_id: socket.assigns.selected_poll_id,
          reason: LogFormat.reason(reason)
        )

        Flash.put_flash(socket, :error, message)
    end
  end

  # The slot was booked out from under the poll, perhaps by a booking the host
  # cannot see (one still unverified or unpaid), so the copy names no meeting.
  # The poll stays open and its conflict badges are refreshed.
  defp refresh_taken_slot(socket, :slot_taken), do: reload_selected(socket, refresh_health: true)
  defp refresh_taken_slot(socket, _reason), do: socket

  # A confirm/cancel raced a lifecycle change (the poll closed under a stale
  # render). Tell the host plainly and reload so the panel shows the true state.
  defp poll_no_longer_open(socket) do
    Flash.warning(dgettext("dashboard_polls", "This poll is no longer open."))
    reload_all(socket, refresh_health: false)
  end

  # The form holds a draft as the selected poll, so closing it lets go of the
  # draft; a published poll's results stay open.
  defp close_form(socket), do: socket |> assign(:show_form, false) |> release_draft()

  # Lets go of a draft open in the form, closing it; anything else selected
  # stays.
  defp release_draft(socket) do
    if SelectedPoll.draft(socket.assigns.selected_poll),
      do: socket |> SelectedPoll.clear() |> assign(:show_form, false),
      else: socket
  end

  defp poll_meeting_types(socket),
    do: Polls.meeting_types_for_poll(socket.assigns.current_user.id)

  defp parse_invitees(text) do
    case Invitations.parse(text) do
      {:ok, []} -> {:error, :no_invitees}
      result -> result
    end
  end

  # The composition points: the deadline is judged last, once the selected
  # poll and the list it stands in for are both loaded.
  defp reload_selected(socket, opts), do: socket |> SelectedPoll.fetch(opts) |> sync_deadline()

  defp load_polls(socket), do: socket |> fetch_polls() |> sync_deadline()

  # Both reloads, judged once against the result.
  defp reload_all(socket, opts),
    do: socket |> SelectedPoll.fetch(opts) |> fetch_polls() |> sync_deadline()

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
