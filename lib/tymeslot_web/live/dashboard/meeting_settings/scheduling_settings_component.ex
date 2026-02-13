defmodule TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent do
  @moduledoc """
  LiveComponent encapsulating scheduling preferences (buffer, advance booking, minimum notice).

  Handles UI events and profile updates locally using Helpers.handle_profile_update/3.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias Tymeslot.Security.MeetingSettingsInputProcessor
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.Dashboard.MeetingSettings.Components
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:custom_input_mode, fn -> CustomInputModeHelper.default_custom_mode() end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card-glass shadow-2xl shadow-tymeslot-200/50">
      <.section_header
        level={3}
        icon={:clock}
        title="Scheduling Preferences"
        class="mb-10"
      />

      <div class="space-y-8">
        <Components.buffer_minutes_setting
          profile={@profile}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :buffer_minutes, false)}
        />
        <Components.advance_booking_days_setting
          profile={@profile}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :advance_booking_days, false)}
        />
        <Components.min_advance_hours_setting
          profile={@profile}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :min_advance_hours, false)}
        />
      </div>
    </div>
    """
  end

  # Events migrated from parent ServiceSettingsComponent

  @impl true
  def handle_event("update_buffer_minutes", params, socket) do
    buffer_str = params["buffer_minutes"] || params["value"] || "0"
    metadata = Helpers.get_security_metadata(socket)

    case MeetingSettingsInputProcessor.validate_buffer_minutes(buffer_str, metadata: metadata) do
      {:ok, validated_buffer} ->
        # Update profile first, then update custom_input_mode only on success
        case Profiles.update_buffer_minutes(socket.assigns.profile, validated_buffer) do
          {:ok, updated_profile} ->
            # Success - now update custom_input_mode with security verification
            socket =
              socket
              |> CustomInputModeHelper.toggle_custom_mode(
                :buffer_minutes,
                params,
                validated_buffer
              )
              |> assign(:profile, updated_profile)

            Flash.info("Buffer time updated to #{updated_profile.buffer_minutes} minutes")
            send(self(), {:profile_updated, updated_profile})
            {:noreply, socket}

          {:error, changeset} ->
            # Failure - don't update custom_input_mode
            error_message = ChangesetUtils.get_first_error(changeset)
            Flash.error(error_message)
            {:noreply, socket}
        end

      {:error, error_msg} ->
        # Validation failed - don't update custom_input_mode
        Flash.error(error_msg)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_advance_booking_days", params, socket) do
    days_str = params["advance_booking_days"] || params["value"] || "90"
    metadata = Helpers.get_security_metadata(socket)

    case MeetingSettingsInputProcessor.validate_advance_booking_days(days_str,
           metadata: metadata
         ) do
      {:ok, validated_days} ->
        # Update profile first, then update custom_input_mode only on success
        case Profiles.update_advance_booking_days(socket.assigns.profile, validated_days) do
          {:ok, updated_profile} ->
            # Success - now update custom_input_mode with security verification
            socket =
              socket
              |> CustomInputModeHelper.toggle_custom_mode(
                :advance_booking_days,
                params,
                validated_days
              )
              |> assign(:profile, updated_profile)

            Flash.info(
              "Advance booking window updated to #{updated_profile.advance_booking_days} days"
            )

            send(self(), {:profile_updated, updated_profile})
            {:noreply, socket}

          {:error, changeset} ->
            # Failure - don't update custom_input_mode
            error_message = ChangesetUtils.get_first_error(changeset)
            Flash.error(error_message)
            {:noreply, socket}
        end

      {:error, error_msg} ->
        # Validation failed - don't update custom_input_mode
        Flash.error(error_msg)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_min_advance_hours", params, socket) do
    hours_str = params["min_advance_hours"] || params["value"] || "24"
    metadata = Helpers.get_security_metadata(socket)

    case MeetingSettingsInputProcessor.validate_min_advance_hours(hours_str, metadata: metadata) do
      {:ok, validated_hours} ->
        # Update profile first, then update custom_input_mode only on success
        case Profiles.update_min_advance_hours(socket.assigns.profile, validated_hours) do
          {:ok, updated_profile} ->
            # Success - now update custom_input_mode with security verification
            socket =
              socket
              |> CustomInputModeHelper.toggle_custom_mode(
                :min_advance_hours,
                params,
                validated_hours
              )
              |> assign(:profile, updated_profile)

            Flash.info(
              "Minimum booking notice updated to #{updated_profile.min_advance_hours} hours"
            )

            send(self(), {:profile_updated, updated_profile})
            {:noreply, socket}

          {:error, changeset} ->
            # Failure - don't update custom_input_mode
            error_message = ChangesetUtils.get_first_error(changeset)
            Flash.error(error_message)
            {:noreply, socket}
        end

      {:error, error_msg} ->
        # Validation failed - don't update custom_input_mode
        Flash.error(error_msg)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("focus_custom_input", %{"setting" => "buffer_minutes"}, socket) do
    current_value = if socket.assigns.profile, do: socket.assigns.profile.buffer_minutes, else: 0
    custom_value = if current_value in [0, 5, 10, 15, 30, 60], do: 45, else: current_value

    # Update profile first, then enable custom mode only on success
    case Profiles.update_buffer_minutes(socket.assigns.profile, custom_value) do
      {:ok, updated_profile} ->
        socket =
          socket
          |> CustomInputModeHelper.enable_custom_mode(:buffer_minutes)
          |> assign(:profile, updated_profile)

        Flash.info("Buffer time set to custom value")
        send(self(), {:profile_updated, updated_profile})
        {:noreply, socket}

      {:error, changeset} ->
        error_message = ChangesetUtils.get_first_error(changeset)
        Flash.error(error_message)
        {:noreply, socket}
    end
  end

  def handle_event("focus_custom_input", %{"setting" => "advance_booking_days"}, socket) do
    current_value =
      if socket.assigns.profile, do: socket.assigns.profile.advance_booking_days, else: 90

    custom_value = if current_value in [7, 14, 30, 60, 90, 180], do: 120, else: current_value

    # Update profile first, then enable custom mode only on success
    case Profiles.update_advance_booking_days(socket.assigns.profile, custom_value) do
      {:ok, updated_profile} ->
        socket =
          socket
          |> CustomInputModeHelper.enable_custom_mode(:advance_booking_days)
          |> assign(:profile, updated_profile)

        Flash.info("Advance booking set to custom value")
        send(self(), {:profile_updated, updated_profile})
        {:noreply, socket}

      {:error, changeset} ->
        error_message = ChangesetUtils.get_first_error(changeset)
        Flash.error(error_message)
        {:noreply, socket}
    end
  end

  def handle_event("focus_custom_input", %{"setting" => "min_advance_hours"}, socket) do
    current_value =
      if socket.assigns.profile, do: socket.assigns.profile.min_advance_hours, else: 24

    custom_value = if current_value in [0, 1, 4, 24, 48, 168], do: 12, else: current_value

    # Update profile first, then enable custom mode only on success
    case Profiles.update_min_advance_hours(socket.assigns.profile, custom_value) do
      {:ok, updated_profile} ->
        socket =
          socket
          |> CustomInputModeHelper.enable_custom_mode(:min_advance_hours)
          |> assign(:profile, updated_profile)

        Flash.info("Minimum notice set to custom value")
        send(self(), {:profile_updated, updated_profile})
        {:noreply, socket}

      {:error, changeset} ->
        error_message = ChangesetUtils.get_first_error(changeset)
        Flash.error(error_message)
        {:noreply, socket}
    end
  end
end
