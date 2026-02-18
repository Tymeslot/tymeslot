defmodule TymeslotWeb.Dashboard.BookingsManagementComponent do
  @moduledoc """
  LiveComponent for viewing and managing meetings in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Ecto.UUID
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings
  alias Tymeslot.Security.RateLimiter

  alias Phoenix.LiveView

  alias TymeslotWeb.Components.Dashboard.Meetings.{
    CancelMeetingModal,
    Helpers,
    MeetingListComponents,
    RescheduleRequestModal
  }

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
        {:noreply, ModalHook.show_modal(socket, :cancel_meeting, meeting)}

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
    {:noreply, ModalHook.hide_modal(socket, :cancel_meeting)}
  end

  def handle_event("confirm_cancel_meeting", _params, socket) do
    meeting = socket.assigns.cancel_meeting_modal_data
    socket = assign(socket, :cancelling_meeting, meeting.id)

    case Meetings.cancel_meeting(meeting) do
      {:ok, _cancelled_meeting} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :cancel, :confirm],
          %{},
          %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id, result: :ok}
        )

        Flash.info("Meeting cancelled successfully")

        {:noreply,
         socket
         |> assign(:cancelling_meeting, nil)
         |> load_meetings()
         |> ModalHook.hide_modal(:cancel_meeting)}

      {:error, reason} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :cancel, :confirm],
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
    meeting = socket.assigns.reschedule_request_modal_data
    socket = assign(socket, :sending_reschedule, meeting.id)

    case Meetings.send_reschedule_request(meeting) do
      :ok ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :reschedule, :confirm],
          %{},
          %{user_id: socket.assigns.current_user.id, meeting_id: meeting.id, result: :ok}
        )

        Flash.info("Reschedule request sent to #{meeting.attendee_name}")

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

        Flash.error("Failed to send reschedule request: #{inspect(reason)}")
        {:noreply, assign(socket, :sending_reschedule, nil)}
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

        Flash.error("Failed to load more meetings")
        {:noreply, assign(socket, :loading_more, false)}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <div>
        <.section_header icon={:calendar} title="Meetings" />

        <div class="mb-10">
          <MeetingListComponents.filter_tabs active={@filter} target={@myself} />
        </div>

        <MeetingListComponents.meetings_list
          loading={@loading}
          is_empty={@is_empty}
          meetings_stream={@streams.meetings}
          filter={@filter}
          profile={@profile}
          cancelling_meeting={@cancelling_meeting}
          sending_reschedule={@sending_reschedule}
          target={@myself}
        />

        <%= if @has_more do %>
          <div class="mt-10 text-center">
            <button
              class="btn-secondary px-10 py-4"
              phx-click="load_more"
              phx-target={@myself}
              disabled={@loading_more}
            >
              <%= if @loading_more do %>
                <.spinner class="h-5 w-5 mr-3 inline-block" /> Loading...
              <% else %>
                Load more meetings
              <% end %>
            </button>
          </div>
        <% end %>

        <div class="mt-16">
          <MeetingListComponents.info_panel />
        </div>
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

      {:error, _error} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :load, :error],
          %{},
          %{user_id: current_user.id, filter: filter}
        )

        Flash.error("Failed to load meetings")

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

  @valid_filters ["upcoming", "past", "cancelled"]

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
