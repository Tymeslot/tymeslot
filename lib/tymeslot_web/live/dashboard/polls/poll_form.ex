defmodule TymeslotWeb.Dashboard.Polls.PollForm do
  @moduledoc """
  LiveComponent for creating a poll, or saving it as a draft and coming back
  to it.

  Owns the interactive create form: the meeting details and the candidate-slot
  builder (each row a `datetime-local` input in the host's timezone). A row
  whose time falls inside the host's time off, or clashes with an event in
  their calendar (`Tymeslot.Polls.SlotHealth`, checked off the LiveView
  process whenever the times change), carries a warning; neither stops the
  poll being created, because confirmation is where both are enforced.

  "Save draft" keeps the poll as it stands without publishing it
  (`Tymeslot.Polls.create_draft/2`). Given a saved `draft`, the form opens
  filled from it (`DraftFields`), saves over it, and publishes it
  (`Tymeslot.Polls.publish_draft/3`) with what the form holds.

  The host may list people to invite by email (see `PollInvite`); they are
  invited with the poll and emailed once it is saved.

  "Who can vote" starts as anyone with the link and follows the invitee field
  until the host chooses: listing anyone presets it to invited people only
  (`Tymeslot.Polls.default_invite_only?/1`, the rule `create_poll/2` applies).

  On submit it converts the local datetime values to UTC and calls
  `Tymeslot.Polls.create_poll/2`, or the draft function the button chose. Success flashes via the parent LiveView and
  asks the parent `PollsComponent` to refresh and close the form; failures map
  to friendly inline errors.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{HostAvailability, Invitations, PollSchema}
  alias Tymeslot.Profiles

  alias TymeslotWeb.Dashboard.Polls.{
    AvailabilityWeek,
    CandidateTimes,
    CandidateTimesField,
    DraftFields,
    LocalTime,
    PollAccess,
    PollDuration,
    PollFormActions,
    PollFormErrors,
    PollInvite,
    PollReminders,
    PollsComponent,
    PollTimezone,
    SlotWarnings
  }

  alias TymeslotWeb.Live.Shared.Flash

  import PollFormErrors, only: [error_list: 2]

  @reminder_events PollReminders.Events.all()
  @timezone_events ~w(toggle_timezone_dropdown close_timezone_dropdown search_timezone change_timezone)

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       title: "",
       description: "",
       meeting_type_id: "",
       duration: "30",
       deadline: "",
       timezone_dropdown_open: false,
       timezone_search: "",
       notify_on_vote: true,
       reminder_picker: PollReminders.new([%{value: 1, unit: "days"}]),
       invitees: "",
       access: "anyone",
       access_chosen?: false,
       slots: [],
       slot_counter: 0,
       time_off_keys: MapSet.new(),
       conflict_keys: MapSet.new(),
       checked_ranges: [],
       week_offset: 0,
       availability_window: nil,
       draft: nil,
       loaded_draft_id: nil,
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

    {:ok, socket |> load_draft() |> refresh_availability()}
  end

  # Once per draft: the parent passes the same draft on every update, and the
  # host's edits since must not be written over.
  defp load_draft(
         %{assigns: %{draft: %PollSchema{id: id} = draft, loaded_draft_id: loaded}} = socket
       )
       when id != loaded do
    socket
    |> assign(DraftFields.assigns(draft))
    |> assign(loaded_draft_id: id, errors: %{})
    |> assign_time_off_keys()
    |> check_calendar()
  end

  defp load_draft(socket), do: socket

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"poll-form-#{@id}"}>
      <.card
        icon={if @draft, do: "hero-pencil-square", else: "hero-plus-circle"}
        title={
          if @draft,
            do: dgettext("dashboard_polls", "Edit draft"),
            else: dgettext("dashboard_polls", "New poll")
        }
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
            <.select
              id={"poll-meeting-type-#{@id}"}
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
            <PollTimezone.field
              timezone={@timezone}
              open={@timezone_dropdown_open}
              search={@timezone_search}
              errors={error_list(@errors, :timezone)}
              target={@myself}
            />

            <.datetime_picker
              id={"poll-deadline-#{@id}"}
              name="poll[deadline]"
              label={dgettext("dashboard_polls", "Voting deadline (optional)")}
              value={@deadline}
              errors={error_list(@errors, :deadline_at)}
            />
          </div>

          <CandidateTimesField.field
            id={"poll-candidates-#{@id}"}
            slots={@slots}
            time_off_keys={@time_off_keys}
            conflict_keys={@conflict_keys}
            errors={error_list(@errors, :slots)}
            myself={@myself}
            week={
              %{
                first_day: @first_day,
                timezone: @timezone,
                minutes: PollDuration.parse(@duration),
                availability: @availability,
                deadline: @deadline,
                time_format: @time_format
              }
            }
          />

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
              `form` ties the submit buttons back to the poll. --%>
        <PollFormActions.actions
          form={"poll-create-form-#{@id}"}
          draft?={@draft != nil}
          parent_myself={@parent_myself}
        />
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
     |> assign_time_off_keys()
     |> check_calendar()
     |> refresh_availability()}
  end

  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @timezone_events do
    case PollTimezone.handle_event(event, params, socket) do
      {:changed, socket} ->
        {:noreply, socket |> assign_time_off_keys() |> check_calendar() |> refresh_availability()}

      {:unchanged, socket} ->
        {:noreply, socket}
    end
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

  @impl Phoenix.LiveComponent
  def handle_event("add_slot", _params, socket) do
    {:noreply, append_slot(socket, "")}
  end

  @impl Phoenix.LiveComponent
  def handle_event("remove_slot", %{"key" => key}, socket),
    do: {:noreply, remove_slot(socket, key)}

  def handle_event("pick_time", %{"at" => value}, socket) do
    case AvailabilityWeek.toggle(socket.assigns.slots, value) do
      {:remove, key} ->
        {:noreply, remove_slot(socket, key)}

      :add ->
        {:noreply, socket |> append_slot(value) |> assign_time_off_keys() |> check_calendar()}
    end
  end

  def handle_event("availability_week", %{"to" => direction}, socket) do
    offset = AvailabilityWeek.shift(socket.assigns.week_offset, direction)
    {:noreply, socket |> assign(:week_offset, offset) |> refresh_availability()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_poll", %{"poll" => poll_params} = event, socket) do
    # Which submit button was pressed. Enter in a field submits through the
    # first, Save draft, so nothing goes out by accident.
    params = Map.put(poll_params, "intent", event["intent"])

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

  @impl Phoenix.LiveComponent
  def handle_async(:calendar_conflicts, {:ok, keys}, socket),
    do: {:noreply, assign(socket, :conflict_keys, keys)}

  # The check never raises; an exit is the task cut short, and an unchecked
  # time is shown without a warning, as one whose fetch failed is.
  def handle_async(:calendar_conflicts, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :conflict_keys, MapSet.new())}

  # Unread, the grid shows the week without busy times, as the warnings
  # show a time whose check failed without one.
  def handle_async(:host_availability, {:ok, availability}, socket),
    do: {:noreply, assign(socket, :availability, availability)}

  def handle_async(:host_availability, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :availability, nil)}

  defp create(socket, params) do
    intent = if params["intent"] == "draft", do: :draft, else: :publish

    with {:ok, invitees} <- parse_invitees(params),
         attrs = Map.put(build_attrs(params, socket), :invitees, invitees),
         {:ok, poll} <- save(intent, socket.assigns.draft, socket.assigns.current_user.id, attrs) do
      Flash.info(saved_message(intent, poll, invitees))
      send_update(PollsComponent, id: socket.assigns.parent_id, poll_created: true)
      {:noreply, socket}
    else
      # Published or deleted from another tab while this one held it open.
      {:error, reason} when reason in [:not_draft, :not_found] ->
        Flash.warning(
          dgettext("dashboard_polls", "This draft has already been published or deleted.")
        )

        send_update(PollsComponent, id: socket.assigns.parent_id, poll_created: true)
        {:noreply, socket}

      # The calendar went while the form was open: nothing in the form can fix
      # that, so it is said once rather than under a field.
      {:error, :no_calendar} ->
        Flash.error(PollInvite.error_message(:no_calendar))
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :errors, errors_for(reason))}
    end
  end

  defp save(:draft, nil, user_id, attrs), do: Polls.create_draft(user_id, attrs)
  defp save(:draft, draft, user_id, attrs), do: Polls.update_draft(draft.id, user_id, attrs)
  defp save(:publish, nil, user_id, attrs), do: Polls.create_poll(user_id, attrs)
  defp save(:publish, draft, user_id, attrs), do: Polls.publish_draft(draft.id, user_id, attrs)

  defp saved_message(:draft, _poll, _invitees) do
    dgettext(
      "dashboard_polls",
      "Draft saved. Nobody can see it or has been invited until you publish it."
    )
  end

  defp saved_message(:publish, poll, invitees),
    do: PollInvite.created_message(Invitations.uninvited(poll, invitees))

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

  defp remove_slot(socket, key) do
    case CandidateTimes.remove(socket.assigns.slots, key) do
      {:ok, slots, key} ->
        socket
        |> assign(
          slots: slots,
          time_off_keys: MapSet.delete(socket.assigns.time_off_keys, key),
          conflict_keys: MapSet.delete(socket.assigns.conflict_keys, key),
          errors: Map.delete(socket.assigns.errors, :slots)
        )
        |> check_calendar()

      :error ->
        socket
    end
  end

  # The grid's week and the host's busy time and hours for it, read again
  # only when that week or the timezone changes.
  defp refresh_availability(socket) do
    %{week_offset: offset, timezone: timezone, current_user: user} = socket.assigns
    {first_day, {from, to} = window} = AvailabilityWeek.week(timezone, offset)
    socket = assign(socket, :first_day, first_day)

    if window == socket.assigns.availability_window do
      socket
    else
      socket
      |> assign(availability_window: window, availability: :loading)
      |> start_async(
        :host_availability,
        Tasks.with_context(fn -> HostAvailability.for_window(user.id, from, to) end)
      )
    end
  end

  # The rows read as times, for the warnings under them.
  defp slot_ranges(%{slots: slots, timezone: timezone, duration: duration}),
    do: SlotWarnings.ranges(slots, timezone, PollDuration.parse(duration))

  # Asks the host's calendar which rows clash with an event, off the LiveView
  # process, whenever the times the rows name change (their time, timezone or
  # duration). A newer check replaces one still running.
  defp check_calendar(socket) do
    ranges = slot_ranges(socket.assigns)

    cond do
      ranges == socket.assigns.checked_ranges ->
        socket

      ranges == [] ->
        assign(socket, checked_ranges: [], conflict_keys: MapSet.new())

      true ->
        user_id = socket.assigns.current_user.id
        draft_id = socket.assigns.draft && socket.assigns.draft.id

        socket
        |> assign(:checked_ranges, ranges)
        |> start_async(
          :calendar_conflicts,
          Tasks.with_context(fn -> SlotWarnings.conflict_keys(user_id, draft_id, ranges) end)
        )
    end
  end

  # Recomputed on every change, for the same reasons.
  defp assign_time_off_keys(socket) do
    keys = SlotWarnings.time_off_keys(socket.assigns.current_user.id, slot_ranges(socket.assigns))
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
      duration_minutes: PollDuration.parse(Map.get(params, "duration", socket.assigns.duration)),
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
