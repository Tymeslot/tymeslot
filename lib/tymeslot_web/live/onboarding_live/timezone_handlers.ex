defmodule TymeslotWeb.OnboardingLive.TimezoneHandlers do
  @moduledoc """
  Timezone management event handlers for the onboarding flow.

  Handles timezone dropdown interactions, search functionality,
  and timezone selection updates.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles.Settings
  alias Tymeslot.Timezones

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
    socket =
      socket
      |> Component.assign(:timezone_dropdown_open, false)
      |> Component.assign(:timezone_search, "")

    case validate_timezone(timezone) do
      {:ok, validated_timezone} ->
        case Settings.update_timezone(socket.assigns.profile, validated_timezone) do
          {:ok, profile} ->
            {:noreply,
             socket
             |> Component.assign(:profile, profile)
             |> Component.assign(:form_errors, %{})}

          {:error, _reason} ->
            {:noreply,
             LiveView.put_flash(
               socket,
               :error,
               dgettext(
                 "onboarding_wizard",
                 "Please check your timezone selection and try again."
               )
             )}
        end

      {:error, errors} ->
        {:noreply, Component.assign(socket, :form_errors, errors)}
    end
  end

  # Private helpers

  defp validate_timezone(timezone) when is_binary(timezone) do
    if Timezones.valid?(timezone) do
      {:ok, timezone}
    else
      {:error, %{timezone: dgettext("onboarding_wizard", "Invalid timezone")}}
    end
  end

  defp validate_timezone(_invalid),
    do: {:error, %{timezone: dgettext("onboarding_wizard", "Timezone must be a string")}}
end
