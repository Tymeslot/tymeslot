defmodule Tymeslot.Integrations.Calendar.ProviderCalendarSeriesQueries do
  @moduledoc """
  Database queries over every cached row of one recurring series.

  A series is addressed as its provider addresses it: a Google or Outlook
  series by its master's id (`{:master, id}`), which its occurrences name in
  `recurring_event_id` and the master's own row, when cached, carries as its
  `provider_event_id`; a CalDAV series by the href of the resource holding it
  (`{:resource, href}`), which every row of it carries as its
  `provider_event_id`. The per-row queries stay in
  `ProviderCalendarEventQueries`.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  @typedoc "How a provider addresses a whole series."
  @type address :: {:master, String.t()} | {:resource, String.t()}

  @doc """
  Every cached row of the series at `address` in the integration
  `calendar_integration_id`: a master's occurrences and its own row, or every
  row of a CalDAV resource.
  """
  @spec list_rows(integer(), address()) :: [ProviderCalendarEventSchema.t()]
  def list_rows(calendar_integration_id, {:master, master_id}) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.recurring_event_id == ^master_id or e.provider_event_id == ^master_id)
    |> Repo.all()
  end

  def list_rows(calendar_integration_id, {:resource, href}) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.provider_event_id == ^href)
    |> Repo.all()
  end

  @doc """
  The videos the rows cached for the masters `master_ids` themselves carry,
  in the integration `calendar_integration_id`: `{master_id,
  video_integration_id, video_link}` for each master row with both a video
  integration and a link.
  """
  @spec list_master_videos(integer(), [String.t()]) ::
          [{String.t(), pos_integer(), String.t()}]
  def list_master_videos(_calendar_integration_id, []), do: []

  def list_master_videos(calendar_integration_id, master_ids) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.provider_event_id in ^master_ids)
    |> where([e], is_nil(e.recurring_event_id) or e.recurring_event_id == "")
    |> where([e], not is_nil(e.video_integration_id) and e.video_link != "")
    |> select([e], {e.provider_event_id, e.video_integration_id, e.video_link})
    |> Repo.all()
  end

  @doc """
  Gives every cached occurrence of the series at `address` that has no video
  of its own the link `video_link` from the video integration
  `video_integration_id`.

  An occurrence is a row a sync cached for one slot of the series, not a row
  standing in for the whole of it: a Google or Outlook row naming the master,
  or a CalDAV row of the resource other than one cached under the series' own
  UID, `series_uid`. A row with a link, or with an integration and no link
  yet, keeps what it has.

  Returns `{:ok, count}`, or `:not_cached` when the cache holds no occurrence
  of the series at all. Nothing is written when the video integration no
  longer exists.
  """
  @spec put_video(integer(), address(), String.t() | nil, pos_integer(), String.t()) ::
          {:ok, non_neg_integer()} | :not_cached
  def put_video(calendar_integration_id, address, series_uid, video_integration_id, video_link) do
    occurrences = occurrences(calendar_integration_id, address, series_uid)

    if Repo.exists?(occurrences) do
      {count, _rows} =
        occurrences
        |> where([e], is_nil(e.video_link) and is_nil(e.video_integration_id))
        |> where(
          [_e],
          exists(from(v in VideoIntegrationSchema, where: v.id == ^video_integration_id))
        )
        |> Repo.update_all(
          set: [
            video_link: video_link,
            video_integration_id: video_integration_id,
            updated_at: DateTime.utc_now(:microsecond)
          ]
        )

      {:ok, count}
    else
      :not_cached
    end
  end

  defp occurrences(calendar_integration_id, {:master, master_id}, _series_uid) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.recurring_event_id == ^master_id)
  end

  defp occurrences(calendar_integration_id, {:resource, href}, series_uid) do
    query =
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> where([e], e.provider_event_id == ^href)

    if is_binary(series_uid), do: where(query, [e], e.uid != ^series_uid), else: query
  end
end
