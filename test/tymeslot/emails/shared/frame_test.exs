defmodule Tymeslot.Emails.Shared.FrameTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Frame

  @base_sections %{
    title: "Test Email",
    preview: "A short preview",
    stage: "<mj-section><mj-column><mj-text>Stage</mj-text></mj-column></mj-section>",
    header: "<mj-section><mj-column><mj-text>Header</mj-text></mj-column></mj-section>",
    body: "<mj-section><mj-column><mj-text>Body content</mj-text></mj-column></mj-section>",
    footer: "<mj-section><mj-column><mj-text>Footer</mj-text></mj-column></mj-section>"
  }

  describe "wrap/1" do
    test "returns non-empty MJML with all required keys" do
      mjml = Frame.wrap(@base_sections)

      assert String.length(mjml) > 100
      assert mjml =~ "<mjml>"
      assert mjml =~ "</mjml>"
    end

    test "includes title and preview in the head" do
      mjml = Frame.wrap(@base_sections)

      assert mjml =~ "Test Email"
      assert mjml =~ "A short preview"
    end

    test "includes the body content in the output" do
      mjml = Frame.wrap(@base_sections)

      assert mjml =~ "Body content"
    end

    test "omits pre_card section when optional key is absent" do
      mjml_without = Frame.wrap(@base_sections)
      mjml_with = Frame.wrap(Map.put(@base_sections, :pre_card, "<mj-section>Pre</mj-section>"))

      refute mjml_without =~ "Pre"
      assert mjml_with =~ "Pre"
    end

    test "includes pre_card content when optional key is present" do
      sections =
        Map.put(
          @base_sections,
          :pre_card,
          "<mj-section><mj-column><mj-text>Announcement</mj-text></mj-column></mj-section>"
        )

      mjml = Frame.wrap(sections)

      assert mjml =~ "Announcement"
    end
  end
end
