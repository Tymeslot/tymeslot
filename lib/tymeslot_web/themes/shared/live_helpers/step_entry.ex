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

  alias Phoenix.HTML.Form
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Bookings.SubmissionToken
  alias Tymeslot.CustomFields
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Scheduling.ThemeFlow
  alias TymeslotWeb.Helpers.ClientIP

  alias TymeslotWeb.Live.Scheduling.{
    AvailabilityHelpers,
    BookingConfig,
    CalendarHelpers,
    InvitationMessages,
    NextAvailable,
    OrganizerHelpers
  }

  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.ChosenLength
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Answers
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.LiveHelpers.InvitationGate
  alias TymeslotWeb.Themes.Shared.PathHandlers
  alias TymeslotWeb.Themes.Shared.ReschedulePin

  # The fields the visitor types into the booking form.
  @booking_fields Enum.map(BookingConfig.booking_field_spec(), &elem(&1, 0))

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
      socket.assigns[:organizer_user_id]
      |> ThemeFlow.resolve_meeting_type_for_duration(duration_str)
      |> offered_here(socket.assigns)
  end

  # The lookup by duration spans every type the organiser has, so a
  # `?duration=` or a crafted `select_duration` could otherwise book, under
  # this address and recorded against its page, a type it does not offer, a
  # private one included. Only a type the address lists, or the one already
  # held (entered by its own address, which `at_own_address?/2` checked), is
  # taken; any other is treated as an unknown duration.
  defp offered_here(%{id: id} = meeting_type, assigns) do
    held = assigns[:meeting_type]
    listed = assigns[:meeting_types] || []

    if (is_map(held) and held.id == id) or Enum.any?(listed, &(&1.id == id)),
      do: meeting_type
  end

  defp offered_here(nil, _assigns), do: nil

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
    case resolve_entry_meeting_type(socket, params, :schedule) do
      {:unresolvable, socket} ->
        socket

      {:ok, socket} ->
        if closed?(socket),
          do: leave_closed(socket),
          else: do_handle_schedule_entry(socket, params)
    end
  end

  # A one-to-one type offering fixed dates with no time left to book would
  # open on a calendar with no day to pick and nothing saying why, so its
  # link leads to the booking page instead, as an invalid one does, saying so.
  # A group type's page says why itself (the event has ended, a session is
  # full), and a reschedule is let through: the booking being moved holds a
  # time the calendar offers it.
  defp closed?(socket) do
    case socket.assigns[:meeting_type] do
      %{} = meeting_type ->
        FixedDates.offered_times?(meeting_type) and not ReschedulePin.pinned?(socket) and
          not FixedDates.open_for_booking?(meeting_type)

      _none ->
        false
    end
  end

  defp leave_closed(socket) do
    socket
    |> put_flash(
      :info,
      dgettext("booking", "This meeting type has no times open for booking right now.")
    )
    |> redirect(to: invalid_meeting_type_redirect_path(socket))
  end

  # Every entry into the flow has to resolve `:meeting_type`, and a reschedule
  # resolves it exactly once, in `ReschedulePin`. The slug in the URL is not
  # consulted for one: two types can share a duration, and a stale reschedule
  # link can name a different type outright. Only when the pin comes back empty
  # (not a reschedule, a whole booking whose type has since been deleted, or a
  # seat on another organiser's meeting) does the slug decide, which is what
  # a fresh booking uses. `step` is the step being entered, `:schedule` or
  # `:booking`, which a type found at another address is sent on to there.
  defp resolve_entry_meeting_type(socket, params, step) do
    slug = normalize_duration_param(params)

    cond do
      ReschedulePin.pinned?(socket) -> {:ok, socket}
      is_nil(slug) -> readmit_held(socket, params)
      true -> resolve_slug_meeting_type(socket, slug, params, step)
    end
  end

  # Resolves the slug in the URL into `:meeting_type`, the record whose rules
  # the submission is validated against. Every entry point into the flow has to
  # do this: a booking that reaches the submit without it persists with
  # `meeting_type_id: nil`, which the domain waves through, dropping the type's
  # custom-field snapshot, schedule, buffers and booking limits, and leaving
  # the duration to an unbounded parse of the slug itself.
  #
  # Returns `{:unresolvable, socket}`, already redirected, when the organiser
  # has no type for this slug (flashed), or when the type's one address is not
  # the one in the URL (`at_own_address?/2`): that goes to the same step at
  # the type's address, so the link still books it, the booking is recorded
  # against the page that offers it, and each type has one address to share.
  defp resolve_slug_meeting_type(socket, slug, params, step) do
    if is_binary(socket.assigns[:username_context]) and is_binary(slug) do
      socket.assigns[:organizer_user_id]
      |> ThemeFlow.resolve_meeting_type_for_slug(slug)
      |> assign_resolved_meeting_type(socket, params, step)
    else
      {:ok, socket}
    end
  end

  defp assign_resolved_meeting_type(nil, socket, _params, _step) do
    {:unresolvable,
     socket
     |> put_flash(:error, dgettext("booking", "Invalid meeting type"))
     |> redirect(to: invalid_meeting_type_redirect_path(socket))}
  end

  defp assign_resolved_meeting_type(meeting_type, socket, params, step) do
    profile = socket.assigns[:organizer_profile]

    if at_own_address?(profile, meeting_type),
      do: admit(socket, meeting_type, params),
      else: {:unresolvable, redirect(socket, to: own_address(socket, meeting_type, params, step))}
  end

  # The entry gate of an invitation-only type (`InvitationGate`): the invitation
  # it admits on becomes `:invitation` for the submit to claim. It runs after
  # the redirect to the type's own address, which carries `?invite=` along with
  # the page's query.
  defp admit(socket, meeting_type, params) do
    case InvitationGate.check(socket, meeting_type, params) do
      {:ok, invitation} ->
        {:ok, socket |> assign(:invitation, invitation) |> assign_meeting_type(meeting_type)}

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  # An entry that names no type (the flow restarting on the type it holds)
  # checks the held invitation-only type's invitation again: a link spent by
  # the booking just made must not open the schedule for another.
  defp readmit_held(socket, params) do
    with %{} = meeting_type <- InvitationGate.held_type(socket),
         {:error, reason} <- InvitationGate.check(socket, meeting_type, params) do
      refuse(socket, reason)
    else
      _admitted_or_none -> {:ok, socket}
    end
  end

  defp refuse(socket, reason) do
    {:unresolvable,
     socket
     |> put_flash(:error, InvitationMessages.message(reason))
     |> redirect(to: invalid_meeting_type_redirect_path(socket))}
  end

  # A booking page serves the types it lists, and those listed nowhere
  # (`BookingPages.serves?/2`); the host's own page serves every type but
  # one hidden from it and listed on a page, whose address is that page's
  # (`BookingPages.home_page/1`). A demo organiser has no pages.
  defp at_own_address?(%ProfileSchema{booking_page: %BookingPageSchema{} = page}, meeting_type),
    do: BookingPages.serves?(page, meeting_type)

  defp at_own_address?(%ProfileSchema{}, meeting_type),
    do: is_nil(BookingPages.home_page(meeting_type))

  defp at_own_address?(_demo_organiser, _meeting_type), do: true

  # The step at the type's own address, with the page's query (an embed's
  # parameters, a preview, a timezone): the one `handle_params` applied, or
  # on a mount that enters before it, the URL's.
  defp own_address(socket, meeting_type, params, step) do
    path = BookingPages.meeting_type_path(socket.assigns.organizer_profile, meeting_type)
    path = if step == :booking, do: path <> "/book", else: path

    query =
      case socket.assigns[:page_query_params] do
        query when is_map(query) and map_size(query) > 0 -> query
        _not_applied -> PathHandlers.query_params(params)
      end

    PathHandlers.with_query(path, query)
  end

  # Carries the reschedule context across the redirect so a bad slug doesn't
  # silently turn a reschedule into a new, duplicate booking, and a demo's
  # chosen theme so the visitor lands on the theme they were viewing.
  defp invalid_meeting_type_redirect_path(socket) do
    query =
      case socket.assigns[:reschedule_meeting_uid] do
        uid when is_binary(uid) and uid != "" -> %{"reschedule_meeting_uid" => uid}
        _other -> %{}
      end

    PathHandlers.with_query(
      "/" <> socket.assigns[:username_context],
      Map.merge(query, PathHandlers.demo_theme_param(socket.assigns))
    )
  end

  @doc "Makes `meeting_type` the one this booking is for, with its questions, locations and booking window."
  @spec assign_meeting_type(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_meeting_type(socket, meeting_type) do
    socket
    |> ChosenLength.keep_if_offered(meeting_type)
    |> assign(:meeting_type, meeting_type)
    |> assign(:engine, refreshed_engine(socket, meeting_type))
    |> maybe_subscribe_to_group_seats()
    |> BookingLocation.assign_for_meeting_type(
      meeting_type,
      ThemeFlow.reschedule_location_choice(socket.assigns[:reschedule_context])
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
  # beside. `Tymeslot.Scheduling.ThemeFlow.reschedule_answers/2` decides which
  # answers may be carried; the step itself is still shown, so the booker sees
  # what will be sent and can change it.
  defp init_questions_engine(socket, definitions) do
    carried = ThemeFlow.reschedule_answers(socket.assigns[:reschedule_context], definitions)

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

    # Trigger the month availability fetch in the background, unless the
    # meeting type's choice has just started the same one.
    if AvailabilityHelpers.can_fetch_availability?(socket) do
      AvailabilityHelpers.ensure_month_availability(socket)
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
      case resolve_entry_meeting_type(socket, params, :booking) do
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
      redirect(socket,
        to:
          PathHandlers.with_query(
            "/#{username}/#{slug}",
            PathHandlers.demo_theme_param(socket.assigns)
          )
      )
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

    # Pre-fill form if rescheduling, from the booking the organiser-scoped
    # lookup loaded, or for a seat move from the participant's own seat;
    # otherwise from the booking link's fragment, if it carried one. A
    # reschedule link whose booking could not be loaded starts blank.
    form_data =
      ThemeFlow.build_booking_form_data(
        socket.assigns[:seat_move_context] || socket.assigns[:reschedule_context],
        Map.merge(InvitationGate.prefill(socket.assigns[:invitation]), fragment_prefill(socket))
      )

    socket
    |> OrganizerHelpers.setup_form_state(Map.merge(form_data, typed_fields(socket)), as: :booking)
    |> GuestBooking.assign_seat_cap()
    |> assign(:client_ip, client_ip)
    |> assign(:submission_token, submission_token)
    |> assign(:submission_processed, false)
  end

  # What the visitor typed into the form while it was open earlier in this
  # page view: the attendee moment closes when the time is forgotten (another
  # day picked, Back on a paged journey, a taken slot) and opens afresh, and
  # its name, email and message are carried over the prefill rather than
  # lost. Only those fields: the token and everything else are made anew.
  # The booking reaching its confirmation, and a restart, drop the form.
  defp typed_fields(socket) do
    case socket.assigns[:form] do
      %Form{params: params} when is_map(params) ->
        Map.take(params, @booking_fields)

      _none ->
        %{}
    end
  end

  defp fragment_prefill(%{assigns: %{reschedule_meeting_uid: uid}}) when is_binary(uid), do: %{}
  defp fragment_prefill(socket), do: socket.assigns[:attendee_prefill] || %{}

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
