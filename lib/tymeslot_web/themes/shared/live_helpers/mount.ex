defmodule TymeslotWeb.Themes.Shared.LiveHelpers.Mount do
  @moduledoc """
  Mounting a theme's scheduling LiveView and applying URL parameters to it:
  the initial state, the booker's timezone, the organiser, the owner-preview
  gate, and the calendar subscription that keeps availability fresh. The theme
  customisation is not loaded here: `MountHelpers.prepare_theme_context/3`
  loads it once per mount, before the theme's own mount runs.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias TymeslotWeb.Live.Scheduling.{
    AvailabilityHelpers,
    CalendarHelpers,
    OrganizerHelpers,
    PreviewToken,
    ThemeUtils
  }

  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry
  alias TymeslotWeb.Themes.Shared.PathHandlers
  alias TymeslotWeb.Themes.Shared.ReschedulePin
  alias TymeslotWeb.Themes.Shared.SchedulingInit
  alias TymeslotWeb.Themes.Shared.SeatMoveLink
  alias TymeslotWeb.Themes.Shared.TimezoneHelpers

  @doc """
  Mounts a theme's scheduling LiveView: initial state, timezone, theme and
  organiser, owner preview, calendar subscription, and (on the connected
  mount) the entry into the step the route names.
  """
  @spec mount_scheduling_view(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def mount_scheduling_view(socket, params) do
    initial_state = entry(socket)

    socket =
      socket
      |> SchedulingInit.assign_theme_state()
      |> TimezoneHelpers.assign_user_timezone(params)
      |> ThemeUtils.assign_attendee_prefill()
      |> ThemeUtils.assign_theme_with_preview(params)

    # Resolve the username context (which sets meeting_types) unless the
    # dispatcher already resolved it before delegating to this mount
    socket =
      if socket.assigns[:organizer_profile] do
        socket
      else
        OrganizerHelpers.handle_username_resolution(socket, params["username"])
      end

    # The week start falls back to the organiser's own, so it needs them
    # resolved; the calendar then opens on the booker's today (after the
    # timezone) in a week that starts on it.
    socket =
      socket
      |> SchedulingInit.assign_week_start()
      |> CalendarHelpers.anchor_on_today()

    # Verify an owner-preview token now that the organiser (and so the page
    # owner's user id) is resolved. Gates simulate-vs-persist downstream.
    socket = assign_owner_preview(socket, params)

    # Subscribe to calendar event updates for the organiser so availability refreshes on sync
    socket = maybe_subscribe_to_calendar_events(socket)

    # The reschedule uid must reach the socket before the first entry handler
    # runs: it builds the questions engine and then memoises it on the
    # definitions, so one built without the uid is the one `handle_params`
    # finds and keeps. `handle_param_updates/2` is too late, running only once
    # `handle_params` does.
    socket =
      StepEntry.maybe_assign_from_params(
        socket,
        :reschedule_meeting_uid,
        params["reschedule_meeting_uid"]
      )

    # Finally setup initial state. Only on the connected mount — handle_params
    # (which always runs immediately after mount, on both the static and
    # connected passes) calls the same entry handler, so doing it here too on
    # the static pass would throw the result away and query twice for nothing.
    socket =
      if connected?(socket) do
        Runtime.transition_to(socket, initial_state, params)
      else
        socket
      end

    # Pre-fetch month availability so it's ready for the schedule step. Only on
    # the connected mount — the static render would throw the result away, and
    # the calendar degrades gracefully to business-hours availability until the
    # socket connects.
    if connected?(socket) do
      AvailabilityHelpers.fetch_month_availability_async(socket)
    else
      socket
    end
  end

  @doc """
  Applies the URL parameters and enters the moment the route opens on.

  On the payment wait (`:awaiting_payment`) it applies nothing: a client may
  patch this socket to any URL the page serves, and only the payment webhook
  (`:paid`, `:expired`) ends the wait. A reload is a fresh mount, not this.
  """
  @spec handle_scheduling_params(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_scheduling_params(%{assigns: %{current_state: :awaiting_payment}} = socket, _params),
    do: {:noreply, socket}

  def handle_scheduling_params(socket, params) do
    initial_state = entry(socket)
    socket = handle_param_updates(socket, params)

    # A spent seat link is sent on to a fresh booking before any moment is
    # entered for it (`SeatMoveLink.leave_if_spent/2`).
    if socket.redirected do
      {:noreply, socket}
    else
      socket =
        socket
        |> ThemeUtils.assign_theme_with_preview(params)
        |> assign_owner_preview(params)
        |> Runtime.transition_to(initial_state, params)

      if socket.redirected do
        {:noreply, socket}
      else
        {:ok, socket} = SlotFetchingHandlerComponent.maybe_reload_slots(socket)
        {:noreply, socket}
      end
    end
  end

  # Owner-preview gate: a booking submitted on a page loaded with a valid,
  # owner-bound preview token is SIMULATED rather than persisted. The booking
  # page is public, so a bare `?preview=true` is not enough — only a token
  # signed in the owner's authenticated session and bound to this page's owner
  # flips the gate. Sticky once true so internal multi-step navigation (which
  # does not re-carry the query param) can't silently drop it back to a real
  # booking. Defaults to false, so any path that never sets it fails closed.
  defp assign_owner_preview(socket, params) do
    verified_token = verified_preview_token(socket, params)

    socket
    |> assign(:owner_preview, socket.assigns[:owner_preview] || verified_token != nil)
    |> assign(:preview_token, socket.assigns[:preview_token] || verified_token)
  end

  # The token itself is kept, not just the boolean it produced, because a locale
  # switch redirects out of this LiveView entirely and every assign is lost. The
  # replacement page can only be told it is still a preview through the query
  # string, so `PathHandlers` needs the original token to put back. Carried
  # forward as-is rather than re-signed: switching language should not extend a
  # preview session past the expiry the owner started it with.
  defp verified_preview_token(socket, params) do
    token = params["preview_token"]

    if PreviewToken.owner?(token, socket.assigns[:organizer_user_id]), do: token
  end

  @doc """
  Applies the URL parameters to the socket: the meeting type, day and time
  they name, the reschedule or seat move they carry, and the page's own query
  (`:page_query_params`, which a restart keeps). A spent seat-move token is
  dropped and the page sent on to a fresh booking (`SeatMoveLink`).
  """
  @spec handle_param_updates(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_param_updates(socket, params) do
    seat_token = params["reschedule_seat_token"]

    socket
    |> assign(:page_query_params, PathHandlers.query_params(params))
    |> StepEntry.maybe_assign_from_params(:duration, StepEntry.normalize_duration_param(params))
    |> StepEntry.maybe_assign_from_params(
      :selected_duration,
      StepEntry.normalize_duration_param(params)
    )
    |> StepEntry.maybe_assign_from_params(:selected_date, StepEntry.date_param(params))
    |> StepEntry.maybe_assign_from_params(:selected_time, params["time"])
    # Checked against the day's times once they arrive (`InfoHandlers`).
    |> assign(:carried_time, if(is_binary(params["time"]), do: params["time"]))
    |> StepEntry.maybe_assign_from_params(
      :reschedule_meeting_uid,
      params["reschedule_meeting_uid"]
    )
    |> SeatMoveLink.assign_from_url(seat_token)
    |> assign_rescheduling(params)
    |> pin_reschedule_meeting_type()
    |> handle_confirmation_params(params)
    |> SeatMoveLink.leave_if_spent(seat_token)
  end

  # A whole-meeting reschedule names the meeting; a group participant moving
  # their own seat carries a live seat token instead.
  defp assign_rescheduling(socket, params) do
    assign(
      socket,
      :is_rescheduling,
      is_binary(params["reschedule_meeting_uid"]) or socket.assigns.reschedule_seat_token != nil
    )
  end

  # A reschedule is pinned to the type it booked; `ReschedulePin` says why.
  defp pin_reschedule_meeting_type(socket) do
    case ReschedulePin.meeting_type(socket) do
      nil ->
        ReschedulePin.clear(socket)

      meeting_type ->
        socket |> StepEntry.assign_meeting_type(meeting_type) |> ReschedulePin.pin(meeting_type)
    end
  end

  defp handle_confirmation_params(socket, params) do
    if socket.assigns[:live_action] == :confirmation do
      name =
        case params["name"] do
          val when is_binary(val) -> URI.decode(val)
          _missing -> dgettext("booking", "Guest")
        end

      socket
      |> assign(:name, name)
      |> assign(:email, params["email"] || "")
      |> assign(:meeting_uid, params["meeting_uid"] || "")
    else
      socket
    end
  end

  # The moment, or outcome, the route opens on: the journey's navigator
  # decides (`Navigator.entry/3`). `SchedulingLive` assigns the journey
  # before it calls this module.
  defp entry(socket) do
    journey = socket.assigns.journey
    journey.navigator.entry(journey, socket.assigns[:live_action], socket.assigns)
  end

  defp maybe_subscribe_to_calendar_events(socket) do
    organizer_user_id = socket.assigns[:organizer_user_id]

    if connected?(socket) && is_integer(organizer_user_id) &&
         !socket.assigns[:calendar_pubsub_subscribed] do
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{organizer_user_id}")
      assign(socket, :calendar_pubsub_subscribed, true)
    else
      socket
    end
  end
end
