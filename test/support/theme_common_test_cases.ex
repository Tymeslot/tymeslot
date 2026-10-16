defmodule TymeslotWeb.ThemeCommonTestCases do
  @moduledoc """
  The contract every registered theme honours, asserted for each theme in
  `TymeslotWeb.ThemeTestMatrix` by `theme_contract_test.exs`.

  Each function raises on the first failed expectation and returns `:ok`, so
  a call site asserts that it ran to completion.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @doc "The theme's LiveView module exists and is a LiveView."
  @spec test_live_view_module(module()) :: :ok
  def test_live_view_module(theme_module) do
    live_view = theme_module.live_view_module()

    assert Code.ensure_loaded?(live_view), "#{inspect(live_view)} does not exist"
    assert function_exported?(live_view, :__live__, 0), "#{inspect(live_view)} is no LiveView"
    assert %{kind: :view} = live_view.__live__()
    :ok
  end

  @doc "`metadata/0` names a preview image that exists and a description."
  @spec test_metadata(module()) :: :ok
  def test_metadata(theme_module) do
    assert %{preview_image: "/" <> _rest = image, description: description} =
             theme_module.metadata()

    assert is_binary(description) and description != ""

    path = Path.join(Application.app_dir(:tymeslot, "priv/static"), image)
    assert File.exists?(path), "preview image #{image} is not under priv/static"
    :ok
  end

  @doc "`render_meeting_action/2` renders the three meeting pages and rejects others."
  @spec test_render_meeting_action(module(), map()) :: :ok
  def test_render_meeting_action(theme_module, assigns) do
    reschedule = render(&theme_module.render_meeting_action(&1, :reschedule), assigns)
    assert reschedule =~ "Reschedule Appointment"
    assert reschedule =~ "Select a new time for your meeting"
    refute reschedule =~ "Yes, Cancel Meeting"

    cancel = render(&theme_module.render_meeting_action(&1, :cancel), assigns)
    assert cancel =~ "Cancel Appointment"
    assert cancel =~ "Are you sure you want to cancel this appointment?"
    assert cancel =~ "Yes, Cancel Meeting"
    assert cancel =~ "Keep Meeting"

    kept =
      render(
        &theme_module.render_meeting_action(&1, :cancel),
        Map.put(assigns, :meeting_kept, true)
      )

    assert kept =~ "Meeting Confirmed"
    assert kept =~ "Great! Your meeting is still scheduled as planned."
    refute kept =~ "Yes, Cancel Meeting"

    cancel_confirmed = render(&theme_module.render_meeting_action(&1, :cancel_confirmed), assigns)
    assert cancel_confirmed =~ "Meeting Cancelled"
    assert cancel_confirmed =~ "Your meeting has been successfully cancelled."
    assert cancel_confirmed =~ "Schedule a New Meeting"
    refute cancel_confirmed =~ "Are you sure you want to cancel this appointment?"

    assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
      theme_module.render_meeting_action(assigns, :invalid)
    end

    :ok
  end

  @doc "`render_poll_action/1` renders the shared poll body in the theme's shell."
  @spec test_render_poll_action(module(), map()) :: :ok
  def test_render_poll_action(theme_module, assigns) do
    poll = %{
      title: "Roadmap sync",
      description: nil,
      timezone: "Etc/UTC",
      status: :open,
      deadline_at: nil,
      time_slots: []
    }

    html =
      render(
        &theme_module.render_poll_action/1,
        Map.merge(assigns, %{poll: poll, tallies: %{}, voting_open: false, participant: nil})
      )

    assert html =~ ~s(data-testid="poll-voting")
    assert html =~ "Roadmap sync"
    assert html =~ "Voting has closed."
    :ok
  end

  @doc "`render_payment_page/2` renders both payment return pages."
  @spec test_render_payment_page(module(), map()) :: :ok
  def test_render_payment_page(theme_module, assigns) do
    processing =
      render(
        &theme_module.render_payment_page(&1, :processing),
        Map.merge(assigns, %{loading: true, payment: nil, meeting: nil, rebook_path: nil})
      )

    assert processing =~ "Confirming your payment"

    cancelled =
      render(
        &theme_module.render_payment_page(&1, :cancelled),
        Map.merge(assigns, %{loading: false, meeting: nil, rebook_path: "/host/consult"})
      )

    assert cancelled =~ "Payment cancelled"
    assert cancelled =~ ~s(href="/host/consult")
    :ok
  end

  @doc "Builds the base assigns every theme page expects."
  @spec build_meeting_assigns(String.t()) :: map()
  def build_meeting_assigns(theme_id) do
    %{
      meeting: %{
        uid: "test-123",
        start_time: ~U[2026-02-20 10:00:00Z],
        duration: 30,
        organizer_name: "Test User",
        attendee_timezone: "UTC"
      },
      organizer_profile: %{username: "testuser"},
      theme_tokens:
        ThemeCustomizations.tokens(theme_id, %ThemeCustomizationSchema{
          theme_id: theme_id,
          settings: %{
            "color_scheme" => "turquoise",
            "background_type" => "gradient",
            "background_value" => "gradient_1"
          }
        }),
      locale: "en",
      language_dropdown_open: false,
      loading: false,
      meeting_kept: false
    }
  end

  # A page renders as LiveView renders it, from assigns that carry change
  # tracking, never from a bare map.
  defp render(page, assigns), do: render_component(page, assigns)
end
