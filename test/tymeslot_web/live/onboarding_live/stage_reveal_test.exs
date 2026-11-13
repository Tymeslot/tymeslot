defmodule TymeslotWeb.OnboardingLive.StageRevealTest do
  @moduledoc """
  The stage's times reveal once per new week. The list's id carries the
  stage's `reveal_key`, so a bumped key gives the page a new list, whose
  times enter with the reveal, while any other re-render patches the same
  list in place. The preview is mounted in a small LiveView here so the
  ids can be followed across renders.
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

  # The id of the revealing times list, which must be the only one.
  defp times_id(html) do
    assert [list] = html |> Floki.parse_fragment!() |> Floki.find("[data-reveal]")
    assert [id] = Floki.attribute(list, "id")
    assert Floki.find(list, "[data-reveal-item]") != []
    id
  end

  test "only a new reveal key gives the times a new list to reveal", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, StageHost, session: %{"week" => @week})

    assert times_id(render(view)) == "stage-times-1"

    # The same week, re-rendered for another reason: the same list, patched
    # in place, so its reveal neither replays nor stops short.
    send(view.pid, {:assign, name: "Ada Lovelace"})
    html = render(view)
    assert html =~ "Ada Lovelace"
    assert times_id(html) == "stage-times-1"

    # Two new weeks in a row: a new list each time.
    send(view.pid, {:assign, reveal_key: 2})
    assert times_id(render(view)) == "stage-times-2"
    send(view.pid, {:assign, reveal_key: 3})
    assert times_id(render(view)) == "stage-times-3"
  end

  test "the stage and its expanded copy never share an id" do
    ids =
      for id <- ["stage", "stage-expanded"] do
        times_id(
          render_component(&LivePreview.live_preview/1,
            current_step: :connect_calendar,
            booking_host: "tymeslot.test",
            week: @week,
            reveal_key: 4,
            today: ~D[2026-11-03],
            id: id
          )
        )
      end

    assert ids == ["stage-times-4", "stage-expanded-times-4"]
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
