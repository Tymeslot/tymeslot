defmodule Tymeslot.Integrations.Calendar.SeriesRuleQueries do
  @moduledoc """
  Data access for `calendar_series_rules`: the repeat rule of each Google or
  Outlook series an integration's cache holds occurrences of.
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SeriesRuleSchema
  alias Tymeslot.Repo

  @doc "The stored rows for `master_ids`, by master id, in one query."
  @spec list_by_master(integer(), [String.t()]) :: %{String.t() => SeriesRuleSchema.t()}
  def list_by_master(_integration_id, []), do: %{}

  def list_by_master(integration_id, master_ids) do
    SeriesRuleSchema
    |> where([r], r.calendar_integration_id == ^integration_id)
    |> where([r], r.provider_master_id in ^master_ids)
    |> Repo.all()
    |> Map.new(&{&1.provider_master_id, &1})
  end

  @doc """
  Up to `limit` masters the integration's cache holds occurrences of whose
  rule was never read, or last read before `stale_before`, leaving out
  `except`, each with the calendar an occurrence of it is in.
  """
  @spec masters_to_refresh(integer(), DateTime.t(), [String.t()], non_neg_integer()) ::
          [{String.t(), String.t() | nil}]
  def masters_to_refresh(_integration_id, _stale_before, _except, 0), do: []

  def masters_to_refresh(integration_id, stale_before, except, limit) do
    query =
      from(e in ProviderCalendarEventSchema,
        left_join: r in SeriesRuleSchema,
        on:
          r.calendar_integration_id == e.calendar_integration_id and
            r.provider_master_id == e.recurring_event_id,
        where: e.calendar_integration_id == ^integration_id,
        where: not is_nil(e.recurring_event_id) and e.recurring_event_id not in ^except,
        where: is_nil(r.id) or r.fetched_at < ^stale_before,
        distinct: e.recurring_event_id,
        order_by: e.recurring_event_id,
        select: {e.recurring_event_id, e.provider_calendar_id},
        limit: ^limit
      )

    Repo.all(query)
  end

  @doc """
  Records what a read of the master `master_id` found, replacing what was
  stored for it.
  """
  @spec put(integer(), String.t(), %{
          rule: String.t() | nil,
          master_start: DateTime.t() | nil,
          fetched_at: DateTime.t()
        }) ::
          {:ok, SeriesRuleSchema.t()} | {:error, Ecto.Changeset.t()}
  def put(integration_id, master_id, attrs) do
    %SeriesRuleSchema{}
    |> SeriesRuleSchema.changeset(
      Map.merge(attrs, %{calendar_integration_id: integration_id, provider_master_id: master_id})
    )
    |> Repo.insert(
      on_conflict: {:replace, [:rule, :master_start, :fetched_at, :updated_at]},
      conflict_target: [:calendar_integration_id, :provider_master_id]
    )
  end

  @doc """
  Forgets every series of the integration the cache no longer holds an
  occurrence of. Answers how many were forgotten.
  """
  @spec delete_orphans(integer()) :: non_neg_integer()
  def delete_orphans(integration_id) do
    query =
      from(r in SeriesRuleSchema,
        as: :rule,
        where: r.calendar_integration_id == ^integration_id and not exists(occurrences())
      )

    {count, _rows} = Repo.delete_all(query)

    count
  end

  @doc """
  `delete_orphans/1` for every integration at once, after a prune of the
  cache that spans them all.
  """
  @spec delete_all_orphans() :: non_neg_integer()
  def delete_all_orphans do
    {count, _rows} =
      Repo.delete_all(from(r in SeriesRuleSchema, as: :rule, where: not exists(occurrences())))

    count
  end

  # The cached occurrences of the series the `:rule` row stands for.
  defp occurrences do
    from(e in ProviderCalendarEventSchema,
      where:
        e.calendar_integration_id == parent_as(:rule).calendar_integration_id and
          e.recurring_event_id == parent_as(:rule).provider_master_id,
      select: 1
    )
  end
end
