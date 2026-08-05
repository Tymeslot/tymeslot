defmodule TymeslotWeb.Dashboard.AgendaDetailModalTest do
  @moduledoc """
  Covers the modal's time rendering. The agenda is the organiser's own, so the
  time range follows the clock they chose rather than the one their language
  would imply, and must not hardcode 12-hour `%-I:%M %p`.
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

  defp assigns(time_format) do
    %{
      entry: entry(),
      timezone: "Etc/UTC",
      time_format: time_format,
      now: ~U[2026-01-05 10:00:00Z],
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
  end

  test "renders the time range on a 12-hour clock when that is the choice" do
    html = render_component(&AgendaDetailModal.agenda_detail_modal/1, assigns("12h"))

    assert html =~ "2:30 PM"
    assert html =~ "3:00 PM"
  end

  test "renders the time range on a 24-hour clock when that is the choice" do
    html = render_component(&AgendaDetailModal.agenda_detail_modal/1, assigns("24h"))

    assert html =~ "14:30"
    assert html =~ "15:00"
    refute html =~ "PM"
  end

  test "keeps the chosen clock even when the language would imply the other" do
    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    html = render_component(&AgendaDetailModal.agenda_detail_modal/1, assigns("12h"))

    assert html =~ "2:30 PM"
    # The date beside it still follows German word order: only the clock is
    # governed by the preference.
    assert html =~ "Januar"
  end
end
