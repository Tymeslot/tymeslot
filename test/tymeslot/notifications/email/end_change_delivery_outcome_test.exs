defmodule Tymeslot.Notifications.Email.EndChangeDeliveryOutcomeTest do
  @moduledoc "Verifies end-change snoozes preserve successful claims and the host's reached count."

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :workers

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, user_smtp_enabled: false, email_service_module: EmailServiceMock)
    :ok
  end

  for reason <- [:rate_limited, :circuit_open], role <- [:attendee, :guest, :host] do
    test "#{role} #{reason} snoozes and resumes without repeating reached recipients" do
      meeting = insert(:meeting)
      original_end = DateTime.add(meeting.end_time, -30, :minute)
      meeting = meeting |> Changeset.change(notified_end_time: original_end) |> Repo.update!()
      {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
      guest |> Changeset.change(notified_end_time: original_end) |> Repo.update!()

      if unquote(role) == :attendee do
        expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
          {:error, unquote(reason)}
        end)
      end

      expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      if unquote(role) == :guest do
        expect(EmailServiceMock, :send_guest_end_change, fn _email, _details ->
          {:error, unquote(reason)}
        end)
      end

      expect(EmailServiceMock, :send_guest_end_change, fn _email, _details -> {:ok, :sent} end)

      if unquote(role) == :host do
        expect(EmailServiceMock, :send_end_change_to_organizer, fn _meeting, _email, notice ->
          assert notice.attendees == [meeting.attendee_name]
          assert notice.guests == 1
          {:error, unquote(reason)}
        end)
      end

      expect(EmailServiceMock, :send_end_change_to_organizer, fn _meeting, _email, notice ->
        assert notice.attendees == [meeting.attendee_name]
        assert notice.guests == 1
        assert notice.previous_end_time == original_end
        {:ok, :sent}
      end)

      job =
        %{
          "action" => "send_end_change_emails",
          "meeting_id" => meeting.id,
          "start_time" => DateTime.to_iso8601(meeting.start_time)
        }
        |> EmailWorker.new()
        |> Oban.insert!()

      assert {:snooze, seconds} = EmailWorker.perform(%{job | attempt: 1})
      assert seconds > 0
      assert :ok = EmailWorker.perform(%{job | attempt: 2})
      assert Repo.reload!(meeting).notified_end_time == meeting.end_time
      assert Repo.reload!(guest).notified_end_time == meeting.end_time
    end
  end
end
