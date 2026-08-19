defmodule Tymeslot.Webhooks.Dispatcher do
  @moduledoc """
  Dispatches webhook events when booking events occur.

  Integrates with the notification system to trigger webhooks
  when meetings are created, cancelled, or rescheduled.
  """

  require Logger

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.EventTypes
  alias Tymeslot.Webhooks

  @doc """
  Dispatches webhooks for a meeting event.

  Finds all active webhooks subscribed to the event type
  and schedules delivery jobs via Oban.
  """
  @spec dispatch(atom() | String.t(), MeetingSchema.t()) :: :ok | {:error, term()}
  def dispatch(event_atom, %MeetingSchema{} = meeting) when is_atom(event_atom) do
    event_type = atom_to_event_type(event_atom)
    dispatch(event_type, meeting)
  end

  def dispatch(event_type, %MeetingSchema{} = meeting) when is_binary(event_type) do
    case meeting.organizer_user_id do
      nil ->
        Logger.warning("Cannot dispatch webhook: meeting has no organizer_user_id",
          meeting_id: meeting.id
        )

        {:error, :no_organizer}

      user_id ->
        Logger.debug("Dispatching webhooks",
          user_id: user_id,
          event_type: event_type,
          meeting_id: meeting.id
        )

        Webhooks.trigger_webhooks_for_event(user_id, event_type, meeting)
        :ok
    end
  end

  @doc """
  Converts internal event atoms to webhook event type strings.
  """
  @spec atom_to_event_type(atom()) :: String.t()
  defdelegate atom_to_event_type(atom), to: EventTypes, as: :to_event_type
end
