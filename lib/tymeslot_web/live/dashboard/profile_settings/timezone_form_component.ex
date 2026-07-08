defmodule TymeslotWeb.Dashboard.ProfileSettings.TimezoneFormComponent do
  @moduledoc """
  Timezone form component for profile settings.
  Allows users to update their account timezone.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Components.TimezoneDropdown
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       timezone_options: Timezones.all_options(),
       timezone_dropdown_open: false,
       timezone_search: "",
       form_errors: %{}
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
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
    socket = assign(socket, timezone_dropdown_open: false, timezone_search: "")

    if Timezones.valid?(timezone) do
      update_timezone(socket, timezone)
    else
      errors =
        Map.put(
          socket.assigns.form_errors,
          :timezone,
          dgettext("dashboard_profile", "Unknown timezone")
        )

      {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  defp update_timezone(socket, sanitized_timezone) do
    profile = socket.assigns.profile

    case Profiles.update_timezone(profile, sanitized_timezone) do
      {:ok, updated_profile} ->
        label = label_for_timezone(socket, updated_profile.timezone)
        send(self(), {:profile_updated, updated_profile})

        Flash.info(
          dgettext("dashboard_profile", "Timezone updated to %{timezone}", timezone: label)
        )

        {:noreply, assign(socket, profile: updated_profile)}

      {:error, _changeset} ->
        Flash.error(dgettext("dashboard_profile", "Failed to update timezone"))
        {:noreply, socket}
    end
  end

  defp label_for_timezone(socket, timezone_value) do
    case Enum.find(socket.assigns.timezone_options, fn {_label, value} ->
           value == timezone_value
         end) do
      {label, _value} -> label
      _not_found -> timezone_value
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="timezone-form-container">
      <.section_header level={3} title={dgettext("dashboard_profile", "Timezone")} class="mb-4" />
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
