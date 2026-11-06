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
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Utils.QrCode
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Analytics
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared
  alias TymeslotWeb.OnboardingLive.MeetingHandlers
  alias TymeslotWeb.OnboardingLive.ProfileHandlers
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Records that the host kept their booking link on the last step, by one of
  the methods the step's own buttons send (`Onboarding.keep_methods/0` but
  `phone`): the first keep completes onboarding and stamps the profile's
  first share (`Onboarding.keep_booking_link/3`), so closing the tab
  afterwards loses nothing. The method comes from the client, so anything
  else is ignored. Keeping it again is harmless; the confirmation shows the
  latest.

  A first-person keep says how it went (`via`), since that decides what the
  confirmation may claim: `mail` (the mail client was opened, nothing is
  sent yet) and `copy` (the message was copied) each confirm as their own
  `kept_method`, while the share sheet's `first_person` confirms as sent.
  """
  @spec handle_keep_link(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_keep_link(socket, %{"method" => method} = params) do
    # `phone` is the server's to claim: the handoff page opening on another
    # device says so (`handle_phone_opened/1`), never the client.
    if method != "phone" and method in Onboarding.keep_methods(),
      do: {:noreply, keep_on_ready(socket, method, confirmation(method, params["via"]))},
      else: {:noreply, socket}
  end

  def handle_keep_link(socket, _params), do: {:noreply, socket}

  @first_person_via %{"mail" => "mail_app", "copy" => "message_copy"}

  defp confirmation("first_person", via) when is_map_key(@first_person_via, via),
    do: Map.fetch!(@first_person_via, via)

  defp confirmation(method, _via), do: method

  @doc """
  The host's booking page was opened from the handoff link (the QR code) on
  another device, which keeps the link by `phone`.
  """
  @spec handle_phone_opened(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_phone_opened(socket), do: {:noreply, keep_on_ready(socket, "phone", "phone")}

  defp keep_on_ready(%{assigns: %{current_step: :ready}} = socket, method, confirmation),
    do: keep_link(socket, method, confirmation)

  defp keep_on_ready(socket, _method, _confirmation), do: socket

  defp keep_link(socket, method, confirmation) do
    %{current_user: user, profile: profile} = socket.assigns

    case Onboarding.keep_booking_link(user, profile, method) do
      {:ok, completed} ->
        socket
        |> Component.assign(current_user: completed, kept_method: confirmation)
        |> LiveView.clear_flash()

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
  not live offers nothing to keep, so finishing stays open there, and so
  does a debug route on an account that finished onboarding long ago: there
  is nothing left for this visit to complete.
  """
  @spec finish_locked?(map()) :: boolean()
  def finish_locked?(%{kept_method: nil, booking_page_live: live} = assigns),
    do: live != false and not settled_debug_visit?(assigns)

  def finish_locked?(_assigns), do: false

  defp settled_debug_visit?(%{live_action: action, current_user: user})
       when action in [:debug_welcome, :debug_step],
       do: Onboarding.onboarding_completed?(user)

  defp settled_debug_visit?(_assigns), do: false

  @doc """
  The share step's own state, on the connected render only (the static
  render shows the miniature the live page then switches on over):

    * the subscription that hears the handoff being opened, made once per
      LiveView process (`share_subscribed`);
    * the owner-preview path the stage's iframe shows, built for the
      profile's username and the meeting the wizard set up
      (`share_preview_key`) and rebuilt when either changes, so a patch
      never re-signs the token and reloads the page, but a new link never
      shows the old one. It opens at that meeting's own step, the dates
      and times the miniature it fades in over drew, not at the page's
      list of meeting types, so the stage does not change design as the
      real page arrives. The handoff link and its QR code go with it;
      they are signed only when the QR code is shown
      (`handle_show_handoff_qr/1`), so its hour starts then.
  """
  @spec assign_share_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_share_state(%{assigns: %{profile: %{username: username}}} = socket)
      when is_binary(username) do
    if LiveView.connected?(socket) do
      socket |> subscribe_once() |> build_preview(username)
    else
      socket
    end
  end

  def assign_share_state(socket), do: socket

  defp subscribe_once(%{assigns: %{share_subscribed: true}} = socket), do: socket

  defp subscribe_once(socket) do
    :ok = Onboarding.subscribe(socket.assigns.current_user.id)
    Component.assign(socket, :share_subscribed, true)
  end

  defp build_preview(socket, username) do
    slug = meeting_slug(socket.assigns[:meeting_type])

    if socket.assigns[:share_preview_key] == {username, slug} do
      socket
    else
      Component.assign(socket,
        share_username: username,
        share_preview_key: {username, slug},
        # Relative: the stage frames the page from this origin (`frame-src 'self'`).
        owner_preview_url:
          PreviewMode.owner_path(username, socket.assigns.current_user.id,
            stage: true,
            meeting_slug: slug
          ),
        handoff_url: nil,
        handoff_qr: nil
      )
    end
  end

  defp meeting_slug(%{name: name} = meeting_type) when is_binary(name),
    do: MeetingTypes.effective_slug(meeting_type)

  defp meeting_slug(_none), do: nil

  @doc """
  Shows the QR code of the handoff link: the host's page, absolute (a phone
  opens it), carrying `handoff=1` and a token signed now.
  """
  @spec handle_show_handoff_qr(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_handoff_qr(%{assigns: %{share_username: username}} = socket)
      when is_binary(username) do
    url = PreviewMode.owner_url(username, socket.assigns.current_user.id, handoff: true)
    {:noreply, Component.assign(socket, handoff_url: url, handoff_qr: QrCode.svg_data_uri(url))}
  end

  def handle_show_handoff_qr(socket), do: {:noreply, socket}

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
  # navigates (on a debug route, back to where it started), as it does on a
  # debug route on a settled account (`finish_locked?/1`). A page that is
  # not live has nothing to keep and finishes as before.
  defp handle_finish(%{assigns: %{kept_method: method}} = socket) when is_binary(method) do
    {:noreply, LiveView.redirect(socket, to: finish_path(socket))}
  end

  defp handle_finish(%{assigns: %{booking_page_live: false}} = socket),
    do: {:noreply, complete_onboarding(socket, ~p"/dashboard")}

  defp handle_finish(socket) do
    if finish_locked?(socket.assigns),
      do: handle_finish_locked(socket),
      else: {:noreply, LiveView.redirect(socket, to: finish_path(socket))}
  end

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
    |> then(fn socket ->
      if returning?,
        do: socket,
        else: Analytics.push(socket, "onboarding_step_completed", %{step: to_string(step)})
    end)
    |> go_to_step(next)
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
  Shows `step` and records the view (`onboarding_step_viewed`). Every way
  onto a step goes through here: forward, back, the share step's way back
  to the calendar step, and landing on one by its address (a resume or a
  reload), so the views of a step count everyone who saw it.
  """
  @spec enter_step(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def enter_step(socket, step) do
    socket
    |> Component.assign(:current_step, step)
    |> Analytics.push("onboarding_step_viewed", %{step: Atom.to_string(step)})
  end

  @doc """
  "Try booking yourself" on the live step (`guest_preview_opened`): opens
  the host's page at full size, at any screen width, to make a test booking.
  """
  @spec handle_try_booking(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_try_booking(%{assigns: %{current_step: :ready}} = socket, _params) do
    socket
    |> Analytics.push("guest_preview_opened", %{})
    |> ModalHook.show_modal(:stage_preview)
    |> then(&{:noreply, &1})
  end

  def handle_try_booking(socket, _params), do: {:noreply, socket}

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
     |> Component.assign(:returning_to_share, true)
     |> go_to_step(:connect_calendar)
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
         |> go_to_step(prev)
         |> refresh_form_data(prev)
         |> LiveView.clear_flash()}
    end
  end

  @doc """
  Shows `step` when the address brought the host to it rather than one of
  the wizard's controls: a reload, a resume, or the browser's Back and
  Forward through the steps the wizard has patched into its history. The
  step is drawn as the wizard's own Back draws it (`handle_previous_step/1`),
  from what is saved. The flash stays: on a fresh mount it can be the
  calendar provider's word on the connection just made.
  """
  @spec enter_by_address(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def enter_by_address(socket, step), do: socket |> enter_step(step) |> refresh_form_data(step)

  @doc """
  Moves the host to `step` from one of the wizard's own controls: shows it
  (`enter_step/2`) and patches the address to the step's own, so a reload
  lands on the step on screen and the browser's Back returns to the one
  before. The query string travels along (a debug fixture), bar the share
  step's return flag, which goes only with the calendar step it applies to.
  `OnboardingLive.handle_params/3` knows the patch as its own by
  `patched_step` and draws nothing a second time.
  """
  @spec go_to_step(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def go_to_step(socket, step) do
    socket
    |> enter_step(step)
    |> Component.assign(:patched_step, step)
    |> LiveView.push_patch(to: step_path(socket, step))
  end

  defp step_path(socket, step) do
    query =
      socket.assigns
      |> Map.get(:step_query, %{})
      |> Map.delete("return")
      |> then(fn query ->
        if step == :connect_calendar and socket.assigns.returning_to_share,
          do: Map.put(query, "return", "share"),
          else: query
      end)

    path = socket.assigns.base_path <> "/" <> Atom.to_string(step)
    if query == %{}, do: path, else: path <> "?" <> URI.encode_query(query)
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
          |> Analytics.push("onboarding_step_completed", %{step: "profile"})
          |> go_to_step(:connect_calendar)
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
