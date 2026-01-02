defmodule TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent do
  @moduledoc """
  LiveComponent encapsulating scheduling preferences (buffer, advance booking, minimum notice).

  Handles UI events and profile updates locally using Helpers.handle_profile_update/3.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias Tymeslot.Security.MeetingSettingsInputProcessor
  alias TymeslotWeb.Dashboard.MeetingSettings.Components
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.Flash

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex items-center mb-6">
        <div class="text-gray-600 mr-3">
          <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
        </div>
        <h3 class="text-xl font-semibold text-gray-800">Scheduling Settings</h3>
      </div>

      <div class="space-y-6">
        <Components.buffer_minutes_setting profile={@profile} myself={@myself} />
        <Components.advance_booking_days_setting profile={@profile} myself={@myself} />
        <Components.min_advance_hours_setting profile={@profile} myself={@myself} />
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
        Helpers.handle_profile_update(
          socket,
          fn profile -> Profiles.update_buffer_minutes(profile, validated_buffer) end,
          fn updated_profile ->
            "Buffer time updated to #{updated_profile.buffer_minutes} minutes"
          end
        )

      {:error, error_msg} ->
        Flash.error(error_msg)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_advance_booking_days", params, socket) do
    days_str = params["advance_booking_days"] || params["value"] || "90"
    metadata = Helpers.get_security_metadata(socket)

    case MeetingSettingsInputProcessor.validate_advance_booking_days(days_str, metadata: metadata) do
      {:ok, validated_days} ->
        Helpers.handle_profile_update(
          socket,
          fn profile -> Profiles.update_advance_booking_days(profile, validated_days) end,
          fn updated_profile ->
            "Advance booking window updated to #{updated_profile.advance_booking_days} days"
          end
        )

      {:error, error_msg} ->
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
        Helpers.handle_profile_update(
          socket,
          fn profile -> Profiles.update_min_advance_hours(profile, validated_hours) end,
          fn updated_profile ->
            "Minimum booking notice updated to #{updated_profile.min_advance_hours} hours"
          end
        )

      {:error, error_msg} ->
        Flash.error(error_msg)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("focus_custom_input", %{"setting" => "buffer_minutes"}, socket) do
    current_value = if socket.assigns.profile, do: socket.assigns.profile.buffer_minutes, else: 0
    custom_value = if current_value in [0, 5, 10, 15, 30, 60], do: 45, else: current_value

    Helpers.handle_profile_update(
      socket,
      fn profile -> Profiles.update_buffer_minutes(profile, to_string(custom_value)) end,
      fn _ -> "Buffer time set to custom value" end
    )
  end

  def handle_event("focus_custom_input", %{"setting" => "advance_booking_days"}, socket) do
    current_value =
      if socket.assigns.profile, do: socket.assigns.profile.advance_booking_days, else: 90

    custom_value = if current_value in [7, 14, 30, 60, 90, 180], do: 120, else: current_value

    Helpers.handle_profile_update(
      socket,
      fn profile -> Profiles.update_advance_booking_days(profile, to_string(custom_value)) end,
      fn _ -> "Advance booking set to custom value" end
    )
  end

  def handle_event("focus_custom_input", %{"setting" => "min_advance_hours"}, socket) do
    current_value =
      if socket.assigns.profile, do: socket.assigns.profile.min_advance_hours, else: 24

    custom_value = if current_value in [0, 1, 4, 24, 48, 168], do: 12, else: current_value

    Helpers.handle_profile_update(
      socket,
      fn profile -> Profiles.update_min_advance_hours(profile, to_string(custom_value)) end,
      fn _ -> "Minimum notice set to custom value" end
    )
  end
end
