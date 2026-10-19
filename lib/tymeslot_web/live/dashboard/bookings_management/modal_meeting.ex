defmodule TymeslotWeb.Dashboard.BookingsManagement.ModalMeeting do
  @moduledoc """
  Resolves the meeting a bookings-dashboard modal (cancel, reschedule request)
  is asked to open for, and whether the booking rules still allow the action.

  The meeting id arrives from the client, so it is validated and the meeting
  is looked up scoped to the signed-in host (`Meetings.get_meeting_for_organizer/2`)
  before the action's policy check runs.
  """

  alias Ecto.UUID
  alias Tymeslot.Meetings
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage

  @doc """
  The host's meeting named by `params["id"]`, when `policy_fun` allows the
  action on it. Refuses a malformed id with `:validation_failed`, a meeting
  the host does not own with `:not_found`, and one the policy refuses with
  `:policy_blocked` and the policy's reason. A group meeting arrives with its
  live participants, since its modals and flashes speak of them.
  """
  @spec fetch(integer(), map(), (Meetings.MeetingSchema.t() -> :ok | {:error, term()})) ::
          {:ok, Meetings.MeetingSchema.t()}
          | {:error, :not_found, nil}
          | {:error, :validation_failed, map()}
          | {:error, :policy_blocked, term()}
  def fetch(user_id, params, policy_fun) when is_function(policy_fun, 1) do
    with {:ok, validated_id} <- validate_meeting_id(params),
         {:ok, meeting} <- fetch_meeting_for_organizer(validated_id, user_id),
         :ok <- policy_fun.(meeting) do
      {:ok, meeting}
    else
      {:error, :not_found} -> {:error, :not_found, nil}
      {:error, reason} when is_map(reason) -> {:error, :validation_failed, reason}
      {:error, reason} -> {:error, :policy_blocked, reason}
    end
  end

  @doc "The copy shown to the host for a `:policy_blocked` reason from `fetch/3`."
  @spec refusal_message(term()) :: String.t()
  def refusal_message(reason), do: BookingErrorMessage.message(reason)

  defp fetch_meeting_for_organizer(id, user_id) do
    with {:ok, meeting} <- Meetings.get_meeting_for_organizer(id, user_id) do
      if Meetings.group?(meeting),
        do: {:ok, Meetings.with_live_participants(meeting)},
        else: {:ok, meeting}
    end
  end

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
