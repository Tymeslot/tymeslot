defmodule TymeslotWeb.Dashboard.Polls.PollForm do
  @moduledoc """
  LiveComponent for creating a poll.

  Owns the interactive create form: the meeting details, the candidate-slot
  builder (each row a `datetime-local` input in the host's timezone), and the
  "suggest times" helper that reads the host's own availability for a date and
  offers conflict-free times as clickable chips.

  On submit it converts the local datetime values to UTC and calls
  `Tymeslot.Polls.create_poll/2`. Success flashes via the parent LiveView and
  asks the parent `PollsComponent` to refresh and close the form; failures map
  to friendly inline errors. Availability lookups run in a bounded `Task` and
  never block the form: on timeout or error the suggestions are simply hidden.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Dashboard.Polls.PollsComponent
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Live.Shared.Flash

  @suggest_timeout 6_000

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       title: "",
       description: "",
       meeting_type_id: "",
       duration: "30",
       deadline: "",
       slots: [],
       slot_counter: 0,
       errors: %{},
       suggest_date: "",
       suggestions: nil,
       suggest_error: false
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
    <div id={"poll-form-#{@id}"} class="card-glass py-6 px-6 space-y-6">
      <.section_header
        level={3}
        icon="hero-plus-circle"
        title={dgettext("dashboard_common", "New poll")}
      />

      <form
        id={"poll-create-form-#{@id}"}
        phx-submit="create_poll"
        phx-change="form_change"
        phx-target={@myself}
        class="space-y-4"
      >
        <.input
          name="poll[title]"
          label={dgettext("dashboard_common", "Title")}
          value={@title}
          required
          placeholder={dgettext("dashboard_common", "e.g., Team sync")}
          errors={error_list(@errors, :title)}
          icon="hero-hand-raised"
        />

        <.input
          type="textarea"
          name="poll[description]"
          label={dgettext("dashboard_common", "Description (optional)")}
          value={@description}
          placeholder={dgettext("dashboard_common", "Add any context for your guests")}
          errors={error_list(@errors, :description)}
        />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input
            type="select"
            name="poll[meeting_type_id]"
            label={dgettext("dashboard_common", "Meeting type (optional)")}
            value={@meeting_type_id}
            prompt={dgettext("dashboard_common", "No meeting type")}
            options={meeting_type_options(@meeting_types)}
            errors={error_list(@errors, :meeting_type_id)}
          />

          <div :if={meeting_type_selected?(@meeting_types, @meeting_type_id)}>
            <input type="hidden" name="poll[duration]" value={@duration} />
            <p class="text-token-sm text-tymeslot-600 mt-8">
              {dgettext("dashboard_common", "Duration: %{minutes} min (from meeting type)",
                minutes: @duration
              )}
            </p>
          </div>
          <.input
            :if={!meeting_type_selected?(@meeting_types, @meeting_type_id)}
            type="number"
            name="poll[duration]"
            label={dgettext("dashboard_common", "Duration (minutes)")}
            value={@duration}
            min="5"
            step="5"
            required
            errors={error_list(@errors, :duration_minutes)}
            icon="hero-clock"
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input
            type="select"
            name="poll[timezone]"
            label={dgettext("dashboard_common", "Timezone")}
            value={@timezone}
            options={Timezones.all_options()}
            errors={error_list(@errors, :timezone)}
          />

          <.input
            type="datetime-local"
            name="poll[deadline]"
            label={dgettext("dashboard_common", "Voting deadline (optional)")}
            value={@deadline}
            errors={error_list(@errors, :deadline_at)}
          />
        </div>

        <div class="space-y-3">
          <div class="flex items-center justify-between">
            <label class="label mb-0">
              {dgettext("dashboard_common", "Candidate times")}
            </label>
            <span class="text-token-xs text-tymeslot-500">
              {dngettext(
                "dashboard_common",
                "%{count} of %{max} time",
                "%{count} of %{max} times",
                length(@slots),
                count: length(@slots),
                max: PollSchema.max_slots()
              )}
            </span>
          </div>

          <div :for={{slot, index} <- Enum.with_index(@slots)} class="flex items-center gap-2">
            <div class="flex-1">
              <.input
                type="datetime-local"
                name={"poll[slots][#{slot.key}]"}
                value={slot.value}
                aria-label={dgettext("dashboard_common", "Candidate time %{n}", n: index + 1)}
              />
            </div>
            <button
              type="button"
              phx-click="remove_slot"
              phx-value-key={slot.key}
              phx-target={@myself}
              class="p-2 rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 transition-colors"
              aria-label={dgettext("dashboard_common", "Remove time")}
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <p :for={error <- error_list(@errors, :slots)} class="form-error">{error}</p>

          <button
            type="button"
            phx-click="add_slot"
            phx-target={@myself}
            class="btn btn-secondary btn-sm inline-flex items-center gap-1"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {dgettext("dashboard_common", "Add time")}
          </button>
        </div>

        <p :for={error <- error_list(@errors, :base)} class="form-error">{error}</p>

        <div class="flex justify-end gap-3 pt-2">
          <button
            type="button"
            phx-click="cancel_poll_form"
            phx-target={@parent_myself}
            class="btn btn-secondary"
          >
            {dgettext("dashboard_common", "Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">
            {dgettext("dashboard_common", "Create poll")}
          </button>
        </div>
      </form>

      <%!-- Availability-based suggestions live outside the main form so the
           date picker never posts with the poll and never nests a form. --%>
      <div class="border-t border-tymeslot-100 pt-5 space-y-3">
        <p class="text-token-sm font-medium text-tymeslot-700">
          {dgettext("dashboard_common", "Suggest times from your availability")}
        </p>
        <form
          id={"poll-suggest-form-#{@id}"}
          phx-submit="suggest_times"
          phx-target={@myself}
          class="flex items-end gap-2 flex-wrap"
        >
          <div class="flex-1 min-w-[12rem]">
            <.input
              type="date"
              name="date"
              value={@suggest_date}
              aria-label={dgettext("dashboard_common", "Suggest times for date")}
            />
          </div>
          <button type="submit" class="btn btn-secondary">
            {dgettext("dashboard_common", "Suggest times")}
          </button>
        </form>

        <p :if={@suggest_error} class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_common",
            "Couldn't load your availability. Add times manually instead."
          )}
        </p>

        <div :if={@suggestions == []} class="text-token-sm text-tymeslot-500">
          {dgettext("dashboard_common", "No free times on that date.")}
        </div>

        <div :if={is_list(@suggestions) and @suggestions != []} class="flex flex-wrap gap-2">
          <button
            :for={time <- @suggestions}
            type="button"
            phx-click="add_suggested_slot"
            phx-value-time={time}
            phx-target={@myself}
            class="px-3 py-1.5 rounded-token-full bg-turquoise-50 border border-turquoise-200 text-turquoise-700 text-token-sm font-medium hover:bg-turquoise-100 transition-colors"
          >
            {time}
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("form_change", %{"poll" => params}, socket) do
    meeting_type_id = Map.get(params, "meeting_type_id", socket.assigns.meeting_type_id)
    duration = resolve_duration(params, meeting_type_id, socket)

    {:noreply,
     assign(socket,
       title: Map.get(params, "title", socket.assigns.title),
       description: Map.get(params, "description", socket.assigns.description),
       meeting_type_id: meeting_type_id,
       duration: duration,
       deadline: Map.get(params, "deadline", socket.assigns.deadline),
       timezone: Map.get(params, "timezone", socket.assigns.timezone),
       slots: merge_slot_values(socket.assigns.slots, Map.get(params, "slots", %{}))
     )}
  end

  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_event("add_slot", _params, socket) do
    {:noreply, append_slot(socket, "")}
  end

  @impl Phoenix.LiveComponent
  def handle_event("remove_slot", %{"key" => key}, socket) do
    key = String.to_integer(key)
    slots = Enum.reject(socket.assigns.slots, &(&1.key == key))
    {:noreply, assign(socket, slots: slots, errors: Map.delete(socket.assigns.errors, :slots))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("suggest_times", %{"date" => date}, socket) when date != "" do
    case fetch_suggestions(socket, date) do
      {:ok, times} ->
        {:noreply, assign(socket, suggestions: times, suggest_date: date, suggest_error: false)}

      :error ->
        {:noreply, assign(socket, suggestions: nil, suggest_date: date, suggest_error: true)}
    end
  end

  def handle_event("suggest_times", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_event("add_suggested_slot", %{"time" => time}, socket) do
    {:noreply, append_slot(socket, suggested_slot_value(socket.assigns.suggest_date, time))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_poll", %{"poll" => params}, socket) do
    attrs = build_attrs(params, socket)

    case Polls.create_poll(socket.assigns.current_user.id, attrs) do
      {:ok, _poll} ->
        Flash.info(dgettext("dashboard_common", "Poll created"))
        send_update(PollsComponent, id: socket.assigns.parent_id, poll_created: true)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :errors, errors_for(reason))}
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

  # Availability suggestions come back display-formatted ("9:00 AM"); a
  # datetime-local value needs 24-hour "HH:MM", so parse and reformat.
  defp suggested_slot_value(date, time) do
    case DateTimeUtils.parse_time_string(time) do
      {:ok, %Time{} = parsed} -> "#{date}T#{Calendar.strftime(parsed, "%H:%M")}"
      _other -> "#{date}T#{time}"
    end
  end

  defp merge_slot_values(slots, values) do
    Enum.map(slots, fn %{key: key} = slot ->
      %{slot | value: Map.get(values, Integer.to_string(key), slot.value)}
    end)
  end

  # --- Availability suggestions ---

  defp fetch_suggestions(socket, date) do
    user = socket.assigns.current_user
    profile = socket.assigns.profile
    timezone = socket.assigns.timezone
    duration = parse_duration(socket.assigns.duration)
    context = %{organizer_profile: profile}

    # Unlinked + supervised: a crash or timeout in the availability calc must
    # never take down the LiveView. Fall back to manual entry instead.
    task =
      Task.Supervisor.async_nolink(Tymeslot.TaskSupervisor, fn ->
        AvailabilityHelpers.get_available_slots(
          date,
          duration,
          timezone,
          user.id,
          profile,
          context
        )
      end)

    case Task.yield(task, @suggest_timeout) || Task.shutdown(task) do
      {:ok, {:ok, times}} when is_list(times) -> {:ok, times}
      _other -> :error
    end
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
      deadline_at: to_utc(Map.get(params, "deadline"), timezone),
      slots: build_slots(Map.get(params, "slots", %{}), timezone)
    }
  end

  defp build_slots(values, timezone) do
    values
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(key) end)
    |> Enum.map(fn {_key, value} -> to_utc(value, timezone) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn start_time -> %{start_time: start_time} end)
  end

  defp to_utc(value, _timezone) when value in [nil, ""], do: nil

  defp to_utc(value, timezone) do
    with {:ok, naive} <- parse_naive(value),
         {:ok, datetime} <- DateTimeUtils.convert_to_utc(naive, timezone) do
      DateTime.truncate(datetime, :second)
    else
      _other -> nil
    end
  end

  defp parse_naive(value) do
    normalized = if String.length(value) == 16, do: value <> ":00", else: value
    NaiveDateTime.from_iso8601(normalized)
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

  defp errors_for(:no_slots),
    do: %{slots: [dgettext("dashboard_common", "Add at least one candidate time")]}

  defp errors_for(:too_many_slots), do: %{slots: [too_many_message()]}

  defp errors_for(:slot_in_past),
    do: %{slots: [dgettext("dashboard_common", "Times must be in the future")]}

  defp errors_for(:payment_required_type),
    do: %{
      meeting_type_id: [
        dgettext("dashboard_common", "Paid meeting types can't be used for polls")
      ]
    }

  defp errors_for(:meeting_type_not_found),
    do: %{meeting_type_id: [dgettext("dashboard_common", "That meeting type is unavailable")]}

  defp errors_for(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp errors_for(_other),
    do: %{base: [dgettext("dashboard_common", "Something went wrong. Please try again.")]}

  defp too_many_message,
    do: dgettext("dashboard_common", "Up to %{max} times", max: PollSchema.max_slots())
end
