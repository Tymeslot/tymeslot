defmodule Tymeslot.Emails.Shared.MjmlEmailTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Mailer

  describe "compile_mjml/1" do
    test "compiles valid MJML to HTML" do
      mjml = """
      <mjml>
        <mj-body>
          <mj-section>
            <mj-column>
              <mj-text>Hello World</mj-text>
            </mj-column>
          </mj-section>
        </mj-body>
      </mjml>
      """

      html = MjmlEmail.compile_mjml(mjml)

      assert html =~ "Hello World"
      assert html =~ "<!doctype html>"
    end

    test "raises error on invalid MJML" do
      invalid_mjml = "<mjml><invalid-tag></invalid-tag></mjml>"

      assert_raise RuntimeError, ~r/MJML compilation failed/, fn ->
        MjmlEmail.compile_mjml(invalid_mjml)
      end
    end
  end

  describe "base_email/1" do
    test "creates email with correct from address" do
      email = MjmlEmail.base_email()

      assert %Swoosh.Email{} = email
      assert email.from == {configured(:from_name), configured(:from_email)}
    end

    test "attaches the logo with a Content-ID equal to its filename" do
      # SendGrid derives content_id from the filename (ignoring `cid:`), and
      # Mailgun drops `cid:` entirely and keys inline images by filename, so
      # cid and filename must match for the logo to render on every provider.
      email = MjmlEmail.base_email()

      assert [%Swoosh.Attachment{filename: filename, cid: cid}] = email.attachments
      assert filename == cid
      assert cid == MjmlEmail.logo_cid()
    end

    test "references the logo in the HTML body via cid:<filename>" do
      mjml = MjmlEmail.logo_header()

      assert mjml =~ "src=\"cid:#{MjmlEmail.logo_cid()}\""
    end
  end

  describe "base_email/1 tracking" do
    test "defaults to :transactional" do
      email = MjmlEmail.base_email()

      assert Mailer.tracking(email) == :transactional
    end

    test "stashes :lifecycle when given explicitly" do
      email = MjmlEmail.base_email(tracking: :lifecycle)

      assert Mailer.tracking(email) == :lifecycle
    end

    test "stashes :marketing when given explicitly" do
      email = MjmlEmail.base_email(tracking: :marketing)

      assert Mailer.tracking(email) == :marketing
    end

    test "carries no provider options at build time — translation happens at delivery" do
      email = MjmlEmail.base_email(tracking: :marketing)

      assert email.provider_options == %{}
    end
  end

  describe "fetch_from_email/0" do
    test "returns a valid email address" do
      email = MjmlEmail.fetch_from_email()

      assert email == configured(:from_email)
      assert email =~ ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/
    end
  end

  describe "fetch_from_name/0" do
    test "returns a non-empty string" do
      name = MjmlEmail.fetch_from_name()

      assert name == configured(:from_name)
      assert String.length(name) > 0
    end
  end

  describe "base_mjml_template/2" do
    test "generates valid MJML with organizer details" do
      content = "<mj-text>Test Content</mj-text>"

      organizer_details = %{
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "<mjml>"
      assert mjml =~ "</mjml>"
      assert mjml =~ "Test Content"
      assert mjml =~ "Tymeslot"
    end

    test "uses provided organizer details" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        name: "John Doe",
        email: "john@example.com",
        title: "CEO",
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "John Doe"
      assert mjml =~ "CEO"
    end

    test "generates default avatar URL when not provided" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        name: "Jane Smith",
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "data:image/svg+xml;base64"
      assert mjml =~ "Jane Smith"
    end

    test "uses provided avatar URL" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        name: "John Doe",
        avatar_url: "https://example.com/avatar.jpg",
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "https://example.com/avatar.jpg"
    end

    test "includes standard email sections" do
      content = "<mj-text>Body Content</mj-text>"

      organizer_details = %{
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      # Check for header, content, and footer sections
      assert mjml =~ "<mj-head>"
      assert mjml =~ "<mj-body"
      assert mjml =~ "Sent with care by"
      assert mjml =~ "Tymeslot"
    end

    test "includes Inter font" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "Inter"
      assert mjml =~ "fonts.googleapis.com"
    end

    test "escapes ampersand in organizer name exactly once when stage_title is absent" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        name: "Tom & Jerry",
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "Tom &amp; Jerry"
      refute mjml =~ "Tom &amp;amp; Jerry"
    end

    test "escapes ampersand in explicit stage_title exactly once" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        name: "Tom & Jerry",
        stage_title: "R&D",
        intent: :confirmed,
        eyebrow: "Confirmed"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "R&amp;D"
      refute mjml =~ "R&amp;amp;D"
    end
  end

  # Reads the sender identity from config rather than the module under test, so
  # the assertions stay independent of MjmlEmail's own accessors.
  defp configured(key), do: Application.get_env(:tymeslot, :email)[key]
end
