defmodule Tymeslot.Integrations.Calendar.SyncLink.MoveCorrection do
  @moduledoc """
  Builds the two iCalendar lines that put a moved occurrence's busy block where
  the meeting actually is.

  ## What is being corrected

  A mirrored series is one recurring placeholder built from the master's rule.
  Moving a single occurrence does not touch that rule — Google leaves the RRULE
  alone, adds no EXDATE, and records the move on a separate exception instance —
  so the placeholder goes on expanding the occurrence at the time it left, and
  nothing at all covers the time it went to. `SyncLink.MovedOccurrence` reports
  that state; this is what repairs it.

  ## Why a pair, and never one half — for a move

  `EXDATE` at the original instant frees the slot the occurrence left. `RDATE`
  at the new instant blocks the slot it went to. Emitting only the first was
  considered and rejected before this module existed, and the reasoning holds:
  it removes the falsely-busy slot while leaving the genuinely-busy one
  bookable, which *widens* the double-booking window rather than closing it. So
  a move that cannot produce both lines produces neither.

  ## Why a cancellation is the one correction that is a single line

  A cancelled occurrence is expressed here as a `new_start` of `nil`, and it
  renders an `EXDATE` with no `RDATE`. That is not the rejected half-correction
  above: the rule that makes a lone EXDATE dangerous is that the meeting is
  still happening *somewhere*, so freeing its old slot without blocking its new
  one leaves a real meeting bookable over. A cancellation has no new slot. The
  meeting is not happening at all, and an `RDATE` beside the `EXDATE` would
  re-block the very time the organiser has just cleared — turning the fix into
  a no-op that still reports success.

  So the distinction the two carry is `new_start`: an instant means *moved
  there*, `nil` means *gone*. Keeping them in one renderer rather than two
  means the "these occurrences are no longer at their scheduled time" statement
  is made once, and a series carrying both kinds at once — which the live
  calendar this was measured on does — is one list rather than two that have to
  be merged in the right order by every caller.

  ## Why this is not the expensive correction that was deferred

  The two approaches costed earlier both bought instance-level fidelity with
  provider traffic: listing a series' instances on every sync, or writing a
  separate placeholder event per moved occurrence. This buys the same outcome
  with two extra strings on a placeholder the engine already rewrites — no
  extra request, no second mirror row, still one placeholder per series.

  Confirmed against the live API before it was written: Google accepts both
  lines in an event's `recurrence` array and expands them, dropping the
  EXDATE'd occurrence and adding the RDATE'd one to the instance list that
  availability reads.

  ## Why these lines are safe where forwarded ones are not

  `SyncLink.RecurringSeries` forwards the master's `EXDATE` lines and refuses
  its `RDATE` and `EXRULE` lines, because forwarding them unexamined would let
  the placeholder describe a series the source does not have. That rule is
  unchanged and still right. These lines are not forwarded from anywhere: they
  are constructed from a move Tymeslot detected, naming instants it computed.
  Examined, not passed through.

  ## The parameters carry the meaning

  A timed occurrence is rendered in the series' own zone under `TZID`, because
  the instant the organiser sees is the one the block has to sit at; a UTC wall
  clock under a zone label names a different time. An all-day occurrence is
  rendered `VALUE=DATE`, because a date is not a time and a provider handed a
  date-time for an all-day series writes the wrong kind of block.
  """

  @typedoc """
  One correction, as `SyncLink.MovedOccurrence` describes it.

  `new_start` is where the occurrence went, or `nil` when it was cancelled and
  went nowhere. That single field is what separates the two, and it is why both
  travel as one list.
  """
  @type move :: %{
          original_start: DateTime.t() | Date.t(),
          new_start: DateTime.t() | Date.t() | nil
        }

  @doc """
  `series_opts` with the corrections appended to whatever exception lines the
  master already supplied.

  Gated on a recurrence rule having been resolved, not merely on the series
  having resolved at all: `RecurringSeries.resolve/2` answers `{:ok, []}` for a
  source that is not recurring, and a pair added there would hand the provider
  an `EXDATE`/`RDATE` with no `RRULE` to except against — a single event
  describing a recurrence it does not have.

  Appended rather than replacing, because a series can carry a cancelled
  occurrence and a moved one at once, and writing the second over the first
  would silently un-cancel it.
  """
  @spec apply_to(keyword(), map(), [move()]) :: keyword()
  def apply_to(series_opts, source_event, moves)

  def apply_to(series_opts, _source_event, []), do: series_opts

  def apply_to(series_opts, source_event, moves) when is_list(moves) do
    if is_binary(Keyword.get(series_opts, :recurrence_rule)) do
      lines = lines_for(moves, Map.get(source_event, :timezone))
      Keyword.update(series_opts, :exceptions, lines, &((&1 || []) ++ lines))
    else
      series_opts
    end
  end

  @doc """
  The `EXDATE`/`RDATE` pair for each move, in the order given — or a lone
  `EXDATE` for a cancellation, whose `new_start` is `nil`.

  A move whose two halves disagree in kind — a date against a date-time — is
  skipped rather than guessed at: there is no rendering that makes them a
  matching pair, and half a correction is worse than none. A `nil` `new_start`
  is not such a disagreement; it is the cancellation case, and is rendered.

  `timezone` is the series' own. `nil` falls back to UTC rather than emitting a
  bare instant, which a provider is entitled to read in its own default zone.
  """
  @spec lines_for([move()], String.t() | nil) :: [String.t()]
  def lines_for(moves, timezone) when is_list(moves) do
    zone = timezone || "Etc/UTC"

    Enum.flat_map(moves, fn move ->
      case {point(move, :original_start), point(move, :new_start)} do
        {%DateTime{} = original, %DateTime{} = new} ->
          [
            "EXDATE;TZID=#{zone}:#{timed(original, zone)}",
            "RDATE;TZID=#{zone}:#{timed(new, zone)}"
          ]

        {%Date{} = original, %Date{} = new} ->
          ["EXDATE;VALUE=DATE:#{date(original)}", "RDATE;VALUE=DATE:#{date(new)}"]

        {%DateTime{} = original, nil} ->
          ["EXDATE;TZID=#{zone}:#{timed(original, zone)}"]

        {%Date{} = original, nil} ->
          ["EXDATE;VALUE=DATE:#{date(original)}"]

        _mismatched ->
          []
      end
    end)
  end

  # Two shapes reach here and both are real. `MovedOccurrence` detects moves as
  # atom-keyed structs with `DateTime`s; the same moves travel to the write on an
  # Oban job, where JSONB round-trips them to string keys and ISO 8601 strings.
  # Reading only the first would work in every test that calls this directly and
  # fail on every job that carries one.
  defp point(move, key) do
    move
    |> Map.get(key, Map.get(move, Atom.to_string(key)))
    |> parse_point()
  end

  defp parse_point(%DateTime{} = at), do: at
  defp parse_point(%Date{} = d), do: d

  defp parse_point(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _not_a_datetime -> parse_date(value)
    end
  end

  defp parse_point(_other), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  # The wall clock in the series' zone, with no offset suffix: paired with a
  # TZID, an offset is what makes a provider reinterpret the value as UTC.
  defp timed(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, shifted} -> format(shifted)
      {:error, _reason} -> format(at)
    end
  end

  defp format(%DateTime{} = at) do
    "#{pad4(at.year)}#{pad2(at.month)}#{pad2(at.day)}T#{pad2(at.hour)}#{pad2(at.minute)}#{pad2(at.second)}"
  end

  defp date(%Date{} = d), do: "#{pad4(d.year)}#{pad2(d.month)}#{pad2(d.day)}"

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
  defp pad4(n), do: String.pad_leading(Integer.to_string(n), 4, "0")
end
