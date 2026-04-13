defmodule Tymeslot.Emails.Templates.RescheduleRequestTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.RescheduleRequest

  import Tymeslot.Factory

  describe "RescheduleRequest.render/1" do
    test "creates valid Swoosh email with text_body" do
      meeting = insert(:meeting)
      email = RescheduleRequest.render(meeting)

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.html_body != nil
      assert email.text_body != nil
      assert email.text_body =~ "Reschedule Request"
      assert email.text_body =~ "Choose a New Time"
    end

    test "sets correct recipient as attendee" do
      meeting =
        insert(:meeting, attendee_name: "Sarah Johnson", attendee_email: "sarah@example.com")

      email = RescheduleRequest.render(meeting)

      assert email.to == [{"Sarah Johnson", "sarah@example.com"}]
    end

    test "includes subject with meeting title and date" do
      meeting = insert(:meeting, title: "Product Demo")
      email = RescheduleRequest.render(meeting)

      assert email.subject =~ "Reschedule"
      assert email.subject =~ "Product Demo"
    end

    test "includes attendee name in HTML body" do
      meeting = insert(:meeting, attendee_name: "Michael Chen")
      email = RescheduleRequest.render(meeting)

      assert email.html_body =~ "Michael Chen"
    end

    test "includes meeting details" do
      meeting =
        insert(:meeting,
          location: "Video Conference",
          duration: 45,
          meeting_type: "Consultation"
        )

      email = RescheduleRequest.render(meeting)

      # Should contain substantial meeting information
      assert String.length(email.html_body) > 1000
    end

    test "includes reschedule URL" do
      email_config = Application.get_env(:tymeslot, :email)
      domain = email_config[:domain] || "tymeslot.app"
      reschedule_url = "https://#{domain}/reschedule/token123"
      meeting = insert(:meeting, reschedule_url: reschedule_url)
      email = RescheduleRequest.render(meeting)

      assert email.html_body =~ reschedule_url
    end

    test "includes call to action button" do
      meeting = insert(:meeting)
      email = RescheduleRequest.render(meeting)

      assert email.html_body =~ "Choose" || email.html_body =~ "New Time" ||
               email.html_body =~ "reschedule"
    end

    test "converts time to attendee timezone" do
      meeting = insert(:meeting, attendee_timezone: "America/New_York")
      email = RescheduleRequest.render(meeting)

      assert email.html_body != nil
      # Should contain time information
      assert String.length(email.html_body) > 1000
    end

    test "handles missing attendee timezone with UTC fallback" do
      meeting = insert(:meeting, attendee_timezone: nil)
      email = RescheduleRequest.render(meeting)

      assert %Swoosh.Email{} = email
      assert email.html_body != nil
    end

    test "includes apology and explanation text" do
      meeting = insert(:meeting)
      email = RescheduleRequest.render(meeting)

      assert email.html_body =~ "apologize" || email.html_body =~ "inconvenience" ||
               email.html_body =~ "cancelled"
    end

    test "includes organizer information in from field" do
      meeting = insert(:meeting, organizer_name: "Dr. Lisa Anderson")
      email = RescheduleRequest.render(meeting)

      assert email.from ==
               {"Dr. Lisa Anderson", Application.get_env(:tymeslot, :email)[:from_email]}
    end

    test "handles various meeting types" do
      meeting_types = ["Discovery Call", "Demo", "Consultation", "Interview"]

      for type <- meeting_types do
        meeting = insert(:meeting, meeting_type: type)
        email = RescheduleRequest.render(meeting)

        assert %Swoosh.Email{} = email
        assert email.html_body != nil
      end
    end

    test "raises FunctionClauseError when reschedule_url is nil" do
      meeting = insert(:meeting, reschedule_url: nil)

      assert_raise FunctionClauseError, fn ->
        RescheduleRequest.render(meeting)
      end
    end
  end

  describe "RescheduleRequest locale rendering" do
    test "renders without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr"] do
        meeting = insert(:meeting, attendee_locale: locale)
        email = RescheduleRequest.render(meeting)

        assert %Swoosh.Email{} = email,
               "Expected valid Swoosh email for locale #{locale}"

        assert is_binary(email.html_body),
               "Expected html_body for locale #{locale}"

        assert is_binary(email.text_body),
               "Expected text_body for locale #{locale}"
      end
    end

    test "German reschedule request translates subject and body" do
      meeting = insert(:meeting, attendee_locale: "de")
      email = RescheduleRequest.render(meeting)

      assert email.subject =~ "Verschiebungsanfrage"
      refute email.subject =~ "Reschedule Request"
      assert email.text_body =~ "Anfrage zur Terminverschiebung"
    end

    test "French reschedule request translates subject and body" do
      meeting = insert(:meeting, attendee_locale: "fr")
      email = RescheduleRequest.render(meeting)

      assert email.subject =~ "Demande de report"
      refute email.subject =~ "Reschedule Request"
      assert email.text_body =~ "Demande de report"
    end

    test "Ukrainian reschedule request translates subject and body" do
      meeting = insert(:meeting, attendee_locale: "uk")
      email = RescheduleRequest.render(meeting)

      assert email.subject =~ "Запит на перенесення"
      refute email.subject =~ "Reschedule Request"
      assert email.text_body =~ "Запит на перенесення"
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input and the expected structural content is always present.

    test "RescheduleRequest text_body is always present and contains expected structure with malicious attendee name" do
      meeting = insert(:meeting, attendee_name: "<script>steal()</script>")
      email = RescheduleRequest.render(meeting)

      assert is_binary(email.text_body)
      assert email.text_body =~ "Choose a New Time"
    end
  end
end
