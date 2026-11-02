defmodule Tymeslot.Meetings.AttendeeNotifications.SeriesEntryQueries do
  @moduledoc """
  Data access for `attendee_series_entries`: the entries attendee emails put
  in guests' calendars for each recurring series.
  """
  import Ecto.Query

  alias Tymeslot.Meetings.AttendeeNotifications.SeriesEntrySchema
  alias Tymeslot.Repo

  @doc "Every entry recorded for the series `address` of the integration."
  @spec list(integer(), String.t()) :: [SeriesEntrySchema.t()]
  def list(integration_id, address) do
    integration_id
    |> series(address)
    |> order_by([e], asc: e.id)
    |> Repo.all()
  end

  @doc """
  Records the entries in `attrs` for the series `address` of the
  integration, each replacing what was recorded for its UID.
  """
  @spec put_all(integer(), String.t(), [map()]) :: :ok
  def put_all(_integration_id, _address, []), do: :ok

  def put_all(integration_id, address, attrs) do
    Repo.transaction(fn ->
      Enum.each(attrs, fn entry ->
        %SeriesEntrySchema{}
        |> SeriesEntrySchema.changeset(
          Map.merge(entry, %{calendar_integration_id: integration_id, series_address: address})
        )
        |> Repo.insert!(
          on_conflict: {:replace, [:updated_at | SeriesEntrySchema.replaced_fields()]},
          conflict_target: [:calendar_integration_id, :series_address, :entry_uid]
        )
      end)
    end)

    :ok
  end

  @doc "Forgets the entry `uid` of the series `address`."
  @spec delete(integer(), String.t(), String.t()) :: :ok
  def delete(integration_id, address, uid) do
    integration_id
    |> series(address)
    |> where([e], e.entry_uid == ^uid)
    |> Repo.delete_all()

    :ok
  end

  @doc "Forgets every entry of the series `address`."
  @spec delete_all(integer(), String.t()) :: :ok
  def delete_all(integration_id, address) do
    integration_id
    |> series(address)
    |> Repo.delete_all()

    :ok
  end

  defp series(integration_id, address) do
    from(e in SeriesEntrySchema,
      where: e.calendar_integration_id == ^integration_id and e.series_address == ^address
    )
  end
end
