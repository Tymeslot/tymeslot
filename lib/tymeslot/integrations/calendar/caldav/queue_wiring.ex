defmodule Tymeslot.Integrations.Calendar.CalDAV.QueueWiring do
  @moduledoc """
  Tags `provider_calendar_events` cache rows with a `sync_state` value so
  `OfflineQueue.flush/2` can replay a failed write on the next sync cycle.

  Sits between the domain (`CalendarEventWorker`, booking flows) and the
  cache table. Callers describe _what_ they tried to do — create, update,
  delete a meeting — and this module writes the correct queue marker
  provided the target integration is a CalDAV-family provider.

  Non-CalDAV providers (Google, Outlook) are silently no-op'd: they have
  their own retry surface and no offline queue reads from this table.

  ## Idempotency

  `tag/3` and `clear/2` are idempotent. Calling `tag/3` twice results in
  one cache row with the most recent `sync_state`. Calling `clear/2`
  when the row is already `synced` (or absent) is a no-op. This lets the
  worker call `clear/2` unconditionally on success without checking
  prior state.

  ## Semantics of each action

    * `:create` → `sync_state: "locally_created"`; row carries the full
                  `event_data` so `OfflineQueue` can reconstruct the PUT.
    * `:update` → `sync_state: "locally_modified"`; same payload.
    * `:delete` → `sync_state: "locally_deleted"`; minimum fields only —
                  a DELETE only needs the uid and the cached href.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.QueueQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver
  alias Tymeslot.Integrations.CalendarManagement

  @type action :: :create | :update | :delete
  @type meeting :: %{
          :uid => String.t(),
          :calendar_integration_id => integer(),
          optional(atom()) => term()
        }

  @doc """
  Tags a cache row for offline retry.

  `event_data` is the map produced by
  `Tymeslot.Integrations.Calendar.CalendarEventBuilder.build_event_data/1`
  and carries the fields `OfflineQueue` will need to reconstruct the
  CalDAV write: `summary`, `start_time`, `end_time`, `location`, `timezone`.

  Returns `:ok` on success, or `:ignored` when the meeting's integration
  is not a CalDAV-family provider. Never raises.
  """
  @spec tag(meeting(), action(), map()) :: :ok | :ignored
  def tag(%{calendar_integration_id: nil}, _action, _event_data), do: :ignored

  def tag(%{calendar_integration_id: integration_id} = meeting, action, event_data) do
    with {:ok, integration} <- fetch_integration(integration_id),
         true <- caldav_provider?(integration),
         [_head | _tail] <- integration.calendar_paths do
      attrs = build_attrs(meeting, integration, action, event_data)
      _result = QueueQueries.upsert_queue_entry(attrs)

      Logger.info("CalDAV queue wiring tagged cache row for offline retry",
        calendar_integration_id: integration_id,
        uid: meeting.uid,
        action: action
      )

      :ok
    else
      _not_caldav -> :ignored
    end
  end

  @doc """
  Clears a previously-tagged cache row back to `"synced"`.

  Called from the worker's success path so a row tagged on a transient
  failure earlier in the same Oban run is untagged once the retry
  succeeds. Matches on `(integration_id, uid)` and updates only if the
  row exists — a missing row is a no-op.

  Returns `:ok` regardless of outcome.
  """
  @spec clear(meeting(), String.t() | nil) :: :ok
  def clear(%{calendar_integration_id: nil}, _etag), do: :ok

  def clear(%{calendar_integration_id: integration_id, uid: uid}, etag) do
    _result = QueueQueries.mark_synced(integration_id, uid, etag)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_integration(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
        {:error, :requires_reencryption}
    end
  end

  defp caldav_provider?(%{provider: provider}) when is_binary(provider) do
    provider in ProviderConfig.caldav_based_provider_strings()
  end

  # The columns a local change may describe. Everything else on the cache row —
  # notably `organiser`, `attachments`, `links` and `provider_metadata` — is
  # server-sourced, so the queue neither writes it nor, now, erases it.
  @content_fields ~w(summary description location timezone visibility colour
                     attendees reminders recurrence_rule recurrence_exceptions
                     provider_event_id etag raw_ical)a

  # The attrs are the write: `QueueQueries.upsert_queue_entry/1` replaces
  # exactly the columns present here and leaves every other one on the existing
  # row untouched. So a field is supplied only when the local change actually
  # carried one. A queued delete, whose callers pass `%{}`, therefore writes
  # nothing but the queue marker, where it used to null the `etag`,
  # `provider_event_id` and `raw_ical` the replay needs to address the event.
  #
  # The retry bookkeeping is reset deliberately: a new tag is a new intent, and
  # the attempt count and last error belong to the intent it replaces.
  defp build_attrs(meeting, integration, action, event_data) do
    now = DateTime.utc_now(:microsecond)
    event_data = normalize_event_data(event_data)

    %{
      uid: meeting.uid,
      calendar_integration_id: integration.id,
      provider: integration.provider,
      # Only meaningful on a first insert, since the upsert never replaces it.
      # The booking collection is where `ClientManager.booking_client/1` wrote
      # the event this tag is retrying, so it is the collection the row belongs
      # in; the integration's first configured path is not the same thing
      # whenever the booking calendar is not the first one.
      provider_calendar_id: CalendarPathResolver.resolve(integration),
      synced_at: now,
      sync_state: sync_state_for(action),
      sync_attempts: 0,
      sync_last_attempt_at: now,
      sync_last_error: nil,
      created_by_tymeslot: true
    }
    |> Map.merge(content_attrs(event_data))
    |> Map.merge(timing_attrs(event_data))
  end

  # Carried straight through when present. `status` and `transparency` are
  # converted rather than copied, and are dropped when nil because both columns
  # are NOT NULL with a database default — on a fresh insert the default is the
  # right answer, and on an existing row the stored value is.
  defp content_attrs(event_data) do
    @content_fields
    |> Enum.filter(&Map.has_key?(event_data, &1))
    |> Map.new(&{&1, event_data[&1]})
    |> put_converted(event_data, :status, &status_string/1)
    |> put_converted(event_data, :transparency, &transparency_string/1)
  end

  defp put_converted(attrs, event_data, key, converter) do
    case Map.get(event_data, key) do
      nil -> attrs
      value -> Map.put(attrs, key, converter.(value))
    end
  end

  # Timing is written as a set or not at all: `all_day` decides which pair of
  # columns means anything, so the four move together or a row ends up all-day
  # with a `start_at` or timed with a `start_date`.
  #
  # All three shapes the callers actually pass are accepted. `Date`s arrive
  # from an all-day edit and ISO-8601 strings from a payload that has been
  # through JSON; both used to fall through to "no timing at all", which left
  # the row permanently unsendable because `OfflineQueue.sendable_event_data/1`
  # refuses a row with no start or end. An unrecognised shape now writes no
  # timing rather than nulling what the row already holds.
  defp timing_attrs(event_data) do
    case {parse_time(event_data[:start_time]), parse_time(event_data[:end_time])} do
      {{:ok, %Date{} = start_date}, end_time} ->
        %{
          all_day: true,
          start_date: start_date,
          end_date: as_date(end_time),
          start_at: nil,
          end_at: nil
        }

      {{:ok, %DateTime{} = start_at}, end_time} ->
        %{
          all_day: false,
          start_at: ensure_usec(start_at),
          end_at: as_datetime(end_time),
          start_date: nil,
          end_date: nil
        }

      _no_usable_start ->
        %{}
    end
  end

  defp as_date({:ok, %Date{} = date}), do: date
  defp as_date({:ok, %DateTime{} = datetime}), do: DateTime.to_date(datetime)
  defp as_date(:error), do: nil

  defp as_datetime({:ok, %DateTime{} = datetime}), do: ensure_usec(datetime)
  defp as_datetime(_other), do: nil

  defp parse_time(%DateTime{} = datetime), do: {:ok, datetime}
  defp parse_time(%Date{} = date), do: {:ok, date}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> parse_iso_date(value)
    end
  end

  defp parse_time(_other), do: :error

  defp parse_iso_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp sync_state_for(:create), do: "locally_created"
  defp sync_state_for(:update), do: "locally_modified"
  defp sync_state_for(:delete), do: "locally_deleted"

  # `event_data[:status]` carries the held-request marker
  # (`CalendarEventBuilder.build_event_data/1` sets `:tentative` for a
  # meeting still awaiting approval). Losing it here is what let a replayed
  # offline-queue write land as an ordinary confirmed event on the host's
  # calendar for a request nobody had approved yet.
  defp status_string(nil), do: "confirmed"
  defp status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_string(status) when is_binary(status), do: status

  defp transparency_string(nil), do: "opaque"

  defp transparency_string(transparency) when is_atom(transparency),
    do: Atom.to_string(transparency)

  defp transparency_string(transparency) when is_binary(transparency), do: transparency

  # `event_data` is documented as the atom-keyed map `CalendarEventBuilder`
  # produces, but it can also arrive from a payload that has been through JSON
  # and so carries string keys. Answer the question once, here, rather than at
  # every read below.
  #
  # Only the key is moved, never invented: `Map.has_key?/2` is what decides
  # whether a column is written at all, so putting a nil under an absent atom
  # key would turn every omission back into a blanking write.
  @event_data_keys @content_fields ++ ~w(status transparency start_time end_time)a

  defp normalize_event_data(event_data) when is_map(event_data) do
    Enum.reduce(@event_data_keys, event_data, fn key, acc ->
      with false <- Map.has_key?(acc, key),
           {:ok, value} <- Map.fetch(acc, Atom.to_string(key)) do
        Map.put(acc, key, value)
      else
        _already_atom_keyed_or_absent -> acc
      end
    end)
  end

  defp ensure_usec(%DateTime{microsecond: {_us, 6}} = dt), do: dt

  defp ensure_usec(%DateTime{} = dt) do
    {us, _precision} = dt.microsecond
    %{dt | microsecond: {us, 6}}
  end
end
