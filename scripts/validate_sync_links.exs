# Live validation of cross-calendar mirroring, run against the deployed node.
#
# Drives one source calendar through the operations an organiser performs and
# checks, after each, that the target carries exactly the placeholders it
# should. Every event it creates is prefixed and deleted at the end, and the
# summary line is the only thing meant to be read on a good run.
#
# Usage: copy this file onto the host running the release, then evaluate it
# inside the running node.
#
#   /app/bin/tymeslot rpc 'Code.eval_file("/tmp/validate_sync_links.exs")'
#
# `rpc`, not `eval`. `eval` starts a fresh VM with no application started, so
# every Repo call fails with "could not lookup Ecto repo Tymeslot.Repo because
# it was not started".
#
# On a host reached over SSH, pass the command on stdin rather than as an
# argument. A quoted `-C "... rpc '\''...'\''"` nests quotes in a way that
# surfaces as an Elixir macro-expansion error rather than a shell one.

alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
alias Tymeslot.Integrations.Calendar.SyncLink.Engine
alias Tymeslot.Repo

import Ecto.Query

defmodule LiveValidation do
  @prefix "TYMESLOT-VALIDATION"

  def prefix, do: @prefix

  def check(label, true), do: IO.puts("  PASS  #{label}") && :pass
  def check(label, false), do: IO.puts("  FAIL  #{label}") && :fail

  def check(label, actual, expected) when actual == expected do
    IO.puts("  PASS  #{label}")
    :pass
  end

  def check(label, actual, expected) do
    IO.puts("  FAIL  #{label} — expected #{inspect(expected)}, got #{inspect(actual)}")
    :fail
  end

  # A count of zero is a failing check, not a passing one: a verification that
  # examined nothing reports success just as loudly as one that examined
  # everything, and this suite has been fooled that way before.
  def check_nonzero(label, count) do
    if count > 0 do
      IO.puts("  PASS  #{label} (n=#{count})")
      :pass
    else
      IO.puts("  FAIL  #{label} — examined nothing (n=0)")
      :fail
    end
  end

  # --- The matrix ----------------------------------------------------------

  def run(link, user_id, source_id, target_id) do
    at = fn days, time ->
      Date.utc_today() |> Date.add(days) |> DateTime.new!(time, "Etc/UTC")
    end

    one_off = one_off(link, user_id, source_id, target_id, at)
    recurring = recurring(link, user_id, source_id, target_id, at)
    inventory = inventory(link, source_id, target_id)

    one_off ++ recurring ++ inventory
  end

  # --- One-off: create, move, cancel, delete --------------------------------

  defp one_off(link, user_id, source_id, target_id, at) do
    IO.puts("\n=== ONE-OFF EVENT ===")
    uid = "#{@prefix}-oneoff-#{System.unique_integer([:positive])}"

    event = %{
      uid: uid,
      calendar_integration_id: source_id,
      summary: "#{@prefix} one-off",
      start_at: at.(30, ~T[09:00:00]),
      end_at: at.(30, ~T[10:00:00]),
      all_day: false,
      status: "confirmed",
      transparency: "opaque"
    }

    created = Engine.mirror(link, event, user_id)
    c1 = check("create mirrors to the target", created, :ok)
    c2 = check("a mirror row exists", mirror_count(link.id, uid), 1)

    c3 =
      check(
        "the placeholder is on the target, not the source",
        placeholder_integration(link.id, uid, target_id, source_id),
        :target
      )

    moved = %{event | start_at: at.(31, ~T[14:00:00]), end_at: at.(31, ~T[15:00:00])}
    c4 = check("move updates rather than duplicating", Engine.mirror(link, moved, user_id), :ok)
    c5 = check("still exactly one mirror row", mirror_count(link.id, uid), 1)

    cancelled = %{moved | status: "cancelled"}

    c6 =
      check(
        "cancel is accepted",
        Engine.mirror(link, cancelled, user_id) in [:ok, {:discard, :not_blocking}],
        true
      )

    deleted = Engine.unmirror(link, uid, user_id)
    c7 = check("delete withdraws the placeholder", deleted in [:ok, {:discard, :no_mirror}], true)
    c8 = check("no mirror row survives the delete", mirror_count(link.id, uid), 0)

    [c1, c2, c3, c4, c5, c6, c7, c8]
  end

  # --- Recurring: the same four operations on a series ----------------------

  defp recurring(link, user_id, source_id, target_id, at) do
    IO.puts("\n=== RECURRING SERIES ===")
    uid = "#{@prefix}-series-#{System.unique_integer([:positive])}"

    series = %{
      uid: uid,
      calendar_integration_id: source_id,
      summary: "#{@prefix} weekly",
      start_at: at.(30, ~T[11:00:00]),
      end_at: at.(30, ~T[12:00:00]),
      all_day: false,
      status: "confirmed",
      transparency: "opaque",
      recurrence_rule: "RRULE:FREQ=WEEKLY;COUNT=4"
    }

    created = Engine.mirror(link, series, user_id)

    # A target that cannot expand a series is a legitimate refusal, not a
    # failure: `Capability` decides, and reporting it as a fault would make the
    # run red on a perfectly correct CalDAV target.
    r1 =
      case created do
        :ok -> check("series mirrors as one repeating placeholder", true)
        {:discard, reason} -> check("series refused by capability (#{inspect(reason)})", true)
        other -> check("series create", other, :ok)
      end

    r2 =
      if created == :ok do
        check("exactly one row for the whole series", mirror_count(link.id, uid), 1)
      else
        check("no row for a refused series", mirror_count(link.id, uid), 0)
      end

    moved = %{series | start_at: at.(31, ~T[16:00:00]), end_at: at.(31, ~T[17:00:00])}

    r3 =
      check(
        "series move is accepted",
        Engine.mirror(link, moved, user_id) |> ok_or_discard?(),
        true
      )

    cancelled = %{moved | status: "cancelled"}

    r4 =
      check(
        "series cancel is accepted",
        Engine.mirror(link, cancelled, user_id) |> ok_or_discard?(),
        true
      )

    Engine.unmirror(link, uid, user_id)
    r5 = check("series delete leaves no row", mirror_count(link.id, uid), 0)

    [r1, r2, r3, r4, r5]
  end

  # --- Inventory: the invariants the loop incident violated -----------------

  defp inventory(link, source_id, target_id) do
    IO.puts("\n=== MIRROR INVENTORY ===")

    total = Repo.aggregate(from(m in "calendar_sync_mirrors"), :count)

    on_source =
      Repo.aggregate(
        from(e in "provider_calendar_events",
          where: e.calendar_integration_id == ^source_id and e.created_by_tymeslot == true
        ),
        :count
      )

    rows =
      Repo.all(
        from(m in "calendar_sync_mirrors",
          select: %{src: m.source_uid, pid: m.target_provider_event_id}
        )
      )

    outputs = MapSet.new(rows, & &1.pid)

    loops =
      Enum.count(rows, fn m ->
        MapSet.member?(outputs, String.replace(m.src || "", "@google.com", ""))
      end)

    mistargeted =
      Repo.aggregate(
        from(m in "calendar_sync_mirrors", where: m.target_integration_id == ^source_id),
        :count
      )

    [
      check_nonzero("mirror rows exist to inspect", total),
      check("no placeholder sits on the source calendar", on_source, 0),
      check("no mirror names another mirror's output as its source", loops, 0),
      check("no mirror row targets the link's source", mistargeted, 0),
      check("the link is still enabled", link.enabled, true),
      check("target integration unchanged", link.target_integration_id, target_id)
    ]
  end

  defp ok_or_discard?(:ok), do: true
  defp ok_or_discard?({:discard, _reason}), do: true
  defp ok_or_discard?(_other), do: false

  defp mirror_count(link_id, source_uid) do
    Repo.aggregate(
      from(m in "calendar_sync_mirrors",
        where: m.sync_link_id == ^link_id and m.source_uid == ^source_uid
      ),
      :count
    )
  end

  # Which side the placeholder landed on — the question the loop incident
  # turned on, and the one a count alone cannot answer.
  defp placeholder_integration(link_id, source_uid, target_id, source_id) do
    case Repo.one(
           from(m in "calendar_sync_mirrors",
             where: m.sync_link_id == ^link_id and m.source_uid == ^source_uid,
             select: m.target_integration_id
           )
         ) do
      ^target_id -> :target
      ^source_id -> :source
      other -> {:unexpected, other}
    end
  end
end

# --- Preconditions ---------------------------------------------------------

IO.puts("\n=== PRECONDITIONS ===")

link = Repo.one(from(l in Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema, limit: 1))

results =
  if is_nil(link) do
    IO.puts("  FAIL  no sync link configured — nothing to validate")
    [:fail]
  else
    user_id = link.user_id
    source_id = link.source_integration_id
    target_id = link.target_integration_id

    IO.puts("  link #{link.id}: integration #{source_id} -> #{target_id} (user #{user_id})")

    integrations =
      Repo.all(
        from(c in "calendar_integrations",
          where: c.id in ^[source_id, target_id],
          select: %{id: c.id, active: c.is_active, reauth: c.needs_reauth}
        )
      )

    all_active? = Enum.all?(integrations, & &1.active)

    pre = [
      LiveValidation.check("both calendars active", all_active?),
      LiveValidation.check(
        "neither needs reauth",
        Enum.all?(integrations, &(not &1.reauth))
      )
    ]

    if Enum.any?(pre, &(&1 == :fail)) do
      IO.puts("\n  Skipping: an inactive target is refused by design, so every")
      IO.puts("  mirror below would report {:discard, :target_unavailable}.")
      pre
    else
      pre ++ LiveValidation.run(link, user_id, source_id, target_id)
    end
  end

# --- Summary ---------------------------------------------------------------

passed = Enum.count(results, &(&1 == :pass))
failed = Enum.count(results, &(&1 == :fail))

IO.puts("\n=== SUMMARY ===")
IO.puts("  #{passed} passed, #{failed} failed")
IO.puts(if failed == 0, do: "  RESULT: OK", else: "  RESULT: FAILURES PRESENT")
