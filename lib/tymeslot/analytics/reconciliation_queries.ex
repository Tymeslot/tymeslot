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

  ## Salt-awareness and the untracked ratio

  `Fingerprint` rotates the visitor hash salt every UTC day for visitor
  privacy. This means the same visitor hashes to a different value on
  different UTC days, so a page-view on day N and a booking on day N+1 will
  never share a hash. Comparing them across days would systematically
  over-count "untracked" bookings.

  `count_untracked_converting_visitors/2` therefore only flags a booking as
  untracked when there is no page-view event whose hash matches **and** whose
  `inserted_at` falls on the **same UTC calendar day** as the booking. Within
  a single UTC day the salt is constant, so the match is reliable.

  Residual limitation: bookings where the visitor genuinely browsed on a prior
  UTC day and booked the next day (or later) cannot be hash-verified given the
  daily salt. Such bookings are excluded from the untracked numerator when no
  other events were recorded on the booking day (the `any_same_day_event`
  guard); on busy days where other events do exist they may still be counted as
  untracked — an acceptable false positive that is documented and bounded. The
  ratio therefore measures **same-day tracking loss** rather than lifetime
  tracking loss.
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
      matching same-day page-view event (same-day tracking-loss measure; see
      moduledoc for the daily-salt constraint)
  """
  @type totals :: %{
          visits: non_neg_integer(),
          unique_visitors: non_neg_integer(),
          converting_visitors: non_neg_integer(),
          untracked_converting_visitors: non_neg_integer()
        }

  @spec instance_totals(DateTime.t(), DateTime.t()) :: totals()
  def instance_totals(%DateTime{} = from, %DateTime{} = to) do
    # All four counts run inside a single transaction so they share a DB
    # connection and a consistent view of committed data. Under READ COMMITTED
    # (PostgreSQL default) each statement sees data committed before that
    # statement starts, so a concurrent insert between two of the four calls
    # could transiently make the invariants look violated. This is an
    # acceptable risk for a monitoring job — the window is microseconds, and a
    # false alert self-corrects on the next run. REPEATABLE READ would close
    # this gap entirely but `SET TRANSACTION ISOLATION LEVEL` must be issued
    # before any query in a transaction, which conflicts with the Ecto sandbox
    # used in tests (the sandbox opens the transaction before application code
    # runs). A single-CTE implementation would give the same guarantee without
    # that constraint — worthwhile if spurious alerts become a real problem.
    {:ok, totals} =
      Repo.transaction(fn ->
        %{
          visits: count_visits(from, to),
          unique_visitors: count_unique_visitors(from, to),
          converting_visitors: count_converting_visitors(from, to),
          untracked_converting_visitors: count_untracked_converting_visitors(from, to)
        }
      end)

    totals
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

  # Distinct booking visitor hashes in the window with no matching same-day
  # page-view event.
  #
  # "Same-day" means the event's `inserted_at` shares the same UTC calendar date
  # as the booking — on a given day the daily salt is constant, so hashes are
  # comparable. Cross-day hashes are not comparable (different salt → different
  # value for the same visitor), so cross-day matching is excluded.
  #
  # A booking is only included in the untracked numerator when tracking was
  # provably active on the booking day: the outer query requires at least one
  # event (`any_same_day_event`) to exist on that calendar day. This excludes
  # bookings made on days with no events at all, which are unverifiable (the
  # visitor may well have browsed the previous day and booked today — we simply
  # cannot confirm it either way; see moduledoc).
  @spec count_untracked_converting_visitors(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_untracked_converting_visitors(%DateTime{} = from, %DateTime{} = to) do
    matching_event =
      from(e in EventSchema,
        where:
          fragment("DATE(?)", e.inserted_at) ==
            fragment("DATE(?)", parent_as(:meeting).inserted_at) and
            e.visitor_hash == parent_as(:meeting).visitor_hash
      )

    any_same_day_event =
      from(e in EventSchema,
        where:
          fragment("DATE(?)", e.inserted_at) ==
            fragment("DATE(?)", parent_as(:meeting).inserted_at)
      )

    from(m in MeetingSchema, as: :meeting)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.visitor_hash))
    |> where([m], exists(any_same_day_event))
    |> where([m], not exists(matching_event))
    |> select([m], count(m.visitor_hash, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end
end
