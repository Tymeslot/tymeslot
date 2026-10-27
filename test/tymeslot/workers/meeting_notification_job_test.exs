defmodule Tymeslot.Workers.MeetingNotificationJobTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :notifications

  use Oban.Testing, repo: Tymeslot.Repo
  import Ecto.Query, only: [where: 2]

  alias Ecto.UUID
  alias Oban.Job
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker, WebhookWorker}

  describe "schedule/5 through the channel workers" do
    test "a delivery still waiting absorbs a duplicate however long it has waited" do
      assert :ok = SlackWorker.schedule_delivery(7, "meeting.rescheduled", "m-1")

      # Well past the 300 s window the workers used to have.
      Repo.update_all(where(Job, worker: ^inspect(SlackWorker)),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert :ok = SlackWorker.schedule_delivery(7, "meeting.rescheduled", "m-1")

      assert [_job] = all_enqueued(worker: SlackWorker)
    end

    test "a delivery that already ran does not absorb a later event" do
      assert :ok = TelegramWorker.schedule_delivery(7, "meeting.rescheduled", "m-1")

      Repo.update_all(where(Job, worker: ^inspect(TelegramWorker)),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      assert :ok = TelegramWorker.schedule_delivery(7, "meeting.rescheduled", "m-1")

      assert [_job] = all_enqueued(worker: TelegramWorker)
    end

    test "each seat of a group meeting is its own delivery" do
      seat_a = UUID.generate()
      seat_b = UUID.generate()

      assert :ok = SlackWorker.schedule_delivery(7, "meeting.created", "m-1", seat_a)
      assert :ok = SlackWorker.schedule_delivery(7, "meeting.created", "m-1", seat_b)
      assert :ok = SlackWorker.schedule_delivery(7, "meeting.created", "m-1", seat_a)

      assert all_enqueued(worker: SlackWorker)
             |> Enum.map(& &1.args["participant_id"])
             |> Enum.sort() == Enum.sort([seat_a, seat_b])
    end

    test "a delivery for one seat does not absorb the meeting's own delivery" do
      seat = UUID.generate()

      assert :ok = SlackWorker.schedule_delivery(7, "meeting.cancelled", "m-1", seat)
      assert :ok = SlackWorker.schedule_delivery(7, "meeting.cancelled", "m-1")

      assert all_enqueued(worker: SlackWorker)
             |> Enum.map(& &1.args["participant_id"])
             |> Enum.sort() == Enum.sort([seat, nil])
    end

    test "a webhook duplicate with a different snapshot is its own delivery" do
      assert :ok = WebhookWorker.schedule_delivery(7, "meeting.rescheduled", "m-1", %{"a" => 1})
      assert :ok = WebhookWorker.schedule_delivery(7, "meeting.rescheduled", "m-1", %{"a" => 1})
      assert :ok = WebhookWorker.schedule_delivery(7, "meeting.rescheduled", "m-1", %{"a" => 2})

      assert length(all_enqueued(worker: WebhookWorker)) == 2
    end
  end
end
