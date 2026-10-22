defmodule TymeslotWeb.Components.Dashboard.Meetings.HostMoveModal do
  @moduledoc """
  LiveComponent in which the host picks a new time for a meeting they manage,
  one confirmed from a poll (`MeetingSchema.managed_by_host?/1`).

  Such a meeting has no booker to ask for a new time, so the dashboard's
  Reschedule opens this instead of the reschedule request. The time is read
  in the host's timezone and the meeting keeps its length. On a move, or when
  the host closes it, it tells the owning `BookingsManagementComponent`
  (`host_move: :moved | :closed`).
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Meetings
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:error, fn -> nil end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <Modal.modal
        id={@id}
        show
        on_cancel={JS.push("close", target: @myself)}
        size={:medium}
      >
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-arrows-right-left" class="w-5 h-5 text-turquoise-600" />
            {dgettext("dashboard_bookings", "Move this meeting")}
          </div>
        </:header>

        <div class="space-y-4">
          <p class="text-tymeslot-600">
            {dgettext(
              "dashboard_bookings",
              "It was arranged by a poll, so you choose its new time. Everyone invited is sent the new time with an updated calendar entry and asked again whether they can come."
            )}
          </p>

          <p class="text-token-sm text-tymeslot-500">
            {dgettext("dashboard_bookings", "Currently: %{date}, %{time}",
              date: Helpers.format_meeting_date(@meeting, @timezone),
              time: Helpers.format_meeting_time(@meeting, @timezone, @time_format)
            )}
          </p>

          <form
            id={"#{@id}-form"}
            phx-submit="move"
            phx-target={@myself}
            data-testid="host-move-form"
          >
            <.input
              type="datetime-local"
              name="move[start]"
              value=""
              label={dgettext("dashboard_bookings", "New start (%{timezone})", timezone: @timezone)}
              required
              errors={List.wrap(@error)}
            />
          </form>
        </div>

        <:footer>
          <div class="flex justify-end gap-3">
            <.action_button variant={:secondary} phx-click={JS.push("close", target: @myself)}>
              {dgettext("common", "Cancel")}
            </.action_button>
            <.action_button type="submit" form={"#{@id}-form"} data-testid="host-move-submit">
              {dgettext("dashboard_bookings", "Move meeting")}
            </.action_button>
          </div>
        </:footer>
      </Modal.modal>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("close", _params, socket) do
    send_update(socket.assigns.parent_module, id: socket.assigns.parent_id, host_move: :closed)
    {:noreply, socket}
  end

  def handle_event("move", %{"move" => %{"start" => value}}, socket) do
    %{meeting: meeting, timezone: timezone, user_id: user_id} = socket.assigns

    with {:ok, new_start} <- parse(value, timezone),
         {:ok, _moved} <- Meetings.move_by_host(meeting.uid, new_start, user_id) do
      Flash.info(dgettext("dashboard_bookings", "Meeting moved. Everyone invited has been told."))
      send_update(socket.assigns.parent_module, id: socket.assigns.parent_id, host_move: :moved)
      {:noreply, socket}
    else
      {:error, reason} -> {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  defp parse(value, timezone) when is_binary(value) and value != "" do
    normalized = if String.length(value) == 16, do: value <> ":00", else: value

    with {:ok, naive} <- NaiveDateTime.from_iso8601(normalized),
         {:ok, datetime} <- DateTimeUtils.convert_to_utc(naive, timezone) do
      {:ok, datetime}
    else
      _invalid -> {:error, :invalid_time}
    end
  end

  defp parse(_value, _timezone), do: {:error, :invalid_time}

  defp error_message(:invalid_time),
    do: dgettext("dashboard_bookings", "Enter the new date and time.")

  defp error_message(:slot_in_past),
    do: dgettext("dashboard_bookings", "The new time must be in the future.")

  defp error_message(:slot_taken),
    do: dgettext("dashboard_bookings", "You already have a meeting at that time.")

  defp error_message(:time_off),
    do:
      dgettext(
        "dashboard_bookings",
        "This time falls within your time off. Change or remove the time off to move the meeting there."
      )

  defp error_message(_reason),
    do: dgettext("dashboard_bookings", "The meeting could not be moved. Please try again.")
end
