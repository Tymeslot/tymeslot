defmodule Tymeslot.Bookings.CancelTest do
  @moduledoc """
  Tests for the booking cancellation module.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :bookings

  import Mox

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.ZoomOAuthHelperMock
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup do
    # Setup email mocks for cancellation notifications
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "execute/1 with meeting UID" do
    test "successfully cancels a future meeting" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      assert {:ok, cancelled_meeting} = Cancel.execute(meeting.uid)
      assert cancelled_meeting.status == "cancelled"
      assert %DateTime{} = cancelled_meeting.cancelled_at
    end

    test "returns error when meeting is not found" do
      assert {:error, :meeting_not_found} = Cancel.execute("non-existent-uid")
    end

    test "returns error when meeting is already cancelled" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{status: "cancelled", start_offset: 3600, duration: 3600})

      assert {:error, "Meeting is already cancelled"} = Cancel.execute(meeting.uid)
    end

    test "returns error when meeting is completed" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -7_200,
          duration: 3_600
        })

      assert {:error, "Cannot cancel a completed meeting"} = Cancel.execute(meeting.uid)
    end

    test "returns error when meeting has already started" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -3_600,
          duration: 7_200
        })

      assert {:error, "Cannot cancel a meeting that has already started"} =
               Cancel.execute(meeting.uid)
    end

    test "returns error when meeting has already occurred" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -7_200,
          duration: 3_600
        })

      assert {:error, "Cannot cancel a meeting that has already occurred"} =
               Cancel.execute(meeting.uid)
    end

    test "refuses the withdraw link on a request that already expired" do
      %{user: user} = create_user_with_profile()

      # The invitee's request-received email carries a "Withdraw your request"
      # link, and it stays in their inbox after the deadline passes. By then
      # `Meetings.Approval` has released the slot, told them the request
      # lapsed and refunded anything paid — so running the cancellation
      # pipeline over that would overwrite the outcome and send a second,
      # contradicting round of emails for a meeting that never happened.
      expired =
        insert_meeting_for_user(user, %{
          status: "expired",
          start_offset: 3_600,
          duration: 3_600,
          approval_requested_at: DateTime.add(DateTime.utc_now(:second), -13, :hour),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :hour),
          approval_resolved_at: DateTime.utc_now(:second),
          cancelled_at: DateTime.utc_now(:second)
        })

      assert {:error, "Cannot cancel an expired meeting"} = Cancel.execute(expired.uid)

      {:ok, stored} = MeetingQueries.get_meeting_by_uid(expired.uid)
      assert stored.status == "expired"

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_cancellation_emails", "meeting_id" => expired.id}
      )
    end
  end

  describe "execute/1 with meeting struct" do
    test "successfully cancels a future meeting struct" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      # Reload to ensure we have the full struct
      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:ok, cancelled_meeting} = Cancel.execute(loaded_meeting)
      assert cancelled_meeting.status == "cancelled"
      assert %DateTime{} = cancelled_meeting.cancelled_at
    end

    test "returns error when meeting is already cancelled" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "cancelled",
          start_offset: 3600,
          duration: 3600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Meeting is already cancelled"} = Cancel.execute(loaded_meeting)
    end

    test "allows cancellation of meeting starting soon" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 600,
          duration: 3_600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:ok, cancelled_meeting} = Cancel.execute(loaded_meeting)
      assert cancelled_meeting.status == "cancelled"
    end
  end

  describe "validate_cancellation/1" do
    test "returns :ok for future meetings" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert :ok = Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for already cancelled meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "cancelled",
          start_offset: 3600,
          duration: 3600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Meeting is already cancelled"} =
               Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for completed meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -7_200,
          duration: 3_600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Cannot cancel a completed meeting"} =
               Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for ongoing meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -3_600,
          duration: 7_200
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Cannot cancel a meeting that has already started"} =
               Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for past meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -7_200,
          duration: 3_600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Cannot cancel a meeting that has already occurred"} =
               Cancel.validate_cancellation(loaded_meeting)
    end
  end

  describe "withdrawing a held booking request" do
    # The invitee is invited to withdraw by the "withdraw your request" link in
    # the request-received email, and that link reaches `Cancel.execute/1`
    # rather than `Approval.decline/2`. A request that never became a meeting
    # gave them nothing, so the money must come back on this exit exactly as it
    # does on the two `Approval` owns.
    test "refunds a paid request in full" do
      %{user: user} = create_user_with_profile()
      meeting = insert_held_paid_request(user)
      payment = BookingPaymentQueries.by_meeting_id(meeting.id)

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == payment.stripe_charge_id
        assert params.amount == 5000
        {:ok, %{id: "re_withdrawn"}}
      end)

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      reloaded = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000

      assert_enqueued(
        worker: SendBookingPaymentRefunded,
        args: %{booking_payment_id: payment.id}
      )
    end

    # No `expect/3` is set on StripeAdapterMock, so Mox raises if the
    # cancellation reaches Stripe at all.
    test "does not touch Stripe when the request was never paid for" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 86_400,
          duration: 3600,
          status: "awaiting_approval"
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    # A confirmed booking the attendee cancels is the ordinary cancellation
    # path, where the refund is the host's decision in the dashboard rather
    # than automatic. Withdrawing a *held request* is the case that refunds.
    test "leaves a confirmed booking's payment alone" do
      %{user: user} = create_user_with_profile()
      meeting = insert_held_paid_request(user, "confirmed")

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      reloaded = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert reloaded.status == "paid"
      assert reloaded.refunded_amount_cents == 0
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    # A request that was already a confirmed, paid meeting before it
    # re-entered the gate (a reschedule of a confirmed booking resets it to
    # "awaiting_approval") is not the same case as one that never got
    # approved: there IS a confirmed meeting to weigh a refund choice
    # against, so the automatic full refund must not run.
    #
    # `first_announced_at` is the durable marker of that history and
    # `announced_at` is not: the re-gating reschedule clears the latter so the
    # host's second approval can claim the fan-out again. A row carrying only
    # `announced_at` is one production cannot produce, which is what this test
    # used to build.
    test "does not auto-refund a request that was a confirmed meeting before re-entering the gate" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_held_paid_request(user, "awaiting_approval", %{
          announced_at: nil,
          first_announced_at: DateTime.utc_now(:second)
        })

      # No `expect/3` is set on StripeAdapterMock, so Mox raises if the
      # withdrawal reaches Stripe at all.
      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      reloaded = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert reloaded.status == "paid"
      assert reloaded.refunded_amount_cents == 0
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    # The single-writer invariant this whole gate exists for: withdrawing
    # must go through the same guarded `UPDATE ... WHERE status =
    # 'awaiting_approval'` every other exit uses, not a plain changeset
    # write keyed on a struct that can go stale. Simulates the race by
    # flipping the row to "confirmed" behind the caller's back (as a
    # concurrent host approval or the expiry sweep would) before it acts on
    # its stale, still-"awaiting_approval" copy.
    test "does not overwrite a meeting a concurrent approval already confirmed" do
      %{user: user} = create_user_with_profile()
      stale_meeting = insert_held_paid_request(user)

      {:ok, _confirmed} =
        MeetingQueries.update_meeting(stale_meeting, %{status: "confirmed"})

      assert {:error, :not_awaiting_approval} = Cancel.execute(stale_meeting)

      {:ok, reloaded} = MeetingQueries.get_meeting_by_uid(stale_meeting.uid)
      assert reloaded.status == "confirmed"

      reloaded_payment = BookingPaymentQueries.by_meeting_id(stale_meeting.id)
      assert reloaded_payment.status == "paid"
      assert reloaded_payment.refunded_amount_cents == 0
    end
  end

  describe "the external auto-cancel path releases a held request properly" do
    # `execute_external/1` is what fires when the host deletes the tentative
    # hold from their own calendar. For a held request this used to leave
    # the approval clock running entirely: no refund, no outcome email, and
    # the nudge/expiry jobs still armed against a meeting already gone.
    test "refunds a paid held request and records why it was cancelled" do
      %{user: user} = create_user_with_profile()
      meeting = insert_held_paid_request(user)
      payment = BookingPaymentQueries.by_meeting_id(meeting.id)

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == payment.stripe_charge_id
        assert params.amount == 5000
        {:ok, %{id: "re_external"}}
      end)

      assert {:ok, cancelled} = Cancel.execute_external(meeting)
      assert cancelled.status == "cancelled"
      assert cancelled.cancellation_reason == "Cancelled externally via calendar sync"

      reloaded = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000

      assert_enqueued(
        worker: SendBookingPaymentRefunded,
        args: %{booking_payment_id: payment.id}
      )
    end
  end

  describe "status update side effects" do
    test "persists cancellation status in database" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      assert {:ok, _cancelled_meeting} = Cancel.execute(meeting.uid)

      # Reload from database to verify persistence
      {:ok, reloaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      assert reloaded_meeting.status == "cancelled"
      assert %DateTime{} = reloaded_meeting.cancelled_at
    end

    test "deletes pending reminder email jobs" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )

      assert {:ok, _cancelled_meeting} = Cancel.execute(meeting.uid)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )
    end
  end

  describe "Zoom video room cleanup" do
    test "enqueues a video-sync delete job that calls the Zoom REST API" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: "987654321"
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      # The provider call is deferred to a supervised, retrying Oban job rather
      # than made inline — so a transient Zoom failure no longer orphans the
      # meeting. The cancellation itself does not touch the Zoom API.
      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => cancelled.id, "action" => "delete"}
      )

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/987654321"
        assert {"Authorization", "Bearer access-token"} in headers

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => cancelled.id, "action" => "delete"})
    end

    test "still cancels successfully and the job retries when Zoom delete fails" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: "555"
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_cancellation_emails", "meeting_id" => cancelled.id}
      )

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => cancelled.id, "action" => "delete"}
      )

      # A transient Zoom failure returns {:error, _} from the job so Oban retries
      # it — the meeting is not permanently desynced.
      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => cancelled.id, "action" => "delete"})
    end

    test "the delete job treats Zoom 404 as success so cancellation is idempotent" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: "gone"
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => cancelled.id, "action" => "delete"})
    end

    test "still enqueues the delete job after the integration was disconnected" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "86360699337"
        })

      # Disconnecting nulls video_integration_id through the nilify_all foreign
      # key while the Zoom meeting carries on existing.
      assert {:ok, :deleted} = Video.delete_integration(user.id, integration.id)

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"
      assert cancelled.video_integration_id == nil
      assert cancelled.video_room_id == "86360699337"

      # The link is gone but the room is not, so the provider must still be told.
      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => cancelled.id, "action" => "delete"}
      )
    end

    test "does not enqueue a video-sync job when meeting has no video_room_id" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: nil
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      refute_enqueued(worker: VideoSyncWorker)
    end
  end

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
  end

  defp insert_held_paid_request(user, status \\ "awaiting_approval", extra_attrs \\ %{}) do
    meeting =
      insert_meeting_for_user(
        user,
        Map.merge(
          %{
            start_offset: 86_400,
            duration: 3600,
            status: status
          },
          extra_attrs
        )
      )

    insert(:booking_payment, %{
      meeting_id: meeting.id,
      stripe_charge_id: "ch_TEST_#{System.unique_integer([:positive])}",
      stripe_account_id: "acct_TEST",
      amount_cents: 5000,
      refunded_amount_cents: 0,
      application_fee_cents: 0,
      status: "paid",
      paid_at: DateTime.utc_now(:second)
    })

    meeting
  end
end
