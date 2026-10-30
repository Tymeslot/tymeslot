defmodule Tymeslot.Webhooks.MeetingSnapshot do
  @moduledoc """
  The event-defining fields of a meeting, captured at the moment a webhook
  fires and replayed at delivery time instead of being re-derived.

  Without this, a `meeting.requested` delivery retried after the host has
  since approved or declined re-reads the meeting fresh and reports its
  *current* state under the original event's envelope: the event says one
  thing and the body says another. Kept to the handful of scalar/datetime
  fields that actually drive `Tymeslot.Webhooks.PayloadBuilder`'s
  status-dependent sections, rather than snapshotting the whole meeting into
  the job args.

  The snapshot is stored in Oban job args, so every value is JSON-safe:
  datetimes are encoded as ISO 8601 strings and decoded on replay.
  """

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.SeatView

  @snapshot_fields ~w(
    status cancelled_at cancellation_reason decline_reason
    approval_requested_at approval_deadline_at approval_resolved_at
    approval_declined_at
  )a

  @datetime_snapshot_fields ~w(
    cancelled_at approval_requested_at approval_deadline_at approval_resolved_at
    approval_declined_at
  )a

  @doc """
  Captures the event-defining fields of a meeting for
  `Tymeslot.Workers.WebhookWorker.schedule_delivery/5`.

  Called by the trigger site at the moment the event fires, so a retried
  delivery can replay what that event asserted rather than whatever the
  meeting looks like by the time the retry runs.

  A group meeting's seat (`Tymeslot.Meetings.SeatView`) also pins the seats
  taken on the slot when the event fired, under `"seats_taken"`, and the
  seat a move replaced, under `"previous_seat"`.
  """
  @spec snapshot(MeetingSchema.t()) :: map()
  def snapshot(%MeetingSchema{} = meeting) do
    meeting
    |> Map.take(@snapshot_fields)
    |> Map.new(fn {field, value} -> {Atom.to_string(field), encode_snapshot_field(value)} end)
    |> maybe_put_seats_taken(SeatView.seats_taken(meeting))
    |> maybe_put_previous_seat(SeatView.previous_seat(meeting))
  end

  @doc """
  Replays a snapshot over a freshly loaded meeting: each captured field
  overrides the live value, and a field the snapshot lacks keeps it. A `nil`
  snapshot (a job enqueued before snapshots existed) leaves the meeting as
  loaded.
  """
  @spec replay(MeetingSchema.t(), map() | nil) :: MeetingSchema.t()
  def replay(meeting, nil), do: meeting

  def replay(%MeetingSchema{} = meeting, snapshot) when is_map(snapshot) do
    overrides =
      Enum.map(@snapshot_fields, fn field ->
        {field, snapshot_field_value(snapshot, field, Map.get(meeting, field))}
      end)

    struct(meeting, overrides)
  end

  @doc """
  The seats taken on the slot when the event fired, or `nil` when the
  snapshot pinned none.
  """
  @spec seats_taken(map() | nil) :: integer() | nil
  def seats_taken(%{"seats_taken" => seats}) when is_integer(seats), do: seats
  def seats_taken(_snapshot), do: nil

  @doc """
  The seat a move replaced, decoded from the snapshot, or `nil` when the
  snapshot pinned none or its start time does not parse.
  """
  @spec previous_seat(map() | nil) :: map() | nil
  def previous_seat(%{
        "previous_seat" => %{
          "seat_id" => seat_id,
          "meeting_id" => meeting_id,
          "start_time" => start_time
        }
      }) do
    case DateTime.from_iso8601(start_time) do
      {:ok, start_time, _offset} ->
        %{seat_id: seat_id, meeting_id: meeting_id, start_time: start_time}

      {:error, _reason} ->
        nil
    end
  end

  def previous_seat(_snapshot), do: nil

  defp maybe_put_seats_taken(snapshot, nil), do: snapshot
  defp maybe_put_seats_taken(snapshot, seats), do: Map.put(snapshot, "seats_taken", seats)

  defp maybe_put_previous_seat(snapshot, nil), do: snapshot

  defp maybe_put_previous_seat(snapshot, previous) do
    Map.put(snapshot, "previous_seat", %{
      "seat_id" => previous.seat_id,
      "meeting_id" => previous.meeting_id,
      "start_time" => DateTime.to_iso8601(previous.start_time)
    })
  end

  defp encode_snapshot_field(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  # Job args are JSON: the status is stored in its string form.
  defp encode_snapshot_field(status) when is_atom(status) and status != nil,
    do: Atom.to_string(status)

  defp encode_snapshot_field(value), do: value

  defp snapshot_field_value(snapshot, field, default) do
    case Map.fetch(snapshot, Atom.to_string(field)) do
      {:ok, value} -> decode_snapshot_field(field, value, default)
      :error -> default
    end
  end

  defp decode_snapshot_field(_field, nil, _default), do: nil

  # Read back through the known statuses rather than `String.to_atom/1`; a
  # value no status matches keeps the meeting's own.
  defp decode_snapshot_field(:status, value, default) when is_binary(value) do
    Enum.find(MeetingState.statuses(), default, &(Atom.to_string(&1) == value))
  end

  defp decode_snapshot_field(field, value, _default) when field in @datetime_snapshot_fields do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
    end
  end

  defp decode_snapshot_field(_field, value, _default), do: value
end
