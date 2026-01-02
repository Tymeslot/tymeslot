defmodule TymeslotWeb.Dashboard.Availability.ListComponent do
  @moduledoc """
  LiveView component for the list-based availability management interface.
  Handles the traditional day-by-day list view with detailed settings.
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Availability.{AvailabilityActions, Breaks}
  alias Tymeslot.Security.{AvailabilityInputProcessor, RateLimiter}
  alias TymeslotWeb.Components.Dashboard.Availability.{ClearDayModal, DeleteBreakModal}
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Dashboard.Availability.Helpers
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash

  # UI Helper Functions

  @impl true
  def mount(socket) do
    {:ok, ModalHook.mount_modal(socket, delete_break: false, clear_day: false)}
  end

  @impl true
  def update(assigns, socket) do
    # Get timezone info from profile
    profile = assigns.profile
    timezone_info = Helpers.get_timezone_info(profile)

    socket =
      socket
      |> assign(assigns)
      |> assign(timezone_info)
      |> assign(break_duration_presets: Breaks.get_break_duration_presets())
      |> assign(form_errors: %{})
      |> assign_new(:show_delete_break_modal, fn -> false end)
      |> assign_new(:show_clear_day_modal, fn -> false end)
      |> assign_new(:delete_break_modal_data, fn -> nil end)
      |> assign_new(:clear_day_modal_data, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_day_available", %{"day" => day_str}, socket) do
    with {:ok, day} <- parse_day(day_str),
         %{} = current_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         {:ok, _updated} <-
           AvailabilityActions.toggle_day_availability(
             profile_id(socket),
             day,
             current_availability.is_available
           ) do
      send(self(), {:flash, {:info, "#{AvailabilityActions.day_name(day)} availability updated"}})

      updated_schedule = toggle_day_in_schedule(socket.assigns.weekly_schedule, day)
      send(self(), {:reload_schedule})
      {:noreply, assign(socket, :weekly_schedule, updated_schedule)}
    else
      {:error, _changeset} ->
        Flash.error("Failed to update availability")
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # Validation event handlers
  def handle_event("validate_day_hours", params, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    case AvailabilityInputProcessor.validate_day_hours(params, metadata: metadata) do
      {:ok, _sanitized_params} ->
        {:noreply, assign(socket, :form_errors, %{})}

      {:error, errors} ->
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  def handle_event("validate_break", params, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    # Since we're using dropdowns with pre-validated time options,
    # we'll skip showing validation errors during phx-change events.
    # The validation still runs for security logging purposes.
    case AvailabilityInputProcessor.validate_break_input(params, metadata: metadata) do
      {:ok, _sanitized_params} ->
        {:noreply, assign(socket, :form_errors, %{})}

      {:error, _errors} ->
        # Don't show validation errors on change events for dropdown inputs
        # The actual validation will still happen on submit
        {:noreply, socket}
    end
  end

  def handle_event(
        "update_day_hours",
        params,
        socket
      ) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    do_update_day_hours(params, socket, metadata)
  end

  def handle_event(
        "add_break",
        %{"day" => day_str, "start" => start_str, "end" => end_str, "label" => label},
        socket
      ) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    with {:ok, day} <- parse_day(day_str),
         :ok <- check_rate_limit(socket, "availability:add_break", 8, 60_000),
         %{} = day_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         {:ok, sanitized_params} <-
           AvailabilityInputProcessor.validate_break_input(
             %{"start" => start_str, "end" => end_str, "label" => label},
             metadata: metadata
           ) do
      case AvailabilityActions.add_break(
             day_availability.id,
             sanitized_params["start"],
             sanitized_params["end"],
             sanitized_params["label"]
           ) do
        {:ok, _break} ->
          Flash.info("Break added")
          send(self(), {:reload_schedule})
          socket = assign(socket, :form_errors, %{})
          {:noreply, socket}

        {:error, :invalid_time_format} ->
          Flash.error("Invalid time format")
          {:noreply, socket}
      end
    else
      nil ->
        {:noreply, socket}

      {:error, validation_errors} ->
        socket = assign(socket, :form_errors, validation_errors)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  catch
    :throw, :halt -> {:noreply, socket}
  end

  def handle_event("show_delete_break_modal", %{"break_id" => break_id}, socket) do
    break_id = String.to_integer(break_id)
    # Find the break details from the schedule
    break_info = find_break_info(socket.assigns.weekly_schedule, break_id)

    {:noreply, ModalHook.show_modal(socket, :delete_break, %{id: break_id, info: break_info})}
  end

  def handle_event("hide_delete_break_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete_break)}
  end

  def handle_event("confirm_delete_break", _params, socket) do
    break_data = socket.assigns.delete_break_modal_data

    case AvailabilityActions.delete_break(break_data.id) do
      {:ok, _break} ->
        Flash.info("Break deleted")
        send(self(), {:reload_schedule})
        {:noreply, ModalHook.hide_modal(socket, :delete_break)}

      {:error, _} ->
        Flash.error("Failed to delete break")
        {:noreply, socket}
    end
  end

  def handle_event(
        "quick_break",
        %{"day" => day_str, "start" => start_str, "duration" => duration_str},
        socket
      ) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    with {:ok, day} <- parse_day(day_str),
         :ok <- check_rate_limit(socket, "availability:quick_break", 8, 60_000),
         %{} = day_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         {:ok, sanitized_params} <-
           AvailabilityInputProcessor.validate_quick_break_input(
             %{"start" => start_str, "duration" => duration_str},
             metadata: metadata
           ) do
      duration = String.to_integer(sanitized_params["duration"])

      case AvailabilityActions.add_quick_break(
             day_availability.id,
             sanitized_params["start"],
             duration
           ) do
        {:ok, _break} ->
          Flash.info("Quick break added")
          send(self(), {:reload_schedule})
          socket = assign(socket, :form_errors, %{})
          {:noreply, socket}

        {:error, :invalid_time_format} ->
          Flash.error("Invalid time format")
          {:noreply, socket}
      end
    else
      nil ->
        {:noreply, socket}

      {:error, validation_errors} ->
        socket = assign(socket, :form_errors, validation_errors)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  catch
    :throw, :halt -> {:noreply, socket}
  end

  def handle_event(
        "copy_to_days",
        %{"from_day" => from_day_str, "to_days" => to_days_str},
        socket
      ) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    with {:ok, from_day} <- parse_day(from_day_str),
         {:ok, to_days} <-
           AvailabilityInputProcessor.validate_day_selections(to_days_str, metadata: metadata),
         {:ok, _} <- AvailabilityActions.copy_day_settings(profile_id(socket), from_day, to_days) do
      day_names = Enum.map_join(to_days, ", ", &AvailabilityActions.day_name/1)
      Flash.info("Settings copied to #{day_names}")
      send(self(), {:reload_schedule})
      {:noreply, socket}
    else
      {:error, validation_error} when is_binary(validation_error) ->
        Flash.error(validation_error)
        {:noreply, socket}

      {:error, _} ->
        Flash.error("Failed to copy settings")
        {:noreply, socket}
    end
  end

  def handle_event("show_clear_day_modal", %{"day" => day_str}, socket) do
    case parse_day(day_str) do
      {:ok, day} ->
        day_name = AvailabilityActions.day_name(day)

        {:noreply, ModalHook.show_modal(socket, :clear_day, %{day: day, day_name: day_name})}
    end
  end

  def handle_event("hide_clear_day_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :clear_day)}
  end

  def handle_event("confirm_clear_day", _params, socket) do
    day_data = socket.assigns.clear_day_modal_data

    case AvailabilityActions.clear_day_settings(profile_id(socket), day_data.day) do
      {:ok, _} ->
        Flash.info("#{day_data.day_name} settings cleared")
        send(self(), {:reload_schedule})
        {:noreply, ModalHook.hide_modal(socket, :clear_day)}

      {:error, _} ->
        Flash.error("Failed to clear day settings")
        {:noreply, socket}
    end
  end

  # Helper Functions

  defp do_update_day_hours(params, socket, metadata) do
    with {:ok, day} <- parse_day(params),
         :ok <- check_rate_limit(socket, "availability:update_hours", 10, 10_000),
         %{} = day_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         strings <- resolve_day_strings(params, day_availability),
         {:ok, sanitized_params} <-
           AvailabilityInputProcessor.validate_day_hours(strings, metadata: metadata),
         result <-
           AvailabilityActions.update_day_hours(
             profile_id(socket),
             day,
             sanitized_params["start"],
             sanitized_params["end"]
           ) do
      handle_update_day_hours_result(day, result, socket)
    else
      nil ->
        {:noreply, socket}

      {:error, validation_errors} ->
        {:noreply, assign(socket, :form_errors, validation_errors)}
    end
  catch
    :throw, :halt -> {:noreply, socket}
  end

  defp resolve_day_strings(params, day_availability) do
    %{
      "start" => params["start"] || format_time(day_availability.start_time),
      "end" => params["end"] || format_time(day_availability.end_time)
    }
  end

  defp handle_update_day_hours_result(day, result, socket) do
    case result do
      {:ok, _updated} ->
        Flash.info("#{AvailabilityActions.day_name(day)} hours updated")
        send(self(), {:reload_schedule})
        {:noreply, assign(socket, :form_errors, %{})}

      {:error, :invalid_time_format} ->
        Flash.error("Invalid time format")
        {:noreply, socket}
    end
  end

  defp find_break_info(weekly_schedule, break_id) do
    Enum.reduce_while(weekly_schedule, nil, fn day_availability, acc ->
      break = Enum.find(day_availability.breaks || [], &(&1.id == break_id))
      if break, do: {:halt, break}, else: {:cont, acc}
    end)
  end

  defp toggle_day_in_schedule(schedule, day) do
    Enum.map(schedule, fn day_avail ->
      if day_avail.day_of_week == day do
        %{day_avail | is_available: !day_avail.is_available}
      else
        day_avail
      end
    end)
  end

  # Prefer using AvailabilityActions.get_day_from_schedule/2 across handlers

  defp format_time(nil), do: ""
  defp format_time(time), do: Calendar.strftime(time, "%H:%M")

  # Small helpers to reduce duplication
  defp parse_day(params_or_str) do
    str =
      cond do
        is_map(params_or_str) -> params_or_str["day"] || ""
        is_binary(params_or_str) -> params_or_str
        true -> ""
      end

    case Integer.parse(str) do
      {day, ""} when day in 1..7 -> {:ok, day}
      _ -> {:error, :invalid_day}
    end
  end

  defp profile_id(socket), do: socket.assigns.profile.id

  defp check_rate_limit(socket, action_prefix, limit, window_ms) do
    key = "#{action_prefix}:#{profile_id(socket)}"

    case RateLimiter.check_rate_limit(key, limit, window_ms) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        Flash.error("You’re adding breaks too quickly. Please wait a bit.")
        throw(:halt)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Timezone Display Header -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-6 space-y-2 sm:space-y-0">
        <h2 class="text-xl font-semibold text-gray-800">Weekly Schedule</h2>
        <Helpers.timezone_display timezone_display={@timezone_display} country_code={@country_code} />
      </div>
      
    <!-- Weekly Schedule -->
      <div class="space-y-1">
        <%= for day_availability <- @weekly_schedule do %>
          <.day_card
            day_availability={day_availability}
            day_name={AvailabilityActions.day_name(day_availability.day_of_week)}
            break_duration_presets={@break_duration_presets}
            form_errors={@form_errors}
            myself={@myself}
          />
        <% end %>
      </div>

      <DeleteBreakModal.delete_break_modal
        id="delete-break-modal"
        show={@show_delete_break_modal}
        break_data={@delete_break_modal_data}
        on_cancel={JS.push("hide_delete_break_modal", target: @myself)}
        on_confirm={JS.push("confirm_delete_break", target: @myself)}
      />

      <ClearDayModal.clear_day_modal
        id="clear-day-modal"
        show={@show_clear_day_modal}
        day_data={@clear_day_modal_data}
        on_cancel={JS.push("hide_clear_day_modal", target: @myself)}
        on_confirm={JS.push("confirm_clear_day", target: @myself)}
      />
    </div>
    """
  end

  defp day_card(assigns) do
    ~H"""
    <div class={[
      "card-glass",
      if(@day_availability.is_available, do: "card-glass-available", else: "card-glass-unavailable")
    ]}>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-4 space-y-3 sm:space-y-0">
        <h3 class="text-lg font-medium text-gray-800">{@day_name}</h3>
        <div class="flex items-center space-x-4">
          <button
            phx-click="toggle_day_available"
            phx-value-day={@day_availability.day_of_week}
            phx-target={@myself}
            class={[
              "relative inline-flex h-8 w-16 flex-shrink-0 cursor-pointer rounded-full border-2 transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-purple-500 focus:ring-offset-2",
              if(@day_availability.is_available,
                do: "bg-green-500 border-green-500",
                else: "bg-gray-300 border-gray-300"
              )
            ]}
            role="switch"
            aria-checked={@day_availability.is_available}
            aria-label={"Toggle #{@day_name} availability"}
          >
            <span class={[
              "pointer-events-none absolute top-0.5 inline-block h-7 w-7 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
              if(@day_availability.is_available, do: "translate-x-8", else: "translate-x-0")
            ]}>
              <span class={[
                "absolute inset-0 flex h-full w-full items-center justify-center transition-opacity duration-200 ease-in-out",
                if(@day_availability.is_available, do: "opacity-0", else: "opacity-100")
              ]}>
                <svg class="h-3 w-3 text-gray-400" fill="none" viewBox="0 0 12 12">
                  <path
                    d="M4 8l2-2m0 0l2-2M6 6L4 4m2 2l2 2"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                </svg>
              </span>
              <span class={[
                "absolute inset-0 flex h-full w-full items-center justify-center transition-opacity duration-200 ease-in-out",
                if(@day_availability.is_available, do: "opacity-100", else: "opacity-0")
              ]}>
                <svg class="h-3 w-3 text-green-600" fill="currentColor" viewBox="0 0 12 12">
                  <path d="M3.707 5.293a1 1 0 00-1.414 1.414l1.414-1.414zM5 7l-.707.707a1 1 0 001.414 0L5 7zm4.707-3.293a1 1 0 00-1.414-1.414l1.414 1.414zm-7.414 2l2 2 1.414-1.414-2-2-1.414 1.414zm3.414 2l4-4-1.414-1.414-4 4 1.414 1.414z" />
                </svg>
              </span>
            </span>
          </button>
          <span class={[
            "text-sm font-medium availability-status",
            if(@day_availability.is_available, do: "text-green-600", else: "text-gray-500")
          ]}>
            {if @day_availability.is_available, do: "Available", else: "Unavailable"}
          </span>
        </div>
      </div>

      <%= if @day_availability.is_available do %>
        <!-- Work Hours -->
        <div class="mb-4">
          <form phx-change="update_day_hours" phx-target={@myself} phx-debounce="500">
            <input type="hidden" name="day" value={@day_availability.day_of_week} />
            <div class="flex flex-col sm:flex-row sm:items-center space-y-3 sm:space-y-0 sm:space-x-4">
              <div class="flex-1 sm:flex-initial">
                <label class="text-sm text-gray-600">Start</label>
                <select name="start" class="glass-input time-select w-full sm:w-32">
                  <%= for {label, value} <- TimeOptions.time_options() do %>
                    <option
                      value={value}
                      selected={value == format_time(@day_availability.start_time)}
                    >
                      {label}
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="flex-1 sm:flex-initial">
                <label class="text-sm text-gray-600">End</label>
                <select name="end" class="glass-input time-select w-full sm:w-32">
                  <%= for {label, value} <- TimeOptions.time_options() do %>
                    <option value={value} selected={value == format_time(@day_availability.end_time)}>
                      {label}
                    </option>
                  <% end %>
                </select>
              </div>
            </div>
          </form>
        </div>
        
    <!-- Breaks -->
        <div class="mb-4">
          <h4 class="text-md font-medium text-gray-700 mb-3">Breaks</h4>

          <% breaks =
            case @day_availability.breaks do
              %Ecto.Association.NotLoaded{} -> []
              b when is_list(b) -> b
              _ -> []
            end %>

          <%= if breaks != [] do %>
            <div class="flex flex-wrap gap-2 mb-4">
              <%= for break <- breaks do %>
                <div class="inline-flex items-center bg-white/20 backdrop-blur-sm border border-purple-300/40 rounded-full px-3 py-1 text-sm">
                  <span class="font-medium text-gray-700 mr-2">{break.label || "Break"}</span>
                  <span class="text-gray-600 mr-2">
                    {format_time(break.start_time)} - {format_time(break.end_time)}
                  </span>
                  <button
                    phx-click="show_delete_break_modal"
                    phx-value-break_id={break.id}
                    phx-target={@myself}
                    class="ml-1 text-red-400 hover:text-red-600 hover:bg-red-100/30 hover:scale-110 rounded-full p-1 transition-all duration-200"
                    title="Delete Break"
                  >
                    <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
          
    <!-- Add Break Form -->
          <form
            phx-submit="add_break"
            phx-change="validate_break"
            phx-target={@myself}
            class="flex flex-col lg:flex-row gap-3 lg:gap-4 lg:items-end"
          >
            <input type="hidden" name="day" value={@day_availability.day_of_week} />
            <div class="lg:w-40">
              <label class="text-sm text-gray-600 font-medium mb-1 block">Break Label</label>
              <input
                type="text"
                name="label"
                placeholder="e.g., Lunch Break"
                class={[
                  "glass-input text-sm w-full",
                  if(@form_errors[:label], do: "border-red-500", else: "")
                ]}
              />
              <%= if @form_errors[:label] do %>
                <p class="text-xs text-red-400 mt-1">{@form_errors[:label]}</p>
              <% end %>
            </div>
            <div class="lg:w-32">
              <label class="text-sm text-gray-600 font-medium mb-1 block">Start Time</label>
              <select
                name="start"
                required
                class={[
                  "glass-input time-select text-sm w-full",
                  if(@form_errors[:start_time], do: "border-red-500", else: "")
                ]}
              >
                <option value="">Select time</option>
                <%= for {label, value} <- TimeOptions.time_options() do %>
                  <option value={value}>{label}</option>
                <% end %>
              </select>
              <%= if @form_errors[:start_time] do %>
                <p class="text-xs text-red-400 mt-1">{@form_errors[:start_time]}</p>
              <% end %>
            </div>
            <div class="lg:w-32">
              <label class="text-sm text-gray-600 font-medium mb-1 block">End Time</label>
              <select
                name="end"
                required
                class={[
                  "glass-input time-select text-sm w-full",
                  if(@form_errors[:end_time], do: "border-red-500", else: "")
                ]}
              >
                <option value="">Select time</option>
                <%= for {label, value} <- TimeOptions.time_options() do %>
                  <option value={value}>{label}</option>
                <% end %>
              </select>
              <%= if @form_errors[:end_time] do %>
                <p class="text-xs text-red-400 mt-1">{@form_errors[:end_time]}</p>
              <% end %>
            </div>
            <div class="lg:w-32">
              <button
                type="submit"
                class="btn btn-sm btn-primary w-full h-[38px] flex items-center justify-center"
              >
                <svg class="w-4 h-4 mr-1.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 4v16m8-8H4"
                  />
                </svg>
                Add Break
              </button>
            </div>
          </form>
        </div>
        
    <!-- Copy Settings -->
        <div class="flex flex-wrap gap-2 mt-4">
          <button
            phx-click="copy_to_days"
            phx-value-from_day={@day_availability.day_of_week}
            phx-value-to_days="1,2,3,4,5,6,7"
            phx-target={@myself}
            class="btn btn-sm btn-secondary"
          >
            <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
              />
            </svg>
            Copy to all days
          </button>
          <button
            phx-click="copy_to_days"
            phx-value-from_day={@day_availability.day_of_week}
            phx-value-to_days="1,2,3,4,5"
            phx-target={@myself}
            class="btn btn-sm btn-secondary"
          >
            <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
              />
            </svg>
            Copy to weekdays
          </button>
          <button
            phx-click="show_clear_day_modal"
            phx-value-day={@day_availability.day_of_week}
            phx-target={@myself}
            class="btn btn-sm btn-danger"
          >
            <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
            Clear
          </button>
        </div>
      <% else %>
        <p class="text-gray-500 text-sm">Not available on this day</p>
      <% end %>
    </div>
    """
  end
end
