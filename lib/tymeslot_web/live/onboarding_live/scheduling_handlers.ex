defmodule TymeslotWeb.OnboardingLive.SchedulingHandlers do
  @moduledoc """
  Scheduling preferences event handlers for the onboarding flow.

  Handles validation and updates for scheduling preferences including
  buffer time, advance booking window, and minimum advance notice.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles.Settings
  alias Tymeslot.Security.OnboardingInputProcessor
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared

  @doc """
  Handles validation of scheduling preferences.

  Validates scheduling preference input in real-time.
  """
  @spec handle_validate_scheduling_preferences(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_scheduling_preferences(params, socket) do
    metadata = BasicSettingsShared.metadata(socket)

    case OnboardingInputProcessor.validate_scheduling_preferences(params, metadata: metadata) do
      {:ok, _sanitized_params} ->
        {:noreply, Component.assign(socket, :form_errors, %{})}

      {:error, errors} ->
        {:noreply, Component.assign(socket, :form_errors, errors)}
    end
  end

  @doc """
  Handles updating scheduling preferences in the database.

  Validates and persists scheduling preference settings.
  """
  @spec handle_update_scheduling_preferences(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_scheduling_preferences(params, socket) do
    metadata = BasicSettingsShared.metadata(socket)

    # First validate the input
    case OnboardingInputProcessor.validate_scheduling_preferences(params, metadata: metadata) do
      {:ok, sanitized_params} ->
        # Then update the profile with sanitized data
        case Settings.update_scheduling_preferences(
               socket.assigns.profile,
               sanitized_params
             ) do
          {:ok, profile} ->
            socket =
              socket
              |> Component.assign(:profile, profile)
              |> Component.assign(:form_errors, %{})

            {:noreply, socket}

          {:error, _} ->
            {:noreply,
             LiveView.put_flash(socket, :error, "Please check your input and try again.")}
        end

      {:error, errors} ->
        socket = Component.assign(socket, :form_errors, errors)

        {:noreply, socket}
    end
  end
end
