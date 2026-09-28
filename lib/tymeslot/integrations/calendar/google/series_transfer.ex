defmodule Tymeslot.Integrations.Calendar.Google.SeriesTransfer do
  @moduledoc """
  Moving a whole Google recurring series, addressed by its master's id, to
  another calendar: of the same Google account, or of another one. Reached
  through `Tymeslot.Integrations.Calendar.Events.move_google_series/3`,
  which loads both integrations as the user's.

    * **Within one integration** the series is moved as Google moves it
      (`events.move`): one request, after which the master has the same id
      and `iCalUID` on the destination calendar, with every instance,
      instances edited on their own, exceptions and the Meet. Nothing is
      created or deleted apart from it.
    * **Across integrations** Google has no move, so the master is read on
      the source, inserted into the destination calendar as
      `Google.CreatableEvent` makes it creatable (its whole `recurrence`,
      `EXDATE` lines included, and its conference as the join details it
      has), and only once the destination has accepted it is the master
      deleted on the source. Instances edited on their own are separate
      events in Google, which the copy does not carry: their occurrences
      come back on the destination as the rule makes them.

  Every request goes out on its own integration's API client and with its
  own access token, refreshed as every Google call refreshes it.

  A move to the calendar the series is already on is refused with
  `:same_calendar` before anything is sent: Google has nothing to move, and
  a copy of the series next to itself is not what the organiser asked for.

  Answers `{:ok, moved}` (`t:moved/0`) once the destination holds the
  series, or `{:error, reason}` with nothing written. A delete that fails
  once the copy exists is not an error: the answer says
  `source: :left_behind`, the copy stays, and nothing is queued.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.CreatableEvent

  require Logger

  @typedoc "The series a move takes: its master, on a calendar of an integration."
  @type source :: %{
          integration: CalendarIntegrationSchema.t(),
          calendar_id: String.t(),
          master_id: String.t()
        }

  @typedoc "The calendar a series moves to, of an integration."
  @type destination :: %{integration: CalendarIntegrationSchema.t(), calendar_id: String.t()}

  @typedoc "Where a moved series now lives: its master's `iCalUID` and id."
  @type moved :: %{
          uid: String.t(),
          id: String.t(),
          calendar_id: String.t(),
          source: :removed | :left_behind
        }

  @doc """
  Moves the series `source` names to `destination` (see the moduledoc).
  """
  @spec move(source(), destination()) :: {:ok, moved()} | {:error, term()}
  def move(
        %{integration: %{id: id}, calendar_id: calendar_id},
        %{integration: %{id: id}, calendar_id: calendar_id}
      ),
      do: {:error, :same_calendar}

  def move(%{integration: %{id: id}} = source, %{integration: %{id: id}} = destination) do
    moved =
      api().move_event(
        source.integration,
        source.calendar_id,
        source.master_id,
        destination.calendar_id
      )

    with {:ok, master} <- reason(moved) do
      {:ok,
       %{
         uid: master["iCalUID"],
         id: master["id"] || source.master_id,
         calendar_id: destination.calendar_id,
         source: :removed
       }}
    end
  end

  def move(source, destination) do
    api = api()

    with {:ok, master} <- read_master(api, source),
         {:ok, created} <- insert_copy(api, destination, master) do
      {:ok,
       %{
         uid: created["iCalUID"],
         id: created["id"],
         calendar_id: destination.calendar_id,
         source: delete_master(api, source)
       }}
    end
  end

  # A master Google still answers for, but as deleted, is not a series to
  # copy.
  defp read_master(api, source) do
    case reason(api.get_event(source.integration, source.calendar_id, source.master_id)) do
      {:ok, %{"status" => "cancelled"}} -> {:error, :not_found}
      other -> other
    end
  end

  defp insert_copy(api, destination, master) do
    body = CreatableEvent.from_event(master)
    reason(api.insert_event(destination.integration, destination.calendar_id, body))
  end

  defp delete_master(api, source) do
    case api.delete_event(source.integration, source.calendar_id, source.master_id) do
      :ok ->
        :removed

      error ->
        Logger.warning("Google series move: the original series could not be deleted",
          calendar_integration_id: source.integration.id,
          reason: LogFormat.reason(error_type(error))
        )

        :left_behind
    end
  end

  # The API answers with the type and Google's message; a writer answers
  # with the type alone.
  defp reason({:error, type, _message}), do: {:error, type}
  defp reason(answer), do: answer

  defp error_type({:error, type, _message}), do: type
  defp error_type({:error, type}), do: type
  defp error_type(other), do: other

  defp api, do: Config.google_calendar_api_module()
end
