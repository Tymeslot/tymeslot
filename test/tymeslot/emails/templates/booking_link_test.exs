defmodule Tymeslot.Emails.Templates.BookingLinkTest do
  # async: false: `:shared_test_process` is global, and the delivery test
  # swaps the email service for the real one.
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :onboarding

  import Mox
  import Oban.Testing, only: [perform_job: 3]

  alias Tymeslot.Emails.Templates.BookingLink
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Repo
  alias Tymeslot.Utils.QrCode
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  @url "https://example.com/anna"

  # The base email carries the logo as an inline attachment too.
  defp qr_attachment(email) do
    assert [qr] = Enum.filter(email.attachments, &(&1.filename == "booking-link-qr.png"))
    qr
  end

  describe "BookingLink.render/2" do
    test "renders the link, the signature line and the dashboard link" do
      user = %{id: 1, name: "Anna", email: "anna@example.com", locale: "en"}

      email = BookingLink.render(user, @url)

      assert email.subject == "Your booking link"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "/anna"
        assert body =~ "Book a time with me:"
        assert body =~ "/dashboard"
      end

      assert email.text_body =~ "Book a time with me: #{@url}"
    end

    test "renders in the user's locale" do
      user = %{id: 1, name: "Anna", email: "anna@example.com", locale: "de"}

      assert BookingLink.render(user, @url).subject == "Ihr Buchungslink"
    end

    test "references the QR code by cid, never as a data URI" do
      user = %{id: 1, name: "Anna", email: "anna@example.com", locale: "en"}

      email = BookingLink.render(user, @url)

      qr = qr_attachment(email)

      assert %{type: :inline, content_type: "image/png", data: <<0x89, "PNG", _rest::binary>>} =
               qr

      assert email.html_body =~ "cid:#{qr.cid}"
      refute email.html_body =~ "data:image"
    end
  end

  describe "Tymeslot.Utils.QrCode" do
    test "returns a PNG and an SVG data URI" do
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = QrCode.png(@url)
      assert String.starts_with?(QrCode.svg_data_uri(@url), "data:image/svg+xml;base64,")
    end
  end

  describe "the booking link job" do
    setup do
      stub_with(Tymeslot.EmailServiceMock, Tymeslot.Emails.EmailService)
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    end

    test "delivers to the host, with the QR code inline" do
      user = insert(:user, email: "anna@example.com")
      insert(:profile, user: user, username: "anna")

      assert :ok =
               perform_job(
                 EmailWorker,
                 %{"action" => "send_booking_link_email", "user_id" => user.id},
                 repo: Repo
               )

      assert_received {:email, email}
      assert email.to == [{user.name || user.email, "anna@example.com"}]
      assert email.subject == "Your booking link"
      assert email.text_body =~ "/anna"
      qr = qr_attachment(email)
      assert qr.type == :inline
      assert email.html_body =~ "cid:#{qr.cid}"
    end

    test "a host without a username gets an error and no email" do
      user = insert(:user)
      insert(:profile, user: user, username: nil)

      assert {:error, _reason} =
               perform_job(
                 EmailWorker,
                 %{"action" => "send_booking_link_email", "user_id" => user.id},
                 repo: Repo
               )

      assert {:error, :no_username} =
               EmailHandlers.execute_email_action(
                 "send_booking_link_email",
                 %{"user_id" => user.id}
               )

      refute_received {:email, _email}
    end
  end
end
