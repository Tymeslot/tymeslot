defmodule TymeslotWeb.Components.Dashboard.Meetings.GuestStatusPillTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard
  @moduletag :meetings

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Meetings.GuestStatusPill

  defp render_status(status) do
    doc =
      LazyHTML.from_fragment(
        render_component(&GuestStatusPill.guest_status_pill/1, status: status)
      )

    [pill] = doc |> LazyHTML.query("span.rounded-token-full") |> Enum.to_list()
    {pill |> LazyHTML.text() |> String.trim(), pill |> LazyHTML.attribute("class") |> hd()}
  end

  test "an accepted guest is going, in green" do
    {label, class} = render_status("accepted")

    assert label == "Going"
    assert class =~ "bg-green-100"
  end

  test "a declined guest has declined, in red" do
    {label, class} = render_status("declined")

    assert label == "Declined"
    assert class =~ "bg-red-100"
  end

  # The meeting card used to say "Pending" where the add-guest modal said
  # "Awaiting reply" for the same guest.
  test "any other status is awaiting a reply, in amber" do
    for status <- ["pending", "invited"] do
      {label, class} = render_status(status)

      assert label == "Awaiting reply"
      assert class =~ "bg-amber-100"
    end
  end
end
