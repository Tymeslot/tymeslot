defmodule Tymeslot.Notifications.Email.ApprovalReleaseGuestTest do
  @moduledoc "Verifies approval release queues retryable guest cancellations with compatible job args."

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :bookings

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, user_smtp_enabled: true, email_service_module: EmailServiceMock)
    owner = insert(:user)

    settings =
      Repo.insert!(%UserSmtpSettingsSchema{
        user_id: owner.id,
        host: "smtp.customer.example",
        port: 587,
        security: :starttls,
        username_encrypted: Encryption.encrypt("smtp-user"),
        password_encrypted: Encryption.encrypt("smtp-password"),
        from_address: "bookings@customer.example",
        from_name: "Customer bookings",
        enabled: true,
        revision: 1,
        tested_revision: 1,
        tested_at: DateTime.utc_now()
      })

    %{owner: owner, settings: settings}
  end

  test "the scheduler keeps old args unchanged and validates its optional boolean", %{
    owner: owner
  } do
    meeting = released(owner)

    for invalid <- [nil, "true", 1, %{}] do
      assert {:error, :invalid_options} =
               EmailScheduler.schedule_request_outcome(meeting.id, :declined,
                 notify_guests: invalid
               )
    end

    assert [] = all_enqueued(worker: EmailWorker)
    assert :ok = EmailScheduler.schedule_request_outcome(meeting.id, :declined)

    assert outcome_job(meeting).args == %{
             "action" => "send_booking_request_outcome",
             "meeting_id" => meeting.id,
             "variant" => "declined"
           }
  end

  test "an explicit synchronous release decision survives a later feature enable", %{owner: owner} do
    meeting = released(owner)

    assert {:ok, :notifications_scheduled} =
             Orchestrator.send_request_outcome_notifications(meeting, :declined,
               notify_guests: false
             )

    refute Map.has_key?(outcome_job(meeting).args, "notify_guests")
  end

  for variant <- [:declined, :expired] do
    test "a #{variant} approval release defers guests to the existing marked outcome job", %{
      owner: owner
    } do
      deadline =
        DateTime.add(
          DateTime.utc_now(:second),
          if(unquote(variant) == :expired, do: -1, else: 1),
          :hour
        )

      meeting =
        insert(:meeting,
          organizer_user_id: owner.id,
          status: :awaiting_approval,
          first_announced_at: DateTime.utc_now(:second),
          approval_requested_at: DateTime.add(deadline, -2, :hour),
          approval_deadline_at: deadline
        )

      guests(meeting)

      # Release side effects are best effort, so record an unexpected direct
      # send explicitly rather than relying on a swallowed mock exception.
      test_pid = self()

      stub(EmailServiceMock, :send_guest_cancellation, fn email, _details ->
        send(test_pid, {:synchronous_guest, email})
        {:ok, :sent}
      end)

      assert {:ok, released} =
               if(unquote(variant) == :expired,
                 do: Approval.expire(meeting),
                 else: Approval.decline(meeting, nil)
               )

      refute_received {:synchronous_guest, _email}

      assert outcome_job(released).args == %{
               "action" => "send_booking_request_outcome",
               "meeting_id" => meeting.id,
               "variant" => Atom.to_string(unquote(variant)),
               "notify_guests" => true
             }
    end
  end

  for rollback <- [:settings_disabled, :feature_disabled] do
    test "a marked job still owes guests after #{rollback}", %{owner: owner, settings: settings} do
      meeting = released(owner)
      guests(meeting)
      :ok = EmailScheduler.schedule_request_outcome(meeting.id, :declined, notify_guests: true)

      if unquote(rollback) == :settings_disabled do
        assert {:ok, _disabled} =
                 EmailSending.disable_settings(owner, {settings.id, settings.revision})
      else
        with_config(:tymeslot, user_smtp_enabled: false)
      end

      expected_sender =
        if unquote(rollback) == :feature_disabled, do: nil, else: Sender.platform(owner.id)

      expect(EmailServiceMock, :send_booking_request_outcome, fn :declined, sent ->
        assert sent.id == meeting.id
        assert sent.email_sender == expected_sender
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_guest_cancellation, 2, fn _email, details ->
        assert Map.get(details, :email_sender) == expected_sender
        {:ok, :sent}
      end)

      assert :ok = EmailWorker.perform(%{outcome_job(meeting) | attempt: 1})
    end
  end

  test "old unmarked jobs stay attendee-only even when SMTP is now enabled", %{owner: owner} do
    meeting = released(owner)
    guests(meeting)
    :ok = EmailScheduler.schedule_request_outcome(meeting.id, :declined)

    expect(EmailServiceMock, :send_booking_request_outcome, fn :declined, _meeting ->
      {:ok, :sent}
    end)

    assert :ok = EmailWorker.perform(%{outcome_job(meeting) | attempt: 1})
  end

  for failed <- [:attendee, :guest], reason <- [:rate_limited, :circuit_open] do
    test "a marked outcome retries only the #{failed} refused by #{reason}", %{owner: owner} do
      meeting = released(owner)
      guests(meeting)
      :ok = EmailScheduler.schedule_request_outcome(meeting.id, :declined, notify_guests: true)
      job = outcome_job(meeting)

      if unquote(failed) == :attendee do
        expect(EmailServiceMock, :send_booking_request_outcome, fn :declined, _sent ->
          {:error, unquote(reason)}
        end)
      end

      expect(EmailServiceMock, :send_booking_request_outcome, fn :declined, sent ->
        assert sent.email_sender.kind == :user_smtp
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_guest_cancellation, 2, fn email, details ->
        assert details.email_sender.kind == :user_smtp

        if unquote(failed) == :guest and email == "missed@example.com",
          do: {:error, unquote(reason)},
          else: {:ok, :sent}
      end)

      if unquote(failed) == :guest do
        expect(EmailServiceMock, :send_guest_cancellation, fn "missed@example.com", _details ->
          {:ok, :sent}
        end)
      end

      assert {:snooze, seconds} = EmailWorker.perform(%{job | attempt: 1})
      assert seconds > 0
      assert :ok = EmailWorker.perform(%{job | attempt: 2})

      # A rescued successful run sends none of its already-claimed copies.
      assert :ok = EmailWorker.perform(%{job | attempt: 3})
    end
  end

  defp released(owner) do
    insert(:meeting,
      organizer_user_id: owner.id,
      status: :cancelled,
      first_announced_at: DateTime.utc_now(:second)
    )
  end

  defp guests(meeting) do
    {:ok, guests} =
      Guests.create_for_meeting(meeting.id, ["delivered@example.com", "missed@example.com"])

    guests
  end

  defp outcome_job(meeting) do
    [job] =
      all_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_outcome", "meeting_id" => meeting.id}
      )

    job
  end
end
