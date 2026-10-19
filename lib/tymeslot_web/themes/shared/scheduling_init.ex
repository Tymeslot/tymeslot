defmodule TymeslotWeb.Themes.Shared.SchedulingInit do
  @moduledoc """
  Shared initialization helpers for scheduling themes.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]

  alias Phoenix.LiveView
  alias Tymeslot.Integrations.Calendar.Management
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Live.Scheduling.WeekSlots
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.GuestBooking

  @spec assign_theme_state(LiveView.Socket.t()) :: LiveView.Socket.t()
  def assign_theme_state(socket) do
    socket
    |> assign_base_state()
    |> assign(:duration, nil)
    |> assign(:meeting_type, nil)
    |> assign(:meeting_type_pinned, false)
    # Which day the calendar's weeks start on; `assign_week_start/1` settles
    # it once the organiser is resolved, and this keeps a socket that never
    # gets that far on a defined value. The calendar window (current_year,
    # current_month, current_week_start, calendar_today, and calendar_landing,
    # where the page itself left the calendar) is set on it by
    # `CalendarHelpers.anchor_on_today/1` once the booker's timezone is known;
    # `LiveHelpers.Mount` calls it.
    |> assign(:week_start, :monday)
    |> assign(:month_availability_map, nil)
    |> assign(:availability_status, :not_loaded)
    |> assign(:availability_task, nil)
    |> assign(:availability_task_ref, nil)
    # Nil until a week view asks for its week (`load_week`); see `WeekSlots`.
    |> WeekSlots.assign_defaults()
    |> OrganizerHelpers.setup_form_state(%{}, as: :booking)
    |> assign_new(:client_ip, fn -> nil end)
    |> assign(:submission_token, nil)
    |> assign_new(:meeting_types, fn -> [] end)
    # Engine starts empty; it is re-initialised with the meeting type's custom
    # field snapshot in maybe_assign_meeting_type/2 once the organiser is resolved.
    |> assign(:engine, QEngine.init([]))
  end

  @doc """
  Settles which day the booking calendar's weeks start on, once the
  organiser is resolved: the visitor's own (`:visitor_week_start`, read from
  their `Accept-Language` by `LocalePlug`), else the organiser's calendar
  setting. Only assigns `:week_start`; `CalendarHelpers.anchor_on_today/1`
  builds the calendar window on it.
  """
  @spec assign_week_start(LiveView.Socket.t()) :: LiveView.Socket.t()
  def assign_week_start(socket) do
    week_start =
      socket.assigns[:visitor_week_start] ||
        Management.get_week_start(socket.assigns[:organizer_user_id])

    assign(socket, :week_start, week_start)
  end

  # The organizer context (username_context, organizer_profile,
  # organizer_user_id, meeting_types, client_ip) may already have been
  # resolved by the theme dispatcher before it delegates to the theme
  # mount — use assign_new for those keys so the resolved values are
  # passed through instead of being reset and resolved a second time.
  @spec assign_base_state(LiveView.Socket.t()) :: LiveView.Socket.t()
  def assign_base_state(socket) do
    socket
    # The moment the route opens on (`Navigator.entry/3`), so the page names a
    # moment of its own journey before the connected mount enters it.
    |> assign(:current_state, opening_moment(socket.assigns))
    # Records how the booker entered: only when they landed on the overview do
    # they get a "back to all appointments" control on the schedule step. A
    # direct link (e.g. a private booking link) enters at :schedule and must not
    # expose the organiser's other meeting types. live_action is fixed for the
    # life of the LiveView, so this entry signal is stable across step patches.
    |> assign(:entered_via_overview, socket.assigns[:live_action] == :overview)
    |> assign_new(:username_context, fn -> nil end)
    |> assign_new(:organizer_profile, fn -> nil end)
    |> assign_new(:organizer_user_id, fn -> nil end)
    |> assign(:selected_duration, nil)
    |> assign(:selected_date, nil)
    |> assign(:selected_time, nil)
    |> assign(:available_slots, [])
    # These three describe the slot list currently on screen and are refreshed
    # with it on every fetch. They are defaulted here as well because the slot
    # panel renders before any date is picked, and a template reading them at
    # mount would otherwise raise. nil interval means "use the meeting length",
    # which is the flat grid every meeting type had before intervals existed.
    |> assign(:expanded_hour, nil)
    |> assign(:slot_interval_minutes, nil)
    |> assign(:duration_minutes, nil)
    |> assign(:loading_slots, false)
    |> assign(:calendar_error, nil)
    |> assign(:timezone_dropdown_open, false)
    |> assign(:language_dropdown_open, false)
    |> assign(:timezone_search, "")
    |> assign(:reschedule_meeting_uid, nil)
    |> assign(:reschedule_context, nil)
    |> assign(:reschedule_refusal, nil)
    |> assign(:reschedule_loaded_at_mount, false)
    |> assign(:seat_move_context, nil)
    |> assign(:seat_move_refusal, nil)
    |> assign(:reschedule_seat_token, nil)
    |> assign(:reschedule_seat_from, nil)
    |> assign(:page_query_params, %{})
    |> assign(:is_rescheduling, false)
    |> assign(:meeting_uid, nil)
    |> assign(:seat_calendar_url, nil)
    |> assign(:name, "")
    |> assign(:email, "")
    |> assign(:submitting, false)
    |> assign(:submission_processed, false)
    # Safe defaults so the confirmation components can always render
    # `@custom_fields_snapshot`/`@custom_field_answers`. The booking
    # submission handler overrides these with the real snapshot/answers on a
    # successful booking; a direct visit to `/:username/thank-you` mounts the
    # confirmation state without going through that handler, so without these
    # defaults the render raises a KeyError.
    |> assign(:custom_fields_snapshot, [])
    |> assign(:custom_field_answers, %{})
    |> GuestBooking.assign_defaults()
    |> BookingLocation.assign_defaults()
  end

  # `SchedulingLive` assigns the journey before it mounts the page.
  defp opening_moment(%{journey: journey} = assigns),
    do: journey.navigator.entry(journey, assigns[:live_action], assigns)
end
