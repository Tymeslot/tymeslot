defmodule TymeslotWeb.Dashboard.Polls.PollForm do
  @moduledoc """
  LiveComponent for creating a poll, or saving it as a draft and coming back
  to it.

  Owns the interactive create form: the meeting details, where it will be
  held (`PollLocationField`), and the candidate-slot builder (each row a `datetime-local` input in the host's timezone). A row
  whose time falls inside the host's time off, or clashes with an event in
  their calendar (`Tymeslot.Polls.SlotHealth`, checked off the LiveView
  process whenever the times change), carries a warning; neither stops the
  poll being created, because confirmation is where both are enforced.
  The rows and those checks are kept on the socket by `CandidateTimesState`.

  "Save draft" keeps the poll as it stands without publishing it
  (`Tymeslot.Polls.create_draft/2`). Given a saved `draft`, the form opens
  filled from it (`DraftFields`), saves over it, and publishes it
  (`Tymeslot.Polls.publish_draft/3`) with what the form holds.

  The host may list people to invite by email (see `PollInvite`); they are
  invited with the poll and emailed once it is saved.

  "Who can vote" starts as anyone with the link and follows the invitee field
  until the host chooses: listing anyone presets it to invited people only
  (`Tymeslot.Polls.default_invite_only?/1`, the rule `create_poll/2` applies).

  On submit it converts the local datetime values to UTC (`PollFormAttrs`) and calls
  `Tymeslot.Polls.create_poll/2`, or the draft function the button chose. Success flashes via the parent LiveView and
  asks the parent `PollsComponent` to refresh and close the form; failures map
  to friendly inline errors.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{Invitations, PollLocation, PollSchema}

  alias TymeslotWeb.Dashboard.Polls.{
    AvailabilityWeek,
    CandidateTimes,
    CandidateTimesField,
    CandidateTimesState,
    DraftFields,
    LocalTime,
    PollAccess,
    PollDuration,
    PollFormActions,
    PollFormAttrs,
    PollFormErrors,
    PollInvite,
    PollLocationField,
    PollReminders,
    PollsComponent,
    PollTimezone
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
       location_choice: "",
       location_details: "",
       type_location: nil,
       type_location_for: "",
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
        assign(socket, :timezone, LocalTime.host_timezone(socket.assigns.profile))
      end

    {:ok,
     socket
     |> assign_new(:location_options, &Polls.location_options(&1.current_user.id))
     |> load_draft()
     |> assign_type_location()
     |> CandidateTimesState.refresh_availability()}
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
    |> CandidateTimesState.assign_time_off_keys()
    |> CandidateTimesState.check_calendar()
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

          <PollLocationField.field
            id={"poll-location-#{@id}"}
            choice={@location_choice}
            details={@location_details}
            options={@location_options}
            type_location={@type_location}
            errors={@errors}
          />

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
            hint={PollAccess.create_hint(@access, @invitees)}
          />

          <p :for={error <- error_list(@errors, :base)} class="form-error">{error}</p>
        </form>

        <PollReminders.reminders_form
          :if={PollFormAttrs.invitees_entered?(@invitees)}
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
    {access, access_chosen?} = PollAccess.resolve(params, event["_target"], socket.assigns)

    {:noreply,
     socket
     |> assign(
       title: Map.get(params, "title", socket.assigns.title),
       description: Map.get(params, "description", socket.assigns.description),
       meeting_type_id: meeting_type_id,
       duration: duration,
       deadline: Map.get(params, "deadline", socket.assigns.deadline),
       notify_on_vote:
         PollFormAttrs.checked?(params, "notify_on_vote", socket.assigns.notify_on_vote),
       invitees: Map.get(params, "invitees", socket.assigns.invitees),
       access: access,
       access_chosen?: access_chosen?,
       timezone: Map.get(params, "timezone", socket.assigns.timezone),
       slots: CandidateTimes.merge(socket.assigns.slots, Map.get(params, "slots", %{}))
     )
     |> assign(PollLocationField.form_state(params, socket.assigns))
     |> assign_type_location()
     |> CandidateTimesState.assign_time_off_keys()
     |> CandidateTimesState.check_calendar()
     |> CandidateTimesState.refresh_availability()}
  end

  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @timezone_events do
    case PollTimezone.handle_event(event, params, socket) do
      {:changed, socket} ->
        {:noreply,
         socket
         |> CandidateTimesState.assign_time_off_keys()
         |> CandidateTimesState.check_calendar()
         |> CandidateTimesState.refresh_availability()}

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
    {:noreply, CandidateTimesState.append(socket, "")}
  end

  @impl Phoenix.LiveComponent
  def handle_event("remove_slot", %{"key" => key}, socket),
    do: {:noreply, CandidateTimesState.remove(socket, key)}

  def handle_event("pick_time", %{"at" => value}, socket) do
    case AvailabilityWeek.toggle(socket.assigns.slots, value) do
      {:remove, key} ->
        {:noreply, CandidateTimesState.remove(socket, key)}

      :add ->
        {:noreply,
         socket
         |> CandidateTimesState.append(value)
         |> CandidateTimesState.assign_time_off_keys()
         |> CandidateTimesState.check_calendar()}
    end
  end

  def handle_event("availability_week", %{"to" => direction}, socket) do
    offset = AvailabilityWeek.shift(socket.assigns.week_offset, direction)

    {:noreply,
     socket |> assign(:week_offset, offset) |> CandidateTimesState.refresh_availability()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_poll", %{"poll" => poll_params} = event, socket) do
    # Which submit button was pressed. Enter in a field submits through the
    # first, Save draft, so nothing goes out by accident.
    params = Map.put(poll_params, "intent", event["intent"])

    # The picker shows only with invitees, so a lead time typed into it
    # before they were cleared is not the host's intent any more, and an
    # invalid one must not stop a save through an error nobody can see.
    if PollFormAttrs.invitees_entered?(Map.get(params, "invitees", socket.assigns.invitees)) do
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

    with :ok <- PollFormErrors.finished_times(params, "slots"),
         {:ok, invitees} <- PollFormAttrs.invitees(params),
         attrs = Map.put(PollFormAttrs.attrs(params, socket.assigns), :invitees, invitees),
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

  # The selected type's location, which the poll takes while it has none of
  # its own, read again only when the type changes.
  defp assign_type_location(%{assigns: %{meeting_type_id: id, type_location_for: id}} = socket),
    do: socket

  defp assign_type_location(%{assigns: %{meeting_types: types, meeting_type_id: id}} = socket) do
    location = types |> selected_meeting_type(id) |> PollLocation.of_meeting_type()
    assign(socket, type_location: location, type_location_for: id)
  end

  defp meeting_type_options(meeting_types) do
    Enum.map(meeting_types, &{&1.name, &1.id})
  end

  defp errors_for({:invitees, reason}), do: %{invitees: [PollInvite.error_message(reason)]}
  defp errors_for(:poll_full), do: %{invitees: [PollInvite.error_message(:poll_full)]}
  defp errors_for(:no_username), do: %{invitees: [PollInvite.error_message(:no_username)]}

  defp errors_for({:rate_limited, _remaining} = reason),
    do: %{invitees: [PollInvite.error_message(reason)]}

  defp errors_for(:location_not_found),
    do: %{location_kind: [PollLocationField.not_found_message()]}

  defp errors_for(%Changeset{} = changeset), do: PollFormErrors.changeset_errors(changeset)
  defp errors_for(reason), do: PollFormErrors.errors_for(reason, :slots)
end
