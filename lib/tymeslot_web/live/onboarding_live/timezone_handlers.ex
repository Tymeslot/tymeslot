defmodule TymeslotWeb.OnboardingLive.TimezoneHandlers do
  @moduledoc """
  Timezone management event handlers for the onboarding flow.

  Handles timezone dropdown interactions, search functionality,
  and timezone selection updates.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles.Settings
  alias Tymeslot.Security.OnboardingInputProcessor
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared

  @doc """
  Handles toggling the timezone dropdown visibility.
  """
  @spec handle_toggle_timezone_dropdown(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_timezone_dropdown(socket) do
    {:noreply,
     Component.assign(socket,
       timezone_dropdown_open: !socket.assigns.timezone_dropdown_open
     )}
  end

  @doc """
  Handles closing the timezone dropdown.
  """
  @spec handle_close_timezone_dropdown(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_timezone_dropdown(socket) do
    {:noreply, Component.assign(socket, timezone_dropdown_open: false)}
  end

  @doc """
  Handles timezone search functionality.

  Updates the search query for filtering available timezones.
  """
  @spec handle_search_timezone(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_search_timezone(search_term, socket) do
    {:noreply, Component.assign(socket, timezone_search: search_term)}
  end

  @doc """
  Handles timezone selection and updates.

  Validates the selected timezone and updates the user's profile.
  """
  @spec handle_change_timezone(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_change_timezone(timezone, socket) do
    metadata = BasicSettingsShared.metadata(socket)

    # Close dropdown and clear search, but explicitly preserve form_data
    socket =
      socket
      |> Component.assign(:timezone_dropdown_open, false)
      |> Component.assign(:timezone_search, "")
      # Ensure form_data is preserved
      |> Component.assign(:form_data, socket.assigns.form_data)

    # First validate the timezone
    case OnboardingInputProcessor.validate_timezone_selection(timezone, metadata: metadata) do
      {:ok, validated_timezone} ->
        # Update and persist the timezone
        case Settings.update_timezone(
               socket.assigns.profile,
               validated_timezone
             ) do
          {:ok, profile} ->
            socket =
              socket
              |> Component.assign(:profile, profile)
              |> Component.assign(:form_errors, %{})
              # Explicitly preserve form_data
              |> Component.assign(:form_data, socket.assigns.form_data)

            {:noreply, socket}

          {:error, _} ->
            {:noreply,
             LiveView.put_flash(
               socket,
               :error,
               "Please check your timezone selection and try again."
             )}
        end

      {:error, errors} ->
        socket =
          socket
          |> Component.assign(:form_errors, errors)
          # Preserve form_data even on error
          |> Component.assign(:form_data, socket.assigns.form_data)

        {:noreply, socket}
    end
  end
end
