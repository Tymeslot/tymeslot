defmodule Tymeslot.Telegram.Dispatcher do
  @moduledoc """
  Dispatches Telegram notifications when booking events occur.
  Mirrors the webhook dispatcher pattern.
  """

  require Logger

  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Telegram

  @spec dispatch(atom() | String.t(), MeetingSchema.t()) :: :ok | {:error, term()}
  def dispatch(event_atom, %MeetingSchema{} = meeting) when is_atom(event_atom) do
    event_type = atom_to_event_type(event_atom)
    dispatch(event_type, meeting)
  end

  def dispatch(event_type, %MeetingSchema{} = meeting) when is_binary(event_type) do
    case meeting.organizer_user_id do
      nil ->
        Logger.warning("Cannot dispatch Telegram: meeting has no organizer_user_id",
          meeting_id: meeting.id
        )

        {:error, :no_organizer}

      user_id ->
        Logger.debug("Dispatching Telegram notifications",
          user_id: user_id,
          event_type: event_type,
          meeting_id: meeting.id
        )

        Telegram.trigger_integrations_for_event(user_id, event_type, meeting)
        :ok
    end
  end

  @spec atom_to_event_type(atom()) :: String.t()
  def atom_to_event_type(:meeting_created), do: "meeting.created"
  def atom_to_event_type(:meeting_cancelled), do: "meeting.cancelled"
  def atom_to_event_type(:meeting_rescheduled), do: "meeting.rescheduled"
  def atom_to_event_type(atom), do: to_string(atom)
end
