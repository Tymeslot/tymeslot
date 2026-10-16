defmodule TymeslotWeb.Themes.Shared.InfoHandlers do
  @moduledoc """
  Shared handle_info handlers for theme scheduling LiveViews.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  require Logger

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Live.Scheduling.NextAvailable
  alias TymeslotWeb.Live.Scheduling.WeekSlots
  alias TymeslotWeb.Themes.Shared.BookingFlow
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Reveal
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @doc """
  Routes a message the scheduling LiveView received to its handler.

  Returns `:unhandled` for a message the booking flow does not own, so the
  LiveView can offer it to the theme and otherwise ignore it.
  """
  @spec route(term(), Socket.t()) :: {:noreply, Socket.t()} | :unhandled
  def route({:flash, {type, message}}, socket), do: {:noreply, put_flash(socket, type, message)}

  def route({:calendar_events_updated, _user_id, _changed_uids}, socket),
    do: handle_calendar_events_updated(socket)

  def route({:calendar_sync_complete, _user_id, _integration_id}, socket),
    do: handle_calendar_events_updated(socket)

  def route(:close_dropdown, socket), do: handle_close_dropdown(socket)

  def route({:fetch_available_slots, date, duration, timezone}, socket),
    do: handle_fetch_available_slots(socket, date, duration, timezone)

  def route({:load_slots, date}, socket), do: handle_load_slots(socket, date)

  def route({:seat_update, meeting_type_id}, socket),
    do: handle_seat_update(socket, meeting_type_id)

  def route({ref, {:ok, availability_map}}, socket) when is_reference(ref),
    do: handle_availability_ok(socket, ref, availability_map)

  def route({ref, {:error, reason}}, socket) when is_reference(ref),
    do: handle_availability_error(socket, ref, reason)

  # A monitor this LiveView never asked for — LiveView's own channel
  # intercepts the ones it owns before delegating here. The availability
  # fetch cannot produce one (its task is linked, so a crash kills this
  # process instead), so there is nothing to finalise: ignore it rather
  # than let it reach `handle_unexpected/2` and log a warning per stray
  # monitor on a public page.
  def route({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  # PubSub broadcasts for embedded paid bookings — see
  # `BookingSubmissionHandlerComponent.handle_payment_required_embedded/3`.
  def route(:paid, socket), do: handle_payment_paid(socket)
  def route(:expired, socket), do: handle_payment_expired(socket)
  def route(_message, _socket), do: :unhandled

  @doc """
  Handles calendar events updated via PubSub.

  Re-fetches the month availability map and a week view's week, and clears any
  cached slot data so the scheduling page reflects the latest calendar state.
  The chosen time is dropped only while the visitor has not moved past the
  moment collecting the slot (`Progress.at_or_before?/2`); once they have,
  the booking they are completing keeps it.
  """
  @spec handle_calendar_events_updated(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_events_updated(socket) do
    socket =
      if Progress.at_or_before?(socket.assigns, :slot) do
        socket
        |> assign(:available_slots, nil)
        |> assign(:selected_time, nil)
        |> AvailabilityHelpers.fetch_month_availability_async()
        |> WeekSlots.refetch()
      else
        AvailabilityHelpers.fetch_month_availability_async(socket)
      end

    {:noreply, socket}
  end

  @doc """
  Handles month availability fetch completion (success).
  """
  @spec handle_availability_ok(Phoenix.LiveView.Socket.t(), reference(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_availability_ok(socket, ref, availability_map) do
    Process.demonitor(ref, [:flush])
    finalize_availability_task(socket, ref, :loaded, availability_map)
  end

  @doc """
  Handles month availability fetch completion (error).

  There is no crash counterpart: the fetch runs in a *linked* task, so a
  task that raises takes the LiveView with it and never delivers a
  `:DOWN` anyone could act on. A handler for one would be unreachable
  code pretending the page degrades gracefully.
  """
  @spec handle_availability_error(Phoenix.LiveView.Socket.t(), reference(), any()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_availability_error(socket, ref, reason) do
    Process.demonitor(ref, [:flush])

    finalize_availability_task(socket, ref, :error, nil, fn ->
      Logger.warning("Month availability fetch failed", reason: LogFormat.reason(reason))
    end)
  end

  # Applies the terminal availability-task state, but only for the *current*
  # task ref — a stale ref (the user moved on before the fetch finished) is a
  # no-op. `on_active` runs only when the ref matches, so an error warning is
  # never emitted for a superseded fetch.
  defp finalize_availability_task(socket, ref, status, map, on_active \\ fn -> :ok end) do
    if ref == socket.assigns[:availability_task_ref] do
      on_active.()

      socket =
        socket
        |> assign(:month_availability_map, map)
        |> assign(:availability_status, status)
        |> assign(:availability_task, nil)
        |> assign(:availability_task_ref, nil)
        |> apply_auto_selection(status)
        # The landing can move the week under a grid that has already loaded.
        |> WeekSlots.follow_week()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Landing the booker on the first bookable day. This runs on the task result
  # rather than on schedule-step entry because the availability map does not
  # exist yet at entry — it is precisely this message that carries it.
  #
  # A `:refetch` means the whole loaded range was dead, so the window has moved
  # forward and needs its own fetch; the hop counter inside NextAvailable stops
  # that walking forever.
  #
  # Only a loaded map is searched. On an :error the map is nil, which
  # is indistinguishable from "no day is free" — advancing the month on a
  # failed fetch would march the booker through months nobody has successfully
  # looked at.
  defp apply_auto_selection(socket, :loaded) do
    case NextAvailable.apply(socket) do
      {socket, :done} -> socket
      {socket, :refetch} -> AvailabilityHelpers.fetch_month_availability_async(socket)
    end
  end

  # A failed fetch still spends the attempt. The booker is on the schedule step
  # looking at the error banner; leaving the landing armed means the next fetch
  # to succeed — a month arrow, a week arrow, a calendar-sync broadcast — picks
  # a day and re-aligns the window onto it, moving the calendar backwards under
  # a booker who asked to go forwards.
  defp apply_auto_selection(socket, _failed), do: NextAvailable.settle(socket)

  @doc """
  Handles common dropdown closing logic.
  """
  @spec handle_close_dropdown(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_dropdown(socket) do
    {:noreply, assign(socket, :timezone_dropdown_open, false)}
  end

  @doc """
  Handles fetching available slots.
  """
  @spec handle_fetch_available_slots(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t() | integer(),
          String.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_fetch_available_slots(socket, date, duration, timezone) do
    {_result, updated_socket} =
      SlotFetchingHandlerComponent.fetch_available_slots(socket, date, duration, timezone)

    {:noreply, check_carried_time(updated_socket, date)}
  end

  # A time the URL carried (a deep link, or a language switch, which
  # redirects with the day and time chosen) is checked once, against the
  # first times fetched for its day. On a page that opens its moments by
  # itself the time alone made the slot known, so the page moved on past
  # the calendar; a time no longer free, or one whose day's times failed to
  # load (a failed fetch offers none, so it cannot be confirmed free), is
  # dropped there, with what was built on it, and the page settles back on
  # the moment collecting the slot. A paged journey keeps it: its booking
  # step is already on screen, and the submission refuses a time that was
  # taken.
  defp check_carried_time(%{assigns: %{carried_time: time, selected_date: date}} = socket, date)
       when is_binary(time) do
    socket = assign(socket, :carried_time, nil)

    if Reveal.journey?(socket.assigns[:journey]) and socket.assigns[:selected_time] == time and
         not slot_still_available?(socket.assigns[:available_slots], time) do
      before = socket.assigns[:current_state]
      socket = socket |> Runtime.clear([:slot]) |> Runtime.settle()

      if socket.assigns[:current_state] == before,
        do: socket,
        else: assign(socket, :journey_focus, socket.assigns[:current_state])
    else
      socket
    end
  end

  defp check_carried_time(socket, _date), do: socket

  @doc """
  Handles loading slots for a specific date.
  """
  @spec handle_load_slots(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_load_slots(socket, date) do
    case SlotFetchingHandlerComponent.load_slots(socket, date) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
    end
  end

  # A burst of seat changes on a popular slot broadcasts one message per
  # change; without coalescing, every one of them drove its own synchronous,
  # uncached refetch on every connected page. Trailing-edge debounce: the
  # first update in a quiet period refreshes immediately, and any further
  # ones within the window collapse into a single re-check once it elapses,
  # rather than one full refetch per broadcast per page.
  @seat_update_debounce_ms 500

  @doc """
  Handles a `{:seat_update, meeting_type_id}` broadcast from the domain layer.

  Refetches slots for the currently displayed date (and a week view's week)
  and updates them in place, never clearing the visitor's selection, unless
  the selected slot has filled up, in which case the visitor goes back to the
  moment collecting the slot with the same flash and recovery as a lost
  submit race.

  Only while the booker is on the moment collecting the slot or a later one:
  on an outcome the "missing" slot is very likely the one this booker just
  took, and before the slot's moment nothing has been chosen.
  """
  @spec handle_seat_update(Phoenix.LiveView.Socket.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_seat_update(socket, meeting_type_id) do
    with %{id: ^meeting_type_id} <- socket.assigns[:meeting_type],
         true <- slot_moment_reached?(socket.assigns),
         date when is_binary(date) <- socket.assigns[:selected_date] do
      debounce_or_refresh_seats(socket, meeting_type_id, date)
    else
      _other -> {:noreply, socket}
    end
  end

  defp slot_moment_reached?(%{journey: %{moments: _moments} = journey} = assigns) do
    Progress.collecting_now?(assigns, :slot) or
      (Journey.moment(journey, assigns[:current_state]) != nil and
         not Progress.at_or_before?(assigns, :slot))
  end

  defp slot_moment_reached?(_assigns), do: false

  defp debounce_or_refresh_seats(socket, meeting_type_id, date) do
    now = System.monotonic_time(:millisecond)
    last_refreshed_at = socket.assigns[:seat_update_refreshed_at]

    if is_integer(last_refreshed_at) and now - last_refreshed_at < @seat_update_debounce_ms do
      schedule_trailing_seat_update(socket, meeting_type_id)
    else
      socket =
        socket
        |> assign(:seat_update_refreshed_at, now)
        |> assign(:seat_update_timer_ref, nil)

      refresh_seats_for_date(socket, date)
    end
  end

  # At most one trailing refresh is ever pending: a timer already scheduled
  # means a later broadcast in the same quiet-period window is redundant with
  # it, so it is dropped rather than stacking another one behind it.
  defp schedule_trailing_seat_update(socket, meeting_type_id) do
    if socket.assigns[:seat_update_timer_ref] do
      {:noreply, socket}
    else
      ref = Process.send_after(self(), {:seat_update, meeting_type_id}, @seat_update_debounce_ms)
      {:noreply, assign(socket, :seat_update_timer_ref, ref)}
    end
  end

  defp refresh_seats_for_date(socket, date) do
    duration = socket.assigns[:duration] || socket.assigns[:selected_duration]
    timezone = socket.assigns[:user_timezone]

    case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, duration, timezone) do
      {:ok, updated_socket} ->
        updated_socket
        |> WeekSlots.refetch()
        |> apply_refreshed_seats()

      # A passive background refresh failing is not something the booker
      # caused and must not cost them what they already have: restore the
      # slot list and suppress the error the shared fetch just assigned,
      # rather than propagating a wiped list and an alarming banner. Their
      # selection stands until a successful refresh (or the submit-time
      # check) says otherwise.
      {:error, _failed_socket} ->
        {:noreply, socket}
    end
  end

  defp apply_refreshed_seats(socket) do
    selected_time = socket.assigns[:selected_time]

    cond do
      is_nil(selected_time) ->
        {:noreply, socket}

      slot_still_available?(socket.assigns[:available_slots], selected_time) ->
        {:noreply, GuestBooking.assign_seat_cap(socket)}

      true ->
        socket =
          socket
          |> put_flash(:error, BookingErrorMessage.message(:slot_taken))
          |> BookingFlow.return_to_schedule_for_new_slot(&Runtime.transition_to/3)

        {:noreply, socket}
    end
  end

  defp slot_still_available?(slots, time) do
    slots
    |> MeetingUtils.normalize_slot_list()
    |> Enum.any?(&(&1.time == time))
  end

  @doc """
  Handles the `:paid` PubSub broadcast for an embedded paid booking.

  The booker iframe subscribed to `meeting_payment:<meeting_id>` when it
  pushed Stripe Checkout to a new tab; when the webhook confirms the
  payment we flip the iframe directly to the theme's `:confirmation`
  view so the attendee never sees Stripe inside the host's page.
  """
  @spec handle_payment_paid(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_payment_paid(socket) do
    case socket.assigns do
      %{current_state: :awaiting_payment, awaiting_payment_meeting: %{} = meeting} ->
        socket =
          socket
          |> assign(:meeting_uid, meeting.uid)
          |> assign(:seat_calendar_url, nil)
          |> BookingLocation.assign_booked(meeting)
          |> assign(:name, meeting.attendee_name)
          |> assign(:email, meeting.attendee_email)
          |> Runtime.forget_payment_wait()

        {:noreply, Runtime.transition_to(socket, :confirmation, %{})}

      # Only the wait ends on a payment: a broadcast repeated once the page
      # has moved on (the confirmation, a booking started again) moves
      # nothing.
      _not_waiting ->
        {:noreply, socket}
    end
  end

  @doc """
  Handles the `:expired` PubSub broadcast for an embedded paid booking.

  When the Stripe Checkout session expires (attendee closed the tab,
  30 minutes elapsed, etc.) we send the booker back to the moment
  collecting the attendee (the classic booking step) with a flash so they
  can try again, and stop listening for that meeting's payment broadcasts.
  """
  @spec handle_payment_expired(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_payment_expired(socket) do
    case socket.assigns do
      %{current_state: :awaiting_payment, awaiting_payment_meeting: %{}} ->
        socket =
          socket
          |> Runtime.forget_payment_wait()
          |> assign(:submission_processed, false)
          |> put_flash(
            :error,
            dgettext("booking", "Payment was cancelled. Please try booking again.")
          )

        {:noreply,
         Runtime.transition_to(
           socket,
           Progress.moment_for(socket.assigns.journey, :attendee),
           %{}
         )}

      # As with `:paid`, only the wait ends on an expiry: a broadcast repeated
      # once the page has moved on (a later booking, its confirmation) moves
      # nothing.
      _not_waiting ->
        {:noreply, socket}
    end
  end

  @doc """
  Ignores a message the scheduling LiveView has no clause for.

  Without this the process raises, the theme error boundary catches it, and a
  booker part-way through a booking is shown an error page over a message that
  had nothing to do with them. The booking page is public and long-lived, so it
  has to tolerate whatever reaches its mailbox: a late reply from a task whose
  result is no longer wanted, or a library that posts to whichever process
  called it.
  """
  @spec handle_unexpected(Phoenix.LiveView.Socket.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_unexpected(socket, message) do
    Logger.warning("Scheduling LiveView ignoring unexpected message",
      message_shape: message_shape(message),
      current_state: socket.assigns[:current_state],
      organizer_user_id: socket.assigns[:organizer_user_id]
    )

    Logger.debug(fn ->
      "Scheduling LiveView ignoring unexpected message (full): " <>
        inspect(message, limit: 50, printable_limit: 200)
    end)

    {:noreply, socket}
  end

  # Logs only what shape the message has — never its content, which on this
  # public, unauthenticated page may carry booker PII (e.g. a stray Swoosh
  # post-delivery message embeds attendee name/email).
  defp message_shape(message) when is_tuple(message) and tuple_size(message) > 0 do
    "{#{inspect(elem(message, 0))}, arity: #{tuple_size(message)}}"
  end

  defp message_shape(message) when is_atom(message), do: inspect(message)
  defp message_shape(message) when is_reference(message), do: "reference"
  defp message_shape(message) when is_pid(message), do: "pid"
  defp message_shape(message) when is_map(message), do: "map"
  defp message_shape(message) when is_list(message), do: "list"
  defp message_shape(_message), do: "other"
end
