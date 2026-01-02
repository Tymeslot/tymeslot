defmodule TymeslotWeb.OnboardingLive.NavigationHandlers do
  @moduledoc """
  Navigation event handlers for the onboarding flow.

  Handles step navigation including next/previous step transitions,
  modal management, and onboarding completion.
  """

  use TymeslotWeb, :verified_routes

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared

  @doc """
  Handles the next step navigation event.

  Validates current step data and progresses to the next step
  in the onboarding flow.
  """
  @spec handle_next_step(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_next_step(socket) do
    current_step = socket.assigns.current_step

    case current_step do
      :welcome ->
        {:noreply,
         socket |> Component.assign(:current_step, :basic_settings) |> LiveView.clear_flash()}

      :basic_settings ->
        handle_basic_settings_next(socket)

      :scheduling_preferences ->
        {:noreply, socket |> Component.assign(:current_step, :complete) |> LiveView.clear_flash()}

      :complete ->
        {:noreply, complete_onboarding(socket)}
    end
  end

  @doc """
  Handles the previous step navigation event.

  Moves back to the previous step in the onboarding flow,
  preserving any necessary form data.
  """
  @spec handle_previous_step(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_previous_step(socket) do
    current_step = socket.assigns.current_step

    case current_step do
      :basic_settings ->
        {:noreply, socket |> Component.assign(:current_step, :welcome) |> LiveView.clear_flash()}

      :scheduling_preferences ->
        # Reload form_data from profile when going back
        # Use user name if available, otherwise fall back to profile full_name
        default_full_name =
          socket.assigns.current_user.name || socket.assigns.profile.full_name || ""

        socket =
          socket
          |> Component.assign(:current_step, :basic_settings)
          |> Component.assign(:form_data, %{
            "full_name" => default_full_name,
            "username" => socket.assigns.profile.username || ""
          })
          |> LiveView.clear_flash()

        {:noreply, socket}

      :complete ->
        {:noreply,
         socket
         |> Component.assign(:current_step, :scheduling_preferences)
         |> LiveView.clear_flash()}

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  Handles showing the skip onboarding modal.
  """
  @spec handle_show_skip_modal(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_skip_modal(socket) do
    {:noreply, Component.assign(socket, :show_skip_modal, true)}
  end

  @doc """
  Handles hiding the skip onboarding modal.
  """
  @spec handle_hide_skip_modal(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_skip_modal(socket) do
    {:noreply, Component.assign(socket, :show_skip_modal, false)}
  end

  @doc """
  Handles skipping the onboarding process.
  """
  @spec handle_skip_onboarding(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_skip_onboarding(socket) do
    {:noreply, complete_onboarding(socket)}
  end

  # Private helper function
  defp complete_onboarding(socket) do
    user = socket.assigns.current_user

    # Reload profile from DB to ensure we don't have stale state if updated in another tab
    case ProfileQueries.get_by_user_id(user.id) do
      {:ok, profile} ->
        # Ensure user has a username before completing onboarding
        # This prevents broken booking URLs if they skip setup
        case ensure_username(profile, user.id) do
          {:ok, _profile} ->
            # Check if this is a debug route
            is_debug = socket.assigns.live_action in [:debug_welcome, :debug_step]

            case Onboarding.complete_onboarding(user) do
              {:ok, _user} ->
                # For debug routes, show completion message but stay on debug route
                if is_debug do
                  socket
                  |> LiveView.put_flash(
                    :info,
                    "Debug: Onboarding would be completed. Redirecting to debug start."
                  )
                  |> LiveView.redirect(to: ~p"/debug/onboarding")
                else
                  socket
                  |> LiveView.put_flash(:info, "Welcome to Tymeslot! Your account is now set up.")
                  |> LiveView.redirect(to: ~p"/dashboard")
                end

              {:error, _} ->
                LiveView.put_flash(socket, :error, "Something went wrong. Please try again.")
            end

          {:error, _} ->
            LiveView.put_flash(socket, :error, "Could not set up your profile. Please try again.")
        end

      {:error, :not_found} ->
        LiveView.put_flash(socket, :error, "Profile not found. Please try again.")
    end
  end

  defp ensure_username(profile, user_id) do
    if profile.username && profile.username != "" do
      {:ok, profile}
    else
      default_username = Profiles.generate_default_username(user_id)
      # Use ProfileQueries.update_username directly to bypass rate limits
      # for system-assigned default usernames
      ProfileQueries.update_username(profile, default_username)
    end
  end

  # Helper function to update basic settings and proceed to next step
  defp update_and_proceed(socket, sanitized_params) do
    # Ensure timezone is included so it persists even if the user didn't change it explicitly
    case BasicSettingsShared.persist_basic_settings(
           socket,
           sanitized_params,
           preserve_timezone: true
         ) do
      {:ok, profile} ->
        socket =
          socket
          |> Component.assign(:profile, profile)
          |> Component.assign(:current_step, :scheduling_preferences)
          |> LiveView.clear_flash()

        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         LiveView.put_flash(
           socket,
           :error,
           "Please check your input and try again."
         )}
    end
  end

  # Handle next step for basic settings
  defp handle_basic_settings_next(socket) do
    case BasicSettingsShared.validate_basic_settings(socket, socket.assigns.form_data) do
      {:ok, sanitized_params} ->
        handle_username_validation(socket, sanitized_params)

      {:error, errors} ->
        {:noreply, BasicSettingsShared.apply_validation_errors(socket, errors)}
    end
  end

  # Handle username validation and availability check
  defp handle_username_validation(socket, sanitized_params) do
    username = Map.get(sanitized_params, "username", "")
    current_username = socket.assigns.profile.username || ""

    cond do
      # Username hasn't changed, proceed
      username == current_username ->
        update_and_proceed(socket, sanitized_params)

      # Username is empty, show error
      username == "" ->
        {:noreply, Component.assign(socket, :form_errors, %{username: "Username is required"})}

      # Check if username is available
      Profiles.username_available?(username) ->
        update_and_proceed(socket, sanitized_params)

      # Username is taken
      true ->
        {:noreply,
         Component.assign(socket, :form_errors, %{
           username: "Username is already taken. Please choose another."
         })}
    end
  end
end
