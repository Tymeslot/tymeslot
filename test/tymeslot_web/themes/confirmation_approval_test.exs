defmodule TymeslotWeb.Themes.ConfirmationApprovalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  The confirmation screen must never tell an invitee their booking is
  confirmed while the meeting is actually held for the host's approval:
  heading, badge, email-sent copy, calendar affordance and closing help
  text all have to agree with the "Not confirmed yet" notice, in both
  themes, and in owner preview where the meeting itself is a mock.
  """
  @moduletag :themes

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Shared.ApprovalDisplay

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent,
    as: QuillConfirmation

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent,
    as: RhythmConfirmation

  describe "ApprovalDisplay.awaiting_approval?/1" do
    test "true when the meeting's own status is awaiting_approval" do
      assert ApprovalDisplay.awaiting_approval?(%{meeting_status: "awaiting_approval"})
    end

    test "false when the meeting's own status is confirmed, even on a gated type" do
      refute ApprovalDisplay.awaiting_approval?(%{
               meeting_status: "confirmed",
               meeting_type: build(:meeting_type, requires_approval: true)
             })
    end

    test "falls back to the meeting type flag when no status has been assigned" do
      assert ApprovalDisplay.awaiting_approval?(%{
               meeting_type: build(:meeting_type, requires_approval: true)
             })

      refute ApprovalDisplay.awaiting_approval?(%{
               meeting_type: build(:meeting_type, requires_approval: false)
             })
    end

    test "owner preview always answers from the meeting type, not the mock status" do
      assert ApprovalDisplay.awaiting_approval?(%{
               owner_preview: true,
               meeting_status: "confirmed",
               meeting_type: build(:meeting_type, requires_approval: true)
             })
    end
  end

  describe "Quill confirmation screen" do
    test "held request: no confirmed-only copy, and held-specific copy instead" do
      html = render_quill(held_assigns())

      assert html =~ "Request sent!"
      assert html =~ "confirmation-badge--pending"
      refute html =~ "Confirmation sent to"
      assert html =~ "Sent to"
      assert html =~ "Add tentative hold to calendar"
      refute html =~ "Add to calendar<"
      assert html =~ "Your request email has a link to withdraw it"
      refute html =~ "Check your confirmation email"
      assert html =~ "your request to"
      refute html =~ "your request with"
    end

    test "confirmed booking: unchanged copy and no pending styling" do
      html = render_quill(confirmed_assigns())

      assert html =~ "Confirmation sent to"
      refute html =~ "confirmation-badge--pending"
      assert html =~ "Add to calendar"
      refute html =~ "Add tentative hold to calendar"
      assert html =~ "Check your confirmation email"
    end

    test "owner preview of a gated type renders the held screen despite the mock status" do
      html =
        render_quill(
          confirmed_assigns()
          |> Map.put(:owner_preview, true)
          |> Map.put(:meeting_type, build(:meeting_type, requires_approval: true))
        )

      assert html =~ "Request sent!"
      assert html =~ "confirmation-badge--pending"
    end
  end

  describe "Rhythm confirmation screen" do
    test "held request: badge and closing text switch, heading says request sent" do
      html = render_rhythm(held_assigns())

      assert html =~ "Request sent!"
      assert html =~ "success-badge-inner--pending"
      assert html =~ "Add tentative hold to calendar"
      refute html =~ "Add to calendar<"
      assert html =~ "Your request email has a link to withdraw it"
      refute html =~ "Check your email for reschedule options"
      assert html =~ "your request to"
      refute html =~ "your request with"
    end

    test "confirmed booking: unchanged copy and no pending styling" do
      html = render_rhythm(confirmed_assigns())

      refute html =~ "success-badge-inner--pending"
      assert html =~ "Add to calendar"
      assert html =~ "Check your email for reschedule options"
    end
  end

  defp held_assigns do
    Map.put(base_assigns(), :meeting_status, "awaiting_approval")
  end

  defp confirmed_assigns do
    Map.put(base_assigns(), :meeting_status, "confirmed")
  end

  defp base_assigns do
    %{
      id: "confirmation-step",
      locale: "en",
      duration: "30-minutes",
      username_context: "hostuser",
      selected_date: "2026-09-10",
      selected_time: "10:00",
      user_timezone: "UTC",
      email: "guest@example.com",
      guest_emails: [],
      name: "Alice",
      organizer_profile: build(:profile, full_name: "Jane Organizer"),
      meeting_type: build(:meeting_type, requires_approval: false),
      meeting_uid: "abc123",
      custom_fields_snapshot: [],
      custom_field_answers: %{},
      is_rescheduling: false
    }
  end

  defp render_quill(assigns), do: render_component(QuillConfirmation, assigns)
  defp render_rhythm(assigns), do: render_component(RhythmConfirmation, assigns)
end
