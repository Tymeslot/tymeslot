defmodule Tymeslot.Integrations.Calendar.Runtime.EventOperations do
  @moduledoc """
  Calendar event write operations (create, update, delete).

  Responsibilities:
  - Create calendar events with validation
  - Update existing events by UID
  - Delete events by UID
  - Context-aware routing (integration_id vs Meeting context)

  Failures surface as `{:error, type}`, where `type` is the provider's
  classification atom (`:not_found`, `:unauthorized`, `:rate_limited`, …).
  Callers dispatch on that atom — `CalendarEventSync` recreates a missing
  event, `CalendarEventWorker` maps it to a retry outcome — so a provider's
  `{:error, type, message}` is reduced to its type here and the message is
  logged rather than returned.
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Utils.EventValidator
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

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

  The success value is a `CreatedEvent`: the identifier the event is addressed
  by, plus whatever identity the provider gave away with it, namely its own id
  for the resource and, on CalDAV, the ETag the server assigned.
  """
  @spec create_event(event_data(), context()) ::
          {:ok, CreatedEvent.t()} | {:error, term()}
  def create_event(event_data, context) do
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

          {:error, type}

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
  def update_event(uid, event_data, context) do
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

          {:error, type}

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
  def delete_event(uid, context, opts) do
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

          {:error, type}

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
  Fetches one event of the given calendar integration straight from its
  provider, bypassing the sync cache.

  Every calendar of the integration a client reaches is asked in turn, since
  the event may live in any of them. The answer is `{:ok, events}` as soon as
  one finds it, `{:error, :not_found}` only when every one of them says it
  does not exist, `{:error, :unsupported}` when the provider cannot fetch a
  single event, and any other error when it could not be told. An integration
  that is not the user's, or no longer active, is
  `{:error, :no_calendar_integration}`.
  """
  @spec fetch_event(map(), {integration_id(), user_id()}) ::
          {:ok, list()} | {:error, :not_found} | {:error, term()}
  def fetch_event(event_ref, {integration_id, user_id})
      when is_integer(integration_id) and is_integer(user_id) do
    case CalendarManagement.fetch_integration_for_user(integration_id, user_id) do
      {:ok, integration} ->
        integration
        |> event_clients()
        |> fetch_from_clients(Map.put(event_ref, :calendar_integration_id, integration_id))

      {:error, _reason} ->
        {:error, :no_calendar_integration}
    end
  end

  # One client per calendar the integration reaches, plus the booking calendar
  # Tymeslot writes new events to, which need not be among the selected ones.
  defp event_clients(integration) do
    booking = ClientManager.get_client_by_integration_id(integration.id, integration.user_id)

    Enum.uniq(ClientManager.clients_for_integration(integration) ++ List.wrap(booking))
  end

  defp fetch_from_clients([], _event_ref), do: {:error, :no_calendar_client}

  defp fetch_from_clients(clients, event_ref) do
    Enum.reduce_while(clients, {:error, :not_found}, fn client, acc ->
      case ProviderAdapter.fetch_event(client, event_ref) do
        {:ok, _events} = found -> {:halt, found}
        {:error, :not_found} -> {:cont, acc}
        # One calendar that could not answer leaves the event's absence
        # unproven, whatever the others say, unless another one finds it.
        {:error, _reason} = error -> {:cont, unproven(acc, error)}
      end
    end)
  end

  defp unproven({:error, :not_found}, error), do: error
  defp unproven(earlier_error, _error), do: earlier_error

  # --- Private Helpers ---

  defp validate_event(event_data) do
    case EventValidator.validate(event_data) do
      {:ok, _result} -> :ok
      {:error, _cs} -> {:error, :invalid_event_data}
    end
  end

  defp log_context(%MeetingSchema{} = meeting) do
    [
      meeting_id: meeting.id,
      organizer_user_id: meeting.organizer_user_id,
      meeting_type_id: meeting.meeting_type_id
    ]
  end

  defp log_context(%MeetingTypeSchema{} = meeting_type) do
    [meeting_type_id: meeting_type.id, user_id: meeting_type.user_id]
  end

  defp log_context(user_id) when is_integer(user_id), do: [user_id: user_id]
  defp log_context(_arg), do: []
end
