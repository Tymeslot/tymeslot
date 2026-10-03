defmodule TymeslotWeb.Dashboard.MeetingSettings.Helpers do
  @moduledoc """
  Helper functions for the ServiceSettingsComponent.
  Contains business logic, state management, and utility functions.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.Component
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.FormHelpers
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash

  @doc """
  Resets the form state to initial values.
  """
  @spec reset_form_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_form_state(socket) do
    socket
    |> Component.assign(:show_add_form, false)
    |> Component.assign(:editing_type, nil)
    |> Component.assign(:show_edit_overlay, false)
    |> Component.assign(:form_errors, %{})
    |> Component.assign(:saving, false)
    |> Component.assign(:selected_icon, "none")
    |> Component.assign(:form_data, %{})
  end

  @doc """
  Reloads the profile if necessary to ensure fresh data.
  """
  @spec maybe_reload_profile(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_reload_profile(socket) do
    # If we have a profile and a current user, reload to ensure fresh data
    if socket.assigns[:profile] && socket.assigns[:current_user] do
      fresh_profile = Profiles.get_profile(socket.assigns.current_user.id)
      Component.assign(socket, :profile, fresh_profile || socket.assigns.profile)
    else
      socket
    end
  end

  @doc """
  Gets security metadata from socket assigns using the centralized dashboard helper.
  """
  @spec get_security_metadata(Phoenix.LiveView.Socket.t()) :: map()
  def get_security_metadata(socket) do
    DashboardHelpers.get_security_metadata(socket)
  end

  @flashed_field_errors [
    :video_integration_required,
    :invalid_duration,
    :invalid_price,
    :group_bookings_not_allowed
  ]

  @doc """
  Handles the result of saving a meeting type.
  """
  @spec handle_meeting_type_save_result(
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | atom() | any()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_meeting_type_save_result(result, socket) do
    case result do
      {:ok, _type} ->
        send(self(), {:meeting_type_changed})

        send(
          self(),
          {:flash,
           {:info,
            if(socket.assigns.editing_type,
              do: dgettext("dashboard_meeting_form", "Meeting type updated"),
              else: dgettext("dashboard_meeting_form", "Meeting type created")
            )}}
        )

        {:noreply, reset_form_state(socket)}

      {:error, reason} when reason in @flashed_field_errors ->
        Flash.error(field_error_flash(reason))

        {:noreply,
         socket
         |> Component.assign(:form_errors, FormHelpers.format_context_error(reason))
         |> Component.assign(:saving, false)}

      {:error, :insufficient_plan} ->
        Flash.error(
          dgettext(
            "dashboard_meeting_form",
            "Custom booking questions are available on Pro plans."
          )
        )

        {:noreply, Component.assign(socket, :saving, false)}

      {:error, :feature_access_checker_failed} ->
        Flash.error(
          dgettext(
            "dashboard_meeting_form",
            "Unable to verify subscription status. Please try again."
          )
        )

        {:noreply, Component.assign(socket, :saving, false)}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = changeset_form_errors(changeset)

        {:noreply,
         socket
         |> Component.assign(:form_errors, errors)
         |> Component.assign(:saving, false)}

      {:error, error} ->
        Flash.error(dgettext("dashboard_meeting_form", "Failed to save meeting type"))

        {:noreply,
         socket
         |> Component.assign(:form_errors, FormHelpers.format_context_error(error))
         |> Component.assign(:saving, false)}
    end
  end

  # Refusals that belong to one field: a flash says what went wrong, and the
  # field's own error outlet points at where.
  defp field_error_flash(:video_integration_required),
    do: dgettext("dashboard_meeting_form", "Please select a video provider for video meetings")

  defp field_error_flash(:invalid_duration),
    do: dgettext("dashboard_meeting_form", "Duration must be a valid number")

  defp field_error_flash(:invalid_price),
    do: dgettext("dashboard_meeting_form", "Enter a valid price for this meeting type")

  defp field_error_flash(:group_bookings_not_allowed),
    do: FormHelpers.group_bookings_not_allowed_message()

  @doc """
  The meeting-type form's errors from a refused changeset, keyed by field
  and translated through the `errors` domain like any other form error
  (`Forms.translate_error/1`).
  """
  @spec changeset_form_errors(Changeset.t()) :: %{atom() => [String.t()]}
  def changeset_form_errors(%Changeset{} = changeset),
    do: Changeset.traverse_errors(changeset, &Forms.translate_error/1)

  @doc """
  Formats error messages that can be either strings or lists.
  """
  @spec format_errors(list() | String.t() | any()) :: String.t()
  def format_errors(errors) when is_list(errors), do: Enum.join(errors, ", ")
  def format_errors(error) when is_binary(error), do: error
  def format_errors(_other), do: dgettext("dashboard_meeting_form", "An error occurred")
end
