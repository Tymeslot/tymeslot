defmodule TymeslotWeb.Dashboard.Polls.PollForm do
  @moduledoc """
  LiveComponent for creating a poll.

  Owns the interactive create form: the meeting details and the candidate-slot
  builder (each row a `datetime-local` input in the host's timezone). A row
  whose time falls inside the host's time off carries a warning; it does not
  stop the poll being created, because confirmation is where time off is
  enforced.

  The host may list people to invite by email (see `PollInvite`); they are
  invited with the poll and emailed once it is saved.

  On submit it converts the local datetime values to UTC and calls
  `Tymeslot.Polls.create_poll/2`. Success flashes via the parent LiveView and
  asks the parent `PollsComponent` to refresh and close the form; failures map
  to friendly inline errors.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{Invitations, PollSchema}
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.Polls.{LocalTime, PollInvite, PollReminders, PollsComponent}
  alias TymeslotWeb.Helpers.FormErrors
  alias TymeslotWeb.Live.Shared.Flash

  @reminder_events PollReminders.events()

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       title: "",
       description: "",
       meeting_type_id: "",
       duration: "30",
       deadline: "",
       notify_on_vote: true,
       reminder_picker: PollReminders.new([%{value: 1, unit: "days"}]),
       invitees: "",
       slots: [],
       slot_counter: 0,
       time_off_keys: MapSet.new(),
       errors: %{}
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:timezone] do
        socket
      else
        assign(socket, :timezone, host_timezone(socket.assigns.profile))
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"poll-form-#{@id}"}>
      <.card
        icon="hero-plus-circle"
        title={dgettext("dashboard_polls", "New poll")}
        class="space-y-6"
      >
        <form
          id={"poll-create-form-#{@id}"}
          phx-submit="create_poll"
          phx-change="form_change"
          phx-target={@myself}
          class="space-y-4"
          novalidate
        >
          <.input
            name="poll[title]"
            label={dgettext("dashboard_polls", "Title")}
            value={@title}
            required
            placeholder={dgettext("dashboard_polls", "e.g., Team sync")}
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

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <.input
              type="select"
              name="poll[meeting_type_id]"
              label={dgettext("dashboard_polls", "Meeting type (optional)")}
              value={@meeting_type_id}
              prompt={dgettext("dashboard_polls", "No meeting type")}
              options={meeting_type_options(@meeting_types)}
              errors={error_list(@errors, :meeting_type_id)}
            />

            <div :if={meeting_type_selected?(@meeting_types, @meeting_type_id)}>
              <input type="hidden" name="poll[duration]" value={@duration} />
              <p class="text-token-sm text-tymeslot-600 mt-8">
                {dgettext("dashboard_polls", "Duration: %{minutes} min (from meeting type)",
                  minutes: @duration
                )}
              </p>
            </div>
            <.input
              :if={!meeting_type_selected?(@meeting_types, @meeting_type_id)}
              type="number"
              name="poll[duration]"
              label={dgettext("dashboard_polls", "Duration (minutes)")}
              value={@duration}
              min={Constraints.poll_duration_minutes_opts()[:greater_than_or_equal_to]}
              max={Constraints.poll_duration_minutes_opts()[:less_than_or_equal_to]}
              required
              errors={error_list(@errors, :duration_minutes)}
              icon="hero-clock"
            />
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <.input
              type="select"
              name="poll[timezone]"
              label={dgettext("dashboard_polls", "Timezone")}
              value={@timezone}
              options={Timezones.all_options()}
              errors={error_list(@errors, :timezone)}
            />

            <.input
              type="datetime-local"
              name="poll[deadline]"
              label={dgettext("dashboard_polls", "Voting deadline (optional)")}
              value={@deadline}
              errors={error_list(@errors, :deadline_at)}
            />
          </div>

          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <label class="label mb-0">
                {dgettext("dashboard_polls", "Candidate times")}
              </label>
              <span class="text-token-xs text-tymeslot-500">
                {dngettext(
                  "dashboard_polls",
                  "%{count} of %{max} time",
                  "%{count} of %{max} times",
                  length(@slots),
                  count: length(@slots),
                  max: PollSchema.max_slots()
                )}
              </span>
            </div>

            <div :for={{slot, index} <- Enum.with_index(@slots)} class="space-y-1">
              <div class="flex items-center gap-2">
                <div class="flex-1">
                  <.input
                    type="datetime-local"
                    name={"poll[slots][#{slot.key}]"}
                    value={slot.value}
                    aria-label={dgettext("dashboard_polls", "Candidate time %{n}", n: index + 1)}
                  />
                </div>
                <.icon_button
                  icon="hero-x-mark"
                  label={dgettext("dashboard_polls", "Remove time")}
                  variant={:danger}
                  phx-click="remove_slot"
                  phx-value-key={slot.key}
                  phx-target={@myself}
                />
              </div>
              <p
                :if={MapSet.member?(@time_off_keys, slot.key)}
                data-testid="poll-slot-time-off-warning"
                data-slot-key={slot.key}
                class="flex items-center gap-1 text-token-xs text-amber-700"
              >
                <.icon name="hero-exclamation-triangle-mini" class="w-4 h-4 shrink-0" />
                {dgettext(
                  "dashboard_polls",
                  "This time falls within your time off, so it can't be confirmed while that stays in place."
                )}
              </p>
            </div>

            <p :for={error <- error_list(@errors, :slots)} class="form-error">{error}</p>

            <.action_button
              variant={:secondary}
              size={:sm}
              icon="hero-plus"
              phx-click="add_slot"
              phx-target={@myself}
            >
              {dgettext("dashboard_polls", "Add time")}
            </.action_button>
          </div>

          <.input
            type="checkbox"
            id={"poll-notify-on-vote-#{@id}"}
            name="poll[notify_on_vote]"
            value={@notify_on_vote}
            label={dgettext("dashboard_polls", "Email me about new votes")}
          >
            <:description>
              {dgettext(
                "dashboard_polls",
                "At most one email every 15 minutes, naming who voted, with the current standings."
              )}
            </:description>
          </.input>
          <PollInvite.invitees_input
            name="poll[invitees]"
            value={@invitees}
            errors={error_list(@errors, :invitees)}
          />

          <p :for={error <- error_list(@errors, :base)} class="form-error">{error}</p>
        </form>

        <PollReminders.reminders_form
          id={"poll-create-reminders-#{@id}"}
          state={@reminder_picker}
          myself={@myself}
        />
        <p :for={error <- error_list(@errors, :reminder_config)} class="form-error">{error}</p>

        <%!-- Outside the form above, so the reminder picker can sit before it;
              `form` ties the submit button back to the poll. --%>
        <div class="flex justify-end gap-3 pt-2">
          <.action_button
            variant={:secondary}
            phx-click="cancel_poll_form"
            phx-target={@parent_myself}
          >
            {dgettext("dashboard_polls", "Cancel")}
          </.action_button>
          <.action_button type="submit" form={"poll-create-form-#{@id}"}>
            {dgettext("dashboard_polls", "Create poll")}
          </.action_button>
        </div>
      </.card>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("form_change", %{"poll" => params}, socket) do
    meeting_type_id = Map.get(params, "meeting_type_id", socket.assigns.meeting_type_id)
    duration = resolve_duration(params, meeting_type_id, socket)

    {:noreply,
     socket
     |> assign(
       title: Map.get(params, "title", socket.assigns.title),
       description: Map.get(params, "description", socket.assigns.description),
       meeting_type_id: meeting_type_id,
       duration: duration,
       deadline: Map.get(params, "deadline", socket.assigns.deadline),
       notify_on_vote: checked?(params, "notify_on_vote", socket.assigns.notify_on_vote),
       invitees: Map.get(params, "invitees", socket.assigns.invitees),
       timezone: Map.get(params, "timezone", socket.assigns.timezone),
       slots: merge_slot_values(socket.assigns.slots, Map.get(params, "slots", %{}))
     )
     |> assign_time_off_keys()}
  end

  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_event(event, params, socket) when event in @reminder_events do
    {:noreply,
     assign(
       socket,
       :reminder_picker,
       PollReminders.apply_event(event, socket.assigns.reminder_picker, params)
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_slot", _params, socket) do
    {:noreply, append_slot(socket, "")}
  end

  @impl Phoenix.LiveComponent
  def handle_event("remove_slot", %{"key" => key}, socket) do
    key = String.to_integer(key)
    slots = Enum.reject(socket.assigns.slots, &(&1.key == key))

    {:noreply,
     assign(socket,
       slots: slots,
       time_off_keys: MapSet.delete(socket.assigns.time_off_keys, key),
       errors: Map.delete(socket.assigns.errors, :slots)
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_poll", %{"poll" => params}, socket) do
    with {:ok, invitees} <- parse_invitees(params),
         {:ok, _poll} <-
           Polls.create_poll(
             socket.assigns.current_user.id,
             Map.put(build_attrs(params, socket), :invitees, invitees)
           ) do
      Flash.info(dgettext("dashboard_polls", "Poll created"))
      send_update(PollsComponent, id: socket.assigns.parent_id, poll_created: true)
      {:noreply, socket}
    else
      {:error, reason} -> {:noreply, assign(socket, :errors, errors_for(reason))}
    end
  end

  # --- Slot helpers ---

  defp append_slot(socket, value) do
    if length(socket.assigns.slots) >= PollSchema.max_slots() do
      assign(socket, :errors, Map.put(socket.assigns.errors, :slots, [too_many_message()]))
    else
      key = socket.assigns.slot_counter
      slots = socket.assigns.slots ++ [%{key: key, value: value}]

      assign(socket,
        slots: slots,
        slot_counter: key + 1,
        errors: Map.delete(socket.assigns.errors, :slots)
      )
    end
  end

  defp merge_slot_values(slots, values) do
    Enum.map(slots, fn %{key: key} = slot ->
      %{slot | value: Map.get(values, Integer.to_string(key), slot.value)}
    end)
  end

  # The rows whose time the host is away for. Recomputed on every change
  # because the time, the timezone it is read in and the duration all move it.
  defp assign_time_off_keys(socket) do
    %{slots: slots, timezone: timezone, duration: duration} = socket.assigns

    starts =
      for %{key: key, value: value} <- slots,
          start_time = LocalTime.to_utc(value, timezone),
          start_time != nil,
          do: {key, start_time}

    clashing =
      Polls.starts_during_time_off(
        socket.assigns.current_user.id,
        Enum.map(starts, &elem(&1, 1)),
        parse_duration(duration)
      )

    keys = for {key, start_time} <- starts, start_time in clashing, into: MapSet.new(), do: key
    assign(socket, :time_off_keys, keys)
  end

  # --- Attribute building ---

  defp build_attrs(params, socket) do
    timezone = Map.get(params, "timezone", socket.assigns.timezone)

    %{
      title: Map.get(params, "title", ""),
      description: blank_to_nil(Map.get(params, "description")),
      timezone: timezone,
      duration_minutes: parse_duration(Map.get(params, "duration", socket.assigns.duration)),
      meeting_type_id: parse_meeting_type_id(Map.get(params, "meeting_type_id")),
      deadline_at: LocalTime.to_utc(Map.get(params, "deadline"), timezone),
      notify_on_vote: checked?(params, "notify_on_vote", socket.assigns.notify_on_vote),
      reminder_config: PollReminders.to_config(socket.assigns.reminder_picker),
      slots: build_slots(Map.get(params, "slots", %{}), timezone)
    }
  end

  defp parse_invitees(params) do
    case Invitations.parse(Map.get(params, "invitees")) do
      {:ok, invitees} -> {:ok, invitees}
      {:error, reason} -> {:error, {:invitees, reason}}
    end
  end

  defp build_slots(values, timezone) do
    values
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(key) end)
    |> Enum.map(fn {_key, value} -> LocalTime.to_utc(value, timezone) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn start_time -> %{start_time: start_time} end)
  end

  # --- Meeting-type / duration resolution ---

  defp resolve_duration(params, meeting_type_id, socket) do
    case selected_meeting_type(socket.assigns.meeting_types, meeting_type_id) do
      nil -> Map.get(params, "duration", socket.assigns.duration)
      meeting_type -> Integer.to_string(meeting_type.duration_minutes)
    end
  end

  defp meeting_type_selected?(meeting_types, meeting_type_id) do
    selected_meeting_type(meeting_types, meeting_type_id) != nil
  end

  defp selected_meeting_type(_meeting_types, id) when id in [nil, ""], do: nil

  defp selected_meeting_type(meeting_types, id) do
    Enum.find(meeting_types, &(Integer.to_string(&1.id) == to_string(id)))
  end

  defp meeting_type_options(meeting_types) do
    Enum.map(meeting_types, &{&1.name, &1.id})
  end

  defp parse_meeting_type_id(id) when id in [nil, ""], do: nil

  defp parse_meeting_type_id(id) do
    case Integer.parse(id) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  # --- Misc ---

  defp parse_duration(value) when is_integer(value), do: value

  defp parse_duration(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int > 0 -> int
      _other -> 30
    end
  end

  defp parse_duration(_other), do: 30

  defp checked?(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      value -> value == "true"
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp host_timezone(%{timezone: timezone}) when is_binary(timezone) and timezone != "",
    do: timezone

  defp host_timezone(_profile), do: Profiles.get_default_timezone()

  defp error_list(errors, field) do
    case Map.get(errors, field) do
      nil -> []
      messages when is_list(messages) -> messages
      message -> [message]
    end
  end

  defp errors_for({:invitees, reason}), do: %{invitees: [PollInvite.error_message(reason)]}
  defp errors_for(:poll_full), do: %{invitees: [PollInvite.error_message(:poll_full)]}

  defp errors_for(:no_slots),
    do: %{slots: [dgettext("dashboard_polls", "Add at least one candidate time")]}

  defp errors_for(:too_many_slots), do: %{slots: [too_many_message()]}

  defp errors_for(:slot_in_past),
    do: %{slots: [dgettext("dashboard_polls", "Times must be in the future")]}

  defp errors_for(:payment_required_type),
    do: %{
      meeting_type_id: [
        dgettext("dashboard_polls", "Paid meeting types can't be used for polls")
      ]
    }

  defp errors_for(:meeting_type_not_found),
    do: %{meeting_type_id: [dgettext("dashboard_polls", "That meeting type is unavailable")]}

  defp errors_for(%Changeset{} = changeset), do: FormErrors.to_map(changeset)

  defp too_many_message,
    do: dgettext("dashboard_polls", "Up to %{max} times", max: PollSchema.max_slots())
end
