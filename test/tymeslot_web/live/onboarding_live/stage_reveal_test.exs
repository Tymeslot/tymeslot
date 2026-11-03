defmodule TymeslotWeb.OnboardingLive.StageRevealTest do
  @moduledoc """
  The stage's times reveal once per new week: on the render where
  `reveal_key` changed, and never on a later re-render of the same week.
  Change tracking only exists inside a LiveView, so the preview is mounted
  in a small one here.
  """

  use TymeslotWeb.LiveCase, async: true
  @moduletag :onboarding

  import Phoenix.LiveViewTest

  alias Tymeslot.Availability.WeekPreview
  alias TymeslotWeb.OnboardingLive.LivePreview

  defmodule StageHost do
    @moduledoc false
    use Phoenix.LiveView

    alias TymeslotWeb.OnboardingLive.LivePreview

    @impl Phoenix.LiveView
    def mount(_params, %{"week" => week}, socket) do
      {:ok, assign(socket, week: week, reveal_key: 1, name: "Ada")}
    end

    @impl Phoenix.LiveView
    def handle_info({:assign, changes}, socket), do: {:noreply, assign(socket, changes)}

    @impl Phoenix.LiveView
    def render(assigns) do
      ~H"""
      <LivePreview.live_preview
        current_step={:connect_calendar}
        booking_host="tymeslot.test"
        name={@name}
        week={@week}
        reveal_key={@reveal_key}
        today={~D[2026-11-03]}
      />
      """
    end
  end

  @week %{
    state: :ready,
    preview: %WeekPreview{
      days: [%{date: ~D[2026-11-03], slots: ["09:00", "09:30"], busy: []}],
      slot_count: 2,
      first_busy: nil
    }
  }

  defp revealing?(view) do
    view |> render() |> Floki.parse_fragment!() |> Floki.find("[data-reveal]") != []
  end

  test "the reveal attribute is only present on the transition render", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, StageHost, session: %{"week" => @week})

    assert revealing?(view)

    # The same week, re-rendered for another reason: no second reveal.
    send(view.pid, {:assign, name: "Ada Lovelace"})
    refute revealing?(view)
    assert render(view) =~ "Ada Lovelace"

    # A new week arrives: it reveals again.
    send(view.pid, {:assign, reveal_key: 2})
    assert revealing?(view)
  end

  test "the times carry the reveal stagger" do
    html =
      render_component(&LivePreview.live_preview/1,
        current_step: :connect_calendar,
        booking_host: "tymeslot.test",
        week: @week,
        today: ~D[2026-11-03]
      )

    assert html =~ "--reveal-index: 0;"
    assert html =~ "--reveal-index: 1;"
  end
end
