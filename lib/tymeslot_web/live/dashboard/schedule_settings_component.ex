defmodule TymeslotWeb.Dashboard.ScheduleSettingsComponent do
  @moduledoc """
  LiveView component for managing user availability settings.

  A profile owns several named schedules, exactly one of which is the default.
  This component manages that set (create, rename, duplicate, set default,
  delete) and edits the selected schedule: its weekly pattern, breaks, date
  overrides, and the scheduling policy applied to every meeting type booked
  against it.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset

  alias Tymeslot.Availability.{
    AvailabilityActions,
    AvailabilityScheduleSchema,
    Schedules,
    WeeklySchedule
  }

  alias Tymeslot.MeetingTypes.InputValidation, as: MeetingSettingsInputValidation
  alias Tymeslot.Utils.ChangesetUtils
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.Dashboard.Availability.{DeleteScheduleModal, ScheduleFormModal}
  alias TymeslotWeb.CustomInputModeHelper

  alias TymeslotWeb.Dashboard.Availability.{ListComponent, PolicyCard, ScheduleSwitcher}

  # The policy settings differ only in which schedule field they write, so the
  # handlers below route through one pair of helpers driven by these tables.
  @policy_events %{
    "update_buffer_minutes" => :buffer_minutes,
    "update_advance_booking_days" => :advance_booking_days,
    "update_min_advance_hours" => :min_advance_hours
  }

  @policy_settings %{
    "buffer_minutes" => :buffer_minutes,
    "advance_booking_days" => :advance_booking_days,
    "min_advance_hours" => :min_advance_hours
  }

  # Query-string key carrying the schedule the page is editing.
  @schedule_param "schedule"

  # Value seeded into the custom input when a field currently sitting on a
  # preset is switched into custom mode. The preset lists themselves are
  # `CustomInputModeHelper.presets/1`, the same table the card renders its tags
  # from, so this cannot fall out of step with what the user sees.
  @policy_custom_seed %{
    buffer_minutes: 45,
    advance_booking_days: 120,
    min_advance_hours: 12
  }

  @impl Phoenix.LiveComponent
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    socket = ModalHook.mount_modal(socket, schedule_form: false, delete_schedule: false)

    {:ok, assign(socket, :schedule_menu_open, false)}
  end

  @impl Phoenix.LiveComponent
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> select_from_params()
      |> load_schedules()
      |> assign(saving: false)
      |> assign(form_errors: %{})
      |> assign_new(:custom_input_mode, fn -> CustomInputModeHelper.default_custom_mode() end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  # Schedule management

  def handle_event("toggle_schedule_menu", _params, socket) do
    {:noreply, assign(socket, :schedule_menu_open, not socket.assigns.schedule_menu_open)}
  end

  def handle_event("close_schedule_menu", _params, socket) do
    {:noreply, assign(socket, :schedule_menu_open, false)}
  end

  def handle_event("switch_tab", %{"tab" => schedule_id}, socket) do
    socket =
      socket
      # The menu acts on the active schedule, so leaving it open across a switch
      # would aim its actions at a schedule the user is no longer looking at.
      |> close_menu()
      |> assign(:selected_schedule_id, parse_id(schedule_id))
      |> load_schedules()

    {:noreply, patch_to_selected(socket)}
  end

  def handle_event("show_schedule_form", %{"mode" => "rename"}, socket) do
    with_selected(socket, fn schedule ->
      {:noreply,
       socket
       |> close_menu()
       |> ModalHook.show_modal(:schedule_form, %{mode: :rename, name: schedule.name})}
    end)
  end

  def handle_event("show_schedule_form", _params, socket) do
    {:noreply,
     socket
     |> close_menu()
     |> ModalHook.show_modal(:schedule_form, %{mode: :create, name: ""})}
  end

  def handle_event("hide_schedule_form", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :schedule_form)}
  end

  def handle_event("save_schedule", %{"name" => name}, socket) do
    ModalHook.with_modal_data(socket, :schedule_form, fn %{mode: mode} ->
      save_schedule(socket, mode, String.trim(name))
    end)
  end

  def handle_event("duplicate_schedule", _params, socket) do
    with_selected(socket, fn schedule ->
      taken = Enum.map(socket.assigns.schedules, & &1.name)

      case Schedules.duplicate(schedule, copy_name(schedule.name, taken)) do
        {:ok, copy} ->
          Flash.info(duplicate_message(schedule))
          {:noreply, select_and_reload(socket, copy.id)}

        {:error, reason} ->
          Flash.error(failure_message(reason))
          {:noreply, socket}
      end
    end)
  end

  def handle_event("set_default_schedule", _params, socket) do
    with_selected(socket, fn schedule ->
      case Schedules.set_default(schedule) do
        {:ok, updated} ->
          Flash.info(dgettext("dashboard_availability", "Default schedule updated"))
          {:noreply, select_and_reload(socket, updated.id)}

        {:error, reason} ->
          Flash.error(failure_message(reason))
          {:noreply, socket}
      end
    end)
  end

  def handle_event("show_delete_schedule_modal", _params, socket) do
    with_selected(socket, fn schedule ->
      data = %{
        id: schedule.id,
        name: schedule.name,
        meeting_type_names: Schedules.meeting_type_names(schedule.id)
      }

      {:noreply,
       socket
       |> close_menu()
       |> ModalHook.show_modal(:delete_schedule, data)}
    end)
  end

  def handle_event("hide_delete_schedule_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete_schedule)}
  end

  def handle_event("confirm_delete_schedule", _params, socket) do
    ModalHook.with_modal_data(socket, :delete_schedule, fn data ->
      case Enum.find(socket.assigns.schedules, &(&1.id == data.id)) do
        nil -> {:noreply, ModalHook.hide_modal(socket, :delete_schedule)}
        schedule -> delete_schedule(socket, schedule)
      end
    end)
  end

  # Scheduling policy

  def handle_event(event, params, socket) when is_map_key(@policy_events, event) do
    update_policy_setting(socket, Map.fetch!(@policy_events, event), params)
  end

  def handle_event("focus_custom_input", %{"setting" => setting}, socket)
      when is_map_key(@policy_settings, setting) do
    enable_custom_policy(socket, Map.fetch!(@policy_settings, setting))
  end

  @spec handle_info({:reload_schedule}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:reload_schedule}, socket) do
    {:noreply, load_schedules(socket)}
  end

  # State Management Functions

  @spec load_schedules(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_schedules(socket) do
    schedules = Schedules.list_for_profile(socket.assigns.profile.id)
    selected = pick_selected(schedules, socket.assigns[:selected_schedule_id])

    socket
    |> assign(:schedules, schedules)
    |> assign(:selected_schedule, selected)
    |> assign(:selected_schedule_id, selected && selected.id)
    |> assign(:meeting_type_names, meeting_type_names_for(selected))
    |> assign(:weekly_schedule, weekly_schedule_for(selected))
    |> assign(:saving, false)
  end

  defp meeting_type_names_for(nil), do: []
  defp meeting_type_names_for(schedule), do: Schedules.meeting_type_names(schedule.id)

  # The selected schedule lives in the query string so a reload, a bookmark or a
  # shared link reopens the same one. Anything unparseable is ignored rather
  # than clearing the selection, which would silently bounce the user to the
  # default schedule.
  defp select_from_params(socket) do
    case parse_id(socket.assigns[:params][@schedule_param]) do
      nil -> socket
      id -> assign(socket, :selected_schedule_id, id)
    end
  end

  defp patch_to_selected(%{assigns: %{selected_schedule: nil}} = socket) do
    push_patch(socket, to: ~p"/dashboard/availability")
  end

  defp patch_to_selected(socket) do
    query = [{@schedule_param, socket.assigns.selected_schedule.id}]
    push_patch(socket, to: ~p"/dashboard/availability?#{query}")
  end

  # The list is ordered default first, so the head is the natural fallback when
  # the previously selected schedule is gone.
  defp pick_selected([], _selected_id), do: nil

  defp pick_selected([first | _rest] = schedules, id),
    do: Enum.find(schedules, first, &(&1.id == id))

  defp weekly_schedule_for(nil), do: []

  defp weekly_schedule_for(schedule) do
    schedule.id
    |> WeeklySchedule.get_weekly_schedule()
    |> AvailabilityActions.ensure_complete_schedule(schedule.id)
  end

  defp close_menu(socket), do: assign(socket, :schedule_menu_open, false)

  defp select_and_reload(socket, schedule_id) do
    socket
    |> close_menu()
    |> ModalHook.hide_modal(:schedule_form)
    |> ModalHook.hide_modal(:delete_schedule)
    |> assign(:selected_schedule_id, schedule_id)
    |> load_schedules()
    |> patch_to_selected()
  end

  defp with_selected(socket, fun) do
    case socket.assigns.selected_schedule do
      nil -> {:noreply, socket}
      schedule -> fun.(schedule)
    end
  end

  defp save_schedule(socket, :create, name) do
    case Schedules.create(socket.assigns.profile.id, %{name: name}) do
      {:ok, schedule} ->
        Flash.info(dgettext("dashboard_availability", "Schedule created"))
        {:noreply, select_and_reload(socket, schedule.id)}

      {:error, reason} ->
        Flash.error(failure_message(reason))
        {:noreply, socket}
    end
  end

  defp save_schedule(socket, :rename, name) do
    with_selected(socket, fn schedule ->
      case Schedules.rename(schedule, name) do
        {:ok, renamed} ->
          Flash.info(dgettext("dashboard_availability", "Schedule renamed"))
          {:noreply, select_and_reload(socket, renamed.id)}

        {:error, reason} ->
          Flash.error(failure_message(reason))
          {:noreply, socket}
      end
    end)
  end

  defp delete_schedule(socket, schedule) do
    case Schedules.delete(schedule) do
      {:ok, _schedule} ->
        Flash.info(dgettext("dashboard_availability", "Schedule deleted"))

        {:noreply,
         socket
         |> ModalHook.hide_modal(:delete_schedule)
         |> assign(:selected_schedule_id, nil)
         |> load_schedules()
         |> patch_to_selected()}

      {:error, :cannot_delete_default} ->
        Flash.error(
          dgettext(
            "dashboard_availability",
            "Your default schedule cannot be deleted. Make another schedule the default first."
          )
        )

        {:noreply, ModalHook.hide_modal(socket, :delete_schedule)}

      {:error, reason} ->
        Flash.error(failure_message(reason))
        {:noreply, socket}
    end
  end

  # A copy carries the hours, breaks and rules but not the date overrides, which
  # name specific calendar days. Said only when the source actually had some, so
  # the ordinary duplicate stays a one-word confirmation.
  defp duplicate_message(source) do
    if Schedules.has_overrides?(source.id) do
      dgettext(
        "dashboard_availability",
        "Schedule duplicated. Its date overrides were not copied."
      )
    else
      dgettext("dashboard_availability", "Schedule duplicated")
    end
  end

  # Appends a "(copy)" suffix, numbering it when that name is already taken and
  # trimming it to the column limit so the insert cannot fail on length.
  defp copy_name(source_name, taken) do
    base = truncate_name(dgettext("dashboard_availability", "%{name} (copy)", name: source_name))
    if base in taken, do: number_copy(base, taken, 2), else: base
  end

  defp number_copy(base, taken, counter) do
    candidate = truncate_name("#{base} #{counter}")
    if candidate in taken, do: number_copy(base, taken, counter + 1), else: candidate
  end

  defp truncate_name(name) do
    String.slice(name, 0, AvailabilityScheduleSchema.name_max_length())
  end

  defp parse_id(schedule_id) when is_binary(schedule_id) do
    case Integer.parse(schedule_id) do
      {id, _rest} -> id
      :error -> nil
    end
  end

  defp parse_id(schedule_id), do: schedule_id

  # Scheduling policy helpers

  defp update_policy_setting(%{assigns: %{selected_schedule: nil}} = socket, _field, _params),
    do: {:noreply, socket}

  defp update_policy_setting(socket, field, params) do
    submitted = params[Atom.to_string(field)] || params["value"] || policy_default(field)

    metadata = DashboardHelpers.get_security_metadata(socket)

    with {:ok, value} <- validate_policy(field, submitted, metadata: metadata),
         {:ok, schedule} <-
           Schedules.update_policy(socket.assigns.selected_schedule, %{field => value}) do
      Flash.info(policy_flash(field, Map.fetch!(schedule, field)))

      socket =
        socket
        |> CustomInputModeHelper.toggle_custom_mode(field, params, value)
        |> assign_selected(schedule)

      {:noreply, socket}
    else
      {:error, reason} ->
        Flash.error(failure_message(reason))
        {:noreply, socket}
    end
  end

  defp enable_custom_policy(%{assigns: %{selected_schedule: nil}} = socket, _field),
    do: {:noreply, socket}

  defp enable_custom_policy(socket, field) do
    schedule = socket.assigns.selected_schedule
    current = Map.fetch!(schedule, field)

    custom_value =
      if current in CustomInputModeHelper.presets(field),
        do: Map.fetch!(@policy_custom_seed, field),
        else: current

    case Schedules.update_policy(schedule, %{field => custom_value}) do
      {:ok, updated} ->
        Flash.info(custom_policy_flash(field))

        {:noreply,
         socket
         |> CustomInputModeHelper.enable_custom_mode(field)
         |> assign_selected(updated)}

      {:error, reason} ->
        Flash.error(failure_message(reason))
        {:noreply, socket}
    end
  end

  defp assign_selected(socket, schedule) do
    schedules =
      Enum.map(socket.assigns.schedules, fn existing ->
        if existing.id == schedule.id, do: schedule, else: existing
      end)

    socket
    |> assign(:schedules, schedules)
    |> assign(:selected_schedule, schedule)
  end

  # Only reached when an event arrives carrying no value at all. Read from the
  # same table the schema's column defaults and the engine's fallbacks use, so a
  # value-less event lands on the rules the rest of the system already assumes.
  # `validate_policy/3` sanitises its input as a string, hence the conversion.
  defp policy_default(field) do
    Constraints.scheduling_policy_defaults() |> Map.fetch!(field) |> to_string()
  end

  defp validate_policy(:buffer_minutes, value, opts),
    do: MeetingSettingsInputValidation.validate_buffer_minutes(value, opts)

  defp validate_policy(:advance_booking_days, value, opts),
    do: MeetingSettingsInputValidation.validate_advance_booking_days(value, opts)

  defp validate_policy(:min_advance_hours, value, opts),
    do: MeetingSettingsInputValidation.validate_min_advance_hours(value, opts)

  defp policy_flash(:buffer_minutes, value),
    do:
      dgettext("dashboard_availability", "Buffer time updated to %{minutes} minutes",
        minutes: value
      )

  defp policy_flash(:advance_booking_days, value),
    do:
      dgettext("dashboard_availability", "Advance booking window updated to %{days} days",
        days: value
      )

  defp policy_flash(:min_advance_hours, value),
    do:
      dgettext("dashboard_availability", "Minimum booking notice updated to %{hours} hours",
        hours: value
      )

  defp custom_policy_flash(:buffer_minutes),
    do: dgettext("dashboard_availability", "Buffer time set to custom value")

  defp custom_policy_flash(:advance_booking_days),
    do: dgettext("dashboard_availability", "Advance booking set to custom value")

  defp custom_policy_flash(:min_advance_hours),
    do: dgettext("dashboard_availability", "Minimum notice set to custom value")

  defp failure_message(%Changeset{} = changeset), do: ChangesetUtils.get_first_error(changeset)
  defp failure_message(message) when is_binary(message), do: message

  defp failure_message(:schedule_limit_reached),
    do:
      dgettext(
        "dashboard_availability",
        "You have reached the limit of %{count} schedules. Delete one to add another.",
        count: Schedules.max_schedules()
      )

  defp failure_message(_reason),
    do: dgettext("dashboard_availability", "Something went wrong. Please try again.")

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header
        icon="hero-calendar-days"
        title={dgettext("dashboard_availability", "Availability")}
        saving={@saving}
      />

      <ScheduleSwitcher.schedule_panel
        schedules={@schedules}
        selected_schedule={@selected_schedule}
        meeting_type_names={@meeting_type_names}
        max_schedules={Schedules.max_schedules()}
        menu_open={@schedule_menu_open}
        myself={@myself}
      >
        <.live_component
          module={ListComponent}
          id="availability-list"
          weekly_schedule={@weekly_schedule}
          profile={@profile}
          selected_schedule={@selected_schedule}
          time_format={@time_format}
          form_errors={@form_errors}
          client_ip={@client_ip}
          user_agent={@user_agent}
        />

        <PolicyCard.policy_card
          :if={@selected_schedule}
          schedule={@selected_schedule}
          myself={@myself}
          custom_input_mode={@custom_input_mode}
        />
      </ScheduleSwitcher.schedule_panel>

      <ScheduleFormModal.schedule_form_modal
        id="schedule-form-modal"
        show={@show_schedule_form_modal}
        schedule_data={@schedule_form_modal_data}
        on_cancel={JS.push("hide_schedule_form", target: @myself)}
        myself={@myself}
      />

      <DeleteScheduleModal.delete_schedule_modal
        id="delete-schedule-modal"
        show={@show_delete_schedule_modal}
        schedule_data={@delete_schedule_modal_data}
        on_cancel={JS.push("hide_delete_schedule_modal", target: @myself)}
        on_confirm={JS.push("confirm_delete_schedule", target: @myself)}
      />
    </div>
    """
  end
end
