defmodule TymeslotWeb.Dashboard.Polls.PollEditor do
  @moduledoc """
  LiveComponent for editing an open poll from its results panel.

  Covers what can change while people vote (see `Tymeslot.Polls.Editing`):
  the title and description, whether the host is emailed about new votes, who
  can vote (switching to invited people only withdraws pending link requests,
  which the editor warns about with the count it is given), the
  voting deadline (moved, removed, or set again to reopen voting), the
  reminders before it, and new candidate times. Everything is saved at once.
  The participant list beside it removes someone straight away.

  The editor keeps its own state across re-renders: a vote arriving while the
  host edits refreshes the poll it is given, not what the host has typed.
  On a save it tells the owning `PollsComponent` (`poll_edited: true`), which
  closes the editor and reloads the poll.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}
  alias TymeslotWeb.Dashboard.Polls.{LocalTime, PollAccess, PollReminders, PollsComponent}
  alias TymeslotWeb.Live.Shared.Flash

  @reminder_events PollReminders.events()

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:initialized?] do
      {:ok, socket}
    else
      {:ok, init(socket, assigns.poll)}
    end
  end

  defp init(socket, poll) do
    assign(socket,
      initialized?: true,
      title: poll.title,
      description: poll.description || "",
      deadline: LocalTime.to_input(poll.deadline_at, poll.timezone),
      notify_on_vote: poll.notify_on_vote,
      access: PollAccess.value(poll.invite_only),
      meeting_type_id: poll.meeting_type_id,
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
          options={Enum.map(@meeting_types, &{&1.name, &1.id})}
          errors={error_list(@errors, :meeting_type_id)}
        >
          <:description>
            {dgettext(
              "dashboard_polls",
              "Its calendar and video provider are used for the meeting when you confirm a time. The poll's times and title stay as they are."
            )}
          </:description>
        </.input>

        <PollAccess.access_input
          id={"poll-access-#{@poll.id}"}
          name="poll[access]"
          value={@access}
          hint={withdraw_hint(@poll, @access, assigns[:unconfirmed_count] || 0)}
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
            <input
              type="datetime-local"
              name={"poll[new_times][#{time.key}]"}
              value={time.value}
              class="input py-1.5 px-3 text-token-sm"
              aria-label={dgettext("dashboard_polls", "New time")}
            />
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
      </form>

      <PollReminders.reminders_form
        id={"poll-edit-reminders-#{@poll.id}"}
        state={@reminder_picker}
        myself={@myself}
      />
      <p :for={error <- error_list(@errors, :reminder_config)} class="form-error">{error}</p>

      <.participants poll={@poll} myself={@myself} />

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

  attr :poll, :map, required: true
  attr :myself, :any, required: true

  # Everyone counted on the poll, with a way to take someone off it.
  defp participants(assigns) do
    ~H"""
    <details :if={@poll.participants != []} class="text-token-sm" data-testid="poll-participants">
      <summary class="cursor-pointer font-medium text-tymeslot-700">
        {dngettext(
          "dashboard_polls",
          "%{count} participant",
          "%{count} participants",
          length(@poll.participants)
        )}
      </summary>
      <ul class="mt-2 divide-y divide-tymeslot-100">
        <li
          :for={participant <- @poll.participants}
          class="flex items-center justify-between gap-3 py-2"
          data-testid="poll-participant"
        >
          <div class="min-w-0">
            <p class="truncate text-tymeslot-800">
              {PollParticipantSchema.display_name(participant)}
            </p>
            <p class="truncate text-token-xs text-tymeslot-500">
              {participant.email} · {status_label(participant)}
            </p>
          </div>
          <.icon_button
            icon="hero-user-minus"
            label={dgettext("dashboard_polls", "Remove from the poll")}
            phx-click="remove_participant"
            phx-value-id={participant.id}
            phx-target={@myself}
            data-confirm={
              dgettext(
                "dashboard_polls",
                "Remove %{name} and their responses from this poll? They are not told.",
                name: PollParticipantSchema.display_name(participant)
              )
            }
            data-testid="poll-remove-participant"
          />
        </li>
      </ul>
    </details>
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
    {:noreply,
     assign(socket,
       title: Map.get(params, "title", socket.assigns.title),
       description: Map.get(params, "description", socket.assigns.description),
       deadline: Map.get(params, "deadline", socket.assigns.deadline),
       notify_on_vote: Map.get(params, "notify_on_vote", "false") == "true",
       access: Map.get(params, "access", socket.assigns.access),
       meeting_type_id: parse_id(Map.get(params, "meeting_type_id")),
       new_times: merge_times(socket.assigns.new_times, Map.get(params, "new_times", %{}))
     )}
  end

  def handle_event("add_time", _params, socket) do
    key = socket.assigns.time_counter

    {:noreply,
     assign(socket,
       new_times: socket.assigns.new_times ++ [%{key: key, value: ""}],
       time_counter: key + 1
     )}
  end

  def handle_event("remove_time", %{"key" => key}, socket) do
    key = String.to_integer(key)

    {:noreply,
     assign(socket, :new_times, Enum.reject(socket.assigns.new_times, &(&1.key == key)))}
  end

  def handle_event("remove_participant", %{"id" => participant_id}, socket) do
    %{poll: poll, user_id: user_id} = socket.assigns

    case Polls.remove_participant(poll.id, user_id, participant_id) do
      :ok ->
        Flash.info(dgettext("dashboard_polls", "Removed from the poll"))

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_polls", "This poll is no longer open."))
    end

    send_update(PollsComponent, id: socket.assigns.parent_id, poll_updated: poll.id)
    {:noreply, socket}
  end

  def handle_event("save", %{"poll" => params}, socket) do
    %{poll: poll, user_id: user_id} = socket.assigns

    attrs = %{
      "title" => Map.get(params, "title"),
      "description" => Map.get(params, "description"),
      "notify_on_vote" => Map.get(params, "notify_on_vote", "false"),
      "invite_only" => PollAccess.invite_only?(Map.get(params, "access", socket.assigns.access)),
      "deadline_at" => LocalTime.to_utc(Map.get(params, "deadline"), poll.timezone),
      "meeting_type_id" => parse_id(Map.get(params, "meeting_type_id")),
      "reminder_config" => PollReminders.to_config(socket.assigns.reminder_picker)
    }

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

  defp parse_id(value) when value in [nil, ""], do: nil

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _invalid -> nil
    end
  end

  defp parse_id(value), do: value

  defp merge_times(times, values) do
    Enum.map(times, fn %{key: key} = time ->
      %{time | value: Map.get(values, Integer.to_string(key), time.value)}
    end)
  end

  defp status_label(%{voted_at: %DateTime{}}), do: dgettext("dashboard_polls", "voted")
  defp status_label(%{invited_at: %DateTime{}}), do: dgettext("dashboard_polls", "invited")
  defp status_label(_participant), do: dgettext("dashboard_polls", "not voted yet")

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

  defp errors_for(:too_many_slots),
    do: %{
      new_times: [
        dgettext("dashboard_polls", "Up to %{max} times", max: PollSchema.max_slots())
      ]
    }

  defp errors_for(:meeting_type_not_found),
    do: %{meeting_type_id: [dgettext("dashboard_polls", "That meeting type is unavailable")]}

  defp errors_for(:payment_required_type),
    do: %{
      meeting_type_id: [
        dgettext("dashboard_polls", "Paid meeting types can't be used for polls")
      ]
    }

  defp errors_for(:slot_in_past),
    do: %{new_times: [dgettext("dashboard_polls", "Times must be in the future")]}

  defp errors_for(%Changeset{data: %PollSchema{}} = changeset) do
    errors = changeset_errors(changeset)

    if Map.has_key?(errors, :deadline_at),
      do:
        Map.put(errors, :deadline_at, [
          dgettext("dashboard_polls", "The deadline must be in the future")
        ]),
      else: errors
  end

  # A time clashing with one the poll already has fails on the slot's unique
  # index.
  defp errors_for(%Changeset{}),
    do: %{new_times: [dgettext("dashboard_polls", "The poll already has this time")]}

  defp errors_for(_reason),
    do: %{base: [dgettext("dashboard_polls", "Couldn't save this poll. Please try again.")]}

  defp changeset_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end

  defp error_list(errors, field), do: Map.get(errors, field, [])
end
