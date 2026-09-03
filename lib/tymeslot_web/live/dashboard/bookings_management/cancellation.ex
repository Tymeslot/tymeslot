defmodule TymeslotWeb.Dashboard.BookingsManagement.Cancellation do
  @moduledoc """
  Telemetry and user-facing copy for cancelling a booking from the dashboard.

  Split out of `BookingsManagementComponent` to keep that module inside the
  size limit: these are the two concerns of the cancel flow that need no socket
  and no reload, so they move cleanly while the socket-threading handlers stay
  with the component that owns the assigns.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @event_prefix [:tymeslot, :dashboard, :meetings, :cancel]

  @doc "Records that the host opened the cancel dialog."
  @spec emit_open(integer(), binary()) :: :ok
  def emit_open(user_id, meeting_id) do
    :telemetry.execute(
      @event_prefix ++ [:open],
      %{},
      %{user_id: user_id, meeting_id: meeting_id}
    )
  end

  @doc """
  Records a cancellation the host was not allowed to make: `:validation_failed`
  for a malformed request, anything else for one the domain refused.
  """
  @spec emit_error(integer(), term(), atom()) :: :ok
  def emit_error(user_id, reason, tag) do
    event = if tag == :validation_failed, do: :validation_failed, else: :blocked

    :telemetry.execute(
      @event_prefix ++ [event],
      %{},
      %{user_id: user_id, reason: inspect(reason)}
    )
  end

  @doc "Records the outcome of a confirmed cancellation."
  @spec emit_confirm(integer(), binary(), term()) :: :ok
  def emit_confirm(user_id, meeting_id, result) do
    measurements = %{user_id: user_id, meeting_id: meeting_id}

    metadata =
      case result do
        {:ok, _cancelled} -> Map.put(measurements, :result, :ok)
        {:error, reason} -> Map.merge(measurements, %{result: :error, reason: inspect(reason)})
      end

    :telemetry.execute(@event_prefix ++ [:confirm], %{}, metadata)
  end

  @doc "The message shown when the refund the host asked for cannot be made."
  @spec refund_error_message(term()) :: String.t()
  def refund_error_message(:acknowledgement_required),
    do:
      dgettext(
        "dashboard_bookings",
        "Tick the acknowledgement to cancel without refunding the attendee."
      )

  def refund_error_message(:exceeds_remaining),
    do: dgettext("dashboard_bookings", "Refund amount exceeds the remaining refundable balance.")

  def refund_error_message(_reason),
    do: dgettext("dashboard_bookings", "Enter a valid partial refund amount.")

  @doc "The message shown once the cancellation has gone through."
  @spec success_message(term()) :: String.t()
  def success_message({:refund, _cents}),
    do: dgettext("dashboard_bookings", "Meeting cancelled and refund issued.")

  def success_message(:none),
    do: dgettext("dashboard_bookings", "Meeting cancelled successfully")
end
