defmodule Tymeslot.Integrations.Calendar.SyncLink.UnmirrorableSeriesTest do
  @moduledoc """
  The refusal that used to be a silent discard, pinned as a recorded one.

  A recurring source on a link that cannot carry a series is not mirrored, and
  that part has always been correct. What was wrong is that nothing said so: the
  write-back worker answered `{:discard, :not_an_eligible_source}`, which is an
  Oban outcome and nothing else, so the organiser's recurring meetings went
  unmirrored with no placeholder, no retry, and nothing on the dashboard. The
  slots stayed bookable and the first sign of it would have been a double
  booking.

  This module pins the recording half. It is deliberately about *which* rows are
  written and, just as much, which are not: a row per event per sweep would
  drown the conflict history that is read precisely when someone is trying to
  find out why a calendar looks wrong.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.UnmirrorableSeries

  defp conflicts(link),
    do: Map.get(CalendarSyncConflictQueries.list_for_links([link.id]), link.id, [])

  # A link whose two ends are named outright, since the whole question is which
  # provider stands at each. `linked_pair/0` builds Google-to-Google, the one
  # combination that *can* carry a series.
  defp link_between(source_provider, target_provider) do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: source_provider)
    target = insert(:calendar_integration, user: user, provider: target_provider)

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    # Re-read through the query module rather than using the factory struct.
    # The factory sets only the two foreign keys, so both associations are
    # `NotLoaded` — and a link in that state reads as an unrecognised provider
    # at *both* ends, which would make every assertion below pass for the wrong
    # reason and none of them able to tell the two ends apart.
    # `CalendarSyncLinkQueries.get/1` preloads both, and is the call every
    # production caller of `record/2` arrives through.
    {:ok, link} = CalendarSyncLinkQueries.get(link.id)

    %{user: user, source: source, target: target, link: link}
  end

  describe "record/2 — the source cannot have its series resolved" do
    test "a CalDAV source onto a Google target is recorded, naming the source end" do
      %{source: source, link: link} = link_between("nextcloud", "google")
      instance = google_series_instance(source)

      assert :recorded == UnmirrorableSeries.record(link, instance)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "series_unsupported"
      assert conflict.resolution == "skipped"
      assert conflict.source_uid == instance.uid

      # Which end failed, and which provider it was, because the organiser's
      # only remedy differs completely between the two: an unresolvable source
      # means the repeating event has to live on a different calendar, while an
      # incapable target means the link has to point somewhere else.
      assert conflict.detail["unsupported_end"] == "source"
      assert conflict.detail["source_provider"] == "nextcloud"
      assert conflict.detail["target_provider"] == "google"
    end

    test "every CalDAV-family source is recorded the same way" do
      for provider <- ~w(caldav radicale apple baikal zimbra mailbox_org) do
        %{source: source, link: link} = link_between(provider, "google")

        assert :recorded == UnmirrorableSeries.record(link, google_series_instance(source))

        assert [conflict] = conflicts(link)
        assert conflict.detail["unsupported_end"] == "source"
        assert conflict.detail["source_provider"] == provider
      end
    end
  end

  describe "record/2 — the target cannot expand a series" do
    test "a Google source onto an Outlook target names the target end" do
      %{source: source, link: link} = link_between("google", "outlook")

      assert :recorded == UnmirrorableSeries.record(link, google_series_instance(source))

      assert [conflict] = conflicts(link)
      assert conflict.kind == "series_unsupported"
      assert conflict.detail["unsupported_end"] == "target"
      assert conflict.detail["target_provider"] == "outlook"
    end

    # Both ends failing is one row, not two, and it names both. An organiser
    # reading "the source cannot" and then fixing only that would find the link
    # still refusing, with a second row appearing to be a new problem.
    test "both ends failing is a single row naming both" do
      %{source: source, link: link} = link_between("nextcloud", "outlook")

      assert :recorded == UnmirrorableSeries.record(link, google_series_instance(source))

      assert [conflict] = conflicts(link)
      assert conflict.detail["unsupported_end"] == "both"
    end
  end

  describe "record/2 — what is deliberately not recorded" do
    # The whole point of the gate is that this pair mirrors, so a row here would
    # report a failure that did not happen.
    test "a link that can carry the series records nothing" do
      %{source: source, link: link} = link_between("google", "google")

      assert :nothing_to_record == UnmirrorableSeries.record(link, google_series_instance(source))
      assert conflicts(link) == []
    end

    # An ordinary event refused for transparency, cancellation or loop
    # prevention is not a recurrence problem, and filing it as one would send
    # the organiser looking for a repeating event that does not exist.
    test "a non-recurring source records nothing, whatever the providers are" do
      for {src, tgt} <- [{"outlook", "google"}, {"google", "outlook"}, {"nextcloud", "apple"}] do
        %{source: source, link: link} = link_between(src, tgt)

        one_off =
          insert(:provider_calendar_event,
            calendar_integration: source,
            uid: "one-off-uid",
            provider: src
          )

        assert :nothing_to_record == UnmirrorableSeries.record(link, one_off)
        assert conflicts(link) == []
      end
    end

    # The rule this exists to keep: the write-back worker runs on every change
    # to every event, and the reconcile sweep runs over the whole window every
    # pass. Appending on each would fill the history with the same sentence
    # about the same series until nothing else in it could be found.
    test "the same series on the same link is recorded once, not once per pass" do
      %{source: source, link: link} = link_between("nextcloud", "google")
      instance = google_series_instance(source)

      assert :recorded == UnmirrorableSeries.record(link, instance)
      assert :nothing_to_record == UnmirrorableSeries.record(link, instance)
      assert :nothing_to_record == UnmirrorableSeries.record(link, instance)

      assert length(conflicts(link)) == 1
    end

    # Two different series on one link are two different problems from the
    # organiser's side — each names an event they have to do something about —
    # so suppression is per source event rather than per link.
    test "a second series on the same link is its own row" do
      %{source: source, link: link} = link_between("nextcloud", "google")

      assert :recorded ==
               UnmirrorableSeries.record(link, google_series_instance(source))

      assert :recorded ==
               UnmirrorableSeries.record(
                 link,
                 google_series_instance(source, %{uid: "second-series@google.com"})
               )

      assert length(conflicts(link)) == 2
    end
  end

  describe "the kind is one the schema and the dashboard both know" do
    # A kind the schema rejects is a changeset error swallowed by the append,
    # which would make every one of the tests above pass against a table that
    # received nothing. Asserted directly rather than inferred.
    test "series_unsupported is a valid kind" do
      assert "series_unsupported" in CalendarSyncConflictSchema.kinds()
    end
  end
end
