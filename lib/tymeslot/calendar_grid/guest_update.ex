defmodule Tymeslot.CalendarGrid.GuestUpdate do
  @moduledoc """
  Tells an event's guests about the changes made to it since a starting
  point, in one update: the calendar surface's "Tell guests".

  Only the organiser of an event on a calendar they can write may send it
  (`EditGuard.guest_update/3`); anything else is refused before anything is
  enqueued, whatever the client sent.

  An edit of one event is sent through the debounced pipeline
  (`AttendeeNotifications.event_updated_confirm/3`). An edit of this and
  every following occurrence of a series, or of all of them, drops the
  series' cached rows, which that pipeline would read, so it is sent at once
  from both versions (`AttendeeNotifications.series_updated_confirm/4`).

  The debounced update is held for a while before it goes out, so later
  edits join it: `held_until/1` says until when one is still held, and
  `cancel/3` drops it, so the guests are told nothing after all.
  """

  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications

  @type refusal :: :booking | :unauthorized | :read_only | :not_organiser

  @doc """
  Tells `event`'s guests what changed since `opened_with`, the event as it
  was. `scope` is the series scope the changes were written with (`nil`,
  `:this_only`, `:following` or `:all`).

  `{:ok, :sent}` once the update is on its way, `{:ok, :noop}` when there
  is nothing guests would see or nobody to tell, `{:error, refusal}` when
  the user may not send it, and `{:error, reason}` when it could not be
  enqueued.
  """
  @spec tell(pos_integer(), [map()], map(), map(), atom() | nil) ::
          {:ok, :sent | :noop} | {:error, refusal() | term()}
  def tell(user_id, integrations, opened_with, event, scope) do
    with :ok <- EditGuard.guest_update(user_id, integrations, event),
         do: send_update(user_id, opened_with, event, scope)
  end

  defp send_update(user_id, opened_with, event, scope) when scope in [:following, :all],
    do: AttendeeNotifications.series_updated_confirm(opened_with, event, user_id, scope)

  defp send_update(_user_id, opened_with, event, _scope) do
    guests = event |> Map.get(:attendees) |> List.wrap() |> Enum.map(&Attendee.normalise/1)

    case AttendeeNotifications.event_updated(opened_with, event, guests) do
      {:needs_confirmation, summary} ->
        AttendeeNotifications.event_updated_confirm(event, summary, guests)

      {:ok, :no_changes} ->
        {:ok, :noop}
    end
  end

  @doc """
  When the update held for `event`'s guests goes out, or nil when none is
  held. Only a cached calendar event has one; anything else has none.
  """
  @spec held_until(map()) :: DateTime.t() | nil
  def held_until(%ProviderCalendarEventSchema{} = event),
    do: AttendeeNotifications.pending_due_at(event)

  def held_until(_event), do: nil

  @doc """
  Drops the update held for `event`'s guests, so they are told nothing:
  `{:ok, :cancelled}`, or `{:ok, :already_sent}` when none was held any
  more, as it has gone out. Refused, like `tell/5`, unless the user
  organises the event on a calendar they can write.
  """
  @spec cancel(pos_integer(), [map()], map()) ::
          {:ok, :cancelled | :already_sent} | {:error, refusal()}
  def cancel(user_id, integrations, event) do
    with :ok <- EditGuard.guest_update(user_id, integrations, event) do
      case cancel_held(event) do
        {:ok, :cancelled} -> {:ok, :cancelled}
        {:ok, :none} -> {:ok, :already_sent}
      end
    end
  end

  defp cancel_held(%ProviderCalendarEventSchema{} = event),
    do: AttendeeNotifications.cancel_pending(event)

  defp cancel_held(_not_cached), do: {:ok, :none}
end
