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

  "Who can vote" starts as anyone with the link and follows the invitee field
  until the host chooses: listing anyone presets it to invited people only
  (`Tymeslot.Polls.default_invite_only?/1`, the rule `create_poll/2` applies).

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

  alias TymeslotWeb.Dashboard.Polls.{
    CandidateTimes,
    LocalTime,
    PollAccess,
    PollDuration,
    PollFormErrors,
    PollInvite,
    PollReminders,
    PollsComponent
  }

  alias TymeslotWeb.Live.Shared.Flash

  import PollFormErrors, only: [error_list: 2]

  @reminder_events PollReminders.Events.all()

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
       access: "anyone",
       access_chosen?: false,
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

            <PollDuration.duration_field
              meeting_type={selected_meeting_type(@meeting_types, @meeting_type_id)}
              duration={@duration}
              errors={error_list(@errors, :duration_minutes)}
            />
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <.input
              type="select"
              name="poll[timezone]"
              label={dgettext("dashboard_polls", "Timezone")}
              value={@timezone}
              options={timezone_options(@timezone)}
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
                <%!-- The noun counts the maximum ("1 of 40 times"), so the
                      plural follows it rather than the times added. --%>
                {dngettext(
                  "dashboard_polls",
                  "%{used} of %{count} time",
                  "%{used} of %{count} times",
                  PollSchema.max_slots(),
                  used: length(@slots)
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
          <PollAccess.access_input
            id={"poll-access-#{@id}"}
            name="poll[access]"
            value={@access}
            hint={access_hint(@access, @invitees)}
          />

          <p :for={error <- error_list(@errors, :base)} class="form-error">{error}</p>
        </form>

        <PollReminders.reminders_form
          :if={invitees_entered?(@invitees)}
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
  def handle_event("form_change", %{"poll" => params} = event, socket) do
    meeting_type_id = Map.get(params, "meeting_type_id", socket.assigns.meeting_type_id)
    duration = resolve_duration(params, meeting_type_id, socket)
    {access, access_chosen?} = resolve_access(params, event["_target"], socket)

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
       access: access,
       access_chosen?: access_chosen?,
       timezone: Map.get(params, "timezone", socket.assigns.timezone),
       slots: CandidateTimes.merge(socket.assigns.slots, Map.get(params, "slots", %{}))
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
    case CandidateTimes.remove(socket.assigns.slots, key) do
      {:ok, slots, key} ->
        {:noreply,
         assign(socket,
           slots: slots,
           time_off_keys: MapSet.delete(socket.assigns.time_off_keys, key),
           errors: Map.delete(socket.assigns.errors, :slots)
         )}

      :error ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_poll", %{"poll" => params}, socket) do
    # The picker shows only with invitees, so a lead time typed into it
    # before they were cleared is not the host's intent any more, and an
    # invalid one must not stop a save through an error nobody can see.
    if invitees_entered?(Map.get(params, "invitees", socket.assigns.invitees)) do
      case PollReminders.commit_pending(socket.assigns.reminder_picker) do
        {:ok, picker} -> create(assign(socket, :reminder_picker, picker), params)
        {:error, rejected} -> {:noreply, assign(socket, :reminder_picker, rejected)}
      end
    else
      create(socket, params)
    end
  end

  defp create(socket, params) do
    with {:ok, invitees} <- parse_invitees(params),
         {:ok, poll} <-
           Polls.create_poll(
             socket.assigns.current_user.id,
             Map.put(build_attrs(params, socket), :invitees, invitees)
           ) do
      Flash.info(PollInvite.created_message(Invitations.uninvited(poll, invitees)))
      send_update(PollsComponent, id: socket.assigns.parent_id, poll_created: true)
      {:noreply, socket}
    else
      # The calendar went while the form was open: nothing in the form can fix
      # that, so it is said once rather than under a field.
      {:error, :no_calendar} ->
        Flash.error(PollInvite.error_message(:no_calendar))
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :errors, errors_for(reason))}
    end
  end

  # --- Slot helpers ---

  defp append_slot(socket, value) do
    if length(socket.assigns.slots) >= PollSchema.max_slots() do
      assign(
        socket,
        :errors,
        Map.put(socket.assigns.errors, :slots, [PollFormErrors.too_many_message()])
      )
    else
      {slots, counter} =
        CandidateTimes.add(socket.assigns.slots, socket.assigns.slot_counter, value)

      assign(socket,
        slots: slots,
        slot_counter: counter,
        errors: Map.delete(socket.assigns.errors, :slots)
      )
    end
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
      case parse_duration(duration) do
        minutes when is_integer(minutes) and minutes > 0 ->
          Polls.starts_during_time_off(
            socket.assigns.current_user.id,
            Enum.map(starts, &elem(&1, 1)),
            minutes
          )

        # No usable length yet: the field shows its own error on save.
        _invalid ->
          []
      end

    keys = for {key, start_time} <- starts, start_time in clashing, into: MapSet.new(), do: key
    assign(socket, :time_off_keys, keys)
  end

  # --- Attribute building ---

  # Reminders reach only invitees, so the picker waits until someone is.
  defp invitees_entered?(invitees), do: String.trim(invitees || "") != ""

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
      invite_only: params |> resolve_access(nil, socket) |> elem(0) |> PollAccess.invite_only?(),
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
    |> Enum.sort_by(fn {key, _value} -> slot_order(key) end)
    |> Enum.map(fn {_key, value} -> LocalTime.to_utc(value, timezone) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn start_time -> %{start_time: start_time} end)
  end

  # Rows are keyed by the counter the form issued; a forged key sorts last.
  defp slot_order(key) do
    case Integer.parse(key) do
      {order, ""} -> order
      _forged -> :infinity
    end
  end

  # --- Meeting-type / duration resolution ---

  defp resolve_duration(params, meeting_type_id, socket) do
    socket.assigns.meeting_types
    |> selected_meeting_type(meeting_type_id)
    |> PollDuration.resolve(params, socket.assigns.duration)
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

  # --- Who can vote ---

  # The host's choice, or until they make one, the default for the invitees
  # typed so far. The form always sends whichever radio is checked, and a
  # change event can carry the value the page showed before the server's
  # default flipped, so only a change the radio itself triggered is a choice.
  # A submit (no target) keeps the host's choice, or else the default.
  defp resolve_access(%{"access" => value}, ["poll", "access"], _socket)
       when value in ["anyone", "invited"],
       do: {value, true}

  defp resolve_access(_params, _target, %{assigns: %{access: shown, access_chosen?: true}}),
    do: {shown, true}

  defp resolve_access(params, _target, socket) do
    {default_access(Map.get(params, "invitees", socket.assigns.invitees)), false}
  end

  # An unreadable list is still a list of people the host means to invite.
  defp default_access(invitees_text) do
    case Invitations.parse(invitees_text) do
      {:ok, invitees} -> PollAccess.value(Polls.default_invite_only?(invitees))
      {:error, _reason} -> PollAccess.value(true)
    end
  end

  defp access_hint("invited", invitees) do
    if String.trim(invitees || "") == "" do
      dgettext(
        "dashboard_polls",
        "Nobody can vote until you invite someone. You can also invite people after creating the poll."
      )
    end
  end

  defp access_hint(_access, _invitees), do: nil

  # --- Misc ---

  # What the host typed, or nil when it is not a whole number: the changeset
  # then says what is wrong, where a default would quietly replace it.
  defp parse_duration(value) when is_integer(value), do: value

  defp parse_duration(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp parse_duration(_other), do: nil

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

  # The picker lists the zones the app offers; a host whose profile holds
  # another valid zone (`America/Detroit`, `Etc/UTC`) would otherwise see the
  # first option selected and create the poll in the wrong zone.
  defp timezone_options(selected) do
    options = Timezones.all_options()

    if Enum.any?(options, fn {_label, id} -> id == selected end) or not Timezones.valid?(selected),
      do: options,
      else: [{selected, selected} | options]
  end

  defp errors_for({:invitees, reason}), do: %{invitees: [PollInvite.error_message(reason)]}
  defp errors_for(:poll_full), do: %{invitees: [PollInvite.error_message(:poll_full)]}
  defp errors_for(:no_username), do: %{invitees: [PollInvite.error_message(:no_username)]}

  defp errors_for({:rate_limited, _remaining} = reason),
    do: %{invitees: [PollInvite.error_message(reason)]}

  defp errors_for(:no_slots),
    do: %{slots: [dgettext("dashboard_polls", "Add at least one candidate time")]}

  defp errors_for(%Changeset{} = changeset), do: PollFormErrors.changeset_errors(changeset)
  defp errors_for(reason), do: PollFormErrors.errors_for(reason, :slots)
end
