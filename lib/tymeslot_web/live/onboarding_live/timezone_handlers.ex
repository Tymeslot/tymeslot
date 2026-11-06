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
  Swaps the timezone line for the picker, opened.
  """
  @spec handle_edit_timezone(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_edit_timezone(socket) do
    {:noreply,
     Component.assign(socket,
       timezone_editing: true,
       timezone_dropdown_open: true,
       timezone_focus_change: false
     )}
  end

  @doc """
  Handles toggling the timezone dropdown visibility.
  """
  @spec handle_toggle_timezone_dropdown(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_timezone_dropdown(%{assigns: %{timezone_dropdown_open: true}} = socket),
    do: handle_close_timezone_dropdown(socket)

  def handle_toggle_timezone_dropdown(socket),
    do: {:noreply, Component.assign(socket, timezone_dropdown_open: true)}

  @doc """
  Handles closing the timezone dropdown, which returns to the timezone line.
  """
  @spec handle_close_timezone_dropdown(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_timezone_dropdown(socket),
    do: {:noreply, Component.assign(socket, back_to_timezone_line())}

  # Closing the picker, with or without a choice, folds it back into the
  # timezone line and hands the focus to its Change button.
  defp back_to_timezone_line,
    do: [timezone_dropdown_open: false, timezone_editing: false, timezone_focus_change: true]

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
    socket = Component.assign(socket, :timezone_search, "")

    case Timezones.validate(timezone) do
      {:ok, validated_timezone} ->
        case Settings.update_timezone(socket.assigns.profile, validated_timezone) do
          {:ok, profile} ->
            {:noreply,
             socket
             |> Component.assign([profile: profile] ++ back_to_timezone_line())
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

      {:error, message} ->
        {:noreply, Component.assign(socket, :form_errors, %{timezone: message})}
    end
  end
end
