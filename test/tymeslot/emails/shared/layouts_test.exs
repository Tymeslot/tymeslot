defmodule Tymeslot.Emails.Shared.LayoutsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Layouts

  describe "system_layout/2" do
    test "escapes ampersand in title exactly once when stage_title is absent" do
      mjml =
        Layouts.system_layout(
          "<mj-section><mj-column><mj-text>Body</mj-text></mj-column></mj-section>",
          intent: :confirmed,
          eyebrow: "Notification",
          title: "Tom & Jerry"
        )

      assert mjml =~ "Tom &amp; Jerry"
      refute mjml =~ "Tom &amp;amp; Jerry"
    end

    test "escapes ampersand in explicit stage_title exactly once" do
      mjml =
        Layouts.system_layout(
          "<mj-section><mj-column><mj-text>Body</mj-text></mj-column></mj-section>",
          intent: :confirmed,
          eyebrow: "Notification",
          title: "Tymeslot",
          stage_title: "R&D Update"
        )

      assert mjml =~ "R&amp;D Update"
      refute mjml =~ "R&amp;amp;D Update"
    end
  end

  describe "simple_layout/2" do
    test "escapes ampersand in title exactly once" do
      mjml =
        Layouts.simple_layout("<p>Body</p>",
          intent: :confirmed,
          eyebrow: "Notice",
          title: "Terms & Conditions"
        )

      assert mjml =~ "Terms &amp; Conditions"
      refute mjml =~ "Terms &amp;amp; Conditions"
    end
  end
end
