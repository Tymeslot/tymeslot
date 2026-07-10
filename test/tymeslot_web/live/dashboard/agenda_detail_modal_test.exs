defmodule TymeslotWeb.Dashboard.AgendaDetailModalTest do
  @moduledoc """
  Covers the modal's time rendering — `clock/2` must route through
  `LocaleFormat.format_time/2` rather than hardcoding 12-hour `%-I:%M %p`,
  so the time range respects the active locale (e.g. 24-hour for `de`).
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :meetings
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Dashboard.AgendaDetailModal

  setup do
    on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)
    :ok
  end

  defp entry do
    %Entry{
      id: "1",
      source: :tymeslot,
      title: "Planning sync",
      day: ~D[2026-01-05],
      start_at: ~U[2026-01-05 14:30:00Z],
      end_at: ~U[2026-01-05 15:00:00Z],
      all_day?: false
    }
  end

  defp assigns do
    %{
      entry: entry(),
      timezone: "Etc/UTC",
      now: ~U[2026-01-05 10:00:00Z],
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
  end

  test "renders the time range as 12-hour AM/PM for the en locale" do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    html = render_component(&AgendaDetailModal.agenda_detail_modal/1, assigns())

    assert html =~ "02:30 PM"
    assert html =~ "03:00 PM"
  end

  test "renders the time range as 24-hour time for the de locale" do
    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    html = render_component(&AgendaDetailModal.agenda_detail_modal/1, assigns())

    assert html =~ "14:30"
    assert html =~ "15:00"
    refute html =~ "PM"
  end
end
