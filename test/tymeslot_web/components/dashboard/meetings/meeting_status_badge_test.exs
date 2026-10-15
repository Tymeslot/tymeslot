defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingStatusBadgeTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :bookings

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingStatusBadge

  defp meeting(status, ends_in_seconds) do
    %{
      status: status,
      reschedule_requested_at: nil,
      end_time: DateTime.add(DateTime.utc_now(), ends_in_seconds, :second)
    }
  end

  defp render_badge(meeting) do
    html = render_component(&MeetingStatusBadge.status_badges/1, meeting: meeting)

    [pill] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("span.rounded-token-full")
      |> Enum.to_list()

    {pill |> LazyHTML.text() |> String.trim(), pill |> LazyHTML.attribute("class") |> hd()}
  end

  @future 86_400
  @past -86_400

  for {status, ends_in, label, tone} <- [
        {"cancelled", @future, "Cancelled", "bg-red-100"},
        {"expired", @past, "Expired", "bg-tymeslot-100"},
        {"reschedule_requested", @future, "Reschedule Requested", "bg-amber-100"},
        {"awaiting_approval", @future, "Awaiting your approval", "bg-amber-100"},
        {"awaiting_payment", @future, "Awaiting payment", "bg-amber-100"},
        {"completed", @past, "Completed", "bg-tymeslot-100"},
        {"confirmed", @past, "Completed", "bg-tymeslot-100"},
        {"confirmed", @future, "Scheduled", "bg-green-100"},
        {"pending", @future, "Scheduled", "bg-green-100"}
      ] do
    test "a #{status} meeting ending #{if ends_in > 0, do: "later", else: "earlier"} reads #{label}" do
      {label, class} = render_badge(meeting(unquote(status), unquote(ends_in)))

      assert label == unquote(label)
      assert class =~ unquote(tone)
    end
  end

  test "keeps every label in sentence case, since some are phrases" do
    {_label, class} = render_badge(meeting("awaiting_approval", @future))
    refute class =~ "uppercase"
  end
end
