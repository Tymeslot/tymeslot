defmodule Tymeslot.Slack.Dispatcher do
  @moduledoc """
  Dispatches Slack notifications when booking events occur.

  Public entry point: `dispatch(event_type, meeting)`. The event identifier may
  be either the dotted string Slack integrations subscribe to
  (`"meeting.created"`) or the internal Tymeslot atom (`:meeting_created`).
  """

  require Logger

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.EventTypes
  alias Tymeslot.Slack

  @spec dispatch(atom() | String.t(), MeetingSchema.t()) :: :ok | {:error, term()}
  def dispatch(event_atom, %MeetingSchema{} = meeting) when is_atom(event_atom) do
    dispatch(atom_to_event_type(event_atom), meeting)
  end

  def dispatch(event_type, %MeetingSchema{} = meeting) when is_binary(event_type) do
    case meeting.organizer_user_id do
      nil ->
        Logger.warning("Cannot dispatch Slack: meeting has no organizer_user_id",
          meeting_id: meeting.id
        )

        {:error, :no_organizer}

      user_id ->
        Logger.debug("Dispatching Slack notifications",
          user_id: user_id,
          event_type: event_type,
          meeting_id: meeting.id
        )

        Slack.trigger_integrations_for_event(user_id, event_type, meeting)
        :ok
    end
  end

  @spec atom_to_event_type(atom()) :: String.t()
  defdelegate atom_to_event_type(atom), to: EventTypes, as: :to_event_type
end
