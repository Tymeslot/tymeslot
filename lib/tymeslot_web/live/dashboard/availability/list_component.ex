defmodule TymeslotWeb.Dashboard.Availability.ListComponent do
  @moduledoc """
  LiveView component for the list-based availability management interface.
  Handles the traditional day-by-day list view with detailed settings.
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Availability.{AvailabilityActions, Breaks}
  alias Tymeslot.Availability.InputValidation, as: AvailabilityInputValidation
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.Dashboard.Availability.{ClearDayModal, DeleteBreakModal}
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Dashboard.Availability.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  # UI Helper Functions

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> ModalHook.mount_modal(delete_break: false, clear_day: false)
     |> assign(show_add_break_form: nil)}
  end

  @impl Phoenix.LiveComponent
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
      |> assign_new(:show_add_break_form, fn -> nil end)
      |> assign_new(:show_delete_break_modal, fn -> false end)
      |> assign_new(:show_clear_day_modal, fn -> false end)
      |> assign_new(:delete_break_modal_data, fn -> nil end)
      |> assign_new(:clear_day_modal_data, fn -> nil end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_day_available", %{"day" => day_str}, socket) do
    with {:ok, day} <- parse_day(day_str),
         %{} = current_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         {:ok, updated_day} <-
           AvailabilityActions.toggle_day_availability(
             profile_id(socket),
             day,
             current_availability.is_available
           ) do
      send(self(), {:flash, {:info, "#{AvailabilityActions.day_name(day)} availability updated"}})

      updated_schedule = update_day_in_schedule(socket.assigns.weekly_schedule, updated_day)
      send(self(), {:reload_schedule})

      {:noreply, assign(socket, :weekly_schedule, updated_schedule)}
    else
      {:error, _changeset} ->
        Flash.error("Failed to update availability")
        {:noreply, socket}

      _other ->
        {:noreply, socket}
    end
  end

  # Validation event handlers
  def handle_event("validate_day_hours", params, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    case AvailabilityInputValidation.validate_day_hours(params, metadata: metadata) do
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
    case AvailabilityInputValidation.validate_break_input(params, metadata: metadata) do
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
           AvailabilityInputValidation.validate_break_input(
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

          socket =
            socket
            |> assign(:form_errors, %{})
            |> assign(:show_add_break_form, nil)

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

      _other ->
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

  def handle_event("show_add_break_form", %{"day" => day_str}, socket) do
    case parse_day(day_str) do
      {:ok, day} ->
        {:noreply, assign(socket, :show_add_break_form, day)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("hide_add_break_form", _params, socket) do
    {:noreply, assign(socket, :show_add_break_form, nil)}
  end

  def handle_event("confirm_delete_break", _params, socket) do
    break_data = socket.assigns.delete_break_modal_data

    case AvailabilityActions.delete_break(break_data.id, profile_id(socket)) do
      {:ok, _break} ->
        Flash.info("Break deleted")
        send(self(), {:reload_schedule})

        {:noreply, ModalHook.hide_modal(socket, :delete_break)}

      {:error, _reason} ->
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
           AvailabilityInputValidation.validate_quick_break_input(
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

          socket =
            socket
            |> assign(:form_errors, %{})
            |> assign(:show_add_break_form, nil)

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

      _other ->
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
           AvailabilityInputValidation.validate_day_selections(to_days_str, metadata: metadata),
         {:ok, _result} <-
           AvailabilityActions.copy_day_settings(profile_id(socket), from_day, to_days) do
      day_names = Enum.map_join(to_days, ", ", &AvailabilityActions.day_name/1)
      Flash.info("Settings copied to #{day_names}")
      send(self(), {:reload_schedule})

      {:noreply, socket}
    else
      {:error, validation_error} when is_binary(validation_error) ->
        Flash.error(validation_error)
        {:noreply, socket}

      {:error, _reason} ->
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
      {:ok, _result} ->
        Flash.info("#{day_data.day_name} settings cleared")
        send(self(), {:reload_schedule})

        {:noreply, ModalHook.hide_modal(socket, :clear_day)}

      {:error, _reason} ->
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
           AvailabilityInputValidation.validate_day_hours(strings, metadata: metadata),
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

  defp update_day_in_schedule(schedule, updated_day) do
    Enum.map(schedule, fn day_avail ->
      if day_avail.day_of_week == updated_day.day_of_week do
        updated_day
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
      _other -> {:error, :invalid_day}
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

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <%!-- Timezone Display Header --%>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-6 space-y-2 sm:space-y-0">
        <.section_header
          level={2}
          title="Weekly Schedule"
        />
        <Helpers.timezone_display timezone_display={@timezone_display} country_code={@country_code} />
      </div>

    <%!-- Weekly Schedule --%>
      <div class="space-y-1">
        <%= for day_availability <- @weekly_schedule do %>
          <.day_card
            day_availability={day_availability}
            day_name={AvailabilityActions.day_name(day_availability.day_of_week)}
            break_duration_presets={@break_duration_presets}
            form_errors={@form_errors}
            show_add_break_form={@show_add_break_form}
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
      "card-glass group/day transition-all duration-300",
      if(@day_availability.is_available,
        do: "border-turquoise-100 bg-white shadow-2xl shadow-turquoise-500/5",
        else: "opacity-60 bg-tymeslot-50 border-tymeslot-100 hover:opacity-100"
      )
    ]}>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-4 gap-4">
        <div class="flex items-center gap-4">
          <div class={[
            "w-12 h-12 rounded-token-xl flex items-center justify-center font-black transition-all",
            if(@day_availability.is_available,
              do: "bg-turquoise-600 text-white shadow-lg shadow-turquoise-500/30",
              else: "bg-tymeslot-200 text-tymeslot-500"
            )
          ]}>
            {String.slice(@day_name, 0, 1)}
          </div>
          <h3 class="text-token-2xl font-black text-tymeslot-900 tracking-tight group-hover/day:text-turquoise-700 transition-colors">
            {@day_name}
          </h3>
        </div>

        <div class="flex items-center gap-4 bg-tymeslot-50 p-2 rounded-token-2xl border border-tymeslot-100">
          <button
            phx-click="toggle_day_available"
            phx-value-day={@day_availability.day_of_week}
            phx-target={@myself}
            class={[
              "relative inline-flex h-9 w-16 flex-shrink-0 cursor-pointer rounded-full border-2 transition-all duration-300 ease-in-out focus:outline-none",
              if(@day_availability.is_available,
                do: "bg-turquoise-600 border-turquoise-600",
                else: "bg-tymeslot-300 border-tymeslot-300"
              )
            ]}
            role="switch"
            aria-checked={@day_availability.is_available}
          >
            <span class={[
              "pointer-events-none absolute top-1 left-1 inline-block h-7 w-7 transform rounded-full bg-white shadow-lg ring-0 transition duration-300 ease-in-out",
              if(@day_availability.is_available, do: "translate-x-7", else: "translate-x-0")
            ]}>
            </span>
          </button>
          <div class="w-24 text-left">
            <span class={[
              "text-token-sm font-black uppercase tracking-wider",
              if(@day_availability.is_available, do: "text-turquoise-700", else: "text-tymeslot-400")
            ]}>
              {if @day_availability.is_available, do: "Available", else: "Off"}
            </span>
          </div>
        </div>
      </div>

      <%= if @day_availability.is_available do %>
        <%!-- Work Hours --%>
        <div class="mb-6 pb-6 border-b-2 border-tymeslot-50">
          <form phx-change="update_day_hours" phx-target={@myself} phx-debounce="500">
            <input type="hidden" name="day" value={@day_availability.day_of_week} />
            <div class="flex flex-col sm:flex-row sm:items-center gap-6">
              <div class="flex-1">
                <.input
                  type="select"
                  name="start"
                  label="Start Time"
                  options={TimeOptions.time_options()}
                  value={format_time(@day_availability.start_time)}
                />
              </div>
              <div class="flex-1">
                <.input
                  type="select"
                  name="end"
                  label="End Time"
                  options={TimeOptions.time_options()}
                  value={format_time(@day_availability.end_time)}
                />
              </div>
            </div>
          </form>
        </div>

    <%!-- Breaks --%>
        <div class="space-y-4">
          <div class="flex items-center justify-between gap-3">
            <div class="flex items-center gap-3">
              <h4 class="text-token-lg font-black text-tymeslot-900 tracking-tight">Breaks</h4>
              <% breaks =
                case @day_availability.breaks do
                  %Ecto.Association.NotLoaded{} -> []
                  b when is_list(b) -> b
                  _other -> []
                end %>
              <span class="bg-tymeslot-100 text-tymeslot-500 text-token-2xs font-black uppercase tracking-widest px-2 py-0.5 rounded-md">
                {length(breaks)} total
              </span>
            </div>

            <%= if @show_add_break_form != @day_availability.day_of_week do %>
              <button
                phx-click="show_add_break_form"
                phx-value-day={@day_availability.day_of_week}
                phx-target={@myself}
                class="btn-secondary py-2 px-3 text-token-xs flex items-center whitespace-nowrap"
              >
                <svg class="w-3.5 h-3.5 mr-1.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 4v16m8-8H4" />
                </svg>
                Add Break
              </button>
            <% end %>
          </div>

          <%= if breaks != [] do %>
            <div class="flex flex-wrap gap-3">
              <%= for break <- breaks do %>
                <div class="inline-flex items-center bg-white border-2 border-tymeslot-100 rounded-token-xl px-4 py-2 text-token-sm font-bold text-tymeslot-700 shadow-sm group/break hover:border-turquoise-200 transition-all">
                  <span class="mr-3">{break.label || "Break"}</span>
                  <span class="text-turquoise-600">
                    {format_time(break.start_time)} - {format_time(break.end_time)}
                  </span>
                  <button
                    phx-click="show_delete_break_modal"
                    phx-value-break_id={break.id}
                    phx-target={@myself}
                    class="ml-3 text-tymeslot-300 hover:text-red-500 transition-colors"
                    title="Delete Break"
                  >
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>

    <%!-- Add Break Form --%>
          <%= if @show_add_break_form == @day_availability.day_of_week do %>
            <form
              phx-submit="add_break"
              phx-change="validate_break"
              phx-target={@myself}
              class="grid grid-cols-1 lg:grid-cols-4 gap-4 items-end bg-tymeslot-50/50 p-4 rounded-token-2xl border-2 border-tymeslot-50"
            >
              <input type="hidden" name="day" value={@day_availability.day_of_week} />
              <div class="lg:col-span-1">
                <.input
                  name="label"
                  label="Label"
                  placeholder="e.g. Lunch"
                  maxlength={Constraints.break_label_max_length()}
                  errors={FormValidationHelpers.field_errors(@form_errors, :label)}
                />
              </div>
              <div>
                <.input
                  type="select"
                  name="start"
                  label="From"
                  required
                  prompt="Start"
                  options={TimeOptions.time_options()}
                  errors={FormValidationHelpers.field_errors(@form_errors, :start_time)}
                />
              </div>
              <div>
                <.input
                  type="select"
                  name="end"
                  label="Until"
                  required
                  prompt="End"
                  options={TimeOptions.time_options()}
                  errors={FormValidationHelpers.field_errors(@form_errors, :end_time)}
                />
              </div>
              <div class="flex gap-2">
                <button type="submit" class="btn-primary flex-1 py-3 flex items-center justify-center whitespace-nowrap">
                  <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 4v16m8-8H4" />
                  </svg>
                  Add
                </button>
                <button
                  type="button"
                  phx-click="hide_add_break_form"
                  phx-target={@myself}
                  class="btn-secondary px-3 py-3"
                  title="Cancel"
                >
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>
            </form>
          <% end %>
        </div>

    <%!-- Action Bar --%>
        <div class="flex flex-wrap items-center justify-between gap-4 mt-6 pt-6 border-t-2 border-tymeslot-50">
          <div class="flex flex-wrap gap-3">
            <button
              phx-click="copy_to_days"
              phx-value-from_day={@day_availability.day_of_week}
              phx-value-to_days="1,2,3,4,5,6,7"
              phx-target={@myself}
              class="btn-secondary py-2 px-4 text-token-xs flex items-center whitespace-nowrap"
            >
              <svg class="w-3.5 h-3.5 mr-2 text-tymeslot-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4" />
              </svg>
              Apply to All Days
            </button>
            <button
              phx-click="copy_to_days"
              phx-value-from_day={@day_availability.day_of_week}
              phx-value-to_days="1,2,3,4,5"
              phx-target={@myself}
              class="btn-secondary py-2 px-4 text-token-xs flex items-center whitespace-nowrap"
            >
              <svg class="w-3.5 h-3.5 mr-2 text-tymeslot-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4" />
              </svg>
              Apply to Workdays
            </button>
          </div>
          <button
            phx-click="show_clear_day_modal"
            phx-value-day={@day_availability.day_of_week}
            phx-target={@myself}
            class="text-tymeslot-400 hover:text-red-600 text-token-xs font-black uppercase tracking-widest flex items-center gap-2 transition-colors"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
            </svg>
            Clear Day
          </button>
        </div>
      <% else %>
        <div class="py-4 px-6 bg-tymeslot-50 rounded-token-2xl border-2 border-dashed border-tymeslot-100">
          <p class="text-tymeslot-400 font-bold text-token-sm">Not taking any bookings on this day.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
