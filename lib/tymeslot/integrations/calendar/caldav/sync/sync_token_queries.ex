defmodule Tymeslot.Integrations.Calendar.CalDAV.Sync.SyncTokenQueries do
  @moduledoc """
  Writes to the `caldav_sync_tokens` column of `calendar_integrations`: the
  per-path CalDAV sync tokens a sync run reads and records.
  """

  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  @doc """
  Forgets every calendar path's CalDAV sync token, so the next sync of each
  starts from a full fetch.
  """
  @spec clear_caldav_sync_tokens(CalendarIntegrationSchema.t()) :: :ok
  def clear_caldav_sync_tokens(%CalendarIntegrationSchema{id: id}) do
    query =
      from(ci in CalendarIntegrationSchema,
        where: ci.id == ^id,
        update: [set: [caldav_sync_tokens: fragment("'{}'::jsonb")]]
      )

    Repo.update_all(query, [])

    :ok
  end

  @doc """
  Records one calendar path's CalDAV sync token, or forgets it when `token` is
  `nil`.

  A single atomic jsonb edit rather than a changeset over the whole map: a sync
  run writes a token per path from the integration struct it loaded at the
  start, so replacing the map would drop every token another path wrote
  earlier in the same run.
  """
  @spec put_caldav_sync_token(CalendarIntegrationSchema.t(), String.t(), String.t() | nil) ::
          :ok
  def put_caldav_sync_token(%CalendarIntegrationSchema{id: id}, path, nil) do
    query =
      from(ci in CalendarIntegrationSchema,
        where: ci.id == ^id,
        update: [set: [caldav_sync_tokens: fragment("? - ?::text", ci.caldav_sync_tokens, ^path)]]
      )

    Repo.update_all(query, [])

    :ok
  end

  def put_caldav_sync_token(%CalendarIntegrationSchema{id: id}, path, token)
      when is_binary(token) do
    query =
      from(ci in CalendarIntegrationSchema,
        where: ci.id == ^id,
        update: [
          set: [
            caldav_sync_tokens:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)",
                ci.caldav_sync_tokens,
                ^path,
                ^token
              )
          ]
        ]
      )

    Repo.update_all(query, [])

    :ok
  end
end
