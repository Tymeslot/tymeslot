defmodule TymeslotWeb.Dashboard.ProfileSettings.TimezoneFormComponent do
  @moduledoc """
  Timezone form component for profile settings.
  Allows users to update their account timezone.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias Tymeslot.Security.SettingsInputProcessor
  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Components.TimezoneDropdown
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    timezone_options = TimezoneUtils.get_all_timezone_options()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(timezone_options: timezone_options)
     |> assign(timezone_dropdown_open: false)
     |> assign(timezone_search: "")
     |> assign(:form_errors, %{})}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_timezone_dropdown", _params, socket) do
    {:noreply, assign(socket, timezone_dropdown_open: !socket.assigns.timezone_dropdown_open)}
  end

  def handle_event("close_timezone_dropdown", _params, socket) do
    {:noreply, assign(socket, timezone_dropdown_open: false)}
  end

  def handle_event("search_timezone", %{"search" => search}, socket) do
    {:noreply, assign(socket, timezone_search: search)}
  end

  def handle_event("search_timezone", %{"value" => search}, socket) do
    {:noreply, assign(socket, timezone_search: search)}
  end

  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    socket = assign(socket, timezone_dropdown_open: false, timezone_search: "")

    case SettingsInputProcessor.validate_timezone_update(timezone, metadata: metadata) do
      {:ok, sanitized_timezone} ->
        update_timezone(socket, sanitized_timezone)

      {:error, validation_error} ->
        errors = Map.put(socket.assigns.form_errors, :timezone, validation_error)
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  defp update_timezone(socket, sanitized_timezone) do
    profile = socket.assigns.profile

    case Profiles.update_timezone(profile, sanitized_timezone) do
      {:ok, updated_profile} ->
        label = label_for_timezone(socket, updated_profile.timezone)
        send(self(), {:profile_updated, updated_profile})
        Flash.info("Timezone updated to #{label}")
        {:noreply, assign(socket, profile: updated_profile)}

      {:error, _reason} ->
        Flash.error("Failed to update timezone")
        {:noreply, socket}
    end
  end

  defp label_for_timezone(socket, timezone_value) do
    case Enum.find(socket.assigns.timezone_options, fn {_label, value} ->
           value == timezone_value
         end) do
      {label, _value} -> label
      _ -> timezone_value
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="timezone-form-container">
      <.section_header level={3} title="Timezone" class="mb-4" />
      <TimezoneDropdown.timezone_dropdown
        profile={@profile}
        timezone_options={@timezone_options}
        timezone_dropdown_open={@timezone_dropdown_open}
        timezone_search={@timezone_search}
        target={@myself}
        safe_flags={false}
      />
      <%= for message <- FormValidationHelpers.field_errors(@form_errors, :timezone) do %>
        <p class="text-token-sm text-red-400 mt-1">{message}</p>
      <% end %>
    </div>
    """
  end
end
