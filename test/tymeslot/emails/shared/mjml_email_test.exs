defmodule Tymeslot.Emails.Shared.MjmlEmailTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.MjmlEmail

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

      assert is_binary(html)
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

  describe "base_email/0" do
    test "creates email with correct from address" do
      email = MjmlEmail.base_email()

      assert %Swoosh.Email{} = email
      assert email.from != nil
      {name, address} = email.from
      assert is_binary(name)
      assert is_binary(address)
    end

    test "sets provider options for tracking" do
      email = MjmlEmail.base_email()

      assert email.provider_options[:track_opens] == true
      assert email.provider_options[:track_links] == "HtmlAndText"
    end
  end

  describe "fetch_from_email/0" do
    test "returns a valid email address" do
      email = MjmlEmail.fetch_from_email()

      assert is_binary(email)
      assert email =~ ~r/@/
    end
  end

  describe "fetch_from_name/0" do
    test "returns a non-empty string" do
      name = MjmlEmail.fetch_from_name()

      assert is_binary(name)
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

      assert is_binary(mjml)
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
end
