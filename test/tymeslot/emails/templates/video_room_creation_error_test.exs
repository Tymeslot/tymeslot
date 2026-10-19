defmodule Tymeslot.Emails.Templates.VideoRoomCreationErrorTest do
  # Not async: the sent email is captured through Swoosh's global
  # `:shared_test_process`.
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :video

  alias Tymeslot.Emails.EmailService.IntegrationEmails
  alias Tymeslot.Emails.Templates.VideoRoomCreationError

  @user %{id: 1, email: "owner@example.com", name: "Olivia"}

  describe "render/2" do
    test "explains the refusal with its fix and links to the video settings" do
      integration = %{provider: "nextcloud_talk", room_creation_error: :password_required}

      email = VideoRoomCreationError.render(@user, integration)
      %{html_body: html, text_body: text} = email

      assert email.to == [{"Olivia", "owner@example.com"}]
      assert email.subject == "Bookings on Nextcloud Talk are getting no video link"

      for body <- [html, text] do
        assert body =~ "turn off the password requirement for public conversations"
        assert body =~ "Nextcloud Talk refused to create a video room"
        # Nothing about a booking: a calendar grid event gets its room the same
        # way, and the same email.
        refute body =~ "its confirmation went out"
        assert body =~ "/dashboard/integrations?tab=video"
      end

      assert html =~ "<!doctype html>"
      assert html =~ "in 30 days, you will hear about it again"
      refute text =~ "<mj-"
    end

    test "names the refusal it was sent for" do
      integration = %{provider: "nextcloud_talk", room_creation_error: :talk_not_allowed}

      %{text_body: text} = VideoRoomCreationError.render(@user, integration)

      assert text =~ "may not use Talk"
      refute text =~ "password requirement"
    end
  end

  describe "the resend window" do
    @singular "This is the only email you will get about this for now. If the same problem is still there in %{count} day, you will hear about it again. Your video settings show the notice for as long as it lasts."
    @plural "This is the only email you will get about this for now. If the same problem is still there in %{count} days, you will hear about it again. Your video settings show the notice for as long as it lasts."

    # One, few and many, as each locale's plural rule picks them.
    @forms %{
      "en" => {"1 day,", "3 days,", "30 days,"},
      "cs" => {"1 den", "3 dny", "30 dní"},
      "de" => {"1 Tag", "3 Tagen", "30 Tagen"},
      "fr" => {"1 jour", "3 jours", "30 jours"},
      "it" => {"1 giorno", "3 giorni", "30 giorni"},
      "pl" => {"1 dzień", "3 dni", "30 dni"},
      "pt" => {"1 dia", "3 dias", "30 dias"},
      "uk" => {"1 день", "3 дні", "30 днів"}
    }

    for {locale, {one, few, many}} <- @forms do
      test "counts days in the singular and the plural in #{locale}" do
        sentences =
          Gettext.with_locale(TymeslotWeb.Gettext, unquote(locale), fn ->
            for count <- [1, 3, 30] do
              Gettext.dngettext(
                TymeslotWeb.Gettext,
                "emails_integrations",
                @singular,
                @plural,
                count
              )
            end
          end)

        assert [singular, few, many] = sentences
        assert singular =~ whole(unquote(one))
        assert few =~ whole(unquote(few))
        assert many =~ whole(unquote(many))
      end
    end

    # The form as a whole word, so "1 Tag" does not match "1 Tagen".
    defp whole(form),
      do: Regex.compile!("(?<![\\p{L}\\d])" <> Regex.escape(form) <> "(?!\\p{L})", "u")

    test "is rendered with the plural form of its 30 days" do
      user = Map.put(@user, :locale, "uk")
      integration = %{provider: "nextcloud_talk", room_creation_error: :password_required}

      %{text_body: text} = VideoRoomCreationError.render(user, integration)

      assert text =~ "30 днів"
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
