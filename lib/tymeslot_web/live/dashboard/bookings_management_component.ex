defmodule TymeslotWeb.Dashboard.BookingsManagementComponent do
  @moduledoc """
  LiveComponent for viewing and managing meetings in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings
  alias Tymeslot.Security.MeetingsInputProcessor
  alias TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal
  alias TymeslotWeb.Components.Dashboard.Meetings.RescheduleRequestModal
  alias TymeslotWeb.Components.DashboardComponents
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Dashboard.Meetings.{Components, Helpers, Loader}
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash
  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> LiveView.stream(:meetings, [])
     |> assign(:meetings, [])
     |> assign(:filter, "upcoming")
     |> assign(:loading, true)
     |> assign(:cancelling_meeting, nil)
     |> assign(:sending_reschedule, nil)
     |> assign(:per_page, 20)
     |> assign(:next_cursor, nil)
     |> assign(:has_more, false)
     |> assign(:loading_more, false)
     # Track initialization and last-known values to prevent unnecessary reloads
     |> assign(:_initialized, false)
     |> assign(:_last_filter, nil)
     |> assign(:_last_user_id, nil)
     |> assign(:_last_per_page, nil)
     |> ModalHook.mount_modal(cancel_meeting: false, reschedule_request: false)}
  end

  @impl true
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

  @impl true
  def handle_event("filter_meetings", %{"filter" => filter}, socket) do
    metadata = DashboardHelpers.get_security_metadata(socket)

    case MeetingsInputProcessor.validate_filter_input(%{"filter" => filter}, metadata: metadata) do
      {:ok, %{"filter" => validated_filter}} ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :filter
          ],
          %{},
          %{user_id: socket.assigns.current_user.id, filter: validated_filter}
        )

        {:noreply,
         socket
         |> assign(:filter, validated_filter)
         |> assign(:next_cursor, nil)
         |> assign(:has_more, false)
         |> assign(:meetings, [])
         |> assign(:loading, true)
         |> load_meetings()}

      {:error, _errors} ->
        # On filter validation failure, keep current filter and log the attempt
        {:noreply, socket}
    end
  end

  def handle_event("show_cancel_modal", %{"id" => id} = params, socket) do
    Logger.debug("Cancel modal event received id=#{id}")

    case fetch_meeting_for_modal(socket, params, policy_fun: &Policy.can_cancel_meeting?/1) do
      {:ok, meeting} ->
        emit_cancel_open_telemetry(socket.assigns.current_user.id, meeting.id)
        Logger.debug("Showing modal for meeting id=#{meeting.id}")
        {:noreply, ModalHook.show_modal(socket, :cancel_meeting, meeting)}

      {:error, :validation_failed, reason} ->
        emit_cancel_error_telemetry(socket.assigns.current_user.id, reason, :validation_failed)
        Logger.debug("Cancellation validation blocked: #{inspect(reason)}")
        {:noreply, socket}

      {:error, :policy_blocked, reason} ->
        Logger.debug("Cancellation blocked: #{inspect(reason)}")
        emit_cancel_error_telemetry(socket.assigns.current_user.id, reason, :blocked)
        Flash.error(reason)
        {:noreply, socket}

      {:error, :not_found, _} ->
        Logger.debug("Meeting not found")
        {:noreply, socket}
    end
  end

  def handle_event("hide_cancel_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :cancel_meeting)}
  end

  def handle_event("confirm_cancel_meeting", _params, socket) do
    meeting = socket.assigns.cancel_meeting_modal_data
    socket = assign(socket, :cancelling_meeting, meeting.id)

    case Meetings.cancel_meeting(meeting) do
      {:ok, _cancelled_meeting} ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :cancel,
            :confirm
          ],
          %{},
          %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id, result: :ok}
        )

        Flash.info("Meeting cancelled successfully")

        # Remove cancelled meeting from the current list instead of reloading all meetings
        updated_meetings = Enum.filter(socket.assigns.meetings, fn m -> m.id != meeting.id end)

        {:noreply,
         socket
         |> assign(:cancelling_meeting, nil)
         |> assign(:meetings, updated_meetings)
         |> LiveView.stream_delete(:meetings, meeting)
         |> ModalHook.hide_modal(:cancel_meeting)}

      {:error, reason} ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :cancel,
            :confirm
          ],
          %{},
          %{
            user_id: socket.assigns.current_user.id,
            meeting_id: meeting.id,
            result: :error,
            reason: inspect(reason)
          }
        )

        Flash.error("Failed to cancel meeting: #{inspect(reason)}")
        {:noreply, assign(socket, :cancelling_meeting, nil)}
    end
  end

  def handle_event("cancel_meeting", %{"id" => id}, socket) do
    # Legacy handler for backwards compatibility, redirects to show modal
    handle_event("show_cancel_modal", %{"id" => id}, socket)
  end

  def handle_event("show_reschedule_modal", %{"id" => id} = params, socket) do
    Logger.debug("Reschedule modal event received id=#{id}")

    case fetch_meeting_for_modal(socket, params, policy_fun: &Policy.can_reschedule_meeting?/1) do
      {:ok, meeting} ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :reschedule,
            :open
          ],
          %{},
          %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id}
        )

        {:noreply, ModalHook.show_modal(socket, :reschedule_request, meeting)}

      {:error, :validation_failed, reason} ->
        Logger.debug("Reschedule validation blocked: #{inspect(reason)}")
        {:noreply, socket}

      {:error, :policy_blocked, reason} ->
        Logger.debug("Reschedule blocked: #{inspect(reason)}")

        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :reschedule,
            :blocked
          ],
          %{},
          %{user_id: socket.assigns.current_user.id, reason: inspect(reason)}
        )

        Flash.error(reason)
        {:noreply, socket}

      {:error, :not_found, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("hide_reschedule_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :reschedule_request)}
  end

  def handle_event("confirm_reschedule_request", _params, socket) do
    meeting = socket.assigns.reschedule_request_modal_data
    socket = assign(socket, :sending_reschedule, meeting.id)

    case Meetings.send_reschedule_request(meeting) do
      :ok ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :reschedule,
            :confirm
          ],
          %{},
          %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id, result: :ok}
        )

        Flash.info("Reschedule request sent to #{meeting.attendee_name}")

        {:noreply,
         socket
         |> assign(:sending_reschedule, nil)
         |> ModalHook.hide_modal(:reschedule_request)}

      {:error, reason} ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :reschedule,
            :confirm
          ],
          %{},
          %{
            user_id: socket.assigns.current_user.id,
            meeting_id: meeting.id,
            result: :error,
            reason: inspect(reason)
          }
        )

        Flash.error("Failed to send reschedule request: #{inspect(reason)}")
        {:noreply, assign(socket, :sending_reschedule, nil)}
    end
  end

  def handle_event("load_more", _params, %{assigns: %{loading_more: true}} = socket) do
    # Prevent overlapping pagination requests
    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    socket = assign(socket, :loading_more, true)

    filter = socket.assigns.filter
    current_user = socket.assigns.current_user
    per_page = socket.assigns.per_page
    after_cursor = socket.assigns.next_cursor

    :telemetry.execute(
      [
        :tymeslot,
        :dashboard,
        :meetings,
        :load_more,
        :start
      ],
      %{},
      %{user_id: current_user.id, filter: filter, after: after_cursor}
    )

    case Loader.list_meetings_page_for_user(filter, current_user, per_page, after_cursor) do
      {:ok, page} ->
        socket =
          Enum.reduce(page.items, socket, fn item, s ->
            LiveView.stream_insert(s, :meetings, item)
          end)

        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :load_more,
            :stop
          ],
          %{items: length(page.items)},
          %{user_id: current_user.id, filter: filter, has_more: page.has_more}
        )

        {:noreply,
         socket
         |> assign(:meetings, socket.assigns.meetings ++ page.items)
         |> assign(:next_cursor, page.next_cursor)
         |> assign(:has_more, page.has_more)
         |> assign(:loading_more, false)}

      {:error, _reason} ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :load_more,
            :error
          ],
          %{},
          %{user_id: current_user.id, filter: filter, after: after_cursor}
        )

        Flash.error("Failed to load more meetings")
        {:noreply, assign(socket, :loading_more, false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div>
        <DashboardComponents.section_header
          icon={:calendar}
          title="Meetings"
          title_class="text-2xl sm:text-3xl font-bold text-neutral-800"
        />

        <Components.filter_tabs active={@filter} target={@myself} />

        <Components.meetings_list
          loading={@loading}
          meetings={@meetings}
          meetings_stream={@streams.meetings}
          filter={@filter}
          profile={@profile}
          cancelling_meeting={@cancelling_meeting}
          sending_reschedule={@sending_reschedule}
          target={@myself}
        />

        <%= if @has_more do %>
          <div class="mt-4 text-center">
            <button
              class="btn btn-secondary"
              phx-click="load_more"
              phx-target={@myself}
              disabled={@loading_more}
            >
              <%= if @loading_more do %>
                Loading...
              <% else %>
                Load more
              <% end %>
            </button>
          </div>
        <% end %>

        <Components.info_panel />

        <div class="pb-8"></div>
      </div>

      <CancelMeetingModal.cancel_meeting_modal
        id="cancel-meeting-modal"
        show={@show_cancel_meeting_modal || false}
        meeting={@cancel_meeting_modal_data}
        timezone={
          if @cancel_meeting_modal_data,
            do: Helpers.get_meeting_timezone(@cancel_meeting_modal_data, @profile),
            else: "UTC"
        }
        cancelling={@cancelling_meeting != nil}
        on_cancel={JS.push("hide_cancel_modal", target: @myself)}
        on_confirm={JS.push("confirm_cancel_meeting", target: @myself)}
      />

      <RescheduleRequestModal.reschedule_request_modal
        id="reschedule-request-modal"
        show={@show_reschedule_request_modal || false}
        meeting={@reschedule_request_modal_data}
        timezone={
          if @reschedule_request_modal_data,
            do: Helpers.get_meeting_timezone(@reschedule_request_modal_data, @profile),
            else: "UTC"
        }
        sending={
          !!(@reschedule_request_modal_data && @sending_reschedule &&
               @sending_reschedule == @reschedule_request_modal_data.id)
        }
        on_cancel={JS.push("hide_reschedule_modal", target: @myself)}
        on_confirm={JS.push("confirm_reschedule_request", target: @myself)}
      />
    </div>
    """
  end

  # Private functions

  defp emit_cancel_open_telemetry(user_id, meeting_id) do
    :telemetry.execute(
      [
        :tymeslot,
        :dashboard,
        :meetings,
        :cancel,
        :open
      ],
      %{},
      %{user_id: user_id, meeting_id: meeting_id}
    )
  end

  defp emit_cancel_error_telemetry(user_id, reason, tag) do
    event =
      case tag do
        :validation_failed -> :validation_failed
        _ -> :blocked
      end

    :telemetry.execute(
      [
        :tymeslot,
        :dashboard,
        :meetings,
        :cancel,
        event
      ],
      %{},
      %{user_id: user_id, error: inspect(reason), reason: inspect(reason)}
    )
  end

  defp load_meetings(socket) do
    filter = socket.assigns.filter
    current_user = socket.assigns.current_user
    per_page = socket.assigns.per_page

    :telemetry.execute(
      [
        :tymeslot,
        :dashboard,
        :meetings,
        :load,
        :start
      ],
      %{},
      %{user_id: current_user.id, filter: filter}
    )

    case Loader.list_meetings_page_for_user(filter, current_user, per_page, nil) do
      {:ok, page} ->
        socket = LiveView.stream(socket, :meetings, page.items, reset: true)

        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :load,
            :stop
          ],
          %{items: length(page.items)},
          %{user_id: current_user.id, filter: filter}
        )

        socket
        |> assign(:meetings, page.items)
        |> assign(:next_cursor, page.next_cursor)
        |> assign(:has_more, page.has_more)
        |> assign(:loading, false)

      {:error, _reason} ->
        :telemetry.execute(
          [
            :tymeslot,
            :dashboard,
            :meetings,
            :load,
            :error
          ],
          %{},
          %{user_id: current_user.id, filter: filter}
        )

        Flash.error("Failed to load meetings")

        socket
        |> assign(:meetings, [])
        |> assign(:next_cursor, nil)
        |> assign(:has_more, false)
        |> assign(:loading, false)
    end
  end

  # Helper function to get security metadata
  defp fetch_meeting_for_modal(socket, params, opts) do
    metadata = DashboardHelpers.get_security_metadata(socket)
    policy_fun = Keyword.fetch!(opts, :policy_fun)

    with {:ok, %{"id" => validated_id}} <-
           MeetingsInputProcessor.validate_meeting_id_input(params, metadata: metadata),
         meeting when not is_nil(meeting) <-
           Enum.find(socket.assigns.meetings, fn m -> to_string(m.id) == validated_id end),
         :ok <- policy_fun.(meeting) do
      {:ok, meeting}
    else
      {:error, reason} when is_map(reason) ->
        {:error, :validation_failed, reason}

      {:error, reason} ->
        {:error, :policy_blocked, reason}

      nil ->
        {:error, :not_found, nil}
    end
  end
end
