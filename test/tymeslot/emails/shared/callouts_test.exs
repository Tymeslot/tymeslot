defmodule Tymeslot.Emails.Shared.CalloutsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Callouts

  describe "alert_box/3" do
    test "output differs between intent atoms" do
      confirmed_html = Callouts.alert_box(:confirmed, "A message")
      alert_html = Callouts.alert_box(:alert, "A message")
      cancelled_html = Callouts.alert_box(:cancelled, "A message")

      assert confirmed_html != alert_html
      assert alert_html != cancelled_html
    end

    test "includes the message text in output" do
      html = Callouts.alert_box(:confirmed, "Please bring your ID")

      assert html =~ "Please bring your ID"
    end

    test "includes a title when :title opt is provided" do
      html = Callouts.alert_box(:confirmed, "Body text", title: "Important")

      assert html =~ "Important"
      assert html =~ "Body text"
    end

    test "omits the title block when no :title opt is given" do
      html_with = Callouts.alert_box(:confirmed, "Body", title: "Heading")
      html_without = Callouts.alert_box(:confirmed, "Body")

      assert html_with =~ "Heading"
      refute html_without =~ "Heading"
      assert String.length(html_without) < String.length(html_with)
    end
  end

  describe "preparation_checklist/3" do
    test "includes all items in the output" do
      items = ["Bring your ID", "Arrive 10 minutes early", "Wear comfortable clothes"]

      html = Callouts.preparation_checklist(:confirmed, items)

      assert html =~ "Bring your ID"
      assert html =~ "Arrive 10 minutes early"
      assert html =~ "Wear comfortable clothes"
    end

    test "returns empty string for an empty item list" do
      assert Callouts.preparation_checklist(:confirmed, []) == ""
    end

    test "uses provided :title option" do
      html = Callouts.preparation_checklist(:confirmed, ["Item one"], title: "What to bring")

      assert html =~ "What to bring"
    end
  end
end
