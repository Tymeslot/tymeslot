defmodule Tymeslot.Emails.Shared.MjmlEmailTest do
  use Tymeslot.DataCase, async: true

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
    test "generates valid MJML with default organizer details" do
      content = "<mj-text>Test Content</mj-text>"
      mjml = MjmlEmail.base_mjml_template(content)

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
        title: "CEO"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "John Doe"
      assert mjml =~ "CEO"
    end

    test "generates default avatar URL when not provided" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        name: "Jane Smith"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "data:image/svg+xml;base64"
      assert mjml =~ "Jane Smith"
    end

    test "uses provided avatar URL" do
      content = "<mj-text>Test</mj-text>"

      organizer_details = %{
        name: "John Doe",
        avatar_url: "https://example.com/avatar.jpg"
      }

      mjml = MjmlEmail.base_mjml_template(content, organizer_details)

      assert mjml =~ "https://example.com/avatar.jpg"
    end

    test "includes standard email sections" do
      content = "<mj-text>Body Content</mj-text>"
      mjml = MjmlEmail.base_mjml_template(content)

      # Check for header, content, and footer sections
      assert mjml =~ "<mj-head>"
      assert mjml =~ "<mj-body"
      assert mjml =~ "Sent by"
      assert mjml =~ "Tymeslot"
    end

    test "includes Inter font" do
      content = "<mj-text>Test</mj-text>"
      mjml = MjmlEmail.base_mjml_template(content)

      assert mjml =~ "Inter"
      assert mjml =~ "fonts.googleapis.com"
    end
  end
end
