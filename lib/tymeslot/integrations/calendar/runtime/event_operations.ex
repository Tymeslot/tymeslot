defmodule Tymeslot.Integrations.Calendar.Runtime.EventOperations do
  @moduledoc """
  Calendar event CRUD operations (Create, Read, Update, Delete).

  Responsibilities:
  - Create calendar events with validation
  - Update existing events by UID
  - Delete events by UID
  - Get single events by UID
  - Context-aware routing (integration_id vs Meeting context)
  """

  require Logger
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Runtime.EventQueries
  alias Tymeslot.Integrations.Calendar.Utils.EventValidator

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type event_uid :: String.t()
  @type event_data :: map()
  @type context ::
          user_id()
          | {integration_id(), user_id()}
          | MeetingSchema.t()
          | MeetingTypeSchema.t()
          | nil

  @doc """
  Creates a new event using the user's booking calendar.
  """
  @spec create_event(event_data(), context()) ::
          {:ok, map()} | {:error, term()}
  def create_event(event_data, context \\ nil) do
    Metrics.time_operation(:create_event, %{}, fn ->
      Logger.info("Creating new calendar event")

      with :ok <- validate_event(event_data),
           %{} = client <- ClientManager.booking_client(context),
           {:ok, _event} = result <- ProviderAdapter.create_event(client, event_data) do
        Logger.info("Successfully created calendar event")
        result
      else
        nil ->
          Logger.error("Failed to create calendar event - no calendar client available",
            context: log_context(context)
          )

          {:error, :no_calendar_client}

        {:error, :invalid_event_data} = error ->
          error

        {:error, type, reason} ->
          Logger.error("Failed to create calendar event",
            error_type: type,
            reason: inspect(reason)
          )

          {:error, reason}

        {:error, reason} = error ->
          Logger.error("Failed to create calendar event", reason: inspect(reason))
          error
      end
    end)
  end

  @doc """
  Updates an existing event by UID.
  Accepts optional context (MeetingSchema, user_id, or {integration_id, user_id}) to use specific calendar.
  """
  @spec update_event(event_uid(), event_data(), context() | {integration_id(), user_id()}) ::
          :ok | {:error, term()}
  def update_event(uid, event_data, context \\ nil) do
    Metrics.time_operation(:update_event, %{uid: uid}, fn ->
      Logger.info("Updating calendar event", uid: uid)

      with %{} = client <- ClientManager.resolve_client(context),
           :ok <- ProviderAdapter.update_event(client, uid, event_data) do
        Logger.info("Successfully updated calendar event", uid: uid)
        :ok
      else
        nil ->
          Logger.error("No calendar integration found for update", context: log_context(context))
          {:error, :no_calendar_integration}

        {:error, type, reason} ->
          Logger.error("Failed to update calendar event",
            error_type: type,
            uid: uid,
            reason: inspect(reason)
          )

          {:error, reason}

        {:error, reason} = error ->
          Logger.error("Failed to update calendar event", uid: uid, reason: inspect(reason))
          error
      end
    end)
  end

  @doc """
  Deletes an event by UID.
  Accepts optional context (MeetingSchema, user_id, or {integration_id, user_id}) to use specific calendar.
  """
  @spec delete_event(event_uid(), context() | {integration_id(), user_id()}, keyword()) ::
          :ok | {:error, term()}
  def delete_event(uid, context \\ nil, opts \\ []) do
    Metrics.time_operation(:delete_event, %{uid: uid}, fn ->
      Logger.info("Deleting calendar event", uid: uid)

      with %{} = client <- ClientManager.resolve_client(context),
           :ok <- ProviderAdapter.delete_event(client, uid, opts) do
        Logger.info("Successfully deleted calendar event", uid: uid)
        :ok
      else
        nil ->
          Logger.error("No calendar integration found for deletion",
            uid: uid,
            context: log_context(context)
          )

          {:error, :no_calendar_integration}

        {:error, type, reason} ->
          Logger.error("Failed to delete calendar event",
            error_type: type,
            uid: uid,
            reason: inspect(reason)
          )

          {:error, reason}

        {:error, reason} = error ->
          Logger.error("Failed to delete calendar event",
            uid: uid,
            reason: inspect(reason)
          )

          error
      end
    end)
  end

  @doc """
  Get a single event by UID.
  Searches across all calendars for the event for a specific user.
  """
  @spec get_event(event_uid(), user_id() | nil) :: {:ok, map()} | {:error, :not_found | term()}
  def get_event(uid, user_id \\ nil) do
    Logger.debug("Getting calendar event", uid: uid, user_id: user_id)

    case EventQueries.list_events(user_id) do
      {:ok, events} ->
        event = Enum.find(events, &(&1.uid == uid))

        if event do
          Logger.debug("Found calendar event", uid: uid)
          {:ok, event}
        else
          Logger.warning("Calendar event not found", uid: uid)
          {:error, :not_found}
        end

      error ->
        error
    end
  end

  # --- Private Helpers ---

  defp validate_event(event_data) do
    case EventValidator.validate(event_data) do
      {:ok, _result} -> :ok
      {:error, _cs} -> {:error, :invalid_event_data}
    end
  end

  defp log_context(%MeetingSchema{} = meeting) do
    %{
      meeting_id: meeting.id,
      organizer_user_id: meeting.organizer_user_id,
      meeting_type_id: meeting.meeting_type_id
    }
  end

  defp log_context(%MeetingTypeSchema{} = meeting_type) do
    %{meeting_type_id: meeting_type.id, user_id: meeting_type.user_id}
  end

  defp log_context(user_id) when is_integer(user_id), do: %{user_id: user_id}
  defp log_context(_arg), do: %{}
end
