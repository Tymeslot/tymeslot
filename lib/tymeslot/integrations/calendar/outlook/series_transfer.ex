defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesTransfer do
  @moduledoc """
  Moving a whole Outlook recurring series, addressed by its master's id, to
  another calendar: of the same Microsoft account, or of another one.
  Reached through `Tymeslot.Integrations.Calendar.Events.move_outlook_series/3`,
  which loads both integrations as the user's.

  Graph has no move for events, so the series is always copied: the master
  is read on the source, with its body as stored (an HTML description stays
  HTML), created in the destination calendar as
  `Outlook.CreatableEvent` makes it creatable, with the master's own
  `recurrence` (its pattern and range as they are) and its timing on the
  series' own wall clock, labelled with the zone the series was created in,
  and only once the destination has accepted it is the master deleted on
  the source. The copy is always created in a named calendar
  (`POST /me/calendars/{id}/events`): a destination the grid knows only as
  `"primary"` is the account's default calendar, whose id Graph is asked
  for, since Graph has no calendar by that name.

  What the copy does not carry:

    * The online meeting. Creating an event with one asks Teams for a new
      meeting, so the copy has no Teams meeting; the join details in the
      body still lead to the original one.
    * Occurrences edited or cancelled on their own. They are not in the
      master's `recurrence`, so on the destination every occurrence the
      pattern makes is plain again.

  Attendees are copied as `Outlook.SeriesSplit` copies them to a tail, so
  Graph invites them to the copy; deleting the original master cancels it
  for them. Neither can be suppressed beyond the header every write here
  sends.

  A move to the calendar the series is already on is refused with
  `:same_calendar` before anything is written. The cache records most
  Outlook rows as on `"primary"`, whichever calendar holds them, so the
  cached calendar only settles it when it names a real one: within one
  integration, the calendar Graph says holds the master is compared with
  the destination once both are known, and only reads have been sent by
  then.

  Every request goes out on its own integration's API client and with its
  own access token, refreshed as every Outlook call refreshes it.

  Answers `{:ok, moved}` (`t:moved/0`) once the destination holds the
  series, or `{:error, reason}` with nothing written. A delete that fails
  once the copy exists is not an error: the answer says
  `source: :left_behind`, the copy stays, and nothing is queued.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.CreatableEvent
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesPatch

  require Logger

  @typedoc """
  The series a move takes: its master, cached as on `calendar_id` of an
  integration.
  """
  @type source :: %{
          integration: CalendarIntegrationSchema.t(),
          calendar_id: String.t(),
          master_id: String.t()
        }

  @typedoc "The calendar a series moves to, of an integration."
  @type destination :: %{integration: CalendarIntegrationSchema.t(), calendar_id: String.t()}

  @typedoc """
  Where a moved series now lives: its master's `iCalUId` and id, and the id
  of the calendar that holds it.
  """
  @type moved :: %{
          uid: String.t(),
          id: String.t(),
          calendar_id: String.t(),
          source: :removed | :left_behind
        }

  # The placeholder for a calendar the grid cannot name.
  @unnamed "primary"

  @doc """
  Moves the series `source` names to `destination` (see the moduledoc).
  """
  @spec move(source(), destination()) :: {:ok, moved()} | {:error, term()}
  def move(
        %{integration: %{id: id}, calendar_id: calendar_id},
        %{integration: %{id: id}, calendar_id: calendar_id}
      )
      when calendar_id != @unnamed,
      do: {:error, :same_calendar}

  def move(source, destination) do
    api = api()

    with {:ok, master} <- read_master(api, source),
         {:ok, body} <- copy_body(master),
         {:ok, calendar_id} <- destination_calendar(api, destination),
         :ok <- ensure_other_calendar(api, source, destination, calendar_id),
         {:ok, created} <- reason(api.insert_event(destination.integration, calendar_id, body)) do
      {:ok,
       %{
         uid: created["iCalUId"],
         id: created["id"],
         calendar_id: calendar_id,
         source: delete_master(api, source)
       }}
    end
  end

  # A master Graph still answers for, but as cancelled, is not a series to
  # copy.
  defp read_master(api, source) do
    case reason(api.get_event(source.integration, source.master_id, body: :stored)) do
      {:ok, %{"isCancelled" => true}} -> {:error, :not_found}
      other -> other
    end
  end

  # The master's timing is read on the series' own wall clock and written
  # back labelled with its zone, so the pattern's weekdays and the range's
  # dates keep meaning what they meant. A timed series whose zone cannot be
  # read has no wall clock to copy, and is refused.
  defp copy_body(%{"recurrence" => %{"pattern" => %{}, "range" => %{}} = recurrence} = master) do
    case SeriesPatch.master_timing(master) do
      {:ok, {%NaiveDateTime{}, _finish}, {nil, _label}} ->
        {:error, :unreadable_timing}

      {:ok, timing, {_zone, label}} ->
        {:ok,
         master
         |> CreatableEvent.from_event()
         |> CreatableEvent.put_timing(timing, label)
         |> Map.put("recurrence", recurrence)}

      error ->
        error
    end
  end

  defp copy_body(_master), do: {:error, :not_recurring}

  defp destination_calendar(api, %{integration: integration, calendar_id: @unnamed}) do
    with {:ok, calendars} <- reason(api.list_calendars(integration)) do
      case Enum.find(calendars, &(&1["isDefaultCalendar"] == true)) do
        %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
        _none -> {:error, :no_destination_calendar}
      end
    end
  end

  defp destination_calendar(_api, %{calendar_id: calendar_id}), do: {:ok, calendar_id}

  # Only the same account can hold the series in the destination calendar.
  defp ensure_other_calendar(
         api,
         %{integration: %{id: id}} = source,
         %{integration: %{id: id}},
         calendar_id
       ) do
    case reason(api.get_event_calendar_id(source.integration, source.master_id)) do
      {:ok, ^calendar_id} -> {:error, :same_calendar}
      {:ok, _other} -> :ok
      error -> error
    end
  end

  defp ensure_other_calendar(_api, _source, _destination, _calendar_id), do: :ok

  defp delete_master(api, source) do
    case api.delete_event(source.integration, source.master_id) do
      :ok ->
        :removed

      error ->
        Logger.warning("Outlook series move: the original series could not be deleted",
          calendar_integration_id: source.integration.id,
          reason: inspect(error_type(error))
        )

        :left_behind
    end
  end

  # The API answers with the type and Graph's message; a writer answers
  # with the type alone.
  defp reason({:error, type, _message}), do: {:error, type}
  defp reason(answer), do: answer

  defp error_type({:error, type, _message}), do: type
  defp error_type({:error, type}), do: type
  defp error_type(other), do: other

  defp api, do: Config.outlook_calendar_api_module()
end
