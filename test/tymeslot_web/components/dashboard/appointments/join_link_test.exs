defmodule TymeslotWeb.Components.Dashboard.Appointments.JoinLinkTest do
  @moduledoc """
  Covers the Join link and the live countdown, whose markup is the contract
  the `AgendaCountdown` hook reads: the start and end, the translated band
  templates, and the id of the Join link it reveals.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :dashboard
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Components.Dashboard.Appointments.JoinLink

  defp entry(attrs \\ []) do
    struct!(
      %Entry{
        id: "meeting-1",
        source: :tymeslot,
        title: "Discovery call",
        day: ~D[2026-02-05],
        start_at: ~U[2026-02-05 14:30:00Z],
        end_at: ~U[2026-02-05 15:00:00Z],
        all_day?: false,
        join_url: "https://zoom.us/j/1"
      },
      attrs
    )
  end

  defp attr(doc, selector, name),
    do: doc |> Floki.find(selector) |> Floki.attribute(name) |> List.first()

  describe "join_link/1" do
    test "opens the call in a new tab without reaching a clickable row around it" do
      doc =
        Floki.parse_fragment!(render_component(&JoinLink.join_link/1, url: "https://zoom.us/j/1"))

      assert attr(doc, "a", "href") == "https://zoom.us/j/1"
      assert attr(doc, "a", "target") == "_blank"
      assert attr(doc, "a", "rel") == "noopener noreferrer"
      # An empty JS command: a click binding of its own that does nothing.
      assert attr(doc, "a", "phx-click") == "[]"
      assert Floki.text(doc) =~ "Join meeting"
      refute attr(doc, "a", "class") =~ "hidden"
    end

    test "renders hidden for the countdown to reveal" do
      html =
        render_component(&JoinLink.join_link/1, url: "https://zoom.us/j/1", id: "j", hidden: true)

      doc = Floki.parse_fragment!(html)

      assert attr(doc, "a#j", "class") =~ "hidden"
    end
  end

  describe "agenda_countdown/1" do
    defp countdown(entry) do
      Floki.parse_fragment!(
        render_component(&JoinLink.agenda_countdown/1, entry: entry, id_prefix: "agenda-cockpit")
      )
    end

    test "carries what the hook needs and names the hidden Join link it reveals" do
      doc = countdown(entry())
      start_unix = DateTime.to_unix(~U[2026-02-05 14:30:00Z])

      time = "time#agenda-cockpit-countdown-meeting-1-#{start_unix}"
      assert attr(doc, time, "phx-hook") == "AgendaCountdown"
      assert attr(doc, time, "phx-update") == "ignore"
      assert attr(doc, time, "data-start") == "2026-02-05T14:30:00Z"
      assert attr(doc, time, "data-end") == "2026-02-05T15:00:00Z"
      assert attr(doc, time, "data-tpl-minutes") == "in __N__m"
      assert attr(doc, time, "data-tpl-now") == "now"
      assert attr(doc, time, "data-join") == "agenda-cockpit-join-meeting-1"

      assert attr(doc, "a#agenda-cockpit-join-meeting-1", "class") =~ "hidden"
      assert attr(doc, "a#agenda-cockpit-join-meeting-1", "href") == "https://zoom.us/j/1"
    end

    test "names no Join link when there is no call" do
      doc = countdown(entry(join_url: nil))

      assert attr(doc, "time", "data-join") == nil
      assert Floki.find(doc, "a") == []
    end

    test "keys the countdown's id on the start, so a reschedule remounts the hook" do
      moved = entry(start_at: ~U[2026-02-05 16:00:00Z], end_at: ~U[2026-02-05 16:30:00Z])

      refute attr(countdown(entry()), "time", "id") == attr(countdown(moved), "time", "id")
    end
  end
end
