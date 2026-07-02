defmodule Tymeslot.Workers.ColourWriteBackWorker do
  @moduledoc """
  Best-effort push of a per-event colour to the host calendar, reusing the
  existing event-update path (Google `colorId` / CalDAV `COLOR`). The event's
  full current timing and summary are always sent, so the provider write is a
  valid update that never wipes fields.

  Outlook has no per-event colour concept, so those jobs are discarded. Read-only
  calendars and transient failures surface as errors and are retried by Oban; the
  durable override remains the display source regardless of write-back outcome.
  Only *set* enqueues a job — clearing a colour leaves the host untouched.
  """
  use Oban.Worker, queue: :calendar_events, max_attempts: 3, priority: 2

  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "integration_id" => integration_id,
      "uid" => uid,
      "user_id" => user_id,
      "colour" => colour
    } = args

    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, event} -> write_back(event, integration_id, user_id, colour)
      {:error, :not_found} -> {:discard, :event_not_cached}
    end
  end

  # Microsoft Graph exposes no per-event colour, so there is nothing to push.
  defp write_back(%{provider: "outlook"}, _integration_id, _user_id, _colour),
    do: {:discard, :provider_has_no_event_colour}

  defp write_back(event, integration_id, user_id, colour) do
    event_data = Map.put(base_event_data(event), :colour, colour)

    case CalendarEvents.update_event(event.uid, event_data, {integration_id, user_id}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The full current event payload (timing + core fields), so the provider write
  # is a complete, valid update — mirrors the grid's colour-update path.
  defp base_event_data(%{all_day: true} = event) do
    %{
      summary: event.summary || "",
      start_time: event.start_date,
      end_time: event.end_date,
      all_day: true,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id
    }
  end

  defp base_event_data(event) do
    %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      all_day: false,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id
    }
  end
end
