defmodule Tymeslot.Bookings.ActivationTest do
  @moduledoc """
  The confirmation-side effects shared by every path that turns a meeting
  into a booking the world knows about: a fresh confirmed booking, a held
  request the host just approved, the Stripe checkout webhook, and an
  ad-hoc host booking.

  Coverage here proves the branching `activate/2`'s moduledoc promises:
  a request still `awaiting_approval` takes the request fan-out rather than
  the confirmation one, a meeting with an API-created video provider hands
  off to `VideoRoomWorker` instead of scheduling the confirmation email
  itself (the room-then-email ordering the moduledoc calls load-bearing),
  and everything else goes straight to the confirmation email.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :video

  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  defp meeting_for(user, attrs) do
    defaults = %{organizer_user: user, organizer_user_id: user.id}
    insert(:meeting, Map.merge(defaults, attrs))
  end

  describe "activate/2 — a request still awaiting approval" do
    test "dispatches to the request fan-out, not the confirmation one" do
      user = insert(:user)

      meeting =
        meeting_for(user, %{
          status: "awaiting_approval",
          approval_requested_at: DateTime.utc_now(:second),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
        })

      assert :ok = Activation.activate(meeting)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_emails", "meeting_id" => meeting.id}
      )

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )

      refute_enqueued(worker: VideoRoomWorker)
    end
  end

  describe "activate/2 — with_video_room: true" do
    test "enqueues the video-room job rather than scheduling the confirmation email itself" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user, provider: "mirotalk")

      meeting =
        meeting_for(user, %{status: "confirmed", video_integration_id: video_integration.id})

      assert :ok = Activation.activate(meeting, with_video_room: true)

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "send_emails" => true}
      )

      # The room must exist before the join link can go out, so the worker
      # sends the confirmation itself once it has created it — Activation
      # must not race it by scheduling the same email up front.
      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end

    test "a meeting with no video integration goes straight to notification" do
      user = insert(:user)
      meeting = meeting_for(user, %{status: "confirmed", video_integration_id: nil})

      assert :ok = Activation.activate(meeting, with_video_room: true)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )

      refute_enqueued(worker: VideoRoomWorker)
    end
  end

  describe "activate/2 — auto-detecting the provider" do
    test "a Zoom meeting takes the room-creating path" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user, provider: "zoom")

      meeting =
        meeting_for(user, %{status: "confirmed", video_integration_id: video_integration.id})

      assert :ok = Activation.activate(meeting)

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "send_emails" => true}
      )

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end

    test "a meeting whose provider is not API-created goes straight to notification" do
      user = insert(:user)
      meeting = meeting_for(user, %{status: "confirmed", video_integration_id: nil})

      assert :ok = Activation.activate(meeting)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )

      refute_enqueued(worker: VideoRoomWorker)
    end
  end
end
