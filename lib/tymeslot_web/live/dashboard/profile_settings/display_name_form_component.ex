defmodule TymeslotWeb.Dashboard.ProfileSettings.DisplayNameFormComponent do
  @moduledoc """
  Display name form component for profile settings.
  Allows users to update their public display name.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  use TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, :form_errors, %{})}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate_full_name", %{"full_name" => full_name}, socket) do
    case InputProcessor.validate_field(full_name, :full_name) do
      {:ok, sanitized_name} ->
        socket =
          assign(
            socket,
            :form_errors,
            FormValidationHelpers.delete_field_error(socket.assigns.form_errors, :full_name)
          )

        maybe_update_full_name(socket, sanitized_name)

      {:error, error_msg} ->
        errors = Map.put(socket.assigns.form_errors, :full_name, error_msg)
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  defp maybe_update_full_name(socket, sanitized_name) do
    profile = socket.assigns.profile

    if profile && sanitized_name != profile.full_name do
      case Profiles.update_full_name(profile, sanitized_name) do
        {:ok, updated_profile} ->
          send(self(), {:profile_updated, updated_profile})
          Flash.info(dgettext("dashboard_profile", "Display name updated"))
          {:noreply, assign(socket, profile: updated_profile)}

        {:error, _reason} ->
          Flash.error(dgettext("dashboard_profile", "Failed to update display name"))
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="display-name-form-container">
      <.subsection_header
        id="display-name-heading"
        title={dgettext("dashboard_profile", "Display Name")}
        class="mb-4"
      />
      <.form_wrapper
        for={%{}}
        phx-change="validate_full_name"
        phx-target={@myself}
        id="display-name-form"
      >
        <.input
          name="full_name"
          value={if @profile, do: @profile.full_name || "", else: ""}
          aria-labelledby="display-name-heading"
          placeholder={dgettext("dashboard_profile", "Enter your full name")}
          errors={FormValidationHelpers.field_errors(@form_errors, :full_name)}
          phx-debounce="500"
        />
        <p class="mt-2 text-sm text-tymeslot-500 font-bold">
          {dgettext(
            "dashboard_profile",
            "This name will appear to visitors when they book meetings with you. Changes are saved automatically."
          )}
        </p>
      </.form_wrapper>
    </div>
    """
  end
end
