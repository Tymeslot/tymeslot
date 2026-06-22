defmodule Tymeslot.Analytics.ReconciliationQueries do
  @moduledoc """
  Instance-wide read queries that cross-check booking analytics against
  bookings, for the reconciliation job.

  Unlike the per-organizer query modules, these aggregate across every
  organizer — the reconciliation job monitors the health of the whole
  installation, not one user's dashboard. The untracked-converting query
  deliberately spans both `analytics_events` and `meetings`: detecting
  bookings whose page-view was never recorded is inherently a cross-table
  question.

  All `Repo.*` calls for reconciliation live here per the
  `CredoChecks.RepoCallBoundary` rule.
  """
  import Ecto.Query

  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @typedoc """
  Aggregate counts for a window:

    * `visits` — total page-view events
    * `unique_visitors` — distinct visitor hashes among events
    * `converting_visitors` — distinct visitor hashes among bookings
    * `untracked_converting_visitors` — distinct booking visitor hashes with no
      matching page-view event (the direct tracking-loss measure)
  """
  @type totals :: %{
          visits: non_neg_integer(),
          unique_visitors: non_neg_integer(),
          converting_visitors: non_neg_integer(),
          untracked_converting_visitors: non_neg_integer()
        }

  @spec instance_totals(DateTime.t(), DateTime.t()) :: totals()
  def instance_totals(%DateTime{} = from, %DateTime{} = to) do
    %{
      visits: count_visits(from, to),
      unique_visitors: count_unique_visitors(from, to),
      converting_visitors: count_converting_visitors(from, to),
      untracked_converting_visitors: count_untracked_converting_visitors(from, to)
    }
  end

  @spec count_visits(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_visits(%DateTime{} = from, %DateTime{} = to) do
    EventSchema
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> select([e], count(e.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @spec count_unique_visitors(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_unique_visitors(%DateTime{} = from, %DateTime{} = to) do
    EventSchema
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> select([e], count(e.visitor_hash, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @spec count_converting_visitors(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_converting_visitors(%DateTime{} = from, %DateTime{} = to) do
    MeetingSchema
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.visitor_hash))
    |> select([m], count(m.visitor_hash, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end

  # Distinct booking visitor hashes in the window with no page-view event
  # sharing that hash in the same window — i.e. bookings we failed to track.
  @spec count_untracked_converting_visitors(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_untracked_converting_visitors(%DateTime{} = from, %DateTime{} = to) do
    matching_event =
      from(e in EventSchema,
        where:
          e.inserted_at >= ^from and e.inserted_at <= ^to and
            e.visitor_hash == parent_as(:meeting).visitor_hash
      )

    from(m in MeetingSchema, as: :meeting)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.visitor_hash))
    |> where([m], not exists(matching_event))
    |> select([m], count(m.visitor_hash, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end
end
