defmodule Tymeslot.Emails.Shared.Meeting.ActionsBarTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Meeting.ActionsBar
  alias Tymeslot.Emails.Shared.Styles

  describe "meeting_actions_bar/2" do
    test "renders each action's text and URL" do
      actions = [
        %{text: "Reschedule", url: "https://example.com/reschedule"},
        %{text: "Cancel", url: "https://example.com/cancel", style: :danger}
      ]

      html = ActionsBar.meeting_actions_bar(:confirmed, actions)

      assert html =~ "Reschedule"
      assert html =~ "Cancel"
      assert html =~ "https://example.com/reschedule"
      assert html =~ "https://example.com/cancel"
    end

    test "sanitizes XSS in action text" do
      actions = [
        %{text: "<script>alert('xss')</script>Reschedule", url: "https://example.com/"}
      ]

      html = ActionsBar.meeting_actions_bar(:confirmed, actions)

      refute html =~ "<script>alert"
      assert html =~ "Reschedule"
    end

    test "leaves out an action with an unsafe or missing URL" do
      actions = [
        %{text: "Bad link", url: "javascript:alert(1)"},
        %{text: "No link", url: nil},
        %{text: "Good link", url: "https://example.com/good"}
      ]

      html = ActionsBar.meeting_actions_bar(:confirmed, actions)

      refute html =~ "javascript:"
      refute html =~ ~s(href="#")
      refute html =~ "Bad link"
      refute html =~ "No link"
      assert html =~ ~s(href="https://example.com/good")
    end

    test "renders nothing when no action has a URL" do
      assert ActionsBar.meeting_actions_bar(:confirmed, [%{text: "No link", url: nil}]) == ""
    end

    test ":danger style always uses the cancelled intent colour" do
      cancelled_colour = Styles.intent_accent_deep(:cancelled)

      html =
        ActionsBar.meeting_actions_bar(:confirmed, [
          %{text: "Cancel", url: "https://example.com/c", style: :danger}
        ])

      assert html =~ "color: #{cancelled_colour}"
    end

    test ":secondary style uses muted ink regardless of intent" do
      muted = Styles.ink_muted()

      html =
        ActionsBar.meeting_actions_bar(:confirmed, [
          %{text: "Reschedule", url: "https://example.com/r", style: :secondary}
        ])

      assert html =~ "color: #{muted}"
    end

    test ":primary style inherits the surrounding intent's accent" do
      confirmed_colour = Styles.intent_accent_deep(:confirmed)

      html =
        ActionsBar.meeting_actions_bar(:confirmed, [
          %{text: "Reschedule", url: "https://example.com/r", style: :primary}
        ])

      assert html =~ "color: #{confirmed_colour}"
    end

    test "defaults to :primary style when style is omitted" do
      confirmed_colour = Styles.intent_accent_deep(:confirmed)

      html =
        ActionsBar.meeting_actions_bar(:confirmed, [
          %{text: "Reschedule", url: "https://example.com/r"}
        ])

      assert html =~ "color: #{confirmed_colour}"
    end

    test "separates multiple actions with a middle dot" do
      actions = [
        %{text: "Reschedule", url: "https://example.com/r"},
        %{text: "Cancel", url: "https://example.com/c", style: :danger}
      ]

      html = ActionsBar.meeting_actions_bar(:confirmed, actions)

      assert html =~ "·"
    end

    test "renders nothing when no actions are supplied" do
      assert ActionsBar.meeting_actions_bar(:confirmed, []) == ""
    end
  end

  describe "actions_section/4" do
    test "renders the heading and footer only with an action to offer" do
      actions = [%{text: "Go", url: "https://example.com/go"}]

      html = ActionsBar.actions_section(:confirmed, "Heading", actions, footer: "Footnote")

      assert html =~ "Heading"
      assert html =~ "Footnote"
      assert html =~ ~s(href="https://example.com/go")

      assert ActionsBar.actions_section(:confirmed, "Heading", [%{text: "Go", url: nil}],
               footer: "Footnote"
             ) == ""
    end
  end
end
