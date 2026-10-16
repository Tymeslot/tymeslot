defmodule TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry do
  @moduledoc """
  What entering a booking step sets up, and how the flow settles which meeting
  type it is booking.

  Every entry into the flow has to resolve `:meeting_type`, the record whose
  rules the submission is validated against, so meeting-type assignment lives
  here with the entries that depend on it. Also holds the URL-parameter
  readers the entries and `LiveHelpers.Mount` share.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, redirect: 2]

  alias Tymeslot.Bookings.SubmissionToken
  alias Tymeslot.CustomFields
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Scheduling.ThemeFlow
  alias TymeslotWeb.Helpers.ClientIP

  alias TymeslotWeb.Live.Scheduling.{
    AvailabilityHelpers,
    CalendarHelpers,
    NextAvailable,
    OrganizerHelpers
  }

  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Answers
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.ReschedulePin

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
        nil -> socket
        meeting_type -> assign_meeting_type(socket, meeting_type)
      end
    else
      socket
    end
  end

  # A reschedule stays on the meeting's own type, because that is the one whose
  # rules the submit will be validated against. Everything else picks by
  # duration, which is what the visitor actually chose.
  defp resolve_meeting_type(socket, duration_str) do
    ReschedulePin.meeting_type(socket) ||
      ThemeFlow.resolve_meeting_type_for_duration(
        socket.assigns[:organizer_user_id],
        duration_str
      )
  end

  @doc """
  Assigns `value` under `key` when it is a string, and leaves the socket alone
  otherwise. Query parameters are whatever the URL says they are: Phoenix
  decodes `?date[]=x` to a list and `?date[a]=b` to a map, and every consumer
  downstream is written for strings only.
  """
  @spec maybe_assign_from_params(Phoenix.LiveView.Socket.t(), atom(), term()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_assign_from_params(socket, key, value) when is_binary(value),
    do: assign(socket, key, value)

  def maybe_assign_from_params(socket, _key, _value), do: socket

  # A date that does not parse is no more usable than one that was never named,
  # and dropping it here is what lets `NextAvailable` land the booker on a real
  # day: it stands down for any non-empty `:selected_date`, so a malformed one
  # left on the socket would strand the schedule step with no day selected and
  # a calendar-parsing error where the times belong.
  @doc "The `date` parameter when it is an ISO 8601 date, else nil."
  @spec date_param(map()) :: String.t() | nil
  def date_param(params), do: parsed_date(params["date"])

  defp parsed_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> value
      {:error, _reason} -> nil
    end
  end

  defp parsed_date(_value), do: nil

  @doc "The meeting-type slug the URL names (`slug`, else `duration`), normalised."
  @spec normalize_duration_param(map()) :: String.t() | nil
  def normalize_duration_param(params) do
    duration = params["slug"] || params["duration"]
    MeetingTypes.normalize_duration_slug(duration)
  end

  @doc """
  Common logic for entering the schedule state.
  """
  @spec handle_schedule_entry(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_schedule_entry(socket, params) do
    case resolve_entry_meeting_type(socket, params) do
      {:unresolvable, socket} -> socket
      {:ok, socket} -> do_handle_schedule_entry(socket, params)
    end
  end

  # Every entry into the flow has to resolve `:meeting_type`, and a reschedule
  # resolves it exactly once, in `ReschedulePin`. The slug in the URL is not
  # consulted for one: two types can share a duration, and a stale reschedule
  # link can name a different type outright. Only when the pin comes back empty
  # — not a reschedule, or its type has since been deleted — does the slug
  # decide, which is what a fresh booking uses.
  defp resolve_entry_meeting_type(socket, params) do
    if ReschedulePin.pinned?(socket) do
      {:ok, socket}
    else
      resolve_slug_meeting_type(socket, normalize_duration_param(params))
    end
  end

  # Resolves the slug in the URL into `:meeting_type`, the record whose rules
  # the submission is validated against. Every entry point into the flow has to
  # do this: a booking that reaches the submit without it persists with
  # `meeting_type_id: nil`, which the domain waves through, dropping the type's
  # custom-field snapshot, schedule, buffers and booking limits, and leaving
  # the duration to an unbounded parse of the slug itself.
  #
  # Returns `{:unresolvable, socket}` — already flashed and redirected — when
  # the organiser has no type for this slug.
  defp resolve_slug_meeting_type(socket, slug) do
    if is_binary(socket.assigns[:username_context]) and is_binary(slug) do
      socket.assigns[:organizer_user_id]
      |> ThemeFlow.resolve_meeting_type_for_slug(slug)
      |> assign_resolved_meeting_type(socket)
    else
      {:ok, socket}
    end
  end

  defp assign_resolved_meeting_type(nil, socket) do
    {:unresolvable,
     socket
     |> put_flash(:error, dgettext("booking", "Invalid meeting type"))
     |> redirect(to: invalid_meeting_type_redirect_path(socket))}
  end

  defp assign_resolved_meeting_type(meeting_type, socket) do
    {:ok, assign_meeting_type(socket, meeting_type)}
  end

  # Carries the reschedule context across the redirect so a bad slug doesn't
  # silently turn a reschedule into a new, duplicate booking.
  defp invalid_meeting_type_redirect_path(socket) do
    base = ~p"/#{socket.assigns[:username_context]}"

    case socket.assigns[:reschedule_meeting_uid] do
      uid when is_binary(uid) and uid != "" ->
        "#{base}?#{URI.encode_query(%{"reschedule_meeting_uid" => uid})}"

      _other ->
        base
    end
  end

  @doc "Makes `meeting_type` the one this booking is for, with its questions, locations and booking window."
  @spec assign_meeting_type(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_meeting_type(socket, meeting_type) do
    socket
    |> assign(:meeting_type, meeting_type)
    |> assign(:engine, refreshed_engine(socket, meeting_type))
    |> maybe_subscribe_to_group_seats()
    |> BookingLocation.assign_for_meeting_type(
      meeting_type,
      ThemeFlow.reschedule_location_choice(
        socket.assigns[:reschedule_meeting_uid],
        socket.assigns[:organizer_user_id]
      )
    )
    |> OrganizerHelpers.assign_booking_window()
  end

  @doc """
  Entering the questions step: re-syncs the engine with the meeting type's
  current custom-field definitions, so forward and back navigation always
  reflect them, but only when they changed, so going back keeps the answers.
  """
  @spec handle_questions_entry(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_questions_entry(socket) do
    assign(socket, :engine, refreshed_engine(socket, socket.assigns[:meeting_type] || %{}))
  end

  # Re-initialise only when the definitions actually changed, so re-entering a
  # step (or landing on `/book` directly, which resolves the same type again)
  # preserves answers already given. Also what `handle_questions_entry/1` runs.
  defp refreshed_engine(socket, meeting_type) do
    defs = CustomFields.snapshot_for(meeting_type)

    case socket.assigns[:engine] do
      %QEngine{definitions: ^defs} = engine -> engine
      _changed -> init_questions_engine(socket, defs)
    end
  end

  # A fresh questions engine for `definitions`, carrying over the answers of the
  # booking a reschedule is moving.
  #
  # A reschedule re-enters the flow as an ordinary booking, so without this the
  # booker is asked the organiser's questions again from blank, having already
  # answered them — while their name, email and message are prefilled right
  # beside. `Tymeslot.Scheduling.ThemeFlow.reschedule_answers/3` decides which
  # answers may be carried; the step itself is still shown, so the booker sees
  # what will be sent and can change it.
  defp init_questions_engine(socket, definitions) do
    carried =
      ThemeFlow.reschedule_answers(
        socket.assigns[:reschedule_meeting_uid],
        socket.assigns[:organizer_user_id],
        definitions
      )

    definitions
    |> QEngine.init()
    |> QEngine.prefill(carried)
  end

  defp do_handle_schedule_entry(socket, params) do
    normalized_duration =
      ReschedulePin.selected_duration(
        socket,
        normalize_duration_param(params) || socket.assigns[:selected_duration]
      )

    socket =
      socket
      |> assign(:duration, normalized_duration)
      # Arriving at the step is a fresh landing: it gets its own hop budget,
      # even if an earlier visit spent one on a duration that was booked out.
      |> NextAvailable.reset()
      # `mount` reaches this entry before `handle_params` runs, so a date named
      # in the URL is not yet on the socket. The auto-selection runs later, off
      # the fetch result, by which point `handle_params` has seeded it anyway —
      # but this entry is also reached on an in-page step transition, whose
      # params arrive with the event rather than through `handle_params`.
      # Seeding here covers that arrival.
      |> maybe_assign_from_params(:selected_date, date_param(params))
      # After the seed, so a linked or earlier-chosen day opens its own month
      # and week, and the fetch below is for that month. A day outside the
      # booking window is dropped here, and `NextAvailable` lands the booker.
      |> CalendarHelpers.anchor_on_selection()

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
    if selection_made?(socket, params) || reschedule?(socket, params) do
      case resolve_entry_meeting_type(socket, params) do
        {:unresolvable, socket} ->
          socket

        {:ok, socket} ->
          socket
          |> maybe_route_to_questions()
          |> do_handle_booking_entry(params)
      end
    else
      redirect_to_schedule_step(socket, params)
    end
  end

  # Either half of the selection can arrive on the socket (carried from an
  # earlier step) or in the params (a deep link straight to `/book`).
  defp selection_made?(socket, params) do
    selected?(socket.assigns[:selected_date], params["date"]) &&
      selected?(socket.assigns[:selected_time], params["time"])
  end

  defp selected?(assigned, param), do: assigned != nil || (is_binary(param) && param != "")

  # A whole-meeting reschedule carries a meeting uid; a group participant
  # moving their own seat carries a seat token instead. Either one enters the
  # booking step without a prior date/time selection.
  defp reschedule?(socket, params) do
    socket.assigns[:reschedule_meeting_uid] != nil ||
      is_binary(params["reschedule_meeting_uid"]) ||
      socket.assigns[:reschedule_seat_token] != nil ||
      is_binary(params["reschedule_seat_token"])
  end

  defp redirect_to_schedule_step(socket, params) do
    username = socket.assigns[:username_context]
    slug = socket.assigns[:selected_duration] || params["slug"]

    if is_binary(username) && is_binary(slug) do
      redirect(socket, to: ~p"/#{username}/#{slug}")
    else
      redirect(socket, to: ~p"/")
    end
  end

  # `/:username/:slug/book` can be entered directly (a reschedule deep-link,
  # or a locale switch mid-flow, both of which redirect straight back to this
  # URL). Neither passes through the moment collecting the answers (the
  # classic questions step), so a meeting type with required custom fields
  # would otherwise seed the engine with definitions but no answers and render
  # the attendee's moment, which has no UI for them; every submit then fails
  # validation with no way to correct it. Route to the answers' moment instead
  # whenever the freshly-resolved engine still needs it; forward navigation
  # from there already lands back on the attendee's. A moment that collects
  # the answers itself asks them where it is, so it stays: moving to it would
  # enter the attendee's moment again, and again. That is read from the
  # journey, not from `current_state`, which a navigator may update only
  # after the moment has opened.
  defp maybe_route_to_questions(socket) do
    journey = socket.assigns.journey
    answers_moment = Progress.moment_for(journey, :answers)

    if needs_questions_step?(socket.assigns[:engine]) and
         answers_moment != Progress.moment_for(journey, :attendee) do
      Runtime.transition_to(socket, answers_moment, %{})
    else
      socket
    end
  end

  # The rule is `Answers.known?/1`'s: a booking needs the step until it holds.
  defp needs_questions_step?(engine), do: not Answers.known?(%{engine: engine})

  defp do_handle_booking_entry(socket, _params) do
    # Set up form and rate limiting
    client_ip = ClientIP.get(socket)
    submission_token = SubmissionToken.generate()

    # Pre-fill form if rescheduling, scoped to the organizer to prevent PII
    # leaks; otherwise from the booking link's fragment, if it carried one
    form_data =
      case socket.assigns[:reschedule_seat_token] do
        nil ->
          ThemeFlow.build_booking_form_data(
            socket.assigns[:reschedule_meeting_uid],
            socket.assigns[:organizer_user_id],
            socket.assigns[:attendee_prefill] || %{}
          )

        seat_token ->
          ThemeFlow.build_seat_booking_form_data(seat_token)
      end

    socket
    |> OrganizerHelpers.setup_form_state(form_data, as: :booking)
    |> GuestBooking.assign_seat_cap()
    |> assign(:client_ip, client_ip)
    |> assign(:submission_token, submission_token)
    |> assign(:submission_processed, false)
  end

  @doc """
  Subscribes the booking page to live seat updates for the resolved meeting
  type. Group types only; mirrors the calendar subscription `Mount` makes.

  Re-invoked whenever a meeting type is assigned. Switching between group
  types adds a subscription per type without unsubscribing: the
  `{:seat_update, id}` handler matches on the current meeting type's id, so
  broadcasts for a previously viewed type are no-ops. Every id subscribed to
  this session is tracked (not just the most recent one), so returning to a
  type visited earlier is a no-op rather than a second `PubSub.subscribe/2`
  to the same topic, which would otherwise double every later broadcast for
  that type, once per subscription.
  """
  @spec maybe_subscribe_to_group_seats(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_subscribe_to_group_seats(socket) do
    meeting_type = socket.assigns[:meeting_type]
    subscribed_ids = socket.assigns[:group_seats_subscribed_ids] || MapSet.new()

    if connected?(socket) && MeetingTypes.group_type?(meeting_type) &&
         not MapSet.member?(subscribed_ids, meeting_type.id) do
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatBroadcast.topic(meeting_type.id))
      assign(socket, :group_seats_subscribed_ids, MapSet.put(subscribed_ids, meeting_type.id))
    else
      socket
    end
  end
end
