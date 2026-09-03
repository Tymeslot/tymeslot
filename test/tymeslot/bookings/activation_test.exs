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

  # async: false already required by the module's own setup; the recovery
  # tests below additionally patch Oban.insert/1 with :meck, which replaces
  # the module globally for every process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :video

  alias Ecto.Changeset
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
        args: %{"meeting_id" => meeting.id, "announce" => true}
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
        args: %{"meeting_id" => meeting.id, "announce" => true}
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

    test "an integration whose provider is no longer recognised still goes to notification" do
      # A provider disabled after the integration was created — the row is
      # inserted directly, bypassing the changeset's enum validation, exactly
      # as a legacy row already in the database would.
      user = insert(:user)

      video_integration =
        insert(:video_integration, user: user, provider: "discontinued_provider")

      meeting =
        meeting_for(user, %{status: "confirmed", video_integration_id: video_integration.id})

      assert :ok = Activation.activate(meeting)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )

      refute_enqueued(worker: VideoRoomWorker)
    end
  end

  describe "activate/2 — recovery branches" do
    test "awaiting_approval: a failed request-email insert still returns :ok and leaves the nudge and expiry armed" do
      user = insert(:user)

      meeting =
        meeting_for(user, %{
          status: "awaiting_approval",
          approval_requested_at: DateTime.utc_now(:second),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
        })

      # Only the request-email insert fails; the nudge and the expiry job the
      # same call arms must still reach the queue, and the case clause that
      # handles this error must not let it escape `activate/2` — without it
      # this raises a `CaseClauseError` instead of returning `:ok`.
      :meck.new(Oban, [:passthrough])

      :meck.expect(Oban, :insert, fn changeset ->
        if Changeset.get_field(changeset, :args)["action"] == "send_booking_request_emails" do
          {:error, :simulated_failure}
        else
          :meck.passthrough([changeset])
        end
      end)

      try do
        assert :ok = Activation.activate(meeting)
      after
        :meck.unload(Oban)
      end

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_emails", "meeting_id" => meeting.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_approval_nudge", "meeting_id" => meeting.id}
      )
    end

    test "with_video_room: true — a failed video-room insert still enqueues the confirmation email" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user, provider: "mirotalk")

      meeting =
        meeting_for(user, %{status: "confirmed", video_integration_id: video_integration.id})

      # Only the video-room insert fails; the fallback (`notify/1`) is what
      # guarantees the attendee still gets a confirmation email rather than
      # nothing at all when the video job cannot be enqueued.
      :meck.new(Oban, [:passthrough])

      :meck.expect(Oban, :insert, fn changeset ->
        if Changeset.get_field(changeset, :worker) == "Tymeslot.Workers.VideoRoomWorker" do
          {:error, :simulated_failure}
        else
          :meck.passthrough([changeset])
        end
      end)

      try do
        assert :ok = Activation.activate(meeting, with_video_room: true)
      after
        :meck.unload(Oban)
      end

      refute_enqueued(worker: VideoRoomWorker)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end

    test "notify/1: a failed confirmation-email insert still returns :ok without escaping" do
      # No video integration, so this goes straight to `notify/1`. Only the
      # confirmation-email insert fails; the case clause that handles the
      # resulting `{:error, _}` from `Events.meeting_created/1` must not let
      # it escape `activate/2` — without it this raises a `CaseClauseError`
      # instead of returning `:ok`.
      user = insert(:user)
      meeting = meeting_for(user, %{status: "confirmed", video_integration_id: nil})

      :meck.new(Oban, [:passthrough])

      :meck.expect(Oban, :insert, fn changeset ->
        if Changeset.get_field(changeset, :args)["action"] == "send_confirmation_emails" do
          {:error, :simulated_failure}
        else
          :meck.passthrough([changeset])
        end
      end)

      try do
        assert :ok = Activation.activate(meeting)
      after
        :meck.unload(Oban)
      end

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end
  end
end
