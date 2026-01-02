defmodule TymeslotWeb.Dashboard.MeetingSettings.Helpers do
  @moduledoc """
  Helper functions for the ServiceSettingsComponent.
  Contains business logic, state management, and utility functions.
  """

  alias Phoenix.Component
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.ChangesetUtils
  alias Tymeslot.Utils.FormHelpers
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
  Handles profile update operations with consistent error handling.
  """
  @spec handle_profile_update(
          Phoenix.LiveView.Socket.t(),
          (Ecto.Schema.t() -> {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}),
          (Ecto.Schema.t() -> String.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_profile_update(socket, update_fn, success_message_fn) do
    case update_fn.(socket.assigns.profile) do
      {:ok, updated_profile} ->
        Flash.info(success_message_fn.(updated_profile))
        send(self(), {:profile_updated, updated_profile})

        # Update the component's own assigns with the new profile data
        socket = Component.assign(socket, :profile, updated_profile)
        {:noreply, socket}

      {:error, changeset} ->
        error_message = ChangesetUtils.get_first_error(changeset)
        Flash.error(error_message)
        {:noreply, socket}
    end
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
              do: "Meeting type updated",
              else: "Meeting type created"
            )}}
        )

        {:noreply, reset_form_state(socket)}

      {:error, :video_integration_required} ->
        Flash.error("Please select a video provider for video meetings")

        {:noreply,
         socket
         |> Component.assign(
           :form_errors,
           FormHelpers.format_context_error(:video_integration_required)
         )
         |> Component.assign(:saving, false)}

      {:error, :invalid_duration} ->
        Flash.error("Duration must be a valid number")

        {:noreply,
         socket
         |> Component.assign(:form_errors, FormHelpers.format_context_error(:invalid_duration))
         |> Component.assign(:saving, false)}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = FormHelpers.format_changeset_errors(changeset)

        {:noreply,
         socket
         |> Component.assign(:form_errors, errors)
         |> Component.assign(:saving, false)}

      {:error, error} ->
        Flash.error("Failed to save meeting type")

        {:noreply,
         socket
         |> Component.assign(:form_errors, FormHelpers.format_context_error(error))
         |> Component.assign(:saving, false)}
    end
  end

  @doc """
  Formats error messages that can be either strings or lists.
  """
  @spec format_errors(list() | String.t() | any()) :: String.t()
  def format_errors(errors) when is_list(errors), do: Enum.join(errors, ", ")
  def format_errors(error) when is_binary(error), do: error
  def format_errors(_), do: "An error occurred"
end
