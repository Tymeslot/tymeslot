defmodule TymeslotWeb.OnboardingLive.NavigationHandlers do
  @moduledoc """
  Navigation event handlers for the onboarding flow.

  Handles step navigation including next/previous step transitions,
  skip modal management, step skipping, and onboarding completion.
  """

  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias TymeslotWeb.Analytics
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared
  alias TymeslotWeb.OnboardingLive.CalendarHandlers
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Handles the next step navigation event.

  Validates current step data and progresses to the next step
  in the onboarding flow.
  """
  @spec handle_next_step(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_next_step(socket) do
    case socket.assigns.current_step do
      :profile ->
        handle_profile_next(socket)

      :connect_calendar ->
        handle_calendar_continue(socket)

      :ready ->
        handle_complete_onboarding(socket, redirect_to: ~p"/dashboard")

      step ->
        {:noreply, advance_step(socket, step)}
    end
  end

  # Continue on the calendar step is a forced choice: act on the selected
  # option rather than blindly advancing. OAuth providers redirect out; CalDAV
  # opens the inline form; "skip" (or an already-connected calendar) advances.
  defp handle_calendar_continue(socket) do
    case socket.assigns.calendar_choice do
      "google" ->
        CalendarHandlers.handle_connect_google(socket)

      "outlook" ->
        CalendarHandlers.handle_connect_outlook(socket)

      "caldav" ->
        {:noreply, Component.assign(socket, :calendar_state, :connecting_caldav)}

      "skip" ->
        # Don't advance immediately: Tymeslot only makes sense with a calendar
        # connected, so nudge the user to reconsider before proceeding.
        {:noreply, Component.assign(socket, :show_skip_calendar_modal, true)}

      _none ->
        if socket.assigns.connected_calendars == [] do
          {:noreply, socket}
        else
          {:noreply, advance_step(socket, :connect_calendar)}
        end
    end
  end

  defp advance_step(socket, step) do
    next = StepConfig.next_step(step, socket.assigns.steps) || step

    socket
    |> Component.assign(:current_step, next)
    |> Analytics.push("onboarding_step_completed", %{step: to_string(step)})
    |> LiveView.clear_flash()
  end

  @doc """
  Handles the previous step navigation event.

  Moves back to the previous step in the onboarding flow,
  preserving any necessary form data.
  """
  @spec handle_previous_step(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_previous_step(socket) do
    case socket.assigns.current_step do
      :connect_calendar ->
        {:noreply,
         socket
         |> Component.assign(
           :current_step,
           StepConfig.previous_step(:connect_calendar, socket.assigns.steps)
         )
         |> Component.assign(:form_data, BasicSettingsShared.build_form_data(socket))
         |> LiveView.clear_flash()}

      step when step in [:buffer_time, :booking_window, :minimum_notice] ->
        {:noreply,
         socket
         |> Component.assign(:current_step, StepConfig.previous_step(step, socket.assigns.steps))
         |> LiveView.clear_flash()}

      :ready ->
        {:noreply,
         socket
         |> Component.assign(
           :current_step,
           StepConfig.previous_step(:ready, socket.assigns.steps)
         )
         |> Component.assign_new(:custom_input_mode, fn ->
           CustomInputModeHelper.default_custom_mode()
         end)
         |> LiveView.clear_flash()}

      step ->
        case StepConfig.previous_step(step, socket.assigns.steps) do
          nil ->
            {:noreply, socket}

          prev ->
            {:noreply, socket |> Component.assign(:current_step, prev) |> LiveView.clear_flash()}
        end
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
  Confirms proceeding past the calendar step without a connected calendar.

  Closes the nudge modal and advances to the next step, recording the skip.
  """
  @spec handle_confirm_skip_calendar(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_skip_calendar(socket) do
    {:noreply,
     socket
     |> Component.assign(:show_skip_calendar_modal, false)
     |> Component.assign(
       :current_step,
       StepConfig.next_step(:connect_calendar, socket.assigns.steps)
     )
     |> Analytics.push("onboarding_step_completed", %{
       step: "connect_calendar",
       skipped: true
     })
     |> LiveView.clear_flash()}
  end

  @doc """
  Dismisses the calendar nudge modal, returning the user to the calendar step.
  """
  @spec handle_hide_skip_calendar_modal(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_skip_calendar_modal(socket) do
    {:noreply, Component.assign(socket, :show_skip_calendar_modal, false)}
  end

  @doc """
  Handles skipping the onboarding process entirely.
  """
  @spec handle_skip_onboarding(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_skip_onboarding(socket) do
    handle_complete_onboarding(socket)
  end

  @doc """
  Completes the onboarding flow, marking it done and redirecting.

  ## Options

  * `:redirect_to` - Path to redirect to after completion (default: `/dashboard`)
  """
  @spec handle_complete_onboarding(Phoenix.LiveView.Socket.t(), keyword()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_complete_onboarding(socket, opts \\ []) do
    redirect_to = Keyword.get(opts, :redirect_to, ~p"/dashboard")
    {:noreply, complete_onboarding(socket, redirect_to)}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp complete_onboarding(socket, redirect_to) do
    user = socket.assigns.current_user

    case Profiles.get_profile_by_user_id(user.id) do
      {:error, :not_found} ->
        LiveView.put_flash(
          socket,
          :error,
          dgettext("onboarding_wizard", "Profile not found. Please try again.")
        )

      {:ok, profile} ->
        case ensure_username(profile, user.id) do
          {:ok, _profile} ->
            is_debug = socket.assigns.live_action in [:debug_welcome, :debug_step]

            case Onboarding.complete_onboarding(user) do
              {:ok, _user} ->
                if is_debug do
                  socket
                  |> LiveView.put_flash(
                    :info,
                    dgettext(
                      "onboarding_wizard",
                      "Debug: Onboarding would be completed. Redirecting to debug start."
                    )
                  )
                  |> LiveView.redirect(to: ~p"/debug/onboarding")
                else
                  socket
                  |> LiveView.put_flash(
                    :info,
                    dgettext(
                      "onboarding_wizard",
                      "Welcome to Tymeslot! Your account is now set up."
                    )
                  )
                  |> LiveView.redirect(to: redirect_to)
                end

              {:error, _reason} ->
                LiveView.put_flash(
                  socket,
                  :error,
                  dgettext("onboarding_wizard", "Something went wrong. Please try again.")
                )
            end

          {:error, _reason} ->
            LiveView.put_flash(
              socket,
              :error,
              dgettext("onboarding_wizard", "Could not set up your profile. Please try again.")
            )
        end
    end
  end

  defp ensure_username(profile, user_id) do
    if profile.username && profile.username != "" do
      {:ok, profile}
    else
      default_username = Profiles.generate_default_username(user_id)
      Profiles.assign_default_username(profile, default_username)
    end
  end

  defp update_and_proceed(socket, sanitized_params) do
    case BasicSettingsShared.persist_basic_settings(
           socket,
           sanitized_params,
           preserve_timezone: true
         ) do
      {:ok, profile} ->
        booking_url = "#{Policy.app_url()}/#{profile.username || ""}"

        socket =
          socket
          |> Component.assign(:profile, profile)
          |> Component.assign(:booking_url, booking_url)
          |> Component.assign(:current_step, :connect_calendar)
          |> Analytics.push("onboarding_step_completed", %{step: "profile"})
          |> LiveView.clear_flash()

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         LiveView.put_flash(
           socket,
           :error,
           dgettext("onboarding_wizard", "Please check your input and try again.")
         )}
    end
  end

  defp handle_profile_next(socket) do
    case BasicSettingsShared.validate_basic_settings(socket, socket.assigns.form_data) do
      {:ok, sanitized_params} ->
        handle_username_validation(socket, sanitized_params)

      {:error, errors} ->
        {:noreply, BasicSettingsShared.apply_validation_errors(socket, errors)}
    end
  end

  defp handle_username_validation(socket, sanitized_params) do
    username = Map.get(sanitized_params, "username", "")
    current_username = socket.assigns.profile.username || ""

    cond do
      username == current_username ->
        update_and_proceed(socket, sanitized_params)

      username == "" ->
        {:noreply,
         Component.assign(socket, :form_errors, %{
           username: dgettext("onboarding_wizard", "Username is required")
         })}

      Profiles.username_available?(username) ->
        update_and_proceed(socket, sanitized_params)

      true ->
        {:noreply,
         Component.assign(socket, :form_errors, %{
           username:
             dgettext("onboarding_wizard", "Username is already taken. Please choose another.")
         })}
    end
  end
end
