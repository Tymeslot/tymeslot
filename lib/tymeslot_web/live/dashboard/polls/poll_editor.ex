defmodule TymeslotWeb.Dashboard.Polls.PollEditor do
  @moduledoc """
  LiveComponent for editing an open poll from its results panel.

  Covers what can change while people vote (see `Tymeslot.Polls.Editing`):
  the title and description, whether the host is emailed about new votes, who
  can vote (switching to invited people only withdraws pending link requests,
  which the editor warns about with the count it reads when the choice is made), the
  voting deadline (moved, removed, or set again to reopen voting), the
  reminders before it, and new candidate times. Everything is saved at once.
  The participant list beside it (`PollParticipantList`) takes someone off
  the poll or sends them their link again.

  The editor keeps its own state across re-renders: a vote arriving while the
  host edits refreshes the poll it is given, not what the host has typed.
  On a save it tells the owning `PollsComponent` (`poll_edited: true`), which
  closes the editor and reloads the poll.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollSchema

  alias TymeslotWeb.Dashboard.Polls.{
    CandidateTimes,
    LocalTime,
    PollAccess,
    PollFormErrors,
    PollParticipantList,
    PollReminders,
    PollsComponent
  }

  alias TymeslotWeb.Live.Shared.Flash

  import PollFormErrors, only: [error_list: 2]

  @reminder_events PollReminders.Events.all()

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    socket = if socket.assigns[:initialized?], do: socket, else: init(socket, assigns.poll)

    # Read on every update: someone invited while the host edits brings
    # the reminders with them.
    {:ok, assign(socket, :invited?, Polls.has_invitees?(socket.assigns.poll))}
  end

  defp init(socket, poll) do
    assign(socket,
      initialized?: true,
      title: poll.title,
      description: poll.description || "",
      deadline: LocalTime.to_input(poll.deadline_at, poll.timezone),
      notify_on_vote: poll.notify_on_vote,
      access: PollAccess.value(poll.invite_only),
      unconfirmed_count: 0,
      meeting_type_id: poll.meeting_type_id,
      kept_meeting_type:
        kept_meeting_type(poll, socket.assigns.meeting_types, socket.assigns.user_id),
      new_times: [],
      time_counter: 0,
      reminder_picker: PollReminders.new(PollSchema.reminders(poll)),
      errors: %{}
    )
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-4" data-testid="poll-editor">
      <form
        id={"poll-details-form-#{@poll.id}"}
        phx-submit="save"
        phx-change="change"
        phx-target={@myself}
        class="space-y-4"
        data-testid="poll-details-form"
        novalidate
      >
        <.input
          type="text"
          name="poll[title]"
          label={dgettext("dashboard_polls", "Title")}
          value={@title}
          required
          errors={error_list(@errors, :title)}
          icon="hero-hand-raised"
        />

        <.input
          type="textarea"
          name="poll[description]"
          label={dgettext("dashboard_polls", "Description (optional)")}
          value={@description}
          placeholder={dgettext("dashboard_polls", "Add any context for your guests")}
          errors={error_list(@errors, :description)}
        />

        <.input
          type="datetime-local"
          name="poll[deadline]"
          label={dgettext("dashboard_polls", "Voting deadline (optional)")}
          value={@deadline}
          errors={error_list(@errors, :deadline_at)}
        >
          <:description>
            {dgettext(
              "dashboard_polls",
              "Move it, clear it, or set it again after it has passed to reopen voting. Times in %{timezone}.",
              timezone: @poll.timezone
            )}
          </:description>
        </.input>

        <.input
          type="select"
          name="poll[meeting_type_id]"
          label={dgettext("dashboard_polls", "Meeting type (optional)")}
          value={@meeting_type_id}
          prompt={dgettext("dashboard_polls", "No meeting type")}
          options={meeting_type_options(@meeting_types, @kept_meeting_type)}
          errors={error_list(@errors, :meeting_type_id)}
        >
          <:description>
            {dgettext(
              "dashboard_polls",
              "Its calendar and video provider are used for the meeting when you confirm a time. The poll's times and title stay as they are."
            )}
            <span
              :if={kept_selected?(@kept_meeting_type, @meeting_type_id)}
              class="mt-1 block"
              data-testid="poll-kept-meeting-type"
            >
              {dgettext(
                "dashboard_polls",
                "%{name} is switched off or takes payment, so new polls can't use it. This poll keeps it until you choose another.",
                name: @kept_meeting_type.name
              )}
            </span>
          </:description>
        </.input>

        <PollAccess.access_input
          id={"poll-access-#{@poll.id}"}
          name="poll[access]"
          value={@access}
          hint={withdraw_hint(@poll, @access, @unconfirmed_count)}
        />

        <div class="space-y-2" data-testid="poll-new-times">
          <p class="text-token-sm font-medium text-tymeslot-700">
            {dgettext("dashboard_polls", "Add times")}
          </p>
          <p class="text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_polls",
              "Existing times stay as they are. Everyone who has voted is emailed about the new ones."
            )}
          </p>
          <div :for={time <- @new_times} class="flex items-center gap-2">
            <div class="flex-1">
              <.input
                type="datetime-local"
                name={"poll[new_times][#{time.key}]"}
                value={time.value}
                aria-label={dgettext("dashboard_polls", "New time")}
              />
            </div>
            <.icon_button
              icon="hero-x-mark"
              label={dgettext("dashboard_polls", "Remove time")}
              phx-click="remove_time"
              phx-value-key={time.key}
              phx-target={@myself}
            />
          </div>
          <.action_button
            variant={:secondary}
            size={:sm}
            icon="hero-plus"
            phx-click="add_time"
            phx-target={@myself}
          >
            {dgettext("dashboard_polls", "Add time")}
          </.action_button>
          <p :for={error <- error_list(@errors, :new_times)} class="form-error">{error}</p>
        </div>

        <.input
          type="checkbox"
          id={"poll-notify-on-vote-#{@poll.id}"}
          name="poll[notify_on_vote]"
          value={@notify_on_vote}
          label={dgettext("dashboard_polls", "Email me about new votes")}
        />
        <p :for={error <- error_list(@errors, :base)} class="form-error">{error}</p>
      </form>

      <PollReminders.reminders_form
        :if={@invited?}
        id={"poll-edit-reminders-#{@poll.id}"}
        state={@reminder_picker}
        myself={@myself}
      />
      <p :for={error <- error_list(@errors, :reminder_config)} class="form-error">{error}</p>

      <.live_component
        module={PollParticipantList}
        id={"poll-participant-list-#{@poll.id}"}
        poll={@poll}
        user_id={@user_id}
        parent_id={@parent_id}
        voting_open?={@voting_open?}
      />

      <div class="flex justify-end gap-2">
        <.action_button
          variant={:secondary}
          size={:sm}
          phx-click="cancel_edit_poll_details"
          phx-target={@parent_myself}
        >
          {dgettext("dashboard_polls", "Cancel")}
        </.action_button>
        <.action_button type="submit" size={:sm} form={"poll-details-form-#{@poll.id}"}>
          {dgettext("dashboard_polls", "Save changes")}
        </.action_button>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event(event, params, socket) when event in @reminder_events do
    {:noreply,
     assign(
       socket,
       :reminder_picker,
       PollReminders.apply_event(event, socket.assigns.reminder_picker, params)
     )}
  end

  def handle_event("change", %{"poll" => params}, socket) do
    access = valid_access(Map.get(params, "access"), socket.assigns.access)

    {:noreply,
     socket
     |> count_pending_requests(access, socket.assigns.access)
     |> assign(
       title: Map.get(params, "title", socket.assigns.title),
       description: Map.get(params, "description", socket.assigns.description),
       deadline: Map.get(params, "deadline", socket.assigns.deadline),
       notify_on_vote: Map.get(params, "notify_on_vote", "false") == "true",
       access: access,
       meeting_type_id: parse_id(Map.get(params, "meeting_type_id")),
       new_times:
         CandidateTimes.merge(socket.assigns.new_times, Map.get(params, "new_times", %{}))
     )}
  end

  def handle_event("add_time", _params, socket) do
    {new_times, counter} =
      CandidateTimes.add(socket.assigns.new_times, socket.assigns.time_counter)

    {:noreply, assign(socket, new_times: new_times, time_counter: counter)}
  end

  def handle_event("remove_time", %{"key" => key}, socket) do
    case CandidateTimes.remove(socket.assigns.new_times, key) do
      {:ok, new_times, _key} -> {:noreply, assign(socket, :new_times, new_times)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("save", %{"poll" => params}, %{assigns: %{invited?: false}} = socket),
    # The picker is hidden without invitees: whatever it holds unsaved must
    # not stop the save through an error nobody can see.
    do: save(socket, params)

  def handle_event("save", %{"poll" => params}, socket) do
    case PollReminders.commit_pending(socket.assigns.reminder_picker) do
      {:ok, picker} -> save(assign(socket, :reminder_picker, picker), params)
      {:error, rejected} -> {:noreply, assign(socket, :reminder_picker, rejected)}
    end
  end

  defp save(socket, params) do
    %{poll: poll, user_id: user_id} = socket.assigns

    attrs = save_attrs(params, socket.assigns)

    new_starts =
      params
      |> Map.get("new_times", %{})
      |> Map.values()
      |> Enum.map(&LocalTime.to_utc(&1, poll.timezone))
      |> Enum.reject(&is_nil/1)

    case Polls.update_details(poll.id, user_id, attrs, new_starts) do
      {:ok, _poll} ->
        Flash.info(dgettext("dashboard_polls", "Poll updated"))
        send_update(PollsComponent, id: socket.assigns.parent_id, poll_edited: true)
        {:noreply, socket}

      {:error, :not_open} ->
        Flash.warning(dgettext("dashboard_polls", "This poll is no longer open."))
        send_update(PollsComponent, id: socket.assigns.parent_id, poll_edited: true)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :errors, errors_for(reason))}
    end
  end

  defp save_attrs(params, %{poll: poll} = assigns) do
    Map.merge(
      %{
        "title" => Map.get(params, "title"),
        "description" => Map.get(params, "description"),
        "notify_on_vote" => Map.get(params, "notify_on_vote", "false"),
        "invite_only" => PollAccess.invite_only?(Map.get(params, "access", assigns.access)),
        "deadline_at" => LocalTime.to_utc(Map.get(params, "deadline"), poll.timezone),
        "reminder_config" => PollReminders.to_config(assigns.reminder_picker)
      },
      meeting_type_change(params, poll)
    )
  end

  defp parse_id(value) when value in [nil, ""], do: nil

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _invalid -> nil
    end
  end

  defp parse_id(value), do: value

  # Only a type the host changed is sent: the domain checks a type being
  # set, and the poll's own may no longer pass that check.
  defp meeting_type_change(params, %{meeting_type_id: current}) do
    with {:ok, raw} <- Map.fetch(params, "meeting_type_id"),
         id when id != current <- parse_id(raw) do
      %{"meeting_type_id" => id}
    else
      _unchanged -> %{}
    end
  end

  # The type the poll already has, when the types a poll may take leave it
  # out because it has been switched off or has started taking payment.
  # Kept selectable, so that saving the poll's other details does not clear it.
  defp kept_meeting_type(%{meeting_type_id: nil}, _meeting_types, _user_id), do: nil

  defp kept_meeting_type(%{meeting_type_id: id}, meeting_types, user_id) do
    if Enum.any?(meeting_types, &(&1.id == id)),
      do: nil,
      else: MeetingTypes.get_meeting_type(id, user_id)
  end

  defp meeting_type_options(meeting_types, nil), do: Enum.map(meeting_types, &{&1.name, &1.id})

  defp meeting_type_options(meeting_types, kept) do
    meeting_type_options(meeting_types, nil) ++
      [
        {dgettext("dashboard_polls", "%{name} (unavailable for new polls)", name: kept.name),
         kept.id}
      ]
  end

  defp kept_selected?(nil, _meeting_type_id), do: false
  defp kept_selected?(kept, meeting_type_id), do: kept.id == meeting_type_id

  defp valid_access(value, _previous) when value in ["anyone", "invited"], do: value
  defp valid_access(_value, previous), do: previous

  # Requests can arrive while the editor is open and nothing broadcasts them,
  # so the count the warning shows is read when the host switches to invited
  # people only, not carried over from when the panel loaded.
  defp count_pending_requests(socket, "invited", previous) when previous != "invited" do
    case socket.assigns.poll do
      %{invite_only: false} = poll ->
        assign(socket, :unconfirmed_count, Polls.count_unconfirmed(poll))

      _invite_only ->
        socket
    end
  end

  defp count_pending_requests(socket, _access, _previous), do: socket

  # Warns before the switch that withdraws the requests waiting on the poll.
  defp withdraw_hint(%{invite_only: false}, "invited", count) when count > 0 do
    dngettext(
      "dashboard_polls",
      "%{count} person who asked for a voting link but hasn't voted with it yet will be removed.",
      "%{count} people who asked for a voting link but haven't voted with it yet will be removed.",
      count
    )
  end

  defp withdraw_hint(_poll, _access, _count), do: nil

  defp errors_for(reason) do
    if PollFormErrors.shared_reason?(reason),
      do: PollFormErrors.errors_for(reason, :new_times),
      else: editor_errors_for(reason)
  end

  defp editor_errors_for(:voting_closed),
    do: %{
      new_times: [
        dgettext("dashboard_polls", "Voting has closed. Move the deadline to add times.")
      ]
    }

  defp editor_errors_for(%Changeset{data: %PollSchema{}} = changeset),
    do: PollFormErrors.changeset_errors(changeset)

  # A time clashing with one the poll already has fails on the slot's unique
  # index.
  defp editor_errors_for(%Changeset{}),
    do: %{new_times: [dgettext("dashboard_polls", "The poll already has this time")]}

  defp editor_errors_for(_reason),
    do: %{base: [dgettext("dashboard_polls", "Couldn't save this poll. Please try again.")]}
end
