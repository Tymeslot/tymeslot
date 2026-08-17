defmodule Tymeslot.Integrations.Calendar.SyncLink.MovedOccurrenceEnqueueTest do
  @moduledoc """
  Detection handing its moves to the write that can act on them.

  `MovedOccurrence` has always recorded a move and stopped there. The recording
  stays — it is what the organiser reads, and what the decision to correct was
  made on — but the same pass now also enqueues the rewrite that puts the block
  where the meeting went.

  The enqueue is where the moves have to be attached, because nothing later can
  see them: the cache holds one row per series and the moved instance is
  collapsed into it before the job runs.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.MovedOccurrence
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup do
    context = linked_pair()
    {:ok, link} = CalendarSyncLinkQueries.get(context.link.id)
    %{context | link: link}
  end

  defp instance(source, attrs) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: "weekly-series@google.com",
          calendar_integration_id: source.id,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "instance-1",
          summary: "Weekly standup",
          all_day: false,
          recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
          recurring_event_id: "master_abc123",
          synced_at: ~U[2026-07-01 00:00:00Z]
        },
        attrs
      )
    )
  end

  defp moved_instance(source) do
    instance(source, %{
      start_at: ~U[2026-08-14 22:00:00Z],
      end_at: ~U[2026-08-14 22:30:00Z],
      original_start_at: ~U[2026-08-14 14:00:00Z]
    })
  end

  defp enqueued do
    Enum.map(all_enqueued(worker: SyncLinkWriteBackWorker), & &1.args)
  end

  describe "report/2 enqueuing the correction" do
    test "a moved occurrence enqueues an upsert carrying the move", %{
      source: source,
      link: link
    } do
      assert :ok == MovedOccurrence.report([moved_instance(source)], [link])

      assert [args] = enqueued()

      assert args["sync_link_id"] == link.id
      assert args["source_uid"] == "weekly-series@google.com"
      assert args["operation"] == "upsert"

      assert args["moved"] == [
               %{
                 "original_start" => "2026-08-14T14:00:00Z",
                 "new_start" => "2026-08-14T22:00:00Z"
               }
             ]
    end

    test "an unmoved series enqueues nothing", %{source: source, link: link} do
      # The ordinary sync already enqueues for every event it sees; this pass
      # must not add a second job for a series that has not moved.
      unmoved =
        instance(source, %{
          start_at: ~U[2026-08-14 14:00:00Z],
          end_at: ~U[2026-08-14 14:30:00Z],
          original_start_at: nil
        })

      assert :ok == MovedOccurrence.report([unmoved], [link])

      assert enqueued() == []
    end

    test "a link whose target cannot expand a series enqueues nothing", %{
      user: user,
      source: source
    } do
      # `Eligibility` refuses a recurring source for such a target, so no
      # placeholder was ever written and there is nothing to correct.
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      outlook_link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: outlook_target.id
        )

      {:ok, outlook_link} = CalendarSyncLinkQueries.get(outlook_link.id)

      assert :ok == MovedOccurrence.report([moved_instance(source)], [outlook_link])

      assert enqueued() == []
    end

    test "two links onto capable targets each get their own correction", %{
      user: user,
      source: source,
      link: link
    } do
      {_target, second} = extra_target_link(%{user: user, source: source})
      {:ok, second} = CalendarSyncLinkQueries.get(second.id)

      assert :ok == MovedOccurrence.report([moved_instance(source)], [link, second])

      ids = enqueued() |> Enum.map(& &1["sync_link_id"]) |> Enum.sort()

      assert ids == Enum.sort([link.id, second.id])
    end
  end
end
