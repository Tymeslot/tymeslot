defmodule TymeslotWeb.Dashboard.Availability.ListComponent do
  @moduledoc """
  LiveView component for the list-based availability management interface.
  Handles the traditional day-by-day list view with detailed settings.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Availability.{AvailabilityActions, Breaks}
  alias Tymeslot.Availability.InputValidation, as: AvailabilityInputValidation
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Components.Dashboard.Availability.{ClearDayModal, DeleteBreakModal}
  alias TymeslotWeb.Dashboard.Availability.DayCardComponent
  alias TymeslotWeb.Dashboard.Availability.Helpers
  alias TymeslotWeb.Dashboard.Availability.ListComponent.BreakHelpers

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
    with {:ok, day} <- BreakHelpers.parse_day(day_str),
         %{} = current_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         {:ok, updated_day} <-
           AvailabilityActions.toggle_day_availability(
             schedule_id(socket),
             day,
             current_availability.is_available
           ) do
      send(
        self(),
        {:flash,
         {:info,
          dgettext("dashboard_availability", "%{day} availability updated",
            day: AvailabilityActions.day_name(day)
          )}}
      )

      updated_schedule =
        BreakHelpers.update_day_in_schedule(socket.assigns.weekly_schedule, updated_day)

      send(self(), {:reload_schedule})

      {:noreply, assign(socket, :weekly_schedule, updated_schedule)}
    else
      {:error, _changeset} ->
        Flash.error(dgettext("dashboard_availability", "Failed to update availability"))
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

    with {:ok, day} <- BreakHelpers.parse_day(day_str),
         :ok <- check_rate_limit(socket, "availability:add_break", 8, 60_000),
         %{} = day_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         {:ok, sanitized_params} <-
           AvailabilityInputValidation.validate_break_input(
             %{"start" => start_str, "end" => end_str, "label" => label},
             metadata: metadata
           ) do
      day_availability.id
      |> AvailabilityActions.add_break(
        sanitized_params["start"],
        sanitized_params["end"],
        sanitized_params["label"]
      )
      |> handle_break_result(socket, dgettext("dashboard_availability", "Break added"))
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
    break_info = BreakHelpers.find_break_info(socket.assigns.weekly_schedule, break_id)

    {:noreply, ModalHook.show_modal(socket, :delete_break, %{id: break_id, info: break_info})}
  end

  def handle_event("hide_delete_break_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete_break)}
  end

  def handle_event("show_add_break_form", %{"day" => day_str}, socket) do
    case BreakHelpers.parse_day(day_str) do
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
    ModalHook.with_modal_data(socket, :delete_break, fn break_data ->
      case AvailabilityActions.delete_break(break_data.id, schedule_id(socket)) do
        {:ok, _break} ->
          Flash.info(dgettext("dashboard_availability", "Break deleted"))
          send(self(), {:reload_schedule})

          {:noreply, ModalHook.hide_modal(socket, :delete_break)}

        {:error, _reason} ->
          Flash.error(dgettext("dashboard_availability", "Failed to delete break"))
          {:noreply, socket}
      end
    end)
  end

  def handle_event(
        "quick_break",
        %{"day" => day_str, "start" => start_str, "duration" => duration_str},
        socket
      ) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    with {:ok, day} <- BreakHelpers.parse_day(day_str),
         :ok <- check_rate_limit(socket, "availability:quick_break", 8, 60_000),
         %{} = day_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         {:ok, sanitized_params} <-
           AvailabilityInputValidation.validate_quick_break_input(
             %{"start" => start_str, "duration" => duration_str},
             metadata: metadata
           ) do
      duration = String.to_integer(sanitized_params["duration"])

      day_availability.id
      |> AvailabilityActions.add_quick_break(sanitized_params["start"], duration)
      |> handle_break_result(socket, dgettext("dashboard_availability", "Quick break added"))
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

    with {:ok, from_day} <- BreakHelpers.parse_day(from_day_str),
         {:ok, to_days} <-
           AvailabilityInputValidation.validate_day_selections(to_days_str, metadata: metadata),
         {:ok, _result} <-
           AvailabilityActions.copy_day_settings(schedule_id(socket), from_day, to_days) do
      day_names = Enum.map_join(to_days, ", ", &AvailabilityActions.day_name/1)

      Flash.info(
        dgettext("dashboard_availability", "Settings copied to %{day_names}",
          day_names: day_names
        )
      )

      send(self(), {:reload_schedule})

      {:noreply, socket}
    else
      {:error, validation_error} when is_binary(validation_error) ->
        Flash.error(validation_error)
        {:noreply, socket}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_availability", "Failed to copy settings"))
        {:noreply, socket}
    end
  end

  def handle_event("show_clear_day_modal", %{"day" => day_str}, socket) do
    case BreakHelpers.parse_day(day_str) do
      {:ok, day} ->
        day_name = AvailabilityActions.day_name(day)

        {:noreply, ModalHook.show_modal(socket, :clear_day, %{day: day, day_name: day_name})}
    end
  end

  def handle_event("hide_clear_day_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :clear_day)}
  end

  def handle_event("confirm_clear_day", _params, socket) do
    ModalHook.with_modal_data(socket, :clear_day, fn day_data ->
      case AvailabilityActions.clear_day_settings(schedule_id(socket), day_data.day) do
        {:ok, _result} ->
          Flash.info(
            dgettext("dashboard_availability", "%{day_name} settings cleared",
              day_name: day_data.day_name
            )
          )

          send(self(), {:reload_schedule})

          {:noreply, ModalHook.hide_modal(socket, :clear_day)}

        {:error, _reason} ->
          Flash.error(dgettext("dashboard_availability", "Failed to clear day settings"))
          {:noreply, socket}
      end
    end)
  end

  # Helper Functions

  defp do_update_day_hours(params, socket, metadata) do
    with {:ok, day} <- BreakHelpers.parse_day(params),
         :ok <- check_rate_limit(socket, "availability:update_hours", 10, 10_000),
         %{} = day_availability <-
           AvailabilityActions.get_day_from_schedule(socket.assigns.weekly_schedule, day),
         strings <- resolve_day_strings(params, day_availability),
         {:ok, sanitized_params} <-
           AvailabilityInputValidation.validate_day_hours(strings, metadata: metadata),
         result <-
           AvailabilityActions.update_day_hours(
             schedule_id(socket),
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
      "start" => params["start"] || BreakHelpers.format_time(day_availability.start_time),
      "end" => params["end"] || BreakHelpers.format_time(day_availability.end_time)
    }
  end

  defp handle_update_day_hours_result(day, result, socket) do
    case result do
      {:ok, _updated} ->
        Flash.info(
          dgettext("dashboard_availability", "%{day} hours updated",
            day: AvailabilityActions.day_name(day)
          )
        )

        send(self(), {:reload_schedule})

        {:noreply, assign(socket, :form_errors, %{})}

      {:error, :invalid_time_format} ->
        Flash.error(dgettext("dashboard_availability", "Invalid time format"))
        {:noreply, socket}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_availability", "Failed to update availability"))
        {:noreply, socket}
    end
  end

  # Every break write funnels through here so a rejected changeset reaches the
  # organiser as a form error rather than crashing the LiveView.
  defp handle_break_result({:ok, _break}, socket, success_message) do
    Flash.info(success_message)
    send(self(), {:reload_schedule})

    socket =
      socket
      |> assign(:form_errors, %{})
      |> assign(:show_add_break_form, nil)

    {:noreply, socket}
  end

  defp handle_break_result({:error, :invalid_time_format}, socket, _success_message) do
    Flash.error(dgettext("dashboard_availability", "Invalid time format"))
    {:noreply, socket}
  end

  defp handle_break_result({:error, %Ecto.Changeset{} = changeset}, socket, _success_message) do
    {field_errors, general_messages} = BreakHelpers.break_error_messages(changeset)

    Enum.each(general_messages, &Flash.error/1)

    {:noreply, assign(socket, :form_errors, field_errors)}
  end

  defp handle_break_result({:error, _reason}, socket, _success_message) do
    Flash.error(dgettext("dashboard_availability", "Break could not be saved"))
    {:noreply, socket}
  end

  # Small helpers to reduce duplication
  defp schedule_id(socket), do: socket.assigns.selected_schedule.id

  defp check_rate_limit(socket, action_prefix, limit, window_ms) do
    key = "#{action_prefix}:#{schedule_id(socket)}"

    case RateLimiter.check_rate_limit(key, limit, window_ms) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        Flash.error(
          dgettext(
            "dashboard_availability",
            "You're adding breaks too quickly. Please wait a bit."
          )
        )

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
          title={dgettext("dashboard_availability", "Weekly Schedule")}
        />
        <Helpers.timezone_display timezone_display={@timezone_display} country_code={@country_code} />
      </div>

      <%!-- Weekly Schedule --%>
      <div class="space-y-1">
        <%= for day_availability <- @weekly_schedule do %>
          <DayCardComponent.day_card
            day_availability={day_availability}
            day_name={AvailabilityActions.day_name(day_availability.day_of_week)}
            break_duration_presets={@break_duration_presets}
            form_errors={@form_errors}
            show_add_break_form={@show_add_break_form}
            time_format={@time_format}
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
end
