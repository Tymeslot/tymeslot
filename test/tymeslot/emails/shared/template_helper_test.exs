defmodule Tymeslot.Emails.Shared.TemplateHelperTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.TemplateHelper

  describe "compile_system_template/3" do
    test "uses default preview when preview is nil" do
      content = "<mj-text>Test content</mj-text>"
      html = TemplateHelper.compile_system_template(content, "Test Title", nil)

      # Should use default preview text from system_layout
      assert html =~ "Important notification from Tymeslot"
    end

    test "uses provided preview when not nil" do
      content = "<mj-text>Test content</mj-text>"
      html = TemplateHelper.compile_system_template(content, "Test Title", "Custom preview text")

      assert html =~ "Custom preview text"
    end

    test "sanitizes title" do
      content = "<mj-text>Test</mj-text>"
      html = TemplateHelper.compile_system_template(content, "<script>Title</script>", nil)

      refute html =~ "<script>Title</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "compiles valid HTML output" do
      content = "<mj-text>Hello World</mj-text>"
      html = TemplateHelper.compile_system_template(content, "Test", "Preview")

      assert is_binary(html)
      assert html =~ "<!doctype html>"
      assert html =~ "Hello World"
    end
  end
end
