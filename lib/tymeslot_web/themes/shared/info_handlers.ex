defmodule TymeslotWeb.Themes.Shared.InfoHandlers do
  @moduledoc """
  Shared handle_info handlers for theme scheduling LiveViews.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  require Logger

  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Live.Scheduling.NextAvailable
  alias TymeslotWeb.Themes.Shared.BookingFlow
  alias TymeslotWeb.Themes.Shared.GuestBooking

  @doc """
  Handles calendar events updated via PubSub.

  Re-fetches the month availability map and clears any cached slot data
  so the scheduling page reflects the latest calendar state.
  """
  @spec handle_calendar_events_updated(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_events_updated(socket) do
    socket =
      case socket.assigns[:current_state] do
        state when state in [:overview, :schedule, nil] ->
          socket
          |> assign(:available_slots, nil)
          |> assign(:selected_time, nil)
          |> AvailabilityHelpers.fetch_month_availability_async()

        _committed ->
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
      Logger.warning("Month availability fetch failed", reason: inspect(reason))
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
    case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, duration, timezone) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
      {:error, updated_socket} -> {:noreply, updated_socket}
    end
  end

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

  # Seat updates only matter while the booker is somewhere between picking a
  # slot and submitting. On :confirmation the "missing" slot is very likely
  # the one this booker just took — bouncing there would be absurd.
  @seat_update_states [:schedule, :questions, :booking]

  # A burst of seat changes on a popular slot broadcasts one message per
  # change; without coalescing, every one of them drove its own synchronous,
  # uncached refetch on every connected page. Trailing-edge debounce: the
  # first update in a quiet period refreshes immediately, and any further
  # ones within the window collapse into a single re-check once it elapses,
  # rather than one full refetch per broadcast per page.
  @seat_update_debounce_ms 500

  @doc """
  Handles a `{:seat_update, meeting_type_id}` broadcast from the domain layer.

  Refetches slots for the currently displayed date only and updates
  `available_slots` in place, never clearing the visitor's selection — unless
  the selected slot has filled up, in which case the visitor bounces back to
  the schedule step with the same flash and recovery as a lost submit race.
  """
  @spec handle_seat_update(
          Phoenix.LiveView.Socket.t(),
          term(),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_seat_update(socket, meeting_type_id, transition_fun) do
    with %{id: ^meeting_type_id} <- socket.assigns[:meeting_type],
         true <- socket.assigns[:current_state] in @seat_update_states,
         date when is_binary(date) <- socket.assigns[:selected_date] do
      debounce_or_refresh_seats(socket, meeting_type_id, date, transition_fun)
    else
      _other -> {:noreply, socket}
    end
  end

  defp debounce_or_refresh_seats(socket, meeting_type_id, date, transition_fun) do
    now = System.monotonic_time(:millisecond)
    last_refreshed_at = socket.assigns[:seat_update_refreshed_at]

    if is_integer(last_refreshed_at) and now - last_refreshed_at < @seat_update_debounce_ms do
      schedule_trailing_seat_update(socket, meeting_type_id)
    else
      socket =
        socket
        |> assign(:seat_update_refreshed_at, now)
        |> assign(:seat_update_timer_ref, nil)

      refresh_seats_for_date(socket, date, transition_fun)
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

  defp refresh_seats_for_date(socket, date, transition_fun) do
    duration = socket.assigns[:duration] || socket.assigns[:selected_duration]
    timezone = socket.assigns[:user_timezone]

    case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, duration, timezone) do
      {:ok, updated_socket} ->
        apply_refreshed_seats(updated_socket, transition_fun)

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

  defp apply_refreshed_seats(socket, transition_fun) do
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
          |> BookingFlow.return_to_schedule_for_new_slot(transition_fun)

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
  @spec handle_payment_paid(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_payment_paid(socket, transition_fun) do
    case socket.assigns[:awaiting_payment_meeting] do
      %{} = meeting ->
        socket =
          socket
          |> assign(:meeting_uid, meeting.uid)
          |> assign(:name, meeting.attendee_name)
          |> assign(:email, meeting.attendee_email)

        {:noreply, transition_fun.(socket, :confirmation, %{})}

      _other ->
        {:noreply, socket}
    end
  end

  @doc """
  Handles the `:expired` PubSub broadcast for an embedded paid booking.

  When the Stripe Checkout session expires (attendee closed the tab,
  30 minutes elapsed, etc.) we send the booker back to the booking form
  with a flash so they can try again.
  """
  @spec handle_payment_expired(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_payment_expired(socket, transition_fun) do
    socket =
      socket
      |> assign(:awaiting_payment_meeting, nil)
      |> assign(:awaiting_payment_checkout_url, nil)
      |> assign(:submission_processed, false)
      |> put_flash(
        :error,
        dgettext("booking", "Payment was cancelled. Please try booking again.")
      )

    {:noreply, transition_fun.(socket, :booking, %{})}
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
