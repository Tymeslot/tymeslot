defmodule Tymeslot.Integrations.Calendar.ProviderCalendarResourceQueries do
  @moduledoc """
  Database queries over every cached row of one CalDAV resource.

  A CalDAV series is one resource on the server, and the sync caches one row
  per occurrence of it, all sharing the resource's href as their
  `provider_event_id` and its document as their `raw_ical`. A write to the
  resource therefore lands on every one of those rows at once. The per-row
  queries stay in `ProviderCalendarEventQueries`.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @doc """
  Records `document` as the resource at `href` now reads, on every cached row
  of it, and forgets their ETag: the write that produced the document came
  back without one, and a `nil` ETag sends the next write to the resource
  down the path that re-reads it first. Returns the number of rows updated.
  """
  @spec replace_document(integer(), String.t(), String.t()) :: non_neg_integer()
  def replace_document(calendar_integration_id, href, document)
      when is_binary(href) and is_binary(document) do
    {count, _rows} =
      ProviderCalendarEventSchema
      |> where(
        [e],
        e.calendar_integration_id == ^calendar_integration_id and e.provider_event_id == ^href
      )
      |> Repo.update_all(set: [raw_ical: document, etag: nil, updated_at: DateTime.utc_now()])

    count
  end
end
