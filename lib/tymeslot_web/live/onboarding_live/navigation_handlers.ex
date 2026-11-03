defmodule TymeslotWeb.OnboardingLive.NavigationHandlers do
  @moduledoc """
  Navigation event handlers for the onboarding flow.

  Handles step navigation including next/previous step transitions and
  onboarding completion.
  """

  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Analytics
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared
  alias TymeslotWeb.OnboardingLive.CalendarHandlers
  alias TymeslotWeb.OnboardingLive.ProfileHandlers
  alias TymeslotWeb.OnboardingLive.ReadyStep
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Records that the host shared their booking link from the final step.

  The channel comes from the client, so anything outside the step's own
  channels is dropped rather than reported.
  """
  @spec handle_share_booking_link(Phoenix.LiveView.Socket.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_share_booking_link(socket, channel) do
    if channel in ReadyStep.share_channels() do
      {:noreply, Analytics.push(socket, "booking_link_shared", %{channel: channel})}
    else
      {:noreply, socket}
    end
  end

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
        {:noreply, complete_onboarding(socket, ~p"/dashboard")}

      step ->
        {:noreply, advance_step(socket, step)}
    end
  end

  # Continue on the calendar step is a forced choice: act on the selected
  # option rather than blindly advancing. OAuth providers redirect out; CalDAV
  # opens the inline form; with nothing selected it advances only once a
  # bookable calendar is connected, the same rule that keeps every later step
  # out of reach without one.
  defp handle_calendar_continue(socket) do
    case socket.assigns.calendar_choice do
      "google" ->
        CalendarHandlers.handle_connect_google(socket)

      "outlook" ->
        CalendarHandlers.handle_connect_outlook(socket)

      "caldav" ->
        {:noreply, Component.assign(socket, :calendar_state, :connecting_caldav)}

      _none ->
        if socket.assigns.booking_page_live do
          {:noreply, advance_step(socket, :connect_calendar)}
        else
          {:noreply, socket}
        end
    end
  end

  # A host sent back from the share step to connect a calendar has already
  # answered every step after it, so the calendar step leads straight back to
  # the share step, and is not counted as completed a second time.
  defp advance_step(socket, step) do
    returning? = step == :connect_calendar and socket.assigns.returning_to_share
    next = if returning?, do: :ready, else: StepConfig.next_step(step) || step

    socket
    |> Component.assign(:current_step, next)
    |> then(fn socket ->
      if returning?,
        do: socket,
        else: Analytics.push(socket, "onboarding_step_completed", %{step: to_string(step)})
    end)
    |> LiveView.clear_flash()
    |> then(&if(next == :ready, do: enter_share_step(&1), else: &1))
  end

  # Records which variant of the share step the host sees. Reloading
  # `/onboarding/ready` does not count as a view; arriving back from the
  # calendar step does, flagged `returned`, since whether that fixed the page
  # is what it measures.
  defp enter_share_step(socket) do
    returned? = socket.assigns.returning_to_share

    socket =
      socket
      |> assign_booking_page_live()
      |> Component.assign(:returning_to_share, false)

    Analytics.push(socket, "share_step_viewed", %{
      page_live: socket.assigns.booking_page_live,
      returned: returned?
    })
  end

  @doc """
  Checks whether the booking page is actually live, with the same rule the
  public page applies. Without a bookable calendar the page refuses visitors,
  so the share step greys out its actions instead of sending people to a dead
  link.
  """
  @spec assign_booking_page_live(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_booking_page_live(socket) do
    live? = LinkAccessPolicy.check_public_readiness(socket.assigns.profile) == {:ok, :ready}
    Component.assign(socket, :booking_page_live, live?)
  end

  @doc """
  Takes the host from the share step back to the calendar step, so a page
  that is not live yet can be fixed without leaving onboarding.
  """
  @spec handle_return_to_calendar_step(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_return_to_calendar_step(socket) do
    {:noreply,
     socket
     |> Component.assign(
       current_step: :connect_calendar,
       calendar_choice: nil,
       returning_to_share: true
     )
     |> LiveView.clear_flash()}
  end

  @doc """
  Handles the previous step navigation event.

  Moves back one step. The profile step is redrawn from the saved profile, so
  it shows what was stored rather than an edit that was never saved.
  """
  @spec handle_previous_step(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_previous_step(socket) do
    case StepConfig.previous_step(socket.assigns.current_step) do
      nil ->
        {:noreply, socket}

      prev ->
        {:noreply,
         socket
         |> Component.assign(:current_step, prev)
         |> refresh_form_data(prev)
         |> LiveView.clear_flash()}
    end
  end

  defp refresh_form_data(socket, :profile), do: BasicSettingsShared.assign_form_data(socket)

  defp refresh_form_data(socket, _step), do: socket

  @doc """
  Returns the onboarding route prefix the request was served on, from its
  URI: `/onboarding`, or a debug mount such as `/dev/onboarding` or
  `/debug/onboarding`, so a debug session stays on the route it came in on.
  """
  @spec base_path(String.t()) :: String.t()
  def base_path(uri) do
    case uri |> URI.parse() |> Map.get(:path) |> Kernel.||("") |> String.split("/", trim: true) do
      [prefix, "onboarding" | _rest] when prefix != "onboarding" -> "/" <> prefix <> "/onboarding"
      _other -> "/onboarding"
    end
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
        case Profiles.ensure_default_username(profile) do
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
                  |> LiveView.redirect(to: socket.assigns.base_path)
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

  defp update_and_proceed(socket, sanitized_params) do
    case BasicSettingsShared.persist_basic_settings(
           socket,
           sanitized_params,
           preserve_timezone: true
         ) do
      {:ok, profile} ->
        booking_url = UrlBuilder.booking_url(profile.username)

        socket =
          socket
          |> Component.assign(:profile, profile)
          |> Component.assign(:booking_url, booking_url)
          |> Component.assign(:current_step, :connect_calendar)
          |> Analytics.push("onboarding_step_completed", %{step: "profile"})
          |> LiveView.clear_flash()

        {:noreply, socket}

      {:error, {:update_failed, reason}} ->
        {:noreply, handle_update_failure(socket, reason)}
    end
  end

  # A username that was free when checked can still be refused on write: taken
  # in the meantime, or colliding only at the case-insensitive unique index.
  # That is worth naming inline; anything else gets the generic message.
  defp handle_update_failure(socket, %Changeset{} = changeset) do
    case Profiles.username_error(changeset) do
      nil -> put_generic_input_error(socket)
      reason -> ProfileHandlers.put_username_error(socket, reason)
    end
  end

  # A refusal that already says what went wrong in the host's language (the
  # username change limit, a username the validator refuses) is shown as is.
  defp handle_update_failure(socket, message) when is_binary(message),
    do: LiveView.put_flash(socket, :error, message)

  defp handle_update_failure(socket, _reason), do: put_generic_input_error(socket)

  defp put_generic_input_error(socket) do
    LiveView.put_flash(
      socket,
      :error,
      dgettext("onboarding_wizard", "Please check your input and try again.")
    )
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

    case Profiles.username_status(socket.assigns.profile, username) do
      status when status in [:ok, :unchanged] ->
        update_and_proceed(socket, sanitized_params)

      reason when reason in [:reserved, :taken] ->
        {:noreply, ProfileHandlers.put_username_error(socket, reason)}

      {:invalid, _message} when username == "" ->
        {:noreply,
         Component.assign(socket, :form_errors, %{
           username: dgettext("onboarding_wizard", "Username is required")
         })}

      {:invalid, message} ->
        {:noreply, Component.assign(socket, :form_errors, %{username: message})}
    end
  end
end
