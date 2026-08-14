defmodule TymeslotWeb.Themes.Shared.LiveHelpers do
  @moduledoc """
  Shared LiveView helpers for scheduling themes.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, redirect: 2]

  alias Tymeslot.Analytics
  alias Tymeslot.Bookings.SubmissionToken
  alias Tymeslot.CustomFields
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.ThemeFlow
  alias TymeslotWeb.Helpers.ClientIP

  alias TymeslotWeb.Live.Scheduling.{
    AvailabilityHelpers,
    OrganizerHelpers,
    PreviewToken,
    ThemeUtils
  }

  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Themes.Shared.Customization.Helpers, as: CustomizationHelpers
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine

  @doc """
  Shared mounting logic for scheduling themes.
  """
  @spec mount_scheduling_view(
          Phoenix.LiveView.Socket.t(),
          map(),
          atom(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def mount_scheduling_view(
        socket,
        params,
        initial_state,
        assign_initial_state_fun,
        setup_initial_state_fun
      ) do
    socket =
      socket
      |> assign_initial_state_fun.()
      |> ThemeUtils.assign_user_timezone(params)
      |> ThemeUtils.assign_theme_with_preview(params)

    # Resolve the username context (which sets meeting_types) unless the
    # dispatcher already resolved it before delegating to this mount
    socket =
      if socket.assigns[:organizer_profile] do
        socket
      else
        OrganizerHelpers.handle_username_resolution(socket, params["username"])
      end

    # Apply theme customization after organizer is resolved
    socket = maybe_assign_customization(socket)

    # Verify an owner-preview token now that the organiser (and so the page
    # owner's user id) is resolved. Gates simulate-vs-persist downstream.
    socket = assign_owner_preview(socket, params)

    # Subscribe to calendar event updates for the organiser so availability refreshes on sync
    socket = maybe_subscribe_to_calendar_events(socket)

    # Finally setup initial state
    socket = setup_initial_state_fun.(socket, initial_state, params)

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
  Shared handle_params logic for scheduling themes.
  """
  @spec handle_scheduling_params(
          Phoenix.LiveView.Socket.t(),
          map(),
          atom(),
          (Phoenix.LiveView.Socket.t(), map() -> Phoenix.LiveView.Socket.t()),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_scheduling_params(
        socket,
        params,
        initial_state,
        handle_param_updates_fun,
        handle_state_entry_fun
      ) do
    socket =
      socket
      |> handle_param_updates_fun.(params)
      |> ThemeUtils.assign_theme_with_preview(params)
      |> assign_owner_preview(params)
      |> assign(:current_state, initial_state)
      |> handle_state_entry_fun.(initial_state, params)

    # Re-apply theme customization in case theme changed in preview mode
    socket = maybe_assign_customization(socket)

    if socket.redirected do
      {:noreply, socket}
    else
      {:ok, socket} = SlotFetchingHandlerComponent.maybe_reload_slots(socket)
      {:noreply, socket}
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
    owner_preview? =
      socket.assigns[:owner_preview] ||
        PreviewToken.owner?(params["preview_token"], socket.assigns[:organizer_user_id])

    assign(socket, :owner_preview, owner_preview?)
  end

  @doc """
  Assigns theme customization data if an organizer profile is present.
  """
  @spec maybe_assign_customization(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_assign_customization(socket) do
    if socket.assigns[:organizer_profile] do
      CustomizationHelpers.assign_theme_customization(
        socket,
        socket.assigns.organizer_profile,
        socket.assigns.scheduling_theme_id
      )
    else
      socket
    end
  end

  @doc """
  Assigns a meeting type based on duration if organizer context is present.
  """
  @spec maybe_assign_meeting_type(Phoenix.LiveView.Socket.t(), integer() | String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def maybe_assign_meeting_type(socket, nil), do: socket

  def maybe_assign_meeting_type(socket, duration) do
    duration_str = if is_integer(duration), do: "#{duration}min", else: duration

    if socket.assigns[:username_context] && socket.assigns[:organizer_user_id] do
      case resolve_meeting_type(socket, duration_str) do
        nil ->
          socket

        meeting_type ->
          # Re-initialise the engine with a fresh snapshot whenever the meeting type
          # changes so the `:questions` step always reflects the current custom fields.
          defs = CustomFields.snapshot_for(meeting_type)

          socket
          |> assign(:meeting_type, meeting_type)
          |> assign(:engine, QEngine.init(defs))
          |> OrganizerHelpers.assign_booking_window()
      end
    else
      socket
    end
  end

  # A reschedule stays on the meeting's own type, because that is the one whose
  # rules the submit will be validated against. Everything else picks by
  # duration, which is what the visitor actually chose.
  defp resolve_meeting_type(socket, duration_str) do
    ThemeFlow.resolve_meeting_type_for_reschedule(
      socket.assigns[:reschedule_meeting_uid],
      socket.assigns[:organizer_user_id]
    ) ||
      ThemeFlow.resolve_meeting_type_for_duration(
        socket.assigns[:organizer_user_id],
        duration_str
      )
  end

  @doc """
  Updates socket assigns from URL parameters.
  """
  @spec handle_param_updates(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_param_updates(socket, params) do
    socket
    |> maybe_assign_from_params(:duration, normalize_duration_param(params))
    |> maybe_assign_from_params(:selected_duration, normalize_duration_param(params))
    |> maybe_assign_from_params(:selected_date, params["date"])
    |> maybe_assign_from_params(:selected_time, params["time"])
    |> maybe_assign_from_params(:reschedule_meeting_uid, params["reschedule_meeting_uid"])
    |> assign(:is_rescheduling, params["reschedule_meeting_uid"] != nil)
    |> handle_confirmation_params(params)
  end

  defp handle_confirmation_params(socket, params) do
    if socket.assigns[:live_action] == :confirmation do
      name =
        case params["name"] do
          nil -> "Guest"
          val when is_binary(val) -> URI.decode(val)
          _other -> "Guest"
        end

      socket
      |> assign(:name, name)
      |> assign(:email, params["email"] || "")
      |> assign(:meeting_uid, params["meeting_uid"] || "")
    else
      socket
    end
  end

  defp maybe_assign_from_params(socket, _key, nil), do: socket
  defp maybe_assign_from_params(socket, key, value), do: assign(socket, key, value)

  defp normalize_duration_param(params) do
    duration = params["slug"] || params["duration"]
    MeetingTypes.normalize_duration_slug(duration)
  end

  @doc """
  Sets up the initial state for the LiveView.
  """
  @spec setup_initial_state(
          Phoenix.LiveView.Socket.t(),
          atom(),
          map(),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def setup_initial_state(socket, initial_state, params, entry_handler) do
    if initial_state in [:overview, :schedule, :booking, :confirmation] do
      socket
      |> assign(:current_state, initial_state)
      |> entry_handler.(initial_state, params)
    else
      socket
    end
  end

  @doc """
  Common logic for entering the schedule state.
  """
  @spec handle_schedule_entry(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_schedule_entry(socket, params) do
    # Validate slug against meeting types if username context
    slug = normalize_duration_param(params)

    with {:username_context, true} <-
           {:username_context, is_binary(socket.assigns[:username_context])},
         {:slug, slug} when is_binary(slug) <- {:slug, slug},
         {:meeting_type, nil} <-
           {:meeting_type,
            ThemeFlow.resolve_meeting_type_for_slug(socket.assigns[:organizer_user_id], slug)} do
      socket
      |> put_flash(:error, dgettext("booking", "Invalid meeting type"))
      |> redirect(to: ~p"/#{socket.assigns[:username_context]}")
    else
      {:meeting_type, meeting_type} ->
        defs = CustomFields.snapshot_for(meeting_type)

        socket
        |> assign(:meeting_type, meeting_type)
        |> assign(:engine, QEngine.init(defs))
        |> OrganizerHelpers.assign_booking_window()
        |> do_handle_schedule_entry(params)

      _other ->
        do_handle_schedule_entry(socket, params)
    end
  end

  defp do_handle_schedule_entry(socket, params) do
    # Set up calendar
    timezone = socket.assigns[:user_timezone] || Profiles.get_default_timezone()

    {current_year, current_month} =
      case DateTime.now(timezone) do
        {:ok, dt} -> {dt.year, dt.month}
        _other -> {Date.utc_today().year, Date.utc_today().month}
      end

    normalized_duration =
      normalize_duration_param(params) || socket.assigns[:selected_duration]

    socket =
      socket
      |> assign(:current_year, current_year)
      |> assign(:current_month, current_month)
      |> assign(:duration, normalized_duration)

    # Trigger month availability fetch in background if not already loading or loaded for this month
    if AvailabilityHelpers.can_fetch_availability?(socket) do
      AvailabilityHelpers.fetch_month_availability_async(socket)
    else
      socket
    end
  end

  @doc """
  Common logic for entering the booking state.
  Redirects to the schedule step if no date/time has been selected,
  unless this is a reschedule flow which doesn't require prior selection.
  """
  @spec handle_booking_entry(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_booking_entry(socket, params) do
    has_selection =
      (socket.assigns[:selected_date] != nil ||
         (is_binary(params["date"]) && params["date"] != "")) &&
        (socket.assigns[:selected_time] != nil ||
           (is_binary(params["time"]) && params["time"] != ""))

    is_reschedule =
      socket.assigns[:reschedule_meeting_uid] != nil ||
        is_binary(params["reschedule_meeting_uid"])

    if has_selection || is_reschedule do
      do_handle_booking_entry(socket, params)
    else
      username = socket.assigns[:username_context]
      slug = socket.assigns[:selected_duration] || params["slug"]

      if is_binary(username) && is_binary(slug) do
        redirect(socket, to: ~p"/#{username}/#{slug}")
      else
        redirect(socket, to: ~p"/")
      end
    end
  end

  defp do_handle_booking_entry(socket, _params) do
    # Set up form and rate limiting
    client_ip = ClientIP.get(socket)
    submission_token = SubmissionToken.generate()

    # Pre-fill form if rescheduling, scoped to the organizer to prevent PII leaks
    reschedule_uid = socket.assigns[:reschedule_meeting_uid]
    organizer_user_id = socket.assigns[:organizer_user_id]
    form_data = ThemeFlow.build_booking_form_data(reschedule_uid, organizer_user_id)

    socket
    |> OrganizerHelpers.setup_form_state(form_data, as: :booking)
    |> assign(:client_ip, client_ip)
    |> assign(:submission_token, submission_token)
    |> assign(:submission_processed, false)
  end

  @doc """
  Captures UTM and arbitrary tracking params plus the referrer host from
  the request, and assigns the combined map under `:tracking`. The shape
  matches what `Tymeslot.Bookings.Create.execute/3` expects on the
  meeting params, so merging this assign into the meeting params at
  submit time persists the attribution on the booking.

  **First-touch attribution only.** This function is called once in `mount/3`.
  Internal LiveView navigations within the same session (e.g. schedule →
  booking → confirmation) do not invoke `mount/3` again, so the tracking
  assign is never refreshed mid-session. The UTM and referrer values
  recorded here reflect the URL the visitor first arrived on.
  """
  @spec assign_tracking(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_tracking(socket, params) do
    if Analytics.enabled?() do
      referrer = raw_referrer_from_socket(socket)

      tracking =
        params
        |> Analytics.extract_attribution(referrer)
        |> maybe_put_visitor_hash(socket)

      assign(socket, :tracking, tracking)
    else
      assign(socket, :tracking, %{})
    end
  end

  # `PageViewHook` (an on_mount hook, so it runs before this mount/3 helper)
  # computes the cookieless visitor hash and assigns it. Carry it into the
  # tracking map so it persists onto the booking and lets analytics join the
  # booking back to its page-view. Absent when the visit was not tracked
  # (e.g. dead render); then no hash is attached.
  defp maybe_put_visitor_hash(tracking, socket) do
    case socket.assigns[:visitor_hash] do
      hash when is_binary(hash) -> Map.put(tracking, :visitor_hash, hash)
      _other -> tracking
    end
  end

  @doc """
  Appends preserved tracking params to a path so UTM and custom URL
  params survive cross-route navigation in the scheduling flow.

  The `:referrer_host` key is local to the visitor's session (captured
  from the request header at mount) and is therefore omitted — it is
  not a query-string-shaped value.
  """
  @spec tracking_path(String.t(), map() | nil) :: String.t()
  def tracking_path(path, nil), do: path

  def tracking_path(path, tracking) do
    query =
      tracking
      |> Enum.flat_map(fn
        {:tracking_params, custom} when is_map(custom) -> Map.to_list(custom)
        {:referrer_host, _value} -> []
        {_key, nil} -> []
        {key, value} -> [{to_string(key), value}]
      end)
      |> URI.encode_query()

    cond do
      query == "" -> path
      String.contains?(path, "?") -> path <> "&" <> query
      true -> path <> "?" <> query
    end
  end

  defp raw_referrer_from_socket(socket) do
    socket.assigns[:scheduling_referrer]
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
