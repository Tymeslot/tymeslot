defmodule TymeslotWeb.Dashboard.BookingsManagementComponent do
  @moduledoc """
  LiveComponent for viewing and managing meetings in the dashboard.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.UUID
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.RateLimiter

  alias Phoenix.LiveView

  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingListComponents
  alias TymeslotWeb.Dashboard.BookingsManagement.Modals

  alias TymeslotWeb.Dashboard.BookingsManagement.RequestActions
  alias TymeslotWeb.Live.Shared.Flash

  require Logger

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> LiveView.stream(:meetings, [])
     |> assign(:filter, "upcoming")
     |> assign(:loading, true)
     |> assign(:is_empty, true)
     |> assign(:cancelling_meeting, nil)
     |> assign(:cancel_booking_payment, nil)
     |> assign(:sending_reschedule, nil)
     |> assign(:answering_request, nil)
     |> assign(:awaiting_approval_count, 0)
     |> assign(:per_page, 20)
     |> assign(:next_cursor, nil)
     |> assign(:has_more, false)
     |> assign(:loading_more, false)
     # Track initialization and last-known values to prevent unnecessary reloads
     |> assign(:_initialized, false)
     |> assign(:_last_filter, nil)
     |> assign(:_last_user_id, nil)
     |> assign(:_last_per_page, nil)
     |> ModalHook.mount_modal(
       cancel_meeting: false,
       reschedule_request: false,
       decline_request: false
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Apply incoming assigns first
    socket = assign(socket, assigns)

    new_filter = socket.assigns.filter
    new_user_id = socket.assigns.current_user.id
    new_per_page = socket.assigns.per_page

    last_filter = socket.assigns[:_last_filter]
    last_user_id = socket.assigns[:_last_user_id]
    last_per_page = socket.assigns[:_last_per_page]
    initialized? = socket.assigns[:_initialized]

    should_load =
      !initialized? or
        new_filter != last_filter or
        new_user_id != last_user_id or
        new_per_page != last_per_page

    socket =
      socket
      |> assign(:_initialized, true)
      |> assign(:_last_filter, new_filter)
      |> assign(:_last_user_id, new_user_id)
      |> assign(:_last_per_page, new_per_page)

    socket = if should_load, do: load_meetings(socket), else: socket

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("filter_meetings", %{"filter" => filter}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_meeting_filter_rate_limit(user_id) do
      :ok ->
        case validate_filter(filter) do
          {:ok, validated_filter} ->
            :telemetry.execute(
              [:tymeslot, :dashboard, :meetings, :filter],
              %{},
              %{user_id: user_id, filter: validated_filter}
            )

            {:noreply,
             socket
             |> assign(:filter, validated_filter)
             |> assign(:next_cursor, nil)
             |> assign(:has_more, false)
             |> assign(:loading, true)
             |> load_meetings()}

          {:error, _errors} ->
            {:noreply, socket}
        end

      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}
    end
  end

  def handle_event("show_cancel_modal", %{"id" => _meeting_id} = params, socket) do
    case fetch_meeting_for_modal(socket, params, policy_fun: &Policy.can_cancel_meeting?/1) do
      {:ok, meeting} ->
        emit_cancel_open_telemetry(socket.assigns.current_user.id, meeting.id)
        booking_payment = MeetingPayments.payment_for_meeting(meeting.id)

        {:noreply,
         socket
         |> assign(:cancel_booking_payment, booking_payment)
         |> ModalHook.show_modal(:cancel_meeting, meeting)}

      {:error, :validation_failed, reason} ->
        emit_cancel_error_telemetry(socket.assigns.current_user.id, reason, :validation_failed)
        {:noreply, socket}

      {:error, :policy_blocked, reason} ->
        emit_cancel_error_telemetry(socket.assigns.current_user.id, reason, :blocked)
        Flash.error(reason)
        {:noreply, socket}

      {:error, :not_found, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("hide_cancel_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:cancel_booking_payment, nil)
     |> ModalHook.hide_modal(:cancel_meeting)}
  end

  def handle_event("confirm_cancel_meeting", params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_dashboard_cancel_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        ModalHook.with_modal_data(socket, :cancel_meeting, fn meeting ->
          do_cancel_meeting(socket, meeting, params)
        end)
    end
  end

  def handle_event("show_reschedule_modal", %{"id" => _id} = params, socket) do
    case fetch_meeting_for_modal(socket, params, policy_fun: &Policy.can_reschedule_meeting?/1) do
      {:ok, meeting} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :reschedule, :open],
          %{},
          %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id}
        )

        {:noreply, ModalHook.show_modal(socket, :reschedule_request, meeting)}

      {:error, :validation_failed, _error} ->
        {:noreply, socket}

      {:error, :policy_blocked, reason} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :reschedule, :blocked],
          %{},
          %{user_id: socket.assigns.current_user.id, reason: inspect(reason)}
        )

        Flash.error(reason)
        {:noreply, socket}

      {:error, :not_found, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("hide_reschedule_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :reschedule_request)}
  end

  def handle_event("confirm_reschedule_request", _params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_dashboard_reschedule_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        ModalHook.with_modal_data(socket, :reschedule_request, fn meeting ->
          do_send_reschedule_request(socket, meeting)
        end)
    end
  end

  def handle_event("dismiss_calendar_sync_banner", %{"id" => meeting_id}, socket) do
    case Meetings.dismiss_calendar_sync_status(meeting_id, socket.assigns.current_user.id) do
      {:ok, updated_meeting} ->
        {:noreply, LiveView.stream_insert(socket, :meetings, updated_meeting)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("load_more", _params, %{assigns: %{loading_more: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    socket = assign(socket, :loading_more, true)

    filter = socket.assigns.filter
    current_user = socket.assigns.current_user
    per_page = socket.assigns.per_page
    after_cursor = socket.assigns.next_cursor

    :telemetry.execute(
      [:tymeslot, :dashboard, :meetings, :load_more, :start],
      %{},
      %{user_id: current_user.id, filter: filter, after: after_cursor}
    )

    case Meetings.list_user_meetings_by_filter(current_user.id, filter,
           per_page: per_page,
           after: after_cursor
         ) do
      {:ok, page} ->
        socket =
          Enum.reduce(page.items, socket, fn item, s ->
            LiveView.stream_insert(s, :meetings, item)
          end)

        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :load_more, :stop],
          %{items: length(page.items)},
          %{user_id: current_user.id, filter: filter, has_more: page.has_more}
        )

        {:noreply,
         socket
         |> assign(:next_cursor, page.next_cursor)
         |> assign(:has_more, page.has_more)
         |> assign(:loading_more, false)}

      {:error, _error} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :load_more, :error],
          %{},
          %{user_id: current_user.id, filter: filter, after: after_cursor}
        )

        Flash.error(dgettext("dashboard_bookings", "Failed to load more meetings"))
        {:noreply, assign(socket, :loading_more, false)}
    end
  end

  # Approving from the dashboard and approving from the emailed link are the
  # same transition through `Meetings.Approval`, which resolves the race
  # between them in the database. The only thing this layer adds is the
  # ownership check: the lookup is scoped to the signed-in host, so an id
  # belonging to somebody else is not found rather than answered.
  def handle_event("approve_request", %{"id" => _id} = params, socket) do
    RequestActions.answer(socket, params, &Approval.approve/1,
      success: dgettext("dashboard_bookings", "Booking confirmed. The invitee has been told."),
      failure: dgettext("dashboard_bookings", "That request could not be approved."),
      reload: &load_meetings/1
    )
  end

  def handle_event("show_decline_modal", %{"id" => _id} = params, socket) do
    case RequestActions.fetch_held_request(socket, params) do
      {:ok, meeting} -> {:noreply, ModalHook.show_modal(socket, :decline_request, meeting)}
      {:error, message} -> {:noreply, RequestActions.flash_and_stay(socket, message)}
    end
  end

  def handle_event("hide_decline_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :decline_request)}
  end

  def handle_event("confirm_decline_request", params, socket) do
    reason = Map.get(params, "reason")

    ModalHook.with_modal_data(socket, :decline_request, fn meeting ->
      socket
      |> ModalHook.hide_modal(:decline_request)
      |> RequestActions.answer(%{"id" => meeting.id}, &Approval.decline(&1, reason),
        success: dgettext("dashboard_bookings", "Request declined. The slot is free again."),
        failure: dgettext("dashboard_bookings", "That request could not be declined."),
        reload: &load_meetings/1
      )
    end)
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="bookings-management" class="space-y-10 pb-20">
      <div>
        <.section_header
          icon="hero-calendar-days"
          title={dgettext("dashboard_bookings", "Meetings")}
        />

        <div class="mb-10">
          <MeetingListComponents.filter_tabs
            active={@filter}
            awaiting_approval_count={@awaiting_approval_count}
            target={@myself}
          />
        </div>

        <MeetingListComponents.meetings_list
          loading={@loading}
          is_empty={@is_empty}
          meetings_stream={@streams.meetings}
          filter={@filter}
          profile={@profile}
          time_format={@time_format}
          cancelling_meeting={@cancelling_meeting}
          sending_reschedule={@sending_reschedule}
          answering_request={@answering_request}
          target={@myself}
        />

        <div :if={@has_more} class="mt-10 text-center">
          <button
            class="btn-secondary px-10 py-4"
            phx-click="load_more"
            phx-target={@myself}
            disabled={@loading_more}
          >
            <span :if={@loading_more}>
              <.spinner class="h-5 w-5 mr-3 inline-block" /> {dgettext(
                "dashboard_bookings",
                "Loading..."
              )}
            </span>
            <span :if={!@loading_more}>{dgettext("dashboard_bookings", "Load more meetings")}</span>
          </button>
        </div>

        <div class="mt-16">
          <MeetingListComponents.info_panel />
        </div>
      </div>

      <Modals.booking_modals
        cancel_meeting={@cancel_meeting_modal_data}
        show_cancel={@show_cancel_meeting_modal || false}
        cancel_booking_payment={@cancel_booking_payment}
        cancelling={@cancelling_meeting != nil}
        decline_request={@decline_request_modal_data}
        show_decline={@show_decline_request_modal || false}
        declining={@answering_request != nil}
        reschedule_request={@reschedule_request_modal_data}
        show_reschedule={@show_reschedule_request_modal || false}
        sending_reschedule={@sending_reschedule}
        profile={@profile}
        time_format={@time_format}
        target={@myself}
      />
    </div>
    """
  end

  # Private functions

  defp do_cancel_meeting(socket, meeting, params) do
    booking_payment = socket.assigns.cancel_booking_payment

    case Meetings.resolve_cancellation_refund(booking_payment, params) do
      {:ok, refund_action} ->
        socket
        |> assign(:cancelling_meeting, meeting.id)
        |> run_cancellation(meeting, booking_payment, refund_action)

      {:error, reason} ->
        Flash.error(refund_error_flash(reason))
        {:noreply, socket}
    end
  end

  defp run_cancellation(socket, meeting, booking_payment, refund_action) do
    result = Meetings.cancel_meeting_with_refund(meeting, booking_payment, refund_action)

    emit_cancel_telemetry(socket, meeting, result)
    handle_cancellation(socket, meeting, refund_action, result)
  end

  defp handle_cancellation(socket, _meeting, refund_action, {:ok, _cancelled}) do
    Flash.info(cancel_success_flash(refund_action))
    {:noreply, close_cancel_modal(socket)}
  end

  # The meeting is cancelled; only the money is outstanding. The modal closes
  # and the list refreshes as on success, because the cancellation itself did
  # happen and leaving the dialog open would suggest otherwise.
  defp handle_cancellation(socket, _meeting, _refund_action, {:error, {:refund_failed, _reason}}) do
    Flash.error(
      dgettext(
        "dashboard_bookings",
        "Meeting cancelled but refund could not be issued. Please issue the refund manually from your Stripe dashboard."
      )
    )

    {:noreply, close_cancel_modal(socket)}
  end

  defp handle_cancellation(socket, meeting, _refund_action, {:error, reason}) do
    Logger.error("cancel_meeting_failed", reason: inspect(reason), meeting_id: meeting.id)
    Flash.error(dgettext("dashboard_bookings", "Failed to cancel meeting. Please try again."))
    {:noreply, assign(socket, :cancelling_meeting, nil)}
  end

  defp close_cancel_modal(socket) do
    socket
    |> assign(:cancelling_meeting, nil)
    |> assign(:cancel_booking_payment, nil)
    |> load_meetings()
    |> ModalHook.hide_modal(:cancel_meeting)
  end

  defp emit_cancel_telemetry(socket, meeting, result) do
    measurements = %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id}

    metadata =
      case result do
        {:ok, _cancelled} -> Map.put(measurements, :result, :ok)
        {:error, reason} -> Map.merge(measurements, %{result: :error, reason: inspect(reason)})
      end

    :telemetry.execute([:tymeslot, :dashboard, :meetings, :cancel, :confirm], %{}, metadata)
  end

  defp refund_error_flash(:acknowledgement_required),
    do:
      dgettext(
        "dashboard_bookings",
        "Tick the acknowledgement to cancel without refunding the attendee."
      )

  defp refund_error_flash(:exceeds_remaining),
    do: dgettext("dashboard_bookings", "Refund amount exceeds the remaining refundable balance.")

  defp refund_error_flash(_reason),
    do: dgettext("dashboard_bookings", "Enter a valid partial refund amount.")

  defp cancel_success_flash({:refund, _cents}),
    do: dgettext("dashboard_bookings", "Meeting cancelled and refund issued.")

  defp cancel_success_flash(:none),
    do: dgettext("dashboard_bookings", "Meeting cancelled successfully")

  defp do_send_reschedule_request(socket, meeting) do
    socket = assign(socket, :sending_reschedule, meeting.id)

    case Meetings.send_reschedule_request(meeting) do
      :ok ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :reschedule, :confirm],
          %{},
          %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id, result: :ok}
        )

        Flash.info(
          dgettext("dashboard_bookings", "Reschedule request sent to %{attendee_name}",
            attendee_name: meeting.attendee_name
          )
        )

        {:noreply,
         socket
         |> assign(:sending_reschedule, nil)
         |> load_meetings()
         |> ModalHook.hide_modal(:reschedule_request)}

      {:error, reason} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :reschedule, :confirm],
          %{},
          %{
            user_id: socket.assigns.current_user.id,
            meeting_id: meeting.id,
            result: :error,
            reason: inspect(reason)
          }
        )

        Logger.error("send_reschedule_request_failed",
          reason: inspect(reason),
          meeting_id: meeting.id
        )

        Flash.error(
          dgettext("dashboard_bookings", "Failed to send reschedule request. Please try again.")
        )

        {:noreply, assign(socket, :sending_reschedule, nil)}
    end
  end

  defp assign_awaiting_approval_count(socket) do
    assign(
      socket,
      :awaiting_approval_count,
      MeetingQueries.count_awaiting_approval_for_organizer(socket.assigns.current_user.id)
    )
  end

  defp emit_cancel_open_telemetry(user_id, meeting_id) do
    :telemetry.execute(
      [:tymeslot, :dashboard, :meetings, :cancel, :open],
      %{},
      %{user_id: user_id, meeting_id: meeting_id}
    )
  end

  defp emit_cancel_error_telemetry(user_id, reason, tag) do
    event = if tag == :validation_failed, do: :validation_failed, else: :blocked

    :telemetry.execute(
      [:tymeslot, :dashboard, :meetings, :cancel, event],
      %{},
      %{user_id: user_id, reason: inspect(reason)}
    )
  end

  defp load_meetings(socket) do
    filter = socket.assigns.filter
    current_user = socket.assigns.current_user
    per_page = socket.assigns.per_page

    :telemetry.execute(
      [:tymeslot, :dashboard, :meetings, :load, :start],
      %{},
      %{user_id: current_user.id, filter: filter}
    )

    case Meetings.list_user_meetings_by_filter(current_user.id, filter, per_page: per_page) do
      {:ok, page} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :load, :stop],
          %{items: length(page.items)},
          %{user_id: current_user.id, filter: filter}
        )

        socket
        |> LiveView.stream(:meetings, page.items, reset: true)
        |> assign(:next_cursor, page.next_cursor)
        |> assign(:has_more, page.has_more)
        |> assign(:loading, false)
        |> assign(:is_empty, page.items == [])
        |> assign_awaiting_approval_count()

      {:error, _error} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :load, :error],
          %{},
          %{user_id: current_user.id, filter: filter}
        )

        Flash.error(dgettext("dashboard_bookings", "Failed to load meetings"))

        socket
        |> LiveView.stream(:meetings, [], reset: true)
        |> assign(:next_cursor, nil)
        |> assign(:has_more, false)
        |> assign(:loading, false)
        |> assign(:is_empty, true)
    end
  end

  defp fetch_meeting_for_modal(socket, params, opts) do
    policy_fun = Keyword.fetch!(opts, :policy_fun)
    user_email = socket.assigns.current_user.email

    with {:ok, validated_id} <- validate_meeting_id(params),
         {:ok, meeting} <- fetch_meeting_for_user(validated_id, user_email),
         :ok <- policy_fun.(meeting) do
      {:ok, meeting}
    else
      {:error, :not_found} -> {:error, :not_found, nil}
      {:error, reason} when is_map(reason) -> {:error, :validation_failed, reason}
      {:error, reason} -> {:error, :policy_blocked, reason}
    end
  end

  defp fetch_meeting_for_user(id, user_email) do
    Meetings.get_meeting_for_user(id, user_email)
  end

  @valid_filters ["upcoming", "past", "cancelled", "awaiting_approval"]

  defp validate_filter(filter) when filter in @valid_filters, do: {:ok, filter}
  defp validate_filter(_filter), do: {:error, "Invalid filter option"}

  defp validate_meeting_id(params) do
    case Map.get(params, "id") do
      id when is_binary(id) ->
        case UUID.cast(String.trim(id)) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, %{id: "Invalid meeting ID format"}}
        end

      _id ->
        {:error, %{id: "Meeting ID is required"}}
    end
  end
end
