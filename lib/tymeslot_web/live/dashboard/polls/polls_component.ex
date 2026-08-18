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
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Meetings
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Polls.SlotHealth
  alias TymeslotWeb.Dashboard.Polls.{CancelPollModal, PollForm, PollList, PollResults}
  alias TymeslotWeb.Live.Shared.Flash

  @task_supervisor Tymeslot.TaskSupervisor
  @health_timeout 6_000

  @impl Phoenix.LiveComponent
  def update(%{poll_created: true}, socket) do
    # The child form persisted a poll: refresh the list and close the form.
    {:ok, socket |> assign(:show_form, false) |> load_polls()}
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
     |> assign_new(:tallies, fn -> %{} end)
     |> assign_new(:slot_health, fn -> %{} end)
     |> assign_new(:slot_health_loading, fn -> false end)
     |> assign_new(:slot_errors, fn -> %{} end)
     |> assign_new(:winning_slot_id, fn -> nil end)
     |> assign_new(:meeting_types, fn -> [] end)
     |> assign_new(:show_cancel_modal, fn -> false end)
     |> assign_new(:expanded_slots, fn -> MapSet.new() end)
     |> assign_new(:editing_details?, fn -> false end)
     |> assign_new(:detail_errors, fn -> %{} end)
     |> load_polls()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <%!-- Header --%>
      <.section_header
        icon="hero-hand-raised"
        title={dgettext("dashboard_common", "Polls")}
        class="mb-4"
      />

      <p class="text-tymeslot-600 mb-6">
        {dgettext(
          "dashboard_common",
          "Find a time that works for everyone. Propose a few slots and let your guests vote."
        )}
      </p>

      <div id="polls-container" class="space-y-6">
        <div :if={!@show_form} class="flex justify-end">
          <button
            type="button"
            phx-click="new_poll"
            phx-target={@myself}
            class="btn btn-primary inline-flex items-center gap-1"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {dgettext("dashboard_common", "New poll")}
          </button>
        </div>

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
          tallies={@tallies}
          slot_health={@slot_health}
          slot_health_loading={@slot_health_loading}
          slot_errors={@slot_errors}
          winning_slot_id={@winning_slot_id}
          expanded_slots={@expanded_slots}
          editing_details?={@editing_details?}
          detail_errors={@detail_errors}
          profile={@profile}
          integration_status={@integration_status}
          meetings_path={~p"/dashboard/meetings"}
          myself={@myself}
        />

        <CancelPollModal.cancel_poll_modal
          :if={@selected_poll}
          open={@show_cancel_modal}
          poll={@selected_poll}
          participant_count={length(@selected_poll.participants)}
          myself={@myself}
        />

        <PollList.poll_list
          polls={@polls}
          profile={@profile}
          integration_status={@integration_status}
          selected_poll_id={@selected_poll_id}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("new_poll", _params, socket) do
    meeting_types =
      socket.assigns.current_user.id
      |> MeetingTypes.get_active_meeting_types()
      |> Enum.reject(& &1.payment_required)

    {:noreply, assign(socket, show_form: true, meeting_types: meeting_types)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_poll_form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_poll", %{"id" => id}, socket) do
    {:noreply, socket |> resubscribe(id) |> open_results(id)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("deselect_poll", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("confirm_slot", %{"slot" => slot_id}, socket) do
    poll_id = socket.assigns.selected_poll_id
    user_id = socket.assigns.current_user.id

    case Confirm.confirm(poll_id, slot_id, user_id) do
      {:ok, _meeting} ->
        Flash.info(
          dgettext("dashboard_common", "Meeting confirmed. Your guests have been notified.")
        )

        {:noreply,
         socket
         |> assign(:slot_errors, %{})
         |> reload_selected(refresh_health: false)
         |> load_polls()}

      {:error, :slot_taken} ->
        # The slot was booked out from under the poll. Keep the poll open, show
        # an inline error, and refresh conflict badges from the calendar.
        socket =
          socket
          |> put_slot_error(slot_id, dgettext("dashboard_common", "This time is no longer free"))
          |> reload_selected(refresh_health: true)

        {:noreply, socket}

      {:error, :not_open} ->
        {:noreply, poll_no_longer_open(socket)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_common", "Couldn't confirm this time. Please try again."))
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("edit_poll_details", _params, socket) do
    {:noreply, assign(socket, editing_details?: true, detail_errors: %{})}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_edit_poll_details", _params, socket) do
    {:noreply, assign(socket, editing_details?: false, detail_errors: %{})}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save_poll_details", %{"poll" => params}, socket) do
    poll_id = socket.assigns.selected_poll_id
    user_id = socket.assigns.current_user.id
    attrs = Map.take(params, ["title", "description"])

    case Polls.update_details(poll_id, user_id, attrs) do
      {:ok, _poll} ->
        Flash.info(dgettext("dashboard_common", "Poll updated"))

        {:noreply,
         socket
         |> assign(editing_details?: false, detail_errors: %{})
         |> reload_selected(refresh_health: false)
         |> load_polls()}

      {:error, :not_open} ->
        {:noreply, socket |> assign(:editing_details?, false) |> poll_no_longer_open()}

      {:error, %Changeset{} = changeset} ->
        {:noreply, assign(socket, :detail_errors, changeset_errors(changeset))}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_common", "Couldn't save this poll. Please try again."))
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
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
  def handle_event("request_cancel_poll", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal, true)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("close_cancel_poll_modal", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal, false)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_poll", _params, socket) do
    poll_id = socket.assigns.selected_poll_id
    socket = assign(socket, :show_cancel_modal, false)
    user_id = socket.assigns.current_user.id

    case Polls.cancel_poll(poll_id, user_id) do
      {:ok, _poll} ->
        Flash.info(dgettext("dashboard_common", "Poll cancelled"))
        {:noreply, socket |> reload_selected(refresh_health: false) |> load_polls()}

      {:error, :not_open} ->
        {:noreply, poll_no_longer_open(socket)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_common", "Couldn't cancel this poll. Please try again."))
        {:noreply, socket}
    end
  end

  # --- Results state ---

  # A confirm/cancel raced a lifecycle change (the poll closed under a stale
  # render). Tell the host plainly and reload so the panel shows the true state.
  defp poll_no_longer_open(socket) do
    Flash.warning(dgettext("dashboard_common", "This poll is no longer open."))
    socket |> reload_selected(refresh_health: false) |> load_polls()
  end

  # Opens the results panel for a poll: loads it, tallies votes and kicks off the
  # advisory calendar conflict check for open polls.
  defp open_results(socket, poll_id) do
    socket
    |> assign(:selected_poll_id, poll_id)
    |> assign(:slot_errors, %{})
    |> reload_selected(refresh_health: true)
  end

  defp reload_selected(socket, opts) do
    user_id = socket.assigns.current_user.id

    case Polls.get_poll_for_host(socket.assigns.selected_poll_id, user_id) do
      {:ok, poll} ->
        socket
        |> assign(:selected_poll, poll)
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

    Task.Supervisor.start_child(@task_supervisor, fn ->
      send(parent, {:poll_slot_health, poll.id, bounded_slot_health(poll)})
    end)

    assign(socket, slot_health: %{}, slot_health_loading: true)
  end

  defp bounded_slot_health(poll) do
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> SlotHealth.check(poll) end)

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

  defp changeset_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end

  defp put_slot_error(socket, slot_id, message) do
    assign(socket, :slot_errors, Map.put(socket.assigns.slot_errors, slot_id, message))
  end

  defp clear_selection(socket) do
    if prev = socket.assigns[:selected_poll_id], do: Polls.unsubscribe(prev)

    assign(socket,
      selected_poll_id: nil,
      selected_poll: nil,
      tallies: %{},
      slot_health: %{},
      slot_health_loading: false,
      slot_errors: %{},
      winning_slot_id: nil,
      show_cancel_modal: false,
      expanded_slots: MapSet.new(),
      editing_details?: false,
      detail_errors: %{}
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

  defp load_polls(socket) do
    assign(socket, :polls, Polls.list_polls(socket.assigns.current_user.id))
  end
end
