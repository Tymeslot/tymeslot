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
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared
  alias TymeslotWeb.OnboardingLive.MeetingHandlers
  alias TymeslotWeb.OnboardingLive.ProfileHandlers
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Records that the host kept their booking link on the last step, by one of
  `Onboarding.keep_methods/0`: the first keep completes onboarding and stamps
  the profile's first share (`Onboarding.keep_booking_link/3`), so closing
  the tab afterwards loses nothing. The method comes from the client, so
  anything else is ignored. Keeping it again is harmless; the confirmation
  shows the latest.
  """
  @spec handle_keep_link(Phoenix.LiveView.Socket.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_keep_link(socket, method) do
    if method in Onboarding.keep_methods() and socket.assigns.current_step == :ready,
      do: {:noreply, keep_link(socket, method)},
      else: {:noreply, socket}
  end

  defp keep_link(socket, method) do
    %{current_user: user, profile: profile} = socket.assigns

    case Onboarding.keep_booking_link(user, profile, method) do
      {:ok, completed} ->
        socket
        |> Component.assign(current_user: completed, kept_method: method)
        |> LiveView.clear_flash()
        # C1 registers `booking_link_kept`; until then the share event carries the method.
        |> Analytics.push("booking_link_shared", %{channel: method})

      {:error, {:email, _reason}} ->
        LiveView.put_flash(
          socket,
          :error,
          dgettext("onboarding_wizard", "We couldn't send the email. Try another option.")
        )

      {:error, _reason} ->
        LiveView.put_flash(
          socket,
          :error,
          dgettext("onboarding_wizard", "Something went wrong. Please try again.")
        )
    end
  end

  @doc """
  The host pressed "Go to dashboard" before keeping their link: the focus
  moves to the first-person button, whose card pulses once (`ShareLink`).
  """
  @spec handle_finish_locked(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_finish_locked(socket),
    do: {:noreply, LiveView.push_event(socket, "share_link:focus", %{})}

  @doc """
  Whether "Go to dashboard" still waits for a keep action. A page that is
  not live offers nothing to keep, so finishing stays open there.
  """
  @spec finish_locked?(map()) :: boolean()
  def finish_locked?(%{kept_method: nil, booking_page_live: live}), do: live != false
  def finish_locked?(_assigns), do: false

  @doc """
  The share step's own state: the owner-preview address the stage shows,
  the handoff address the QR code carries, and the subscription that hears
  the handoff being opened. Set once per session on the connected render
  only, so a patch never re-signs the token and reloads the page, and the
  static render shows the miniature the live page then switches on over.
  """
  @spec assign_share_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_share_state(%{assigns: %{owner_preview_url: url}} = socket) when is_binary(url),
    do: socket

  def assign_share_state(%{assigns: %{profile: %{username: username}}} = socket)
      when is_binary(username) do
    if LiveView.connected?(socket) do
      user_id = socket.assigns.current_user.id
      :ok = Onboarding.subscribe(user_id)

      Component.assign(socket,
        owner_preview_url: PreviewMode.owner_url(username, user_id),
        handoff_url: PreviewMode.owner_url(username, user_id, handoff: true)
      )
    else
      socket
    end
  end

  def assign_share_state(socket), do: socket

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

      :meeting ->
        handle_meeting_continue(socket)

      :ready ->
        handle_finish(socket)

      step ->
        {:noreply, advance_step(socket, step)}
    end
  end

  # A kept link has already completed onboarding, so finishing only
  # navigates (on a debug route, back to where it started). A page that is
  # not live has nothing to keep and finishes as before.
  defp handle_finish(%{assigns: %{kept_method: method}} = socket) when is_binary(method) do
    {:noreply, LiveView.redirect(socket, to: finish_path(socket))}
  end

  defp handle_finish(%{assigns: %{booking_page_live: false}} = socket),
    do: {:noreply, complete_onboarding(socket, ~p"/dashboard")}

  defp handle_finish(socket), do: handle_finish_locked(socket)

  defp finish_path(socket) do
    if socket.assigns.live_action in [:debug_welcome, :debug_step],
      do: socket.assigns.base_path,
      else: ~p"/dashboard"
  end

  # A calendar is required: Continue leaves the calendar step only once the
  # page is bookable, the same rule that keeps every later step out of reach
  # without one. The tiles connect; Continue only moves on.
  defp handle_calendar_continue(%{assigns: %{booking_page_live: true}} = socket),
    do: {:noreply, advance_step(socket, :connect_calendar)}

  defp handle_calendar_continue(socket), do: {:noreply, socket}

  # The meeting step saves what is still pending (a name typed and never
  # left) and moves on only with every field valid.
  defp handle_meeting_continue(socket) do
    case MeetingHandlers.continue(socket) do
      {:ok, socket} -> {:noreply, advance_step(socket, :meeting)}
      {:error, socket} -> {:noreply, socket}
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
    |> then(&if(next == :meeting, do: MeetingHandlers.ensure_loaded(&1, true), else: &1))
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
      |> assign_share_state()
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
     |> Component.assign(current_step: :connect_calendar, returning_to_share: true)
     |> LiveView.clear_flash()}
  end

  @doc """
  Handles the previous step navigation event.

  Moves back one step. The profile step is redrawn from the saved profile, so
  it shows what was stored rather than an edit that was never saved; a link
  that is still blank or the generated `user_<id>` default shows a suggestion
  instead (see `BasicSettingsShared.assign_form_data/1`).
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

  defp refresh_form_data(socket, :meeting), do: MeetingHandlers.ensure_loaded(socket, true)
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
