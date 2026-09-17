defmodule Tymeslot.Emails.Templates.VideoRoomCreationErrorTest do
  # Not async: the sent email is captured through Swoosh's global
  # `:shared_test_process`.
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :video

  alias Tymeslot.Emails.EmailService.IntegrationEmails
  alias Tymeslot.Emails.Templates.VideoRoomCreationError

  describe "render_both/1" do
    test "explains the refusal with its fix and links to the video settings" do
      integration = %{provider: "nextcloud_talk", room_creation_error: :password_required}

      {html, text} = VideoRoomCreationError.render_both(integration)

      for body <- [html, text] do
        assert body =~ "turn off the password requirement for public conversations"
        assert body =~ "Nextcloud Talk refused to create a video room for a booking"
        assert body =~ "/dashboard/settings?tab=video"
      end

      assert html =~ "<!doctype html>"
      refute text =~ "<mj-"
    end

    test "names the refusal it was sent for" do
      integration = %{provider: "nextcloud_talk", room_creation_error: :talk_not_allowed}

      {_html, text} = VideoRoomCreationError.render_both(integration)

      assert text =~ "may not use Talk"
      refute text =~ "password requirement"
    end
  end

  describe "sending" do
    setup do
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    end

    test "goes to the owner in their own language" do
      user = insert(:user, email: "owner@example.com", name: "Olivia", locale: "de")

      integration = %{
        id: 1,
        provider: "nextcloud_talk",
        room_creation_error: :conversation_creation_restricted
      }

      assert {:ok, _result} =
               IntegrationEmails.send_video_room_creation_error_notification(user, integration)

      assert_received {:email, email}
      assert email.to == [{"Olivia", "owner@example.com"}]
      assert email.subject =~ "Nextcloud Talk"
      refute email.subject == "Bookings on Nextcloud Talk are getting no video link"
    end
  end
end
