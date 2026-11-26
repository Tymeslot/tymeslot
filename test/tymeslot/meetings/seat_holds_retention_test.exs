defmodule Tymeslot.Meetings.SeatHoldsRetentionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments
  @moduletag :meetings

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.GroupCancellationTestHelpers
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.DataRetentionWorker

  setup do
    GroupCancellationTestHelpers.host_and_session()
  end

  defp hold_settled(session, status, days_ago, attrs \\ []) do
    hold = insert(:seat_hold, [meeting: session, status: status] ++ attrs)
    at = DateTime.add(DateTime.utc_now(:second), -days_ago, :day)

    {1, nil} =
      Repo.update_all(where(SeatHoldSchema, id: ^hold.id), set: [updated_at: at])

    hold
  end

  defp exists?(hold), do: Repo.get(SeatHoldSchema, hold.id) != nil

  describe "prune_settled/1" do
    test "settled holds older than the window are deleted", %{session: session} do
      old_converted = hold_settled(session, :converted, 31)
      old_released = hold_settled(session, :released, 31, released_reason: :expired)
      recent_converted = hold_settled(session, :converted, 29)
      recent_released = hold_settled(session, :released, 29, released_reason: :expired)

      assert {2, nil} = SeatHolds.prune_settled(30)

      refute exists?(old_converted)
      refute exists?(old_released)
      assert exists?(recent_converted)
      assert exists?(recent_released)
    end

    test "a held hold is never pruned by age", %{session: session} do
      held = hold_settled(session, :held, 90)

      assert {0, nil} = SeatHolds.prune_settled(30)
      assert exists?(held)
    end

    test "deleting a hold keeps its payment", %{session: session} = ctx do
      payment = GroupCancellationTestHelpers.paid_seat(ctx, "ada@example.com")
      hold_id = payment.seat_hold_id

      {1, nil} =
        Repo.update_all(where(SeatHoldSchema, id: ^hold_id),
          set: [updated_at: DateTime.add(DateTime.utc_now(:second), -31, :day)]
        )

      assert {1, nil} = SeatHolds.prune_settled(30)
      # The payment's hold reference is checked at commit, which the sandbox
      # never reaches; fire the pending checks now.
      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

      refute Repo.get(SeatHoldSchema, hold_id)

      assert %BookingPaymentSchema{
               seat_hold_id: nil,
               status: :paid,
               attendee_email: "ada@example.com",
               amount_cents: 2000,
               meeting_id: meeting_id
             } = Repo.get!(BookingPaymentSchema, payment.id)

      assert meeting_id == session.id
    end
  end

  describe "DataRetentionWorker" do
    test "the retention worker prunes seat holds", %{session: session} do
      old = hold_settled(session, :converted, 31)
      recent = hold_settled(session, :released, 10, released_reason: :expired)

      assert :ok = perform_job(DataRetentionWorker, %{"seat_hold_retention_days" => 30})

      refute exists?(old)
      assert exists?(recent)
    end

    test "honours a shorter window from its arguments", %{session: session} do
      recent = hold_settled(session, :released, 10, released_reason: :expired)

      assert :ok = perform_job(DataRetentionWorker, %{"seat_hold_retention_days" => 5})

      refute exists?(recent)
    end
  end
end
